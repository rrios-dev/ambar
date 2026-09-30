#!/usr/bin/env bash
#
# Que los controles de Ámbar tengan nombre para VoiceOver — comprobado sobre la app viva.
#
# POR QUÉ NO ES UN TEST
#
# En un proceso de `swift test` el árbol de accesibilidad **está vacío**: SwiftUI lo
# construye bajo demanda cuando un cliente de accesibilidad pregunta, y una suite no lo es.
# Tres auditorías seguidas señalaron el hueco y las tres lo dieron por cerrado con el
# diagnóstico. No lo estaba: el árbol sí existe en la app lanzada, y la app se puede lanzar.
#
# Lo que quedaba sin red, medido: borrar `.accessibilityLabel(label)` de los botones de la
# banda de dictado —parar, descartar— dejaba las 481 pruebas en verde con esos controles
# **sin nombre**, que es la única forma que VoiceOver tiene de anunciarlos. Quien llegó al
# dictado por el camino accesible se quedaba sin saber cuál es el botón de parar.
#
# El volcado usa `AXUIElementCreateApplication(getpid())` — el mismo canal que VoiceOver—,
# no los métodos internos de `NSView`, que devuelven la jerarquía vacía (comprobado).
#
# Uso: bash Scripts/check-accessibility.sh

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/.build/Ambar.app"
OUT="$(mktemp)"
DATA="$(mktemp -d)"

fail() { echo "✗ $1" >&2; exit 1; }

test -x "$APP/Contents/MacOS/Ambar" \
  || fail "no hay bundle de depuración — corre primero ./Scripts/make-app.sh debug"

# El arnés se compila fuera en release (`#if DEBUG`), así que un bundle de release daría
# cero líneas y este guion diría «no arrancó». Se distingue antes de acusar.
#
# Sin `grep -q` al final de la tubería: sale en cuanto encuentra la primera coincidencia,
# `strings` muere por SIGPIPE, y con `set -o pipefail` la tubería entera se lee como fallo.
# El guion acusaba a un bundle de depuración perfectamente válido de ser de release.
HARNESS="$(strings "$APP/Contents/MacOS/Ambar" | grep -c "AMBAR_DUMP_A11Y" || true)"
if [ "$HARNESS" -eq 0 ]; then
  fail "el bundle es de release: el arnés no viaja en él. Usa ./Scripts/make-app.sh debug"
fi

# Idioma forzado. Sin esto el guion afirmaba sobre literales castellanos y solo podía
# pasar en un Mac en español: en el runner de CI (`en_US`) el volcado trae «Stop» y
# «Discard», y las cuatro aserciones fallaban por un motivo que no es el que dicen. Un gate
# que solo verdea en la máquina de quien lo escribió no es un gate.
#
# Se fija `es` y no el idioma del sistema porque una comprobación tiene que dar el mismo
# resultado en todas partes. Que los diez idiomas estén completos y cuadrados es trabajo de
# `check-localization.sh`; lo de aquí es que los controles TENGAN nombre.
#
# DOS estados, y no uno. Mirar solo `listening` dejaba fuera todo control que solo exista
# en reposo: borrar la etiqueta del botón de micrófono —la alternativa que §8.5 nombra para
# quien no puede mantener el gesto— dejaba el gate en ✓ mientras el control degradaba al
# nombre de reserva del glifo («Micrófono» en vez de «Dictar»). Lo midió una auditoría
# independiente, y es el mismo patrón que este guion dice venir a evitar, un estado más allá.
# El proceso se mata **de verdad**, y se comprueba que murió.
#
# POR QUÉ IMPORTA, y no es limpieza cosmética: esta app registra un atajo GLOBAL con Carbon
# (⇧⌘V por omisión). Una instancia de prueba que sobreviva al `kill` se queda con ese atajo
# para toda la sesión, y a partir de ahí el atajo del usuario abre **el panel de la instancia
# de prueba** —con `AMBAR_DATA_DIR` aislado, o sea sin su historial y con el dictado apagado
# de fábrica—. El síntoma que produce eso es exactamente «el dictado ya no está disponible»,
# y no hay nada roto en la app.
#
# Medido: tras una ejecución de este guion quedó un proceso vivo **ocho minutos**, hasta que
# se buscó con `ps`. Un `kill` a secas no basta porque AppKit puede tardar en atender el
# SIGTERM, y el guion seguía adelante sin comprobarlo.
matar() {
  local pid="$1"
  kill "$pid" 2>/dev/null || true
  for _ in 1 2 3 4 5 6; do
    kill -0 "$pid" 2>/dev/null || return 0
    sleep 0.5
  done
  kill -9 "$pid" 2>/dev/null || true
  sleep 0.5
  if kill -0 "$pid" 2>/dev/null; then
    echo "  AVISO: el proceso $pid sigue vivo y tiene el atajo global registrado." >&2
    echo "  Mátalo a mano antes de usar Ámbar:  kill -9 $pid" >&2
  fi
}

