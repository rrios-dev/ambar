#!/bin/bash
#
# Cadena de publicación de Ámbar: preflight → firma Developer ID → notarización →
# grapado → verificación como la ve el usuario.
#
# POR QUÉ EXISTE
#
# Todo esto vivía solo en prosa (`docs/ambar-lanzamiento.md`). Una auditoría
# independiente lo señaló: la cadena estaba escrita y **nunca se había ejecutado**, así
# que no se sabía si era correcta ni en qué punto exacto fallaría. Un procedimiento que
# nadie ha corrido es una intención, no un procedimiento.
#
# Lo que este script cambia: la mitad que NO necesita credenciales —el preflight— se
# ejecuta hoy, en cada cambio si hace falta, y falla con un motivo concreto. La mitad que
# sí las necesita queda a un comando de distancia, con sus requisitos comprobados ANTES
# de empezar en vez de a mitad de una subida a los servidores de Apple.
#
# USO
#
#   ./Scripts/release.sh preflight     comprueba todo lo verificable sin cuenta de Apple
#   ./Scripts/release.sh full          preflight + firma + notariza + grapa + verifica
#   ./Scripts/release.sh dmg           empaqueta el instalador, lo notariza y lo grapa
#
# `dmg` va DESPUÉS de `full`, no dentro: el .app y la imagen son dos artefactos distintos y
# Gatekeeper los evalúa por separado, así que se notarizan en dos envíos. Encadenarlos
# escondería ese hecho y obligaría a repetir los dos cuando falla uno.
#
# Para `full` y `dmg` hacen falta, como variables de entorno:
#
#   DEVELOPER_ID   p.ej. "Developer ID Application: Nombre (TEAMID)"
#   NOTARY_PROFILE nombre del perfil guardado con `xcrun notarytool store-credentials`
#
# DEVELOPER_ID can be left out: the Developer ID Application identity in the login
# keychain is used, and the run stops if there is none or more than one.
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/.build/Ambar.app"
PLIST="$APP/Contents/Info.plist"
MODE="${1:-preflight}"

fail() { echo "✗ $1" >&2; exit 1; }
ok()   { echo "✓ $1"; }

# ---------------------------------------------------------------------------
# Preflight — todo lo que se puede comprobar sin cuenta de Apple.
# ---------------------------------------------------------------------------

