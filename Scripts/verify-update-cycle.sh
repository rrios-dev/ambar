#!/usr/bin/env bash
#
# Verifica el ciclo de actualización completo de F6.2: una instalación
# antigua consulta el appcast, detecta que hay versión nueva, la descarga,
# verifica su firma EdDSA, la instala y arranca.
#
# Prueba el MECANISMO, no la integración de Sparkle. La diferencia importa y
# se declara: Sparkle añade su propia UI, su comprobación de que la firma de
# código coincide entre versiones, y el relanzamiento. Eso exige un binario
# que Gatekeeper acepte —cuenta de Apple— y queda fuera. Lo que sí se
# demuestra aquí es que el appcast que Hydra genera se puede consumir, que
# la firma protege el artefacto, y que el reemplazo del bundle produce una
# app que arranca.
#
# Uso: bash Scripts/verify-update-cycle.sh <dir-trabajo> <url-appcast> [clave-publica-base64]
#
# La clave pública puede darse como tercer argumento o en `AMBAR_UPDATE_PUBKEY`. Es
# obligatoria: el paso 5 —verificar la firma EdDSA **antes** de tocar nada— es la razón de
# ser de este guion, y sin clave no se puede verificar nada.
#
# Hasta esta ronda la variable se usaba en el paso 5 y **no se asignaba en ningún sitio**:
# con `set -u`, el guion abortaba con «unbound variable» justo ahí, así que el único
# procedimiento que demuestra que las actualizaciones están protegidas no podía llegar a
# demostrarlo. Lo encontró una auditoría independiente.
set -euo pipefail

WORK="${1:?falta el directorio de trabajo}"
APPCAST="${2:?falta la URL del appcast}"
PUBKEY="${3:-${AMBAR_UPDATE_PUBKEY:-}}"

if [ -z "$PUBKEY" ]; then
  echo "✗ falta la clave pública de actualizaciones." >&2
  echo "  Pásala como tercer argumento o en AMBAR_UPDATE_PUBKEY (base64 de la clave" >&2
  echo "  EdDSA con la que Hydra firma los artefactos)." >&2
  echo "  Sin ella el paso 5 no puede verificar la firma, que es lo único que impide" >&2
  echo "  instalar un artefacto sustituido por el camino." >&2
  exit 2
fi

INSTALADA="$WORK/instalada/Ambar.app"
DESCARGA="$WORK/descarga"
mkdir -p "$DESCARGA"

version_de() {
  plutil -extract CFBundleShortVersionString raw "$1/Contents/Info.plist"
}
build_de() {
  plutil -extract CFBundleVersion raw "$1/Contents/Info.plist"
}

echo "═══ 1. La instalación actual ═══"
ANTES_V=$(version_de "$INSTALADA")
ANTES_B=$(build_de "$INSTALADA")
echo "instalada: $ANTES_V (build $ANTES_B)"

echo
echo "═══ 2. Consulta el appcast ═══"
XML=$(curl -fsS "$APPCAST")
# Los atributos del enclosure, extraídos del XML real que sirve Hydra.
URL=$(echo "$XML" | xmllint --xpath 'string(//enclosure/@url)' -)
NUEVO_B=$(echo "$XML" | xmllint --xpath 'string(//enclosure/@*[local-name()="version"])' -)
NUEVO_V=$(echo "$XML" | xmllint --xpath 'string(//enclosure/@*[local-name()="shortVersionString"])' -)
FIRMA=$(echo "$XML" | xmllint --xpath 'string(//enclosure/@*[local-name()="edSignature"])' -)
LARGO=$(echo "$XML" | xmllint --xpath 'string(//enclosure/@length)' -)
echo "anuncia:   $NUEVO_V (build $NUEVO_B) · $LARGO bytes"

echo
echo "═══ 3. Detecta si hay actualización ═══"
if [ "$NUEVO_B" -le "$ANTES_B" ]; then
  # Salir con 0 aquí dejaba el guion en verde **sin haber ejercitado nada**: los pasos 4-7
  # —descarga, verificación de firma, reemplazo y arranque— son la razón de ser de este
  # procedimiento, y un appcast desactualizado los saltaba entero con un ✓. Es el mismo
  # patrón de gate que no puede fallar que el resto del repositorio persigue.
  echo "✗ el appcast no ofrece nada más nuevo que lo instalado (build $ANTES_B)." >&2
  echo "  Sin actualización que aplicar no se puede verificar el ciclo: los pasos 4-7," >&2
  echo "  que son los que importan, no se ejecutarían." >&2
  exit 2
fi
echo "hay actualización: build $ANTES_B → $NUEVO_B ✓"

echo
echo "═══ 4. Descarga ═══"
ZIP="$DESCARGA/update.zip"
curl -fsS -o "$ZIP" "$URL"
BAJADO=$(stat -f%z "$ZIP")
echo "descargado: $BAJADO bytes"
[ "$BAJADO" = "$LARGO" ] && echo "tamaño coincide con el anunciado ✓" || {
  echo "✗ tamaño distinto del anunciado"; exit 1; }

echo
echo "═══ 5. Verifica la firma EdDSA ANTES de tocar nada ═══"
if ! swift "$(dirname "$0")/verify-signature.swift" "$ZIP" "$FIRMA" "$PUBKEY"; then
  echo "✗ firma inválida — actualización abortada"; exit 1
fi

echo
echo "═══ 6. Instala ═══"
ditto -x -k "$ZIP" "$DESCARGA/extraido"
NUEVA_APP="$DESCARGA/extraido/Ambar.app"
[ -d "$NUEVA_APP" ] || { echo "✗ el artefacto no contiene Ambar.app"; exit 1; }
# Reemplazo atómico: mover la vieja a un lado y poner la nueva en su sitio.
mv "$INSTALADA" "$DESCARGA/Ambar-anterior.app"
mv "$NUEVA_APP" "$INSTALADA"

DESPUES_V=$(version_de "$INSTALADA")
DESPUES_B=$(build_de "$INSTALADA")
echo "instalada ahora: $DESPUES_V (build $DESPUES_B)"

echo
echo "═══ 7. La versión instalada arranca ═══"
# Se lanza el ejecutable directamente y se guarda SU pid, en vez de `open` + `pgrep -x`.
#
# Con `pgrep -x Ambar` la comprobación la satisfacía **cualquier** Ámbar en marcha —la del
# usuario incluida—, así que el paso no podía fallar mientras hubiera una abierta. Y lo que
# venía después era peor que un falso verde: `pkill -x Ambar` mataba esa instancia ajena.
# Un guion de verificación no puede cerrarle la app a quien lo ejecuta.
YA_ABIERTAS="$(pgrep -x Ambar | tr '\n' ' ' || true)"
[ -n "$YA_ABIERTAS" ] && echo "  (hay Ámbar en marcha: $YA_ABIERTAS — no se tocan)"

"$INSTALADA/Contents/MacOS/Ambar" > /dev/null 2>&1 &
NUEVA_PID=$!
sleep 4
if kill -0 "$NUEVA_PID" 2>/dev/null; then
  echo "✓ arrancó (PID $NUEVA_PID)"
  kill "$NUEVA_PID" 2>/dev/null || true
else
  echo "✗ no arrancó"; exit 1
fi

echo
echo "═══ RESULTADO ═══"
echo "$ANTES_V (build $ANTES_B) → $DESPUES_V (build $DESPUES_B) · instalada y arrancada ✓"
