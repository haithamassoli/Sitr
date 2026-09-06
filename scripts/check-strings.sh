#!/bin/bash
# String Catalog gate (M4-T05). Fails when a user-facing literal in Sources/Sitr is missing from the catalog or has no
# Arabic translation. Usage: scripts/check-strings.sh [catalog]   (default App/Resources/Localizable.xcstrings)
#
# A literal counts when it is the first argument of Text( Button( Toggle( Label( Section( LabeledContent( Picker(
# TableColumn( Menu( Link( LocalizedStringKey( String(localized: or .accessibilityLabel/Hint/Value(. Anything computed
# (Text(someString)) is invisible here, which is why computed texts must go through String(localized:) in code.
# Interpolations (\(x)) match any %-specifier in the key, so "Step \(a) of \(b)" satisfies "Step %lld of %lld".
# ponytail: regex + a 20-line literal scanner instead of SwiftSyntax; multi-line """ literals are rejected, not parsed.
set -euo pipefail
cd "$(dirname "$0")/.."
python3 - "${1:-App/Resources/Localizable.xcstrings}" <<'PY'
import json, pathlib, re, sys

catalog_path = pathlib.Path(sys.argv[1])
catalog = json.loads(catalog_path.read_text(encoding="utf-8"))
strings = catalog["strings"]

opener = re.compile(
    r'(?<![\w.])(?:(?:Text|Button|Toggle|Label|Section|LabeledContent|Picker|TableColumn|Menu|Link|LocalizedStringKey)\s*\('
    r'|String\(\s*localized:'
    r'|\.accessibility(?:Label|Hint|Value)\s*\()\s*"')
PLACEHOLDER = "\0"
escapes = {"n": "\n", "t": "\t", "r": "\r", "0": "\0", "\\": "\\", '"': '"', "'": "'"}


def read_literal(src, i):
    """src[i] is the first char after the opening quote. Returns (literal with \0 per interpolation, index after the closing quote)."""
    out = []
    while i < len(src):
        c = src[i]
        if c == '"':
            return "".join(out), i + 1
        if c == "\\":
            n = src[i + 1]
            if n == "(":  # interpolation: skip to the matching paren, quotes inside are skipped as a unit
                depth, i = 1, i + 2
                while depth:
                    if src[i] == '"':
                        i = src.index('"', i + 1)
                    elif src[i] == "(":
                        depth += 1
                    elif src[i] == ")":
                        depth -= 1
                    i += 1
                out.append(PLACEHOLDER)
                continue
            out.append(escapes.get(n, "\\" + n))
            i += 2
            continue
        if c == "\n":
            raise SystemExit(f"{path}: unterminated string literal near offset {i}")
        out.append(c)
        i += 1
    raise SystemExit(f"{path}: unterminated string literal")


literals = {}  # literal -> first "file:line"
for path in sorted(pathlib.Path("Sources/Sitr").rglob("*.swift")):
    # Whole-line // comments are blanked (line numbers kept) so an example such as Text("…") in a doc comment is not a key.
    src = re.sub(r"(?m)^\s*//.*$", "", path.read_text(encoding="utf-8"))
    for m in opener.finditer(src):
        start = m.end()
        line = src.count("\n", 0, start) + 1
        if src.startswith('""', start):
            raise SystemExit(f"{path}:{line}: multi-line string literals are not supported here")
        if src.startswith('"', start):
            continue  # "" (an empty TableColumn title) has nothing to translate
        literal, _ = read_literal(src, start)
        literals.setdefault(literal, f"{path}:{line}")


def key_matches(literal):
    if PLACEHOLDER not in literal:
        return literal if literal in strings else None
    pattern = "".join(r"%(?:\d+\$)?[a-zA-Z@]+" if part == PLACEHOLDER else re.escape(part) for part in re.split(f"({PLACEHOLDER})", literal) if part)
    rx = re.compile(pattern, re.DOTALL)
    return next((k for k in strings if rx.fullmatch(k)), None)


problems, used = [], set()
for literal, where in sorted(literals.items(), key=lambda kv: kv[1]):
    key = key_matches(literal)
    shown = literal.replace(PLACEHOLDER, "\\(…)").replace("\n", "\\n")
    if key is None:
        problems.append(f"{where}: not in {catalog_path}: \"{shown}\"")
        continue
    used.add(key)
    ar = (strings[key].get("localizations") or {}).get("ar", {}).get("stringUnit") or {}
    if not ar.get("value") or ar.get("state") != "translated":
        problems.append(f"{where}: no translated Arabic value for \"{shown}\"")

for p in problems:
    print(p)
unused = sorted(set(strings) - used)
for k in unused:
    print(f"warning: catalog key not referenced from Sources/Sitr: \"{k}\"")
if problems:
    print(f"FAIL: {len(problems)} string problem(s), {len(literals)} literals scanned, {len(strings)} catalog keys")
    sys.exit(1)
print(f"OK: {len(literals)} literals in Sources/Sitr all present in {catalog_path} with Arabic; {len(strings)} keys, {len(unused)} unreferenced")
PY
