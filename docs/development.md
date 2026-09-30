# Ámbar

Gestor de historial del portapapeles para macOS. Guarda lo que copias —texto,
imágenes, archivos, colores— y lo devuelve con `⌘⇧V`.

La resina de ámbar atrapa y conserva intacto lo que pasa por ella. Eso hace la
app, y por eso es translúcida.

> Primera app de la raíz `native/` del monorepo Forge. El contrato de esa raíz
> está en [`docs/architecture/native-platform.md`](../docs/architecture/native-platform.md).

---

## Qué hace

- **Historial con imágenes.** Miniaturas en la lista, imagen completa en la
  vista previa. Los binarios se guardan en disco direccionados por contenido, no
  dentro de la base de datos.
- **Busca dentro de las imágenes.** Vision lee el texto de cada captura al
  copiarla y lo indexa. Copias una factura y semanas después la encuentras
  escribiendo «factura». Todo en el dispositivo.
- **Búsqueda instantánea.** SQLite con FTS5 e índice invertido. Sin tildes
  encuentra con tildes: `cancion` → `canción`.
- **Pega con o sin formato.** `↵` restaura todas las representaciones y deja
  elegir a la app de destino; `⌘↵` fuerza texto plano.
- **Filtros por prefijo.** `img:`, `file:`, `app:safari`, `pin:`.
- **Fijados.** Nunca caducan, siempre encabezan la lista.
- **Dictado por voz.** Mantén el atajo del historial y empieza a dictar; a partir
  de ahí las manos quedan libres y se para con `↵`. Todo en el dispositivo, con
  el motor de dictado del sistema. Viene apagado: activarlo implica el permiso de
  micrófono y descargar el modelo del idioma, y eso lo decide quien lo use.
- **Privacidad por defecto.** Ignora lo que el origen marque como confidencial
  (`org.nspasteboard.ConcealedType`) y trae los gestores de contraseñas más
  comunes ya excluidos.
- **Diez idiomas**: español, inglés, francés, alemán, italiano, portugués (Brasil),
  japonés, chino simplificado, coreano y ruso — con reglas de plural propias de
  cada uno.
- **La ventana se puede mover** y recuerda dónde la dejaste, como Spotlight.
- **Techos de tamaño** para que un volcado accidental no tumbe la app: 5 MB de
  texto, 64 MB o 80 megapíxeles de imagen. Lo que los supera **no se captura**
  —nunca se guarda a medias— y se avisa de por qué.

## Primer uso

La primera vez que se abre, Ámbar se presenta en una ventana con seis pasos: qué hace
y que nada sale del Mac, llevar la app a Aplicaciones si no está ahí, el permiso de
Accesibilidad, el atajo y el arranque al inicio, el dictado y el reconocimiento de
texto —ambos opcionales—, y un cierre que recuerda dónde se cambia todo después.

Dos decisiones que conviene conocer:

- **El traslado a Aplicaciones va antes que el permiso.** Los permisos se conceden a
  una copia concreta de la app; concederlos y mover la app después es la forma conocida
  de perderlos, con el peor síntoma posible: el interruptor aparece activado en Ajustes
  del Sistema y el pegado no funciona. Desde el árbol de compilación no se ofrece nada
  (ver `AppRelocation`).
- **Cerrar la ventana cuenta como vista.** Volver a presentarla en cada arranque hasta
  que alguien llegue al último paso convierte una bienvenida en una insistencia. Quien
  la cierre a medias la recupera entera en Ajustes → «Ver la presentación de nuevo».

Los pasos ya resueltos se omiten: con el permiso concedido, ese paso no aparece.

## Atajos

| Tecla | Acción |
|---|---|
| `⌘⇧V` | Abrir o cerrar el panel (configurable en Ajustes) |
| `↑` `↓` | Moverse por la lista |
| `↵` | Pegar conservando el formato |
| `⌘↵` | Pegar como texto plano |
| `⌘P` | Fijar o soltar |
| `⌘⌫` | Borrar la entrada |
| `esc` | Cerrar |

Con el dictado activado y una sesión en marcha, tres teclas cambian de
significado — el pie del panel lo dice en cada momento:

