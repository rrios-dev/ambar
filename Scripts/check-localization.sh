#!/bin/bash
#
# Comprueba que todos los idiomas tienen exactamente las mismas claves.
#
# El modo de fallo que esto ataca no da error de compilación ni se ve en la
# app en español: si a un idioma le falta una clave, ese texto sale en el
# idioma base y nadie se entera hasta que un usuario lo reporta. Al revés
# —una clave de más— es una traducción huérfana que nadie mantiene.
#
# También valida los .stringsdict, porque un plist mal formado se ignora en
# silencio y los plurales vuelven a la forma incorrecta sin avisar.
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATUS=0

# `String(localized:)` sin `bundle:` se resuelve contra Bundle.main, donde NO están
# las cadenas: SwiftPM las empaqueta en Ambar_Ambar.bundle. El síntoma es que la
# interfaz muestra el identificador de la clave en crudo, en todos los idiomas —y
# ni la paridad de claves ni los tests lo detectan, porque la clave existe.
check_bundle_argument() {
  # `grep` línea a línea NO sirve: la forma más usada en el árbol parte la llamada
  # en varias líneas, y una guarda que solo ve la de una línea deja pasar
  # exactamente el caso que más aparece. Y buscar `bundle:` como argumento
  # inmediato tampoco: muchas llamadas legítimas meten `defaultValue:` en medio.
  # Se escanea la llamada completa con paréntesis balanceados.
  local offenders
  offenders="$(
    python3 - "$ROOT" <<'PYEOF'
import re, sys, pathlib
root = pathlib.Path(sys.argv[1])
bad = []
scanned = 0
opening = re.compile(r'String\(\s*localized:\s*"([^"]+)"', re.S)
for area in ("apps", "packages"):
    for path in sorted((root / area).rglob("*.swift")):
        text = path.read_text(encoding="utf-8")
        for match in opening.finditer(text):
            # Avanzar desde el paréntesis de apertura hasta su pareja.
            start = text.index("(", match.start())
            depth, index = 0, start
            while index < len(text):
                if text[index] == "(":
                    depth += 1
                elif text[index] == ")":
                    depth -= 1
                    if depth == 0:
                        break
                index += 1
            call = text[start : index + 1]
            # Solo los argumentos del NIVEL SUPERIOR: buscar «bundle:» en todo el
            # texto de la llamada daba un falso negativo cuando la externa no lo
            # llevaba y una anidada sí. Reproducido por un auditor.
            depth_scan, top_level = 0, []
            for ch in call:
                if ch == "(":
                    depth_scan += 1
                    if depth_scan == 1:
                        continue
                elif ch == ")":
                    depth_scan -= 1
                if depth_scan == 1:
                    top_level.append(ch)
            scanned += 1
            if "bundle:" not in "".join(top_level):
                line = text[: match.start()].count("\n") + 1
                bad.append(f"{path}:{line}: {match.group(1)}")
print("\n".join(bad))
PYEOF
  )"
  # Suelo. Sin él, este control imprimía su ✓ habiendo inspeccionado CERO llamadas: si el
  # `rglob` dejara de casar —una carpeta movida, un `sys.argv` mal pasado— el resultado era
  # idéntico al de un árbol impecable. Lo midió una auditoría independiente.
  local scanned
  scanned="$(
    python3 - "$ROOT" <<'PYEOF'
import re, sys, pathlib
root = pathlib.Path(sys.argv[1])
opening = re.compile(r'String\(\s*localized:\s*"[^"]+"', re.S)
count = 0
for area in ("apps", "packages"):
    for path in sorted((root / area).rglob("*.swift")):
        count += len(opening.findall(path.read_text(encoding="utf-8")))
