#!/usr/bin/env python3
"""Claves usadas en Swift que no existen en el catálogo del idioma de referencia.

El gate comprobaba que cada `String(localized:)` llevara `bundle:` —necesario, porque sin
él la cadena se resuelve contra `Bundle.main`, donde no están— pero nunca que la clave
existiera. Una auditoría independiente metió `dictation.model.needed.TYPO.NOEXISTE` en una
vista y el guion salió con 0: la app habría pintado ese identificador en crudo, y en los
diez idiomas a la vez, porque cuando la clave no está no hay idioma que la tenga.

Es el síntoma exacto que la cabecera del control dice existir para evitar, un paso más allá.

Uso: unknown-keys.py <raíz> <catálogo.strings> [<catálogo.stringsdict> …]
"""

import pathlib
import re
import sys

# `String(localized: "clave"` — el literal va justo detrás, antes de cualquier otro
# argumento. Se acepta el salto de línea porque muchas llamadas del árbol lo tienen.
USE = re.compile(r'String\(\s*localized:\s*"([^"]+)"', re.S)
DEFINITION = re.compile(r'^\s*"((?:[^"\\]|\\.)+)"\s*=')


def defined_keys(paths: list[str]) -> set[str]:
    keys: set[str] = set()
    for raw in paths:
        path = pathlib.Path(raw)
        if not path.exists():
            continue
        if path.suffix == ".stringsdict":
            # Las claves de un stringsdict son las `<key>` de primer nivel; basta con
            # recogerlas todas: una colisión con una clave interna solo puede dar un falso
            # NEGATIVO en este control, nunca un falso positivo.
            keys |= set(re.findall(r"<key>([^<]+)</key>", path.read_text(encoding="utf-8")))
            continue
        for line in path.read_text(encoding="utf-8").splitlines():
            match = DEFINITION.match(line)
            if match:
                keys.add(match.group(1))
    return keys


def main() -> int:
    root = pathlib.Path(sys.argv[1])
    known = defined_keys(sys.argv[2:])
    if len(known) < 20:
        print(f"✗ el catálogo de referencia trajo {len(known)} claves: no se ha leído nada")
        return 2

    missing: list[str] = []
    scanned = 0
    for area in ("apps", "packages"):
        for path in sorted((root / area).rglob("*.swift")):
            text = path.read_text(encoding="utf-8")
            for match in USE.finditer(text):
                scanned += 1
                key = match.group(1)
                if key not in known:
                    line = text[: match.start()].count("\n") + 1
                    missing.append(f"{path}:{line}: «{key}»")

    if scanned < 50:
        print(f"✗ solo se inspeccionaron {scanned} usos: este control no ha mirado el árbol")
        return 2

    for entry in missing:
        print(entry)
    return 1 if missing else 0


if __name__ == "__main__":
    raise SystemExit(main())
