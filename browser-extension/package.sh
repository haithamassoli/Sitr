#!/bin/sh
set -eu
cd "$(dirname "$0")"
version=$(python3 -c 'import json; print(json.load(open("manifest.json"))["version"])')
mkdir -p ../build
archive="../build/sitr-music-extension-$version.zip"
rm -f "$archive"
zip -q -r "$archive" . \
  -x 'tests/*' 'package.json' 'CHROMEWEBSTORE.md' 'package.sh' 'PRIVACY.md' '*.DS_Store'
python3 - "$archive" <<'PY'
import json, sys, zipfile
with zipfile.ZipFile(sys.argv[1]) as z:
    names = set(z.namelist())
    manifest = json.loads(z.read('manifest.json'))
    assert manifest['manifest_version'] == 3
    assert manifest['background']['service_worker'] in names
    assert manifest['action']['default_popup'] in names
    for path in manifest.get('icons', {}).values():
        assert path in names, path
    for path in manifest['action'].get('default_icon', {}).values():
        assert path in names, path
    assert not any(name.startswith('tests/') for name in names)
    assert 'LICENSE.nomusic' in names
print(sys.argv[1])
PY
