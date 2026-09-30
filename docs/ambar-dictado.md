# Ámbar — dictado por voz

Diseño de la transcripción de voz como segunda puerta de entrada al conducto de
Ámbar. Qué se decidió, por qué, y las tensiones que quedan por medir.

> **Revisión 2 (2026-08-12)** — incorpora la auditoría
> [`audit/ambar-dictado-2026-08-12.md`](audit/ambar-dictado-2026-08-12.md): 3
> bloqueantes, 8 graves y 8 menores. Donde el informe contradecía a la revisión 1,
> manda el informe. Los cambios de fondo son tres: el módulo del framework era el
> equivocado (§2), el permiso del micrófono no puede pedirse desde el gesto (§4.1),
> y la detección del gesto no puede fijar los modificadores por constante (§8.2).

---

## Estado

| | |
|---|---|
| Fase | **Implementado** — F0 a F5 cerradas; F6 (auditoría de cierre) en curso |
| Motor | `DictationTranscriber` + `SpeechAnalyzer` (framework **Speech**, macOS 26) |
| Verificado contra | `MacOSX26.0.sdk` · Xcode 26.0.1 |
| Red | **Ninguna** durante el uso. Una instalación de modelo, hecha por el sistema |
| Activación | **Apagado siempre** hasta que el usuario lo active |
| Gesto | El atajo del historial, mantenido → el panel transita a *escuchando*. **Soltar no para**: se para con ⏎, con el botón o con ⌘D |
| Permisos nuevos | Micrófono, pedido **desde Ajustes**, nunca desde el gesto |
| Audio | No se guarda. Solo la transcripción |

---

## 1. La tesis: por qué encaja en un gestor de portapapeles

Dos razones, y la segunda es la que sostiene el producto.

**El carril ya existe.** `Store.pendingOCRItems()` y el `ocr_state` de
`image_meta` (`pending → done | failed | skipped`) son un pipeline de
enriquecimiento asíncrono cuyo trabajo es coger un blob no textual y convertirlo
en texto indexado en FTS5. El reconocimiento de texto es imagen→texto; la
transcripción es audio→texto. Mismo carril, otro motor: `TextRecognizer` tiene
un hermano gemelo que todavía no existe.

**Lo caro ya está pagado.** Lo difícil de una app de dictado no es transcribir —
eso es una llamada. Es el atajo global sin permisos, el pegado con `CGEvent`, un
panel que aparece en un frame y devuelve el foco a la app anterior, el historial
con búsqueda, diez idiomas. Ámbar tiene todo eso construido y
auditado.

De ahí sale la reformulación del producto, que evita el cajón de sastre: Ámbar
deja de ser *el historial de lo que copiaste* y pasa a ser **el conducto por el
que el texto entra en cualquier app** — de entrada por voz, de reentrada por
historial. Una idea, dos puertas.

---

## 2. El motor

El framework Speech de macOS 26 expone **dos** módulos dependientes de locale. El
que corresponde a este caso de uso es `DictationTranscriber`, no
`SpeechTranscriber`:

| | `DictationTranscriber` | `SpeechTranscriber` |
|---|---|---|
| Presets | `phrase`, `shortDictation`, `progressiveShortDictation`, `longDictation`, `progressiveLongDictation`, `timeIndexedLongDictation` | `transcription`, `progressiveTranscription`, … |
| `TranscriptionOption` | `punctuation`, `emoji`, `etiquetteReplacements` | `etiquetteReplacements` y nada más |
| `ContentHint` | `shortForm`, `farField`, `atypicalSpeech`, `customizedLanguage(…)` | — |
| `installedLocales` | Sí | No |

Las tres razones para elegirlo son concretas, no de nombre:

- **`punctuation`** — dictar «coma» y «punto». En una función cuyo destino es un
  campo de texto, eso no es un extra.
- **`ContentHint.atypicalSpeech`** — la función de accesibilidad de Apple para
  habla atípica. Con el otro módulo se pierde sin que nadie lo decida.
- **`ContentHint.shortForm`** — describe exactamente el uso de Ámbar: frases
  cortas hacia un campo.

### 2.1 Configuración por modo

| Modo | Preset |
|---|---|
| En vivo | `progressiveShortDictation` |
| Diferido | `shortDictation` |

Con `ReportingOption.volatileResults` en el modo en vivo — es la opción que
habilita los resultados que se refinan (§7.1), y su existencia como *opción
explícita* del framework confirma que la volatilidad hay que gestionarla, no
esperar a que no ocurra.

### 2.2 Reversibilidad

**La incógnita es la calidad, no la integración** — sobre todo en español hablado
rápido y con muletillas, que es el caso real. Por eso el transcriptor va detrás de
un protocolo aislado, igual que `TextRecognizer` está aislado hoy: si el nativo no
da la talla, whisper.cpp entra por detrás sin rediseñar nada de este documento.
**La decisión de motor tiene que ser reversible desde el primer día.**

Una **API remota queda descartada** como opción por defecto: el argumento de venta
de Ámbar es que nada sale de la máquina.

---

## 3. Todo corre en local

