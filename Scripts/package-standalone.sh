#!/bin/sh
set -euo pipefail

script_directory=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
project_root=$(CDPATH= cd -- "$script_directory/.." && pwd)
app_path="$project_root/Build/QAP.ia.app"
info_plist="$project_root/App/Info.plist"
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$info_plist")
dmg_path="$project_root/Build/QAP.ia-$version.dmg"
staging_dmg_path="$project_root/Build/.QAP.ia-$version.staging.dmg"
package_directory=$(mktemp -d "${TMPDIR:-/tmp}/qapia-package.XXXXXX")
notary_result_path=""

cleanup() {
    rm -rf "$package_directory"
    rm -f "$staging_dmg_path"
    if [ -n "$notary_result_path" ]; then
        rm -f "$notary_result_path"
    fi
}
trap cleanup EXIT INT TERM

bash "$script_directory/build-app-bundle.sh"

codesign --verify --deep --strict --verbose=2 "$app_path"
signed_bundle_identifier=$(codesign -dvv "$app_path" 2>&1 \
    | sed -n 's/^Identifier=//p' \
    | head -n 1)
[ "$signed_bundle_identifier" = "br.com.qapia.app" ] || {
    echo "O app assinado possui um bundle identifier inesperado: $signed_bundle_identifier" >&2
    exit 1
}

signature_details=$(codesign -dvv "$app_path" 2>&1)
printf '%s\n' "$signature_details" | grep -q '(runtime)' || {
    echo "O app standalone não está protegido pelo Hardened Runtime." >&2
    exit 1
}
signed_authority=$(printf '%s\n' "$signature_details" \
    | sed -n 's/^Authority=//p' \
    | head -n 1)

portable_package=false
case "$signed_authority" in
    "Developer ID Application:"*)
        if [ -n "${QAPIA_NOTARIZE_PROFILE:-}" ]; then
            portable_package=true
        fi
        ;;
esac

if [ "$portable_package" != true ]; then
    if [ "${QAPIA_ALLOW_LOCAL_PACKAGE:-0}" != "1" ]; then
        if [ -z "${QAPIA_NOTARIZE_PROFILE:-}" ] \
           && printf '%s\n' "$signed_authority" | grep -q '^Developer ID Application:'; then
            echo "Um pacote portátil exige notarização. Defina QAPIA_NOTARIZE_PROFILE com um perfil válido." >&2
        else
            echo "A identidade '$signed_authority' não é válida para distribuição direta pelo Gatekeeper." >&2
            echo "Instale um certificado Developer ID Application e configure a notarização." >&2
        fi
        echo "Use QAPIA_ALLOW_LOCAL_PACKAGE=1 somente para homologação neste Mac." >&2
        exit 1
    fi
    dmg_path="$project_root/Build/QAP.ia-$version-local.dmg"
    staging_dmg_path="$project_root/Build/.QAP.ia-$version-local.staging.dmg"
    echo "Pacote de homologação local: não portátil e não aceito pelo Gatekeeper em outros Macs."
fi

bundle_version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app_path/Contents/Info.plist")
[ "$bundle_version" = "$version" ] || {
    echo "A versão do bundle ($bundle_version) não corresponde à versão solicitada ($version)." >&2
    exit 1
}

if [ "$portable_package" = true ]; then
    printf '%s\n' "$signature_details" | grep -q '^Authority=Developer ID Application:' || {
        echo "Notarização exige assinatura 'Developer ID Application'. A identidade local é adequada somente para testes neste Mac." >&2
        exit 1
    }
fi

ditto "$app_path" "$package_directory/QAP.ia.app"
ln -s /Applications "$package_directory/Applications"

rm -f "$staging_dmg_path"
hdiutil create \
    -volname "QAP.ia" \
    -srcfolder "$package_directory" \
    -ov \
    -format UDZO \
    "$staging_dmg_path"

hdiutil verify "$staging_dmg_path"

case "$signed_authority" in
    "Developer ID Application:"*)
        # Sign the distribution container as well as the nested app. Apple can
        # then notarize and staple the exact immutable artifact delivered.
        codesign --force --sign "$signed_authority" --timestamp "$staging_dmg_path"
        codesign --verify --strict --verbose=2 "$staging_dmg_path"
        hdiutil verify "$staging_dmg_path"
        ;;
esac

if [ "$portable_package" = true ]; then
    notary_result_path=$(mktemp "${TMPDIR:-/tmp}/qapia-notary-result.XXXXXX.plist")
    xcrun notarytool submit "$staging_dmg_path" \
        --keychain-profile "$QAPIA_NOTARIZE_PROFILE" \
        --wait \
        --output-format plist > "$notary_result_path"
    notary_status=$(/usr/libexec/PlistBuddy -c 'Print :status' "$notary_result_path" 2>/dev/null || true)
    [ "$notary_status" = "Accepted" ] || {
        echo "A notarização não foi aceita pela Apple (status: ${notary_status:-desconhecido})." >&2
        exit 1
    }
    xcrun stapler staple "$staging_dmg_path"
    xcrun stapler validate "$staging_dmg_path"
    spctl -a -t open --context context:primary-signature -vv "$staging_dmg_path"
    echo "Notarização: concluída e validada"
else
    echo "Notarização: não executada; artefato marcado como homologação local"
fi

mv -f "$staging_dmg_path" "$dmg_path"
echo "Instalador criado em: $dmg_path"
