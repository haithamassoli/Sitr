#!/bin/bash
# Fails if the built app has any network entitlement or lacks the sandbox. Usage: scripts/check-entitlements.sh [app]
set -euo pipefail
APP=${1:-build/Sitr.app}
ENT=$(codesign -d --entitlements :- --xml "$APP" 2>/dev/null | plutil -convert xml1 -o - -)
echo "$ENT"
if grep -q "com.apple.security.network" <<<"$ENT"; then echo "FAIL: network entitlement present in $APP"; exit 1; fi
grep -q "com.apple.security.app-sandbox" <<<"$ENT" || { echo "FAIL: app-sandbox entitlement missing in $APP"; exit 1; }
echo "OK: $APP is sandboxed with no network entitlements"
