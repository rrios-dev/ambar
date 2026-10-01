import AVFoundation
import Foundation
import Speech
import Testing

@testable import VoiceKit

/// Las garantías de la sesión que **no** necesitan el motor de voz.
///
/// Existe por un hallazgo de método, no por una función nueva: quince tests del motor se
/// saltan en integración continua —doce en `SpeechEngineTests` y tres aquí; el recuento lo
/// publica el propio CI en cada ejecución, en vez de fiarse de este número, que ya estuvo
/// desactualizado— (`AMBAR_SKIP_SPEECH_TESTS`, porque el runner no trae el
/// modelo de voz), y medido por mutación eso significa que **la peor regresión de la
/// historia del proyecto puede volver a mergear en verde**: acotar el carril del fichero
/// dejaba 34 caracteres de 1442, y el test que lo caza no corre en CI.
///
/// Lo que se hace aquí es mover esas garantías a código que se puede ejercitar sin
/// modelo: la política de la cola depende solo de cómo se construyó la sesión, el
/// silencio final es un buffer que se puede pedir, y el cierre por techo se puede
/// provocar. El test con motor real sigue existiendo y sigue corriendo en local; lo que
/// deja de ocurrir es que en CI no haya **nada**.
@Suite("Cableado de la sesión, sin motor")
struct SessionWiringTests {

    static let locale = Locale(identifier: "es-ES")

