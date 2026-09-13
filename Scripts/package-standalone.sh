#!/bin/sh
set -euo pipefail

script_directory=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
project_root=$(CDPATH= cd -- "$script_directory/.." && pwd)
app_path="$project_root/Build/QAP.ia.app"
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$project_root/App/Info.plist")
dmg_path="$project_root/Build/QAP.ia-$version.dmg"
package_directory=$(mktemp -d "${TMPDIR:-/tmp}/qapia-package.XXXXXX")

cleanup() {
    rm -rf "$package_directory"
}
trap cleanup EXIT INT TERM

bash "$script_directory/build-app-bundle.sh"

codesign --verify --deep --strict --verbose=2 "$app_path"
ditto "$app_path" "$package_directory/QAP.ia.app"
ln -s /Applications "$package_directory/Applications"

rm -f "$dmg_path"
hdiutil create \
    -volname "QAP.ia" \
    -srcfolder "$package_directory" \
    -ov \
    -format UDZO \
    "$dmg_path"

if [ -n "${QAPIA_NOTARIZE_PROFILE:-}" ]; then
    xcrun notarytool submit "$dmg_path" \
        --keychain-profile "$QAPIA_NOTARIZE_PROFILE" \
        --wait
    xcrun stapler staple "$dmg_path"
fi

echo "Instalador criado em: $dmg_path"
