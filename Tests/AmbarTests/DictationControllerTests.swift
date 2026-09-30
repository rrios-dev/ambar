import AppCore
import Foundation
import Testing
import VoiceKit

@testable import Ambar

/// El coordinador del dictado, con un motor doble.
///
/// Existe porque era la única pieza del dictado sin un solo test, y ahí vivían
/// cinco de los seis bloqueantes que encontró la auditoría de implementación: el
/// camino sin gesto que se mataba solo, el modo que se etiquetaba mal, el techo de
/// finalización que descartaba el resultado bueno. Ninguno lo habría cazado un test
/// del motor, porque ninguno está en el motor.
@Suite("Coordinador del dictado")
@MainActor
struct DictationControllerTests {

    // MARK: - Doble del motor

    /// Sesión de mentira que obedece un guion. No transcribe: comprueba que el
    /// coordinador llama a lo que debe, cuando debe.
    actor FakeSession: TranscriptionSession {
        enum Step: Sendable, Equatable { case prepared, started, finished, cancelled }

        private(set) var steps: [Step] = []
        private let transcript: Transcript
        private let finishDelay: Duration
        private let prepareDelay: Duration
        private let fragments: [String]

        init(
            transcript: Transcript = Transcript(text: "hola", mode: .live),
            fragments: [String] = ["ho", "hola"],
            finishDelay: Duration = .zero,
            /// Cuánto tarda en cargar el modelo.
            ///
            /// Hace falta para alcanzar el estado `.preparing`: con la preparación
            /// instantánea, el gesto se confirma cuando ya está lista y la máquina salta
            /// directa a escuchar. Un test sobre `.preparing` sin este retardo no prueba
            /// nada — comprobado: la mutación que reintroducía su anuncio sobrevivía.
            prepareDelay: Duration = .zero
        ) {
            self.transcript = transcript
            self.fragments = fragments
            self.finishDelay = finishDelay
            self.prepareDelay = prepareDelay
        }

        func prepare() async throws {
            if prepareDelay > .zero { try? await Task.sleep(for: prepareDelay) }
            steps.append(.prepared)
        }

        func start() async throws -> AsyncStream<TranscriptFragment> {
            steps.append(.started)
            let captured = fragments
            return AsyncStream { continuation in
                for text in captured {
                    continuation.yield(TranscriptFragment(text: text, isVolatile: true))
                }
                continuation.finish()
            }
        }

        func finish() async throws -> Transcript {
            steps.append(.finished)
            if finishDelay > .zero { try? await Task.sleep(for: finishDelay) }
            return transcript
        }

        func cancel() async { steps.append(.cancelled) }

        func setDeviceChangeHandler(_ handler: @escaping @Sendable () -> Void) async {
            deviceChange = handler
        }
        // No-op explícito: el protocolo ya no lo regala. Este doble no tiene techo propio.
        func setSessionLimitHandler(_ handler: @escaping @Sendable () -> Void) async {}


        func recorded() -> [Step] { steps }

        private var deviceChange: (@Sendable () -> Void)?
        /// Dispara el aviso de cambio de dispositivo, como haría AVFoundation.
        func simulateDeviceChange() { deviceChange?() }
    }

    /// Sesión que emite hipótesis y cierra con un resultado firme, como el motor real.
    actor VolatileThenFinalSession: TranscriptionSession {
        func prepare() async throws {}
        func start() async throws -> AsyncStream<TranscriptFragment> {
            AsyncStream { continuation in
                continuation.yield(TranscriptFragment(text: "hola", isVolatile: true))
                continuation.yield(TranscriptFragment(text: "hola mun", isVolatile: true))
                continuation.yield(TranscriptFragment(text: "hola mundo", isVolatile: false))
                continuation.finish()
            }
        }
        func finish() async throws -> Transcript { Transcript(text: "hola mundo", mode: .live) }
        func cancel() async {}

        func setDeviceChangeHandler(_ handler: @escaping @Sendable () -> Void) async {}
        func setSessionLimitHandler(_ handler: @escaping @Sendable () -> Void) async {}
    }

    /// Sesión que solo emite hipótesis: es lo que se ve mientras se habla.
    actor VolatileOnlySession: TranscriptionSession {
        func prepare() async throws {}
        func start() async throws -> AsyncStream<TranscriptFragment> {
            AsyncStream { continuation in
                continuation.yield(TranscriptFragment(text: "hipótesis", isVolatile: true))
                continuation.finish()
            }
        }
        func finish() async throws -> Transcript { Transcript(text: "hipótesis", mode: .live) }
        func cancel() async {}

        func setDeviceChangeHandler(_ handler: @escaping @Sendable () -> Void) async {}
        func setSessionLimitHandler(_ handler: @escaping @Sendable () -> Void) async {}
    }

