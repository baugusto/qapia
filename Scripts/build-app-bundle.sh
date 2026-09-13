#!/bin/sh
set -euo pipefail

script_directory=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
project_root=$(CDPATH= cd -- "$script_directory/.." && pwd)
app_name="QAP.ia"
bundle_identifier="br.com.qapia.app"
app_directory="$project_root/Build/QAP.ia.app"
staging_directory="$project_root/Build/QAP.ia.app.staging"
legacy_app_directory="$project_root/Build/QAPia.app"
info_plist="$project_root/App/Info.plist"
entitlements_path="${QAPIA_STANDALONE_ENTITLEMENTS:-$script_directory/QAPia-standalone.entitlements}"
build_configuration="${QAPIA_BUILD_CONFIGURATION:-release}"
build_architecture="${QAPIA_BUILD_ARCHITECTURE:-arm64}"
build_scratch_directory="${QAPIA_BUILD_SCRATCH_PATH:-$project_root/.build}"
build_products_directory="$build_scratch_directory/$build_architecture-apple-macosx/$build_configuration"
swiftpm_cache_directory="$build_scratch_directory/cache"
swiftpm_configuration_directory="$build_scratch_directory/configuration"
swiftpm_security_directory="$build_scratch_directory/security"
binary_path="$build_products_directory/Qapia"
framework_path="$build_products_directory/whisper.framework"
signing_identity="${QAPIA_SIGNING_IDENTITY:-}"
explicit_signing_identity="${QAPIA_SIGNING_IDENTITY:-}"
signing_identity_label=""
signing_identity_source="explicit"
preserve_existing_requirement=false
previous_designated_requirement=""
tamper_check_directory=""

fail() {
    echo "Erro no build standalone: $*" >&2
    exit 1
}

cleanup() {
    rm -rf "$staging_directory"
    if [ -n "$tamper_check_directory" ]; then
        rm -rf "$tamper_check_directory"
    fi
}
trap cleanup EXIT INT TERM

case "$build_configuration" in
    debug|release) ;;
    *) fail "QAPIA_BUILD_CONFIGURATION deve ser 'debug' ou 'release'." ;;
esac

case "$build_architecture" in
    arm64|x86_64) ;;
    *) fail "QAPIA_BUILD_ARCHITECTURE deve ser 'arm64' ou 'x86_64'." ;;
esac

[ -f "$info_plist" ] || fail "Info.plist não encontrado em $info_plist"
[ -f "$entitlements_path" ] || fail "Entitlements standalone não encontrado em $entitlements_path"
plutil -lint "$info_plist" >/dev/null
plutil -lint "$entitlements_path" >/dev/null

plist_bundle_identifier=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$info_plist")
[ "$plist_bundle_identifier" = "$bundle_identifier" ] \
    || fail "CFBundleIdentifier inesperado: $plist_bundle_identifier"

for required_key in CFBundleExecutable CFBundleShortVersionString CFBundleVersion NSMicrophoneUsageDescription NSAudioCaptureUsageDescription; do
    required_value=$(/usr/libexec/PlistBuddy -c "Print :$required_key" "$info_plist" 2>/dev/null || true)
    [ -n "$required_value" ] || fail "A chave obrigatória $required_key está ausente ou vazia no Info.plist."
done

if /usr/libexec/PlistBuddy -c 'Print :NSScreenCaptureUsageDescription' "$info_plist" >/dev/null 2>&1; then
    fail "O standalone não deve declarar acesso à captura de tela."
fi

audio_input_entitlement=$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.device.audio-input' "$entitlements_path" 2>/dev/null || true)
[ "$audio_input_entitlement" = "true" ] \
    || fail "Os entitlements standalone precisam habilitar com.apple.security.device.audio-input."

app_sandbox_entitlement=$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.app-sandbox' "$entitlements_path" 2>/dev/null || true)
[ "$app_sandbox_entitlement" != "true" ] \
    || fail "O bundle standalone não deve habilitar App Sandbox."

library_validation_entitlement=$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.cs.disable-library-validation' "$entitlements_path" 2>/dev/null || true)
[ "$library_validation_entitlement" != "true" ] \
    || fail "O standalone deve manter a validação de bibliotecas do Hardened Runtime habilitada."

