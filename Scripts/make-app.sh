#!/bin/bash
#
# Monta Ambar.app a partir del ejecutable que produce SwiftPM.
#
# No hay .xcodeproj a propósito: un paquete SwiftPM se compila igual desde la
# terminal, desde Xcode y desde CI, sin un .pbxproj que resolver en cada merge.
# Lo único que SwiftPM no sabe hacer es el bundle .app, y eso es este script.
#
#   ./Scripts/make-app.sh [debug|release]
#
set -euo pipefail

CONFIGURATION="${1:-release}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$ROOT/.build/$CONFIGURATION"
APP="$ROOT/.build/Ambar.app"

echo "▸ Compilando ($CONFIGURATION)…"
cd "$ROOT"
swift build -c "$CONFIGURATION" --product Ambar

echo "▸ Montando el bundle…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BUILD_DIR/Ambar" "$APP/Contents/MacOS/Ambar"
cp "$ROOT/apps/Ambar/Info.plist" "$APP/Contents/Info.plist"

# Los bundles de recursos van a Contents/Resources, que es el único sitio válido:
# en la raíz del .app, `codesign` los rechaza con «unsealed contents present in the
# bundle root».
#
# Y por eso el código NO puede usar `Bundle.module` para leerlos. El accesor que
# genera SwiftPM prueba dos rutas —`Bundle.main.bundleURL/<T>_<T>.bundle`, o sea la
# raíz, y un `buildPath` ABSOLUTO al .build de la máquina que compiló— y si falla
# hace `fatalError`. Con los bundles aquí, la app arrancaba **solo en la máquina de
# compilación**: la salvaba el buildPath. En cualquier otra moría en
# `applicationDidFinishLaunching`, donde `buildMenu()` resuelve su primera cadena.
# El accesor propio está en `apps/Ambar/StringsBundle.swift y packages/AppCore/StringsBundle.swift`.
#
# Se copian TODOS, no uno enumerado a mano: `AppCore` tiene el suyo y sus cadenas
# viven en el grabador de atajos de Ajustes — la misma ventana desde la que se
# activa el dictado, que es decir que sin él el dictado no se puede encender.
for RESOURCE_BUNDLE in "$BUILD_DIR"/*.bundle; do
  [ -d "$RESOURCE_BUNDLE" ] || continue
  cp -R "$RESOURCE_BUNDLE" "$APP/Contents/Resources/"
done

# Los InfoPlist.strings tienen que ir al Contents/Resources del bundle PRINCIPAL,
# no dentro del bundle de recursos de SwiftPM. macOS solo mira ahí para traducir
# las descripciones de uso —la del micrófono, por ejemplo—, así que dejarlas donde
# las pone SwiftPM (Ambar_Ambar.bundle/<lang>.lproj) las vuelve decorativas: el
# diálogo del sistema saldría en el idioma base para todo el mundo.
#
# Se copian desde las fuentes y no desde el bundle procesado porque SwiftPM
# normaliza los nombres a minúsculas (pt-BR → pt-br.lproj) y la resolución del
# bundle principal espera la capitalización original.
#
# Con contador, y no por prolijidad: sin él, si el glob dejaba de casar —una carpeta
# renombrada, una ruta cambiada— este bucle copiaba CERO ficheros y salía con éxito. El
# bundle resultante enseñaba el diálogo del micrófono en el idioma de reserva a todo el
# mundo, y el preflight lo daba por bueno. Medido por una auditoría independiente.
COPIED=0
for SRC in "$ROOT/apps/Ambar/Resources"/*.lproj; do
  [ -f "$SRC/InfoPlist.strings" ] || continue
  LANG_DIR="$APP/Contents/Resources/$(basename "$SRC")"
  mkdir -p "$LANG_DIR"
  cp "$SRC/InfoPlist.strings" "$LANG_DIR/InfoPlist.strings"
  COPIED=$((COPIED + 1))
done
if [ "$COPIED" -lt 10 ]; then
  echo "✗ solo se copiaron $COPIED InfoPlist.strings de 10: los diálogos de permiso saldrían sin traducir" >&2
  exit 1
fi

if [ -f "$ROOT/apps/Ambar/Resources/AppIcon.icns" ]; then
  cp "$ROOT/apps/Ambar/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
  /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "$APP/Contents/Info.plist" 2>/dev/null || true
fi

# Firma ad-hoc para poder ejecutar en local.
#
# AVISO: macOS asocia el permiso de accesibilidad a la firma del binario. Con
# firma ad-hoc, cada recompilación produce una firma distinta y el sistema
# revoca el permiso — el pegado automático deja de funcionar sin decir por qué.
# Para iterar sin ese incordio, firma con un certificado estable:
#
#   CODESIGN_IDENTITY="Apple Development: tu@correo.com" ./Scripts/make-app.sh
#
# y si el permiso se queda pegado en un estado raro:
#
#   tccutil reset Accessibility dev.rrios.ambar
#
# Si existe un certificado local, se usa sin tener que decirlo cada vez. Es lo
# que hace que el permiso de accesibilidad sobreviva a las recompilaciones.
# Sin `-v`: el certificado de setup-signing.sh es autofirmado, así que la
# evaluación de política lo descarta (CSSMERR_TP_NOT_TRUSTED) y `-v` no lo
# lista. codesign sí lo acepta, que es lo que hace falta para que la firma —y
# con ella el permiso de accesibilidad— sobreviva a la recompilación.
#
# The Developer ID comes first. It is the identity releases are notarized with, and
# macOS keys the Accessibility and Microphone grants to the signature's designated
# requirement (team + bundle identifier): a local build signed with it keeps the same
# grants as the published app, so switching between the two never revokes them.
# Captured in a variable, not piped into `grep -q`, for the SIGPIPE reason below.
IDENTITIES="$(security find-identity -p codesigning 2>/dev/null || true)"
DEVELOPER_ID_FOUND="$(sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' <<<"$IDENTITIES" | head -1)"
LOCAL_IDENTITY="Ambar Local Signing"
if [ -z "${CODESIGN_IDENTITY:-}" ] && [ -n "$DEVELOPER_ID_FOUND" ]; then
  CODESIGN_IDENTITY="$DEVELOPER_ID_FOUND"
elif [ -z "${CODESIGN_IDENTITY:-}" ]; then
  case "$IDENTITIES" in
    *"$LOCAL_IDENTITY"*) CODESIGN_IDENTITY="$LOCAL_IDENTITY" ;;
  esac
fi

IDENTITY="${CODESIGN_IDENTITY:--}"
echo "▸ Firmando con identidad: $IDENTITY"

# --options runtime: Hardened Runtime. La notarización lo exige, y sin él el
#   envío a notarytool se rechaza. Ver docs/audit/ambar-2026-08-09.md (B1).
# --entitlements: una sola entrada, la de entrada de audio que el dictado necesita.
# El fichero explica por qué no hay ninguna más y por qué no hay App Sandbox.
# NO se usa --deep: Apple lo desaconseja explícitamente y no sustituye a firmar
#   cada componente. Hoy el bundle no tiene componentes anidados; el día que
#   los tenga (Sparkle, por ejemplo), habrá que firmarlos de dentro afuera.
SIGN_ARGS=(--force --options runtime --entitlements "$ROOT/apps/Ambar/Ambar.entitlements")

# --timestamp necesita un certificado real y conexión con el servidor de sellado
# de Apple; con firma ad-hoc falla. La notarización exige sello seguro, así que
# se añade en cuanto hay identidad de verdad.
if [ "$IDENTITY" != "-" ]; then
  SIGN_ARGS+=(--timestamp)
else
  SIGN_ARGS+=(--timestamp=none)
fi

codesign "${SIGN_ARGS[@]}" --sign "$IDENTITY" "$APP"

# Comprobación, no confianza: que el flag esté puesto de verdad en el binario.
#
# La salida se captura en una variable en lugar de encadenar un `grep -q`: con
# `set -o pipefail`, grep cierra el pipe en cuanto encuentra la cadena, codesign
# recibe SIGPIPE y el pipeline devuelve error aunque la comprobación haya ido
# bien. Es un falso negativo que se dispara siempre.
# Y se reintenta: un `codesign -d` inmediatamente después de firmar con --force
# puede leer la firma ANTERIOR cacheada y reportar `flags=0x20002(adhoc,
# linker-signed)` sobre un bundle que sí tiene runtime. Medido: 1 de cada 3
# ejecuciones daba ese falso negativo, con un mensaje que manda a buscar el
# problema en la firma, que estaba bien.
SIGN_INFO=""
for _ in 1 2 3 4 5; do
  SIGN_INFO="$(codesign -d --verbose=4 "$APP" 2>&1 || true)"
  case "$SIGN_INFO" in
    *runtime*) break ;;
  esac
  sleep 0.4
done

case "$SIGN_INFO" in
  *runtime*) ;;
  *)
    echo "✗ ERROR: el bundle quedó sin Hardened Runtime. No sería notarizable." >&2
    echo "$SIGN_INFO" >&2
    exit 1
    ;;
esac

if [ "$IDENTITY" = "-" ]; then
  echo
  echo "  AVISO: firma ad-hoc. El permiso de Accesibilidad se revocará en la"
  echo "  próxima compilación y el pegado automático dejará de funcionar."
  echo "  Para arreglarlo de una vez:  ./Scripts/setup-signing.sh"
  echo
fi

echo "✓ $APP"