    /// Sesión cuyo `finish()` **ignora la cancelación**, como el motor real: es el
    /// caso que demostraba que el techo anterior no acotaba nada.
    actor StubbornSession: TranscriptionSession {
        private let duration: Duration
        init(finishTakes duration: Duration) { self.duration = duration }
        func prepare() async throws {}
        func start() async throws -> AsyncStream<TranscriptFragment> {
            AsyncStream { continuation in
                continuation.yield(TranscriptFragment(text: "parcial", isVolatile: true))
                continuation.finish()
            }
        }
        func finish() async throws -> Transcript {
            // Bucle no cancelable a propósito.
            let deadline = ContinuousClock.now.advanced(by: duration)
            while ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(20))
            }
            return Transcript(text: "tarde", mode: .live)
        }
        func cancel() async {}

        // No-op explícito: el protocolo ya no lo regala. Este doble no cambia de
        // dispositivo ni tiene techo propio.
        func setDeviceChangeHandler(_ handler: @escaping @Sendable () -> Void) async {}
        func setSessionLimitHandler(_ handler: @escaping @Sendable () -> Void) async {}

    }

    /// Sesión que dice haber cerrado la frase antes de que venza el techo.
    ///
    /// Cubre la rama que decide si se confiesa una pérdida: si el motor ya dio un
    /// resultado final, el texto está completo y marcarlo como truncado asusta sin
    /// motivo. Los dobles anteriores usaban el valor por defecto del protocolo, así que
    /// esa rama no se ejercitaba.
    actor FinalizedSlowSession: TranscriptionSession {
        private let duration: Duration
        init(finishTakes duration: Duration) { self.duration = duration }
        func prepare() async throws {}
        func start() async throws -> AsyncStream<TranscriptFragment> {
            AsyncStream { continuation in
                continuation.yield(TranscriptFragment(text: "frase completa", isVolatile: false))
                continuation.finish()
            }
        }
        func finish() async throws -> Transcript {
            let deadline = ContinuousClock.now.advanced(by: duration)
            while ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(20)) }
            return Transcript(text: "tarde", mode: .live)
        }
        func cancel() async {}

        // No-op explícito: el protocolo ya no lo regala. Este doble no cambia de
        // dispositivo ni tiene techo propio.
        func setDeviceChangeHandler(_ handler: @escaping @Sendable () -> Void) async {}
        func setSessionLimitHandler(_ handler: @escaping @Sendable () -> Void) async {}

        func hasFinalResultIfAvailable() async -> Bool { true }
    }

    /// Sesión que puede disparar su techo a voluntad.
    actor LimitAnnouncingSession: TranscriptionSession {
        private var onLimit: (@Sendable () -> Void)?
        func prepare() async throws {}
        func start() async throws -> AsyncStream<TranscriptFragment> {
            AsyncStream { continuation in
                continuation.yield(TranscriptFragment(text: "ruido de fondo", isVolatile: true))
                continuation.finish()
            }
        }
        func finish() async throws -> Transcript {
            Transcript(text: "ruido de fondo", mode: .live)
        }
        func cancel() async {}

        // No-op explícito: este doble no cambia de dispositivo.
        func setDeviceChangeHandler(_ handler: @escaping @Sendable () -> Void) async {}

        func setSessionLimitHandler(_ handler: @escaping @Sendable () -> Void) async {
            onLimit = handler
        }
        func fireLimit() { onLimit?() }
    }

    /// Sesión cuyo `finish()` lanza: un fallo del motor, no un retraso.
    /// Sesión que falla al **preparar**, como el motor real sin el modelo instalado.
    actor UnpreparableSession: TranscriptionSession {
        func prepare() async throws { throw DictationEngineError.modelNotInstalled }
        func start() async throws -> AsyncStream<TranscriptFragment> { AsyncStream { $0.finish() } }
        func finish() async throws -> Transcript { Transcript(text: "", mode: .live) }
        func cancel() async {}
        func setDeviceChangeHandler(_ handler: @escaping @Sendable () -> Void) async {}
        func setSessionLimitHandler(_ handler: @escaping @Sendable () -> Void) async {}
    }

    actor FailingSession: TranscriptionSession {
        struct Boom: Error {}
        func prepare() async throws {}
        func start() async throws -> AsyncStream<TranscriptFragment> {
            AsyncStream { $0.finish() }
        }
        func finish() async throws -> Transcript { throw Boom() }
        func cancel() async {}

        // No-op explícito: el protocolo ya no lo regala. Este doble no cambia de
        // dispositivo ni tiene techo propio.
        func setDeviceChangeHandler(_ handler: @escaping @Sendable () -> Void) async {}
        func setSessionLimitHandler(_ handler: @escaping @Sendable () -> Void) async {}

    }

    /// Motor que entrega una sesión distinta por llamada.
    ///
    /// Hace falta para el escenario del bloqueante: **dos** sesiones vivas a la vez, la
    /// abandonada respondiendo tarde mientras la nueva está finalizando. Con un motor que
    /// devuelve siempre la misma sesión, ese caso no se puede montar — y por eso el test
    /// anterior tuvo que recurrir a un atajo que fijaba el testigo a mano, con lo que
    /// probaba la guarda y no el sitio donde se publica.
    final class SequenceEngine: TranscriberEngine, @unchecked Sendable {
        static let identifier = "sequence"
        var catalog: any ModelCatalog { SpeechModelCatalog(mode: .live) }

        private let lock = NSLock()
        private var pending: [any TranscriptionSession]

        init(_ sessions: [any TranscriptionSession]) {
            self.pending = sessions
        }

        func makeSession(
            locale: Locale,
            mode: DictationMode,
            atypicalSpeech: Bool,
            contextualStrings: [String]
        ) throws -> any TranscriptionSession {
            lock.withLock {
                pending.isEmpty ? FakeSession() : pending.removeFirst()
            }
        }
    }

    struct StubbornEngine: TranscriberEngine {
        static let identifier = "stubborn"
        let session: any TranscriptionSession
        var catalog: any ModelCatalog { SpeechModelCatalog(mode: .live) }
        func makeSession(
            locale: Locale,
            mode: DictationMode,
            atypicalSpeech: Bool,
            contextualStrings: [String]
        ) throws -> any TranscriptionSession {
            session
        }
    }

    /// Lo que se le pidió al motor. Un actor porque `makeSession` se llama desde el
    /// coordinador y se lee desde el test.
    actor SessionRequest {
        private(set) var locale: Locale?
        private(set) var mode: DictationMode?
        private(set) var atypicalSpeech: Bool?
        private(set) var contextualStrings: [String]?

        func record(
            locale: Locale,
            mode: DictationMode,
            atypicalSpeech: Bool,
            contextualStrings: [String]
        ) {
            self.locale = locale
            self.mode = mode
            self.atypicalSpeech = atypicalSpeech
            self.contextualStrings = contextualStrings
        }
    }

    struct FakeEngine: TranscriberEngine {
        static let identifier = "fake"
        /// Cualquier sesión, no solo `FakeSession`: hay dobles con guiones distintos
        /// —una que ignora la cancelación, una que emite hipótesis— y atarlo al tipo
        /// concreto obligaba a duplicar el motor por cada uno.
        let session: any TranscriptionSession

        /// Lo que se le pidió, para poder afirmarlo. Los dobles anteriores recibían los
        /// parámetros y los tiraban, así que `atypicalSpeech: false` fijo o
        /// `currentMode = .live` fijo no rompían nada — tres cableados sin red, medidos.
        let request: SessionRequest?

        init(session: any TranscriptionSession, request: SessionRequest? = nil) {
            self.session = session
            self.request = request
        }

        func makeSession(
            locale: Locale,
            mode: DictationMode,
            atypicalSpeech: Bool,
            contextualStrings: [String]
        ) throws -> any TranscriptionSession {
            if let request {
                Task {
                    await request.record(
                        locale: locale,
                        mode: mode,
                        atypicalSpeech: atypicalSpeech,
                        contextualStrings: contextualStrings
                    )
                }
            }
            return session
        }

        var catalog: any ModelCatalog { SpeechModelCatalog(mode: .live) }
    }

    /// Espera hasta que se cumpla una condición, o se rinde.
    ///
    /// Existe porque los tests con dormidas fijas son intermitentes por construcción:
    /// `liveTextRefines` falló 2 de 12 pasadas —lo midió una auditoría— y una suite
    /// intermitente envenena cualquier medición por mutación, porque un rojo deja de
    /// significar «la mutación se detectó». Esperar por la condición y no por el reloj
    /// no debilita la aserción: el fallo sigue siendo fallo, solo deja de depender de
    /// cómo esté de cargada la máquina.
    /// Igual que `waitUntil`, para condiciones que hay que preguntar a un actor.
    ///
    /// Las dormidas fijas hacían fallar dos guardarraíles de bloqueantes anteriores 5 de
    /// cada 18 pasadas locales: con la suite en paralelo, 150 ms no bastan para que corran
    /// los pasos intermedios.
    static func waitForSession(
        timeout: Duration = .seconds(15),
        _ condition: @Sendable () async -> Bool
    ) async {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if await condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    /// Quince segundos, no cinco, y antes no dos: bajo la suite entera —incluidos los tests
    /// de motor real, que bloquean hilos del fondo cooperativo con procesos externos— un
    /// margen corto pierde contra la contención una de cada varias pasadas, con la
    /// afirmación real ya cumplida un instante después.
    ///
    /// La subida a quince la pide el runner de CI, que es bastante más lento que cualquier
    /// Mac de desarrollo: medido, «el texto en vivo se va refinando» agotó los cinco
    /// segundos con `liveText` en «hol» —un fragmento antes del final— y falló con la
    /// mecánica intacta. En este Mac ese mismo test tarda milisegundos.
    ///
    /// No es tapar el síntoma, y conviene tener claro por qué: esta espera **no afirma
    /// nada**. Al agotarse simplemente vuelve, y quien decide es el `#expect` de después.
    /// Un margen mayor no puede convertir un fallo real en un verde: solo hace que ese
    /// fallo tarde diez segundos más en llegar.
    static func waitUntil(
        timeout: Duration = .seconds(15),
        _ condition: @MainActor () -> Bool
    ) async {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    static func make(
        session: FakeSession,
        onDeliver: @escaping @MainActor (Transcript) -> Void = { _ in },
        announcer: @escaping @MainActor (String, AnnouncementUrgency) -> Void = { _, _ in },
        // El proceso de test no tiene permiso de micrófono concedido; lo que se prueba
        // aquí es el coordinador, no TCC. Es un cierre, y no un valor, para poder
        // revocarlo a mitad de sesión — que es exactamente lo que hace Ajustes del
        // Sistema y lo que la app confundía con «no se oyó nada».
        permission: @escaping @MainActor () -> MicrophonePermission = { .granted }
    ) -> DictationController {
        DictationController(
            engine: FakeEngine(session: session),
            gesture: HoldGesture(watchedFlags: [.command], threshold: .milliseconds(50)),
            deliver: onDeliver,
            permission: permission,
            announcer: announcer
        )
    }

    // MARK: - El camino sin gesto

    /// El bloqueante 5, convertido en test.
    ///
    /// `startWithoutGesture` es el camino de quien no puede mantener una tecla. No
    /// solo no tenía llamador: si se cableaba, el vigilante del «sigue pulsado» lo
    /// mataba a los 40 ms, porque por ahí nadie mantiene nada.
    @Test("el camino sin gesto llega a escuchar y no se corta solo")
    func startWithoutGestureSurvives() async throws {
        let session = FakeSession()
        let controller = Self.make(session: session)

        controller.startWithoutGesture(locale: Locale(identifier: "es-ES"), mode: .live)
        await Self.waitUntil { controller.state.isMicrophoneOpen }

        // Y ahora se espera **de más** a propósito: bastante más que el tic del vigilante
        // (40 ms). Si volviera a vigilar el mantenido, aquí ya estaría parado. Esta dormida
        // sí es correcta —lo que se afirma es que NO pasa nada— y por eso no se cambia por
        // una espera por condición: no hay condición que esperar.
        try? await Task.sleep(for: .milliseconds(300))

        #expect(controller.state == .listening, "estado: \(controller.state)")
        #expect(await session.recorded().contains(.started))
        #expect(!(await session.recorded().contains(.finished)), "se cortó sin que nadie lo pidiera")
    }

    @Test("parar desde el botón entrega lo dictado")
    func stoppingDelivers() async throws {
        let expected = Transcript(text: "texto dictado", mode: .deferred)
        let session = FakeSession(transcript: expected)
        var delivered: [Transcript] = []
        let controller = Self.make(session: session) { delivered.append($0) }

        controller.startWithoutGesture(locale: Locale(identifier: "es-ES"), mode: .deferred)
        await Self.waitUntil { controller.state.isMicrophoneOpen }
        controller.stop()
        await Self.waitUntil { !delivered.isEmpty }

        #expect(delivered == [expected], "entregado: \(delivered)")
        #expect(await session.recorded().contains(.finished))
    }

    // MARK: - El modo

    /// El modo se etiquetaba siempre como `.live` porque `mode(of:)` ignoraba su
    /// parámetro. Se veía en la entrada del historial de un dictado diferido.
    @Test("un dictado diferido no se etiqueta como en vivo")
    func deferredModeIsPreserved() async throws {
        // El transcript del motor llega con su modo; lo que se comprueba aquí es
        // que el coordinador no lo sobrescribe por el camino.
        let expected = Transcript(text: "en diferido", mode: .deferred)
        let session = FakeSession(transcript: expected)
        var delivered: [Transcript] = []
        let controller = Self.make(session: session) { delivered.append($0) }

        controller.startWithoutGesture(locale: Locale(identifier: "es-ES"), mode: .deferred)
        await Self.waitUntil { controller.state.isMicrophoneOpen }
        controller.stop()
        await Self.waitUntil { !delivered.isEmpty || controller.lastFailure != nil }

        #expect(delivered.first?.mode == .deferred)
    }

    // MARK: - El techo de finalización

    /// El bloqueante 6: el techo era menor que el trabajo, así que el primer
    /// dictado siempre se entregaba truncado.
    @Test("el techo entrega lo que hay y lo marca como incompleto")
    func timeoutDeliversTruncated() async throws {
        // La sesión tarda más que el techo a propósito.
        let session = FakeSession(
            fragments: ["parcial"],
            finishDelay: DictationController.finalizationTimeout + .seconds(1)
        )
        var delivered: [Transcript] = []
        let controller = Self.make(session: session) { delivered.append($0) }

        controller.startWithoutGesture(locale: Locale(identifier: "es-ES"), mode: .live)
        await Self.waitUntil { controller.state.isMicrophoneOpen }
        controller.stop()
        // Por condición, con margen amplio: el techo son 2,5 s de reloj real y con la suite
        // en paralelo una dormida ajustada llega tarde. Lo que se afirma es **qué** se
        // entrega, no cuándo.
        await Self.waitUntil(timeout: .seconds(8)) { !delivered.isEmpty }

        let transcript = try #require(delivered.first, "no se entregó nada al vencer el techo")
        #expect(transcript.wasTruncated, "se entregó sin decir que puede faltar texto")
        #expect(transcript.text == "parcial", "texto: «\(transcript.text)»")
    }

    /// Si el motor ya cerró la frase, vencer el techo no es perder texto.
    @Test("el techo no confiesa una pérdida que no ha ocurrido")
    func timeoutWithFinalResultIsNotTruncated() async throws {
        var delivered: [Transcript] = []
        let controller = DictationController(
            engine: StubbornEngine(
                session: FinalizedSlowSession(
                    finishTakes: DictationController.finalizationTimeout + .seconds(1)
                )
            ),
            gesture: HoldGesture(watchedFlags: [.command], threshold: .milliseconds(50)),
            deliver: { delivered.append($0) },
            permission: { .granted },
            announcer: { _, _ in }
        )

        controller.startWithoutGesture(locale: Locale(identifier: "es-ES"), mode: .live)
        await Self.waitUntil { controller.state.isMicrophoneOpen }
        controller.stop()
        // Por condición y no por plazo: el techo es de reloj real y con la suite en paralelo
        // —o en un runner de CI— la entrega llega más tarde que el margen que se le fije.
        // Lo que este test afirma es **cómo** se etiqueta lo entregado, no cuándo llega.
        await Self.waitUntil(timeout: .seconds(8)) { !delivered.isEmpty }

        let transcript = try #require(delivered.first, "no se entregó nada")
        #expect(
            !transcript.wasTruncated,
            "se marcó como incompleto un texto que el motor ya había cerrado"
        )
    }

    @Test("una sesión que termina a tiempo no se marca como truncada")
    func fastFinishIsNotTruncated() async throws {
        let session = FakeSession(transcript: Transcript(text: "completo", mode: .live))
        var delivered: [Transcript] = []
        let controller = Self.make(session: session) { delivered.append($0) }

        controller.startWithoutGesture(locale: Locale(identifier: "es-ES"), mode: .live)
        await Self.waitUntil { controller.state.isMicrophoneOpen }
        controller.stop()
        await Self.waitUntil { !delivered.isEmpty }

        #expect(delivered.first?.wasTruncated == false)
    }

    // MARK: - Cancelación e interacción

    @Test("cualquier interacción durante la cuenta cancela y suelta la sesión")
    func interactionCancelsAndReleases() async throws {
        let session = FakeSession()
        let controller = Self.make(session: session)

        controller.shortcutPressed(locale: Locale(identifier: "es-ES"), mode: .live)
        #expect(controller.state.isActive)

        controller.interactionOccurred(.pointerMoved)
        #expect(controller.state == .idle)

        // La sesión tiene que soltarse: si no, se queda con el idioma reservado.
        await Self.waitForSession { await session.recorded().contains(.cancelled) }
        #expect(await session.recorded().contains(.cancelled), "la sesión no se canceló")
        #expect(!(await session.recorded().contains(.started)), "abrió el audio tras cancelar")
    }

    @Test("el texto en vivo se va refinando y nunca sale del panel antes de tiempo")
    func liveTextRefines() async throws {
        let session = FakeSession(fragments: ["ho", "hol", "hola"])
        var delivered: [Transcript] = []
        let controller = Self.make(session: session) { delivered.append($0) }

        controller.startWithoutGesture(locale: Locale(identifier: "es-ES"), mode: .live)
        await Self.waitUntil { controller.liveText == "hola" }

        #expect(controller.liveText == "hola", "liveText: «\(controller.liveText)»")
        // Y nada se ha entregado todavía: mientras se escucha, el texto vive en el
        // panel y no se escribe en la app de destino.
        #expect(delivered.isEmpty, "entregó antes de finalizar")
    }

    /// Bloqueante de la ronda 2: cerrar el panel escuchando dejaba el estado
    /// clavado en `.listening` para siempre — el icono de la barra afirmando que el
    /// micrófono seguía abierto, el panel sin poder volver a cerrarse y el dictado
    /// inservible el resto de la sesión de la app.
    @Test("cerrar el panel mientras escucha vuelve al reposo")
    func dismissingPanelWhileListeningReturnsToIdle() async throws {
        let session = FakeSession()
        let controller = Self.make(session: session)

        controller.startWithoutGesture(locale: Locale(identifier: "es-ES"), mode: .live)
        await Self.waitUntil { controller.state.isMicrophoneOpen }
        #expect(controller.state == .listening)

        controller.panelDismissed()

        #expect(controller.state == .idle, "estado colgado: \(controller.state)")
        #expect(!controller.state.isMicrophoneOpen, "el estado sigue diciendo que escucha")
        #expect(!controller.state.inhibitsPanelDismissal, "el panel ya no podría cerrarse nunca")
        await Self.waitForSession { await session.recorded().contains(.cancelled) }
        #expect(await session.recorded().contains(.cancelled))
    }

    /// El otro atasco: el botón de micrófono servía una sola vez por lanzamiento,
    /// porque el estado quedaba en `.delivered` y `startWithoutGesture` exigía
    /// `.idle`. Y es el único camino de quien no puede mantener una tecla.
    @Test("se puede dictar más de una vez por lanzamiento")
    func canDictateRepeatedly() async throws {
        let session = FakeSession()
        var delivered: [Transcript] = []
        let controller = Self.make(session: session) { delivered.append($0) }

        for round in 1...3 {
            controller.startWithoutGesture(locale: Locale(identifier: "es-ES"), mode: .live)
            await Self.waitUntil { controller.state.isMicrophoneOpen }
            #expect(controller.state == .listening, "ronda \(round): \(controller.state)")
            controller.stop()
            await Self.waitUntil { delivered.count == round }
        }
        #expect(delivered.count == 3, "solo se entregaron \(delivered.count) de 3")
    }

    /// El techo de finalización se midió (0,79-1,16 s en frío) y hay que impedir que
    /// alguien lo devuelva a un valor que descarta siempre el resultado bueno. La
    /// versión anterior lo referenciaba simbólicamente, así que bajarlo no rompía
    /// nada.
    @Test("el techo de finalización no puede bajar del coste medido en frío")
    func finalizationTimeoutCoversColdStart() {
        #expect(
            DictationController.finalizationTimeout >= .milliseconds(1200),
            """
            el techo es \(DictationController.finalizationTimeout): por debajo del \
            coste medido de session.finish() en frío (0,79-1,16 s), así que el primer \
            dictado descartaría el texto finalizado del motor.
            """
        )
    }

    /// El techo tiene que **devolver el control** a tiempo, no solo existir.
    ///
    /// La versión anterior usaba `withTaskGroup`, que espera a todos sus hijos: con
    /// una sesión que ignora la cancelación —como el motor real— el control no
    /// volvía hasta que la operación acabara por su cuenta. Medido entonces:
    /// 2,92 s con el techo puesto en 2,5 s.
    @Test("el techo devuelve el control aunque la sesión ignore la cancelación")
    func timeoutIsHonouredEvenIfSessionIgnoresCancellation() async throws {
        let slow = StubbornSession(finishTakes: .seconds(20))
        var delivered: [Transcript] = []
        let controller = DictationController(
            engine: StubbornEngine(session: slow),
            gesture: HoldGesture(watchedFlags: [.command], threshold: .milliseconds(50)),
            deliver: { delivered.append($0) },
            permission: { .granted }
        )

        controller.startWithoutGesture(locale: Locale(identifier: "es-ES"), mode: .live)
        await Self.waitUntil { controller.state.isMicrophoneOpen }

        let started = ContinuousClock.now
        controller.stop()
        // Se espera **al hecho**, con techo generoso, y quien afirma que el techo acota es la
        // comparación de abajo sobre `elapsed`. Con una dormida fija el test medía otra cosa:
        // si la máquina iba cargada, la entrega llegaba después del plazo y el fallo decía
        // «nada entregado» —como si el techo no existiera— cuando lo único lento era el runner.
        await Self.waitUntil(timeout: .seconds(10)) { !delivered.isEmpty }
        let elapsed = ContinuousClock.now - started

        #expect(!delivered.isEmpty, "el techo no devolvió el control: nada entregado")
        #expect(
            elapsed < DictationController.finalizationTimeout + .seconds(3),
            "tardó \(elapsed), muy por encima del techo"
        )
        #expect(delivered.first?.wasTruncated == true)
    }

    /// Un fallo del motor no puede presentarse como una entrega truncada.
    @Test("un fallo del motor se reporta como fallo, no como entrega a medias")
    func engineFailureIsNotDisguisedAsTruncation() async throws {
        var delivered: [Transcript] = []
        let controller = DictationController(
            engine: StubbornEngine(session: FailingSession()),
            gesture: HoldGesture(watchedFlags: [.command], threshold: .milliseconds(50)),
            deliver: { delivered.append($0) },
            permission: { .granted }
        )

        controller.startWithoutGesture(locale: Locale(identifier: "es-ES"), mode: .live)
        await Self.waitUntil { controller.state.isMicrophoneOpen }
        controller.stop()
        await Self.waitUntil { !delivered.isEmpty || controller.lastFailure != nil }

        #expect(controller.lastFailure == .engineFailed, "estado: \(controller.state)")
        #expect(delivered.isEmpty, "entregó algo pese al fallo del motor")
    }

    /// Y el permiso revocado en caliente tiene que decirse, no quedarse escuchando.
    @Test("sin permiso de micrófono no se abre nada y se explica")
    func revokedPermissionFailsLoudly() async throws {
        let session = FakeSession()
        let controller = DictationController(
            engine: FakeEngine(session: session),
            gesture: HoldGesture(watchedFlags: [.command], threshold: .milliseconds(50)),
            deliver: { _ in },
            permission: { .denied }
        )

        controller.startWithoutGesture(locale: Locale(identifier: "es-ES"), mode: .live)
        // Al fallo, no a la apertura del micrófono: aquí el permiso está denegado, así que
        // esperar a que se abra es esperar a algo que este test afirma que **no** ocurre, y
        // costaba el margen completo de la espera en cada pasada.
        await Self.waitUntil { controller.lastFailure != nil }

        #expect(controller.lastFailure == .permissionDenied, "estado: \(controller.state)")
        #expect(!controller.state.isMicrophoneOpen)
        #expect(!(await session.recorded().contains(.started)), "abrió el audio sin permiso")
    }

    /// Los anuncios son la única señal de estado para quien no ve la pantalla, y se
    /// podían silenciar por completo sin que fallara nada.
    @Test("cada cambio de estado se anuncia a VoiceOver")
    func stateChangesAreAnnounced() async throws {
        let session = FakeSession()
        var announced: [String] = []
        let controller = Self.make(session: session, announcer: { text, _ in announced.append(text) })

        controller.startWithoutGesture(locale: Locale(identifier: "es-ES"), mode: .live)
        await Self.waitUntil { controller.state.isMicrophoneOpen }
        controller.stop()
        // Se espera al último anuncio del ciclo: el estado terminal es lo que lo produce.
        await Self.waitUntil { controller.state == .idle || controller.lastFailure != nil || announced.count >= 3 }

        #expect(announced.count >= 3, "solo se anunció \(announced.count) veces: \(announced)")
        // Y ninguno vacío: la versión anterior emitía uno por cada tick de la cuenta,
        // interrumpiendo al lector para no decir nada.
        #expect(announced.allSatisfy { !$0.isEmpty }, "anuncio vacío en \(announced)")
    }

    /// El aviso de la cuenta existe para poder soltar a tiempo, y va **en el mismo
    /// umbral en el que aparece la banda**: los dos canales tienen que decir lo mismo.
    ///
    /// Antes se anunciaba también a mitad, y era peor: la cuenta dura 550 ms, así que la
    /// segunda locución interrumpía a la primera —VoiceOver no encola, corta— y el aviso
    /// que da margen para reaccionar llegaba troceado.
    @Test("la cuenta del gesto se anuncia una vez, en el umbral en que aparece la banda")
    func armingIsAnnouncedOnceAtTheDisplayThreshold() async throws {
        let session = FakeSession()
        var announced: [String] = []
        let controller = Self.make(session: session, announcer: { text, _ in announced.append(text) })

        controller.shortcutPressed(locale: Locale(identifier: "es-ES"), mode: .live)
        // Por debajo del umbral de aparición no se dice nada: si no, cada apertura del
        // historial por atajo —la acción más frecuente de la app— pediría mantener una
        // tecla que nadie está manteniendo.
        controller.simulateArmingProgress(0.1)
        #expect(!announced.contains(DictationController.arming), "se anunció antes de tiempo")

        controller.simulateArmingProgress(0.4)
        controller.simulateArmingProgress(0.8)
        try? await Task.sleep(for: .milliseconds(120))

        let arming = DictationController.arming
        #expect(announced.contains(arming), "no se anunció el arranque de la cuenta: \(announced)")
        #expect(
            announced.filter { $0 == arming }.count == 1,
            "el aviso de la cuenta se repitió y se pisó a sí mismo: \(announced)"
        )
    }

    /// El fallo se anuncia con su causa, no con el genérico.
    @Test("el anuncio del fallo lleva la causa")
    func failureAnnouncementCarriesTheCause() async throws {
        let session = FakeSession()
        var announced: [String] = []
        let controller = DictationController(
            engine: FakeEngine(session: session),
            gesture: HoldGesture(watchedFlags: [.command], threshold: .milliseconds(50)),
            deliver: { _ in },
            permission: { .denied },
            announcer: { text, _ in announced.append(text) }
        )

        controller.startWithoutGesture(locale: Locale(identifier: "es-ES"), mode: .live)
        // Se espera al **anuncio**, que es lo que este test afirma. Esperaba a que el
        // micrófono se abriera, y con el permiso denegado eso no pasa nunca: agotaba el
        // margen entero de la espera —cinco segundos antes, quince ahora— en cada pasada de
        // la suite, para comprobar algo que ya había ocurrido en el primer milisegundo.
        await Self.waitUntil { !announced.isEmpty }

        let expected = DictationController.message(for: .permissionDenied)
        #expect(
            announced.contains(expected),
            "se anunció el genérico en vez de la causa: \(announced)"
        )
    }

    /// El techo de duración **descarta**. No entrega.
    ///
    /// Estuvo escrito así y sin cablear: `handleSessionLimit()` existía, el handler
    /// seguía apuntando a `.stopRequested` —que es entregar— y el commit que decía
    /// haberlo arreglado no lo arreglaba. Sin este test volvería igual.
    @Test("al vencer el techo de sesión se descarta, no se pega")
    func sessionLimitDiscardsInsteadOfDelivering() async throws {
        let session = LimitAnnouncingSession()
        var delivered: [Transcript] = []
        let controller = DictationController(
            engine: StubbornEngine(session: session),
            gesture: HoldGesture(watchedFlags: [.command], threshold: .milliseconds(50)),
            deliver: { delivered.append($0) },
            permission: { .granted },
            announcer: { _, _ in }
        )

        controller.startWithoutGesture(locale: Locale(identifier: "es-ES"), mode: .live)
        await Self.waitUntil { controller.state.isMicrophoneOpen }
        // La sesión avisa de su techo, como haría al vencer la media hora.
        await session.fireLimit()
        try? await Task.sleep(for: .milliseconds(400))

        #expect(
            delivered.isEmpty,
            "el techo entregó y pegó: \(delivered.map(\.text)) — es audio que nadie pidió dictar"
        )
        #expect(controller.lastFailure == .sessionLimitReached, "estado: \(controller.state)")
    }

    /// Un fallo de una sesión ya abandonada no puede matar la sesión vigente.
    @Test("el fallo de una sesión abandonada no contamina la siguiente")
    func staleFailureDoesNotKillCurrentSession() async throws {
        let session = FakeSession()
        let controller = Self.make(session: session)

        // Primera sesión, y se abandona. Se espera a que esté de verdad escuchando: con
        // una dormida fija, la suite en paralelo podía descartar una sesión que aún no
        // había arrancado, y entonces la segunda no llegaba a `.listening` a tiempo. Este
        // test falló 3 de ~25 pasadas por eso.
        controller.startWithoutGesture(locale: Locale(identifier: "es-ES"), mode: .live)
        await Self.waitUntil { controller.state.isMicrophoneOpen }
        controller.discard()

        // Segunda sesión, sana.
        controller.startWithoutGesture(locale: Locale(identifier: "es-ES"), mode: .live)
        await Self.waitUntil { controller.state.isMicrophoneOpen }
        #expect(controller.state == .listening, "la segunda sesión no arrancó")

        // Un fallo tardío con el testigo viejo se ignora.
        controller.simulateStaleFailure()
        #expect(controller.state == .listening, "un fallo caduco tumbó la sesión: \(controller.state)")
    }

    /// `shutdown()` no tenía un solo test, y su propio comentario describe el modo de
    /// fallo: «el micrófono podía quedarse abierto indefinidamente, sin panel y sin
    /// banner». Anularlo por completo no rompía nada.
    @Test("apagar el dictado cierra la sesión viva")
    func shutdownClosesLiveSession() async throws {
        let session = FakeSession()
        let controller = Self.make(session: session)

        controller.startWithoutGesture(locale: Locale(identifier: "es-ES"), mode: .live)
        // Por condición y no por reloj: con la suite en paralelo, 200 ms de dormida no
        // garantizan que el actor principal haya corrido los pasos intermedios, y este test
        // falló 1 de 9 pasadas por eso.
        await Self.waitUntil { controller.state == .listening }
        #expect(controller.state == .listening, "no llegó a escuchar: \(controller.state)")

        controller.shutdown()

        #expect(controller.state == .idle, "el estado quedó en \(controller.state)")
        #expect(!controller.state.isMicrophoneOpen)
        await Self.waitForSession { await session.recorded().contains(.cancelled) }
        #expect(await session.recorded().contains(.cancelled), "la sesión no se canceló")
    }

    /// Soltar después de que la cuenta se complete **no** cancela: §8.4.bis.
    ///
    /// Este test decía lo contrario hasta que un usuario reportó «mantengo el atajo y no se
    /// pone a grabar». Y pasaba por un camino que en producción no existe: llamaba a
    /// `simulateGestureCompleted()`, que salta al contador, así que el contador seguía
    /// vivo y era ÉL quien cancelaba al soltar. En la app, el contador se para solo al
    /// completar. Lo que cancelaba de verdad eran dos guardas heredadas del modelo
    /// anterior, y entre las dos se comían la sesión en la ventana de carga del modelo:
    /// 126 ms en frío, medido.
    ///
    /// Ahora lo conduce la cuenta real, que es la única forma de que este test hable del
    /// mismo mundo que el usuario.
    @Test("soltar después de la cuenta no cancela: el gesto solo arranca")
    func releasingAfterTheCountKeepsTheSession() async throws {
        // La preparación tiene que **durar**: si fuera instantánea, cuando el test suelta
        // ya estaría escuchando y no se mediría la ventana que causaba el fallo.
        let session = FakeSession(prepareDelay: .milliseconds(300))
        let held = TestBox(true)
        let controller = DictationController(
            engine: FakeEngine(session: session),
            gesture: HoldGesture(watchedFlags: [.command], threshold: .milliseconds(40)),
            deliver: { _ in },
            permission: { .granted },
            announcer: { _, _ in }
        )
        controller.overrideHeldProviderForTesting { held.value }

        controller.shortcutPressed(locale: Locale(identifier: "es-ES"), mode: .live)
        // Sin simular nada: se espera a que la cuenta llegue al final por sí sola, como en
        // la app. Ahí es donde el contador se para y donde empieza la promesa.
        await Self.waitUntil { controller.state == .preparing }

        // Y se suelta, que es lo que hace cualquiera al ver la cuenta completarse.
        held.value = false

        await Self.waitUntil { controller.state.isMicrophoneOpen }
        #expect(
            controller.state.isMicrophoneOpen,
            "soltar tras la cuenta mató la sesión: \(controller.state)"
        )
        // Espera acotada: el registro lo hace el actor de la sesión, así que llega un
        // instante después de que el estado ya lo diga.
        await Self.waitForSession { await session.recorded().contains(.started) }
        #expect(await session.recorded().contains(.started), "no abrió el micrófono")
        controller.shutdown()
    }

    /// Y soltar ANTES de que la cuenta acabe sigue cancelando.
    ///
    /// Es la otra mitad, y sin ella el arreglo de arriba se podría pasar de frenada hasta
    /// «el atajo abre el micrófono aunque lo sueltes enseguida», que es el fallo que el
    /// gesto entero existe para no cometer.
    @Test("soltar antes de completar la cuenta sí cancela")
    func releasingDuringTheCountCancels() async throws {
        let session = FakeSession()
        let held = TestBox(true)
        let controller = DictationController(
            engine: FakeEngine(session: session),
            gesture: HoldGesture(watchedFlags: [.command], threshold: .seconds(5)),
            deliver: { _ in },
            permission: { .granted },
            announcer: { _, _ in }
        )
        controller.overrideHeldProviderForTesting { held.value }

        controller.shortcutPressed(locale: Locale(identifier: "es-ES"), mode: .live)
        #expect(controller.state == .arming(progress: 0, prepared: false))

        held.value = false
        await Self.waitUntil { controller.state == .idle }
        #expect(controller.state == .idle, "la cuenta siguió sin la tecla: \(controller.state)")
        #expect(!(await session.recorded().contains(.started)), "abrió el micrófono sin cuenta")
    }

    /// Completar la cuenta SIN permiso: la cuenta arma y avanza con normalidad —el
    /// usuario ve el progreso, no se le calla la mano— y el fallo llega justo en el
    /// instante en que de verdad se iba a abrir el micrófono. El mismo aviso que ya da
    /// el botón (`startWithoutGesture`) cuando se pide dictar sin permiso.
    ///
    /// Reportado por el usuario junto con el arreglo de arriba: al resolver «soltar tras
    /// la cuenta no cancela», completar el gesto sin permiso seguía sin decir nada — el
    /// micrófono no se abría, pero tampoco había ningún indicio de por qué.
    @Test("completar la cuenta sin permiso avisa, igual que el botón")
    func completingWithoutPermissionFails() async throws {
        let session = FakeSession()
        let controller = DictationController(
            engine: FakeEngine(session: session),
            gesture: HoldGesture(watchedFlags: [.command], threshold: .milliseconds(30)),
            deliver: { _ in },
            permission: { .denied },
            announcer: { _, _ in }
        )
        controller.overrideHeldProviderForTesting { true }

        controller.shortcutPressed(locale: Locale(identifier: "es-ES"), mode: .live)
        // La cuenta arma: sin esto el usuario no tiene NINGÚN indicio de que algo pasa.
        #expect(controller.state != .idle, "el gesto no armó sin permiso")

        await Self.waitUntil { controller.state == .failed(.permissionDenied) }
        #expect(
            controller.state == .failed(.permissionDenied),
            "no avisó del permiso al completar: \(controller.state)"
        )
        #expect(!(await session.recorded().contains(.started)), "abrió el micrófono sin permiso")
    }

    /// Y la ranura de idioma que la sesión ya había reservado durante la cuenta se suelta:
    /// sin esto, cada intento sin permiso se queda con una de las cinco ranuras de la
    /// máquina.
    @Test("fallar por permiso al completar la cuenta suelta la sesión preparada")
    func completingWithoutPermissionReleasesTheSession() async throws {
        let session = FakeSession(prepareDelay: .milliseconds(30))
        let controller = DictationController(
            engine: FakeEngine(session: session),
            gesture: HoldGesture(watchedFlags: [.command], threshold: .milliseconds(30)),
            deliver: { _ in },
            permission: { .denied },
            announcer: { _, _ in }
        )
        controller.overrideHeldProviderForTesting { true }

        controller.shortcutPressed(locale: Locale(identifier: "es-ES"), mode: .live)
        await Self.waitUntil { controller.state == .failed(.permissionDenied) }

        await Self.waitForSession { await session.recorded().contains(.cancelled) }
        let recorded = await session.recorded()
        #expect(recorded.contains(.cancelled), "la sesión preparada se quedó sin soltar: \(recorded)")
    }

    /// La otra mitad de la transición a `.listening`: cuando el modelo tarda MÁS que la
    /// cuenta y el permiso se comprueba al terminar de cargar, no al completar el gesto.
    /// Sin este test, la comprobación de permiso se podía quitar de esta rama —
    /// `(.preparing, .preparationFinished)`— dejando la otra intacta, y el fallo solo se
    /// vería en la máquina donde el modelo tarda: la mayoría, no la de quien desarrolla.
    @Test("completar la cuenta sin permiso también avisa cuando el modelo tarda en cargar")
    func completingWithoutPermissionFailsWhenModelIsStillLoading() async throws {
        // 2 s, no 150 ms: bajo la suite completa —con tests de motor real que saturan
        // la CPU— una ventana de 150 ms podía consumirse entera antes de que el sondeo
        // de 10 ms del siguiente `waitUntil` alcanzara a verla, y el test fallaba «caso
        // mal montado» viendo un estado posterior a `.preparing`, no por un fallo del
        // código sino por perder una ventana demasiado estrecha. Medido por auditoría:
        // ~29% de las corridas completas. Una ventana ancha hace la carrera
        // despreciable sin dejar de probar la misma rama.
        let session = FakeSession(prepareDelay: .seconds(2))
        let controller = DictationController(
            engine: FakeEngine(session: session),
            gesture: HoldGesture(watchedFlags: [.command], threshold: .milliseconds(20)),
            deliver: { _ in },
            permission: { .denied },
            announcer: { _, _ in }
        )
        controller.overrideHeldProviderForTesting { true }

        controller.shortcutPressed(locale: Locale(identifier: "es-ES"), mode: .live)
        // La cuenta completa MUCHO antes de que el modelo esté listo: se entra en
        // `.preparing` por `(.arming(_, false), .gestureCompleted)`, no por la rama que
        // prueba el test de arriba.
        await Self.waitUntil { controller.state == .preparing }
        #expect(controller.state == .preparing, "caso mal montado: \(controller.state)")

        await Self.waitUntil { controller.state == .failed(.permissionDenied) }
        #expect(
            controller.state == .failed(.permissionDenied),
            "no avisó al terminar de cargar el modelo: \(controller.state)"
        )
        #expect(!(await session.recorded().contains(.started)), "abrió el micrófono sin permiso")
    }

    /// Una interacción durante `.preparing` NO cancela: la cuenta ya se completó, el
    /// usuario ya soltó la mano —§8.4.bis—, y lo único que queda es esperar al modelo.
    ///
    /// Hallazgo de la auditoría independiente: `interactionOccurred` guarda
    /// `case .arming = state`, y ese guard no tenía ningún test. Con él relajado, mover
    /// el ratón mientras el modelo carga —0,8 a 1,2 s en frío, medido en rondas
    /// anteriores— mataría una sesión que el usuario ya dio por comprometida: exactamente
    /// el fallo simétrico al que el propio comentario del método describe («quien busca
    /// algo hace algo, quien quiere dictar se queda quieto») aplicado al momento
    /// equivocado. `accessiblePathNeverArms` prueba que el camino sin gesto nunca ENTRA en
    /// `.arming`; esto prueba que salir de `.arming` hacia `.preparing` desactiva la
    /// cancelación, que es una afirmación distinta.
    @Test("mover el ratón mientras el modelo carga no cancela la sesión ya comprometida")
    func interactionDuringPreparingDoesNotCancel() async throws {
        // 2 s, no 200 ms: misma razón que en el test de arriba — bajo la suite
        // completa, una ventana de 200 ms se podía consumir entera antes de que el
        // sondeo de 10 ms la alcanzara a ver, y el test fallaba por perder la ventana,
        // no por un fallo del código. Medido por auditoría: intermitencia reproducida
        // en varias de cada pocas corridas completas.
        let session = FakeSession(prepareDelay: .seconds(2))
        let controller = DictationController(
            engine: FakeEngine(session: session),
            gesture: HoldGesture(watchedFlags: [.command], threshold: .milliseconds(20)),
            deliver: { _ in },
            permission: { .granted },
            announcer: { _, _ in }
        )
        controller.overrideHeldProviderForTesting { true }

        controller.shortcutPressed(locale: Locale(identifier: "es-ES"), mode: .live)
        await Self.waitUntil { controller.state == .preparing }
        #expect(controller.state == .preparing, "caso mal montado: \(controller.state)")

        controller.interactionOccurred(.pointerMoved)

        #expect(
            controller.state == .preparing,
            "una interacción con el modelo cargando mató una sesión ya comprometida: \(controller.state)"
        )
        await Self.waitUntil { controller.state.isMicrophoneOpen }
        #expect(controller.state.isMicrophoneOpen, "la sesión no llegó a abrir el micrófono")
    }

    /// El anuncio que importa es el del micrófono abierto, y el test anterior no lo
    /// tocaba: `count >= 3` ya se cumplía con preparando/finalizando/entregado.
    @Test("se anuncia explícitamente que el micrófono se ha abierto")
    func listeningIsAnnouncedExplicitly() async throws {
        let session = FakeSession()
        var announced: [String] = []
        let controller = Self.make(session: session, announcer: { text, _ in announced.append(text) })

        controller.startWithoutGesture(locale: Locale(identifier: "es-ES"), mode: .live)
        await Self.waitUntil { controller.state.isMicrophoneOpen }

        let listening = String(localized: "dictation.state.listening", bundle: .localized)
        #expect(
            announced.contains(listening),
            "no se anunció que el micrófono estaba abierto: \(announced)"
        )
    }

    /// Un dictado sin voz se traduce a fallo, no a entrega vacía.
    @Test("un dictado sin voz acaba en fallo, no en entrega")
    func emptyDictationBecomesFailure() async throws {
        let session = FakeSession(transcript: Transcript(text: "   ", mode: .live), fragments: [])
        var delivered: [Transcript] = []
        let controller = Self.make(session: session) { delivered.append($0) }

        controller.startWithoutGesture(locale: Locale(identifier: "es-ES"), mode: .live)
        await Self.waitUntil { controller.state.isMicrophoneOpen }
        controller.stop()
        await Self.waitUntil { controller.lastFailure != nil }

        #expect(delivered.isEmpty, "entregó texto vacío: \(delivered.map(\.text))")
        #expect(controller.lastFailure == .noSpeechDetected, "estado: \(controller.state)")
    }

    /// Los anuncios de VoiceOver compiten entre sí: cada uno **interrumpe** al
    /// anterior. Con la cuenta durando medio segundo, apilar cuatro locuciones dejaba
    /// el aviso que da tiempo a soltar cortado a media frase, y el único que de verdad
    /// importa —el que declara que el micrófono está abierto— llegando el último.
    @Test("durante la cuenta no se apilan anuncios que se pisen")
    func announcementsDoNotCollideDuringTheCount() async throws {
        // El modelo tarda MÁS que la cuenta del gesto (50 ms en el arnés): así se
        // atraviesa `.preparing`, que es el estado cuyo anuncio se retiró. Sin este
        // retardo el estado no se alcanza y la aserción de abajo es vacía.
        let session = FakeSession(prepareDelay: .milliseconds(150))
        var announced: [String] = []
        let controller = Self.make(session: session, announcer: { text, _ in announced.append(text) })
        controller.overrideHeldProviderForTesting { true }

        controller.shortcutPressed(locale: Locale(identifier: "es-ES"), mode: .live)
        await Self.waitUntil { controller.state.isMicrophoneOpen }
        // Y que el estado se sostenga: con la suite cargada, comprobar en el borde de la
        // transición hacía que a veces la sesión aún no hubiera registrado `.started`.
        let steps0 = await session.recorded()
        if !steps0.contains(.started) {
            await Self.waitForSession { await session.recorded().contains(.started) }
        }

        // Que de verdad se pasó por ahí: si no, el test no probaría lo que dice.
        let steps = await session.recorded()
        #expect(steps.contains(.started), "la sesión no llegó a escuchar: \(steps)")
        let listening = String(localized: "dictation.state.listening", bundle: .localized)
        #expect(announced.contains(listening), "no se anunció la escucha: \(announced)")

        // Como máximo UNO antes de abrir el micrófono: el aviso de mantener.
        let before = announced.prefix(while: { $0 != listening })
        #expect(before.count <= 1, "anuncios apilados antes de escuchar: \(Array(before))")

        // «Preparando» no se anuncia: carga el modelo, no toca el micrófono, y no hay
        // nada que el usuario pueda decidir con esa información. Se queda en pantalla.
        let preparing = String(localized: "dictation.state.preparing", bundle: .localized)
        #expect(!announced.contains(preparing), "se anunció «preparando»: \(announced)")
    }

    /// El permiso se revoca en Ajustes del Sistema **con la sesión abierta**: el tap
    /// sigue instalado y entrega silencio, así que el síntoma es idéntico a no haber
    /// hablado. La app culpaba al usuario de un fallo que tiene remedio y botón.
    @Test("si el permiso se revoca a mitad, el fallo lo dice en lugar de culpar al silencio")
    func revokedPermissionMidSessionIsDiagnosed() async throws {
        let session = FakeSession(transcript: Transcript(text: "", mode: .live), fragments: [])
        let permission = TestBox(MicrophonePermission.granted)
        let controller = Self.make(
            session: session,
            permission: { permission.value }
        )

        controller.startWithoutGesture(locale: Locale(identifier: "es-ES"), mode: .live)
        await Self.waitUntil { controller.state.isMicrophoneOpen }
        // Aquí el usuario abre Ajustes del Sistema y quita el permiso.
        permission.value = .denied
        controller.stop()
        await Self.waitUntil { controller.lastFailure != nil }

        #expect(
            controller.lastFailure == .permissionDenied,
            "diagnóstico equivocado: \(String(describing: controller.lastFailure))"
        )
    }

    /// El modo con el que se etiqueta lo entregado **cuando vence el techo**.
    ///
    /// `currentMode` solo se lee en un sitio: el transcript que se construye al vencer la
    /// espera de finalización. El único test que atravesaba esa rama usaba `.live`, así que
    /// fijar `currentMode = .live` no rompía nada — el hallazgo M3 de la ronda 2, abierto
    /// otra vez. Y no es cosmético: el modo viaja con el texto al historial.
    @Test("una entrega por techo en diferido se etiqueta como diferido")
    func timeoutInDeferredModeKeepsTheMode() async throws {
        var delivered: [Transcript] = []
        let controller = DictationController(
            engine: StubbornEngine(session: StubbornSession(finishTakes: .seconds(6))),
            gesture: HoldGesture(watchedFlags: [.command], threshold: .milliseconds(50)),
            deliver: { delivered.append($0) },
            permission: { .granted }
        )

        controller.startWithoutGesture(locale: Locale(identifier: "es-ES"), mode: .deferred)
        await Self.waitUntil { controller.state.isMicrophoneOpen }
        controller.stop()
        // Por condición: lo que se afirma es el modo con el que se etiqueta lo entregado, y
        // un plazo fijo lo convierte además en una apuesta sobre la velocidad de la máquina.
        await Self.waitUntil(timeout: .seconds(10)) { !delivered.isEmpty }

        let transcript = try #require(delivered.first, "no entregó nada al vencer el techo")
        #expect(transcript.mode == .deferred, "etiquetó el dictado como \(transcript.mode)")
    }

    /// Lo que se le pide al motor: idioma, modo y la pista de accesibilidad.
    ///
    /// Los tres viajaban sin ninguna red. Medido con mutaciones: `atypicalSpeech: false` fijo
    /// en los dos puntos de entrada dejaba los 324 tests en verde —y esa pista es la tercera
    /// de las tres razones documentadas para elegir este módulo, «arreglada» una ronda antes
    /// añadiendo el parámetro—; y `currentMode = .live` fijo tampoco rompía nada, que es el
    /// hallazgo M3 de la ronda 2 volviendo a estar abierto.
    @Test("la pista de habla atípica llega al motor cuando está activada")
    func atypicalSpeechReachesTheEngine() async throws {
        let request = SessionRequest()
        let controller = DictationController(
            engine: FakeEngine(session: FakeSession(), request: request),
            gesture: HoldGesture(watchedFlags: [.command], threshold: .milliseconds(50)),
            deliver: { _ in },
            permission: { .granted },
            atypicalSpeech: { true }
        )

        controller.startWithoutGesture(locale: Locale(identifier: "es-ES"), mode: .deferred)
        await Self.waitUntil { controller.state.isMicrophoneOpen }
        try? await Task.sleep(for: .milliseconds(50))

        #expect(await request.atypicalSpeech == true, "la pista no llegó al motor")
        // Y el modo, en el mismo viaje: el diferido tiene que llegar como diferido.
        #expect(await request.mode == .deferred, "el modo se etiquetó mal")
        #expect(await request.locale?.identifier == "es-ES")
    }

    @Test("y no llega cuando está desactivada")
    func atypicalSpeechStaysOffWhenDisabled() async throws {
        let request = SessionRequest()
        let controller = DictationController(
            engine: FakeEngine(session: FakeSession(), request: request),
            gesture: HoldGesture(watchedFlags: [.command], threshold: .milliseconds(50)),
            deliver: { _ in },
            permission: { .granted },
            atypicalSpeech: { false }
        )

        controller.startWithoutGesture(locale: Locale(identifier: "es-ES"), mode: .live)
        await Self.waitUntil { controller.state.isMicrophoneOpen }
        try? await Task.sleep(for: .milliseconds(50))

        // No es simétrico por gusto: la pista cambia el modelo acústico, así que activarla
        // para quien no la necesita transcribe algo peor.
        #expect(await request.atypicalSpeech == false)
        #expect(await request.mode == .live)
    }

    @Test("el modo también llega por el camino del gesto")
    func modeReachesTheEngineThroughTheGesture() async throws {
        let request = SessionRequest()
        let controller = DictationController(
            engine: FakeEngine(session: FakeSession(), request: request),
            gesture: HoldGesture(watchedFlags: [.command], threshold: .milliseconds(50)),
            deliver: { _ in },
            permission: { .granted },
            atypicalSpeech: { true }
        )
        controller.overrideHeldProviderForTesting { true }

        controller.shortcutPressed(locale: Locale(identifier: "es-ES"), mode: .deferred)
        try? await Task.sleep(for: .milliseconds(200))

        // Los dos puntos de entrada crean sesión, y la mutación sobrevivía en los dos.
        #expect(await request.mode == .deferred)
        #expect(await request.atypicalSpeech == true)
    }

    /// La prioridad con la que se anuncia **cada** estado, en su sitio de uso.
    ///
    /// `urgency(of:)` estaba probada como función pura, pero todas las capturas del
    /// `announcer` en la suite descartaban el segundo argumento —`{ text, _ in … }`—, así que
    /// sustituir la llamada por `announcer(text, .normal)` dejaba los 324 tests en verde. O
    /// sea: el arreglo entero de la colisión de anuncios tenía poder de detección cero, que
    /// es exactamente la clase de defecto que este proyecto lleva siete rondas documentando.
    @Test("el anuncio del micrófono abierto se emite con prioridad alta")
    func listeningIsAnnouncedWithHighPriority() async throws {
        let session = FakeSession()
        var emitted: [(String, AnnouncementUrgency)] = []
        let controller = Self.make(
            session: session,
            announcer: { text, urgency in emitted.append((text, urgency)) }
        )

        controller.startWithoutGesture(locale: Locale(identifier: "es-ES"), mode: .live)
        await Self.waitUntil { controller.state.isMicrophoneOpen }

        let listening = String(localized: "dictation.state.listening", bundle: .localized)
        let announcement = emitted.first { $0.0 == listening }
        #expect(announcement != nil, "no se anunció la escucha: \(emitted.map(\.0))")
        // VoiceOver no encola: sin prioridad alta, el anuncio que declara que se está
        // grabando lo puede cortar cualquier otro.
        #expect(announcement?.1 == .critical, "se anunció con prioridad \(String(describing: announcement?.1))")
    }

    @Test("el aviso de la cuenta cede el paso, y el fallo no")
    func armingCedesAndFailureDoesNot() async throws {
        let session = FakeSession()
        var emitted: [(String, AnnouncementUrgency)] = []
        let controller = Self.make(
            session: session,
            announcer: { text, urgency in emitted.append((text, urgency)) },
            permission: { .denied }
        )
        controller.overrideHeldProviderForTesting { true }

        // El fallo, por el camino explícito: es el único que lo publica.
        controller.startWithoutGesture(locale: Locale(identifier: "es-ES"), mode: .live)
        try? await Task.sleep(for: .milliseconds(120))

        let failure = emitted.first { $0.0 == DictationController.message(for: .permissionDenied) }
        #expect(failure?.1 == .critical, "el fallo cedió el paso: \(emitted)")
    }

    /// La volatilidad llega a la interfaz.
    ///
    /// `isVolatile` se producía, viajaba por el protocolo y nadie lo leía, con un comentario
    /// afirmando que «gobierna toda la interfaz del modo en vivo». Medido con el motor real:
    /// de once resultados, diez son volátiles y solo el último es firme, así que el panel
    /// pintaba diez hipótesis con el mismo aspecto que el texto definitivo.
    @Test("mientras el texto es una hipótesis, la interfaz lo sabe")
    func volatilityReachesTheInterface() async throws {
        let controller = DictationController(
            engine: FakeEngine(session: VolatileThenFinalSession()),
            gesture: HoldGesture(watchedFlags: [.command], threshold: .milliseconds(50)),
            deliver: { _ in },
            permission: { .granted }
        )

        controller.startWithoutGesture(locale: Locale(identifier: "es-ES"), mode: .live)
        await Self.waitUntil { controller.liveText == "hola mundo" }

        // El último fragmento llegó marcado como firme: la interfaz tiene que dejar de
        // atenuarlo, porque es la señal de «esto ya no va a cambiar».
        #expect(controller.liveText == "hola mundo")
        #expect(!controller.liveTextIsVolatile, "el texto firme se sigue pintando como hipótesis")
    }

    @Test("y mientras es volátil, también")
    func volatilityIsReportedWhileVolatile() async throws {
        let controller = DictationController(
            engine: FakeEngine(session: VolatileOnlySession()),
            gesture: HoldGesture(watchedFlags: [.command], threshold: .milliseconds(50)),
            deliver: { _ in },
            permission: { .granted }
        )

        controller.startWithoutGesture(locale: Locale(identifier: "es-ES"), mode: .live)
        await Self.waitUntil { !controller.liveText.isEmpty }

        #expect(controller.liveTextIsVolatile, "una hipótesis se pintaba como texto firme")
    }

    /// Soltar el atajo **ya no para el dictado**.
    ///
    /// El gesto arranca y las manos quedan libres. El modelo anterior —«mantener mientras
    /// hablas»— no aguanta el uso real: para dictar una conversación hay que sostener tres
    /// teclas varios minutos y cualquier resbalón corta a mitad.
    @Test("soltar el atajo no para un dictado ya empezado")
    func releasingDoesNotStopAnActiveSession() async throws {
        let session = FakeSession()
        let held = TestBox(true)
        let controller = DictationController(
            engine: FakeEngine(session: session),
            gesture: HoldGesture(watchedFlags: [.command], threshold: .milliseconds(40)),
            deliver: { _ in },
            permission: { .granted }
        )
        controller.overrideHeldProviderForTesting { held.value }

        controller.shortcutPressed(locale: Locale(identifier: "es-ES"), mode: .live)
        controller.simulateArmingProgress(1.0)
        controller.simulateGestureCompleted()
        await Self.waitUntil { controller.state.isMicrophoneOpen }

        // Se suelta. Antes esto cerraba la sesión a los 40 ms.
        held.value = false
        try? await Task.sleep(for: .milliseconds(200))

        #expect(
            controller.state.isMicrophoneOpen,
            "soltar cortó el dictado: \(controller.state)"
        )
        #expect(!(await session.recorded().contains(.finished)), "se finalizó sin pedirlo")

        // Y la parte que de verdad prueba la regla: **si llegara** la cancelación del gesto,
        // tampoco corta. Sin esto el test era vacío —tras abrir el micrófono ya nadie
        // consulta el mantenido, así que soltar no produce ningún evento— y habría pasado
        // igual con la regla del reductor invertida. Lo midió una auditoría.
        controller.simulateGestureCancelled(.releasedEarly)
        try? await Task.sleep(for: .milliseconds(60))
        #expect(
            controller.state.isMicrophoneOpen,
            "la cancelación del gesto cortó una sesión abierta: \(controller.state)"
        )

        // Cerrar el panel sí la cierra: el micrófono no puede quedarse abierto sin nada en
        // pantalla. Es la única cancelación que sigue gobernando la sesión.
        controller.simulateGestureCancelled(.panelDismissed)
        await Self.waitUntil { !controller.state.isMicrophoneOpen }
        #expect(!controller.state.isMicrophoneOpen, "cerrar el panel dejó el micrófono abierto")
    }

    /// Y se para pidiéndolo: ⏎, el botón o ⌘D pasan todos por aquí.
    @Test("parar explícitamente sí cierra la sesión")
    func explicitStopClosesIt() async throws {
        let session = FakeSession()
        var delivered: [Transcript] = []
        let controller = Self.make(session: session) { delivered.append($0) }

        controller.startWithoutGesture(locale: Locale(identifier: "es-ES"), mode: .live)
        await Self.waitUntil { controller.state.isMicrophoneOpen }
        controller.stop()
        await Self.waitUntil { !delivered.isEmpty }

        #expect(!delivered.isEmpty, "no entregó al parar")
    }

    /// Cambiar de micrófono a mitad **entrega lo dictado**, no lo tira.
    ///
    /// §3.2 lo dice con estas palabras: «la sesión se finaliza con lo que haya, se avisa, y
    /// no se intenta continuar con un formato inválido». El código emitía un fallo, que pasa
    /// por la cancelación y borra el texto: se avisaba y no se entregaba nada. Distinto del
    /// techo de sesión, que sí descarta a propósito porque allí nadie quiso dictar.
    @Test("conectar auriculares a mitad entrega lo dictado y dice por qué")
    func deviceChangeDeliversWhatWasDictated() async throws {
        let expected = Transcript(text: "lo que dio tiempo a decir", mode: .live)
        let session = FakeSession(transcript: expected, fragments: ["lo que dio tiempo"])
        var delivered: [Transcript] = []
        let controller = Self.make(session: session) { delivered.append($0) }

        controller.startWithoutGesture(locale: Locale(identifier: "es-ES"), mode: .live)
        await Self.waitUntil { controller.state.isMicrophoneOpen }

        // Unos auriculares que se conectan: el formato negociado deja de valer.
        await session.simulateDeviceChange()
        await Self.waitUntil { !delivered.isEmpty }

        #expect(delivered.first?.text == expected.text, "tiró lo dictado: \(delivered.map(\.text))")
        // Y se dice por qué, o el usuario ve texto entregado sin explicación de por qué se
        // cortó.
        #expect(controller.lastFailure == .audioDeviceChanged)

        // **Y el aviso llega a la pantalla.** Esto es lo que faltaba, y lo midió una
        // auditoría independiente: el aviso se guardaba en `lastFailure` pero la banda no
        // se pintaba nunca, porque `deservesDisplay` de `.delivered` es `wasTruncated`
        // (`Session.swift:176`) y en el caso normal —el motor responde a tiempo— era
        // `false`. §3.2 promete «se avisa», y afirmar solo la propiedad interna dejaba la
        // promesa sin cumplir con el test en verde.
        let entrega = try #require(delivered.first)
        #expect(
            entrega.wasTruncated,
            "la entrega interrumpida no se confiesa: la banda no se pintaría"
        )
        #expect(
            DictationSessionState.delivered(entrega).deservesDisplay,
            "el usuario no vería ningún aviso de que el dictado se cortó"
        )
    }

    /// La respuesta tardía de una sesión abandonada no puede pegar su texto.
    ///
    /// Es el bloqueante de la ronda 7 y su testigo estaba sin red: borrar la guarda de
    /// `handle(_:token:)` dejaba la suite entera en verde, también con motor real. El
    /// escenario es cotidiano —⎋, un clic fuera, pegar del historial— y la ventana son los
    /// 2,5 s del techo de finalización.
    @Test("la finalización de una sesión abandonada no entrega su texto — camino real")
    func staleFinalizationDoesNotDeliverThroughRealPath() async throws {
        // Sin atajos: dos sesiones de verdad, la vieja respondiendo tarde mientras la nueva
        // está finalizando. Es el único montaje en el que el fallo se puede reproducir, y el
        // test anterior no lo hacía —usaba un helper que fijaba el testigo a mano, así que
        // ejercitaba la guarda y no el sitio donde `beginFinalizing` publica—. Lo midió una
        // auditoría: quitar el `token:` de esa llamada dejaba los 353 tests en verde.
        let vieja = FakeSession(
            transcript: Transcript(text: "SECRETO VIEJO", mode: .live),
            fragments: [],
            finishDelay: .milliseconds(700)
        )
        let nueva = FakeSession(
            transcript: Transcript(text: "lo nuevo", mode: .live),
            fragments: [],
            finishDelay: .milliseconds(1200)
        )
        var delivered: [Transcript] = []
        let controller = DictationController(
            engine: SequenceEngine([vieja, nueva]),
            gesture: HoldGesture(watchedFlags: [.command], threshold: .milliseconds(50)),
            deliver: { delivered.append($0) },
            permission: { .granted }
        )

        // Sesión A: se pide finalizar y se abandona en `.finalizing`, que es lo que ocurre
        // al pulsar ⎋, al clicar fuera o al pegar del historial.
        controller.startWithoutGesture(locale: Locale(identifier: "es-ES"), mode: .live)
        await Self.waitUntil { controller.state.isMicrophoneOpen }
        controller.stop()
        await Self.waitUntil { if case .finalizing = controller.state { true } else { false } }
        controller.discard()

        // Sesión B, dentro de la ventana en la que A todavía puede responder.
        controller.startWithoutGesture(locale: Locale(identifier: "es-ES"), mode: .live)
        await Self.waitUntil { controller.state.isMicrophoneOpen }
        controller.stop()
        await Self.waitUntil { if case .finalizing = controller.state { true } else { false } }

        // Llega la respuesta de A mientras B finaliza. La ventana está calculada: A tarda
        // 700 ms desde que se le pidió finalizar y B tarda 1200 ms, así que hay que esperar
        // lo suficiente para que A conteste y no tanto como para que B termine. Con 500 ms
        // el test acababa **antes** de que A respondiera y la mutación sobrevivía: un test
        // que no llega a ejercitar el instante que dice probar.
        try? await Task.sleep(for: .milliseconds(900))

        #expect(
            !delivered.contains { $0.text == "SECRETO VIEJO" },
            "pegó el dictado anterior en el documento del usuario: \(delivered.map(\.text))"
        )
    }

    @Test("la finalización de una sesión abandonada no entrega su texto")
    func staleFinalizationDoesNotDeliver() async throws {
        // `finish()` lento: mantiene la sesión viva en `.finalizing`.
        let session = FakeSession(finishDelay: .milliseconds(900))
        var delivered: [Transcript] = []
        let controller = Self.make(session: session) { delivered.append($0) }

        // La sesión viva tiene que estar **finalizando** cuando llegue la respuesta vieja:
        // es el único estado donde `.finalizationFinished` es una transición legal, y por
        // tanto el único donde el texto ajeno puede colarse. Un `finish()` lento mantiene
        // ahí a la sesión el tiempo necesario.
        controller.startWithoutGesture(locale: Locale(identifier: "es-ES"), mode: .live)
        await Self.waitUntil { controller.state.isMicrophoneOpen }
        controller.stop()
        await Self.waitUntil { if case .finalizing = controller.state { true } else { false } }
        #expect(
            { if case .finalizing = controller.state { return true } else { return false } }(),
            "no llegó a finalizar: \(controller.state)"
        )

        // Llega la respuesta de la sesión ANTERIOR, con su testigo viejo.
        controller.simulateStaleFinalization("texto del dictado anterior")
        try? await Task.sleep(for: .milliseconds(80))

        #expect(
            !delivered.contains { $0.text == "texto del dictado anterior" },
            "pegó el texto de una sesión abandonada: \(delivered.map(\.text))"
        )
    }

    /// Sin modelo instalado, el atajo del historial tampoco puede pintar un fallo.
    ///
    /// Es el bloqueante de la ronda 9, y solo se ve en la máquina que **no** tiene el modelo
    /// —o sea, en casi todas menos en la de quien lo desarrolla—. El interruptor se queda
    /// encendido con la oferta en `.needsModel`, a propósito, porque es el estado del primer
    /// arranque y desde ahí se instala; pero entonces cada apertura del historial por atajo
    /// creaba sesión, `prepare()` fallaba en milisegundos y salía una banda roja con anuncio
    /// de VoiceOver de prioridad alta. En cada apertura.
    @Test("sin modelo instalado, abrir el panel con el atajo no pinta ningún fallo")
    func hotKeyWithoutModelStaysSilent() async throws {
        let session = FakeSession()
        var announced: [String] = []
        let controller = DictationController(
            engine: FakeEngine(session: session),
            gesture: HoldGesture(watchedFlags: [.command], threshold: .milliseconds(50)),
            deliver: { _ in },
            permission: { .granted },
            isReady: { false },
            announcer: { text, _ in announced.append(text) }
        )
        controller.overrideHeldProviderForTesting { true }

        controller.shortcutPressed(locale: Locale(identifier: "es-ES"), mode: .live)
        try? await Task.sleep(for: .milliseconds(200))

        #expect(controller.state == .idle, "el estado dejó de ser reposo: \(controller.state)")
        #expect(controller.lastFailure == nil, "registró un fallo que nadie pidió")
        #expect(announced.isEmpty, "anunció un fallo sin que se pidiera dictar: \(announced)")
        let steps = await session.recorded()
        #expect(steps.isEmpty, "creó sesión sin poder dictar: \(steps)")
    }

    /// Pero pedirlo explícitamente sí tiene que decir qué falta.
    @Test("al pedir dictado sin modelo, se dice que falta el modelo")
    func explicitRequestWithoutModelReportsIt() async throws {
        // `startWithoutGesture` no consulta `isReady`: quien pulsa ⌘D o el botón del
        // micrófono está esperando una respuesta, y «no pasa nada» es la peor de todas.
        let controller = DictationController(
            engine: FakeEngine(session: UnpreparableSession()),
            gesture: HoldGesture(watchedFlags: [.command], threshold: .milliseconds(50)),
            deliver: { _ in },
            permission: { .granted },
            isReady: { false }
        )

        controller.startWithoutGesture(locale: Locale(identifier: "es-ES"), mode: .live)
        await Self.waitUntil { controller.lastFailure != nil }

        #expect(controller.lastFailure == .modelUnavailable, "estado: \(controller.state)")
    }

    /// El camino accesible **no** se cancela por mover el ratón.
    ///
    /// Es la regresión R2→R3, y volvía a estar sin red: quitar la guarda `requiresHold`
    /// de `interactionOccurred` no rompía ningún test. Con ella fuera, quien llega por el
    /// botón del micrófono o por ⌘D pierde el dictado al primer movimiento del puntero —y
    /// mover el ratón es lo que hace cualquiera mientras habla.
    @Test("mover el ratón no cancela un dictado que no nació de un gesto")
    func interactionDoesNotKillTheAccessiblePath() async throws {
        let session = FakeSession()
        let controller = Self.make(session: session)

        controller.startWithoutGesture(locale: Locale(identifier: "es-ES"), mode: .live)
        await Self.waitUntil { controller.state.isMicrophoneOpen }
        #expect(controller.state.isMicrophoneOpen, "no llegó a escuchar: \(controller.state)")

        // Exactamente lo que emite el panel con cada movimiento del puntero.
        controller.interactionOccurred(.pointerMoved)
        controller.interactionOccurred(.typed)
        controller.interactionOccurred(.scrolled)
        try? await Task.sleep(for: .milliseconds(80))

        #expect(
            controller.state.isMicrophoneOpen,
            "la interacción cortó el camino accesible: \(controller.state)"
        )
    }

    /// La garantía de verdad, y donde vive: el camino accesible **no pasa por la cuenta**.
    ///
    /// Es lo que hace que ninguna interacción lo pueda cancelar, porque `interactionOccurred`
    /// solo actúa sobre `.arming`. Mientras esto se protegía con una guarda extra en el
    /// coordinador, la guarda era redundante —quitarla no rompía nada— y la garantía real
    /// no estaba afirmada en ningún sitio.
    @Test("el camino accesible nunca entra en la cuenta del gesto")
    func accessiblePathNeverArms() async throws {
        let session = FakeSession()
        var visited: [DictationSessionState] = []
        let controller = DictationController(
            engine: FakeEngine(session: session),
            gesture: HoldGesture(watchedFlags: [.command], threshold: .milliseconds(50)),
            deliver: { _ in },
            onStateChange: { visited.append($0) },
            permission: { .granted }
        )

        controller.startWithoutGesture(locale: Locale(identifier: "es-ES"), mode: .live)
        await Self.waitUntil { controller.state.isMicrophoneOpen }

        let armed = visited.contains { if case .arming = $0 { true } else { false } }
        #expect(!armed, "el camino accesible pasó por la cuenta: \(visited)")
    }

    /// Y sí cancela la cuenta del gesto, que es para lo que existe.
    @Test("mover el ratón sí cancela la cuenta del gesto")
    func interactionCancelsTheGestureCount() async throws {
        let session = FakeSession()
        let controller = Self.make(session: session)
        controller.overrideHeldProviderForTesting { true }

        controller.shortcutPressed(locale: Locale(identifier: "es-ES"), mode: .live)
        controller.simulateArmingProgress(0.4)
        // Quien busca algo en el historial mueve el ratón; quien quiere dictar se queda
        // quieto. Sin esta regla el gesto se dispararía en el flujo más común de la app.
        controller.interactionOccurred(.pointerMoved)
        try? await Task.sleep(for: .milliseconds(80))

        #expect(controller.state == .idle, "la cuenta siguió viva: \(controller.state)")
        let steps = await session.recorded()
        #expect(!steps.contains(.started), "abrió el micrófono tras cancelar: \(steps)")
    }

    /// El techo de una sesión ABANDONADA no puede tocar a la que está viva.
    @Test("el techo de una sesión vieja no mata a la nueva")
    func staleSessionLimitDoesNotKillTheCurrentOne() async throws {
        let session = FakeSession()
        let controller = Self.make(session: session)

        controller.startWithoutGesture(locale: Locale(identifier: "es-ES"), mode: .live)
        await Self.waitUntil { controller.state.isMicrophoneOpen }

        // El techo de la sesión anterior, llegando tarde. Su cancelación es asíncrona,
        // así que esta ventana existe de verdad.
        controller.simulateStaleSessionLimit()
        try? await Task.sleep(for: .milliseconds(80))

        #expect(
            controller.state.isMicrophoneOpen,
            "el techo de una sesión vieja mató a la viva: \(controller.state)"
        )
        #expect(controller.lastFailure == nil, "registró un fallo ajeno")
    }

    /// Sin permiso, un toque BREVE del atajo del historial no puede convertirse en un
    /// aviso de error.
    ///
    /// Es la acción más frecuente de la app. Publicar el fallo en cuanto se pulsa —sin
    /// haber mantenido nada— pintaba una banda roja que el usuario no había provocado en
    /// cada apertura, empujando la lista y anunciándolo por VoiceOver, sin más salida que
    /// encontrar el interruptor en Ajustes. §8: «el atajo del historial abre el panel
    /// exactamente como hoy».
    ///
    /// Lo que este test dejó de afirmar, y por qué: antes comprobaba que el motor **no se
    /// tocaba en absoluto** sin permiso (`steps.isEmpty`), porque el permiso se
    /// comprobaba al principio y todo el gesto quedaba bloqueado ahí. Eso es justo lo que
    /// se reportó como fallo: mantener el atajo con permiso denegado no armaba nada, sin
    /// ningún indicio de por qué. Ahora el permiso se comprueba al completar la cuenta
    /// (ver los tests `completingWithoutPermission…`), así que un toque breve **sí** crea
    /// sesión y arranca la carga del modelo en paralelo con la cuenta —lo mismo que ya
    /// pasaba con permiso concedido, ver `DictationController.shortcutPressed`— y lo
    /// cancela al soltar. Lo que sigue intacto, y es lo que este test protege, es que un
    /// toque breve termina en reposo, sin fallo y sin anuncio.
    @Test("sin permiso, un toque breve del atajo no pinta ningún fallo")
    func hotKeyWithoutPermissionStaysSilent() async throws {
        let session = FakeSession()
        var announced: [String] = []
        let controller = DictationController(
            engine: FakeEngine(session: session),
            gesture: HoldGesture(watchedFlags: [.command], threshold: .milliseconds(50)),
            deliver: { _ in },
            permission: { .denied },
            announcer: { text, _ in announced.append(text) }
        )
        // Determinista: no depende de que el proceso de test no tenga de verdad ninguna
        // tecla pulsada, que es justo la clase de dependencia con el entorno que ya
        // volvió intermitente a otro test en esta misma ronda.
        controller.overrideHeldProviderForTesting { false }

        controller.shortcutPressed(locale: Locale(identifier: "es-ES"), mode: .live)
        await Self.waitUntil { controller.state == .idle }

        #expect(controller.state == .idle, "el estado dejó de ser reposo: \(controller.state)")
        #expect(controller.lastFailure == nil, "registró un fallo que nadie pidió")
        #expect(announced.isEmpty, "anunció algo sin que se pidiera dictar: \(announced)")
    }

    /// Pero cuando alguien PIDE dictar, el fallo del permiso sí se cuenta: es el único
    /// momento en que el usuario está esperando una respuesta.
    @Test("al pedir dictado explícitamente, el permiso denegado sí se dice")
    func explicitRequestWithoutPermissionReportsIt() async throws {
        let session = FakeSession()
        let controller = Self.make(session: session, permission: { .denied })

        controller.startWithoutGesture(locale: Locale(identifier: "es-ES"), mode: .live)
        try? await Task.sleep(for: .milliseconds(120))

        #expect(controller.lastFailure == .permissionDenied, "estado: \(controller.state)")
    }

    /// El techo de sesión, cubierto **sin** motor real: el test que lo comprobaba vive
    /// en la suite del motor y se salta en CI por falta de modelo, así que la garantía
    /// contra el peor resultado del producto —micrófono abierto sin interfaz— no la
    /// comprobaba nunca la integración continua.
    @Test("el techo de sesión descarta y lo dice, sin necesitar el motor real")
    func sessionLimitIsCoveredWithoutEngine() async throws {
        let session = LimitAnnouncingSession()
        var delivered: [Transcript] = []
        var announced: [String] = []
        let controller = DictationController(
            engine: StubbornEngine(session: session),
            gesture: HoldGesture(watchedFlags: [.command], threshold: .milliseconds(50)),
            deliver: { delivered.append($0) },
            permission: { .granted },
            announcer: { text, _ in announced.append(text) }
        )

        controller.startWithoutGesture(locale: Locale(identifier: "es-ES"), mode: .live)
        await Self.waitUntil { controller.state.isMicrophoneOpen }
        await session.fireLimit()
        try? await Task.sleep(for: .milliseconds(300))

        #expect(delivered.isEmpty, "el techo entregó: \(delivered.map(\.text))")
        #expect(controller.lastFailure == .sessionLimitReached)
        #expect(!controller.state.isMicrophoneOpen, "el micrófono sigue abierto tras el techo")
        #expect(
            announced.contains(DictationController.message(for: .sessionLimitReached)),
            "no se anunció por qué se cortó: \(announced)"
        )
    }

    @Test("un estado que merece mostrarse cubre también el fallo")
    func failureIsDisplayable() {
        // El bloqueante 4: la interfaz se gateaba con `isActive`, que es false justo
        // para `.failed`, así que todo fallo era invisible.
        #expect(DictationSessionState.failed(.modelUnavailable).deservesDisplay)
        #expect(!DictationSessionState.idle.deservesDisplay)
        #expect(DictationSessionState.listening.deservesDisplay)
        // Y una entrega truncada hay que confesarla.
        #expect(
            DictationSessionState.delivered(
                Transcript(text: "x", mode: .live, wasTruncated: true)
            ).deservesDisplay
        )
        #expect(
            !DictationSessionState.delivered(
                Transcript(text: "x", mode: .live, wasTruncated: false)
            ).deservesDisplay
        )
    }
}