identity_listing=$(security find-identity -v -p codesigning 2>/dev/null || true)

if [ -d "$app_directory" ]; then
    previous_designated_requirement=$(codesign -d -r- "$app_directory" 2>&1 \
        | sed -n 's/^designated => //p' \
        | head -n 1)
fi

# macOS associates privacy consent with the app's code-signing requirement.
# When identity selection is automatic, changing that requirement between
# builds would make an update look like a different app and can trigger a new
# microphone/audio-capture authorization. Refuse that silent identity change;
# an explicit QAPIA_SIGNING_IDENTITY remains the deliberate override.
if [ -z "$explicit_signing_identity" ] && [ -n "$previous_designated_requirement" ]; then
    preserve_existing_requirement=true
fi

if [ -z "$signing_identity" ]; then
    signing_identity=$(printf '%s\n' "$identity_listing" \
        | awk -F '"' '/"Developer ID Application:/ { print $2; exit }')
    if [ -n "$signing_identity" ]; then
        signing_identity_label="$signing_identity"
        signing_identity_source="developer-id"
    fi
fi

if [ -z "$signing_identity" ]; then
    signing_identity=$(printf '%s\n' "$identity_listing" \
        | awk -F '"' '/"3rd Party Mac Developer Application:/ { print $2; exit }')
    if [ -n "$signing_identity" ]; then
        signing_identity_label="$signing_identity"
        signing_identity_source="mac-distribution"
    fi
fi

if [ -z "$signing_identity" ]; then
    signing_identity=$(printf '%s\n' "$identity_listing" \
        | awk -F '"' '/"Apple Development:/ { print $2; exit }')
    if [ -n "$signing_identity" ]; then
        signing_identity_label="$signing_identity"
        signing_identity_source="apple-development"
    fi
fi

if [ -z "$signing_identity_label" ]; then
    signing_identity_label=$(printf '%s\n' "$identity_listing" \
        | awk -F '"' -v target="$signing_identity" 'tolower($1) ~ tolower(target) { print $2; exit }')
fi
[ -n "$signing_identity_label" ] || signing_identity_label="$signing_identity"
[ -n "$signing_identity" ] \
    || fail "Nenhuma identidade Apple com Team ID foi encontrada. Instale um certificado Developer ID, Mac Distribution ou Apple Development válido."

timestamp_mode="${QAPIA_CODESIGN_TIMESTAMP:-auto}"
case "$timestamp_mode" in
    auto)
        case "$signing_identity_label" in
            "Developer ID Application:"*) timestamp_mode="required" ;;
            *) timestamp_mode="none" ;;
        esac
        ;;
    required|none) ;;
    *) fail "QAPIA_CODESIGN_TIMESTAMP deve ser 'auto', 'required' ou 'none'." ;;
esac

sign_code() {
    target="$1"
    shift
    if [ "$timestamp_mode" = "required" ]; then
        codesign --force --sign "$signing_identity" --options runtime --timestamp "$@" "$target"
    else
        codesign --force --sign "$signing_identity" --options runtime --timestamp=none "$@" "$target"
    fi
}

cd "$project_root"
# Swift/Clang PCM files embed absolute paths and toolchain details. Invalidate
# compiled products only when either changes; keep dependency/artifact caches
# and preserve clean incremental builds on consecutive releases.
compiler_identity=$(swiftc --version 2>&1 | tr '\n' ' ')
sdk_identity=$(xcrun --sdk macosx --show-sdk-path)
cache_identity="$project_root|$compiler_identity|$sdk_identity"
product_cache_identity_path="$build_products_directory/.qapia-cache-identity"
local_cache_identity_path="$build_scratch_directory/.qapia-local-cache-identity"

recorded_product_cache_identity=""
if [ -f "$product_cache_identity_path" ]; then
    recorded_product_cache_identity=$(sed -n '1p' "$product_cache_identity_path")
fi
if [ "$recorded_product_cache_identity" != "$cache_identity" ]; then
    rm -rf "$build_products_directory"
fi

recorded_local_cache_identity=""
if [ -f "$local_cache_identity_path" ]; then
    recorded_local_cache_identity=$(sed -n '1p' "$local_cache_identity_path")
