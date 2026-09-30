import AVFoundation
import Foundation
import Speech
import Testing

@testable import VoiceKit

/// F2 — el motor transcribe de verdad.
///
/// Estos tests **no usan dobles**: hablan con el framework Speech del sistema y
/// transcriben audio real generado con la voz sintética de macOS, igual que el
/// test del reconocimiento de texto usa Vision sobre una imagen generada. Un
/// doble aquí no probaría nada de lo que importa: los fallos que hemos encontrado
/// —el formato incompatible que aborta el proceso, la última palabra que se
/// pierde sin silencio final— solo aparecen contra el motor auténtico.
///
/// Requisitos de la máquina: el modelo de `es-ES` instalado y una voz española
/// para `say`. Si falta el modelo, el test **falla con un mensaje accionable** en
/// lugar de saltarse en silencio: sin él, el criterio de salida de esta fase
/// («transcripción real de un audio de prueba») no se puede afirmar.
/// La suite es **serializada** a propósito: `AssetInventory` es un recurso global
/// del proceso con un cupo pequeño (cinco idiomas), así que dos tests reservando
/// a la vez se pisan. Con ejecución paralela, uno fallaba con «cupo excedido» por
/// una reserva que había hecho otro.
/// Se saltan **de forma declarada** cuando no hay modelo de voz en la máquina.
///
/// Estos tests hablan con el framework real y necesitan el modelo de `es-ES`
/// instalado más una voz española para `say`. El runner de CI no tiene ninguno de
/// los dos, así que sin esta condición el gate nativo se pondría rojo en cada PR
/// que toque `native/` — y un CI que siempre falla deja de decir nada.
///
/// La condición es una variable de entorno y no una comprobación automática a
/// propósito: así saltárselos es una decisión visible en la configuración del CI,
/// no algo que ocurre solo. En local corren siempre.
@Suite("Motor de transcripción sobre el framework Speech", .serialized)
struct SpeechEngineTests {

    static let locale = Locale(identifier: "es-ES")