    static func format() throws -> AVAudioFormat {
        try #require(
            AVAudioFormat(
                commonFormat: .pcmFormatInt16,
                sampleRate: 16000,
                channels: 1,
                interleaved: true
            )
        )
    }

    // MARK: - La política de la cola la decide la fuente
    //
    // Los dos tests que había aquí afirmaban sobre un envoltorio de `SpeechSession` que se
    // quedó sin llamador de producción cuando la sesión pasó a preguntar
    // `source.bufferingPolicy`. Vive ahora en `sourcesDeclareOppositeCriteria`, sobre las
    // fuentes de verdad, y el carril completo lo cubre `FileSourceLosslessTests` contando
    // los bloques que salen de la cola.

    // MARK: - La cola de silencio

    @Test("la sesión lleva un silencio final, y del tamaño que dice")
    func sessionCarriesASilenceTail() async throws {
        let session = SpeechSession(locale: Self.locale, mode: .live)
        let format = try Self.format()

        let silence = try #require(
            session.silenceTail(in: format),
            "la sesión no añade cola de silencio"
        )
        // Sin ella el resultado es **inconsistente entre pasadas**: la última palabra
        // llega unas veces y otras no. Ese es el motivo de conservarla, y también el
        // motivo de que un test de transcripción no la pueda proteger.
        let expected = AVAudioFrameCount(
            SpeechSession.defaultSilenceTailSeconds * format.sampleRate
        )
        #expect(silence.frameLength == expected)
    }

    @Test("con la cola desactivada no se añade nada")
    func zeroTailAddsNothing() async throws {
        let session = SpeechSession(
            locale: Self.locale,
            mode: .live,
            silenceTailSeconds: 0
        )
        #expect(session.silenceTail(in: try Self.format()) == nil)
    }

    /// Nota sobre la mutación `> 0` → `>= 0` que la auditoría de cierre encontró
    /// superviviente: es un mutante EQUIVALENTE, no un hueco real. `AudioFormatConverter
    /// .silence` rechaza `frames == 0` por su cuenta, así que para `seconds == 0` las dos
    /// variantes de la guarda producen exactamente el mismo `nil` — no hay ninguna entrada
    /// para la que `> 0` y `>= 0` difieran en el resultado, así que ningún test puede
    /// matar esa mutación sin que sea un test sobre otra cosa.
    ///
    /// Lo que SÍ distingue una guarda mal escrita de una bien escrita es el signo:
    /// `AVAudioFrameCount(format.sampleRate * seconds)` con `seconds` negativo intenta
    /// construir un entero sin signo desde un valor negativo, que en Swift **aborta el
    /// proceso**, no lanza un error capturable. Un valor negativo no debería poder llegar
    /// aquí desde producción —`defaultSilenceTailSeconds` es una constante positiva—,
    /// pero el parámetro es un `Double` inyectable sin más restricción, y esta guarda es
    /// la única defensa entre eso y un crash.
    @Test("con una cola negativa no se intenta construir un buffer")
    func negativeTailDoesNotAttemptABuffer() async throws {
        let session = SpeechSession(
            locale: Self.locale,
            mode: .live,
            silenceTailSeconds: -1
        )
        #expect(session.silenceTail(in: try Self.format()) == nil)
    }

    // MARK: - El techo de duración

    @Test("el techo borra lo dictado y no se puede recuperar")
    func limitDiscardsWhatWasDictated() async throws {
        let session = SpeechSession(locale: Self.locale, mode: .live)
        await session.recordForTesting("dos minutos de conversación ajena")
        #expect(await session.accumulatedTextForTesting.isEmpty == false)

        await session.closeForLimitForTesting()

        // Las dos mitades, y la segunda es la que faltaba: el techo cierra **y** lo
        // dictado deja de existir. Con solo la primera, `finish()` seguía devolviendo el
        // texto acumulado —medido— y una carrera de 40 ms bastaba para pegar en el
        // documento del usuario el audio ambiente entero que el techo existe
        // para no pegar.
        #expect(await session.isClosed)
        #expect(await session.accumulatedTextForTesting.isEmpty)
        await #expect(throws: DictationEngineError.sessionClosedByLimit) {
            try await session.finish()
        }
    }

    // MARK: - La contabilidad de la reserva

    /// Catálogo espía. La reserva es una de las **cinco** ranuras de idioma de toda la
    /// máquina, y una fuga solo se ve mirando el inventario del sistema —que un test no
    /// puede tocar—, así que la contabilidad se comprueba contra este doble.
    actor SpyCatalog: ModelCatalog {
        private var held: Set<String> = []
        private(set) var releases = 0
        private let availabilityToReport: ModelAvailability

        init(availability: ModelAvailability = .installed, preReserved: Locale? = nil) {
            self.availabilityToReport = availability
            if let preReserved { held.insert(preReserved.identifier) }
        }

        func supportedLocale(equivalentTo locale: Locale) async -> Locale? { locale }
        func availability(forLocale locale: Locale) async -> ModelAvailability {
            availabilityToReport
        }
        func installModel(
            forLocale locale: Locale,
            onProgress: @Sendable @escaping (Double) -> Void
        ) async throws {}
        func installationSize(forLocale locale: Locale) async -> Int64? { nil }
        /// Se invoca DENTRO de `reserve(locale:)`, antes de devolver. Existe para poder
        /// colar una cancelación exactamente en el punto de suspensión que la primera
        /// guarda de generación de `prepare()` protege — con temporización real (dormir
        /// N ms y esperar acertar la ventana) el resultado es intermitente, y ni con
        /// tres retardos distintos se garantiza aterrizar ahí: medido, sobrevivía.
        var onReserve: (@Sendable () async -> Void)?
        func set(onReserve: @escaping @Sendable () async -> Void) { self.onReserve = onReserve }

        func reserve(locale: Locale) async throws -> Bool {
            await onReserve?()
            return held.insert(locale.identifier).inserted
        }
        func release(locale: Locale) async {
            releases += 1
            held.remove(locale.identifier)
        }
        func reservation() async -> (maximum: Int, reserved: [Locale]) {
            (5, held.map { Locale(identifier: $0) })
        }
        func endModelRetention() async {}
        func isHeld(_ locale: Locale) async -> Bool { held.contains(locale.identifier) }
    }

    /// A catalog whose model reads as missing until it has been reserved `needed` times:
    /// the race where something else released the app-wide reservation between our
    /// `reserve` and the status question.
    actor FlickeringCatalog: ModelCatalog {
        private let needed: Int
        private let whenNotReady: ModelAvailability
        private(set) var reserves = 0
        init(installedAfterReserves needed: Int, whenNotReady: ModelAvailability = .supported) {
            self.needed = needed
            self.whenNotReady = whenNotReady
        }
        func supportedLocale(equivalentTo locale: Locale) async -> Locale? { locale }
        func availability(forLocale locale: Locale) async -> ModelAvailability {
            reserves >= needed ? .installed : whenNotReady
        }
        func installModel(
            forLocale locale: Locale,
            onProgress: @Sendable @escaping (Double) -> Void
        ) async throws {}
        func installationSize(forLocale locale: Locale) async -> Int64? { nil }
        func reserve(locale: Locale) async throws -> Bool { reserves += 1; return true }
        func release(locale: Locale) async {}
        func reservation() async -> (maximum: Int, reserved: [Locale]) { (5, []) }
        func endModelRetention() async {}
    }

    @Test("an installed model read as missing for an instant is confirmed after re-reserving")
    func installedCheckSurvivesALostReservation() async {
        // The reservation was taken once by `prepare()` and lost before the question.
        let catalog = FlickeringCatalog(installedAfterReserves: 1)
        let confirmed = await SpeechSession.confirmInstalled(
            locale: Self.locale, in: catalog, pause: .zero
        )
        #expect(confirmed, "failed on the first answer instead of reserving again")
        #expect(await catalog.reserves == 1)
    }

    @Test("a model that is really missing still fails, after the bounded retries")
    func missingModelStillFails() async {
        let catalog = FlickeringCatalog(installedAfterReserves: .max)
        let confirmed = await SpeechSession.confirmInstalled(
            locale: Self.locale, in: catalog, attempts: 3, pause: .zero
        )
        #expect(!confirmed)
        #expect(await catalog.reserves == 2, "retried more than the cap")
    }

    @Test("an unsupported language is final and is not retried")
    func unsupportedIsNotRetried() async {
        let catalog = FlickeringCatalog(installedAfterReserves: .max, whenNotReady: .unsupported)
        let confirmed = await SpeechSession.confirmInstalled(
            locale: Self.locale, in: catalog, pause: .zero
        )
        #expect(!confirmed)
        #expect(await catalog.reserves == 0)
    }

    /// La primera guarda de generación de `prepare()`: cancelar justo después de que la
    /// reserva se resuelva, y antes de que `prepare()` compruebe si sigue vigente.
    ///
    /// Sin esta guarda, `prepare()` reanudaría y marcaría `didReserve = true` sobre una
    /// sesión que ya nadie sostiene: nadie volvería a soltarla y se perdería una de las
    /// cinco ranuras del sistema para siempre. El test que ya existía provocaba esto con
    /// temporización real —dormir 0, 1 o 20 ms y confiar en aterrizar en la ventana—, y
    /// no aterriza: medido, sobrevivía a la mutación de esta guarda en las tres pasadas.
    /// Con el hook dentro de `reserve(locale:)` la cancelación ocurre en el punto exacto,
    /// siempre, sin depender del reloj.
    @Test("cancelar justo tras reservar no deja la ranura tomada")
    func cancellingRightAfterReserveDoesNotLeakReservation() async throws {
        let catalog = SpyCatalog(availability: .supported)
        let session = SpeechSession(locale: Self.locale, mode: .live, catalog: catalog)
        await catalog.set(onReserve: { await session.cancel() })

        await #expect(throws: CancellationError.self) {
            try await session.prepare()
        }
        #expect(
            await catalog.isHeld(Self.locale) == false,
            "cancelar justo tras reservar dejó la ranura tomada"
        )
    }

    @Test("una preparación que falla no se queda con la ranura de idioma")
    func failedPrepareReleasesTheReservation() async throws {
        // El modelo dice no estar instalado: `prepare()` sale por ahí, y ese camino
        // tenía que soltar la reserva.
        let catalog = SpyCatalog(availability: .supported)
        let session = SpeechSession(locale: Self.locale, mode: .live, catalog: catalog)

        await #expect(throws: DictationEngineError.modelNotInstalled) {
            try await session.prepare()
        }
        #expect(await catalog.isHeld(Self.locale) == false, "fuga: la ranura quedó tomada")
    }

    /// `releaseAndThrow` es el código **compartido** por los cuatro `guard`/`catch` de
    /// `prepare()` que sueltan la reserva antes de fallar. Solo uno de los cuatro
    /// —`modelNotInstalled`, arriba— tenía un test que llegara hasta ahí; los otros
    /// tres necesitan que el framework de Speech falle de una forma concreta
    /// (`incompatibleAudioFormat`, o que `prepareToAnalyze` rechace el modelo, o una
    /// cancelación a mitad) que no se puede reproducir sin arriesgar comportamiento no
    /// determinista del propio framework. Como el código es el MISMO en los cuatro
    /// sitios —no una copia por sitio—, un test que lo ejercite directamente protege a
    /// los cuatro, aunque no reproduzca el disparador real de cada uno.
    @Test("releaseAndThrow suelta la reserva antes de relanzar, con cualquier error")
    func releaseAndThrowAlwaysReleasesFirst() async throws {
        let catalog = SpyCatalog(availability: .supported)
        let session = SpeechSession(locale: Self.locale, mode: .live, catalog: catalog)

        struct ProbeError: Error, Equatable {}
        await #expect(throws: ProbeError.self) {
            try await session.releaseAndThrowForTesting(ProbeError())
        }
        #expect(
            await catalog.isHeld(Self.locale) == false,
            "releaseAndThrow relanzó sin soltar: fuga garantizada en los cuatro sitios que lo llaman"
        )
    }

    @Test("una reserva que ya era nuestra también se suelta al fallar")
    func alreadyHeldReservationIsAlsoReleased() async throws {
        // Este es el caso que se escapaba: `reserve` devuelve `false` **también** cuando
        // el idioma ya estaba reservado por este proceso —algo tan inocente como
        // consultar el peso del modelo lo reserva de paso—, así que fiarse del booleano
        // dejaba `didReserve` en falso y la reserva colgada mientras la app viviera.
        let catalog = SpyCatalog(availability: .supported, preReserved: Self.locale)
        let session = SpeechSession(locale: Self.locale, mode: .live, catalog: catalog)

        await #expect(throws: DictationEngineError.modelNotInstalled) {
            try await session.prepare()
        }
        #expect(
            await catalog.isHeld(Self.locale) == false,
            "la reserva preexistente se quedó colgada: nadie la iba a soltar"
        )
        #expect(await catalog.releases >= 1)
    }

    /// El cupo lleno **lanza**; no devuelve `false`.
    ///
    /// Este doble decía lo contrario, y por eso el fallo sobrevivió a la suite entera: el
    /// código se escribió contra la ficción del doble y el test la confirmaba. Medido
    /// caso por caso en macOS 26.0 con las cinco ranuras ocupadas — idioma instalado, no
    /// instalado e inexistente— `AssetInventory.reserve` tira `SFSpeechErrorDomain` 11,
    /// «Too many allocated locales, 5 maximum.». El `false` significa **otra cosa**: que
    /// este proceso ya la tenía. Ver `quotaExhaustedIsTranslated` para la traducción.
    @Test("con el cupo del sistema lleno se dice que está lleno")
    func fullQuotaIsReported() async throws {
        actor FullCatalog: ModelCatalog {
            func supportedLocale(equivalentTo locale: Locale) async -> Locale? { locale }
            func availability(forLocale locale: Locale) async -> ModelAvailability { .installed }
            func installModel(
                forLocale locale: Locale,
                onProgress: @Sendable @escaping (Double) -> Void
            ) async throws {}
            func installationSize(forLocale locale: Locale) async -> Int64? { nil }
            func reserve(locale: Locale) async throws -> Bool {
                throw DictationEngineError.reservationQuotaExceeded
            }
            func release(locale: Locale) async {}
            func reservation() async -> (maximum: Int, reserved: [Locale]) { (5, []) }
            func endModelRetention() async {}
        }

        let session = SpeechSession(locale: Self.locale, mode: .live, catalog: FullCatalog())
        await #expect(throws: DictationEngineError.reservationQuotaExceeded) {
            try await session.prepare()
        }
    }

    /// Y el caso que el usuario veía: `false` con la reserva ya en nuestras manos.
    ///
    /// Era el aviso de «no caben más idiomas de dictado», con su remedio falso —Ajustes
    /// del Sistema, donde no había nada que liberar— emitido **justo cuando todo estaba
    /// bien**. Preparar tiene que salir adelante.
    @Test("una reserva que este proceso ya tenía no es un cupo lleno")
    func alreadyReservedIsNotAFullQuota() async throws {
        actor HeldCatalog: ModelCatalog {
            func supportedLocale(equivalentTo locale: Locale) async -> Locale? { locale }
            func availability(forLocale locale: Locale) async -> ModelAvailability { .installed }
            func installModel(
                forLocale locale: Locale,
                onProgress: @Sendable @escaping (Double) -> Void
            ) async throws {}
            func installationSize(forLocale locale: Locale) async -> Int64? { nil }
            /// Lo que el sistema responde cuando el idioma ya está reservado por nosotros.
            func reserve(locale: Locale) async throws -> Bool { false }
            func release(locale: Locale) async {}
            /// Y el inventario que NO lo lista — la discrepancia que disparaba el aviso.
            func reservation() async -> (maximum: Int, reserved: [Locale]) { (5, []) }
            func endModelRetention() async {}
        }

        let session = SpeechSession(locale: Self.locale, mode: .live, catalog: HeldCatalog())
        // Sin motor real no llega al final, pero el fallo del cupo ya no puede salir:
        // lo que se afirma es que NO es `reservationQuotaExceeded`.
        do {
            try await session.prepare()
        } catch let error as DictationEngineError {
            #expect(
                error != .reservationQuotaExceeded,
                "volvió a confundir «ya la teníamos» con «no caben más idiomas»"
            )
        } catch {
            // Cualquier otro error del motor es aceptable aquí: no es el que se prueba.
        }
    }

    /// La traducción, donde el error del sistema deja de ser «algo ha fallado».
    @Test("el error de cupo del sistema se reconoce por dominio y código, no por su texto")
    func quotaExhaustedIsTranslated() {
        let realError = NSError(
            domain: "SFSpeechErrorDomain", code: 11,
            userInfo: [NSLocalizedDescriptionKey: "Too many allocated locales, 5 maximum."])
        #expect(SpeechModelCatalog.isQuotaExhausted(realError))

        // Localizado: en un Mac en ruso el mensaje no dice «Too many allocated locales»,
        // así que comparar el texto habría dejado el aviso sin salir justo ahí.
        let localizado = NSError(
            domain: "SFSpeechErrorDomain", code: 11,
            userInfo: [NSLocalizedDescriptionKey: "Слишком много выделенных языков"])
        #expect(SpeechModelCatalog.isQuotaExhausted(localizado))

        #expect(!SpeechModelCatalog.isQuotaExhausted(
            NSError(domain: "SFSpeechErrorDomain", code: 7)))
        #expect(!SpeechModelCatalog.isQuotaExhausted(DictationEngineError.localeUnsupported))
    }
}

