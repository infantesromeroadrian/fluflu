#!/usr/bin/env bash
# Construye FluFlu para distribuirla fuera de la Mac App Store: archive → export Developer ID →
# notarizar la .app → staple → .dmg firmado → notarizar el .dmg → staple → verificar con Gatekeeper.
#
# Uso:
#   scripts/release.sh            release completa (exige el certificado Developer ID y el perfil de notarización)
#   scripts/release.sh --dry-run  mismo recorrido con la firma de desarrollo y sin notarizar
#
# Variables: NOTARY_PROFILE (perfil de `notarytool store-credentials`, por defecto FluFlu-notary),
# BUILD_NUMBER (por defecto, fecha y hora: siempre creciente), SKIP_TESTS=1 para no pasar los tests,
# DEVELOPER_ID (SHA-1 o nombre completo del certificado) si hay más de uno, por ejemplo durante una renovación.
# -E: sin ella, el trap de ERR no salta dentro de funciones y un fallo al notarizar cortaba sin mensaje.
set -Eeuo pipefail

TEAM_ID="G2W8J5Z5HS"
SCHEME="FluFlu"
NOTARY_PROFILE="${NOTARY_PROFILE:-FluFlu-notary}"
BUILD_NUMBER="${BUILD_NUMBER:-$(date +%Y%m%d%H%M)}"
DRY_RUN=0
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=1

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$PROJECT_DIR/build/release-$BUILD_NUMBER"
ARCHIVE="$BUILD_DIR/FluFlu.xcarchive"
EXPORT_DIR="$BUILD_DIR/export"
APP="$EXPORT_DIR/FluFlu.app"
LOG="$BUILD_DIR/release.log"
mkdir -p "$BUILD_DIR"
exec > >(tee -a "$LOG") 2>&1

step() { printf '\n==> %s\n' "$*"; }
fail() { printf '\nERROR: %s\nRegistro completo: %s\n' "$*" "$LOG" >&2; exit 1; }
trap 'fail "falló el paso en la línea $LINENO"' ERR

if (( DRY_RUN )); then
    SIGN_IDENTITY="Apple Development"
    EXPORT_METHOD="debugging"
else
    EXPORT_METHOD="developer-id"
    step "Comprobando certificado y perfil de notarización"
    # Identidad completa, no «Developer ID Application» a secas: con dos certificados vigentes (renovación)
    # codesign falla por ambigüedad. La salida se guarda antes de filtrar por el SIGPIPE de pipefail.
    IDENTITIES="$(security find-identity -v -p codesigning)"
    MATCHES="$(awk -F'"' -v team="($TEAM_ID)" 'index($2, "Developer ID Application:") == 1 && index($2, team) { print $2 }' <<<"$IDENTITIES")"
    if [[ -n "${DEVELOPER_ID:-}" ]]; then
        SIGN_IDENTITY="$DEVELOPER_ID"
    elif [[ -z "$MATCHES" ]]; then
        fail "no hay certificado «Developer ID Application ($TEAM_ID)» en el llavero"
    elif [[ "$(wc -l <<<"$MATCHES" | tr -d ' ')" != "1" ]]; then
        fail "hay varios certificados Developer ID del equipo; indica cuál con DEVELOPER_ID=<SHA-1>"
    else
        SIGN_IDENTITY="$MATCHES"
    fi
    echo "Firma: $SIGN_IDENTITY"
    xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null \
        || fail "no existe el perfil de notarización «$NOTARY_PROFILE» (xcrun notarytool store-credentials)"
fi

if [[ "${SKIP_TESTS:-0}" != "1" ]]; then
    step "Tests unitarios"
    xcodebuild test -project "$PROJECT_DIR/FluFlu.xcodeproj" -scheme "$SCHEME" \
        -destination 'platform=macOS,arch=arm64' -only-testing:FluFluTests -quiet
fi