    /// Genera un WAV con voz sintética, ya en el formato que el motor prefiere.
    ///
    /// `async`, y espera con `terminationHandler`, no con `waitUntilExit()`. Esa llamada
    /// es SÍNCRONA: bloquea de verdad el hilo del sistema operativo que la ejecuta hasta
    /// que `say` termina, y ese hilo sale del fondo COOPERATIVO y limitado de Swift
    /// Concurrency —tantos hilos como núcleos, no uno por tarea—. Con la suite entera
    /// corriendo, cada llamada bloqueada competía por uno de esos hilos con tests de
    /// otras suites, y era una de las causas medidas de que la suite local diera roja
    /// una de cada seis pasadas sin que nada en el código hubiera cambiado.
    static func synthesize(_ text: String) async throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "ambar-voicekit-\(UUID().uuidString).wav")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        process.arguments = [
            "-o", url.path(percentEncoded: false),
            // 16 kHz mono Int16: lo que pide el transcriptor. Aun así el camino
            // pasa por el convertidor, porque `processingFormat` es Float32.
            "--data-format=LEI16@16000",
            text,
        ]
        process.standardError = FileHandle.nullDevice

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            process.terminationHandler = { _ in continuation.resume() }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                continuation.resume(throwing: error)
            }
        }

        guard process.terminationStatus == 0,
              FileManager.default.fileExists(atPath: url.path(percentEncoded: false))
        else {
            throw TestFailure.synthesisUnavailable
        }
        return url
    }

    enum TestFailure: Error { case synthesisUnavailable }

    /// Registro del aviso del techo, seguro entre dominios de aislamiento.
    actor LimitNotice {
        private(set) var happened = false
        func record() { happened = true }
    }

    /// Transcribe un fichero de principio a fin con el motor real.
    static func transcribe(
        _ url: URL,
        silenceTail: Double = SpeechSession.defaultSilenceTailSeconds
    ) async throws -> Transcript {
        // Bajo el cerrojo: crear una sesión real reserva el idioma, que es una de las cinco
        // ranuras de **toda la máquina**. Sin esto, un test que afirma «no hay ninguna
        // reserva» falla porque otro la tenía cogida, y el rojo no dice nada del código.
        try await SystemInventoryLock.shared.exclusive {
            try await transcribeBody(url, silenceTail: silenceTail)
        }
    }

    static func transcribeBody(
        _ url: URL,
        silenceTail: Double = SpeechSession.defaultSilenceTailSeconds
    ) async throws -> Transcript {
        let session = SpeechSession(
            locale: locale,
            mode: .live,
            source: .file(url),
            silenceTailSeconds: silenceTail
        )
        try await session.prepare()
        let stream = try await session.start()
        // Los fragmentos se consumen como los consumiría el panel en vivo.
        let drain = Task { for await _ in stream {} }
        let transcript = try await session.finish()
        _ = await drain.value
        return transcript
    }

    // MARK: - El criterio de salida de la fase

    @Test("transcribe audio real de principio a fin", .enabled(
        if: ProcessInfo.processInfo.environment["AMBAR_SKIP_SPEECH_TESTS"] == nil,
        "necesita el modelo de voz instalado; el runner de CI no lo trae"
    ))
    func transcribesRealAudio() async throws {
        let url = try await Self.synthesize(
            "Hola, esto es una prueba de dictado en español."
        )
        defer { try? FileManager.default.removeItem(at: url) }

        let transcript = try await Self.transcribe(url)
        let text = transcript.text.lowercased()

        #expect(!transcript.isEmpty, "no se transcribió nada")
        #expect(text.contains("prueba"), "transcripción inesperada: «\(transcript.text)»")
        #expect(text.contains("dictado"), "transcripción inesperada: «\(transcript.text)»")
        #expect(transcript.mode == .live)
        #expect(!transcript.wasTruncated)
    }

    /// La última palabra llega **con** cola de silencio. Eso es lo que se afirma, y
    /// nada más, porque es lo único estable.
    ///
    /// Tres mediciones y tres conclusiones distintas sobre el caso sin cola: un
    /// sondeo dijo que la palabra se perdía (pero no esperaba la finalización), luego
    /// dos frases cortas sobrevivieron sin cola y se escribió que la cola no aportaba
    /// nada, y después un auditor midió «…con Amb» con una frase larga mientras aquí,
    /// con la misma frase, llegaba completa.
    ///
    /// La lectura correcta no es ninguna de las tres: **sin cola el resultado es
    /// inconsistente entre ejecuciones**, y eso es precisamente el argumento para
    /// mantenerla — no se puede depender de algo que funciona a veces. Así que el
    /// test afirma el caso que importa y protege la constante con un mínimo, en lugar
    /// de fijar un contrafáctico que no se sostiene.
    @Test("con cola de silencio la última palabra llega", .enabled(
        if: ProcessInfo.processInfo.environment["AMBAR_SKIP_SPEECH_TESTS"] == nil,
        "necesita el modelo de voz instalado; el runner de CI no lo trae"
    ))
    func finalWordArrivesWithSilenceTail() async throws {
        let url = try await Self.synthesize(
            "Hola, esto es una prueba de dictado en español con Ámbar"
        )
        defer { try? FileManager.default.removeItem(at: url) }

        let transcript = try await Self.transcribe(url)
        #expect(
            transcript.text.lowercased().contains("ámbar"),
            "se perdió la última palabra: «\(transcript.text)»"
        )
    }

    @Test("la cola de silencio no puede quedarse en cero sin evidencia")
    func silenceTailHasAFloor() {
        // No es una tautología sobre una constante: es la barrera que impide repetir
        // el error de bajarla a 0 apoyándose en una muestra de dos frases cortas.
        #expect(
            SpeechSession.defaultSilenceTailSeconds >= 0.3,
            """
            la cola está en \(SpeechSession.defaultSilenceTailSeconds) s. Sin ella el \
            comportamiento del motor es inconsistente entre ejecuciones; para bajarla \
            hacen falta varias frases largas medidas, no dos cortas.
            """
        )
    }

    // MARK: - El catálogo

    // Sin condición a propósito: solo consulta el catálogo de locales admitidos, que
    // no requiere ningún modelo instalado. Y es la afirmación que sostiene toda la
    // localización del dictado, así que tiene que correr también en CI.
    @Test("los diez idiomas de la interfaz están soportados por el motor")
    func allInterfaceLanguagesAreSupported() async throws {
        // Los mismos diez de `CFBundleLocalizations`. Si el motor dejara de
        // cubrir alguno, el dictado quedaría no disponible para esos usuarios y
        // hay que saberlo aquí, no por un informe de alguien.
        let catalog = SpeechModelCatalog(mode: .live)
        for tag in ["es", "en", "fr", "de", "it", "pt-BR", "ja", "zh-Hans", "ko", "ru"] {
            let resolved = await catalog.supportedLocale(equivalentTo: Locale(identifier: tag))
            #expect(resolved != nil, "el motor no admite \(tag)")
        }
    }

    @Test("un idioma que el motor no admite se reporta como no soportado", .enabled(
        if: ProcessInfo.processInfo.environment["AMBAR_SKIP_SPEECH_TESTS"] == nil,
        "necesita el modelo de voz instalado; el runner de CI no lo trae"
    ))
    func unsupportedLocaleIsReported() async throws {
        let catalog = SpeechModelCatalog(mode: .live)
        // Euskera y gallego no están entre los locales del transcriptor.
        for tag in ["eu", "gl"] {
            let resolved = await catalog.supportedLocale(equivalentTo: Locale(identifier: tag))
            #expect(resolved == nil, "\(tag) debería salir como no soportado")
            #expect(await catalog.availability(forLocale: Locale(identifier: tag)) == .unsupported)
        }
    }

    /// El orden de operaciones que descubrió el sondeo, fijado como test.
    ///
    /// Sin reservar, `AssetInventory` responde `supported` —«hay que instalar»—
    /// para un idioma cuyo modelo ya está en la máquina. Quien invierta este orden
    /// le anunciará una descarga a alguien que no la necesita.
    @Test("reservar el idioma es lo que lo hace disponible", .enabled(
        if: ProcessInfo.processInfo.environment["AMBAR_SKIP_SPEECH_TESTS"] == nil,
        "necesita el modelo de voz instalado; el runner de CI no lo trae"
    ))
    func reservationMakesModelAvailable() async throws {
        try await SystemInventoryLock.shared.exclusive {
            try await Self.reservationMakesModelAvailableBody()
        }
    }

    static func reservationMakesModelAvailableBody() async throws {
        let catalog = SpeechModelCatalog(mode: .live)
        let (maximum, _) = await catalog.reservation()
        #expect(maximum > 0, "el sistema informa de un cupo de idiomas")

        // NO se afirma el booleano de `reserve`. Devuelve `false` en dos situaciones
        // opuestas —cupo lleno y **ya reservado por este proceso**—, y la reserva es estado
        // global: otro test de la misma pasada puede tenerla cogida. Afirmarlo hacía este
        // test **intermitente**, con un fallo que se leía como «cupo lleno» y que dependía
        // del orden de ejecución.
        //
        // Lo que se afirma es la propiedad: después de reservar, el idioma está sostenido.
        _ = try await catalog.reserve(locale: Self.locale)
        let heldByUs = await catalog.holdsReservation(forLocale: Self.locale)
        #expect(heldByUs, "el idioma no quedó reservado; ¿cupo del sistema lleno?")
        // Se suelta al final y **esperando**, no en un `defer { Task { … } }`: esa tarea
        // corría después de salir del cerrojo, así que liberaba el idioma cuando otro test
        // ya lo había reservado. Es la otra mitad de la intermitencia.

        let availability = await catalog.availability(forLocale: Self.locale)
        #expect(
            availability == .installed,
            """
            tras reservar, es-ES debería estar disponible. Si sale \
            «\(availability.rawValue)», falta instalar el modelo: actívalo en \
            Ajustes del Sistema → Teclado → Dictado, en español.
            """
        )

        let (_, after) = await catalog.reservation()
        #expect(after.contains { $0.identifier.hasPrefix("es") }, "la reserva no aparece")

        await catalog.release(locale: Self.locale)
    }

    /// La fuga que el auditor reprodujo, fijada.
    ///
    /// `prepare()` tiene siete puntos de suspensión y `cancel()` puede colarse en
    /// cualquiera. Sin la comprobación de generación, `prepare()` reanudaba y
    /// reasignaba estado —incluido `didReserve = true`— sobre una sesión que ya
    /// nadie sostenía: nadie volvía a soltar el idioma y se perdía una de las cinco
    /// ranuras del sistema. Y producción entra exactamente por ahí: el panel llama a
    /// `shortcutPressed` en cada apertura, y si no se mantiene el atajo se cancela
    /// en el primer tick.
    @Test("cancelar mientras se prepara no deja el idioma reservado", .enabled(
        if: ProcessInfo.processInfo.environment["AMBAR_SKIP_SPEECH_TESTS"] == nil,
        "necesita el modelo de voz instalado; el runner de CI no lo trae"
    ))
    func cancellingDuringPrepareDoesNotLeakReservation() async throws {
        try await SystemInventoryLock.shared.exclusive {
            try await Self.cancellingDuringPrepareBody()
        }
    }

    static func cancellingDuringPrepareBody() async throws {
        let catalog = SpeechModelCatalog(mode: .live)
        // Se parte de limpio para que el resultado no dependa de otra reserva. Esto le
        // QUITA la reserva a quien la tenga, así que el cuerpo va bajo el cerrojo del
        // inventario: sin él, este test tumbaba al de al lado y viceversa. Era una de las
        // dos causas de que la suite fallara 6 de 17 pasadas sin que nada cambiara.
        await catalog.release(locale: Self.locale)

        for delay in [Duration.zero, .milliseconds(1), .milliseconds(20)] {
            let session = SpeechSession(locale: Self.locale, mode: .live, source: .file(URL(fileURLWithPath: "/dev/null")))
            let prepare = Task { try? await session.prepare() }
            if delay > .zero { try? await Task.sleep(for: delay) }
            await session.cancel()
            _ = await prepare.value

            // Margen para que un `prepare()` suspendido reanude y, si estuviera
            // mal, publicara su reserva después de la cancelación.
            try? await Task.sleep(for: .milliseconds(120))

            // Se afirma sobre **esta** sesión, no sobre el inventario del sistema. El
            // inventario es global al bundle: otro proceso de tests del mismo binario
            // —una auditoría corriendo en una copia del árbol, por ejemplo— reserva contra
            // el mismo cupo, y afirmar «no hay ninguna reserva» medía a los demás. Este
            // test falló así 4 de ~25 pasadas, y un rojo que no dice nada del código es
            // peor que no tener test: enseña a ignorarlo.
            #expect(
                await session.holdsReservationForTesting == false,
                "la sesión cancelada con retardo \(delay) se quedó con la ranura"
            )
            await catalog.release(locale: Self.locale)
        }
    }

    /// Los cuatro caminos de error de `prepare()` sueltan la reserva.
    ///
    /// El arreglo estaba sin red: la mutación que quita `releaseReservationIfOurs()`
    /// del camino «modelo no instalado» dejaba la suite entera en verde, y cada fuga
    /// se come una de las cinco ranuras de idioma del sistema.
    @Test("un prepare que falla no se queda el idioma reservado", .enabled(
        if: ProcessInfo.processInfo.environment["AMBAR_SKIP_SPEECH_TESTS"] == nil,
        "necesita el modelo de voz instalado; el runner de CI no lo trae"
    ))
    func failedPrepareReleasesReservation() async throws {
        let catalog = SpeechModelCatalog(mode: .live)
        // Un idioma soportado por el motor pero cuyo modelo no está instalado en
        // esta máquina: el camino `modelNotInstalled`.
        let locale = Locale(identifier: "ru-RU")
        await catalog.release(locale: locale)

        let session = SpeechSession(locale: locale, mode: .live, source: .file(URL(fileURLWithPath: "/dev/null")))
        await #expect(throws: (any Error).self) { try await session.prepare() }

        let (_, reserved) = await catalog.reservation()
        #expect(
            !reserved.contains { $0.identifier.hasPrefix("ru") },
            "reserva fugada tras un prepare fallido: \(reserved.map(\.identifier))"
        )
    }

    @Test("el cupo de idiomas del sistema se respeta y se informa", .enabled(
        if: ProcessInfo.processInfo.environment["AMBAR_SKIP_SPEECH_TESTS"] == nil,
        "necesita el modelo de voz instalado; el runner de CI no lo trae"
    ))
    func reservationQuotaIsVisible() async throws {
        let catalog = SpeechModelCatalog(mode: .live)
        let (maximum, reserved) = await catalog.reservation()
        // No se afirma un número concreto: es una cifra del sistema y puede
        // cambiar entre versiones. Lo que importa es que exista y que las
        // reservas actuales no lo superen.
        #expect(maximum >= 1)
        #expect(reserved.count <= maximum)
    }

    /// El techo de duración tiene que **cerrar**, no solo avisar.
    ///
    /// Avisar solo no basta: el aviso viaja por un closure `[weak self]` hacia el
    /// coordinador, y si alguien lo soltó —apagar el dictado— no llega a nadie y el
    /// micrófono se queda abierto. El techo es la única garantía contra una tecla
    /// enclavada, así que tiene que ser una garantía de la sesión.
    @Test("el techo de duración cierra la sesión, no solo avisa", .enabled(
        if: ProcessInfo.processInfo.environment["AMBAR_SKIP_SPEECH_TESTS"] == nil,
        "necesita el modelo de voz instalado; el runner de CI no lo trae"
    ))
    func sessionLimitClosesTheSession() async throws {
        try await SystemInventoryLock.shared.exclusive {
            try await Self.sessionLimitBody()
        }
    }

    /// Corre `work` con un tope de tiempo. Devuelve `false` si no acabó a tiempo, en
    /// vez de dejar el `await` colgado sin explicación — ver el comentario de
    /// `sessionLimitBody` sobre por qué esto hacía falta.
    ///
    /// **No** con `withTaskGroup`: un grupo estructurado espera a que TODAS sus tareas
    /// hijas terminen antes de devolver el control, cancelación incluida —es la garantía
    /// de concurrencia estructurada de Swift, no un descuido—, así que si `work()` está
    /// bloqueada en un `await` que nunca vuelve, cancelar el grupo no libera la función:
    /// se comprobó, y colgaba igual. Con tareas SUELTAS y un guardián de un solo uso, la
    /// tarea perdedora sigue viva de fondo pero ya no bloquea a nadie.
    static func raceAgainstTimeout(
        _ timeout: Duration,
        _ work: @escaping @Sendable () async -> Void
    ) async -> Bool {
        let gate = TimeoutGate()
        return await withCheckedContinuation { continuation in
            Task {
                await work()
                if await gate.claim() { continuation.resume(returning: true) }
            }
            Task {
                try? await Task.sleep(for: timeout)
                if await gate.claim() { continuation.resume(returning: false) }
            }
        }
    }

    actor TimeoutGate {
        private var done = false
        func claim() -> Bool {
            guard !done else { return false }
            done = true
            return true
        }
    }

    static func sessionLimitBody() async throws {
        let url = try await Self.synthesize("Uno dos tres cuatro cinco")
        defer { try? FileManager.default.removeItem(at: url) }

        let session = SpeechSession(
            locale: Self.locale,
            mode: .live,
            source: .file(url),
            // Techo muy corto para no esperar media hora.
            maximumSessionDuration: .milliseconds(300)
        )
        // Un actor y no una `var` capturada: el handler se invoca desde otro
        // dominio y Swift 6 no lo permite de otra forma.
        let notice = LimitNotice()
        // Por el existencial, que es como lo hace el coordinador. Por el tipo concreto
        // la llamada resolvía a la implementación por defecto del protocolo —vacía— y no
        // guardaba nada: ese no-op ya no existe, y esta línea lo comprueba.
        let asSession: any TranscriptionSession = session
        await asSession.setSessionLimitHandler { Task { await notice.record() } }
        #expect(
            await session.hasSessionLimitHandlerForTesting,
            "el manejador del techo no se guardó"
        )

        try await session.prepare()
        let stream = try await session.start()
        let drain = Task { for await _ in stream {} }

        try? await Task.sleep(for: .milliseconds(900))
        // Con tope, no un `await` desnudo. Sin el temporizador de producción del techo
        // —que este test existe justamente para proteger— la cola de la sesión nunca se
        // cierra y `drain.value` no vuelve NUNCA: medido, más de 300 s antes de matarlo a
        // mano. Ese cuelgue es indistinguible de «la máquina va lenta», así que quien lo
        // encuentra no sabe qué se rompió. Con tope, la misma regresión da un rojo legible
        // en segundos.
        let drained = await Self.raceAgainstTimeout(.seconds(5)) { await drain.value }
        #expect(drained, "drenar el flujo colgó: el temporizador del techo desapareció")

        // Lo esencial: el techo CIERRA. Es la garantía que no puede depender de que
        // alguien escuche el aviso.
        #expect(await session.isClosed, "el techo no cerró la sesión")

        // Y avisa. La versión anterior de este test renunciaba a comprobarlo —«el
        // handler aparece sin asignar cuando el techo dispara»— y esa renuncia era
        // infundada: una sonda contra el módulo compilado midió que sí avisa. Sin esta
        // aserción, la mitad del contrato del techo no estaba cubierta.
        await #expect(throws: DictationEngineError.sessionClosedByLimit) {
            try await session.finish()
        }
        try? await Task.sleep(for: .milliseconds(200))
        #expect(await notice.happened, "el techo cerró sin avisar a nadie")

        // Y lo dictado NO se puede recuperar después. Es la parte que de verdad
        // importa, porque el techo existe para el caso en que nadie quiso dictar: sin
        // esto, `finish()` devolvía el texto acumulado —medido— y una carrera de 40 ms
        // bastaba para pegar el audio ambiente entero en el documento del usuario.
        await #expect(throws: DictationEngineError.sessionClosedByLimit) {
            try await session.finish()
        }
    }

    // MARK: - Conversión de formato

    @Test("el silencio se genera en el formato del motor y está a cero")
    func silenceBufferIsZeroed() throws {
        let format = try #require(
            AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true)
        )
        let buffer = try #require(AudioFormatConverter.silence(in: format, seconds: 0.1))

        #expect(buffer.frameLength == 1600)
        let channel = try #require(buffer.int16ChannelData)
        // Un buffer recién asignado no está garantizado a cero: si esto falla, el
        // «silencio» sería ruido y el motor lo intentaría transcribir.
        for frame in 0..<Int(buffer.frameLength) {
            #expect(channel[0][frame] == 0)
        }
    }

    @Test("convertir de Float32 a 48 kHz al formato del motor produce audio")
    func conversionProducesAudio() throws {
        let source = try #require(
            AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 1, interleaved: false)
        )
        let target = try #require(
            AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true)
        )
        let converter = try #require(AudioFormatConverter(from: source, to: target))

        // Un tono, no silencio: el remuestreo de silencio no distingue un
        // convertidor que funciona de uno que devuelve ceros.
        let frames: AVAudioFrameCount = 4800
        let input = try #require(AVAudioPCMBuffer(pcmFormat: source, frameCapacity: frames))
        input.frameLength = frames
        let channel = try #require(input.floatChannelData)
        for frame in 0..<Int(frames) {
            channel[0][frame] = sin(Float(frame) * 0.05) * 0.5
        }

        let output = try #require(converter.convert(input))
        #expect(output.format.sampleRate == 16000)
        #expect(output.frameLength > 0)
        // 48 kHz → 16 kHz debería dar un tercio de los marcos: 1600 para 4800.
        // Medido: 1360. La primera llamada al convertidor devuelve MENOS de lo
        // teórico porque su filtro de remuestreo necesita cebarse, y esos ~240
        // marcos (15 ms) se quedan dentro. En un flujo continuo el filtro ya está
        // cargado y la pérdida no se repite; solo afecta al primer buffer de cada
        // sesión, que es silencio o el arranque de la primera sílaba.
        #expect(output.frameLength > 1200 && output.frameLength < 1700,
                "marcos inesperados: \(output.frameLength)")

        let outChannel = try #require(output.int16ChannelData)
        let peak = (0..<Int(output.frameLength)).map { abs(Int(outChannel[0][$0])) }.max() ?? 0
        #expect(peak > 1000, "la conversión devolvió algo casi mudo: pico \(peak)")
    }

    /// El test que faltaba, y que un nombre bonito ocultaba.
    ///
    /// Había un test llamado «la cola del micrófono está acotada y la del fichero
    /// no» que solo ejercitaba la aritmética de `AudioQueue.capacity()`: ninguna
    /// aserción dependía de la fuente. Y el invariante que su nombre afirmaba era
    /// **falso** — `SpeechSession.start()` acotaba el carril para todas las
    /// fuentes, así que un audio de 90 s salía con 34 caracteres de 1442.
    ///
    /// Éste transcribe de verdad un audio largo y exige el contenido completo:
    /// principio, medio y final. Es la única forma de que el fallo no vuelva.
    @Test("un audio largo se transcribe íntegro, sin perder el medio", .enabled(
        if: ProcessInfo.processInfo.environment["AMBAR_SKIP_SPEECH_TESTS"] == nil,
        "necesita el modelo de voz instalado; el runner de CI no lo trae"
    ))
    func longAudioIsNotTruncated() async throws {
        // Números en orden: si se descarta audio, faltan los del medio, y eso es
        // visible sin ambigüedad. Una frase normal se puede parafrasear; una
        // secuencia numérica, no.
        let spoken = (1...20).map(String.init).joined(separator: ", ")
        let url = try await Self.synthesize(spoken)
        defer { try? FileManager.default.removeItem(at: url) }

        let transcript = try await Self.transcribe(url)
        let text = transcript.text

        // Se comprueban los tres tercios por separado: perder el medio es
        // exactamente el modo de fallo de una cola con descarte.
        for expected in ["1", "2", "3"] {
            #expect(text.contains(expected), "falta el principio: «\(text)»")
        }
        for expected in ["9", "10", "11", "12"] {
            #expect(text.contains(expected), "falta el medio (¿cola con descarte?): «\(text)»")
        }
        for expected in ["19", "20"] {
            #expect(text.contains(expected), "falta el final: «\(text)»")
        }
        // Y una comprobación de volumen: con descarte el texto se queda en una
        // fracción de lo dictado.
        #expect(
            text.count >= spoken.count / 2,
            "se transcribió menos de la mitad: \(text.count) de \(spoken.count) caracteres"
        )
    }

    /// Afirma sobre la política que usan **las fuentes**, que es la que viaja.
    ///
    /// Este test ha tenido que corregirse dos veces por el mismo defecto de método.
    /// Primero afirmaba sobre `AudioQueue.capacity()` a secas: romper el dimensionado real
    /// lo dejaba verde. Luego sobre `SpeechSession.feedPolicy`, que era una **segunda copia
    /// del criterio** y se había quedado sin llamador —la sesión pregunta
    /// `source.bufferingPolicy`—: cobertura de código muerto, que da confianza sin proteger
    /// nada. La copia se ha borrado; esto pregunta ahora a las dos fuentes de verdad.
    @Test("la política de la cola la decide la fuente, y el micrófono cuenta marcos convertidos")
    func feedPolicyDependsOnSource() {
        // Fichero: sin acotar, o se pierde el medio del audio en silencio.
        guard case .unbounded = AudioQueue.sourcePolicy(
            for: .file(URL(fileURLWithPath: "/tmp/x")),
            targetSampleRate: 16000
        ) else {
            Issue.record("la cola del fichero está acotada: mutilaría la transcripción")
            return
        }

        // Micrófono: acotada, y dimensionada en marcos ya convertidos (~2 s).
        guard case .bufferingNewest(let capacity) = AudioQueue.sourcePolicy(
            for: .microphone,
            targetSampleRate: 16000
        ) else {
            Issue.record("la cola del micrófono no está acotada: la latencia crecería sin techo")
            return
        }
        #expect(capacity >= 20 && capacity <= 26, "capacidad \(capacity): ¿marcos del tap en vez de convertidos?")

        // Degrada con dignidad ante valores absurdos en lugar de dividir por cero.
        #expect(AudioQueue.capacity(chunkFrames: 0, sampleRate: 48000) == 8)
        #expect(AudioQueue.capacity(chunkFrames: 4096, sampleRate: 0) == 8)
    }
}

