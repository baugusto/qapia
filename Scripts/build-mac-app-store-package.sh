#!/bin/sh
# Creates a signed installer package for App Store Connect from this SwiftPM app.
# The packaged app uses only code embedded in the bundle and Apple's optional
# on-device Foundation Models framework for summaries.
set -euo pipefail

script_directory=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
project_root=$(CDPATH= cd -- "$script_directory/.." && pwd)
app_name="QAP.ia"
bundle_identifier="br.com.qapia.app"
entitlements_path="$project_root/App/QAPia.entitlements"
info_plist="$project_root/App/Info.plist"
staging_path="$project_root/Build/$app_name.app.staging"
app_path="$project_root/Build/$app_name.app"
package_path="$project_root/Build/$app_name-mac-app-store.pkg"
binary_path="$project_root/.build/arm64-apple-macosx/release/Qapia"
framework_path="$project_root/.build/arm64-apple-macosx/release/whisper.framework"
profile_path="${QAPIA_APP_STORE_PROVISIONING_PROFILE:-}"
application_identity="${QAPIA_APP_STORE_APPLICATION_IDENTITY:-}"
installer_identity="${QAPIA_APP_STORE_INSTALLER_IDENTITY:-}"

require_value() {
    value="$1"
    name="$2"
    if [ -z "$value" ]; then
        echo "Defina $name antes de gerar o pacote da Mac App Store." >&2
        exit 1
    fi
}

if [ -z "$application_identity" ]; then
    application_identity=$(security find-identity -v -p codesigning 2>/dev/null \
        | awk -F '"' '/"Mac App Distribution:|"Apple Distribution:|"3rd Party Mac Developer Application:/ { print $2; exit }')
fi

if [ -z "$installer_identity" ]; then
    installer_identity=$(security find-identity -v 2>/dev/null \
        | awk -F '"' '/"Mac Installer Distribution:|"3rd Party Mac Developer Installer:/ { print $2; exit }')
fi

require_value "$application_identity" "QAPIA_APP_STORE_APPLICATION_IDENTITY"
require_value "$installer_identity" "QAPIA_APP_STORE_INSTALLER_IDENTITY"
require_value "$profile_path" "QAPIA_APP_STORE_PROVISIONING_PROFILE"
require_value "${QAPIA_GOOGLE_CLIENT_ID:-}" "QAPIA_GOOGLE_CLIENT_ID"

if [ ! -f "$profile_path" ]; then
    echo "Provisioning profile não encontrado: $profile_path" >&2
    exit 1
fi

if [ ! -f "$entitlements_path" ]; then
    echo "Entitlements não encontrado: $entitlements_path" >&2
    exit 1
fi

case "$QAPIA_GOOGLE_CLIENT_ID" in
    *.apps.googleusercontent.com) ;;
    *)
        echo "QAPIA_GOOGLE_CLIENT_ID inválido: use o Client ID completo terminado em .apps.googleusercontent.com." >&2
        exit 1
        ;;
esac

cd "$project_root"
swift build -c release --arch arm64

if [ ! -f "$binary_path" ] || [ ! -d "$framework_path" ]; then
    echo "O build release não produziu o executável ou o framework esperado." >&2
    exit 1
fi

rm -rf "$staging_path"
mkdir -p "$staging_path/Contents/MacOS" "$staging_path/Contents/Frameworks" "$staging_path/Contents/Resources"
cp "$binary_path" "$staging_path/Contents/MacOS/QAPia"
cp "$info_plist" "$staging_path/Contents/Info.plist"
cp "$profile_path" "$staging_path/Contents/embedded.provisionprofile"
cp "$project_root/Assets/AppIcon.icns" "$staging_path/Contents/Resources/AppIcon.icns"
ditto "$framework_path" "$staging_path/Contents/Frameworks/whisper.framework"

# Profiles downloaded from Apple can carry Finder quarantine metadata. That
# metadata is not permitted inside an App Store or TestFlight app bundle.
xattr -cr "$staging_path"

google_client_prefix="${QAPIA_GOOGLE_CLIENT_ID%.apps.googleusercontent.com}"
google_url_scheme="com.googleusercontent.apps.$google_client_prefix"
/usr/libexec/PlistBuddy -c "Set :QAPiaGoogleClientID $QAPIA_GOOGLE_CLIENT_ID" "$staging_path/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleURLTypes:0:CFBundleURLSchemes:0 $google_url_scheme" "$staging_path/Contents/Info.plist"

codesign --force --sign "$application_identity" --options runtime --timestamp=none \
    "$staging_path/Contents/Frameworks/whisper.framework"
codesign --force --sign "$application_identity" --options runtime --timestamp=none \
    --entitlements "$entitlements_path" --identifier "$bundle_identifier" "$staging_path"
codesign --verify --deep --strict --verbose=2 "$staging_path"

rm -rf "$app_path"
mv "$staging_path" "$app_path"
rm -f "$package_path"
productbuild --sign "$installer_identity" --component "$app_path" /Applications "$package_path"

echo "Pacote para App Store Connect criado em: $package_path"
echo "Assinatura do app: $application_identity"
echo "Assinatura do instalador: $installer_identity"
