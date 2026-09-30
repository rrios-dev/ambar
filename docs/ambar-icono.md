# Ámbar — el icono

Cómo se hace el icono, por qué la IA generativa no produce el asset final, y
qué queda pendiente.

---

## Estado

| | |
|---|---|
| Concepto | Gota de resina, elegido tras comparar cuatro direcciones |
| Capas vectoriales | `native/apps/Ambar/Resources/IconSource/{background,foreground}.svg` |
| Generador | `native/Scripts/make-icon-layers.py` |
| Icono en uso | `AppIcon.icns` clásico — **pendiente de migrar a Icon Composer** |

---

## Por qué el icono actual hay que rehacerlo

El `AppIcon.icns` que usa la app hoy lleva **el squircle, el degradado, el
reflejo y el canto pintados dentro del PNG**. Eso era lo correcto hasta macOS 15
y es exactamente lo que macOS 26 prohíbe, porque ahora esos efectos los aplica
el sistema:

> «Avoid adding baked-in shadows, highlights, or gradients to your design.»

El resultado en Tahoe es doble: sombra sobre sombra, cristal sobre un cristal
falso. Funciona, pero se ve de la generación anterior junto a los iconos del
sistema — y en una app que presume de Liquid Glass, eso canta.

---

## Qué pide Apple en macOS 26

- Icono **por capas** (fondo, medio, primer plano), no un mapa de bits plano.
- Capas **limpias**: sin sombras, brillos, degradados ni forma redondeada. La
  máscara y el material los pone el sistema.
- Preferiblemente **SVG**, para que escale de 1024 a 16 px sin perder filo.
- Retícula de 1024 px, con lo esencial a un **15 % de los bordes** como mínimo.
  Aquí se usa un 19 %.
- Se compone en **Icon Composer.app** (viene con Xcode 26), que genera las
  variantes clara, oscura, teñida y monocroma.

---

## Por qué la IA no da el asset final

Se generaron cuatro conceptos con Nexus (`fal-ai/flux/dev`). Sirvieron para
elegir dirección, y ninguno era usable tal cual. Cuatro incompatibilidades, no
opiniones:

1. **Genera justo lo prohibido.** Las cuatro imágenes salieron con sombra
   proyectada, reflejos especulares y degradado interno. Quitarlos de un raster
   es rehacer la imagen.
2. **Viene aplanada.** Icon Composer necesita las capas separadas; una imagen
   generada trae todo fundido.
3. **No sobrevive a tamaño pequeño.** Ver más abajo — está medido.
4. **No es vectorial.** Escalar a 16 px con filo exige geometría.

Donde la IA sí aporta: explorar veinte direcciones en diez minutos.

---

## La prueba que decidió el concepto

Se llevaron dos direcciones hasta capas vectoriales reales y se renderizaron a
los tamaños en los que el icono se ve de verdad:

| Tamaño | Gota sola | Gota con insecto |
|---|---|---|
| 1024 px | ✓ | ✓ el más bonito de los dos |
| 128 px | ✓ | ✓ aún se distingue |
| 64 px | ✓ | ~ mancha con patas |
| 32 px | ✓ | ✗ indistinguible |
| **16 px** (barra de menús) | ✓ | ✗ **desaparece** |

A 16 px —que es donde más se ve, en la barra de menús— la variante del insecto
es indistinguible de la gota sola, pero con menos contraste. Toda su gracia se
pierde justo en el tamaño que importa.

**Decisión: gota sola.**

## Detalles de la silueta

Tres decisiones deliberadas, cada una por un motivo:

- **La punta no acaba en vértice** sino en un arco corto. Un pico agudo se lee
  como llama y, a 16 px, el antialias lo convierte en un píxel sucio.
- **El cuerpo es casi circular.** El ojo reconoce círculos a tamaños en los que
  ya no distingue nada más.
- **Los hombros son cóncavos y entran despacio.** Es lo que separa una gota de
  una cebolla.

---

## Lo que falta

Icon Composer **solo tiene interfaz gráfica** — lo he comprobado, no trae
ejecutable de línea de comandos. Así que este paso es manual, y son cinco
minutos:

1. Abrir `Icon Composer.app` (dentro de Xcode → Open Developer Tool).
2. Nuevo icono, y arrastrar las dos capas:
   - `IconSource/background.svg` → capa de fondo
   - `IconSource/foreground.svg` → capa frontal
3. Ajustar el material de la capa frontal (opacidad y especularidad) y revisar
   las variantes oscura, teñida y monocroma que genera solo.
4. Exportar como `Ambar.icon` a `apps/Ambar/Resources/`.
5. En `Scripts/make-app.sh`, sustituir la copia de `AppIcon.icns` por el
   `.icon`, y cambiar `CFBundleIconFile` por `CFBundleIconName` en el
   `Info.plist`.

Hasta entonces, el `.icns` actual sigue funcionando: se ve correcto, solo que
sin participar del material del sistema.

## Regenerar las capas

Si se cambia el diseño:

```bash
cd native && python3 Scripts/make-icon-layers.py apps/Ambar/Resources/IconSource
```

El script no incluye ningún efecto a propósito. Si alguna vez hace falta añadir
una sombra o un degradado a una capa, la respuesta casi seguro es que el ajuste
va en Icon Composer, no en el SVG.