/// La fuente de audio se PARA de verdad al cerrar la sesión, por los tres caminos.
///
/// Hallazgo de la auditoría independiente (bloqueante): `teardown()`, `cancel()` y
/// `finish()` llaman a `source?.stop()` — el código está ahí, y sus comentarios
/// describen exactamente el fallo que existe para evitar («llegar aquí con ella viva
/// dejaría el tap instalado, el motor corriendo y el micrófono abierto») — pero **nadie
/// lo comprobaba**: `start()` siempre construía una fuente real nueva y se la asignaba a
/// sí misma, así que no había forma de observar si `stop()` se había llamado de verdad.
/// `SpeechSession.start()` ahora respeta una fuente ya inyectada (`setSourceForTesting`)
/// en vez de pisarla, que es lo mínimo que hacía falta para que esto fuera observable.
@Suite("La fuente de audio se para al cerrar la sesión", .serialized)
struct SourceStopWiringTests {

    /// No produce audio real —una cadena vacía basta para que el analizador finalice sin
    /// nada que transcribir— y solo cuenta cuántas veces se le pidió parar.
    final class RecordingSource: AudioSource, @unchecked Sendable {
        private(set) var stopCallCount = 0
        var sequenceEnd: CMTime? { nil }
        func start() throws -> AsyncStream<AnalyzerInput> { AsyncStream { $0.finish() } }
        func stop() { stopCallCount += 1 }
        var bufferingPolicy: AsyncStream<AnalyzerInput>.Continuation.BufferingPolicy { .unbounded }
    }

