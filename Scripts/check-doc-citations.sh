#!/usr/bin/env bash
#
# Que las citas al código en la documentación apunten a algo que existe.
#
# La auditoría de cierre encontró que 4 de 6 citas `fichero:línea` del documento de
# dictado apuntaban a código que no era el que decían: una señalaba una llave de cierre,
# otra un `pasteboard.writeObjects`, y otra un fichero que ya ni estaba en esa ruta
# (`ContentView.swift` se había movido a `Views/`). Nadie se enteró porque un número de
# línea se pudre con cada edición del fichero citado, en silencio y sin dejar rastro.
#
# El arreglo de fondo fue citar **símbolos** en vez de líneas. Este guion comprueba que
# esos símbolos sigan existiendo.
#
# La regla, deliberadamente conservadora: para cada cita con forma `Tipo.miembro`, si
# existe un fichero `Tipo.swift` en el árbol, ese fichero tiene que contener `miembro`.
# Cuando no hay fichero propio —`NSEvent.modifierFlags`, `DictationTranscriber.Preset` y
# demás API del sistema— la cita se salta: no se puede verificar contra este repositorio y
# fingir que sí sería justo el «verde engañoso» que este guion existe para evitar.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# In the monorepo the documents live next to `native/`; in the public repository, inside it.
if [ -d "$ROOT/docs" ]; then DOCS="$ROOT/docs"; else DOCS="$ROOT/../docs"; fi

checked=0
skipped=0
failures=0

while IFS= read -r doc; do
  # Citas entre acentos graves con forma Tipo.miembro.
  while IFS= read -r citation; do
    type="${citation%%.*}"
    member="${citation#*.}"

    # Primero por nombre de fichero, que es lo habitual.
    source_file="$(find "$ROOT/apps" "$ROOT/packages" -name "$type.swift" -not -path "*/.build/*" 2>/dev/null | head -1)"
    # Y si no, por la DECLARACIÓN del tipo, esté donde esté. La heurística anterior era
    # solo la primera mitad, así que un tipo que comparte fichero con otro caía en el saco
    # de «API del sistema» y no se verificaba nunca: `StickyKeys` vive en `HoldGesture.swift`,
    # y `StickyKeys.isEnabled` se saltaba pese a ser código de la casa. Lo midió una
    # auditoría independiente enumerando las 30 citas.
    if [ -z "$source_file" ]; then
      # `|| true`: sin coincidencias `grep` sale con 1 y, con `set -o pipefail`, mataba el
      # guion entero sin imprimir nada. Es la segunda vez que esta trampa muerde en este
      # repositorio; la primera fue `strings … | grep -q` en el gate de accesibilidad.
      source_file="$(
        grep -rlE "(enum|struct|class|actor|protocol|extension) $type[ :{]" \
          "$ROOT/apps" "$ROOT/packages" --include='*.swift' 2>/dev/null | head -1 || true
      )"
    fi
    if [ -z "$source_file" ]; then
      skipped=$((skipped + 1))
      continue
    fi

    checked=$((checked + 1))
    # Palabra completa, no subcadena. Con `grep -q "$member"` bastaba que el nombre nuevo
    # CONTUVIERA al viejo: renombrar `canPaste` → `canPasteRenamed` dejaba el guion diciendo
    # «rotas: 0». Lo midió una auditoría independiente. Los identificadores de Swift llevan
    # letras, dígitos y `_`, así que se exige que no haya ninguno de esos pegado a los lados.
    if ! grep -qE "(^|[^A-Za-z0-9_])$member([^A-Za-z0-9_]|\$)" "$source_file"; then
      echo "✗ $(basename "$doc"): «${citation}» — $type.swift no contiene «${member}»"
      failures=$((failures + 1))
    fi
  # También la forma con firma —`Store.pendingOCRItems()`,
  # `DictationTranscriber.supportedLocale(equivalentTo:)`—, que es igual de verificable y
  # quedaba fuera: se comprueba el nombre del método, sin la lista de argumentos. Eran
  # cinco citas de código propio que el guion decía saltar por «API del sistema».
  done < <(
    grep -oE '`[A-Z][A-Za-z0-9]*\.[a-z][A-Za-z0-9]*(\([^`]*\))?`' "$doc" \
      | tr -d '`' | sed 's/(.*//' | sort -u
  )
# Solo la documentación VIVA (`docs/ambar*.md`), no los informes de `docs/audit/`.
#
# No es un descuido, y se comprobó antes de decidirlo: al ampliar el alcance a los informes
# saltaron dos citas —`SpeechSession.feedPolicy` y `Database.scalar`—, y las dos son
# correctas. Los dos informes dicen literalmente que ese código era muerto y que se borró:
# citarlo es exactamente su trabajo. Un informe de auditoría es una foto fechada, y exigirle
# que apunte al código de hoy lo obligaría a mentir sobre el de entonces.
#
# Lo que sí se arregló es el otro medio hallazgo: la comparación era por subcadena.
done < <(find "$DOCS" -maxdepth 1 -name "ambar*.md")

echo "Citas comprobadas: $checked · sin fichero propio (API del sistema): $skipped · rotas: $failures"

# Suelo. Sin esto el guion no podía fallar por el motivo más probable: que dejara de
# encontrar sus documentos. Una auditoría independiente le cambió el glob a un nombre
# inexistente y salió «0 comprobadas · 0 rotas · exit 0» — un gate verde que no había
# mirado nada, y encima con su salida mandada a /dev/null desde `release.sh`. Era, además,
# el único guion del repositorio sin aserción de suelo.
if [ "$checked" -lt 5 ]; then
  echo "✗ solo se comprobaron $checked citas: el guion no encontró la documentación que debía revisar" >&2
  echo "  (buscaba en $DOCS)" >&2
  exit 1
fi

if [ "$failures" -gt 0 ]; then
  echo "Las citas rotas mandan al lector a código que no dice lo que la documentación afirma."
  exit 1
fi
