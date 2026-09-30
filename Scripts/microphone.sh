#!/usr/bin/env bash
#
# Estado del permiso de micrófono de Ámbar, y cómo pedirlo.
#
# POR QUÉ EXISTE
#
# «La app no aparece en Ajustes del Sistema → Micrófono» no se arregla desde Ajustes del
# Sistema: macOS solo enumera ahí las apps que **han solicitado** el permiso, y no hay botón
# para añadir una a mano. La única forma de que Ámbar aparezca es que Ámbar lo pida.
#
# Y pedirlo tiene una trampa que ya costó dos diagnósticos equivocados en este repositorio:
# si la app se lanza ejecutando su binario desde un terminal, **TCC atribuye la solicitud al
# terminal**. Medido con el mismo bundle: `micrófono=granted` lanzado a mano (el permiso de
# zsh) y `notDetermined` lanzado con `open` (el de Ámbar, que nunca lo pidió). Por eso este
# guion usa `open` siempre.
#
# La otra razón de que esto sea un guion y no un comando pegado en una conversación: el arnés
# vive solo en las compilaciones de depuración (`#if DEBUG`), así que el comando fallaba en
# silencio —arrancando la app sin pedir nada— cuando `.build` contenía un bundle de release.
# Aquí se comprueba antes de lanzar nada.
#
# USO
#
#   ./Scripts/microphone.sh report     mide el estado, sin diálogos ni efectos
#   ./Scripts/microphone.sh request    pide el permiso: sale el diálogo del sistema
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/.build/Ambar.app"
MODE="${1:-report}"
REPORT="$(mktemp /tmp/ambar-microphone.XXXXXX)"

fail() { echo "✗ $1" >&2; exit 1; }

case "$MODE" in
  report|request) ;;
  *) fail "modo desconocido «$MODE» — usa: report | request" ;;
esac

# El bundle de depuración, siempre y sin preguntar: es el único que trae el arnés, y
# reconstruirlo cuesta segundos. Antes esto se daba por supuesto y era falso la mitad de las
# veces.
echo "▸ Montando el bundle de depuración"
"$ROOT/Scripts/make-app.sh" debug > /dev/null

# Comprobación, no confianza. Sin `grep -q` en la tubería: sale al primer acierto, `strings`
# recibe SIGPIPE y con `set -o pipefail` el resultado se lee como fallo justo cuando encuentra
# lo que busca — la trampa que este repositorio lleva cazando en cada guion.
HARNESS="$(strings "$APP/Contents/MacOS/Ambar" | grep -c "AMBAR_REQUEST_MIC" || true)"
[ "$HARNESS" -gt 0 ] || fail "el bundle no trae el arnés: ¿se compiló en release?"

VARIABLE="AMBAR_PERMISSIONS=1"
if [ "$MODE" = "request" ]; then
  VARIABLE="AMBAR_REQUEST_MIC=1"
  echo "▸ Pidiendo el permiso — va a aparecer el diálogo del sistema"
else
  echo "▸ Midiendo el estado (sin diálogos)"
fi

# `open` y no el binario: es la diferencia entre registrar Ámbar y registrar tu terminal.
# `-n` fuerza una instancia nueva aunque la app ya esté abierta.
open --env "$VARIABLE" --env "AMBAR_REPORT_TO=$REPORT" --env "AMBAR_SUPPRESS_PROMPTS=1" \
  -n "$APP" || fail "no se pudo lanzar la app con open"

# El informe lo escribe la app al terminar. Con techo: si no llega, algo impidió que el modo
# corriera y hay que decirlo en lugar de imprimir un fichero vacío.
#
# Dos techos, porque son dos esperas distintas: medir tarda lo que tarde el catálogo de voz,
# pero **pedir el permiso espera a una persona** que tiene que leer un diálogo y decidir. Con
# los 20 s de la medida, el guion abandonaba mientras el usuario aún miraba la pantalla y
# declaraba que el modo no había corrido, que es mentira y además la más confusa posible.
LIMITE=40
[ "$MODE" = "request" ] && LIMITE=240
for _ in $(seq 1 "$LIMITE"); do
  [ -s "$REPORT" ] && break
  sleep 0.5
done

if [ ! -s "$REPORT" ]; then
  rm -f "$REPORT"
  fail "la app no dejó informe: el modo no llegó a ejecutarse"
fi

echo
cat "$REPORT"
echo

ESTADO="$(grep -E "^MICRÓFONO después=|^PERMISOS micrófono=" "$REPORT" | tail -1 | sed 's/.*=//')"
case "$ESTADO" in
  granted)
    echo "✓ Concedido. Ámbar ya aparece en Ajustes del Sistema → Privacidad y seguridad →"
    echo "  Micrófono, con su interruptor activado."
    ;;
  denied)
    echo "▸ Denegado, pero **ya aparece en la lista**: el interruptor está ahí, desactivado."
    echo "  Actívalo tú si quieres el dictado; macOS no vuelve a preguntar."
    ;;
  notDetermined)
    if [ "$MODE" = "report" ]; then
      echo "▸ Sin pedir. Por eso la app no está en la lista del sistema. Para pedirlo:"
      echo "    ./Scripts/microphone.sh request"
    else
      echo "✗ Sigue sin decidir: el diálogo no llegó a aparecer."
      echo "  Mira si el motivo del micrófono viaja en el bundle:"
      echo "    /usr/libexec/PlistBuddy -c 'Print :NSMicrophoneUsageDescription' \\"
      echo "      $APP/Contents/Info.plist"
    fi
    ;;
  *)
    echo "▸ Estado no reconocido: «$ESTADO»"
    ;;
esac

rm -f "$REPORT"

echo
echo '  Nota: .build/Ambar.app queda en DEPURACIÓN. Para volver a un bundle publicable:'
echo "    ./Scripts/make-app.sh release"