print(count)
PYEOF
  )"
  # Y que la clave EXISTA, no solo que lleve bundle. Sin esto, una errata pasaba el gate y
  # la app pintaba el identificador en crudo — en los diez idiomas a la vez, porque cuando
  # la clave no está no hay idioma que la tenga. El criterio vive en `unknown-keys.py`.
  local desconocidas
  desconocidas="$(
    python3 "$ROOT/Scripts/unknown-keys.py" "$ROOT" \
      "$ROOT/apps/Ambar/Resources/es.lproj/Localizable.strings" \
      "$ROOT/apps/Ambar/Resources/es.lproj/Localizable.stringsdict" \
      "$ROOT/packages/AppCore/Resources/es.lproj/Localizable.strings" || true
  )"
  if [ -n "$desconocidas" ]; then
    echo "✗ claves que no existen en el catálogo — la app pintaría el identificador en crudo:"
    echo "$desconocidas" | sed 's|^|    |'
    STATUS=1
  fi

  if [ "$scanned" -lt 50 ]; then
    echo "✗ solo se inspeccionaron $scanned llamadas a String(localized:): este control no ha mirado el árbol"
    STATUS=1
  elif [ -n "$offenders" ]; then
    echo "✗ String(localized:) sin 'bundle:' — saldría el identificador en crudo:"
    echo "$offenders" | sed 's|^|    |'
    STATUS=1
  else
    echo "✓ las $scanned cadenas se resuelven con un bundle explícito"
  fi
}

keys_of() {
  local dir="$1"
  {
    [ -f "$dir/Localizable.strings" ] && grep -oE '^"[^"]+"' "$dir/Localizable.strings" || true
    if [ -f "$dir/Localizable.stringsdict" ]; then
      plutil -convert json -o - "$dir/Localizable.stringsdict" \
        | python3 -c 'import json,sys; [print("\"%s\"" % k) for k in json.load(sys.stdin)]'
    fi
  } | sort
}

