import AVFoundation
import Foundation

/// Mide si **esta** máquina puede seguir al habla.
///
/// Existe porque todo el eje de capacidad —`Capability`, `CapabilityThresholds`,
/// `OfferTone.warning`, la recomendación de usar el modo diferido— estaba escrito,
/// probado y **sin ningún productor**: la oferta se construía con `capability:
/// .unmeasured` fijo, así que el aviso de «esta máquina va justa» no podía ocurrir
/// jamás. Era la decisión de producto del primer día —si los requisitos no son óptimos,
/// se recomienda no activarlo— sin ninguna vía para llegar al usuario.
///
/// El método es el único honesto: se transcribe un audio conocido con el mismo motor y la
/// misma configuración que usa el dictado, y se compara el tiempo de reloj con la
/// duración del audio. No se deduce del nombre del Mac ni del número de núcleos, porque
/// lo que importa no es el hardware en abstracto: es cuánto tarda **este** modelo en
/// **esta** máquina, con lo que esté corriendo a la vez.
public struct CapabilityProbe: Sendable {

    /// Frase de referencia.
    ///
    /// Ni muy corta —el arranque en frío del modelo dominaría la medida— ni larga, porque
    /// el usuario está esperando. Con voz del sistema salen unos tres segundos.
    public static let referencePhrase =
        "Esta es una frase de referencia para medir el rendimiento del dictado en este equipo."

    public init() {}

    /// Transcribe la frase de referencia y devuelve el factor de tiempo real.
    ///
    /// - Throws: `CapabilityProbeError` si no se pudo sintetizar o transcribir. Un fallo
    ///   aquí **no** es un fallo del dictado: la medición es opcional y la ausencia de
    ///   medida se representa con `Capability.unmeasured`.
    /// - Parameter mode: **siempre el modo en vivo por omisión, y a propósito.** Lo que la
    ///   medida decide es si se puede ofrecer el modo en vivo, que pide resultados
    ///   volátiles y finalización frecuente y cuesta más: medido sobre el mismo audio,
    ///   0,163-0,186 s en vivo frente a 0,155-0,161 s en diferido, un 18 % más. Medir el
    ///   modo que el usuario tenga puesto —que por defecto es el diferido, justamente por
    ///   §6.1— daría un factor optimista para la decisión que se está tomando.
    public func measure(
        locale: Locale = .current,
        mode: DictationMode = .live,
        now: Date = Date()
    ) async throws -> CapabilityMeasurement {
        let url = try await Self.renderReferenceAudio(locale: locale)
        defer { try? FileManager.default.removeItem(at: url) }

        let audioDuration = try Self.duration(of: url)
        guard audioDuration > 0.5 else { throw CapabilityProbeError.audioTooShort }

        let session = SpeechSession(locale: locale, mode: mode, source: .file(url))
        do {
            // El cronómetro arranca **después** de `prepare()`. Antes lo incluía, y la
            // carga del modelo en frío cuesta 0,79-1,16 s medidos: sobre un umbral de 0,5
            // eso son 0,21-0,30 puntos —entre el 42 % y el 60 % del presupuesto— dedicados
            // a algo que no tiene nada que ver con seguir al habla. Lo que se mide es el
            // análisis, que es lo que el modo en vivo tiene que sostener en tiempo real.
            try await session.prepare()
            let started = ContinuousClock.now
            let fragments = try await session.start()
            // El drenaje va en su propia tarea y se espera DESPUÉS de `finish()`. Al
            // revés se bloquea: el flujo de fragmentos no termina hasta que la sesión
            // se cierra, así que esperarlo antes deja la sonda colgada hasta que salta
            // el techo de duración —medido: 128 s y un fallo con pinta de fallo del
            // motor, cuando el error estaba en el orden de dos líneas.
            let drain = Task { for await _ in fragments {} }
            _ = try await session.finish()
            await drain.value

            let elapsed = ContinuousClock.now - started
            let elapsedSeconds =
                Double(elapsed.components.seconds)
                + Double(elapsed.components.attoseconds) / 1e18

            return CapabilityMeasurement(
                realTimeFactor: elapsedSeconds / audioDuration,
                measuredAt: now,
                machineIdentifier: Self.machineIdentifier(),
                systemVersion: Self.systemVersion()
            )
        } catch {
            await session.cancel()
            throw CapabilityProbeError.transcriptionFailed
        }
    }