preflight() {
  echo "▸ Preflight de publicación"

  test -d "$APP" || fail "no hay bundle en $APP — corre primero ./Scripts/make-app.sh release"

  # 1. El binario es el de release, no el de depuración. Un bundle de debug firmado y
  #    notarizado es un fallo que solo se descubre cuando alguien lo usa.
  local bin="$APP/Contents/MacOS/Ambar"
  test -f "$bin" || fail "falta el ejecutable en el bundle"
  # Sin `| grep -q`: sale al primer acierto, `strings` recibe SIGPIPE, y con el
  # `set -o pipefail` de arriba la tubería devuelve 141 — o sea, el `if` da FALSO
  # justamente cuando encuentra lo que busca. Este gate no podía fallar: bastaba colocar el
  # binario de depuración en el bundle para que dijera «✓ binario de release, sin variables
  # de revisión» y siguiera hasta firmar con Developer ID y notarizar.
  #
  # Es la TERCERA vez que esta trampa muerde aquí. Estaba documentada y arreglada en
  # `make-app.sh` y en `check-doc-citations.sh`, y faltaba en el sitio de más consecuencia:
  # entre esas variables está `AMBAR_DATA_DIR`, que redirige dónde vive el historial del
  # usuario. Documentar una trampa no la arregla en los sitios donde no se miró.
  local revision
  revision="$(strings "$bin" || true)"
  case "$revision" in
    *AMBAR_*)
      fail "el binario lleva variables de revisión (AMBAR_*): no es una compilación de release" ;;
  esac
  ok "binario de release, sin variables de revisión"

  # 2. Hardened Runtime. Sin él la notarización se rechaza, y se descubre tarde.
  local info
  info="$(codesign -d --verbose=2 "$APP" 2>&1 || true)"
  case "$info" in
    *runtime*) ok "Hardened Runtime activo" ;;
    *) fail "sin Hardened Runtime: Apple rechazaría la notarización" ;;
  esac

  # 3. La firma sella lo que hay dentro y satisface su propio requisito designado.
  codesign --verify --strict --deep-verify "$APP" 2>/dev/null \
    || codesign --verify --strict "$APP" 2>/dev/null \
    || fail "la firma no verifica"
  ok "firma válida y sellada"

  # 4. Entitlements: exactamente los declarados, y ninguno que afloje la ejecución.
  local ents
  ents="$(codesign -d --entitlements - --xml "$APP" 2>/dev/null | plutil -p - 2>/dev/null || true)"
  for peligroso in \
      "com.apple.security.cs.allow-jit" \
      "com.apple.security.cs.disable-library-validation" \
      "com.apple.security.cs.allow-unsigned-executable-memory" \
      "com.apple.security.cs.disable-executable-page-protection" \
      "com.apple.security.get-task-allow"; do
    if grep -q "$peligroso" <<<"$ents"; then
      fail "entitlement que afloja la ejecución: $peligroso"
    fi
  done
  grep -q "com.apple.security.device.audio-input" <<<"$ents" \
    || fail "falta el entitlement de entrada de audio: el dictado no funcionaría"
  ok "entitlements mínimos, sin excepciones peligrosas"

  # 5. Metadatos que Apple exige y que solo se notan cuando faltan.
  local id
  for clave in CFBundleIdentifier CFBundleShortVersionString CFBundleVersion \
               LSMinimumSystemVersion NSHumanReadableCopyright NSMicrophoneUsageDescription; do
    /usr/libexec/PlistBuddy -c "Print :$clave" "$PLIST" >/dev/null 2>&1 \
      || fail "falta $clave en Info.plist"
  done
  id="$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$PLIST")"
  [ "$id" = "dev.rrios.ambar" ] || fail "identificador inesperado: $id"
  ok "metadatos completos (versión, mínimo del sistema, copyright, motivo del micrófono)"

  # 6. Los recursos localizados viajan DENTRO del bundle. Es el fallo silencioso más
  #    fácil de cometer al empaquetar a mano: la app arranca y sale en inglés base.
  # LOS DOS bundles de recursos, no solo el de la app. `Ambar_AppCore.bundle` lleva las
  # cadenas del grabador de atajos —la ventana desde la que se activa el dictado— y nadie
  # las enumeraba: borrar un idioma entero de AppCore pasaba este ✓, que además decía «los
  # 10 idiomas viajan dentro del bundle».
  local faltan=0
  for bundle in Ambar_Ambar Ambar_AppCore; do
    for lang in es en fr de it pt-br ja zh-hans ko ru; do
      test -d "$APP/Contents/Resources/$bundle.bundle/$lang.lproj" || {
        echo "  falta $lang en $bundle.bundle" >&2
        faltan=$((faltan + 1))
      }
    done
  done
  [ "$faltan" -eq 0 ] || fail "$faltan idiomas no viajan en los bundles de recursos"
  ok "los 10 idiomas viajan en los dos bundles de recursos"

  # 6.bis. Y los textos de los diálogos del SISTEMA, que macOS NO lee de ahí.
  #
  # La comprobación de arriba mira `Ambar_Ambar.bundle`, que es donde SwiftPM pone las
  # cadenas de la interfaz. Las *usage descriptions* —el texto que aparece cuando el
  # sistema pide el micrófono— se leen de `Contents/Resources/<lang>.lproj/`, y aquí no
  # las miraba nadie. Una auditoría independiente rompió el bucle que las copia y este
  # preflight dio luz verde a un bundle donde ese diálogo salía en un solo idioma para
  # todo el planeta. El ✓ de arriba, además, decía «los 10 idiomas viajan dentro del
  # bundle»: cierto para la interfaz, engañoso para lo que faltaba.
  local sin_permisos=0
  for lang in es en fr de it pt-BR ja zh-Hans ko ru; do
    test -f "$APP/Contents/Resources/$lang.lproj/InfoPlist.strings" || sin_permisos=$((sin_permisos + 1))
  done
  [ "$sin_permisos" -eq 0 ] \
    || fail "$sin_permisos idiomas sin InfoPlist.strings: el diálogo del micrófono saldría sin traducir"
  ok "los 10 diálogos de permiso del sistema viajan traducidos"

  # 7. El icono. Sin él macOS pinta un genérico y la app parece rota antes de abrirse.
  test -f "$APP/Contents/Resources/AppIcon.icns" || fail "falta AppIcon.icns"
  ok "icono presente"

  # 8. Idioma de reserva. Decide qué ve quien no habla ninguno de los diez traducidos,
  #    que es la mayor parte del planeta. Estuvo en `es` y nadie lo miraba.
  local region
  region="$(plutil -extract CFBundleDevelopmentRegion raw "$APP/Contents/Info.plist" 2>/dev/null || echo "")"
  [ "$region" = "en" ] || fail "idioma de reserva «${region}»: quien no hable los diez traducidos vería eso"
  ok "idioma de reserva en inglés"

  # 9. Las citas al código en la documentación apuntan a algo que existe. La auditoría
  #    de cierre encontró 4 de 6 apuntando a código que no era el que decían — una a un
  #    fichero que ya ni estaba en esa ruta. Documentación que miente con confianza es
  #    peor que no tenerla: manda al siguiente lector a leer otra cosa creyendo que la
  #    ha comprobado.
  # Sin `>/dev/null`: mandar su salida a la nada dejaba invisible el recuento, que es
  # justo el dato que delata a un guion que no ha mirado nada.
  bash "$(dirname "${BASH_SOURCE[0]}")/check-doc-citations.sh" \
    || fail "hay citas al código rotas en la documentación (ver check-doc-citations.sh)"
  ok "las citas de la documentación resuelven"

  echo "✓ Preflight superado: el bundle está listo para firmar con Developer ID"
}