| Pieza | Dónde corre |
|---|---|
| Atajo global | Carbon, en el proceso |
| Detección del mantenido (solo durante la cuenta) | `NSEvent.modifierFlags`, en el proceso |
| Captura y conversión de audio | AVFoundation, en el proceso |
| Transcripción | Framework Speech, **en el dispositivo** |
| Pegado | `CGEvent`, en el proceso |
| Historial y búsqueda | SQLite FTS5 en disco |

Sin cuentas, sin claves de API que rotar, sin servicios que se puedan caer y
dejar la función muerta, y **sin coste marginal por usuario**: el dictado no
obliga a ningún modelo de suscripción, y Ámbar sigue siendo gratuita.

### 3.1 Los modelos son locales pero los instala el sistema

No van en el bundle. La app consulta `AssetInventory.status(forModules:)` y, si
hace falta, pide un `AssetInstallationRequest` y llama a `downloadAndInstall()`,
reportando su `progress`. Esa instalación es la única vez que interviene la red,
la hace macOS, y **no viaja nada del usuario** — ni audio ni texto.

Consecuencia: es la primera vez que Ámbar depende de la red para algo. Se diseña
como tal (§5), no se improvisa.

### 3.2 Formato de audio: se negocia, no se supone

El formato nativo del micrófono rara vez coincide con el que el módulo acepta, así
que hay una conversión por medio y es una pieza con coste propio:

1. `SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith:)` — se usa la variante sin
   `considering:`. Medido: con 48 kHz Float32 como referencia, las dos devuelven el mismo
   16 kHz Int16, así que el parámetro no cambia nada aquí.
2. Conversión de los buffers del tap al formato elegido.
3. `AnalyzerInput(buffer:bufferStartTime:)` hacia el analizador, **con la marca de
   tiempo puesta**. No es opcional: la cola del micrófono descarta lo más antiguo cuando
   el análisis se retrasa, y sin marca el motor trata la secuencia como contigua — un
   descarte deja de ser un hueco y se convierte en un **empalme** de dos trozos de habla
   distintos. O se ponen las marcas o no se descarta.

Formatos medidos: el módulo admite **16 kHz o 8 kHz, mono, Int16**, y
`bestAvailableAudioFormat` devuelve el primero. Un micrófono entrega 44,1 o 48 kHz
en Float32, así que la conversión ocurre siempre. Alimentar al analizador con el
formato equivocado **no da un error: aborta el proceso** (SIGTRAP sin mensaje).

Detalle con consecuencia: la primera llamada al convertidor devuelve ~15 % menos
marcos de lo teórico porque su filtro de remuestreo se ceba. Solo afecta al primer
buffer de cada sesión —unos 15 ms, que son silencio o el arranque de la primera
sílaba— y no se repite mientras el flujo continúa.

**Si el dispositivo de entrada cambia a mitad de sesión** (unos auriculares que se
conectan), el formato negociado deja de valer: la sesión se finaliza con lo que
haya, se avisa, y no se intenta continuar con un formato inválido.

---

## 4. «Opcional de verdad» tiene un significado técnico

Si el dictado está apagado, no debe existir:

- **Target propio** `VoiceKit` en el `Package.swift`: cuanta menos superficie,
  menos hay que auditar.
  La app lo enlaza pero no depende de él para arrancar. No se llama `Dictation`
  para no colisionar con `DictationTranscriber` del sistema en los `import`.
- **Nada de `import Speech` en el camino de arranque.** Apagado significa: no se
  instancia nada, no se pide micrófono, no se instala ningún modelo y **cero coste
  en el tiempo de aparición del panel**. Ese último punto no es cosmético: el
  producto se define por esa latencia.

  Precisión que la revisión 1 no hacía: el framework **sí se enlaza en duro**, así
  que dyld lo mapea en cada arranque aunque el dictado esté apagado (comprobado con
  `otool -L`). El coste es el de una biblioteca compartida, no cero. Lo que sí es
  cero es lo que importa: no se carga modelo, no se abre micrófono y no se instancia
  el coordinador.
- **`NSMicrophoneUsageDescription`** es inevitable en el `Info.plist` (hoy no hay
  ninguna *usage description*), pero es una cadena estática.

### 4.1 El permiso del micrófono se pide desde Ajustes, nunca desde el gesto

El panel se oculta al perder la condición de ventana clave
(`PanelController.resignKey` → `hide()`), y el diálogo de TCC **roba esa
condición**. Pedir el permiso durante el gesto destruiría el gesto: el panel
desaparece, el usuario concede el permiso y se queda sin nada delante,
`previousApplication` se recaptura y el destino del pegado cambia. Si además la
sesión de audio ya se hubiera abierto, quedaría **el micrófono activo sin interfaz
visible**.

Por tanto:

1. El permiso se solicita **al activar la función en Ajustes**, con la app
   activada explícitamente antes de la petición.
2. **Mientras haya una sesión de dictado viva, `onResignKey` no oculta el panel.**
   El panel no puede evaporarse con el micrófono abierto.
3. Si el permiso está denegado, el dictado aparece como no disponible con un
   acceso directo a Ajustes del Sistema, igual que ya se hace con Accessibility.

### 4.1.bis Qué pasa si el permiso se revocó (o nunca se llegó a conceder) y el
usuario mantiene el atajo de todas formas