    @Test("finish() para la fuente", .enabled(
        if: ProcessInfo.processInfo.environment["AMBAR_SKIP_SPEECH_TESTS"] == nil,
        "necesita el modelo de voz instalado; el runner de CI no lo trae"
    ))
    func finishStopsTheSource() async throws {
        try await SystemInventoryLock.shared.exclusive {
            let session = SpeechSession(
                locale: SpeechEngineTests.locale,
                mode: .live,
                source: .file(URL(fileURLWithPath: "/dev/null"))
            )
            let recording = RecordingSource()
            await session.setSourceForTesting(recording)
            try await session.prepare()
            let stream = try await session.start()
            let drain = Task { for await _ in stream {} }
            _ = try await session.finish()
            _ = await drain.value

            // Dos veces: una defensiva al principio de `finish()` y otra dentro de
            // `teardown()`, que `finish()` llama al final. La redundancia es
            // deliberada —dos caminos de vuelta a la fuente parada—, así que el
            // recuento exacto es lo que hace falta para que borrar CUALQUIERA de los
            // dos sitios, no solo los dos a la vez, tumbe este test.
            #expect(recording.stopCallCount == 2, "finish() paró la fuente \(recording.stopCallCount) veces, se esperaban 2")
        }
    }

    @Test("cancel() para la fuente", .enabled(
        if: ProcessInfo.processInfo.environment["AMBAR_SKIP_SPEECH_TESTS"] == nil,
        "necesita el modelo de voz instalado; el runner de CI no lo trae"
    ))
    func cancelStopsTheSource() async throws {
        try await SystemInventoryLock.shared.exclusive {
            let session = SpeechSession(
                locale: SpeechEngineTests.locale,
                mode: .live,
                source: .file(URL(fileURLWithPath: "/dev/null"))
            )
            let recording = RecordingSource()
            await session.setSourceForTesting(recording)
            try await session.prepare()
            let stream = try await session.start()
            let drain = Task { for await _ in stream {} }
            await session.cancel()
            _ = await drain.value

            // Misma redundancia deliberada que en `finish()`: una llamada directa en
            // `cancel()` y otra dentro de `teardown()`.
            #expect(recording.stopCallCount == 2, "cancel() paró la fuente \(recording.stopCallCount) veces, se esperaban 2")
        }
    }
}