# ---------------------------------------------------------------------------
# Cadena con credenciales.
# ---------------------------------------------------------------------------

require_credentials() {
  if [ -z "${DEVELOPER_ID:-}" ]; then
    local found count
    found="$(security find-identity -p codesigning -v 2>/dev/null \
      | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | sort -u || true)"
    count="$(grep -c . <<<"$found" || true)"
    [ "$count" = "1" ] && DEVELOPER_ID="$found"
    [ "$count" -gt 1 ] 2>/dev/null \
      && fail "several Developer ID identities in the keychain: set DEVELOPER_ID to one of them"
  fi

  # Se comprueban ANTES de tocar nada. Descubrir que falta el perfil a mitad de una
  # subida deja el bundle firmado a medias y obliga a empezar de cero.
  [ -n "${DEVELOPER_ID:-}" ] \
    || fail "falta DEVELOPER_ID (p.ej. \"Developer ID Application: Nombre (TEAMID)\")"
  [ -n "${NOTARY_PROFILE:-}" ] \
    || fail "falta NOTARY_PROFILE — créalo con: xcrun notarytool store-credentials"

  # Misma trampa que en el paso 1, y aquí el falso resultado va en la otra dirección:
  # SIGPIPE haría fallar la tubería justo al encontrar la identidad, y el guion abortaría
  # una publicación legítima diciendo que no está en el llavero.
  local identidades
  identidades="$(security find-identity -p codesigning -v 2>/dev/null || true)"
  case "$identidades" in
    *"$DEVELOPER_ID"*) : ;;
    *) fail "la identidad «${DEVELOPER_ID}» no está en el llavero" ;;
  esac
  ok "credenciales presentes"
}