    // MARK: - Audio de referencia

    /// Sintetiza la frase con una voz del sistema y la escribe en un fichero temporal.
    ///
    /// Se usa `AVSpeechSynthesizer` y no `/usr/bin/say` porque lanzar un proceso desde una
    /// app firmada con Hardened Runtime es exactamente el tipo de cosa que funciona en
    /// desarrollo y falla en la copia distribuida.
    static func renderReferenceAudio(locale: Locale) async throws -> URL {
        let utterance = AVSpeechUtterance(string: referencePhrase)
        utterance.voice =
            AVSpeechSynthesisVoice(language: locale.identifier(.bcp47))
            ?? AVSpeechSynthesisVoice(language: "es-ES")

        let url = FileManager.default.temporaryDirectory
            .appending(path: "ambar-capability-\(UUID().uuidString).caf")

        let writer = AudioSampleWriter(url: url)
        let synthesizer = AVSpeechSynthesizer()

        // Pestillo de una sola reanudación. El callback del sintetizador llega en un hilo
        // indeterminado y **puede entregar más de un buffer vacío**: medido, reanudar la
        // continuación en cada uno abortaba el proceso con «CONTINUATION MISUSE».
        let latch = ResumeLatch()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            synthesizer.write(utterance) { buffer in
                guard let pcm = buffer as? AVAudioPCMBuffer else {
                    if latch.close() { continuation.resume(throwing: CapabilityProbeError.synthesisFailed) }
                    return
                }
                // Un buffer vacío es el final del renderizado, no un error.
                if pcm.frameLength == 0 {
                    writer.close()
                    if latch.close() { continuation.resume() }
                    return
                }
                writer.append(pcm)
            }
        }

        guard writer.wroteAnything else { throw CapabilityProbeError.synthesisFailed }
        return url
    }

    static func duration(of url: URL) throws -> Double {
        let file = try AVAudioFile(forReading: url)
        return Double(file.length) / file.processingFormat.sampleRate
    }

    // MARK: - Ámbito de la medida

    /// Modelo de la máquina (`hw.model`), p. ej. `Mac16,10`.
    ///
    /// La medida se guarda con él porque **no vale para otro Mac**: es la razón de que
    /// `CapabilityMeasurement` lleve máquina y versión del sistema.
    public static func machineIdentifier() -> String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        guard size > 0 else { return "unknown" }
        var value = [UInt8](repeating: 0, count: size)
        sysctlbyname("hw.model", &value, &size, nil, 0)
        // Se recorta el terminador antes de decodificar: `String(cString:)` está
        // deprecado en este SDK.
        let bytes = value.prefix { $0 != 0 }
        return String(decoding: bytes, as: UTF8.self)
    }

    public static func systemVersion() -> String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "\(version.majorVersion).\(version.minorVersion)"
    }
}

/// Pestillo que solo se cierra una vez.
///
/// `withCheckedThrowingContinuation` aborta el proceso si se reanuda dos veces, y el
/// callback del sintetizador no garantiza una sola llamada final.
final class ResumeLatch: @unchecked Sendable {
    private let lock = NSLock()
    private var closed = false

    /// `true` la primera vez, `false` en las siguientes.
    func close() -> Bool {
        lock.withLock {
            if closed { return false }
            closed = true
            return true
        }
    }
}

/// Escritor de audio para la sonda. Confinado a su propio cerrojo porque el sintetizador
/// entrega los buffers desde un hilo que no controlamos.
final class AudioSampleWriter: @unchecked Sendable {
    private let url: URL
    private let lock = NSLock()
    private var file: AVAudioFile?
    private var wrote = false

    init(url: URL) {
        self.url = url
    }

    var wroteAnything: Bool { lock.withLock { wrote } }

    func append(_ buffer: AVAudioPCMBuffer) {
        lock.withLock {
            if file == nil {
                file = try? AVAudioFile(
                    forWriting: url,
                    settings: buffer.format.settings,
                    commonFormat: buffer.format.commonFormat,
                    interleaved: buffer.format.isInterleaved
                )
            }
            try? file?.write(from: buffer)
            wrote = true
        }
    }

    func close() {
        lock.withLock { file = nil }
    }
}

public enum CapabilityProbeError: Error, Equatable, Sendable {
    case synthesisFailed
    case audioTooShort
    case transcriptionFailed
}