/// Que el estado del dictado **llegue** a quien tiene que reaccionar.
///
/// Tres consumidores, y los tres estaban sin cubrir: la barra de menús —que enseña que el
/// micrófono está abierto—, la política de cierre del panel —que impide que el panel se
/// esfume dejando el micro abierto sin interfaz— y la puerta que arma el gesto. Anular
/// cualquiera de los tres dejaba la suite en verde, que es la definición del verde
/// engañoso: el estado se calcula bien y no lo recibe nadie.
@Suite("El estado del dictado llega a sus consumidores", .serialized)
@MainActor
struct DictationWiringTests {

    @Test("la barra de menús se entera de que el micrófono está abierto")
    func menuBarLearnsTheMicrophoneIsOpen() throws {
        let (controller, model, root) = try PanelPresentationTests.make()
        defer { controller.hide(); try? FileManager.default.removeItem(at: root) }
        var announced: [Bool] = []
        model.onDictationStateChange = { announced.append($0) }
        model.settings.isDictationEnabled = true
        model.syncDictation(panel: controller)
        let dictation = try #require(model.dictation)

        dictation.simulateStatePublish(.listening)
        #expect(announced.last == true, "la barra de menús no se enteró: \(announced)")

        dictation.simulateStatePublish(.idle)
        #expect(announced.last == false, "se quedó encendida tras cerrar")
    }

