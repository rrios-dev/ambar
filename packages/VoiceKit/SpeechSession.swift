import AVFoundation
import CoreMedia
import Foundation
import Speech

/// Una sesión de dictado sobre el framework Speech.
///
/// Es un `actor` porque tiene que poseer en exclusiva cosas que no son
/// `Sendable`: el motor de audio, el convertidor de formato y el módulo de
/// transcripción. Todo eso queda dentro; lo que cruza la frontera son
/// `AnalyzerInput` (que Apple declara `Sendable`), `TranscriptFragment` y
/// `Transcript`. Así no hace falta ni un `@unchecked Sendable` propio.
///
/// El reparto de responsabilidades entre los tres pasos no es estético:
///
/// - `prepare()` carga el modelo. Es la parte cara y **no toca el micrófono**.
/// - `start()` abre la entrada de audio. Es el único punto que enciende el
///   indicador del sistema.
/// - `finish()` añade la cola de silencio y espera la finalización.
public actor SpeechSession: TranscriptionSession {
    private let locale: Locale
    private let mode: DictationMode
    private let catalog: any ModelCatalog
    private let sourceKind: SourceKind

    /// De dónde sale el audio de esta sesión.
    public enum SourceKind: Sendable, Equatable {
        case microphone
        case file(URL)
    }

    /// El bloque de silencio de cierre, **ya sellado** al final de la secuencia.
    ///
    /// Junto —el bloque y su marca— y no como dos argumentos en el sitio de encolado,
    /// porque la marca no tenía red: sustituirla por `nil` dejaba la suite entera en verde
    /// y el silencio se colocaba al PRINCIPIO de la secuencia, compitiendo con la primera
    /// palabra en vez de cerrando la última. Con la marca dentro de la función hay algo a
    /// lo que un test pueda preguntar.
    func silenceInput(in format: AVAudioFormat) -> AnalyzerInput? {
        guard let silence = silenceTail(in: format) else { return nil }
        return AnalyzerInput(buffer: silence, bufferStartTime: source?.sequenceEnd)
    }

    /// Cuánto silencio se añade al soltar, antes de finalizar.
    ///
    /// Se mantiene porque **sin ella el resultado es inconsistente**, que es una
    /// razón más fuerte que «siempre falla».
    ///
    /// Hicieron falta tres mediciones y salieron tres conclusiones distintas: un
    /// sondeo que no esperaba la finalización dijo que sin cola se perdía la última
    /// palabra (falso: lo que faltaba era `finalizeAndFinishThroughEndOfInput()`);
    /// luego dos frases cortas sobrevivieron sin cola y se escribió que la cola no
    /// aportaba nada; después un auditor midió «…con Amb» con una frase larga, y al
    /// repetirlo aquí con esa misma frase llegó completa.
    ///
    /// Con el mismo audio y el mismo camino, el caso sin cola a veces conserva la
    /// última palabra y a veces no. Medio segundo de silencio cuesta nada y quita la
    /// lotería. La lección no es sobre audio: una muestra de dos casos no sostiene un
    /// invariante, y un test que afirma el contrafáctico con esa muestra es peor que
    /// no tener test, porque convierte la regresión en comportamiento esperado.
    public static let defaultSilenceTailSeconds: Double = 0.6

    /// Cola de silencio de esta sesión. Configurable para poder medir en un test
    /// qué aporta de verdad; en producción se usa el valor por defecto.
    private let silenceTailSeconds: Double

    // Todo lo de abajo es estado confinado al actor.
    private var transcriber: DictationTranscriber?
    private var sessionLimitTask: Task<Void, Never>?
    private var analyzer: SpeechAnalyzer?
    private var source: (any AudioSource)?
    private var targetFormat: AVAudioFormat?
    private var feed: AsyncStream<AnalyzerInput>.Continuation?
    private var forwardTask: Task<Void, Never>?
    private var resultsTask: Task<Void, Never>?
    private var fragments: AsyncStream<TranscriptFragment>.Continuation?

    /// Último texto visto. Los resultados del motor son **acumulativos** —cada
    /// uno trae la frase entera hasta ese instante, no un trozo nuevo— así que el
    /// resultado de la sesión es el último que llegó, no una concatenación.
    /// Medido: 13 resultados para una frase de 3,2 s, todos con el mismo rango
    /// `[0, 3.21]` y texto creciente.
    private var latestText: String = ""
    private var sawFinalResult = false

    /// ¿Reservó **esta** sesión el idioma? Si ya estaba reservado por otra parte
    /// de la app, no se lo quitamos al terminar.
    private var didReserve = false

    /// Generación de la sesión, para detectar que la han cancelado mientras
    /// estábamos suspendidos.
    ///
    /// `prepare()` tiene siete puntos de suspensión, y `cancel()` puede ejecutar
    /// `teardown()` en cualquiera de ellos. Sin este contador, `prepare()` reanudaba
    /// y reasignaba analizador, transcriptor y `didReserve = true` sobre una sesión
    /// que ya nadie sostenía: nadie volvía a llamar a `release` y **se fugaba una de
    /// las cinco ranuras de idioma del sistema**. Reproducido cancelando justo tras
    /// arrancar `prepare()`, que es lo que ocurre en cada apertura de panel en la
    /// que no se mantiene el atajo.
    private var generation = 0

    /// Una sesión cancelada está **muerta**, no en reposo.
    ///
    /// El contador de generación no basta: si `cancel()` entra al actor *antes* de
    /// que `prepare()` haya empezado, `prepare()` se ejecuta después de cero a fin
    /// y reserva el idioma para una sesión que ya nadie sostiene. Lo comprobó un
    /// test, no una lectura del código. Con esta bandera, cancelar es terminal —que
    /// es además la semántica real: el controlador crea una sesión nueva por gesto.
    private var isCancelled = false

    private var onDeviceChange: (@Sendable () -> Void)?
    private var onSessionLimit: (@Sendable () -> Void)?

    public init(
        locale: Locale,
        mode: DictationMode,
        source: SourceKind = .microphone,
        catalog: (any ModelCatalog)? = nil,
        silenceTailSeconds: Double = SpeechSession.defaultSilenceTailSeconds,
        maximumSessionDuration: Duration = SpeechSession.defaultMaximumSessionDuration,
        atypicalSpeech: Bool = false,
        contextualStrings: [String] = []
    ) {
        self.maximumSessionDuration = maximumSessionDuration
        self.locale = locale
        self.mode = mode
        self.sourceKind = source
        self.catalog = catalog ?? SpeechModelCatalog(mode: mode)
        self.silenceTailSeconds = silenceTailSeconds
        self.atypicalSpeech = atypicalSpeech
        self.contextualStrings = contextualStrings
    }

    /// Pista de accesibilidad para habla atípica. Ver `SpeechTranscriberFactory.preset`.
    private let atypicalSpeech: Bool

    /// Words the engine should recognize even though the system vocabulary lacks them.
    private let contextualStrings: [String]

    /// The documented ceiling for contextual strings, across all tags.
    ///
    /// Apple's guidance for `AnalysisContext.contextualStrings`: "Limit the total number
    /// of phrases across all tags to no more than 100." The cap is enforced here — the
    /// last place the list passes through before reaching the framework — and not only
    /// upstream, because every future caller of this session would otherwise have to
    /// know about it, and the failure mode of exceeding it is undefined by the docs.
    public static let contextualStringsLimit = 100

    /// The analysis context that biases the engine, or `nil` when there is nothing to say.
    ///
    /// Extracted so a test can assert the shape without a live engine: the tag must be
    /// `.general` — a custom tag also works, but `.general` is the one the framework
    /// pre-declares for exactly this use — blank entries must not travel (the engine
    /// would try to estimate a pronunciation for whitespace), and the documented cap
    /// of 100 phrases is applied after filtering, so a caller with 100 valid terms and
    /// some blanks does not lose valid ones to the trim.
    nonisolated static func analysisContext(biasing strings: [String]) -> AnalysisContext? {
        let phrases = strings
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !phrases.isEmpty else { return nil }
        let context = AnalysisContext()
        context.contextualStrings = [.general: Array(phrases.prefix(Self.contextualStringsLimit))]
        return context
    }

    // MARK: - Preparar (sin micrófono)

    /// El idioma **ya resuelto** para esta sesión.
    ///
    /// Se resuelve **una vez** y se reutiliza, y esto no es una optimización: medido contra
    /// el framework, `supportedLocale(equivalentTo:)` **no es determinista** cuando el
    /// idioma pedido no tiene coincidencia exacta entre los admitidos. `de_ES` devuelve
    /// `de_AT`, `de_CH` o `de_DE` en llamadas distintas **del mismo proceso** — el caso
    /// natural de una app en diez idiomas, donde el idioma y la región no coinciden.
    ///
    /// `prepare()` resolvía por su cuenta en cuatro sitios: al comprobar la reserva, al
    /// reservar, en su propia guarda y al soltar. Reservar `de_CH` y soltar `de_AT` fuga una
    /// de las cinco ranuras de idioma de toda la máquina; consultar la disponibilidad de una
    /// variante distinta de la que se va a usar produce «falta el modelo de voz» a quien lo
    /// tiene instalado. Invisible en la máquina de quien lo desarrolla, donde `es_ES` casa
    /// exacto.
    private var resolvedLocale: Locale?

    /// Resuelve una vez y recuerda.
    private func resolveLocaleOnce() async -> Locale? {
        if let resolvedLocale { return resolvedLocale }
        let resolved = await catalog.supportedLocale(equivalentTo: locale)
        resolvedLocale = resolved
        return resolved
    }

    /// Whether the model for `locale` is installed, asked again after reserving once
    /// more when the first answer is "not installed".
    ///
    /// The status is per app and tied to the reservation, and the reservation is a
    /// single app-wide flag, not a count. Anything that releases it between our
    /// `reserve` and this question — another Ámbar process sweeping at launch, an older
    /// session tearing down — makes an installed model read as `supported` for that
    /// instant. Measured on 2026-10-01: the model installed, the probe preparing three
    /// sessions in a row without a failure, and the running app still answering "Falta
    /// el modelo de voz" after other instances had launched. Failing on the first
    /// answer turned a passing race into a red banner the user could not fix, because
    /// there was nothing to install.
    ///
    /// Only `supported` and `downloading` are retried. `unsupported` is final, and
    /// `installed` is the answer. A model that is really missing costs `attempts - 1`
    /// short pauses before the same error as before.
    static func confirmInstalled(
        locale: Locale,
        in catalog: any ModelCatalog,
        attempts: Int = 3,
        pause: Duration = .milliseconds(150)
    ) async -> Bool {
        for attempt in 1...max(attempts, 1) {
            switch await catalog.availability(forLocale: locale) {
            case .installed:
                return true
            case .unsupported:
                return false
            case .supported, .downloading:
                guard attempt < attempts else { return false }
                _ = try? await catalog.reserve(locale: locale)
                try? await Task.sleep(for: pause)
            }
        }
        return false
    }

    public func prepare() async throws {
        guard !isCancelled else { throw CancellationError() }
        generation += 1
        let currentGeneration = generation
        // Reservar ANTES de consultar: sin la reserva el estado miente y dice
        // que hay que instalar un modelo que ya está en la máquina.
        //
        // Cuidado con el valor de retorno: `reserve` devuelve `false` **también
        // cuando el idioma ya estaba reservado por este proceso** (medido en
        // macOS 26.0), no solo cuando el cupo está lleno. Tratar ese `false` como
        // «cupo lleno» rompe el segundo dictado seguido del mismo idioma.
        // `reserve` devuelve `false` tanto si el cupo está lleno como si el idioma ya
        // estaba reservado —y algo tan inocente como consultar el peso del modelo lo
        // reserva de paso—. Así que la propiedad se decide comparando el inventario
        // antes y después: con el booleano, `didReserve` quedaba en `false` y la
        // reserva se quedaba colgada mientras la app viviera.
        // Todo el ciclo de la reserva habla del **mismo** idioma resuelto.
        let target = await resolveLocaleOnce() ?? locale
        let reserved = try await catalog.reserve(locale: target)
        // Si nos han cancelado mientras reservábamos, se suelta aquí mismo y no se
        // toca nada más: el estado de la sesión ya no es nuestro.
        guard currentGeneration == generation else {
            if reserved { await catalog.release(locale: target) }
            throw CancellationError()
        }
        // Si `reserve` volvió sin lanzar, la reserva **existe**: o la acabamos de tomar
        // (`true`) o este proceso ya la tenía (`false`). Medido en macOS 26.0 caso por
        // caso: el cupo lleno no devuelve `false`, **lanza** `SFSpeechErrorDomain` 11, y
        // eso llega aquí ya traducido a `reservationQuotaExceeded` desde el catálogo.
        //
        // Antes se leía al revés: el `false` se tomaba por «cupo lleno» y se emitía el
        // aviso de «no caben más idiomas» —mandando a Ajustes del Sistema— justo cuando
        // la reserva ya era nuestra y no había nada que arreglar. Con el cupo de verdad
        // lleno, en cambio, el error caía en el `default` del traductor y salía como
        // «algo ha fallado». Los dos casos, cruzados.
        //
        // Se suelta al terminar en ambos: quien deja de dictar no debe quedarse una de
        // las cinco ranuras de la máquina, y el «dueño previo» que se consultaba antes es,
        // en la práctica, esta misma app.
        didReserve = true
        // A partir de aquí cualquier salida por error tiene que soltar la reserva: los
        // cuatro `throw` de abajo la fugaban, y cada fuga se come una de las cinco
        // ranuras de idioma del sistema. Los cuatro pasan por `releaseAndThrow`, así
        // que hay UN sitio donde la garantía puede tener un test directo —ver
        // `ReleaseAndThrowTests`— en vez de depender de reproducir cada disparador real
        // (dos de los cuatro necesitan que el framework de Speech falle de una forma
        // concreta —formato incompatible, o que `prepareToAnalyze` rechace un modelo—
        // que no se puede forzar sin arriesgar comportamiento no determinista del
        // propio framework, como una descarga de modelo no pedida).
        guard let resolved = await resolveLocaleOnce() else {
            try await releaseAndThrow(DictationEngineError.localeUnsupported)
        }
        guard await Self.confirmInstalled(locale: resolved, in: catalog) else {
            try await releaseAndThrow(DictationEngineError.modelNotInstalled)
        }

        let module = SpeechTranscriberFactory.make(
            locale: resolved,
            mode: mode,
            atypicalSpeech: atypicalSpeech
        )
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(
            compatibleWith: [module]
        ) else {
            try await releaseAndThrow(DictationEngineError.incompatibleAudioFormat)
        }

        let analyzer = SpeechAnalyzer(
            modules: [module],
            options: SpeechAnalyzer.Options(
                priority: .userInitiated,
                // `lingering` mantiene el modelo cargado un rato tras terminar:
                // el segundo dictado seguido no vuelve a pagar la carga, que es
                // justo lo que hace que el gesto se sienta inmediato.
                modelRetention: .lingering
            )
        )

        // Bias the engine towards the user's own vocabulary BEFORE any audio flows.
        //
        // Best-effort by design (`try?`): the bias improves recognition of taught
        // terms, but a rejected context must never cost the dictation itself — the
        // deterministic replacement layer in the app still corrects what the engine
        // gets wrong, so losing the bias degrades quality, not function.
        if let context = Self.analysisContext(biasing: contextualStrings) {
            try? await analyzer.setContext(context)
        }

        // Esto es lo caro, y aquí no hay micrófono abierto todavía. Ocurre
        // mientras el usuario mantiene el atajo.
        do {
            try await analyzer.prepareToAnalyze(in: format)
        } catch {
            await analyzer.cancelAndFinishNow()
            try await releaseAndThrow(error)
        }

        // Última comprobación antes de publicar el estado: entre la suspensión
        // anterior y esta línea la sesión puede haber sido cancelada.
        guard currentGeneration == generation else {
            await analyzer.cancelAndFinishNow()
            try await releaseAndThrow(CancellationError())
        }

        self.transcriber = module
        self.analyzer = analyzer
        self.targetFormat = format
    }

    /// Duración máxima de una sesión de dictado.
    ///
    /// **Treinta minutos**, y el número cambió cuando cambió el gesto. Con «mantener
    /// mientras hablas», dos minutos eran de sobra y acotaban el accidente de una tecla
    /// enclavada. Ahora el gesto solo arranca y las manos quedan libres —se para con ⏎ o con
    /// el botón—, así que ya no hay tecla que se pueda quedar hundida, y el caso real dejó de
    /// ser «una frase hacia un campo» para incluir conversaciones largas: con dos minutos, el
    /// techo cortaba y **descartaba** justo a quien más texto había dictado.
    ///
    /// Sigue habiendo techo porque el micrófono no puede quedarse abierto indefinidamente si
    /// alguien se olvida del panel, pero ahora es una red de último recurso y no un límite
    /// que se toca en el uso normal.
    public static let defaultMaximumSessionDuration: Duration = .seconds(30 * 60)

    /// Duración máxima de esta sesión. Inyectable para poder probar el cierre sin
    /// esperar media hora.
    private let maximumSessionDuration: Duration

    /// La sesión se cerró porque llegó a su duración máxima.
    private var closedByLimit = false

    /// Arranca el temporizador del techo sin abrir el micrófono. Solo para tests.
    ///
    /// Existe porque el techo —hoy de media hora; antes de dos minutos, cuando el gesto
    /// obligaba a mantener la tecla— solo se podía ejercitar con el motor real, y el CI se salta esos tests: borrar la tarea
    /// entera dejaba la integración continua en verde. Y sin el gate tampoco daba rojo:
    /// **colgaba**, que es peor, porque un cuelgue no se lee como regresión.
    func startSessionLimitForTesting(after duration: Duration) {
        sessionLimitTask = Task { [weak self] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled else { return }
            await self?.stopForLimit()
        }
    }

    /// Marca la reserva como nuestra y cierra la sesión. Solo para tests.
    ///
    /// La liberación de la ranura de idioma en `teardown()` también estaba solo cubierta por
    /// tests con motor: quitarla dejaba el CI en verde mientras se fugaba una de las cinco
    /// ranuras de toda la máquina por cada dictado.
    func markReservedAndTeardownForTesting() async {
        didReserve = true
        await teardown()
    }

    /// Fuerza el cierre por techo. Solo para tests: en producción lo dispara
    /// `sessionLimitTask`, y esperar media hora —o montar el motor real, que el CI se
    /// salta— dejaba sin cubrir que el techo BORRA lo dictado.
    func closeForLimitForTesting() async { await stopForLimit() }

    /// Instala una fuente de audio. Solo para tests: el final de la secuencia lo produce
    /// el reloj del hilo de audio, que no se puede adelantar desde fuera.
    func setSourceForTesting(_ source: any AudioSource) {
        self.source = source
    }

    /// Dispara un cambio de configuración real de AVFoundation en la fuente actual, si
    /// es un `MicrophoneSource`. Solo para tests: pasar la instancia sin más desde fuera
    /// del actor —para llamar a `postConfigurationChangeForTesting()` directamente—
    /// arriesgaba una carrera de datos que Swift 6 rechaza con razón; disparándolo desde
    /// aquí dentro, la fuente nunca sale del aislamiento del actor.
    func postConfigurationChangeForTesting() {
        (source as? MicrophoneSource)?.postConfigurationChangeForTesting()
    }

    /// Solo para tests: ejercita `releaseAndThrow` sin tener que reproducir un
    /// disparador real de `prepare()`. Es el código exacto que corren los cuatro
    /// `guard`/`catch` de `prepare()` — no una copia — así que un test aquí protege a
    /// los cuatro sitios de uso a la vez, incluidos los dos que dependen de que el
    /// framework de Speech falle de una forma que no se puede forzar sin riesgo (un
    /// formato incompatible, o que `prepareToAnalyze` rechace el modelo).
    func releaseAndThrowForTesting(_ error: Error) async throws {
        // Se reserva DE VERDAD contra el catálogo —no solo se pone la bandera— para que
        // el test pueda comprobar el efecto observable: si `releaseAndThrow` no suelta,
        // el catálogo se queda con la ranura tomada. Poner solo `didReserve = true` sin
        // tocar el catálogo dejaba la aserción del test comprobando un catálogo que
        // nunca había reservado nada, así que "no soltar" y "soltar" se veían iguales.
        let target = await resolveLocaleOnce() ?? locale
        _ = try await catalog.reserve(locale: target)
        didReserve = true
        try await releaseAndThrow(error)
    }

    /// Acumula texto como si lo hubiera dado el motor. Solo para tests.
    ///
    /// Con `isFinal` incluido a propósito: la contabilidad del resultado final decide si una
    /// entrega por techo se confiesa como recortada, y no estaba afirmada en la sesión real
    /// —el test de esa rama usa un doble que **sobrescribe** `hasFinalResultIfAvailable`, así
    /// que `sawFinalResult = isFinal` → `= false` no rompía nada y todo vencimiento se habría
    /// marcado como truncado.
    ///
    /// Devuelve exactamente lo que el bucle de resultados publicaría al panel.
    @discardableResult
    func recordForTesting(_ text: String, isFinal: Bool = false) -> String {
        record(text: text, isFinal: isFinal)
    }

    /// Same seam, measuring included. It is the exact call the results loop makes,
    /// so a test here asserts the boundary the panel's editor will refuse to cross.
    func recordAndMeasureForTesting(
        _ text: String,
        isFinal: Bool = false
    ) -> (text: String, volatileCharacters: Int) {
        recordAndMeasure(text: text, isFinal: isFinal)
    }

    var accumulatedTextForTesting: String { latestText }

    /// Todo lo dictado hasta ahora: lo cerrado más la hipótesis en curso.
    var accumulatedText: String { latestText }

    private func stopForLimit() async {
        guard !isCancelled else { return }
        // Se suelta la referencia a la propia tarea ANTES de cerrar, porque
        // `teardown()` cancela `sessionLimitTask` y este código corre dentro de ella:
        // los `await` que vienen después correrían con la tarea ya cancelada.
        //
        // La versión anterior de este comentario decía que sin esto se cancelaba «el
        // `Task` hijo que el handler crea», y eso es **falso y está medido**: un `Task {}`
        // no estructurado no hereda la cancelación. El reordenamiento es defensivo, no
        // la causa de nada.
        sessionLimitTask = nil
        // Se avisa **y se cierra**. Avisar solo no basta: el aviso viaja por un
        // closure `[weak self]` hacia el coordinador, y si alguien lo ha soltado
        // —apagar el dictado, por ejemplo— el aviso no llega a nadie y el micrófono
        // se queda abierto indefinidamente. El techo tiene que ser una garantía de
        // la sesión, no una notificación que dependa de que alguien escuche.
        onSessionLimit?()
        isCancelled = true
        // El texto se BORRA aquí, no solo se deja de alimentar. Sin esto, el techo
        // avisaba y cerraba pero `finish()` seguía devolviendo lo acumulado: medido,
        // devolvía la transcripción entera después del cierre. Y hay una carrera real
        // que llega ahí —el sondeo del soltado, cada 40 ms, puede pedir la finalización
        // antes de que el aviso cruce al coordinador—, así que el techo pegaba en el
        // documento del usuario la media hora de audio ambiente que existe para no
        // pegar. El comentario de arriba prometía justo lo contrario.
        latestText = ""
        finalizedText = ""
        volatileTail = ""
        sawFinalResult = false
        closedByLimit = true
        generation += 1
        source?.stop()
        feed?.finish()
        await analyzer?.cancelAndFinishNow()
        await teardown()
    }

    /// ¿Se guardó el manejador del techo?
    ///
    /// Existe porque su ausencia era **silenciosa**: la implementación por defecto del
    /// protocolo se comía la asignación cuando se llamaba por el tipo concreto, y de ahí
    /// salieron dos conclusiones falsas —un test que renunció a comprobar el aviso y una
    /// auditoría que midió «cierra pero no avisa»—. Afirmarlo cuesta una línea.
    var hasSessionLimitHandlerForTesting: Bool { onSessionLimit != nil }

    /// ¿Sostiene ESTA sesión una reserva de idioma?
    ///
    /// Es la invariante que de verdad importa —«una sesión cancelada no se queda con la
    /// ranura»— y la única que se puede afirmar sin depender del mundo: el inventario es
    /// global al bundle, así que otro proceso de tests del mismo binario reserva contra el
    /// mismo cupo. Afirmar sobre el inventario entero medía a los demás y hacía el test
    /// intermitente.
    var holdsReservationForTesting: Bool { didReserve }

    /// Aviso de que la sesión ha llegado a su duración máxima.
    public func setSessionLimitHandler(_ handler: @escaping @Sendable () -> Void) async {
        onSessionLimit = handler
    }

    /// El dispositivo de entrada cambió: el formato negociado ya no vale.
    ///
    /// No se intenta renegociar sobre la marcha porque el audio ya capturado y el
    /// nuevo tendrían ritmos distintos y la transcripción saldría mezclada. Se
    /// termina la sesión, y quien la gobierna decide qué contarle al usuario.
    private func handleConfigurationChange() async {
        guard !isCancelled else { return }
        onDeviceChange?()
    }

    /// Aviso de que el dispositivo de entrada cambió a mitad de sesión.
    public func setDeviceChangeHandler(_ handler: @escaping @Sendable () -> Void) async {
        onDeviceChange = handler
    }

    /// El silencio que se le añade al final, o `nil` si esta sesión no lo lleva.
    ///
    /// Separado del sitio de uso para poder afirmarlo **sin motor**: el test que lo
    /// cubría transcribía un audio real —así que el CI se lo salta— y además no detectaba
    /// que se quitara el `yield`, porque el efecto de la cola no es determinista entre
    /// pasadas. Eso es justamente la razón de conservarla: sin ella, la última palabra
    /// llega unas veces y otras no.
    /// `nonisolated` porque solo depende de una constante de la sesión —y porque un
    /// `AVAudioPCMBuffer` no es `Sendable`, así que no puede cruzar la frontera del actor.
    nonisolated func silenceTail(in format: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard silenceTailSeconds > 0 else { return nil }
        return AudioFormatConverter.silence(in: format, seconds: silenceTailSeconds)
    }

    /// Suelta la reserva y relanza. **Un solo sitio** para el patrón que se repetía
    /// cuatro veces en `prepare()`: soltar antes de fallar. No cambia lo que hace cada
    /// guarda —siguen siendo cuatro disparadores distintos, y el error que se relanza
    /// sigue siendo el suyo—, pero concentra la parte que de verdad puede tener un bug
    /// —¿se soltó de verdad? ¿se soltó lo que había que soltar?— en una función que un
    /// test puede llamar directamente sin necesitar reproducir el disparador real.
    ///
    /// Devuelve `Never` porque siempre lanza: así el sitio de uso puede escribirse como
    /// `guard ... else { try await releaseAndThrow(error) }`, sin un `throw` aparte que
    /// alguien pueda olvidar añadir.
    private func releaseAndThrow(_ error: Error) async throws -> Never {
        await releaseReservationIfOurs()
        throw error
    }

    /// Suelta el idioma si lo reservó esta sesión. Idempotente.
    private func releaseReservationIfOurs() async {
        guard didReserve else { return }
        didReserve = false
        // Se suelta **el idioma resuelto**, no el pedido: si la resolución cambia entre la
        // reserva y la liberación —y cambia, medido— se soltaría una variante distinta de la
        // reservada y la ranura quedaría cogida para siempre.
        await catalog.release(locale: resolvedLocale ?? locale)
    }

    // MARK: - Escuchar

    public func start() async throws -> AsyncStream<TranscriptFragment> {
        guard !isCancelled else { throw CancellationError() }
        guard let analyzer, let transcriber, let format = targetFormat else {
            throw DictationEngineError.audioEngineFailed
        }

        // Si un test ya inyectó una fuente (`setSourceForTesting`), se respeta en vez de
        // pisarla: sin esto, la costura de test no servía para nada una vez que `start()`
        // corría, porque siempre construía y asignaba una fuente real —micrófono o
        // fichero—, y era exactamente el motivo de que nadie pudiera comprobar que
        // `finish()`/`cancel()`/`teardown()` paran la fuente de verdad.
        let source: any AudioSource
        if let injected = self.source {
            source = injected
        } else {
            source = switch sourceKind {
            case .microphone: MicrophoneSource(target: format)
            case .file(let url): FileSource(url: url, target: format)
            }
            self.source = source
        }
        // Fuera del `if`/`else`: una fuente inyectada por un test también puede ser un
        // `MicrophoneSource` de verdad —para poder disparar un cambio de configuración
        // real y comprobar que llega hasta `onDeviceChange`—, y dejar este cableado solo
        // en la rama de «fuente nueva» lo dejaba mudo justo para ese caso.
        if let microphone = source as? MicrophoneSource {
            microphone.onConfigurationChange = { [weak self] in
                Task { await self?.handleConfigurationChange() }
            }
        }

        // Se interpone una cola propia entre la fuente y el analizador para poder
        // añadir la cola de silencio al final: si el silencio lo inyectara la
        // fuente, la política de dictado viviría en el sitio equivocado.
        //
        // La política **depende de la fuente**, y equivocarse aquí no da error: se
        // pierde audio en silencio. Medido con un fichero de 90 s, acotar este
        // carril dejaba 34 caracteres de 1442. Con micrófono hay que preservar el
        // tiempo real y se descarta lo más antiguo; con fichero hay que preservar
        // el audio íntegro y el productor puede esperar.
        let (feedStream, feedContinuation) = AsyncStream<AnalyzerInput>.makeStream(
            // **La misma política que la fuente**, preguntándosela a ella. Son dos colas en
            // serie: mientras cada una la calculaba por su cuenta, se podía acotar la
            // segunda sin tocar la primera y el resultado era el mismo —audio perdido en
            // silencio— con la suite en verde. Ahora la decisión tiene un solo dueño.
            bufferingPolicy: source.bufferingPolicy
        )
        self.feed = feedContinuation

        let sourceStream = try source.start()
        forwardTask = Task {
            for await input in sourceStream {
                feedContinuation.yield(input)
            }
            // No se cierra aquí: `finish()` aún tiene que meter el silencio.
        }

        // La política, declarada como las otras dos. Era la única cola del camino sin
        // decirla, en un fichero cuya tesis es que la política tiene un solo dueño.
        //
        // `.bufferingNewest(1)` y no `.unbounded`, porque aquí cada elemento **no es un
        // delta**: es la transcripción entera acumulada hasta ese momento. Si el actor
        // principal se atasca, acumular fragmentos guarda n copias de un texto que crece,
        // y el consumidor solo pinta la última de todas formas. Quedarse con la más
        // reciente da exactamente el mismo resultado en pantalla con memoria acotada.
        let (publicStream, publicContinuation) = AsyncStream<TranscriptFragment>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        self.fragments = publicContinuation

        // Los resultados hay que consumirlos desde el principio: si nadie los
        // lee, se pierden.
        resultsTask = Task { [weak self] in
            do {
                for try await result in transcriber.results {
                    let text = String(result.text.characters)
                    // `isFinal` SÍ existe: es una propiedad de extensión del
                    // protocolo (`Speech.swiftinterface:383-387`), no un miembro de
                    // su declaración, y por eso un barrido de la declaración no la
                    // encuentra. Medido funcionando contra el motor real: el último
                    // resultado de una frase llega con `isFinal == true`.
                    // Se publica **lo que devuelve `record`**, que es lo acumulado. El motor
                    // reinicia el texto en cada frase nueva; publicar el tramo suelto hacía
                    // que el panel enseñara solo lo último dicho mientras la sesión sí
                    // guardaba el resto —dos verdades para el mismo dictado, y la que el
                    // usuario ve es la que le hace creer que se pierde—. Que `record`
                    // devuelva el texto en vez de dejarlo en una propiedad aparte no es
                    // estilo: mientras el tramo suelto siguiera vivo aquí al lado, volver a
                    // publicarlo era un descuido de una palabra.
                    guard let snapshot = await self?.recordAndMeasure(
                        text: text,
                        isFinal: result.isFinal
                    ) else { break }
                    publicContinuation.yield(
                        TranscriptFragment(
                            text: snapshot.text,
                            isVolatile: !result.isFinal,
                            volatileCharacterCount: snapshot.volatileCharacters
                        )
                    )
                }
            } catch {
                // El flujo se corta al finalizar o al cancelar; el resultado se
                // entrega desde `finish()`, así que aquí no hay nada que hacer.
            }
            publicContinuation.finish()
        }

        // Techo duro de duración. `SpeechDetector` habría sido la forma elegante —cerrar
        // al dejar de hablar— y el motivo escrito aquí era **falso**: decía que «no
        // conforma `SpeechModule`», y en ejecución **sí conforma** (medido con una sonda
        // contra el framework). Lo cierto es solo la mitad declarativa: el
        // `.swiftinterface` del SDK 26.0 declara `final public class SpeechDetector` sin
        // esa conformidad.
        //
        // La decisión de no usarlo se mantiene, por la razón correcta: apoyarse en una
        // conformidad que el interface no promete es construir sobre algo que puede
        // desaparecer en cualquier actualización, y sin aviso del compilador. Este párrafo
        // ya se había equivocado dos veces; el diseño (§7.3) lo corrigió y el código se
        // quedó con la versión vieja.
        //
        // Un techo de tiempo es menos fino pero cubre el riesgo que importa: una
        // tecla enclavada —Sticky Keys, un teclado que reporta un modificador
        // hundido— no puede dejar el micrófono abierto indefinidamente.
        let limit = maximumSessionDuration
        sessionLimitTask = Task { [weak self] in
            try? await Task.sleep(for: limit)
            guard !Task.isCancelled else { return }
            await self?.stopForLimit()
        }

        try await analyzer.start(inputSequence: feedStream)
        return publicStream
    }

    /// Lo ya cerrado por el motor. **No se pisa nunca.**
    private var finalizedText = ""
    /// La hipótesis en curso, que sí se reemplaza en cada resultado.
    private var volatileTail = ""

    /// Acumula un resultado del motor.
    ///
    /// Reemplazaba, y eso perdía texto en cualquier dictado con pausas. Medido con audio
    /// real: el motor cierra una frase y **empieza de cero** en la siguiente —«Primera frase
    /// de la conversación» (32 caracteres) seguido de «segunda» (8)—, así que asignar el
    /// último resultado destruía todo lo anterior. En una frase suelta no se nota; en una
    /// conversación larga se pierde todo menos lo último que se dijo.
    ///
    /// Lo cerrado se acumula y solo la hipótesis en curso se sustituye. `isFinal` es la señal
    /// que separa una cosa de la otra, y por eso importa que se lea del motor —donde existe
    /// como propiedad de extensión— en vez de suponerla.
    /// Anota un resultado del motor y devuelve **el texto que debe verse**.
    ///
    /// - Returns: todo lo dictado en la sesión, no el tramo que acaba de llegar.
    @discardableResult
    private func record(text: String, isFinal: Bool) -> String {
        if isFinal {
            finalizedText = Self.join(finalizedText, text)
            volatileTail = ""
        } else {
            volatileTail = text
        }
        sawFinalResult = isFinal
        latestText = Self.join(finalizedText, volatileTail)
        return latestText
    }

    /// Records a result and reports where the hypothesis begins in the joined text.
    ///
    /// The count is derived from the two parts `record` just committed — everything
    /// past the finalized prefix, joining space included — and not from the raw tail's
    /// length: `join` trims the tail before appending, so measuring the input instead
    /// of the output would drift by exactly the whitespace the engine sends.
    private func recordAndMeasure(
        text: String,
        isFinal: Bool
    ) -> (text: String, volatileCharacters: Int) {
        let joined = record(text: text, isFinal: isFinal)
        guard !volatileTail.isEmpty else { return (joined, 0) }
        return (joined, joined.count - finalizedText.count)
    }

    /// Une dos tramos sin duplicar ni comerse el espacio de la costura.
    ///
    /// Los tramos del motor llegan con espacio inicial cuando continúan una frase y sin él
    /// cuando la abren. Normalizar aquí evita tanto «unopalabra» como los dobles espacios.
    static func join(_ accumulated: String, _ next: String) -> String {
        let trimmed = next.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return accumulated }
        guard !accumulated.isEmpty else { return trimmed }
        return accumulated + " " + trimmed
    }

    /// ¿Llegó ya un resultado marcado como final?
    ///
    /// Sirve para no confesar una pérdida que no ha ocurrido: cuando el techo de
    /// finalización vence pero el último resultado recibido ya era final, el texto
    /// está completo y marcarlo como truncado asusta sin motivo.
    public func hasFinalResultIfAvailable() async -> Bool { sawFinalResult }

    /// ¿Se ha cerrado ya esta sesión? Para poder comprobar que el techo cierra de
    /// verdad y no solo avisa.
    public var isClosed: Bool { isCancelled && analyzer == nil }


    // MARK: - Terminar

    public func finish() async throws -> Transcript {
        // Si la sesión se cerró por el techo de duración, esto NO es una entrega: es un
        // fallo, y el texto ya se ha borrado. Devolver un transcript vacío haría que el
        // coordinador lo tradujera a «no se oyó nada» —culpando al usuario— en lugar de
        // decir que se cortó por tiempo.
        guard !closedByLimit else { throw DictationEngineError.sessionClosedByLimit }
        guard let analyzer, let format = targetFormat else {
            return Transcript(text: latestText, mode: mode)
        }

        // 1. La fuente deja de producir.
        source?.stop()
        await forwardTask?.value
        forwardTask = nil

        // 2. Cola de silencio: sin esto el resultado es inconsistente entre pasadas.
        //
        // Sellada al final de la secuencia, no sin marca: ahora que los bloques llevan
        // tiempo, un silencio sin marca se colocaría al principio.
        //
        // Hueco declarado: quitar este `feed?.yield` no está cubierto de forma
        // determinista. `finalWordArrivesWithSilenceTail` mide contra el motor real —la
        // única forma honesta de probar esto, según la propia historia del fichero: tres
        // sondeos distintos dieron tres conclusiones sobre el caso sin cola— y no siempre
        // detecta la ausencia, porque el reconocimiento de la última palabra depende
        // también de dónde cae el corte del audio sintetizado, no solo de si hay
        // silencio de cierre. `feed` es una `AsyncStream.Continuation` privada sin forma
        // de interceptar desde fuera sin instrumentar el propio motor.
        if let input = silenceInput(in: format) {
            feed?.yield(input)
        }
        feed?.finish()
        feed = nil

        // 3. Esperar a que el texto deje de ser volátil.
        //
        // Con `catch` que desmonta antes de propagar: si `finalizeAndFinish` lanza
        // —incluida la cancelación que provoca un techo de espera vencido— la reserva del
        // idioma se suelta igual. Sin eso se fugaba una ranura por cada finalización que no
        // terminaba limpiamente, y solo hay cinco en toda la máquina.
        //
        // El comentario decía «con `defer`» y aquí no hay ninguno: el efecto es el mismo,
        // el mecanismo no, y quien viniera a tocar esto buscaría una línea que no existe.
        var finalText = latestText
        do {
            try await analyzer.finalizeAndFinishThroughEndOfInput()
            await resultsTask?.value
            finalText = latestText
        } catch {
            await teardown()
            throw error
        }
        resultsTask = nil

        await teardown()
        return Transcript(text: finalText.trimmingCharacters(in: .whitespaces), mode: mode)
    }

    public func cancel() async {
        // Invalida cualquier `prepare()` que esté suspendido —al reanudar verá que
        // su generación ya no es la actual— y también los que aún no han empezado.
        isCancelled = true
        generation += 1
        source?.stop()
        forwardTask?.cancel()
        feed?.finish()
        await analyzer?.cancelAndFinishNow()
        resultsTask?.cancel()
        fragments?.finish()
        await teardown()
        latestText = ""
    }

    /// Suelta el idioma reservado y los objetos del motor.
    ///
    /// Liberar la reserva importa: el cupo del sistema es pequeño —cinco idiomas
    /// en macOS 26.0— y quedárselo sin usar se lo quita a otras apps y al propio
    /// usuario.
    private func teardown() async {
        // Primero la fuente, siempre: llegar aquí con ella viva dejaría el tap
        // instalado, el motor corriendo y el micrófono abierto.
        source?.stop()
        forwardTask?.cancel()
        forwardTask = nil
        resultsTask?.cancel()
        resultsTask = nil
        sessionLimitTask?.cancel()
        sessionLimitTask = nil
        source = nil
        analyzer = nil
        transcriber = nil
        feed = nil
        fragments = nil
        await releaseReservationIfOurs()
    }
}

/// El motor de transcripción del sistema.
public struct SpeechEngine: TranscriberEngine {
    public static let identifier = "apple.speech.dictation-transcriber"

    public var catalog: any ModelCatalog { SpeechModelCatalog(mode: .live) }

    public init() {}

    public func makeSession(
        locale: Locale,
        mode: DictationMode,
        atypicalSpeech: Bool,
        contextualStrings: [String]
    ) throws -> any TranscriptionSession {
        SpeechSession(
            locale: locale,
            mode: mode,
            atypicalSpeech: atypicalSpeech,
            contextualStrings: contextualStrings
        )
    }

}