full_release() {
  preflight
  require_credentials

  echo "▸ Firmando con Developer ID"
  # `--options runtime` otra vez: la firma anterior era la local y se sustituye entera.
  # Sin `--deep`, que Apple desaconseja explícitamente: los bundles internos se firman
  # antes, de dentro hacia fuera.
  codesign --force --options runtime --timestamp \
    --entitlements "$ROOT/apps/Ambar/Ambar.entitlements" \
    --sign "$DEVELOPER_ID" "$APP"
  codesign --verify --strict "$APP" || fail "la firma con Developer ID no verifica"
  ok "firmado y sellado con marca de tiempo"

  echo "▸ Empaquetando para notarizar"
  local zip="$ROOT/.build/Ambar.zip"
  rm -f "$zip"
  # `ditto -c -k --keepParent` es el único empaquetado que Apple acepta: conserva los
  # atributos extendidos y la estructura del bundle.
  ditto -c -k --keepParent "$APP" "$zip"

  echo "▸ Notarizando (esto tarda; se espera al veredicto)"
  xcrun notarytool submit "$zip" --keychain-profile "$NOTARY_PROFILE" --wait \
    || fail "la notarización falló — pide el log con: xcrun notarytool log <id> --keychain-profile $NOTARY_PROFILE"
  ok "notarizado"

  echo "▸ Grapando el ticket"
  # Sin grapar, la app exige red la primera vez que se abre.
  xcrun stapler staple "$APP" || fail "no se pudo grapar el ticket"
  xcrun stapler validate "$APP" || fail "el ticket grapado no valida"
  ok "ticket grapado y validado"

  echo "▸ Verificando como lo verá el usuario"
  # `spctl` es lo que Gatekeeper ejecuta de verdad al abrirla por primera vez.
  spctl --assess --type execute --verbose=4 "$APP" \
    || fail "Gatekeeper rechazaría la app"
  ok "Gatekeeper la acepta"

  rm -f "$zip"
  echo "✓ Publicación lista: $APP"
}

# ---------------------------------------------------------------------------
# Instalador — el DMG que descarga el usuario, notarizado aparte del .app.
# ---------------------------------------------------------------------------
#
# Va después de `full`, no dentro: el `.app` y la imagen son **dos artefactos** y Gatekeeper
# los evalúa por separado, así que también se notarizan por separado. Encadenarlos en un solo
# comando escondería que son dos envíos y haría más difícil repetir solo el que falle.

dmg_release() {
  echo "▸ Instalador (DMG)"
  require_credentials

  # El empaquetado y su verificación viven en `make-dmg.sh`, que además firma la imagen si se
  # le da la identidad. Aquí solo se le pasa y se notariza el resultado.
  CODESIGN_IDENTITY="$DEVELOPER_ID" "$ROOT/Scripts/make-dmg.sh" \
    || fail "el empaquetado del DMG falló"

  local version
  version="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$PLIST")"
  local dmg="$ROOT/.build/Ambar-$version.dmg"
  test -f "$dmg" || fail "no se encontró el DMG en $dmg"

  echo "▸ Notarizando el DMG (esto tarda; se espera al veredicto)"
  xcrun notarytool submit "$dmg" --keychain-profile "$NOTARY_PROFILE" --wait \
    || fail "la notarización del DMG falló — pide el log con: xcrun notarytool log <id> --keychain-profile $NOTARY_PROFILE"
  ok "DMG notarizado"

  echo "▸ Grapando el ticket al DMG"
  # Sin grapar, quien abra la imagen sin conexión ve el aviso de desarrollador no
  # identificado aunque la app de dentro esté notarizada.
  xcrun stapler staple "$dmg" || fail "no se pudo grapar el ticket al DMG"
  xcrun stapler validate "$dmg" || fail "el ticket grapado en el DMG no valida"
  ok "ticket grapado y validado"

  # `spctl` sobre la imagen es lo que evalúa Gatekeeper al abrirla, y es un tipo de
  # evaluación distinto del de la app: `open` en lugar de `execute`.
  spctl --assess --type open --context context:primary-signature --verbose=4 "$dmg" \
    || fail "Gatekeeper rechazaría el DMG"
  ok "Gatekeeper acepta el DMG"

  echo "✓ Instalador listo: $dmg"
}

case "$MODE" in
  preflight) preflight ;;
  dmg)       dmg_release ;;
  full)      full_release ;;
  *)         fail "modo desconocido «${MODE}» — usa: preflight | full | dmg" ;;
esac