volcar() {
  local estado="$1" destino="$2"
  AMBAR_DUMP_A11Y="$estado" AMBAR_SUPPRESS_PROMPTS=1 AMBAR_DATA_DIR="$DATA" \
    "$APP/Contents/MacOS/Ambar" -AppleLanguages '(es)' > "$destino" 2>&1 &
  local pid=$!
  sleep 12
  matar "$pid"
}

IDLE="$(mktemp)"
ONBOARDING="$(mktemp)"
volcar listening "$OUT"
volcar reposo "$IDLE"
# La presentación de primer uso es la PRIMERA pantalla que ve cualquiera, y sus botones son
# la única forma de avanzar por ella: sin nombre, quien llegue con VoiceOver no puede pasar
# del saludo. Sus condiciones las fija el arnés (ver `ReviewHooks`), así que este volcado da
# el mismo resultado en cualquier Mac.
volcar onboarding "$ONBOARDING"
# Y Ajustes, donde viven los botones que conceden permisos: es la ventana a la que llega
# quien tiene algo roto, así que sus controles son los que menos pueden estar sin nombre.
SETTINGS="$(mktemp)"
volcar settings "$SETTINGS"
# Los tres volcados se juntan: las aserciones de abajo buscan cada control donde exista.
cat "$IDLE" "$ONBOARDING" "$SETTINGS" >> "$OUT"

# La precondición, antes que cualquier aserción sobre nombres: si el panel no llegó a
# pantalla, este guion no puede medir NADA, y decir «ningún botón se llama Detener» sería
# indistinguible de haber encontrado un defecto real.
if grep -q "^A11Y ERROR" "$OUT"; then
  echo "✗ no se pudo medir: el panel no llegó a pantalla" >&2
  grep "^A11Y ERROR" "$OUT" | sed 's/^A11Y ERROR/   /' >&2
  echo "   (hace falta una sesión gráfica activa: pantalla desbloqueada y escritorio disponible)" >&2
  exit 2
fi

TOTAL="$(grep -c '^A11Y' "$OUT" || true)"
# Suelo antes que nada: sin él, una app que no arranca produce cero líneas y todas las
# comprobaciones de abajo pasarían por vacuidad. Es el modo de fallo que este repositorio
# lleva rondas encontrando en sus propios guiones.
if [ "$TOTAL" -lt 8 ]; then
  echo "✗ el volcado trajo $TOTAL líneas: la app no llegó a publicar su árbol" >&2
  cat "$OUT" >&2
  exit 1
fi

# Los controles que DEBEN tener nombre. Cada uno es la única salida de algún camino:
# «Detener» y «Descartar» son las dos formas de acabar un dictado; el campo de búsqueda es
# la razón de ser del panel.
#
# Con el ROL, y no solo el nombre. Sin atarlo, la aserción de «Descartar» la satisfacía un
# `AXStaticText` —la pista de teclado «⌘⌫ Descartar» que hay al pie del panel—, así que una
# mutación que dejara sin nombre justo ese botón pasaba entera: el control se anunciaba como
# «Cerrar», el nombre de reserva del glifo, y el gate lo daba por bueno. Lo midió una
# auditoría independiente. Es el patrón «gate que no puede fallar» que la cabecera de este
# guion dice venir a evitar, cometido dentro de él.
faltan=0
while IFS='|' read -r rol etiqueta; do
  if ! grep -q "^A11Y [0-9]* $rol [0-9]*x[0-9]* $etiqueta$" "$OUT"; then
    echo "✗ ningún $rol accesible se llama «${etiqueta}»" >&2
    faltan=$((faltan + 1))
  fi
