#!/usr/bin/env python3
"""Genera las capas SVG del icono, listas para Icon Composer.

Reglas que se respetan aquí y que son la razón de redibujar en vez de usar
la imagen generada por IA:

  · Sin sombras, brillos ni degradados: el sistema los aplica sobre las capas.
  · Sin forma redondeada ni marco: la máscara la pone macOS.
  · Márgenes generosos — lo importante dentro del 70 % central del lienzo,
    por encima del 15 % mínimo que pide Apple.
  · Geometría simple: cada capa es un puñado de curvas, no un mapa de bits.
"""
import pathlib
import sys

SIZE = 1024
OUT = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else ".")
OUT.mkdir(parents=True, exist_ok=True)

# Ámbar: resina oscura al borde, miel encendida al centro. Un único tono plano
# por capa; la profundidad la crea el material del sistema, no el arte.
AMBER_DEEP = "#B45309"
AMBER = "#F59E0B"
CREAM = "#FFF7ED"
DARK = "#3B2412"


def svg(body, background=None):
    fill = f'<rect width="{SIZE}" height="{SIZE}" fill="{background}"/>' if background else ""
    return (
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{SIZE}" height="{SIZE}" '
        f'viewBox="0 0 {SIZE} {SIZE}">{fill}{body}</svg>'
    )


def drop(cx, cy, width, height, fill):
    """Gota de resina: punta redondeada arriba, cuerpo lleno abajo.

    Tres decisiones de forma, cada una por un motivo concreto:

    · La punta no acaba en vértice sino en un arco pequeño. Un pico agudo se
      lee como llama y, a 16 px, el antialias lo convierte en un píxel sucio.
    · El cuerpo es casi circular. Cuanto más se acerca la parte baja a un
      círculo, mejor aguanta la reducción: el ojo reconoce círculos a tamaños
      donde ya no distingue nada más.
    · Los hombros son cóncavos y entran despacio. Es lo que separa una gota de
      una cebolla o de un globo.
    """
    half = width / 2
    top = cy - height / 2
    bottom = cy + height / 2
    # El centro del cuerpo redondo, desplazado hacia abajo: la masa de una gota
    # de resina cae, no está centrada.
    body_r = half
    body_cy = bottom - body_r
    tip_r = width * 0.055               # radio de la punta redondeada

    return (
        f'<path fill="{fill}" d="'
        # Punta: arco corto que evita el vértice.
        f"M {cx - tip_r} {top + tip_r * 1.4} "
        f"Q {cx} {top}, {cx + tip_r} {top + tip_r * 1.4} "
        # Hombro derecho: entrada cóncava y larga hacia el ecuador del cuerpo.
        f"C {cx + half * 0.42} {top + height * 0.30}, {cx + body_r} {body_cy - body_r * 0.62}, "
        f"{cx + body_r} {body_cy} "
        # Cuerpo: media circunferencia.
        f"A {body_r} {body_r} 0 1 1 {cx - body_r} {body_cy} "
        # Hombro izquierdo, simétrico.
        f"C {cx - body_r} {body_cy - body_r * 0.62}, {cx - half * 0.42} {top + height * 0.30}, "
        f"{cx - tip_r} {top + tip_r * 1.4} "
        f'Z"/>'
    )


def insect(cx, cy, scale, fill):
    """Silueta de insecto, reducida a lo mínimo reconocible.

    Cuerpo, cabeza, tres pares de patas y antenas. Sin detalle interno: a
    cualquier tamaño útil, el detalle se convierte en ruido.
    """
    s = scale
    parts = [
        f'<ellipse cx="{cx}" cy="{cy + 22 * s}" rx="{30 * s}" ry="{46 * s}"/>',  # abdomen
        f'<ellipse cx="{cx}" cy="{cy - 30 * s}" rx="{22 * s}" ry="{24 * s}"/>',  # tórax
        f'<circle cx="{cx}" cy="{cy - 62 * s}" r="{15 * s}"/>',                  # cabeza
    ]
    stroke = 9 * s
    for index, (y, spread, lift) in enumerate([(-38, 62, -30), (-4, 70, 6), (30, 62, 44)]):
        for direction in (-1, 1):
            x1 = cx + direction * 18 * s
            y1 = cy + y * s
            x2 = cx + direction * spread * s
            y2 = cy + lift * s
            parts.append(
                f'<path d="M {x1} {y1} Q {cx + direction * (spread - 8) * s} {y1} {x2} {y2}" '
                f'stroke-width="{stroke}" stroke-linecap="round" fill="none" stroke="{fill}"/>'
            )
        _ = index
    for direction in (-1, 1):
        parts.append(
            f'<path d="M {cx + direction * 6 * s} {cy - 74 * s} '
            f"Q {cx + direction * 26 * s} {cy - 104 * s} {cx + direction * 34 * s} {cy - 120 * s}\" "
            f'stroke-width="{stroke * 0.8}" stroke-linecap="round" fill="none" stroke="{fill}"/>'
        )
    return f'<g fill="{fill}">' + "".join(parts) + "</g>"


C = SIZE / 2
# La gota ocupa el 62 % del ancho: deja un margen del 19 % por lado, cómodamente
# por encima del 15 % que Apple pide para lo esencial.
DROP_W, DROP_H = SIZE * 0.62, SIZE * 0.74
DROP_CY = C + SIZE * 0.02

variants = {
    # A — gota sola. Una sola silueta, la apuesta segura.
    "a-background": svg("", AMBER),
    "a-foreground": svg(drop(C, DROP_CY, DROP_W, DROP_H, CREAM)),
    # B — gota con insecto dentro. Tres capas: fondo, gota, insecto.
    "b-background": svg("", AMBER_DEEP),
    "b-middle": svg(drop(C, DROP_CY, DROP_W, DROP_H, AMBER)),
    "b-foreground": svg(insect(C, DROP_CY + SIZE * 0.01, SIZE / 1024 * 1.55, DARK)),
}

for name, content in variants.items():
    (OUT / f"{name}.svg").write_text(content)

# Composiciones planas solo para poder mirarlas a distintos tamaños. No son el
# entregable: Icon Composer recibe las capas por separado.
(OUT / "preview-a.svg").write_text(
    svg(drop(C, DROP_CY, DROP_W, DROP_H, CREAM), AMBER)
)
(OUT / "preview-b.svg").write_text(
    svg(
        drop(C, DROP_CY, DROP_W, DROP_H, AMBER)
        + insect(C, DROP_CY + SIZE * 0.01, SIZE / 1024 * 1.55, DARK),
        AMBER_DEEP,
    )
)

print(f"{len(variants)} capas + 2 previsualizaciones en {OUT}")