/// La configuración del transcriptor, contra los presets del propio sistema.
///
/// §2.1 del diseño afirma que el modo en vivo es **exactamente**
/// `Preset.progressiveShortDictation` y el diferido `Preset.shortDictation`. Era una
/// afirmación sin red: quitar `.punctuation`, `.shortForm` o `.frequentFinalization` no
/// rompía ningún test —tres mutaciones medidas—, y cada una de esas opciones es una de
/// las razones por las que se eligió este módulo frente al otro.
///
/// `Preset` es `Equatable`, así que la comprobación es directa y no hace falta el modelo
/// de voz instalado: se compara configuración, no se transcribe nada.
@Suite("La configuración es la que el diseño declara")
struct TranscriberConfigurationTests {

    static let locale = Locale(identifier: "es-ES")

    @Test("el modo en vivo es exactamente el preset progresivo del sistema")
    func liveMatchesTheSystemPreset() {
        #expect(
            SpeechTranscriberFactory.preset(for: .live)
                == DictationTranscriber.Preset.progressiveShortDictation,
            "la configuración en vivo dejó de coincidir con progressiveShortDictation"
        )
    }

    @Test("el modo diferido es exactamente el preset corto")
    func deferredMatchesTheSystemPreset() {
        #expect(
            SpeechTranscriberFactory.preset(for: .deferred)
                == DictationTranscriber.Preset.shortDictation,
            "la configuración diferida dejó de coincidir con shortDictation"
        )
    }

    @Test("la puntuación está pedida: es la razón de usar este módulo y no el otro")
    func punctuationIsRequested() {
        // `SpeechTranscriber` no ofrece `.punctuation`. Dictar «coma» y «punto» es lo que
        // hace usable un dictado que va a un campo de texto, y es una de las tres razones
        // de §2 para elegir `DictationTranscriber`.
        #expect(SpeechTranscriberFactory.preset(for: .live).transcriptionOptions.contains(.punctuation))
        #expect(SpeechTranscriberFactory.preset(for: .deferred).transcriptionOptions.contains(.punctuation))
    }

    @Test("la pista de habla atípica se puede activar, y solo añade eso")
    func atypicalSpeechCanBeEnabled() {
        // La tercera razón de §2 para elegir este módulo —la función de accesibilidad de
        // Apple para habla atípica— **no tenía forma de activarse**: se perdía «sin que
        // nadie lo decida», que es literalmente lo que el diseño dice evitar.
        let base = SpeechTranscriberFactory.preset(for: .live)
        let atypical = SpeechTranscriberFactory.preset(for: .live, atypicalSpeech: true)

        #expect(atypical.contentHints.contains(.atypicalSpeech))
        #expect(atypical.contentHints.contains(.shortForm), "perdió la pista de forma corta")
        // Y no cambia nada más: sigue siendo el mismo dictado, con una pista añadida.
        #expect(atypical.transcriptionOptions == base.transcriptionOptions)
        #expect(atypical.reportingOptions == base.reportingOptions)
        #expect(atypical.attributeOptions == base.attributeOptions)
    }
}

