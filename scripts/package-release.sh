#!/usr/bin/env bash
# A public ZIP requires Developer ID signing, notarization, stapling and Gatekeeper acceptance.
# --development creates a clearly named local candidate with an ad-hoc signature.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
mode=public
if [[ "${1:-}" == --development && $# == 1 ]]; then mode=development
elif [[ $# != 0 ]]; then echo "Usage: $0 [--development]" >&2; exit 2; fi

if [[ "$mode" == public ]]; then
  : "${TESSERA_CODESIGN_IDENTITY:?Set a Developer ID Application identity}"
  : "${TESSERA_NOTARY_PROFILE:?Set an existing notarytool Keychain profile}"
  export TESSERA_DISTRIBUTION=1
else
  export TESSERA_CODESIGN_IDENTITY=- TESSERA_DISTRIBUTION=0
fi

version=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$root/Resources/Info.plist")
arch=$(uname -m)
out="$root/.build/releases"
mkdir -p "$out"
stage=$(mktemp -d "$out/stage.XXXXXX")
trap 'rm -rf "$stage"' EXIT
export TESSERA_APP_PATH="$stage/Tessera.app"
export TESSERA_SCRATCH_PATH="${TESSERA_SCRATCH_PATH:-$root/.build/release-audit}"
"$root/scripts/build-app.sh" >/dev/null

suffix=""
if [[ "$mode" == public ]]; then
  /usr/bin/codesign -dv --verbose=4 "$TESSERA_APP_PATH" 2>&1 | /usr/bin/grep -q '^Authority=Developer ID Application:' || {
    echo 'Public release requires a Developer ID Application signature.' >&2; exit 1;
  }
  /usr/bin/ditto -c -k --sequesterRsrc --keepParent "$TESSERA_APP_PATH" "$stage/notary.zip"
  /usr/bin/xcrun notarytool submit "$stage/notary.zip" --keychain-profile "$TESSERA_NOTARY_PROFILE" --wait
  /usr/bin/xcrun stapler staple "$TESSERA_APP_PATH"
  /usr/bin/xcrun stapler validate "$TESSERA_APP_PATH"
  /usr/sbin/spctl --assess --type execute --verbose=2 "$TESSERA_APP_PATH"
else
  suffix=-development
fi

artifact="$out/Tessera-$version-macos-$arch$suffix.zip"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$TESSERA_APP_PATH" "$artifact"
(cd "$out" && /usr/bin/shasum -a 256 "$(basename "$artifact")" > "$(basename "$artifact").sha256")
echo "$artifact"
echo "SHA-256: $artifact.sha256"
if [[ "$mode" == development ]]; then
  echo 'Development candidate only: not Developer ID signed or notarized.'
fi