/// Un cambio de dispositivo a mitad de sesión llega hasta el coordinador.
///
/// Hallazgo de la auditoría independiente (bloqueante): `handleConfigurationChange` y
/// `setDeviceChangeHandler` se podían desconectar en silencio, y es exactamente el fallo
/// que `Transcriber.swift` describe como ya resuelto una vez —«conectar auriculares a
/// mitad de sesión invalida el formato negociado; sin observarlo, la sesión se queda en
/// "Escuchando" sin recibir nada»—. El único test existente cubre el CABLEADO del
/// coordinador con un doble; nada comprobaba que la propia sesión reenviara el aviso real
/// de AVFoundation. Se usa un `MicrophoneSource` de verdad —inyectado con
/// `setSourceForTesting`, que ahora `start()` respeta— para poder disparar la
/// notificación real y comprobar que cruza hasta `onDeviceChange`.
/// Vive detrás del gate del motor, como sus hermanos: `prepare()` + `start()` exigen el
/// analizador real y el modelo instalado. Se olvidó al escribirlo, y el fallo solo podía
/// verse en el runner —aquí el modelo está puesto y pasa—, así que esperó a que la rama
/// se subiera por primera vez para salir: `Caught error: .modelNotInstalled`.
///
/// Es el patrón que este proyecto lleva rondas cazando, en su forma más literal: el gate
/// existía a cuarenta líneas de distancia y le faltó al hermano.
@Suite("El cambio de dispositivo llega hasta el coordinador")
struct DeviceChangeWiringTests {