/// El reloj de la secuencia que se entrega al analizador.
///
/// Existe por una interacción entre dos decisiones que por separado eran correctas: la
/// cola del micrófono **descarta lo más antiguo** cuando el análisis se retrasa, y los
/// bloques se entregaban **sin marca de tiempo**. Con eso, el motor trata la secuencia
/// como contigua, así que un descarte no deja un hueco: **empalma** dos trozos de habla
/// distintos. El resultado son frases plausibles que nadie dijo, y solo cuando la máquina
/// va cargada.
@Suite("Reloj de la secuencia de audio")
struct SequenceClockTests {

    @Test("cada bloque empieza donde acabó el anterior")
    func blocksAreContiguous() {
        let clock = SequenceClock(sampleRate: 16000)

        let first = clock.stamp(frames: 1600)   // 100 ms
        let second = clock.stamp(frames: 1600)

        #expect(first.seconds == 0)
        #expect(second.seconds == 0.1)
        #expect(clock.end.seconds == 0.2)
    }

    @Test("un bloque descartado deja un hueco, no un empalme")
    func droppedBlockLeavesAGap() {
        // El reloj sella en el tap, ANTES de que la cola pueda descartar, así que el
        // bloque que sobrevive conserva su tiempo real.
        let clock = SequenceClock(sampleRate: 16000)

        _ = clock.stamp(frames: 1600)           // se entrega
        _ = clock.stamp(frames: 1600)           // este lo descarta la cola
        let third = clock.stamp(frames: 1600)   // se entrega

        // 200 ms, no 100: el hueco del bloque perdido queda declarado. Con marcas
        // renumeradas después del descarte, este bloque diría 100 ms y el motor pegaría
        // dos trozos que no van juntos.
        #expect(third.seconds == 0.2)
    }

    @Test("la marca va en la base de tiempo del motor, no del micrófono")
    func stampUsesTheEngineTimebase() {
        // El micrófono entrega 48 kHz y el motor consume 16 kHz. Contar los marcos de
        // entrada daría tiempos tres veces más largos.
        let clock = SequenceClock(sampleRate: 16000)
        _ = clock.stamp(frames: 16000)
        #expect(clock.end.seconds == 1.0)
    }
}

/// La sonda de capacidad, con el motor real.
///
/// Es lo que hacía falta para que el eje de capacidad dejara de ser código muerto: la
/// oferta se construía con `.unmeasured` fijo, así que el aviso de «esta máquina va
/// justa» —la decisión de producto del primer día— no podía ocurrir nunca.
@Suite("Sonda de capacidad")
struct CapabilityProbeTests {

    @Test("el ámbito de la medida es esta máquina y este sistema")
    func measurementIsScoped() {
        // Sin esto, una medida hecha en un Mac potente viajaría en una copia de seguridad
        // a uno lento y seguiría recomendando el modo en vivo.
        let machine = CapabilityProbe.machineIdentifier()
        #expect(!machine.isEmpty)
        #expect(machine != "unknown", "no se pudo leer hw.model")
        // Formato `Mac16,10` o similar: lo que importa es que distinga modelos.
        #expect(machine.contains(","))

        let version = CapabilityProbe.systemVersion()
        #expect(version.hasPrefix("26."), "versión inesperada: \(version)")
    }

    @Test("sintetiza audio de referencia audible", .enabled(
        if: ProcessInfo.processInfo.environment["AMBAR_SKIP_SPEECH_TESTS"] == nil,
        "usa las voces del sistema"
    ))
    func synthesizesReferenceAudio() async throws {
        let url = try await CapabilityProbe.renderReferenceAudio(
            locale: Locale(identifier: "es-ES")
        )
        defer { try? FileManager.default.removeItem(at: url) }

        // Que dure algo de verdad: un audio de 0,1 s daría una medida dominada por el
        // arranque en frío del modelo, que es justo lo que no se quiere medir.
        let duration = try CapabilityProbe.duration(of: url)
        #expect(duration > 1.0, "el audio de referencia duró \(duration) s")
    }

    @Test("mide un factor de tiempo real plausible", .enabled(
        if: ProcessInfo.processInfo.environment["AMBAR_SKIP_SPEECH_TESTS"] == nil,
        "necesita el modelo de voz instalado"
    ))
    func measuresARealTimeFactor() async throws {
        // Bajo el cerrojo del inventario: la sonda crea una sesión real, que reserva el
        // idioma. Sin esto se pisa con los tests del motor y el fallo es intermitente.
        let measurement = try await SystemInventoryLock.shared.exclusive {
            try await CapabilityProbe().measure(locale: Locale(identifier: "es-ES"))
        }

        // No se afirma un valor: se afirma que es una medida y no un cero ni un absurdo.
        // El umbral de 1,0 no es una elección de diseño, es la definición de tiempo real.
        #expect(measurement.realTimeFactor > 0, "factor cero: no midió nada")
        #expect(measurement.realTimeFactor < 10, "factor absurdo: \(measurement.realTimeFactor)")
        #expect(measurement.isValid(
            machineIdentifier: CapabilityProbe.machineIdentifier(),
            systemVersion: CapabilityProbe.systemVersion()
        ))
    }
}

