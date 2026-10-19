#!/usr/bin/env bash
# Construye la variante de la Mac App Store (sandbox, AppStore.xcconfig) y la sube a App Store Connect:
# tests de la variante → archive firmado con Apple Distribution → export .pkg (instalador de la tienda)
# → comprobaciones → validación → subida. La revisión de Apple se pide aparte, desde App Store Connect.
#
# Uso:
#   scripts/release-appstore.sh            hasta la subida
#   scripts/release-appstore.sh --no-upload  se queda en el .pkg validado
#
# Variables: ASC_KEY_ID y ASC_ISSUER_ID (clave de API de App Store Connect, en el entorno o en scripts/asc.env;
# el .p8 en ~/.appstoreconnect/private_keys/AuthKey_<ID>.p8, donde lo busca altool), BUILD_NUMBER (por defecto,
# fecha y hora en tres enteros: siempre creciente) y SKIP_TESTS=1 para no pasar los tests.
# -E: sin ella, el trap de ERR no salta dentro de funciones.
set -Eeuo pipefail

TEAM_ID="G2W8J5Z5HS"
SCHEME="FluFlu"
BUNDLE_ID="com.adrianinfantes.FluFlu.AppStore"
PROFILE_NAME="FluFlu App Store"
# Identificadores de la clave de API de App Store Connect: no son el secreto (el .p8 vive fuera del repo),
# pero identifican la cuenta y este repositorio es público. Vienen del entorno o de scripts/asc.env, ignorado por git.
ASC_ENV="$(cd "$(dirname "$0")" && pwd)/asc.env"
if [[ -f "$ASC_ENV" ]]; then source "$ASC_ENV"; fi
ASC_KEY_ID="${ASC_KEY_ID:-}"
ASC_ISSUER_ID="${ASC_ISSUER_ID:-}"
PRIVACY_URL="https://github.com/infantesromeroadrian/fluflu/blob/main/PRIVACY.md"
# Tres enteros (año.mesdía.horaminuto) en UTC, para que el cambio de hora no lo haga retroceder, y sin
# ceros a la izquierda (10#): App Store Connect exige que crezca en cada subida.
BUILD_NUMBER="${BUILD_NUMBER:-$(date -u +%Y).$((10#$(date -u +%m%d))).$((10#$(date -u +%H%M)))}"
case "${1:-}" in
    "") UPLOAD=1 ;;
    --no-upload) UPLOAD=0 ;;
    *) echo "Uso: $0 [--no-upload]" >&2; exit 2 ;;
esac

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$PROJECT_DIR/build/appstore-$BUILD_NUMBER"
ARCHIVE="$BUILD_DIR/FluFlu.xcarchive"
EXPORT_DIR="$BUILD_DIR/export"
LOG="$BUILD_DIR/release.log"
mkdir -p "$BUILD_DIR"
exec > >(tee -a "$LOG") 2>&1

step() { printf '\n==> %s\n' "$*"; }
fail() { printf '\nERROR: %s\nRegistro completo: %s\n' "$*" "$LOG" >&2; exit 1; }
trap 'fail "falló el paso en la línea $LINENO"' ERR

# Identidad completa por la misma razón que en release.sh: dos certificados vigentes la vuelven ambigua.
# Deja el resultado en IDENTITY en vez de imprimirlo: dentro de $(...) un fallo salía repetido.
identity() {
    local prefix="$1" identities matches
    identities="$(security find-identity -v)"
    matches="$(awk -F'"' -v prefix="$prefix" -v team="($TEAM_ID)" 'index($2, prefix) == 1 && index($2, team) { print $2 }' <<<"$identities")"
    [[ -n "$matches" ]] || fail "no hay certificado «$prefix ($TEAM_ID)» en el llavero"
    [[ "$(wc -l <<<"$matches" | tr -d ' ')" == "1" ]] || fail "hay varios certificados «$prefix» del equipo"
    IDENTITY="$matches"
}