# Censo de idiomas: los que el bundle ANUNCIA tienen que ser exactamente los que hay.
#
# Todos los bucles de este guion son `for dir in "$resources"/*.lproj`, así que menos
# carpetas significa menos iteraciones, no un fallo. Medido por una auditoría independiente:
# `rm -rf ko.lproj`, borrar `ru.lproj` de AppCore, o dejar solo `es`+`en` — los tres salían
# con exit 0, mientras `Info.plist` seguía anunciando los diez y el usuario coreano se
# encontraba la app en inglés.
#
# El censo es `CFBundleLocalizations`, que es la promesa que la app le hace al sistema. Se
# exige igualdad de conjuntos en las dos direcciones: falta uno prometido, o sobra uno sin
# prometer.
check_language_census() {
  local resources="$1" name="$2"
  # El censo es siempre el `Info.plist` de la app: es la promesa que el bundle le hace al
  # sistema, y los paquetes tienen que cumplirla igual. Correrlo solo para la app dejaba
  # borrar un idioma entero de `AppCore` sin que nada se enterara — el usuario coreano veía
  # el grabador de atajos, la ventana desde la que se activa el dictado, en español.
  local plist="$ROOT/apps/Ambar/Info.plist"

  local anunciados presentes
  anunciados="$(
    /usr/libexec/PlistBuddy -c "Print :CFBundleLocalizations" "$plist" 2>/dev/null \
      | sed -n 's/^ *\([A-Za-z-]*\) *$/\1/p' | grep -v '^$' | sort
  )"
  presentes="$(
    for dir in "$resources"/*.lproj; do
      [ -d "$dir" ] && basename "$dir" .lproj
    done | sort
  )"

  local n
  n="$(printf '%s\n' "$anunciados" | grep -c . || true)"
  if [ "$n" -lt 2 ]; then
    echo "  ✗ $name: no se pudo leer CFBundleLocalizations — este control no ha comprobado nada"
    STATUS=1
    return
  fi

  if [ "$anunciados" != "$presentes" ]; then
    echo "  ✗ $name: los idiomas del bundle no son los que Info.plist anuncia"
    diff <(printf '%s\n' "$anunciados") <(printf '%s\n' "$presentes") \
      | sed -n 's/^< /      anunciado y ausente: /p; s/^> /      presente y no anunciado: /p'
    STATUS=1
    return
  fi
  echo "▸ $name — $n idiomas, los mismos que anuncia Info.plist"
}

# Sintaxis de los `.strings`. CoreFoundation descarta el fichero ENTERO ante un `;` que
# falte, así que un idioma desaparece en tiempo de ejecución sin que nada avise: la paridad
# de claves no lo ve porque lee el fichero con su propio parser, más tolerante.
check_strings_syntax() {
  local resources="$1" name="$2"
  local revisados=0
  for file in "$resources"/*.lproj/Localizable.strings; do
    [ -f "$file" ] || continue
    plutil -lint "$file" > /dev/null 2>&1 \
      || { echo "  ✗ $name/$(basename "$(dirname "$file")"): .strings mal formado — el sistema lo descartaría entero"; STATUS=1; }
    revisados=$((revisados + 1))
  done
  if [ "$revisados" -lt 2 ]; then
    echo "  ✗ $name: solo se revisaron $revisados ficheros .strings: este control no ha mirado nada"
    STATUS=1
    return
  fi
  echo "▸ $name — $revisados ficheros .strings con sintaxis válida"
}

check_bundle() {
  local resources="$1" name="$2" base="$3"
  local base_keys
  base_keys="$(keys_of "$resources/$base.lproj")"
  local count
  count="$(echo "$base_keys" | grep -c . || true)"
  echo "▸ $name — referencia $base con $count claves"

  for dir in "$resources"/*.lproj; do
    local lang
    lang="$(basename "$dir" .lproj)"

    if [ -f "$dir/Localizable.stringsdict" ]; then
      plutil -lint "$dir/Localizable.stringsdict" > /dev/null \
        || { echo "  ✗ $lang: stringsdict mal formado"; STATUS=1; continue; }
    fi

    if diff -q <(echo "$base_keys") <(keys_of "$dir") > /dev/null; then
      echo "  ✓ $lang"
    else
      echo "  ✗ $lang"
      diff <(echo "$base_keys") <(keys_of "$dir") \
        | sed -n 's/^< /      falta:  /p; s/^> /      sobra:  /p'
      STATUS=1
    fi
  done
}

# Valores VACÍOS y valores SIN TRADUCIR.
#
# Dos formas de tener las diez claves y aun así no tener la traducción, ambas invisibles
# para la paridad de claves —que es lo único que este guion miraba.
#
# 1. `"clave" = "";` — la clave está, resuelve, y la interfaz pinta un hueco. No hay
#    reserva: `String(localized:)` devuelve la cadena vacía tan tranquilo.
# 2. Un valor idéntico al del idioma de referencia, de los que deja copiar el fichero
#    para traducir y no terminar. El criterio vive en `Scripts/untranslated.py`, y las
#    coincidencias legítimas —cognados del portugués, «Color» en inglés— en
#    `Scripts/untranslated-allowed.txt`, revisadas una a una en vez de tapadas por un
#    umbral de longitud, que dejaba fuera 14 de las 32 claves del dictado sin que se viera.
check_values() {
  local resources="$1" name="$2" base="$3"

  for dir in "$resources"/*.lproj; do
    local lang file
    lang="$(basename "$dir" .lproj)"
    file="$dir/Localizable.strings"
    [ -f "$file" ] || continue

    local empties
    empties="$(grep -cE '^[[:space:]]*"[^"]+"[[:space:]]*=[[:space:]]*"";' "$file" || true)"
    if [ "$empties" -gt 0 ]; then
      echo "  ✗ $name/$lang: $empties valor(es) vacío(s) — la interfaz pintaría un hueco"
      grep -nE '^[[:space:]]*"[^"]+"[[:space:]]*=[[:space:]]*"";' "$file" | sed 's/^/      /'
      STATUS=1
    fi

    [ "$lang" = "$base" ] && continue

    local untranslated
    untranslated="$(python3 "$ROOT/Scripts/untranslated.py" "$resources/$base.lproj/Localizable.strings" "$file")"
    if [ -n "$untranslated" ]; then
      echo "  ✗ $name/$lang: idénticas a $base y fuera de untranslated-allowed.txt — ¿sin traducir?"
      echo "$untranslated" | sed 's/^/      /'
      STATUS=1
    fi
  done
  echo "▸ $name — valores comprobados (ni vacíos ni copiados de $base)"
}

# Paridad de ESPECIFICADORES de formato, clave a clave.
#
# Es el gotcha que §11 del diseño anota por su nombre y que este guion no comprobaba:
# medido, quitar el `%lld` de una cadena alemana salía en verde y `String(format:)`
# descarta el argumento **en silencio** — el usuario alemán leería «Historial en pausa ·
# min.» sin el número. La paridad de claves no lo ve, porque la clave sigue estando.
check_format_specifiers() {
  local resources="$1" name="$2" base="$3"
  python3 - "$resources" "$base" "$name" <<'PYEOF' || STATUS=1
import re, sys, pathlib

resources, base, name = sys.argv[1], sys.argv[2], sys.argv[3]
# %@ %lld %.1f %1$@ … lo que `String(format:)` consume.
SPEC = re.compile(r'%(?:\d+\$)?[-+ #0]*[\d.]*(?:ll|l|h|hh|z|q)?[@dioufFeEgGxXsc]')
# El `;` puede llevar detrás un comentario: `"clave" = "valor";  // por qué`. El patrón
# anterior exigía fin de línea justo después, así que esas claves quedaban INVISIBLES para
# esta comprobación aunque `plutil` parsee el fichero sin problema — y no es hipotético,
# `es.lproj/Localizable.strings` ya lleva una así. Una clave invisible aquí es una clave a la
# que se le puede cambiar el `%lld` por un `%@` sin que nada avise.
LINE = re.compile(r'^"([^"]+)"\s*=\s*"(.*)";\s*(?://.*|/\*.*)?$')

def specs(path):
    out = {}
    if not path.exists():
        return out
    for line in path.read_text(encoding="utf-8").splitlines():
        m = LINE.match(line.strip())
        if m:
            # El ORDEN cuenta cuando los especificadores no son posicionales.
            #
            # Ordenarlos —lo que hacía antes— dejaba pasar el fallo que de verdad duele:
            # «%@ copió %lld» traducido como «%lld … %@» hace que `String(format:)` lea un
            # puntero donde hay un entero. No es un texto raro: es un fallo de memoria, y el
            # conjunto ordenado de ambos es idéntico. Los posicionales (`%1$@`) existen
            # justamente para reordenar sin eso, así que ahí sí basta el conjunto.
            found = SPEC.findall(m.group(2))
            positional = bool(found) and all("$" in f for f in found)
            out[m.group(1)] = (sorted(found) if positional else found, positional)
    return out

def plural_specs(path):
    """Especificadores dentro de las formas plurales.

    `check_format_specifiers` solo leía `Localizable.strings`, así que cambiar un `%lld`
    por `%@` DENTRO de una forma plural —o reordenar `%1$@ · %2$#@count@`— pasaba. Es
    `String(format:)` leyendo un entero como puntero: el mismo fallo de memoria que el
    docstring de esta función dice existir para prevenir, en el fichero de al lado.
    """
    out = {}
    if not path.exists():
        return out
    text = path.read_text(encoding="utf-8")
    # El ORDEN solo es comparable entre idiomas en `NSStringLocalizedFormatKey`, que es la
    # plantilla externa. Dentro de las formas plurales no lo es: el chino tiene UNA
    # categoría y el español DOS, así que contar los `%lld` por forma descuadra por diseño
    # —lo comprobé al estrenar esto: `settings.retention.days` salía como fallo siendo
    # correcto—. De las formas se compara el CONJUNTO de especificadores distintos, que es
    # lo que de verdad tiene que coincidir: si el español mete un `%lld` donde el chino pone
    # un `%@`, eso sigue siendo `String(format:)` leyendo un entero como puntero.
    for match in re.finditer(r"<key>([^<]+)</key>\s*<dict>(.*?)</dict>", text, re.S):
        key, block = match.group(1), match.group(2)
        plantilla = re.search(r"<key>NSStringLocalizedFormatKey</key>\s*<string>([^<]*)</string>", block)
        externos = SPEC.findall(plantilla.group(1)) if plantilla else []
        variantes = sorted(set(SPEC.findall(" ".join(re.findall(r"<string>([^<]*)</string>", block)))))
        found = externos + [f for f in variantes if f not in externos]
        positional = bool(externos) and all("$" in f for f in externos)
        out[key] = (sorted(found) if positional else found, positional)
    return out


root = pathlib.Path(resources)
reference = specs(root / f"{base}.lproj" / "Localizable.strings")
reference.update(plural_specs(root / f"{base}.lproj" / "Localizable.stringsdict"))
failed = False
for lproj in sorted(root.glob("*.lproj")):
    lang = lproj.name.removesuffix(".lproj")
    if lang == base:
        continue
    entradas = specs(lproj / "Localizable.strings")
    entradas.update(plural_specs(lproj / "Localizable.stringsdict"))
    for key, (expected, positional) in entradas.items():
        entry = reference.get(key)
        if entry is None:
            continue  # la paridad de claves ya lo cubre
        found, base_positional = entry
        # Si una usa posicionales y la otra no, se comparan como conjuntos: reordenar con
        # `%1$@` es legítimo y ahí el orden deja de significar nada.
        if positional != base_positional:
            expected, found = sorted(expected), sorted(found)
        if expected != found:
            nota = " (mismo conjunto, distinto ORDEN: los argumentos se leerían cruzados)" \
                if sorted(expected) == sorted(found) else ""
            print(f"  ✗ {lang}: «{key}» usa {expected or '[]'} y {base} usa {found or '[]'}{nota}")
            failed = True
print(f"▸ {name} — especificadores de formato: " + ("descuadrados" if failed else "paridad correcta"))
sys.exit(1 if failed else 0)
PYEOF
}

# Las categorías de plural que cada idioma NECESITA (CLDR).
#
# `plutil -lint` solo dice que el plist está bien formado, y la paridad de claves que la
# clave existe. Ninguna de las dos ve que al ruso le falte «few»: 2-4 elementos caerían en
# «other», que es la forma de 5 en adelante. El síntoma es una app que cuenta mal en ruso
# con el CI en verde. Al revés también cuenta: una categoría que el idioma no usa es texto
# muerto que alguien mantiene creyendo que se lee.
check_plural_categories() {
  local resources="$1" name="$2"
  python3 - "$resources" "$name" <<'PYEOF' || STATUS=1
import json, subprocess, sys, pathlib

resources, name = sys.argv[1], sys.argv[2]
# Mínimo exigible por idioma. Deliberadamente el conjunto clásico: CLDR 42 añadió «many» a
# es/fr/pt para los millones, y exigirlo marcaría en rojo diez ficheros correctos por un
# caso que esta app no tiene. Lo que sí se exige es que no falte una forma de uso diario.
REQUIRED = {
    "es": {"one", "other"}, "en": {"one", "other"}, "de": {"one", "other"},
    "it": {"one", "other"}, "fr": {"one", "other"}, "pt-BR": {"one", "other"},
    "ru": {"one", "few", "many", "other"},
    "ja": {"other"}, "ko": {"other"}, "zh-Hans": {"other"},
}
CATEGORIES = {"zero", "one", "two", "few", "many", "other"}

failed = False
checked = 0
for lproj in sorted(pathlib.Path(resources).glob("*.lproj")):
    lang = lproj.name.removesuffix(".lproj")
    path = lproj / "Localizable.stringsdict"
    if not path.exists():
        continue
    required = REQUIRED.get(lang)
    if required is None:
        print(f"  ✗ {lang}: idioma sin reglas de plural declaradas en este guion")
        failed = True
        continue
    raw = subprocess.run(
        ["plutil", "-convert", "json", "-o", "-", str(path)],
        capture_output=True, text=True,
    )
    for key, value in json.loads(raw.stdout).items():
        for rule in value.values():
            if not isinstance(rule, dict) or "NSStringFormatSpecTypeKey" not in rule:
                continue
            present = {c for c in rule if c in CATEGORIES}
            checked += 1
            missing = required - present
            if missing:
                print(f"  ✗ {lang}: «{key}» no tiene {sorted(missing)} — esos números saldrían en la forma equivocada")
                failed = True
            extra = present - required - {"zero", "two"}
            if extra:
                print(f"  ✗ {lang}: «{key}» declara {sorted(extra)}, que este idioma no usa: texto muerto")
                failed = True

# Un paquete sin plurales no es un fallo; un paquete CON ficheros de plural de los que no
# se inspeccionó ni una regla, sí: significa que la guarda pasó de largo.
files = list(pathlib.Path(resources).glob("*.lproj/Localizable.stringsdict"))
if files and checked == 0:
    print(f"  ✗ {name}: hay {len(files)} ficheros de plural y no se inspeccionó ni una regla")
    failed = True
if not files:
    # Salir en verde por no encontrar nada es lo que convirtió este control en decorado:
    # una auditoría borró los 10 `.stringsdict` de la app y el guion entero siguió en
    # verde, porque además la paridad de claves sobrevive cuando TODOS los idiomas
    # pierden lo mismo. Para la app se exige que existan; para los paquetes sin plurales
    # se admite, y se dice cuál es cuál.
    if name == "app":
        print(f"  ✗ {name}: no hay ni un Localizable.stringsdict — los plurales saldrían en la forma incorrecta")
        sys.exit(1)
    print(f"▸ {name} — sin plurales que comprobar")
    sys.exit(0)
print(f"▸ {name} — categorías de plural en {checked} reglas: " + ("mal" if failed else "correctas"))
sys.exit(1 if failed else 0)
PYEOF
}

# Los textos de los diálogos de permiso viven en InfoPlist.strings, no en Localizable.
#
# Es lo que el sistema enseña al pedir micrófono y accesibilidad, y no lo miraba nadie: si
# a un idioma le falta `NSMicrophoneUsageDescription`, macOS enseña el texto base —en
# español— dentro de un diálogo del sistema en alemán. Y es el peor sitio para que pase:
# el usuario está decidiendo ahí si te deja escuchar.
check_infoplist_parity() {
  local resources="$1" name="$2" base="$3"
  local base_file="$resources/$base.lproj/InfoPlist.strings"
  if [ ! -f "$base_file" ]; then
    echo "  ✗ $name: no hay InfoPlist.strings de referencia en $base"
    STATUS=1
    return
  fi
  local base_keys checked
  base_keys="$(grep -oE '^"[^"]+"' "$base_file" | sort)"
  checked=0
  for dir in "$resources"/*.lproj; do
    local lang file
    lang="$(basename "$dir" .lproj)"
    file="$dir/InfoPlist.strings"
    if [ ! -f "$file" ]; then
      echo "  ✗ $lang: sin InfoPlist.strings — los diálogos de permiso saldrían en $base"
      STATUS=1
      continue
    fi
    checked=$((checked + 1))
    if ! diff -q <(echo "$base_keys") <(grep -oE '^"[^"]+"' "$file" | sort) > /dev/null; then
      echo "  ✗ $lang: claves de InfoPlist descuadradas"
      diff <(echo "$base_keys") <(grep -oE '^"[^"]+"' "$file" | sort) \
        | sed -n 's/^< /      falta:  /p; s/^> /      sobra:  /p'
      STATUS=1
    fi
    # Un motivo vacío es peor que la clave ausente: el diálogo sale sin explicación.
    if grep -qE '^"[^"]+"[[:space:]]*=[[:space:]]*"";' "$file"; then
      echo "  ✗ $lang: hay un motivo de permiso vacío"
      STATUS=1
    fi
  done
  if [ "$checked" -lt 2 ]; then
    echo "  ✗ $name: solo se inspeccionaron $checked InfoPlist.strings"
    STATUS=1
  fi
  echo "▸ $name — $checked InfoPlist.strings comprobados"
}

check_bundle "$ROOT/apps/Ambar/Resources" "app" "es"
check_bundle "$ROOT/packages/AppCore/Resources" "AppCore" "es"
check_language_census "$ROOT/apps/Ambar/Resources" "app"
check_language_census "$ROOT/packages/AppCore/Resources" "AppCore"
check_strings_syntax "$ROOT/apps/Ambar/Resources" "app"
check_strings_syntax "$ROOT/packages/AppCore/Resources" "AppCore"
check_values "$ROOT/apps/Ambar/Resources" "app" "es"
check_values "$ROOT/packages/AppCore/Resources" "AppCore" "es"
check_format_specifiers "$ROOT/apps/Ambar/Resources" "app" "es"
check_format_specifiers "$ROOT/packages/AppCore/Resources" "AppCore" "es"
check_plural_categories "$ROOT/apps/Ambar/Resources" "app"
check_plural_categories "$ROOT/packages/AppCore/Resources" "AppCore"
check_infoplist_parity "$ROOT/apps/Ambar/Resources" "app" "es"

# El resumen va al FINAL, después de todas las comprobaciones: antes se imprimía
# «✓ Todos los idiomas tienen las mismas claves» y solo después corría la guarda del
# bundle, así que un fallo salía detrás de un ✓. El código de salida era correcto; la
# lectura del log, engañosa.
check_bundle_argument

if [ "$STATUS" -eq 0 ]; then
  echo "✓ Localización verificada: claves, plurales, categorías, especificadores, permisos y bundles"
else
  echo "✗ La localización tiene fallos (ver arriba)" >&2
fi

exit "$STATUS"

