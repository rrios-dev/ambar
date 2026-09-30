#!/bin/bash
#
# Empaqueta Ámbar en una imagen de disco con arrastre a Aplicaciones.
#
# POR QUÉ EXISTE
#
# La cadena de publicación producía un `.app` firmado y notarizado, y ahí se detenía: el
# empaquetado vivía como cuatro líneas de prosa en `docs/ambar-lanzamiento.md` que nadie
# había ejecutado. Es el mismo defecto que `release.sh` vino a arreglar para la firma —un
# procedimiento que nadie ha corrido es una intención, no un procedimiento—, y quedaba justo
# el último tramo: lo que el usuario descarga y abre.
#
# QUÉ PRODUCE
#
#   .build/Ambar-<versión>.dmg   comprimido, con el .app y un alias a /Applications
#
# El DMG se notariza **aparte** del .app: son dos artefactos distintos y Gatekeeper los
# evalúa por separado. Ver `release.sh dmg`, que hace las dos cosas en orden.
#
# USO
#
#   ./Scripts/make-dmg.sh                  # imagen sin firmar (o con la identidad local)
#   CODESIGN_IDENTITY="Developer ID Application: …" ./Scripts/make-dmg.sh
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/.build/Ambar.app"
BUILD="$ROOT/.build"
VOLUME_NAME="Ámbar"

fail() { echo "✗ $1" >&2; exit 1; }
ok()   { echo "✓ $1"; }

# ---------------------------------------------------------------------------
# 1. Lo que se va a empaquetar tiene que ser publicable
# ---------------------------------------------------------------------------

test -d "$APP" || fail "no hay bundle en $APP — corre primero ./Scripts/make-app.sh release"

PLIST="$APP/Contents/Info.plist"
VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$PLIST" 2>/dev/null || true)"
test -n "$VERSION" || fail "el bundle no declara CFBundleShortVersionString"

# Hardened Runtime: si falta, el DMG llevaría dentro algo que la notarización rechaza, y eso
# se descubriría después de subirlo. La salida se captura en una variable en lugar de
# encadenar `grep -q`: con `set -o pipefail`, grep cierra el pipe al primer acierto, codesign
# recibe SIGPIPE y la comprobación da falso justo cuando encuentra lo que busca. Es la misma
# trampa documentada en `make-app.sh` y en `release.sh`, y esta es la cuarta vez que hay que
# tenerla en cuenta.
#
# Y se reintenta, porque un `codesign -d` inmediatamente después de firmar puede leer la
# firma anterior cacheada (medido: 1 de cada 3 ejecuciones).
SIGN_INFO=""
for _ in 1 2 3 4 5; do
  SIGN_INFO="$(codesign -d --verbose=4 "$APP" 2>&1 || true)"
  case "$SIGN_INFO" in
    *runtime*) break ;;
  esac
  sleep 0.4
done
case "$SIGN_INFO" in
  *runtime*) ok "el bundle lleva Hardened Runtime" ;;
  *) fail "el bundle no lleva Hardened Runtime: no sería notarizable dentro del DMG" ;;
esac

DMG="$BUILD/Ambar-$VERSION.dmg"
STAGE="$BUILD/dmg-stage"
TEMP_DMG="$BUILD/Ambar-$VERSION-rw.dmg"
MOUNT_POINT=""

# ---------------------------------------------------------------------------
# Limpieza: un montaje colgado bloquea el fichero y el siguiente intento falla con un
# «resource busy» que no dice nada de la causa.
# ---------------------------------------------------------------------------

detach_quietly() {
  local point="$1"
  [ -n "$point" ] || return 0
  [ -d "$point" ] || return 0
  for _ in 1 2 3 4 5; do
    if hdiutil detach "$point" -quiet 2>/dev/null; then return 0; fi
    sleep 1
  done
  hdiutil detach "$point" -force -quiet 2>/dev/null || true
}