    @Test("una notificación real de AVFoundation llega a onDeviceChange", .enabled(
        if: ProcessInfo.processInfo.environment["AMBAR_SKIP_SPEECH_TESTS"] == nil,
        "necesita el modelo de voz instalado; el runner de CI no lo trae"
    ))
    func realConfigurationChangeReachesTheHandler() async throws {
        let session = SpeechSession(locale: SpeechEngineTests.locale, mode: .live)
        let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true)!
        let microphone = MicrophoneSource(target: format)
        await session.setSourceForTesting(microphone)

        let notified = DeviceChangeNotice()
        await session.setDeviceChangeHandler { Task { await notified.record() } }

        try await session.prepare()
        _ = try await session.start()

        // La notificación real de AVFoundation, no una simulación del closure: es
        // exactamente lo que `input.installTap`/`AVAudioEngineConfigurationChange`
        // dispararía al cambiar de dispositivo. Se dispara DESDE la sesión —no llamando
        // al `microphone` local otra vez— porque una vez enviado al actor, volver a
        // tocarlo desde este lado es la misma carrera de datos que Swift 6 rechaza.
        await session.postConfigurationChangeForTesting()

        // Se **espera al hecho**, no un plazo fijo. Con los 200 ms que había, este test
        // fallaba de forma intermitente —medido: uno de cada tres intentos, sin tocar una
        // línea— porque la notificación de AVFoundation llega cuando llega, y con la máquina
        // cargada llega más tarde. Es el mismo anti-patrón que este repositorio ya cazó en el
        // test de arranque («apostaba a que la máquina fuera rápida»), cometido aquí.
        //
        // El techo sigue existiendo para que un cableado roto falle en dos segundos en vez de
        // colgar la suite.
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while ContinuousClock.now < deadline, await notified.count == 0 {
            try? await Task.sleep(for: .milliseconds(20))
        }
        #expect(await notified.count == 1, "el cambio de dispositivo no llegó al coordinador")