step "Archive (build $BUILD_NUMBER)"
xcodebuild archive -project "$PROJECT_DIR/FluFlu.xcodeproj" -scheme "$SCHEME" -configuration Release \
    -destination 'generic/platform=macOS' -archivePath "$ARCHIVE" \
    CURRENT_PROJECT_VERSION="$BUILD_NUMBER" CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM="$TEAM_ID" \
    CODE_SIGN_IDENTITY="$SIGN_IDENTITY" OTHER_CODE_SIGN_FLAGS="--timestamp" -quiet

step "Export ($EXPORT_METHOD)"
cat > "$BUILD_DIR/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key><string>$EXPORT_METHOD</string>
    <key>teamID</key><string>$TEAM_ID</string>
    <key>signingStyle</key><string>manual</string>
    <key>signingCertificate</key><string>$SIGN_IDENTITY</string>
</dict>
</plist>
PLIST
xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportPath "$EXPORT_DIR" \
    -exportOptionsPlist "$BUILD_DIR/ExportOptions.plist" -quiet

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
DMG="$BUILD_DIR/FluFlu-$VERSION.dmg"

step "Verificando la firma de la app"
codesign --verify --deep --strict --verbose=2 "$APP"
# Se guarda la salida antes de buscar: con pipefail, `grep -q` cierra la tubería y el SIGPIPE de
# codesign daba el paso por fallido aunque la marca estuviera.
SIGNATURE="$(codesign -dvvv "$APP" 2>&1)"
ENTITLEMENTS="$(codesign -d --entitlements - "$APP" 2>/dev/null)"
[[ "$SIGNATURE" == *"flags="*"runtime"* ]] || fail "la app no lleva Hardened Runtime"
if (( ! DRY_RUN )) && [[ "$ENTITLEMENTS" == *"get-task-allow"* ]]; then
    fail "la app conserva com.apple.security.get-task-allow: Apple rechaza la notarización"
fi

# Envía un fichero a Apple y espera el veredicto; si no es «Accepted», trae el informe y para.
notarize() {
    local file="$1" output id status
    # Sin cortar si notarytool sale con error: así se puede leer su salida y pedir el informe.
    output="$(xcrun notarytool submit "$file" --keychain-profile "$NOTARY_PROFILE" --wait --output-format json)" || true
    echo "$output"
    id="$(plutil -extract id raw - <<<"$output" 2>/dev/null)" || id=""
    status="$(plutil -extract status raw - <<<"$output" 2>/dev/null)" || status=""
    [[ -n "$id" ]] || fail "notarytool no devolvió un identificador de envío para $(basename "$file")"
    if [[ "$status" != "Accepted" ]]; then
        xcrun notarytool log "$id" --keychain-profile "$NOTARY_PROFILE" || true
        fail "notarización de $(basename "$file"): $status"
    fi
}

if (( ! DRY_RUN )); then
    step "Notarizando la app"
    ditto -c -k --keepParent "$APP" "$BUILD_DIR/FluFlu-notarize.zip"
    notarize "$BUILD_DIR/FluFlu-notarize.zip"
    xcrun stapler staple "$APP"
    xcrun stapler validate "$APP"
fi

step "Creando el .dmg"
STAGING="$BUILD_DIR/dmg"
# Dos ejecuciones en el mismo minuto comparten carpeta: sin limpiar, `ln -s` fallaba porque el enlace existía.
rm -rf "$STAGING"
mkdir -p "$STAGING"
ditto "$APP" "$STAGING/FluFlu.app"
ln -s /Applications "$STAGING/Aplicaciones"
hdiutil create -volname "FluFlu" -srcfolder "$STAGING" -ov -format UDZO "$DMG" >/dev/null
codesign --sign "$SIGN_IDENTITY" --timestamp "$DMG"

if (( ! DRY_RUN )); then
    step "Notarizando el .dmg"
    notarize "$DMG"
    xcrun stapler staple "$DMG"
    xcrun stapler validate "$DMG"

    step "Gatekeeper"
    spctl -a -vvv -t exec "$APP"
    spctl -a -vvv -t open --context context:primary-signature "$DMG"
fi

step "Listo"
shasum -a 256 "$DMG" | tee "$DMG.sha256"
echo "Versión $VERSION (build $BUILD_NUMBER)$( (( DRY_RUN )) && echo ', ensayo sin notarizar')"
echo "$DMG"