El permiso puede faltar sin que nadie active nada explícitamente: se pidió una
vez, el usuario lo denegó, o la app se reinstaló con una firma distinta —el
grant de TCC es **por firma**, y sustituir el binario lo invalida— y el estado
del sistema vuelve a `notDetermined` sin que ningún ajuste de Ámbar lo refleje.

Dos caminos alcanzan el dictado sin permiso, y responden distinto a propósito:

- **El botón del micrófono / ⌘D** (`startWithoutGesture`) comprueba el permiso
  **antes de nada** y publica `.failed(.permissionDenied)` de inmediato: quien
  pulsó un botón para dictar tiene que enterarse ya.
- **El atajo mantenido** comprobaba el permiso al mismo tiempo que arrancaba la
  cuenta, y con permiso ausente el gesto **no armaba en absoluto** — ni
  progreso, ni aviso, nada. Reportado como «mantengo el atajo y no se pone a
  grabar»: no había forma de distinguir «no lo estoy sujetando bien» de «no
  tengo permiso».

La cuenta arma y avanza con normalidad **aunque falte el permiso** — es lo que
distingue a quien de verdad mantiene la tecla de quien solo dio un toque para
abrir el panel, y esa señal no puede depender de saber si hay permiso. El
permiso se comprueba **al completar la cuenta**, justo antes de abrir el
micrófono, con el mismo aviso — banda roja y enlace a Ajustes — que ya da el
botón. Un toque breve para abrir el panel sigue sin pintar nada: se autocancela
al soltar antes de llegar ahí, como siempre.

---

## 5. Los estados de la función

Se adopta la taxonomía del sistema, `AssetInventory.Status`, en lugar de inventar
una propia:

| Estado | Significado | Comportamiento |
|---|---|---|
| `unsupported` | El locale no está entre los `supportedLocales`, o no hay micrófono, o el permiso está denegado | No se puede activar. Se explica por qué |
| `supported` | Se puede, pero el modelo no está instalado **para esta app** (ver §11.1: exige reservar antes de creerlo) | Se ofrece indicando el peso; instalación con progreso; degrada con dignidad sin red |
| `downloading` | Instalación en curso | Progreso visible; el dictado no está disponible todavía |
| `installed` | Listo | Se ofrece |

Y **en paralelo**, un eje de capacidad medido (§6) que solo cambia el tono y la
preselección:

| Capacidad | Comportamiento |
|---|---|
| Holgada | Se ofrece, con *en vivo* preseleccionado |
| Justa | Se ofrece **con advertencia explícita** de qué se va a notar, y *diferido* preseleccionado |

La diferencia entre holgada y justa **no es encendido/apagado — es el tono**: una
invita, la otra advierte. En todos los casos arranca apagado y decide el usuario.

Todos los estados nuevos —*escuchando*, *finalizando*, pausa, progreso de
instalación— cumplen contraste AA sobre el fondo del panel. No es un recordatorio
genérico: `.tertiary` y `.secondary` de SwiftUI **no lo cumplen** ahí (G1 de la
auditoría de 2026-08-09, medido en las cuatro apariencias), y «Aumentar contraste»
los empeora. Se componen sobre `labelColor` con opacidad medida, como el resto.

---

## 6. La medición: medir, no adivinar

Una tabla de chips y RAM envejece mal, ignora la presión de memoria y la térmica, y
es adivinar. Lo que encaja con la casa es medirlo:
`TextRecognizer.systemPreferredLanguages()` ya cruza las preferencias del usuario
con lo que Vision admite **de verdad** en lugar de fijar una lista.

El equivalente aquí es transcribir una muestra corta del bundle y medir el
**factor de tiempo real** — cuántos segundos de cómputo cuesta cada segundo de
audio.

- **Los umbrales se calibran midiendo en máquinas reales**, no se inventan.
- **La medición no ocurre en el primer arranque de la app.** Ocurre en Ajustes,
  cuando el usuario va a activar la función, con un botón explícito.
- **La medición informa y preselecciona; no impone.**
- Se guarda con el identificador de máquina y versión del sistema, y se repite si
  cambian.

### 6.1 Estado real: la medición está cableada; la degradación en caliente no

`CapabilityProbe` **tiene consumidor**: Ajustes ofrece un botón que sintetiza un
audio de referencia con las voces del sistema, lo transcribe por el carril de
fichero y guarda la medida (`Settings.capabilityMeasurement`), sellada con el
modelo de máquina y la versión del sistema — una medida hecha en un Mac potente no
viaja en una copia de seguridad a uno lento. De ahí sale `Capability`, y de ahí el
modo sugerido. Sin medida válida, `.unmeasured` propone **diferido**, que es el que
funciona en cualquier máquina.

Lo que sigue faltando, y sigue siendo la intención:

- **Degradar en caliente**: observar durante la sesión si el análisis sigue al
  habla y caer a diferido diciéndolo. Una medida estática no captura la presión de
  memoria ni el estado térmico del momento, así que la preselección no puede ser la
  única defensa.

Hasta que exista, la protección es doble: sin medir se propone el modo que no
depende del rendimiento, y la medida caduca al cambiar de máquina o de sistema.

---

## 7. Los dos modos