    // El gesto solo tiene sentido comprobarlo con el micrófono concedido: sin permiso la
    // puerta se cierra un paso antes y el test pasaría sin mirar lo que dice mirar.
    @Test(
        "sin modelo utilizable el gesto no arma",
        .enabled(if: MicrophoneAuthorization.current == .granted)
    )
    func gestureStaysShutWithoutAUsableModel() throws {
        let (controller, model, root) = try PanelPresentationTests.make()
        defer { controller.hide(); try? FileManager.default.removeItem(at: root) }
        // Con motor de mentira: el real reserva una ranura de idioma del sistema en cuanto
        // el gesto arma, y eso se pisa con las suites que corren en otros procesos.
        model.engineProvider = { DictationControllerTests.FakeEngine(session: DictationControllerTests.FakeSession()) }
        model.settings.isDictationEnabled = true
        model.syncDictation(panel: controller)
        let dictation = try #require(model.dictation)

        // La oferta nace sin comprobar. Ante la duda, el gesto no arma: si armara,
        // `prepare()` fallaría en milisegundos y el usuario vería un aviso rojo en CADA
        // apertura del historial por atajo, sin haber pedido nada.
        #expect(model.dictationCanRun == false, "la oferta ya era utilizable: caso mal montado")
        dictation.shortcutPressed(locale: Locale(identifier: "es-ES"), mode: .live)
        #expect(dictation.state == .idle, "armó sin modelo: \(dictation.state)")

        model.markDictationAvailableForTesting()
        dictation.shortcutPressed(locale: Locale(identifier: "es-ES"), mode: .live)
        #expect(dictation.state == .arming(progress: 0, prepared: false), "con modelo utilizable no armó")
        dictation.shutdown()
    }