| Tecla | Acción |
|---|---|
| `⌘D` | Dictar, parar o descartar, según lo que esté pasando |
| `↵` | Parar el dictado y pegar |
| `⌘⌫` | Descartar sin pegar |

---

## Compilar y ejecutar

Requiere **macOS 26** y **Xcode 26** (por `NSGlassEffectView`).

```bash
cd native
swift build
swift test
./Scripts/make-app.sh debug     # deja .build/Ambar.app
open .build/Ambar.app
```

Para el icono, si se cambia el diseño:

```bash
swift Scripts/make-icon.swift
```

Y para comprobar que ningún idioma se ha quedado descuadrado:

```bash
./Scripts/check-localization.sh
```

Para el instalador —una imagen de disco con la app y un alias a Aplicaciones—:

```bash
./Scripts/make-app.sh release && ./Scripts/make-dmg.sh
```

Deja `.build/Ambar-<versión>.dmg`, y lo verifica montándolo: comprueba que dentro
están la app y el alias, que el alias apunta de verdad a `/Applications` y que la firma
del bundle sigue válida. La ventana con fondo y los iconos colocados se compone
pidiéndoselo al Finder, que exige permiso de Automatización: donde no lo haya —en CI—
el DMG sale igual de válido, sin fondo, y el guion lo dice en vez de fingir que salió.

---

## Que pegue sola (permiso de accesibilidad)

Ámbar funciona sin permiso: copia la entrada al portapapeles y la pegas tú con
`⌘V`. Con el permiso concedido, `↵` pega directamente en la app donde estabas.

Son **dos pasos**, y hay que hacerlos en este orden:

```bash
./Scripts/setup-signing.sh      # 1. certificado estable (una sola vez)
./Scripts/make-app.sh           # 2. compilar firmando con él
```

Luego abre la app y concede el permiso en **Ajustes del Sistema → Privacidad y
seguridad → Accesibilidad**.

### Por qué el orden importa

**macOS asocia el permiso a la firma del binario, no a su ruta.** Con firma
ad-hoc —la de por defecto— cada compilación produce una firma distinta: el
sistema ve otra app y revoca el permiso. Si concedes el permiso antes de tener
firma estable, lo perderás en la siguiente compilación y el pegado dejará de
funcionar sin ningún mensaje.

`setup-signing.sh` crea un certificado de firma en tu llavero de inicio de
sesión. No necesita cuenta de Apple, no pide administrador y se deshace
borrando el certificado en Acceso a Llaveros. La primera vez que firmes, macOS
pedirá permiso para usar la clave: pulsa **Permitir siempre**.

Si ya tienes un certificado propio (por ejemplo *Apple Development* de un Apple
ID en Xcode), úsalo directamente:

```bash
CODESIGN_IDENTITY="Apple Development: tu@correo.com" ./Scripts/make-app.sh
```

### Si el atajo no responde (y el dictado «desaparece»)

El atajo global es de **todo el sistema**: si otro proceso lo tiene registrado, Ámbar arranca
igual pero su atajo no hace nada. El caso que más muerde desarrollando es una **segunda copia
de Ámbar** viva —un proceso de prueba que sobrevivió a un `kill`, o el bundle de `.build`
abierto a la vez que el de `/Applications`—: el atajo lo atiende esa otra copia, que con
`AMBAR_DATA_DIR` trae otro historial y el dictado apagado de fábrica. El síntoma es «ya no
está disponible el reconocimiento de voz», y no hay nada roto.

Desde 2026-08-17 la app **lo dice**: si el registro falla, el menú de la barra abre con el
aviso y Ajustes lo repite junto al grabador de atajos. Antes se descartaba en silencio.

Para comprobar quién está vivo:

```bash
ps -eo pid,etime,command | grep "Ambar.app/Contents/MacOS/Ambar" | grep -v grep
```

Si aparece más de una línea, mata las que no quieras y **reinicia** la que te interese: el
registro Carbon se intenta al arrancar, así que la copia que perdió el atajo no lo recupera
sola.

### Si la app no aparece en Ajustes del Sistema → Micrófono