/// La política de la cola **de la fuente**, que es la otra.
///
/// El camino de audio tiene dos colas en serie: la que crea la fuente y la que interpone la
/// sesión. Una ronda anterior movió la garantía a la de la sesión y dejó esta descubierta:
/// acotar la de `FileSource` a cuatro buffers dejaba el CI en verde y la transcripción de un
/// audio largo caía de 68 caracteres a 8 — el bloqueante 3 de la primera ronda, reintroducible
/// con una línea. Y el carril del fichero es producción: la sonda de capacidad transcribe por
/// ahí, disparada desde un botón de Ajustes.
@Suite("La cola de la fuente")
struct SourceQueuePolicyTests {

    @Test("la fuente de fichero no acota, así que no puede perder audio")
    func fileSourceIsUnbounded() {
        let policy = AudioQueue.sourcePolicy(
            for: .file(URL(fileURLWithPath: "/tmp/x.wav")),
            targetSampleRate: 16000
        )
        guard case .unbounded = policy else {
            Issue.record("la cola del fichero está acotada: mutilaría la transcripción en silencio")
            return
        }
    }

    @Test("la del micrófono acota, y con margen de dos segundos")
    func microphoneSourceIsBounded() {
        guard case .bufferingNewest(let capacity) =
            AudioQueue.sourcePolicy(for: .microphone, targetSampleRate: 16000)
        else {
            Issue.record("la cola del micrófono quedó sin acotar: un retraso crece sin techo")
            return
        }
        // 16 kHz con bloques convertidos de ~1365 marcos: unos 23 buffers para dos segundos.
        // Lo que importa no es el número exacto sino que no sea un puñado: con cuatro, un
        // retraso normal del analizador ya tira habla.
        #expect(capacity >= 16, "capacidad de \(capacity): demasiado poco margen")
    }

    @Test("el criterio de la cola es uno solo, y lo declara la fuente")
    func oneCriterionOwnedByTheSource() throws {
        // Había dos colas decidiendo por su cuenta y eso permitía acotar una sin tocar la
        // otra: el mismo audio perdido en silencio, con la suite en verde. Ahora la sesión
        // pregunta `source.bufferingPolicy`, así que el criterio tiene un solo dueño y este
        // test afirma sobre él, no sobre un envoltorio.
        let target = try #require(
            AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true)
        )
        let fileURL = URL(fileURLWithPath: "/tmp/x.wav")

        guard case .unbounded = FileSource(url: fileURL, target: target).bufferingPolicy,
              case .unbounded = AudioQueue.sourcePolicy(
                  for: .file(fileURL),
                  targetSampleRate: 16000
              )
        else {
            Issue.record("el carril de fichero descarta audio en alguna de sus colas")
            return
        }
    }
}

/// El sellado del bloque convertido, sin micrófono.
///
/// Quitar el `bufferStartTime` del tap dejaba los 324 tests en verde **incluso con el motor
/// real**: `SequenceClockTests` probaba la aritmética del reloj, no que la fuente lo use. Y
/// sin marca, un descarte de la cola no deja un hueco: **empalma** dos trozos de habla
/// distintos, que es fabricar frases que nadie dijo.
@Suite("El bloque convertido va sellado")
struct StampedConverterTests {

    static func formats() throws -> (source: AVAudioFormat, target: AVAudioFormat) {
        let source = try #require(
            AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 1, interleaved: false)
        )
        let target = try #require(
            AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true)
        )
        return (source, target)
    }

    static func buffer(in format: AVAudioFormat, frames: AVAudioFrameCount = 4096) throws -> AVAudioPCMBuffer {
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        // Una onda cualquiera: lo que importa es que el convertidor tenga qué convertir.
        if let channel = buffer.floatChannelData?[0] {
            for index in 0..<Int(frames) {
                channel[index] = Float(sin(Double(index) * 0.01)) * 0.3
            }
        }
        return buffer
    }

    @Test("cada bloque sale con su marca de tiempo")
    func everyBlockIsStamped() throws {
        let (source, target) = try Self.formats()
        let stamped = try #require(StampedConverter(from: source, to: target))

        let first = try #require(stamped.input(from: try Self.buffer(in: source)))
        #expect(first.bufferStartTime != nil, "el bloque salió sin marca: un descarte empalmaría")
        #expect(first.bufferStartTime?.seconds == 0)
    }

    @Test("las marcas avanzan en la base de tiempo del motor")
    func stampsAdvanceInTheEngineTimebase() throws {
        let (source, target) = try Self.formats()
        let stamped = try #require(StampedConverter(from: source, to: target))

        _ = stamped.input(from: try Self.buffer(in: source))
        let second = try #require(stamped.input(from: try Self.buffer(in: source)))

        // 4096 marcos a 48 kHz son ~85 ms; el segundo bloque tiene que empezar ahí, contado
        // en marcos de 16 kHz y no de 48. Contar los de entrada daría tiempos tres veces
        // más largos y el motor colocaría el habla donde no está.
        let start = try #require(second.bufferStartTime?.seconds)
        #expect(start > 0.05 && start < 0.12, "el segundo bloque empieza en \(start) s")
        #expect(stamped.sequenceEnd.seconds > start)
    }

    @Test("un formato de frecuencia cero lo ataja la fuente, no el convertidor")
    func zeroRateIsCaughtBySource() throws {
        let (_, target) = try Self.formats()
        let zeroRate = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 0,
            channels: 1,
            interleaved: false
        )

        // Medido, contra lo que esperaba al escribir este test: `AVAudioFormat` **acepta**
        // 0 Hz y `AVAudioConverter` lo construye igual. O sea que el convertidor no es la
        // barrera; la barrera es la guarda `sourceFormat.sampleRate > 0` de las fuentes
        // (`AudioSources.swift`), que traduce a `noInputDevice` /
        // `incompatibleAudioFormat`. Se deja escrito porque la suposición contraria es la
        // que llevaría a quitar esa guarda por «redundante».
        if let zeroRate {
            #expect(StampedConverter(from: zeroRate, to: target) != nil)
        }
    }
}

/// Que la fuente de fichero **no pierda audio**, contando lo que sale de su cola.
///
/// El test anterior afirmaba sobre `AudioQueue.sourcePolicy` —la función pura— y no sobre
/// que `FileSource` la llamara. Un auditor lo midió: acotar la cola dentro de `start()` a
/// cuatro buffers dejaba el CI en verde y la transcripción de un audio largo caía a siete
/// caracteres. **Cuarta variante del mismo fallo de método** del proyecto: el predicado
/// probado y su sitio de uso no.
///
/// Aquí se ejercita la fuente de verdad: se escribe un fichero con muchos más bloques de
/// los que cabría en una cola acotada, se drena y se cuenta. No hace falta ni micrófono ni
/// modelo de voz, así que corre en CI — que es donde la regresión mergeaba en verde.
@Suite("La fuente de fichero no pierde bloques")
struct FileSourceLosslessTests {