**En vivo**: el texto aparece y se refina mientras se habla. **Diferido**: se graba
y el texto llega al final. La diferencia es **solo si se ve el texto mientras se
habla**, no dos mecanismos de pegado distintos.

**El modo con el que se estrena la función es el diferido**, no el en vivo: es lo
que §6.1 llama la protección real mientras no exista la medición, porque funciona en
cualquier máquina. Se aplica al activar y deja de aplicarse en cuanto el usuario
elige, para no pisar su decisión. (La revisión 1 decía «en vivo (predeterminado)» y
se contradecía con §6.1.)

### 7.1 El texto se refina en el panel de Ámbar, nunca en la app de destino

Una lectura de «en vivo» sería inyectar el texto en el campo de destino carácter a
carácter. **Es una trampa**: el transcriptor emite resultados volátiles y corrige
palabras que ya había dado — «cita» se convierte en «cinta» tres palabras después.
Si eso ya está escrito en la app ajena, corregirlo obliga a borrar y reescribir
texto que no se controla, con `CGEvent.post`, en un campo cuyo comportamiento se
desconoce.

El texto se refina **dentro del panel**, donde cambiar no tiene consecuencias, y
al final se hace **un solo pegado** con el `Paster` ya probado.

### 7.2 Al parar, el texto todavía no es final

La finalización es una fase asíncrona **posterior** al fin del audio: el módulo
expone `volatileRange`, cada `Result` trae su `resultsFinalizationTime` y su `isFinal`
—propiedad de extensión, no de la declaración del protocolo—, y el analizador tiene
`finalizeAndFinishThroughEndOfInput()`.

Pegar en el instante en que el usuario para sería pegar texto volátil — el mismo fallo
que evita §7.1, movido de sitio. Por tanto hay un estado **finalizando** entre parar y
pegar:

1. Parar → `finalizeAndFinishThroughEndOfInput()`.
2. Estado *finalizando* visible, con **techo de espera**.
3. Al vencer el techo, se pega lo que haya y se dice que se ha hecho.

El patrón ya existe en la casa: `returnFocusToPreviousApplication` espera hasta
500 ms sondeando en lugar de dormir un tiempo fijo, con el razonamiento escrito al
lado (`PanelController.returnFocusToPreviousApplication`).

### 7.3 Techo de duración, porque el detector de voz no encaja

La idea era usar `SpeechDetector` para cerrar la sesión al dejar de hablar. **No se
usa**, y el motivo hay que decirlo con precisión, porque este párrafo ya se ha
equivocado dos veces:

- En el `.swiftinterface` del SDK 26.0, `SpeechDetector` se declara `final public class`
  **sin la conformidad a `SpeechModule` escrita en la declaración**, al contrario que los
  dos transcriptores. Es un hecho verificable en el fichero.
- Pero **en tiempo de ejecución sí conforma**: una sonda contra el framework midió
  `detector as Any as? any SpeechModule` distinto de `nil`. La revisión 2 afirmaba lo
  contrario como hecho medido, y era falso.

Lo que queda en pie es la consecuencia práctica: apoyarse en una conformidad que el
interface no declara es construir sobre algo que el SDK no promete y que un punto de
versión puede retirar sin romper la compilación de nadie. Se descarta por eso, no porque
sea imposible.

Lo que sí hay es un **techo duro de duración de sesión**, hoy de **treinta minutos**.

Nació en dos minutos, y el número era correcto para el gesto de entonces: con «mantener
mientras hablas», lo que había que acotar era una tecla enclavada —*Sticky Keys*, un teclado
que reporta un modificador hundido— manteniendo el micrófono abierto sin que nadie lo
pidiera.

Cuando el gesto pasó a solo arrancar (§8.4.bis), ese riesgo desapareció y el techo cambió de
naturaleza: dejó de acotar un accidente para **cortar el uso normal**, porque dictar una
conversación pasa de dos minutos con facilidad. Y cortaba descartando, o sea castigando a
quien más había dictado. Treinta minutos lo devuelven a lo que debe ser: una red de último
recurso para el panel olvidado, no un límite que se toque al usar la función.

**Al vencer se descarta lo dictado, y se dice.** La revisión 1 decía lo contrario —«se
entrega; no se descarta»— y era una contradicción con el propósito del techo: existe para
cuando **nadie quiso dictar**, así que entregar convierte la red de seguridad en el peor
resultado posible del producto, que es pegar media hora de conversación ajena en el documento
del usuario. La sesión borra el texto al cerrarse y `finish()` responde con un fallo, no con
una entrega vacía —que se traduciría a «no se oyó nada» y culparía al usuario.

Y hay una segunda salida, más directa: mientras se escucha, la banda muestra un
botón de parar (§8.5).

---

## 8. El gesto

**El atajo del historial abre el panel exactamente como hoy** — mismo frame, misma
latencia. **Si la combinación se sigue manteniendo**, el panel transita de su uso
principal a *escuchando*.

### 8.1 Por qué así y no con un modificador extra

Se consideró un atajo separado. Pierde en **descubribilidad**: un modificador
extra no se descubre nunca sin documentación, y una transición que empieza delante
de los ojos se enseña sola. Y este diseño **no cuesta latencia**: el panel no
espera a nada para aparecer.