fi
if [ "$recorded_local_cache_identity" != "$cache_identity" ]; then
    rm -rf "$build_scratch_directory/LocalClangModuleCache" "$build_scratch_directory/LocalSwiftPMModuleCache"
fi

mkdir -p \
    "$build_products_directory" \
    "$build_scratch_directory/LocalClangModuleCache" \
    "$build_scratch_directory/LocalSwiftPMModuleCache" \
    "$swiftpm_cache_directory" \
    "$swiftpm_configuration_directory" \
    "$swiftpm_security_directory"

env \
    CLANG_MODULE_CACHE_PATH="$build_scratch_directory/LocalClangModuleCache" \
    SWIFTPM_MODULECACHE_OVERRIDE="$build_scratch_directory/LocalSwiftPMModuleCache" \
    swift build \
        --cache-path "$swiftpm_cache_directory" \
        --config-path "$swiftpm_configuration_directory" \
        --security-path "$swiftpm_security_directory" \
        --scratch-path "$build_scratch_directory" \
        --manifest-cache local \
        -c "$build_configuration" \
        --arch "$build_architecture" \
        --disable-sandbox

printf '%s\n' "$cache_identity" > "$product_cache_identity_path"
printf '%s\n' "$cache_identity" > "$local_cache_identity_path"

[ -x "$binary_path" ] || fail "O build não produziu o executável esperado: $binary_path"
[ -d "$framework_path" ] || fail "O build não produziu o framework esperado: $framework_path"

rm -rf "$staging_directory"
mkdir -p "$staging_directory/Contents/MacOS" "$staging_directory/Contents/Frameworks" "$staging_directory/Contents/Resources"
cp "$binary_path" "$staging_directory/Contents/MacOS/QAPia"
cp "$info_plist" "$staging_directory/Contents/Info.plist"
google_client_id="${QAPIA_GOOGLE_CLIENT_ID:-}"
if [ -z "$google_client_id" ]; then
    google_client_id=$(/usr/libexec/PlistBuddy -c 'Print :QAPiaGoogleClientID' "$info_plist" 2>/dev/null || true)
fi
case "$google_client_id" in
    ?*.apps.googleusercontent.com) ;;
    *) fail "Client ID do Google inválido ou ausente no Info.plist e em QAPIA_GOOGLE_CLIENT_ID." ;;
esac
google_client_prefix="${google_client_id%.apps.googleusercontent.com}"
google_url_scheme="com.googleusercontent.apps.$google_client_prefix"
/usr/libexec/PlistBuddy -c "Set :QAPiaGoogleClientID $google_client_id" "$staging_directory/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleURLTypes:0:CFBundleURLSchemes:0 $google_url_scheme" "$staging_directory/Contents/Info.plist"
cp "$project_root/Assets/AppIcon.icns" "$staging_directory/Contents/Resources/AppIcon.icns"
ditto "$framework_path" "$staging_directory/Contents/Frameworks/whisper.framework"

if [ -n "${QAPIA_WHISPER_MODEL_PATH:-}" ]; then
    [ -f "$QAPIA_WHISPER_MODEL_PATH" ] \
        || fail "Modelo Whisper standalone não encontrado em $QAPIA_WHISPER_MODEL_PATH"
    model_sha1=$(shasum -a 1 "$QAPIA_WHISPER_MODEL_PATH" | awk '{ print $1 }')
    [ "$model_sha1" = "55356645c2b361a969dfd0ef2c5a50d530afd8d5" ] \
        || fail "O modelo Whisper standalone não passou na verificação SHA-1."
    cp "$QAPIA_WHISPER_MODEL_PATH" \
        "$staging_directory/Contents/Resources/ggml-small.bin"
fi

plutil -lint "$staging_directory/Contents/Info.plist" >/dev/null
xattr -cr "$staging_directory"

sign_code "$staging_directory/Contents/Frameworks/whisper.framework"
sign_code "$staging_directory" \
    --entitlements "$entitlements_path" \
    --identifier "$bundle_identifier"

codesign --verify --strict --verbose=2 "$staging_directory/Contents/Frameworks/whisper.framework"
codesign --verify --deep --strict --verbose=2 "$staging_directory"