Porque **no se puede añadir a mano**: macOS solo enumera ahí las apps que han *solicitado* el
permiso. Si Ámbar no está, es que nunca lo pidió, y entonces el remedio no está en Ajustes del
Sistema sino en la app: Ajustes de Ámbar → Dictado → **Pedirlo**.

Cómo se llega a ese estado sin darse cuenta: activar el dictado en una copia lanzada **desde un
terminal**. TCC atribuye la solicitud al terminal —que probablemente ya tiene el micrófono
concedido, así que ni aparece el diálogo—, la oferta sale «listo» y el ajuste queda guardado a
`true`, pero Ámbar no queda registrada en ninguna parte. Medido en este mismo repositorio: el
mismo bundle daba `micrófono=granted` lanzado con `./.build/…/Ambar` y `notDetermined` lanzado
con `open`.

Para verlo y para pedirlo sin pasar por la interfaz —y que la app aparezca en la lista—:

```bash
./Scripts/microphone.sh report     # mide, sin diálogos
./Scripts/microphone.sh request    # pide: sale el diálogo del sistema
```

Es un guion y no un par de comandos por dos motivos, los dos aprendidos fallando: el arnés
solo viaja en las compilaciones de **depuración**, así que un `open` sobre un `.build` que
contenía un bundle de release arrancaba la app sin pedir nada y sin decirlo —el guion monta
debug y lo comprueba antes de lanzar—; y hay que lanzar con `open`, porque ejecutando el
binario la solicitud se atribuye al terminal.

---

## Cómo está montado

```
native/
├── Package.swift                    un paquete, varios targets
├── packages/
│   ├── BlobStore/                   binarios por contenido (SHA-256) + miniaturas
│   ├── ClipboardKit/                captura, modelo, SQLite/FTS5, OCR
│   ├── GlassUI/                     primitivos Liquid Glass y medidas
│   ├── VoiceKit/                    dictado: motor Speech, audio, capacidad
│   └── AppCore/                     atajos, pegado, arranque al inicio, ubicación
├── apps/Ambar/                      wiring y UI
│   ├── Onboarding.swift             qué pasos se muestran y por dónde va
│   └── OnboardingController.swift   la ventana de la presentación
├── Tests/
└── Scripts/
    ├── make-app.sh                  monta y firma el bundle .app
    ├── microphone.sh                estado del permiso de micrófono, y pedirlo
    ├── make-dmg.sh                  empaqueta el instalador y lo verifica
    ├── make-dmg-background.swift    fondo de la ventana del DMG
    └── make-icon.swift              genera AppIcon.icns
```

### Decisiones que conviene conocer antes de tocar el código

**Sin dependencias externas.** SQLite viene con el sistema y `Database.swift`
es un envoltorio de 200 líneas. Una dependencia en el camino de datos significa
resolución de red al compilar, superficie que auditar antes de notarizar y una
capa entre el código y el `CREATE VIRTUAL TABLE ... USING fts5`, que es donde
está el rendimiento.

**Las imágenes no van en la base de datos.** Guardarlas como BLOB hincha el
fichero y ralentiza *todas* las consultas, incluidas las que no tocan imágenes.
Van a `blobs/<hash[0:2]>/<hash>`, con deduplicación automática: diez capturas
iguales ocupan lo que una.

**Un item tiene N representaciones.** El portapapeles ofrece varias UTIs a la
vez para el mismo contenido. Se guardan todas y al pegar se restauran todas,
que es lo que permite conservar el formato en Pages y no arrastrar basura a la
terminal.

**El tokenizador lleva `remove_diacritics 2`.** Sin él, buscar `cancion` no
encuentra `canción` y la búsqueda parece rota.

**`GlassUI` no define colores.** Los pone el sistema, para que la app herede el
modo claro/oscuro y el color de acento del usuario. Una paleta propia haría que
se viese ajena a macOS.

**Lo que excede el límite no se trunca, se descarta.** Guardar la mitad de un
texto y dejar que se pegue como si estuviera completo es un fallo de integridad
peor que no guardarlo: el original sigue en el portapapeles del sistema y se
puede pegar con ⌘V. Los techos están en `ClipboardKit/CaptureLimits.swift`.