### 8.2 La detección no necesita permisos nuevos — pero la máscara se deriva del atajo

`HotKeyCenter` registra solo `kEventHotKeyPressed`
(`packages/AppCore/HotKey.swift`), y ese archivo explica por qué usa Carbon:

> «a diferencia de `CGEventTap` o de los monitores globales de `NSEvent`, **no
> requiere permiso de accesibilidad**.»

Detectar el mantenido **globalmente** exigiría un event tap, y con él
Accessibility. Al abrir el panel primero, la detección ocurre dentro del propio
proceso, y basta consultar `NSEvent.modifierFlags`, cuya cabecera dice:

> «modifier keys currently down. This returns the state of devices combined with
> synthesized events at the moment, **independent of which events have been
> delivered via the event stream**.» — `AppKit/NSEvent.h:525`

Es decir: no depende del foco ni de recibir eventos, y no pide permisos. **No es
una técnica a confirmar: ya está en producción en este binario** —
`Paster.waitForModifiersToClear` la usa con sondeo de 15 ms y techo
(`Paster.waitForModifiersToClear`).

**La máscara a vigilar se deriva del `KeyCombination` registrado**, nunca de una
constante. El atajo es configurable y el grabador acepta cualquier combinación con
al menos uno de ⌘/⌃/⌥ (`ShortcutRecorder.validate`); fijar ⇧⌘ dejaría el gesto sin
disparar para quien usa, por ejemplo, ⌃⌘V.

**La detección es sondeo a 40 ms, no un monitor de eventos.** La revisión 1 decía
preferir un monitor local de `.flagsChanged` «con el sondeo como red de seguridad», y
eso no se construyó: describir un mecanismo que no existe es peor que no tenerlo.

Sigue siendo lo correcto por energía, y queda pendiente **para la cuenta**, que es lo único
que sondea ahora: medio segundo a 25 Hz con el panel delante.

La parte cara —sondear durante toda la escucha— ya no existe: desapareció con el cambio de
§8.4.bis, porque soltar dejó de significar nada una vez abierto el micrófono. Es el ejemplo
más limpio de la jornada de que un cambio de producto puede cerrar una deuda técnica que
tres rondas de auditoría solo habían sabido anotar.

### 8.3 La colisión real es el escaneo visual

El riesgo no es «mantener por inercia»: el uso normal es atajo → mirar la lista →
Enter, y **mucha gente no suelta la tecla mientras el ojo busca**. Ese escaneo dura
fácilmente medio segundo, justo en el flujo más común.

**Mitigación: cualquier interacción cancela la cuenta.** Mover el ratón, escribir
en el buscador, pulsar una flecha o girar el scroll la aborta. Quien busca algo
*hace* algo; quien quiere dictar se queda quieto.

Ojo con el alcance: lo que se cancela es **la cuenta**, no una sesión ya abierta. Con el
micrófono en marcha, mover el ratón o teclear no corta nada — solo lo hace cerrar el panel,
que no puede dejar el micrófono abierto sin nada en pantalla.

### 8.4 El umbral es un valor propio; la animación solo lo representa

`GlassUI/AccessibilityPreferences.swift` ya suprime animaciones cuando el usuario
activa Reduce Motion, y el panel lo respeta (`ContentView`, guard sobre `accessibility.reduceMotion`). Si el
mecanismo que explica el gesto fuera la animación, con Reduce Motion el dictado se
dispararía sin aviso: el gesto pasaría de autoexplicativo a secreto justo para
quien más necesita previsibilidad.

Por tanto **el umbral se define como valor propio**, y hay dos representaciones:

| Preferencia | Realimentación |
|---|---|
| Normal | Transición animada de uso principal a *escuchando* |
| Reduce Motion | Progresión **por pasos discretos**, sin movimiento (relleno escalonado, cambio de etiqueta) |

En ambos casos la realimentación aparece **antes de que el micrófono se abra**, para que
soltar sea siempre una salida a tiempo.

> **Revisión 3.** Esto decía «en el primer instante de la cuenta» y el código no lo cumple:
> la banda y el anuncio salen al 33 % del umbral, unos 200 ms de los 550. No es un descuido
> — con realimentación desde el primer tic, **cada apertura del historial por atajo
> parpadeaba una banda**, que es la acción más frecuente de la app. Quedan 350 ms para
> soltar, que es lo que la promesa pretendía proteger.

### 8.4.bis Mantener arranca; no hay que sostener

**Soltar el atajo no para el dictado.** El gesto sirve para arrancar y a partir de ahí las
manos quedan libres: se para con **⏎**, con el botón de la banda o con **⌘D**.

La revisión 1 decía «mantener mientras hablas», y el uso real lo desmintió: dictar una
conversación obligaba a sostener tres teclas varios minutos, y cualquier resbalón la cortaba
a mitad. El modelo actual conserva lo que el gesto aportaba —arrancar sin tocar nada, desde
el atajo que ya se usa— y quita lo que costaba.

Dos consecuencias que van con ello:

- **Se acabó el sondeo del teclado durante la escucha.** Era 25 Hz durante toda la sesión, y
  la mayor deuda de energía de la función. Ya no hace falta saber si se sigue pulsando.