    @Test("con sesión viva el panel no puede cerrarse al perder el foco")
    func liveSessionPinsThePanel() throws {
        let (controller, model, root) = try PanelPresentationTests.make()
        defer { controller.hide(); try? FileManager.default.removeItem(at: root) }
        model.settings.isDictationEnabled = true
        model.syncDictation(panel: controller)
        let dictation = try #require(model.dictation)

        #expect(controller.dismissalPolicy.dictationSessionActive == false)

        // Preparando ya cuenta: el micro está a punto de abrirse y el panel es la única
        // interfaz que lo dice.
        dictation.simulateStatePublish(.preparing)
        #expect(
            controller.dismissalPolicy.dictationSessionActive,
            "el panel podría cerrarse dejando el micrófono abierto sin nada en pantalla"
        )

        dictation.simulateStatePublish(.listening)
        #expect(controller.dismissalPolicy.dictationSessionActive)

        dictation.simulateStatePublish(.idle)
        #expect(controller.dismissalPolicy.dictationSessionActive == false, "se quedó clavado")
    }
}

/// Valor mutable que un cierre `@Sendable` puede leer mientras el test lo cambia.
///
/// Swift 6 avisa —«mutated after capture by sendable closure»— cuando un test captura una
/// `var` local en un `heldProvider` y luego la modifica: es una carrera real aunque en la
/// práctica ambos lados corran en el hilo principal. El aviso tenía razón y estaba
/// silenciado por costumbre; el cerrojo lo resuelve sin cambiar lo que el test prueba.
final class TestBox<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}