    /// Escribe un `.caf` de N bloques de 4096 marcos a 16 kHz.
    static func writeAudio(chunks: Int) throws -> URL {
        let format = try #require(
            AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)
        )
        let url = FileManager.default.temporaryDirectory
            .appending(path: "ambar-lossless-\(UUID().uuidString).caf")
        let file = try AVAudioFile(forWriting: url, settings: format.settings)

        for index in 0..<chunks {
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096))
            buffer.frameLength = 4096
            if let channel = buffer.floatChannelData?[0] {
                for frame in 0..<4096 {
                    channel[frame] = Float(sin(Double(frame + index * 4096) * 0.01)) * 0.3
                }
            }
            try file.write(from: buffer)
        }
        return url
    }

    @Test("todos los bloques del fichero llegan al otro lado de la cola")
    func everyChunkSurvivesTheQueue() async throws {
        // Veinticuatro bloques: más de los ~23 que cabrían en la cola acotada del
        // micrófono, y muchísimos más que cualquier acotación pequeña.
        let chunks = 24
        let url = try Self.writeAudio(chunks: chunks)
        defer { try? FileManager.default.removeItem(at: url) }

        let target = try #require(
            AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true)
        )
        let source = FileSource(url: url, target: target)
        let stream = try source.start()

        var frames = 0
        var received = 0
        for await input in stream {
            received += 1
            frames += Int(input.buffer.frameLength)
        }
        source.stop()

        // `FileSource` escribe el fichero entero en la cola **antes** de que nadie lo
        // drene: con una cola acotada, todo lo que exceda la capacidad se pierde y nadie
        // se entera. Es exactamente el modo de fallo que costó el bloqueante número uno.
        #expect(
            received == chunks,
            "salieron \(received) bloques de \(chunks): la cola de la fuente está acotada"
        )
        // Y los marcos, que es lo que de verdad se transcribe: 24 × 4096 a 16 kHz.
        #expect(frames == chunks * 4096, "llegaron \(frames) marcos de \(chunks * 4096)")
    }

    @Test("y llegan sellados, para que un hueco sea un hueco")
    func chunksArriveStamped() async throws {
        let url = try Self.writeAudio(chunks: 3)
        defer { try? FileManager.default.removeItem(at: url) }
        let target = try #require(
            AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true)
        )
        let source = FileSource(url: url, target: target)

        var times: [Double] = []
        for await input in try source.start() {
            times.append(input.bufferStartTime?.seconds ?? -1)
        }
        source.stop()

        #expect(times.count == 3)
        #expect(times.allSatisfy { $0 >= 0 }, "algún bloque llegó sin marca: \(times)")
        // Y avanzan: si todos empezaran en cero, el analizador los apilaría en el mismo
        // instante.
        #expect(times == times.sorted() && times[0] < times[2], "las marcas no avanzan: \(times)")
    }
}

/// La **segunda** cola —la que la sesión interpone entre la fuente y el analizador— también
/// tiene que llamar a la política, no escribirla.
///
/// Un auditor midió que sustituirla por `.bufferingNewest(4)` en `SpeechSession.start()`
/// dejaba el CI en verde. Es el mismo carril del bloqueante número uno, un eslabón más
/// abajo: hay **dos** colas en serie y proteger solo una no protege nada.
@Suite("Las dos colas del camino de audio")
struct BothQueuesTests {

    /// El nombre anterior era «…, y la sesión se la pregunta», y esa segunda mitad no la
    /// comprobaba nadie: este test afirma sobre las dos fuentes y nunca toca
    /// `SpeechSession`. Una auditoría lo midió — sustituir `source.bufferingPolicy` por
    /// `.unbounded` en `start()` sobrevivía incluso con el motor real. Que la sesión
    /// pregunte se comprueba ahora donde `start()` corre de verdad, en
    /// `SessionAsksItsSourceForThePolicyTests`.
    @Test("cada fuente declara su propia política")
    func eachSourceOwnsItsPolicy() throws {
        let target = try #require(
            AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true)
        )
        // La política ya no se calcula en dos sitios: la sesión pregunta a la fuente
        // (`source.bufferingPolicy`), así que solo hay una decisión que romper y está aquí.
        guard case .unbounded = FileSource(
            url: URL(fileURLWithPath: "/tmp/x.wav"),
            target: target
        ).bufferingPolicy else {
            Issue.record("la fuente de fichero declara una cola acotada")
            return
        }
        guard case .bufferingNewest(let capacity) = MicrophoneSource(target: target).bufferingPolicy
        else {
            Issue.record("la fuente de micrófono declara una cola sin acotar")
            return
        }
        #expect(capacity >= 16, "capacidad de \(capacity): margen insuficiente")
    }

    @Test("las dos fuentes declaran criterios opuestos, y es deliberado")
    func sourcesDeclareOppositeCriteria() throws {
        let target = try #require(
            AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true)
        )

        // Fichero: sin acotar. No tiene ritmo propio, así que lo que hay que preservar es el
        // audio íntegro y el productor puede esperar.
        guard case .unbounded = FileSource(
            url: URL(fileURLWithPath: "/tmp/x.wav"),
            target: target
        ).bufferingPolicy else {
            Issue.record("el carril de fichero descarta audio")
            return
        }

        // Micrófono: acotada. No espera a nadie, así que lo que hay que preservar es el
        // tiempo real y lo viejo se tira. Equivocar cualquiera de los dos criterios no da
        // error: pierde audio, o crece sin techo, en silencio.
        guard case .bufferingNewest(let capacity) = MicrophoneSource(target: target).bufferingPolicy
        else {
            Issue.record("el carril de micrófono crece sin techo")
            return
        }
        #expect(capacity >= 16, "capacidad de \(capacity): margen insuficiente")
    }
}

/// La contabilidad del resultado final, en la sesión **real**.
///
/// Decide si una entrega por vencimiento del techo se confiesa como recortada (§7.2). El
/// único test que cubría esa rama usa un doble que sobrescribe el método, así que la
/// contabilidad de verdad no se ejercitaba nunca: `sawFinalResult = isFinal` → `= false`
/// dejaba la suite en verde y habría marcado como incompleto todo dictado que sí estaba
/// completo — confesando una pérdida que no ocurrió.
@Suite("El resultado final se contabiliza")
struct FinalResultAccountingTests {

    @Test("sin resultado final, la sesión lo dice")
    func noFinalResultYet() async {
        let session = SpeechSession(locale: Locale(identifier: "es-ES"), mode: .live)
        await session.recordForTesting("hola", isFinal: false)
        #expect(await session.hasFinalResultIfAvailable() == false)
    }