- **El techo de sesión sube a treinta minutos** (§7.3). Con el gesto anterior, dos minutos
  acotaban el accidente de una tecla enclavada; sin tecla que sostener, ese techo pasó a
  cortar —y descartar— justo a quien más había dictado.

### 8.5 Alternativas para quien no puede mantener

Los gestos temporizados son hostiles para quien tiene temblor o usa *Slow Keys* /
*Sticky Keys*. Con el panel abierto, el modo dictado se alcanza también con un clic
en el micrófono o con una tecla del propio panel — sin atajo global. Ahí mismo
viven el interruptor del historial y el selector de modo.

El interruptor de Ajustes «Disparar manteniendo el atajo» nace **apagado** si
*Teclas Especiales* ya está activo al primer arranque — con los modificadores
enclavados por el sistema, el vigilante del mantenido no puede distinguir «lo
sigo pulsando» de «lo enclavé y solté», y armaría en cada apertura del panel.

Eso solo resuelve el arranque. Ámbar es un agente de barra de menús que vive
semanas abierto, y *Teclas Especiales* se activa con un atajo del sistema —pulsar
⇧ cinco veces— fácil de disparar sin querer en cualquier momento. Por eso la
comprobación **no se queda en el valor por defecto**: `PanelController.armsGesture`
consulta `StickyKeys.isEnabled` en vivo, en cada apertura del panel, y desarma el
gesto mientras esté activo — independientemente de lo que diga el interruptor
guardado. Es la única de las condiciones de armado que no depende de un ajuste de
Ámbar sino de un ajuste del sistema que puede cambiar en cualquier instante.

---

## 9. Destino del texto

Al finalizar (§7.2):

1. Se pega en la app que estaba delante con `Paster`.
2. Entra al historial **si la captura no está pausada y el destino no está excluido**
   (§10). Con destino desconocido tampoco se archiva: se elige el lado que no deja
   rastro. Y en esos casos el texto va al portapapeles marcado como sensible, para que
   ningún otro gestor lo archive.

> La revisión 1 decía «si hay un campo con foco se pega ahí» y «si no, se queda solo en
> el historial». **No hay detección de foco**, y añadirla exigiría consultar el elemento
> enfocado por accesibilidad en cada dictado. El comportamiento real es el de pegar en
> la app de destino, como al pegar del historial; y la primera versión de §9 además
> contradecía a §10 al decir «en todo caso».

### 9.1 Qué se conserva del resultado y qué se descarta

El transcriptor no devuelve una cadena: devuelve un `AttributedString` con
`transcriptionConfidence` y `audioTimeRange` por fragmento
(`AttributeScopes.SpeechAttributes`). Ámbar es precisamente una app que conserva
**todas** las representaciones de lo que pasa por ella, así que la decisión hay
que tomarla, no heredarla por descuido:

- **Al pegar y al historial va texto plano.** Los atributos no son formato: son
  metadatos del reconocimiento, y no significan nada en la app de destino.
- **La confianza no se usa, y ya no se pide.** La intención era atenuar en el panel
  lo que aún es dudoso; para eso no hace falta la confianza, y sí hay con qué.
  **Corrección de esta afirmación**: la revisión anterior decía que `SpeechModuleResult`
  «solo expone `range` y `resultsFinalizationTime` —no hay `isFinal`—» y que ese segundo
  valor «se midió siempre a 0». Las dos cosas son **falsas**, medidas contra el
  framework: `isFinal` existe como propiedad de **extensión** (`Speech.swiftinterface`,
  líneas 383-387) y el motor la reporta; de once resultados de una frase, diez llegan
  volátiles y el último con `isFinal = true` y `resultsFinalizationTime` igual al final
  del rango. El error de la primera versión fue leer solo la declaración del protocolo.

  Lo que se hace con eso: el texto volátil se pinta **atenuado** y pasa a pleno cuando
  el motor lo da por firme. La confianza sigue sin pedirse, porque no aporta nada por
  encima de esa distinción.
- **El rango temporal se descarta**, porque el audio no se guarda (§10) y sin audio
  no hay nada a lo que apuntar.

### 9.2 El pegado hereda la dependencia de Accessibility

`Paster.canPaste` es `AXIsProcessTrusted()` (`Paster.canPaste`), y sin ese permiso
`pasteToFrontmostApp()` devuelve `false`. Que el dictado no añada Accessibility es
cierto para **detectar el gesto**; no lo es para **entregar el resultado**.

Sin el permiso, el dictado transcribe y el texto queda en el historial, avisando
con el mecanismo que ya existe (`model.flagMissingPastePermission()`), nunca
fallando en silencio.

---

## 10. Privacidad

**Las transcripciones entran en el historial.** Todo lo que pasa por el conducto se
puede recuperar y buscar. Para los momentos sin rastro, la respuesta no es un modo
efímero por elemento sino **pausar el historial completo**.

- **La pausa tiene duración explícita** (15 min / 1 hora / hasta reactivar). Una
  pausa indefinida falla de dos formas simétricas: se olvida y se pierden semanas
  de historial, o se cree activa cuando ya no lo está.
- **El indicador se ve siempre** que el panel esté abierto, y también en el icono
  de la barra de menús.