        await session.cancel()
    }

    actor DeviceChangeNotice {
        private(set) var count = 0
        func record() { count += 1 }
    }
}

/// La segunda cola del camino de audio pregunta su política a la fuente.
///
/// Hay **dos** colas en serie: la de la fuente y la que `SpeechSession.start()` interpone
/// para poder añadir el silencio de cierre. Si la segunda se acota cuando la fuente pide
/// no acotar, se pierde audio **en silencio** — medido con un fichero de 90 s: 34
/// caracteres transcritos de 1442.
///
/// Existía un test llamado «cada fuente declara su propia política, y la sesión se la
/// pregunta» que solo comprobaba la primera mitad del nombre: afirmaba sobre
/// `FileSource.bufferingPolicy` y `MicrophoneSource.bufferingPolicy`, y nunca tocaba
/// `SpeechSession`. Una auditoría independiente lo midió: sustituir `source.bufferingPolicy`
/// por `.unbounded` en `start()` sobrevivía **incluso con el motor real corriendo**, porque
/// nadie observaba si se preguntaba.
///
/// La comprobación es sencilla en cuanto se plantea bien: no se mide el valor —que no es
/// observable desde fuera de la cola— sino **si se pidió**. Una fuente que cuenta las
/// lecturas de su propia política responde exactamente a eso.
///
/// Vive detrás del gate del motor porque la cola solo se construye dentro de `start()`, y
/// `start()` exige el analizador real. Es un hueco de CI declarado, no silencioso.
@Suite("La sesión pregunta la política de cola a su fuente")
struct SessionAsksItsSourceForThePolicyTests {