signature_details=$(codesign -dvv "$staging_directory" 2>&1)
printf '%s\n' "$signature_details" | grep -q "Identifier=$bundle_identifier" \
    || fail "A assinatura não preservou o bundle identifier."
printf '%s\n' "$signature_details" | grep -q '(runtime)' \
    || fail "A assinatura não habilitou o Hardened Runtime."
if printf '%s\n' "$signature_details" | grep -q 'Info.plist=not bound'; then
    fail "O Info.plist externo não foi vinculado à assinatura do bundle."
fi

# Prove that the signed metadata is immutable: changing even one plist value
# in a disposable copy must invalidate verification.
tamper_check_directory=$(mktemp -d "${TMPDIR:-/tmp}/qapia-signature-check.XXXXXX")
ditto "$staging_directory" "$tamper_check_directory/QAP.ia.app"
/usr/libexec/PlistBuddy -c 'Set :CFBundleDisplayName QAP.ia-alterado' \
    "$tamper_check_directory/QAP.ia.app/Contents/Info.plist"
if codesign --verify --deep --strict "$tamper_check_directory/QAP.ia.app" >/dev/null 2>&1; then
    fail "A assinatura aceitou um Info.plist adulterado."
fi
rm -rf "$tamper_check_directory"
tamper_check_directory=""

embedded_entitlements=$(codesign -d --entitlements - "$staging_directory" 2>/dev/null || true)
printf '%s\n' "$embedded_entitlements" | grep -q 'com.apple.security.device.audio-input' \
    || fail "A assinatura não incorporou o entitlement de entrada de áudio."
if printf '%s\n' "$embedded_entitlements" | grep -q 'com.apple.security.cs.disable-library-validation'; then
    fail "A assinatura standalone desabilitou indevidamente a validação de bibliotecas."
fi
if printf '%s\n' "$embedded_entitlements" | grep -q 'com.apple.security.app-sandbox'; then
    fail "A assinatura standalone incorporou App Sandbox indevidamente."
fi

new_designated_requirement=$(codesign -d -r- "$staging_directory" 2>&1 \
    | sed -n 's/^designated => //p' \
    | head -n 1)
[ -n "$new_designated_requirement" ] || fail "Não foi possível validar o requisito designado da assinatura."

main_team_identifier=$(printf '%s\n' "$signature_details" \
    | sed -n 's/^TeamIdentifier=//p' \
    | head -n 1)
framework_signature_details=$(codesign -dvv "$staging_directory/Contents/Frameworks/whisper.framework" 2>&1)
framework_team_identifier=$(printf '%s\n' "$framework_signature_details" \
    | sed -n 's/^TeamIdentifier=//p' \
    | head -n 1)
[ -n "$main_team_identifier" ] && [ "$main_team_identifier" != "not set" ] \
    || fail "A identidade escolhida não possui Team ID; o Hardened Runtime bloquearia o framework Whisper."
[ "$framework_team_identifier" = "$main_team_identifier" ] \
    || fail "O app e o framework Whisper foram assinados com Team IDs diferentes."

otool -l "$staging_directory/Contents/MacOS/QAPia" \
    | grep -q '@executable_path/../Frameworks' \
    || fail "O executável não contém o caminho de carregamento do framework incorporado."

if [ "$preserve_existing_requirement" = true ] \
   && [ -n "$previous_designated_requirement" ] \
   && [ "$new_designated_requirement" != "$previous_designated_requirement" ]; then
    fail "A nova assinatura mudaria a identidade TCC do app. Use explicitamente QAPIA_SIGNING_IDENTITY apenas se essa troca for intencional."
fi

rm -rf "$app_directory"
mv "$staging_directory" "$app_directory"
rm -rf "$legacy_app_directory"
echo "App criado em: $app_directory"
echo "Configuração: $build_configuration ($build_architecture)"
echo "Assinatura usada: $signing_identity_label ($signing_identity_source)"
echo "Hardened Runtime: habilitado"
if [ "$timestamp_mode" = "required" ]; then
    echo "Timestamp seguro: aplicado"
else
    echo "Timestamp seguro: não aplicável à identidade local/de desenvolvimento"
fi
if [ "$preserve_existing_requirement" = true ]; then
    echo "Identidade TCC: requisito designado preservado"
fi