- **En pausa el dictado sigue funcionando**: transcribe y pega, no guarda.
- El control vive en el panel, visible — no enterrado en Ajustes.

**El audio no se guarda**, solo la transcripción. Se mantiene la lista negra por
*bundle ID* que ya existe.

### 10.1 «Escuchando» debe verse en la barra de menús

Ámbar es un agente sin icono en el Dock (`LSUIElement`) cuyo panel no activa la
app (`.nonactivatingPanel`, `canBecomeMain = false`). Si enciende el micrófono, el
indicador del sistema apunta a una app que el usuario no puede localizar por los
medios habituales.

El estado *escuchando* se refleja por tanto **en el icono de la barra de menús**,
que es la única presencia permanente de la app, y no solo dentro del panel.

---

## 11. Idiomas

**Los diez idiomas de la interfaz están cubiertos.** Medido contra el SDK 26.0:
el transcriptor admite 54 locales, y `supportedLocale(equivalentTo:)` resuelve
correctamente los diez de `CFBundleLocalizations` — incluidos los dos casos donde
un cruce por prefijo sería una lotería: `zh-Hans → zh_CN` (y no zh_HK ni zh_TW) y
`pt-BR → pt_BR` (y no pt_PT). Fijado en un test.

El estado `unsupported` sigue siendo real para **otros** idiomas del sistema: el
euskera y el gallego, por ejemplo, no están entre los 54. Quien tenga el sistema
en uno de ellos verá el dictado no disponible, y hay que decírselo con claridad.

La resolución usa la **API oficial**, no un cruce artesanal de prefijos:
`DictationTranscriber.supportedLocale(equivalentTo:)` sobre
`Locale.preferredLanguages`, con `supportedLocales` e `installedLocales` para el
estado.

### 11.1 Los locales se reservan, hay cupo, y hay que liberarlos

`AssetInventory` expone `maximumReservedLocales` —**cinco** en macOS 26.0, medido—,
`reservedLocales`, `reserve(locale:)` y `release(reservedLocale:)`. Los idiomas no
son descargas acumulables sin más.

Y hay dos comportamientos medidos que no se deducen de la firma:

- **La reserva es lo que pone el modelo a disposición de la app.** Con `es_ES` ya
  presente en `installedLocales`, `AssetInventory.status(forModules:)` seguía
  respondiendo `supported` —«hay que instalar»— hasta reservar; después pasaba a
  `installed`. Consultar el estado sin reservar antes le anuncia una descarga a
  quien ya tiene el modelo.
- **`reserve` devuelve `false` también cuando el idioma ya estaba reservado por
  este proceso**, no solo cuando el cupo está lleno. Tratar ese `false` como cupo
  lleno rompe el segundo dictado seguido del mismo idioma. Hay que distinguirlo
  consultando `reservedLocales`.
- La reserva **es por proceso**: al terminar la app se libera sola.

Política: se reserva el locale en uso; se libera al terminar la sesión, pero solo
si fue esta sesión la que reservó; cuando el cupo está lleno se dice qué liberar en
lugar de fallar con un error que el usuario no puede interpretar.

> **Gotcha conocido**: los textos llevarán números interpolados (segundos, ratios,
> megas). Hay que declarar el formato en los `.strings` (`%lld`, `%@`) o la clave
> cae al `defaultValue` —que está en español— y la interfaz inglesa se queda a
> medias sin avisar.

---

## 12. Concurrencia

El diseño cruza tres dominios de aislamiento y hay que declarar el puente, porque
el compilador no protege aquí: `AnalyzerInput` es `@unchecked Sendable`.

| Dominio | Qué vive ahí |
|---|---|
| Hilo de audio (tiempo real) | El tap de `AVAudioEngine` |
| `actor SpeechAnalyzer` | El análisis y sus `results` |
| `@MainActor` | El panel (`PanelController`) y el historial |

Contrato:

1. El tap hace **solo** convertir, envolver en `AnalyzerInput` y encolar. Conviene
   ser preciso: convertir asigna un buffer de salida por callback, y eso ocurre en
   el hilo de tiempo real. Es lo que hace el patrón de Apple para alimentar al
   analizador, y evitarlo exigiría reciclar buffers cuya vida la controla el
   analizador de forma asíncrona — se cambiaría una asignación por una corrupción
   de datos. Lo que sí está prohibido, y no ocurre: E/S, esperas, análisis o
   interfaz dentro del tap.
2. La cola es un `AsyncStream` de **capacidad acotada con política de descarte
   declarada** — bajo presión se pierde audio antiguo, nunca se bloquea el hilo de
   audio ni se acumula sin techo.
3. Los `results` se consumen en el módulo y se publican al `@MainActor` en **una
   sola frontera**.
4. **Los `@unchecked Sendable` propios se cuentan, y en el dictado son tres.** La revisión 1
decía «cero», y era una regla que el código no cumplía: `ResumeLatch` y `AudioSampleWriter`
(la sonda de capacidad) y `SequenceClock` (el reloj del tap) — más `Store`, que es anterior
al dictado y tiene su propia serialización. Los tres del dictado cruzan la **misma**
frontera y por la misma razón: `AVAudioNodeTapBlock` y el callback de `AVSpeechSynthesizer`
son bloques Obj-C **sin `@Sendable`**, así que nada de lo que capturan pasa por el
comprobador de aislamiento. El compilador no puede protegerlos, y por eso el aislamiento se
declara a mano con un `NSLock`.