    @Test("con resultado final, también")
    func finalResultIsRemembered() async {
        let session = SpeechSession(locale: Locale(identifier: "es-ES"), mode: .live)
        await session.recordForTesting("hola mundo", isFinal: true)
        #expect(
            await session.hasFinalResultIfAvailable(),
            "no recordó el resultado final: toda entrega por techo se confesaría recortada"
        )
    }

    @Test("manda el último resultado, no el mejor que hubo")
    func theLastResultWins() async {
        // Escribí este test esperando lo contrario —«un volátil posterior no borra el
        // final»— y falló. El comportamiento real es el correcto y conviene dejarlo fijado:
        // la pregunta que responde este estado es «¿está la frase cerrada **ahora**?», y un
        // resultado volátil posterior significa que el motor volvió a abrirla.
        //
        // Equivocarse hacia el otro lado sería peor: entregar como completo un texto que el
        // motor todavía estaba reescribiendo, sin confesar el recorte que §7.2 exige.
        let session = SpeechSession(locale: Locale(identifier: "es-ES"), mode: .live)
        await session.recordForTesting("hola mundo", isFinal: true)
        #expect(await session.hasFinalResultIfAvailable())

        await session.recordForTesting("hola mundo cru", isFinal: false)
        #expect(
            await session.hasFinalResultIfAvailable() == false,
            "una frase reabierta se daría por cerrada"
        )
    }
}

/// Las dos garantías que solo vivían detrás del gate del CI.
///
/// Nueve tests del motor se saltan en integración continua porque el runner no trae el
/// modelo de voz. Medido por una auditoría: con ese gate puesto se podían **borrar enteros**
/// el techo de la sesión y la liberación de la ranura de idioma sin un solo rojo. Y el
/// primero, sin el gate, tampoco daba rojo: colgaba la suite doce minutos, que es peor —un
/// cuelgue no se lee como regresión, se lee como «la máquina va lenta».
@Suite("Garantías que el gate del CI ocultaba")
struct GuardsBehindTheGateTests {

    static let locale = Locale(identifier: "es-ES")
    typealias SpyCatalog = SessionWiringTests.SpyCatalog


    @Test("el techo de duración cierra la sesión aunque nadie toque el micrófono")
    func sessionLimitClosesWithoutEngine() async throws {
        let session = SpeechSession(locale: Locale(identifier: "es-ES"), mode: .live)
        await session.recordForTesting("dos minutos de conversación ajena")

        await session.startSessionLimitForTesting(after: .milliseconds(120))

        // Espera ACTIVA, no un `sleep` fijo. El original dormía 400 ms para un techo de 120
        // y pasaba en la máquina de desarrollo; en el runner de CI —más lento y con varios
        // jobs compitiendo— el temporizador no había disparado todavía y el test fallaba
        // por la holgura, no por la garantía. Un test que depende de cuánto tarda la máquina
        // no mide lo que dice medir.
        //
        // El plazo es generoso a propósito y NO afloja la garantía: si el techo se borra, la
        // sesión no cierra nunca y esto falla igual, solo que cinco segundos más tarde. En el
        // caso bueno termina en ~130 ms, más rápido que el sleep que sustituye.
        var cerrada = false
        for _ in 0..<100 {
            if await session.isClosed { cerrada = true; break }
            try? await Task.sleep(for: .milliseconds(50))
        }

        // La garantía es del temporizador, no del motor: una tecla enclavada no puede dejar
        // el micrófono abierto indefinidamente, y eso tiene que ser cierto también cuando el
        // modelo de voz no está instalado.
        #expect(cerrada, "el techo no cerró la sesión")
        #expect(await session.accumulatedTextForTesting.isEmpty, "el techo no borró lo dictado")
    }

    @Test("cerrar la sesión devuelve la ranura de idioma")
    func teardownReleasesTheReservation() async throws {
        let catalog = SpyCatalog(availability: .installed)
        _ = try await catalog.reserve(locale: Self.locale)
        #expect(await catalog.isHeld(Self.locale))

        let session = SpeechSession(locale: Self.locale, mode: .live, catalog: catalog)
        await session.markReservedAndTeardownForTesting()

        // Una de las cinco ranuras de toda la máquina, por cada dictado. La fuga solo se ve
        // en otra app, más tarde, sin relación aparente con lo que se rompió.
        #expect(
            await catalog.isHeld(Self.locale) == false,
            "cerrar la sesión no devolvió la ranura: fuga por dictado"
        )
    }
}

/// Que todo el ciclo de la reserva hable del **mismo** idioma.
///
/// Medido contra el framework: `supportedLocale(equivalentTo:)` no es determinista cuando el
/// idioma pedido no casa exacto —`de_ES` devuelve `de_AT`, `de_CH` o `de_DE` en llamadas
/// distintas del mismo proceso—, y `prepare()` resolvía por su cuenta en cuatro sitios.
/// Reservar una variante y soltar otra fuga una de las cinco ranuras de toda la máquina, y
/// solo se ve en otra app, más tarde. Invisible donde el idioma casa exacto, que es la
/// máquina de quien lo desarrolla.
@Suite("La reserva habla de un solo idioma")
struct SingleResolvedLocaleTests {

    /// Catálogo que **cambia de variante en cada llamada**, como el framework real.
    actor DriftingCatalog: ModelCatalog {
        private var calls = 0
        private var held: Set<String> = []
        private let variants = ["de_AT", "de_CH", "de_DE"]

        func supportedLocale(equivalentTo locale: Locale) async -> Locale? {
            defer { calls += 1 }
            return Locale(identifier: variants[calls % variants.count])
        }
        func availability(forLocale locale: Locale) async -> ModelAvailability { .supported }
        func installModel(
            forLocale locale: Locale,
            onProgress: @Sendable @escaping (Double) -> Void
        ) async throws {}
        func installationSize(forLocale locale: Locale) async -> Int64? { nil }
        func reserve(locale: Locale) async throws -> Bool {
            held.insert(locale.identifier).inserted
        }
        func release(locale: Locale) async { held.remove(locale.identifier) }
        func reservation() async -> (maximum: Int, reserved: [Locale]) {
            (5, held.map { Locale(identifier: $0) })
        }
        func endModelRetention() async {}
        var stillHeld: [String] { held.sorted() }
    }

    @Test("con un catálogo que devuelve variantes distintas, no queda nada reservado")
    func driftingResolutionDoesNotLeak() async throws {
        let catalog = DriftingCatalog()
        let session = SpeechSession(
            locale: Locale(identifier: "de_ES"),
            mode: .live,
            catalog: catalog
        )

        // `prepare()` falla —el modelo dice no estar instalado— y en ese camino tiene que
        // soltar lo que reservó. Si resolviera por separado en cada paso, soltaría una
        // variante distinta de la reservada.
        await #expect(throws: DictationEngineError.modelNotInstalled) {
            try await session.prepare()
        }

        let leaked = await catalog.stillHeld
        #expect(leaked.isEmpty, "quedaron ranuras cogidas: \(leaked)")
    }
}

