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

import os
import pathlib
import re
import sys

# `String(localized: "clave"` — el literal va justo detrás, antes de cualquier otro
# argumento. Se acepta el salto de línea porque muchas llamadas del árbol lo tienen.
USE = re.compile(r'String\(\s*localized:\s*"([^"]+)"', re.S)
DEFINITION = re.compile(r'^\s*"((?:[^"\\]|\\.)+)"\s*=')
# Another app can route its keys through a wrapper that takes the literal key (one capture
# group): LOCALIZATION_EXTRA_USE. LOCALIZATION_MIN_CALLS lowers the floor for a smaller tree.
EXTRA = os.environ.get("LOCALIZATION_EXTRA_USE")
USES = [USE] + ([re.compile(EXTRA, re.S)] if EXTRA else [])
MIN_USES = int(os.environ.get("LOCALIZATION_MIN_CALLS", "50"))
# `"menu.quit \(name)"` is the key `menu.quit %@` in the catalog: interpolations and the
# catalog's format specifiers are both reduced to one token before comparing.
SPECIFIER = re.compile(r'%(?:\d+\$)?[-+ #0]*[\d.]*(?:ll|l|h|hh|z|q)?[@dioufFeEgGxXsc]')


def without_interpolations(key: str) -> str:
    out, index = [], 0
    while index < len(key):
        if key.startswith("\\(", index):
            depth, index = 0, index + 1
            while index < len(key):
                if key[index] == "(":
                    depth += 1
                elif key[index] == ")":
                    depth -= 1
                    if depth == 0:
                        break
                index += 1
            out.append("\u0000")
            index += 1
            continue
        out.append(key[index])
        index += 1
    return "".join(out)


def normalised(key: str) -> str:
    return SPECIFIER.sub("\u0000", without_interpolations(key))


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
    known = {normalised(key) for key in defined_keys(sys.argv[2:])}
    if len(known) < 20:
        print(f"✗ el catálogo de referencia trajo {len(known)} claves: no se ha leído nada")
        return 2

    missing: list[str] = []
    scanned = 0
    for area in ("apps", "packages"):
        for path in sorted((root / area).rglob("*.swift")):
            text = path.read_text(encoding="utf-8")
            for match in (found for use in USES for found in use.finditer(text)):
                scanned += 1
                key = match.group(1)
                if normalised(key) not in known:
                    line = text[: match.start()].count("\n") + 1
                    missing.append(f"{path}:{line}: «{key}»")

    if scanned < MIN_USES:
        print(f"✗ solo se inspeccionaron {scanned} usos: este control no ha mirado el árbol")
        return 2

    for entry in missing:
        print(entry)
    return 1 if missing else 0


if __name__ == "__main__":
    raise SystemExit(main())