**El atajo global usa Carbon.** `RegisterEventHotKey` es API vieja, pero es la
única que **no** exige permiso de accesibilidad. Que la app se pueda invocar
desde el primer arranque justifica de sobra la elección.

---

## Variables de entorno (desarrollo)

| Variable | Efecto |
|---|---|
| `AMBAR_DATA_DIR` | Historial en otra carpeta. Evita tocar los datos reales al probar. |
| `AMBAR_SUPPRESS_PROMPTS` | No pide el permiso de accesibilidad al arrancar. |
| `AMBAR_SHOW_ON_LAUNCH` | Abre el panel nada más arrancar. |
| `AMBAR_SEED_DEMO` | Inserta entradas de ejemplo de cada tipo. |
| `AMBAR_CAPTURE_TO` | Rasteriza la interfaz a un PNG y sale. |
| `AMBAR_CAPTURE_LIGHT` | La captura anterior, en modo claro. |
| `AMBAR_CAPTURE_INDEX` | Fila seleccionada en la captura. |
| `AMBAR_CAPTURE_ONBOARDING` | Rasteriza un paso de la presentación: `welcome`, `location`, `accessibility`, `invocation`, `extras`, `finish`. Junto con `AMBAR_CAPTURE_TO`. |
| `AMBAR_DUMP_A11Y=onboarding` | Vuelca el árbol de accesibilidad de la presentación, paso a paso. |
| `AMBAR_REQUEST_MIC` | Pide el permiso del micrófono y sale. Lánzalo con `open`, o la solicitud se atribuye al terminal. |
| `AMBAR_REPORT_TO` | Escribe el informe de `AMBAR_PERMISSIONS`/`AMBAR_REQUEST_MIC` en un fichero, que es la única forma de leerlo cuando la app se lanza con `open`. |

`AMBAR_PERMISSIONS=1` avisa además de **quién lanzó la app**, y esa línea importa: al ejecutar
el binario a mano desde un terminal, TCC puede atribuir los permisos de micrófono al terminal
en lugar de a Ámbar. Una medición así dio `micrófono=granted` mientras la app, abierta
normalmente, no tenía el permiso ni aparecía en la lista del sistema. Para medir lo que ve el
usuario: `open .build/Ambar.app`.

Las capturas de la presentación fijan sus condiciones —app fuera de Aplicaciones, permiso
sin conceder— para que el resultado no dependa de lo que esa máquina tenga concedido. Dos
avisos al mirarlas: el material de cristal no aparece (lo compone el servidor de ventanas
fuera del proceso) y los interruptores y el grabador de atajos salen como un rectángulo
amarillo, porque son vistas de AppKit que `ImageRenderer` no sabe dibujar. Lo que estas
capturas juzgan es la composición.

Ejemplo — revisar la interfaz sin tocar nada real:

```bash
AMBAR_DATA_DIR=/tmp/ambar-demo AMBAR_SEED_DEMO=1 \
AMBAR_SUPPRESS_PROMPTS=1 AMBAR_CAPTURE_TO=/tmp/panel.png \
  ./.build/Ambar.app/Contents/MacOS/Ambar
```

---

## Estado

Listo para producción salvo la publicación. **512 tests** cubren almacén, índice,
blobs, miniaturas, OCR, filtros, retención, permisos de disco, contraste, dictado,
ubicación de la app y los pasos de la presentación; build release sin avisos y Hardened
Runtime activo. El instalador se construye y se verifica con `./Scripts/make-dmg.sh`.

Lo visual —que el material de cristal se compone como debe, que el texto alemán no
desborda la ventana de la presentación— **no lo cubre ningún test**: el material lo pinta
el servidor de ventanas fuera del proceso y no sale en ninguna rasterización. Lo que sí
está automatizado es que los controles de la presentación tengan nombre para VoiceOver,
sobre la app viva, en `./Scripts/check-accessibility.sh`.

Lo que falta para publicar está en
[`docs/ambar-lanzamiento.md`](../docs/ambar-lanzamiento.md), y se reduce a la
cuenta del Apple Developer Program.
