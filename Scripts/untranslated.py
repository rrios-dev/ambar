#!/usr/bin/env python3
"""Cadenas idénticas al idioma de referencia: copiadas y nunca traducidas.

Se cuela al duplicar el fichero para empezar a traducir y no terminar. La paridad de
claves no lo ve —las claves cuadran— y el usuario japonés lee español.

Antes esto se acotaba con un umbral de 20 caracteres, para no marcar las coincidencias
legítimas —«Color» y «General» se escriben igual en inglés; el portugués comparte
muchísimo con el español—. Funcionaba, y era un punto ciego: una auditoría independiente
midió que dejaba fuera **14 de las 32** claves del dictado, invisibles.

Ahora se marca **toda** coincidencia y las excepciones viven en
`untranslated-allowed.txt`, una por línea, miradas una a una. La diferencia es que el
hueco pasa de invisible a revisado: una cadena nueva que coincida falla hasta que alguien
decida que es un cognado y lo escriba.
"""

import pathlib
import re
import sys

LINE = re.compile(r'\s*"((?:[^"\\]|\\.)+)"\s*=\s*"((?:[^"\\]|\\.)*)"\s*;')
ALLOWLIST = pathlib.Path(__file__).with_name("untranslated-allowed.txt")


def allowed(language: str) -> set[str]:
    """Claves que pueden coincidir con la referencia en ese idioma."""
    if not ALLOWLIST.exists():
        return set()
    keys = set()
    for line in ALLOWLIST.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        parts = line.split("\t")
        if len(parts) == 2 and parts[0] == language:
            keys.add(parts[1])
    return keys


def parse(path: str) -> dict[str, str]:
    values = {}
    with open(path, encoding="utf-8") as handle:
        for line in handle:
            match = LINE.match(line)
            if match:
                values[match.group(1)] = match.group(2)
    return values


def main() -> int:
    base, other = parse(sys.argv[1]), parse(sys.argv[2])
    # El idioma sale de la ruta: …/<lang>.lproj/Localizable.strings
    language = pathlib.Path(sys.argv[2]).parent.name.removesuffix(".lproj")
    exceptions = allowed(language)
    for key, value in sorted(other.items()):
        if base.get(key) == value and key not in exceptions:
            print(f"{key}: {value[:60]}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
