#!/bin/sh
set -euo pipefail

script_directory=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
project_root=$(CDPATH= cd -- "$script_directory/.." && pwd)
app_directory="$project_root/Build/QAP.ia.app"
staging_directory="$project_root/Build/QAP.ia.app.staging"
legacy_app_directory="$project_root/Build/QAPia.app"
binary_path="$project_root/.build/arm64-apple-macosx/debug/Qapia"
framework_path="$project_root/.build/arm64-apple-macosx/debug/whisper.framework"
signing_identity="${QAPIA_SIGNING_IDENTITY:-}"

if [ -z "$signing_identity" ]; then
    signing_identity=$(security find-identity -v -p codesigning 2>/dev/null \
        | awk -F '"' '/"Apple Development:|"Developer ID Application:/ { print $2; exit }')
fi

if [ -z "$signing_identity" ]; then
    signing_identity="QAPia Local Development"
fi

cd "$project_root"
swift build -c debug

rm -rf "$staging_directory"
mkdir -p "$staging_directory/Contents/MacOS" "$staging_directory/Contents/Frameworks" "$staging_directory/Contents/Resources"
cp "$binary_path" "$staging_directory/Contents/MacOS/QAPia"
cp "$project_root/App/Info.plist" "$staging_directory/Contents/Info.plist"
if [ -n "${QAPIA_GOOGLE_CLIENT_ID:-}" ]; then
    case "$QAPIA_GOOGLE_CLIENT_ID" in
        *.apps.googleusercontent.com) ;;
        *)
            echo "QAPIA_GOOGLE_CLIENT_ID inválido: use o Client ID completo terminado em .apps.googleusercontent.com" >&2
            exit 1
            ;;
    esac
    google_client_prefix="${QAPIA_GOOGLE_CLIENT_ID%.apps.googleusercontent.com}"
    google_url_scheme="com.googleusercontent.apps.$google_client_prefix"
    /usr/libexec/PlistBuddy -c "Set :QAPiaGoogleClientID $QAPIA_GOOGLE_CLIENT_ID" "$staging_directory/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleURLTypes:0:CFBundleURLSchemes:0 $google_url_scheme" "$staging_directory/Contents/Info.plist"
fi
cp "$project_root/Assets/AppIcon.icns" "$staging_directory/Contents/Resources/AppIcon.icns"
ditto "$framework_path" "$staging_directory/Contents/Frameworks/whisper.framework"
codesign --force --sign "$signing_identity" --timestamp=none "$staging_directory/Contents/Frameworks/whisper.framework"
codesign --force --sign "$signing_identity" --timestamp=none --identifier br.com.qapia.app "$staging_directory"

rm -rf "$app_directory"
mv "$staging_directory" "$app_directory"
rm -rf "$legacy_app_directory"
echo "App criado em: $app_directory"
echo "Assinatura usada: $signing_identity"