La regla que sí se mantiene, y que es la que importa: **ninguno se usa para silenciar al
compilador donde el compilador sí podía razonar**. Cada uno lleva escrito qué garantiza el
cerrojo y por qué la frontera es opaca. Cualquier `@unchecked` nuevo fuera de esa frontera
es deuda y se bloquea.

Las dos salidas fáciles están prohibidas: bloquear el hilo principal esperando
resultados, y hacer en el tap cualquier trabajo que pueda esperar (E/S, análisis,
interfaz).

---

## 13. Lo que no entra

- **Inyectar el texto en el campo de destino mientras se habla** (§7.1).
- **Post-proceso con un LLM** (limpiar muletillas, formatear, traducir). Por API
  rompería el «todo local»; macOS 26 expone un modelo en el dispositivo, así que
  la puerta no queda cerrada. No es plan todavía.
- **API de transcripción remota** como opción por defecto.
- **Guardar el audio.**
- **`AnalysisContext.contextualStrings` alimentado con el historial.** Mejoraría el
  reconocimiento de nombres propios y jerga, pero mete contenido del portapapeles
  en el motor de voz: se decide mirando §10, no de pasada.

---

## 14. Tensiones abiertas

Tres, y las tres se resuelven midiendo:

1. **El umbral del gesto.** Demasiado corto pisa el escaneo visual; demasiado
   largo hace el dictado tedioso. Se ajusta con gente real, y la animación es su
   representación, no su definición (§8.4).
2. **La calidad del motor nativo** en español hablado rápido. Determina si
   whisper.cpp entra por detrás del protocolo (§2.2).
3. **El idioma multi**: si se detecta, se fija en Ajustes, o se cambia desde el
   panel — condicionado por el cupo de §11.1.

> La tensión «cuándo se abre el micrófono» de la revisión 1 **queda resuelta**: lo
> caro es cargar el modelo, no abrir el micrófono, y
> `prepareToAnalyze(in:withProgressReadyHandler:)` permite prepararlo **durante la
> transición sin tocar el micrófono**. El audio se abre solo al confirmar, y
> `ModelRetention.lingering` evita pagar la carga otra vez en el siguiente
> dictado. No era una decisión de producto: era una llamada a la API.

---

## 15. Impacto en el repositorio

| Zona | Cambio |
|---|---|
| `native/Package.swift` | Target `VoiceKit` + dependencia del ejecutable |
| `native/packages/VoiceKit/` | Protocolo del transcriptor, motor `DictationTranscriber`, estados (`AssetInventory`), medición, **puente de concurrencia**, **conversión de formato** |
| `native/packages/AppCore/HotKey.swift` | Sin cambios en Carbon. La máscara del gesto se deriva del `KeyCombination` |
| `native/apps/Ambar/PanelController.swift` | Transición a *escuchando*; cancelación por interacción; **`onResignKey` inhibido con sesión viva**; ⏎ y el atajo global paran la sesión; ⌘⌫ la descarta; el panel oculto sale de las capturas (`sharingType`) |
| `native/apps/Ambar/Views/` | Estados *escuchando* y *finalizando*, progresión sin animación, indicador de pausa, progreso de instalación |
| `native/apps/Ambar/AppDelegate.swift` | Estado *escuchando* en el icono de la barra de menús |
| `native/apps/Ambar/Settings.swift` | Activación, **petición de micrófono**, medición, modo, idioma |
| `native/apps/Ambar/Info.plist` | `NSMicrophoneUsageDescription` |
| `native/packages/ClipboardKit/` | Entrada de transcripciones al historial (reusa `Ingestor`) |
| Recursos `.lproj` × 10 | Textos nuevos, con formatos declarados |
| `native/apps/Ambar/AppModel.swift` | Coordinador del dictado, entrega al historial, reserva de idioma **recordada** para poder soltarla, oferta y medición |
| `native/Scripts/check-localization.sh` | Paridad de claves, plurales, **categorías CLDR**, especificadores **y su orden**, e `InfoPlist.strings` |
| `native/Tests/` | Estados, medición, cancelación del gesto, **máscara con atajos distintos**, finalización, acumulación del texto, presentación del panel, cableado del estado |

---

## 16. Referencias

- [`audit/ambar-dictado-2026-08-12.md`](audit/ambar-dictado-2026-08-12.md) — la
  auditoría que produjo esta revisión.
- [`architecture/native-platform.md`](architecture/native-platform.md) — el grafo
  nativo del monorepo.
- [`audit/ambar-2026-08-09.md`](audit/ambar-2026-08-09.md) — contraste, permisos de
  disco, firma.
- [`ambar-lanzamiento.md`](ambar-lanzamiento.md) — firma y notarización.
- `native/packages/ClipboardKit/TextRecognizer.swift` — «preguntar al sistema en
  vez de asumir».
- `native/packages/AppCore/HotKey.swift` — por qué Carbon y no un event tap.
- `native/packages/AppCore/Paster.swift` — `waitForModifiersToClear`, el precedente
  de §8.2.