/// Que un dictado con pausas **no pierda lo anterior**.
///
/// Medido con audio real: el motor cierra una frase y empieza la siguiente **desde cero** —
/// «Primera frase de la conversación» (32 caracteres) y a continuación «segunda» (8)—. La
/// sesión asignaba el último resultado, así que cada frase nueva borraba todo lo dicho antes.
/// En una frase suelta no se nota; en una conversación larga se pierde todo menos el final,
/// que es exactamente como se reportó: «el texto nuevo va machacando al anterior».
@Suite("Un dictado con pausas conserva lo dicho")
struct AccumulationTests {

    @Test("lo cerrado se acumula y solo la hipótesis se reemplaza")
    func finalizedSegmentsAccumulate() async {
        let session = SpeechSession(locale: Locale(identifier: "es-ES"), mode: .live)

        // Primera frase: hipótesis que se refina y cierra.
        await session.recordForTesting("Primera frase", isFinal: false)
        await session.recordForTesting("Primera frase de la conversación", isFinal: true)
        #expect(await session.accumulatedText == "Primera frase de la conversación")

        // Segunda frase: el motor empieza de cero, y eso NO puede borrar la primera.
        await session.recordForTesting("segunda", isFinal: false)
        let trasSegunda = await session.accumulatedText
        #expect(
            trasSegunda == "Primera frase de la conversación segunda",
            "perdió lo anterior: «\(trasSegunda)»"
        )

        await session.recordForTesting("segunda frase que habla de otra cosa", isFinal: true)
        await session.recordForTesting("tercera y última", isFinal: false)
        #expect(
            await session.accumulatedText
                == "Primera frase de la conversación segunda frase que habla de otra cosa tercera y última"
        )
    }

    @Test("lo que ve el panel es lo acumulado, no el tramo suelto")
    func publishedTextIsTheAccumulatedOne() async {
        // La mitad del arreglo que el usuario **ve**. Guardar bien y enseñar mal es
        // indistinguible de perder el texto: el panel es la única prueba que él tiene.
        // Por eso lo publicado es el valor de retorno de `record`, y se comprueba ahí:
        // comprobarlo en una propiedad aparte dejaba el sitio de publicación sin cubrir.
        let session = SpeechSession(locale: Locale(identifier: "es-ES"), mode: .live)

        _ = await session.recordForTesting("Primera frase cerrada", isFinal: true)
        let publicado = await session.recordForTesting("segunda", isFinal: false)
        #expect(
            publicado == "Primera frase cerrada segunda",
            "el panel enseñaría «\(publicado)» mientras la sesión guarda el resto"
        )

        let cerrado = await session.recordForTesting("segunda frase entera", isFinal: true)
        #expect(cerrado == "Primera frase cerrada segunda frase entera")
    }

    @Test("la hipótesis se sustituye, no se acumula")
    func volatileHypothesisIsReplaced() async {
        // Si la hipótesis se acumulara, cada refinamiento duplicaría palabras: «hola hola
        // mundo hola mundo cruel». Es el error simétrico y sería igual de visible.
        let session = SpeechSession(locale: Locale(identifier: "es-ES"), mode: .live)
        await session.recordForTesting("hola", isFinal: false)
        await session.recordForTesting("hola mundo", isFinal: false)
        await session.recordForTesting("hola mundo cruel", isFinal: false)
        #expect(await session.accumulatedText == "hola mundo cruel")
    }

    @Test("la costura no come ni duplica espacios")
    func seamsAreClean() {
        #expect(SpeechSession.join("Primera frase", "segunda") == "Primera frase segunda")
        // Los tramos llegan con espacio inicial cuando continúan una frase.
        #expect(SpeechSession.join("Primera frase", " segunda") == "Primera frase segunda")
        #expect(SpeechSession.join("", "primera") == "primera")
        #expect(SpeechSession.join("ya escrito", "   ") == "ya escrito")
    }

    @Test("el techo de sesión ya no corta una conversación, pero sigue siendo un techo")
    func theCapFitsALongConversation() {
        // Con el gesto de mantener, dos minutos eran de sobra. Ahora el gesto solo arranca y
        // las manos quedan libres, así que el techo dejó de ser un límite de uso normal: con
        // 120 s, quien dictaba una conversación la perdía entera al vencer.
        #expect(SpeechSession.defaultMaximumSessionDuration >= .seconds(20 * 60))

        // Y la otra mitad, que faltaba: **acotado por arriba**. Medido por una auditoría
        // independiente, subir el techo a 24 horas dejaba la suite verde — es decir, la
        // razón de existir del techo («que el micrófono no se quede abierto si alguien se
        // olvida del panel», §7.3) no la afirmaba nadie. Un techo solo acotado por abajo
        // no es un techo: es un mínimo con otro nombre.
        #expect(
            SpeechSession.defaultMaximumSessionDuration <= .seconds(60 * 60),
            "el techo dejó de acotar: el micrófono podría quedarse abierto horas"
        )
    }
}

/// La cola de silencio va **al final**, no al principio.
///
/// Ahora que cada bloque de audio viaja sellado, un `AnalyzerInput` sin marca se coloca en
/// el instante cero: el silencio que existe para cerrar la última palabra pasaría a competir
/// con la primera. La marca se podía borrar con la suite entera en verde —y el efecto no se
/// ve en un dictado corto, sino en el final de uno largo, que es donde nadie mira.
@Suite("El silencio de cierre va sellado")
struct SilenceTailStampTests {

    /// Fuente que solo sabe decir dónde acabó. Es lo único que la cola de silencio le
    /// pregunta.
    struct EndedSource: AudioSource {
        let end: CMTime?
        func start() throws -> AsyncStream<AnalyzerInput> { AsyncStream { $0.finish() } }
        var sequenceEnd: CMTime? { end }
        func stop() {}
        var bufferingPolicy: AsyncStream<AnalyzerInput>.Continuation.BufferingPolicy { .unbounded }
    }

    static func format() throws -> AVAudioFormat {
        try #require(AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true))
    }

    @Test("el silencio se sella donde acabó lo dictado")
    func silenceIsStampedAtTheEnd() async throws {
        let session = SpeechSession(locale: Locale(identifier: "es-ES"), mode: .live)
        // Treinta segundos de audio entregados: el final de la secuencia.
        let end = CMTime(value: 480_000, timescale: 16000)
        await session.setSourceForTesting(EndedSource(end: end))

        let input = try #require(await session.silenceInput(in: Self.format()))
        #expect(
            input.bufferStartTime == end,
            "el silencio se colocaría en \(input.bufferStartTime.map(String.init(describing:)) ?? "el instante cero")"
        )
    }

    @Test("sin fuente no se inventa una marca")
    func withoutASourceThereIsNoStamp() async throws {
        // El caso degenerado tiene que quedar como estaba: sin fuente no hay secuencia, y
        // fabricar un cero sería peor que no marcar.
        let session = SpeechSession(locale: Locale(identifier: "es-ES"), mode: .live)
        await session.setSourceForTesting(EndedSource(end: nil))
        let input = try #require(await session.silenceInput(in: Self.format()))
        #expect(input.bufferStartTime == nil)
    }
}