    /// Cuenta cuántas veces le preguntan la política. No produce audio: una secuencia
    /// vacía basta para que el analizador termine sin nada que transcribir.
    final class PolicySpySource: AudioSource, @unchecked Sendable {
        private let lock = NSLock()
        private var reads = 0
        var policyReadCount: Int { lock.withLock { reads } }

        var sequenceEnd: CMTime? { nil }
        func start() throws -> AsyncStream<AnalyzerInput> { AsyncStream { $0.finish() } }
        func stop() {}
        var bufferingPolicy: AsyncStream<AnalyzerInput>.Continuation.BufferingPolicy {
            lock.withLock { reads += 1 }
            // `.unbounded` es lo que pide una fuente de fichero: preservar el audio íntegro
            // aunque el productor tenga que esperar.
            return .unbounded
        }
    }

    @Test("start() lee la política de la fuente en vez de decidirla por su cuenta", .enabled(
        if: ProcessInfo.processInfo.environment["AMBAR_SKIP_SPEECH_TESTS"] == nil,
        "necesita el modelo de voz instalado; el runner de CI no lo trae"
    ))
    func startAsksTheSourceForItsPolicy() async throws {
        try await SystemInventoryLock.shared.exclusive {
            let session = SpeechSession(
                locale: SpeechEngineTests.locale,
                mode: .live,
                source: .file(URL(fileURLWithPath: "/dev/null"))
            )
            let spy = PolicySpySource()
            await session.setSourceForTesting(spy)
            try await session.prepare()

            let stream = try await session.start()
            let drain = Task { for await _ in stream {} }
            _ = try await session.finish()
            _ = await drain.value

            #expect(
                spy.policyReadCount >= 1,
                "la sesión construyó su cola sin preguntar a la fuente: puede acotar lo que la fuente pidió no acotar"
            )
        }
    }
}