step "Comprobando certificados, perfil, clave de API y política de privacidad"
identity "Apple Distribution:"; APP_IDENTITY="$IDENTITY"
identity "3rd Party Mac Developer Installer:"; INSTALLER_IDENTITY="$IDENTITY"
echo "App: $APP_IDENTITY"
echo "Instalador: $INSTALLER_IDENTITY"
PROFILES_DIR="$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles"
PROFILE_FOUND=0
for profile in "$PROFILES_DIR"/*.provisionprofile; do
    [[ -e "$profile" ]] || continue
    name="$(security cms -D -i "$profile" 2>/dev/null | plutil -extract Name raw - 2>/dev/null)" || name=""
    if [[ "$name" == "$PROFILE_NAME" ]]; then PROFILE_FOUND=1; fi
done
(( PROFILE_FOUND )) || fail "no está instalado el perfil «$PROFILE_NAME» en $PROFILES_DIR"
if (( UPLOAD )); then
    [[ -n "$ASC_KEY_ID" && -n "$ASC_ISSUER_ID" ]] || fail "define ASC_KEY_ID y ASC_ISSUER_ID (entorno o scripts/asc.env)"
    # La guideline 5.1.1(i) exige una política de privacidad accesible: sin ella, Apple rechaza el envío.
    curl -fsI "$PRIVACY_URL" >/dev/null || fail "la política de privacidad no responde: $PRIVACY_URL"
    [[ -f "$HOME/.appstoreconnect/private_keys/AuthKey_$ASC_KEY_ID.p8" ]] || fail "falta la clave AuthKey_$ASC_KEY_ID.p8"
fi

if [[ "${SKIP_TESTS:-0}" != "1" ]]; then
    step "Tests unitarios de la variante de la tienda"
    xcodebuild test -project "$PROJECT_DIR/FluFlu.xcodeproj" -scheme "$SCHEME" \
        -destination 'platform=macOS,arch=arm64' -only-testing:FluFluTests \
        -xcconfig "$PROJECT_DIR/AppStore.xcconfig" -derivedDataPath "$BUILD_DIR/dd-tests" -quiet
fi

step "Archive (build $BUILD_NUMBER)"
xcodebuild archive -project "$PROJECT_DIR/FluFlu.xcodeproj" -scheme "$SCHEME" -configuration Release \
    -destination 'generic/platform=macOS' -archivePath "$ARCHIVE" -xcconfig "$PROJECT_DIR/AppStore.xcconfig" \
    CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
    CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM="$TEAM_ID" CODE_SIGN_IDENTITY="$APP_IDENTITY" \
    PROVISIONING_PROFILE_SPECIFIER="$PROFILE_NAME" -quiet

step "Export (.pkg para App Store Connect)"
cat > "$BUILD_DIR/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key><string>app-store-connect</string>
    <key>destination</key><string>export</string>
    <key>teamID</key><string>$TEAM_ID</string>
    <key>signingStyle</key><string>manual</string>
    <key>signingCertificate</key><string>$APP_IDENTITY</string>
    <key>installerSigningCertificate</key><string>$INSTALLER_IDENTITY</string>
    <key>provisioningProfiles</key>
    <dict><key>$BUNDLE_ID</key><string>$PROFILE_NAME</string></dict>
</dict>
</plist>
PLIST
xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportPath "$EXPORT_DIR" \
    -exportOptionsPlist "$BUILD_DIR/ExportOptions.plist" -quiet
PKG="$(ls "$EXPORT_DIR"/*.pkg)"

step "Comprobando el contenido del .pkg"
# Se revisa la app que va dentro del .pkg exportado, que es la que se sube, no la del archive.
PKG_DIR="$BUILD_DIR/pkg-expanded"
rm -rf "$PKG_DIR"
pkgutil --expand-full "$PKG" "$PKG_DIR" >/dev/null
APP="$(find "$PKG_DIR" -maxdepth 4 -name FluFlu.app -type d)"
[[ -n "$APP" ]] || fail "el .pkg no contiene FluFlu.app"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist")" == "$BUNDLE_ID" ]] \
    || fail "el bundle ID no es $BUNDLE_ID"
ENTITLEMENTS="$(codesign -d --entitlements - "$APP" 2>/dev/null)"
for required in com.apple.security.app-sandbox com.apple.security.network.client com.apple.security.device.audio-input; do
    [[ "$ENTITLEMENTS" == *"$required"* ]] || fail "falta el entitlement $required"
done
[[ "$ENTITLEMENTS" != *"get-task-allow"* ]] || fail "la app conserva get-task-allow"
# La variante de la tienda no puede contener Accesibilidad (prohibida en sandbox; motivo de rechazo 2.4.5).
SYMBOLS="$(nm -u "$APP/Contents/MacOS/FluFlu")"
[[ "$SYMBOLS" != *"AXIsProcessTrusted"* ]] || fail "el binario usa AXIsProcessTrusted"
pkgutil --check-signature "$PKG"

if (( UPLOAD )); then
    step "Validando con App Store Connect"
    xcrun altool --validate-app -f "$PKG" -t macos --apiKey "$ASC_KEY_ID" --apiIssuer "$ASC_ISSUER_ID"
    step "Subiendo a App Store Connect"
    xcrun altool --upload-app -f "$PKG" -t macos --apiKey "$ASC_KEY_ID" --apiIssuer "$ASC_ISSUER_ID"
fi

step "Listo"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
echo "FluFlu $VERSION (build $BUILD_NUMBER) para la Mac App Store$( (( UPLOAD )) || echo ', sin subir')"
echo "$PKG"
