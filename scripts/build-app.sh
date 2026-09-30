#!/usr/bin/env bash
# Builds Tessera.app from the SwiftPM executable and signs it: with $TESSERA_CODESIGN_IDENTITY when set
# ("-" for ad-hoc), otherwise with the first code-signing identity in your keychain.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
configuration=${CONFIGURATION:-release}
app="${TESSERA_APP_PATH:-$root/.build/app/Tessera.app}"
contents="$app/Contents"

swift build --package-path "$root" -c "$configuration" --product Tessera >&2
bin_dir=$(swift build --package-path "$root" -c "$configuration" --show-bin-path)

/bin/rm -rf "$app"
mkdir -p "$contents/MacOS" "$contents/Resources"
/usr/bin/ditto "$bin_dir/Tessera" "$contents/MacOS/Tessera"
/usr/bin/ditto "$root/Resources/Info.plist" "$contents/Info.plist"
if [[ -f "$root/Resources/AppIcon.icns" ]]; then
  /usr/bin/ditto "$root/Resources/AppIcon.icns" "$contents/Resources/AppIcon.icns"
fi
for bundle in "$bin_dir"/*.bundle; do
  [[ -d "$bundle" ]] && /usr/bin/ditto "$bundle" "$contents/Resources/$(basename "$bundle")"
done
for notice in LICENSE THIRD_PARTY_NOTICES.md LICENSES; do
  /usr/bin/ditto "$root/$notice" "$contents/Resources/$notice"
done

identity=${TESSERA_CODESIGN_IDENTITY:-}
if [[ -z "$identity" ]]; then
  identity=$(/usr/bin/security find-identity -v -p codesigning 2>/dev/null \
    | /usr/bin/sed -nE 's/^[[:space:]]*[0-9]+\) ([[:xdigit:]]+) ".*"$/\1/p' | /usr/bin/head -n 1)
fi
if [[ -z "$identity" ]]; then
  identity="-"
  echo "warning: no code-signing identity; Accessibility permission will need re-granting after each build" >&2
fi
echo "signing with: $(/usr/bin/security find-identity -v -p codesigning 2>/dev/null | /usr/bin/grep -F "$identity" | /usr/bin/sed -nE 's/.*"(.*)"$/\1/p' | /usr/bin/head -n 1 || true) ($identity)" >&2
/usr/bin/codesign --force --sign "$identity" "$app"
echo "$app"