cleanup() {
  detach_quietly "$MOUNT_POINT"
  rm -rf "$STAGE"
  rm -f "$TEMP_DMG"
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# 2. El contenido de la imagen
# ---------------------------------------------------------------------------

rm -rf "$STAGE"
mkdir -p "$STAGE/.background"

# `ditto` y no `cp -R`: conserva los atributos extendidos y la estructura del bundle, que es
# lo que mantiene la firma válida dentro de la imagen.
ditto "$APP" "$STAGE/Ambar.app"

# El alias a Aplicaciones es lo que convierte la imagen en un instalador: arrastrar de un
# icono al otro es el gesto que todo el mundo en macOS ya conoce.
ln -s /Applications "$STAGE/Applications"

swift "$ROOT/Scripts/make-dmg-background.swift" "$STAGE/.background/background.png" \
  || fail "no se pudo generar el fondo de la ventana"

ok "contenido preparado: Ambar.app $VERSION + alias a /Applications"

# ---------------------------------------------------------------------------
# 3. Imagen de lectura/escritura para poder darle forma a la ventana
# ---------------------------------------------------------------------------

rm -f "$TEMP_DMG"
# HFS+ y no APFS: una imagen APFS no se puede abrir en versiones anteriores de macOS, y el
# mensaje que ve quien lo intenta no explica por qué. El sistema de ficheros de la imagen no
# tiene nada que ver con el requisito de macOS 26 de la app.
hdiutil create -srcfolder "$STAGE" -volname "$VOLUME_NAME" -fs HFS+ \
  -format UDRW -ov -quiet "$TEMP_DMG" \
  || fail "hdiutil no pudo crear la imagen de trabajo"

MOUNT_POINT="/Volumes/$VOLUME_NAME"
# `-nobrowse` para que no aparezca en la barra lateral mientras se prepara.
hdiutil attach "$TEMP_DMG" -nobrowse -quiet || fail "no se pudo montar la imagen de trabajo"

# ---------------------------------------------------------------------------
# 4. La ventana — cosmética, y por tanto no bloqueante
# ---------------------------------------------------------------------------
#
# Posicionar iconos y poner el fondo solo se puede hacer pidiéndoselo al Finder por
# AppleScript, y eso exige permiso de Automatización: en un CI, o en una sesión sin ese
# permiso concedido, `osascript` falla con -1743. Ese fallo **no** invalida el DMG —seguirá
# teniendo la app y el alias, que es lo que hace falta para instalar—, así que se avisa y se
# sigue. Lo que no se hace es fingir que salió bien.
#
# Las coordenadas están calculadas contra el tamaño del fondo (620×400 en
# `make-dmg-background.swift`): si cambia uno, hay que cambiar el otro.

LAYOUT_APPLIED="no"
if osascript - "$VOLUME_NAME" <<'APPLESCRIPT' >/dev/null 2>&1
on run argv
  set volumeName to item 1 of argv
  tell application "Finder"
    tell disk volumeName
      open
      set current view of container window to icon view
      set toolbar visible of container window to false
      set statusbar visible of container window to false
      set the bounds of container window to {200, 160, 820, 560}
      set viewOptions to the icon view options of container window
      set arrangement of viewOptions to not arranged
      set icon size of viewOptions to 96
      set background picture of viewOptions to file ".background:background.png"
      set position of item "Ambar.app" of container window to {170, 170}
      set position of item "Applications" of container window to {450, 170}
      close
      open
      update without registering applications
      delay 1
    end tell
  end tell
end run
APPLESCRIPT
then
  LAYOUT_APPLIED="sí"
  ok "ventana compuesta: fondo, iconos a 96 px y barra de herramientas oculta"
else
  echo "  AVISO: no se pudo componer la ventana (el Finder necesita permiso de"
  echo "  Automatización, y en CI no lo hay). El DMG es válido igualmente: lleva"
  echo "  Ambar.app y el alias a /Applications, sin fondo ni posiciones."
fi

sync
detach_quietly "$MOUNT_POINT"
MOUNT_POINT=""

# ---------------------------------------------------------------------------
# 5. Comprimir
# ---------------------------------------------------------------------------

rm -f "$DMG"
hdiutil convert "$TEMP_DMG" -format UDZO -imagekey zlib-level=9 -ov -quiet -o "$DMG" \
  || fail "no se pudo comprimir la imagen"
rm -f "$TEMP_DMG"
ok "imagen comprimida: $(du -h "$DMG" | cut -f1)"

# ---------------------------------------------------------------------------
# 6. Firmar la imagen, si hay con qué
# ---------------------------------------------------------------------------
#
# El DMG se firma **además** del .app. Sin firma, Gatekeeper avisa al abrir la imagen aunque
# la app de dentro esté notarizada, y el usuario ve el aviso antes de llegar a la app.

IDENTITY="${CODESIGN_IDENTITY:-${DEVELOPER_ID:-}}"
if [ -n "$IDENTITY" ]; then
  # `--timestamp` porque la notarización exige sello seguro. Con identidad ad-hoc esto
  # fallaría, y por eso solo se firma cuando hay una identidad de verdad declarada.
  codesign --force --sign "$IDENTITY" --timestamp "$DMG" \
    || fail "no se pudo firmar el DMG con «$IDENTITY»"
  codesign --verify --strict "$DMG" || fail "la firma del DMG no verifica"
  ok "DMG firmado con «$IDENTITY»"
else
  echo "  AVISO: DMG sin firmar. Para publicarlo hace falta"
  echo "  CODESIGN_IDENTITY=\"Developer ID Application: …\" y notarizarlo después."
fi

# ---------------------------------------------------------------------------
# 7. Verificar el resultado montándolo, que es lo que hará el usuario
# ---------------------------------------------------------------------------
#
# Comprobar el fichero producido y no el proceso que lo produjo: un DMG que se crea sin
# errores puede llevar dentro un alias roto o un bundle al que le falta algo.

# El punto de montaje va en el directorio temporal del sistema y **no** dentro de `.build`:
# medido, montar en un punto que vive en otro volumen —el repositorio está en un disco
# externo— falla con un CRC esperado y un `attach` que no completa, y el mensaje no menciona
# nada de volúmenes. En `/tmp` monta a la primera.
VERIFY_POINT="$(mktemp -d "${TMPDIR:-/tmp}/ambar-dmg-verify.XXXXXX")"
hdiutil attach "$DMG" -nobrowse -readonly -quiet -mountpoint "$VERIFY_POINT" \
  || fail "el DMG producido no se puede montar"
MOUNT_POINT="$VERIFY_POINT"

test -d "$VERIFY_POINT/Ambar.app" || fail "el DMG no contiene Ambar.app"
test -L "$VERIFY_POINT/Applications" || fail "el DMG no contiene el alias a Aplicaciones"
LINK_TARGET="$(readlink "$VERIFY_POINT/Applications")"
[ "$LINK_TARGET" = "/Applications" ] \
  || fail "el alias apunta a «$LINK_TARGET» en lugar de a /Applications"

# La firma del .app tiene que seguir válida **dentro** de la imagen: si el empaquetado
# hubiera tocado un byte del bundle, esto es lo único que lo detecta.
codesign --verify --strict "$VERIFY_POINT/Ambar.app" \
  || fail "la firma del bundle dentro del DMG no verifica"

test -f "$VERIFY_POINT/.background/background.png" || fail "el fondo no viajó dentro del DMG"

detach_quietly "$VERIFY_POINT"
MOUNT_POINT=""
rmdir "$VERIFY_POINT" 2>/dev/null || true

ok "verificado montándolo: app, alias, firma y fondo"
echo
echo "▸ $DMG"
echo "  ventana compuesta: $LAYOUT_APPLIED"
echo
echo "  Siguiente paso para publicar:"
echo "    xcrun notarytool submit \"$DMG\" --keychain-profile \"${NOTARY_PROFILE:-<perfil>}\" --wait"
echo "    xcrun stapler staple \"$DMG\""
