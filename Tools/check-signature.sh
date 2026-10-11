#!/bin/zsh
# Check a release build the way a downloaded copy is checked, before publishing it.
#   Tools/check-signature.sh dist/Lasso-X.Y.Z.dmg   (or a Lasso.app)
# Fails if the signature is invalid or its certificate has been revoked. A revoked certificate makes
# macOS treat the app as malware and move it to the Trash (lasso-app#2). "Unnotarized" is expected and
# allowed: releases aren't notarized without a paid Apple Developer Program membership.
set -u
target=${1:?usage: check-signature.sh <Lasso.app | Lasso.dmg>}
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

if [[ $target == *.dmg ]]; then
  mount=$(hdiutil attach -nobrowse -readonly "$target" 2>/dev/null | tail -1 | awk -F'\t' '{print $NF}')
  cp -R "$mount/Lasso.app" "$work/" && hdiutil detach "$mount" -quiet
else
  cp -R "$target" "$work/"
fi
app="$work/Lasso.app"
# As a browser download: quarantined, so Gatekeeper evaluates it like a user's Mac would.
xattr -w com.apple.quarantine "0083;$(printf %x $(date +%s));Safari;" "$app"

signer=$(codesign -dvv "$app" 2>&1 | grep -m1 '^Authority=' | cut -d= -f2-)
verify=$(codesign --verify --deep --strict "$app" 2>&1)
assess=$(spctl --assess --type execute -vv "$app" 2>&1)
echo "signed by: ${signer:-unknown}"
echo "codesign:  ${verify:-valid}"
echo "gatekeeper: $(echo "$assess" | tr '\n' ' ')"

if [[ -n $verify || $assess == *REVOKED* || $assess == *revoked* ]]; then
  echo "FAIL: signature invalid or certificate revoked. Do not publish." >&2
  exit 1
fi
echo "OK: valid signature (unnotarized, as expected)."