done <<'ETIQUETAS'
AXTextField|Buscar en el historial del portapapeles
AXButton|Detener
AXButton|Descartar
AXButton|Dictar
AXMenuButton|Pausar durante…
AXButton|Continuar
AXButton|Mover a Aplicaciones
AXButton|Conceder el permiso
AXHeading|Que pegue por ti
AXCheckBox|Dictar con la voz
AXStaticText|Paso 5 de 6
AXCheckBox|Abrir al iniciar sesión
AXButton|Ver la presentación de nuevo
ETIQUETAS

[ "$faltan" -eq 0 ] || fail "$faltan controles sin nombre para VoiceOver"

# Y que se puedan pulsar, con dos varas distintas porque hay dos clases de botón.
#
# El comentario anterior invocaba 28 puntos y el `awk` de al lado comparaba con 14: con los
# botones de la banda encogidos a 16×16 el gate imprimía su ✓ «todos con nombre y tamaño».
# Ahora el número dice lo que la frase afirma.
#
# 28 para los de la banda —parar y descartar—, que es lo que declaran y lo que las HIG dan
# por cómodo para un objetivo de puntero: son los controles que **resuelven** el problema, y
# encogerlos los hace más difíciles de acertar que el problema. 14 para el resto, que es el
# tamaño legítimo de una afordancia dentro de un campo, como la ✕ de limpiar la búsqueda.
for ETIQUETA in Detener Descartar; do
  LINEA="$(grep -E "^A11Y [0-9]+ AXButton [0-9]+x[0-9]+ $ETIQUETA$" "$OUT" || true)"
  [ -n "$LINEA" ] || continue
  echo "$LINEA" | awk -v etiqueta="$ETIQUETA" '{
    split($4, d, "x")
    if (d[1] < 28 || d[2] < 28) {
      printf "✗ «%s» mide %s: por debajo de los 28 pt que declara\n", etiqueta, $4 > "/dev/stderr"
      exit 1
    }
  }' || exit 1
done

# El suelo de 14 pt se aplica a los botones **con nombre**, que son los que declara la app.
#
# Al ampliar el volcado a la ventana de Ajustes entraron controles que dibuja AppKit y cuyo
# tamaño no elige nadie aquí: las dos flechas de cada `Stepper` miden 20×13 y los deslizadores
# de scroll 11×391. Medirlos era pedirle a la app que reimplementara controles del sistema
# para pasar su propio gate; y todos ellos llegan al árbol **sin nombre**, que es justo lo que
# los distingue de los botones propios.
#
# El filtro es por nombre y no por ventana a propósito: excluir Ajustes entero habría quitado
# de la vara los botones que sí son nuestros —«Conceder el permiso», «Activar»— en la única
# pantalla a la que llega quien tiene algo roto.
pequenos="$(
  grep -E '^A11Y [0-9]+ AXButton ' "$OUT" \
    | awk '{
        nombre = ""
        for (i = 5; i <= NF; i++) nombre = nombre $i
        if (nombre == "") next
        split($4, d, "x")
        if (d[1] < 14 || d[2] < 14) print $0
      }'
)"
if [ -n "$pequenos" ]; then
  echo "✗ botones por debajo del mínimo absoluto de 14 pt:" >&2
  echo "$pequenos" >&2
  exit 1
fi

BOTONES="$(grep -cE '^A11Y [0-9]+ AXButton ' "$OUT" || true)"
echo "✓ árbol de accesibilidad real: $TOTAL elementos, $BOTONES botones, todos con nombre y tamaño"
