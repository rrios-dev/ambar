import AVFoundation
import CoreMedia
import Foundation
import Speech

/// Convierte un bloque del tap y lo **sella** con su posición en la secuencia.
///
/// Existe como pieza propia porque el sellado no tenía red: quitar el `bufferStartTime` del
/// tap dejaba los 324 tests en verde, incluso con el motor real. Y es el hallazgo que evita
/// que un descarte de la cola produzca un **empalme** de dos trozos de habla en lugar de un
/// hueco — o sea, frases plausibles que nadie dijo, y solo cuando la máquina va cargada.
///
/// Se puede ejercitar sin micrófono y sin modelo: solo necesita dos formatos.
final class StampedConverter {
    private let converter: AudioFormatConverter
    private let clock: SequenceClock

    init?(from source: AVAudioFormat, to target: AVAudioFormat) {
        guard let converter = AudioFormatConverter(from: source, to: target) else { return nil }
        self.converter = converter
        self.clock = SequenceClock(sampleRate: target.sampleRate)
    }

    /// Bloque convertido y sellado, o `nil` si la conversión falla.
    func input(from buffer: AVAudioPCMBuffer) -> AnalyzerInput? {
        guard let converted = converter.convert(buffer) else { return nil }
        return AnalyzerInput(
            buffer: converted,
            bufferStartTime: clock.stamp(frames: converted.frameLength)
        )
    }

    /// Dónde acaba lo entregado. Lo usa la cola de silencio final.
    var sequenceEnd: CMTime { clock.end }
}

/// Reloj de la secuencia que se le entrega al analizador.
///
/// Cuenta los marcos **ya convertidos** y produce la marca de tiempo de cada bloque en la
/// base de tiempo del motor. Existe por un fallo de razonamiento, no por completitud:
/// la cola del micrófono **descarta lo más antiguo** cuando el analizador se retrasa, y
/// sin marca de tiempo el motor trata la secuencia como contigua. Es decir, un descarte
/// no producía un hueco: producía un **empalme** de dos trozos de habla distintos, y de
/// ahí salen transcripciones plausibles y falsas justo cuando la máquina va cargada.
///
/// O se ponen las marcas o no se descarta. Hacer las dos cosas era fabricar frases que
/// nadie dijo.
final class SequenceClock: @unchecked Sendable {
    private let sampleRate: Double
    private let lock = NSLock()
    private var emittedFrames: Int64 = 0

    init(sampleRate: Double) {
        self.sampleRate = sampleRate
    }

    /// Marca de inicio del siguiente bloque, y avanza el reloj.
    ///
    /// Con cerrojo, y el comentario anterior decía justo lo contrario —«solo lo toca el hilo
    /// de audio, serialmente»—. Es falso: `sequenceEnd` lo lee el actor de la sesión al
    /// sellar el silencio final, así que hay una escritura en el hilo de tiempo real y una
    /// lectura desde otro dominio. El compilador no lo puede ver porque
    /// `AVAudioNodeTapBlock` es un bloque Obj-C **sin `@Sendable`**, y esa es exactamente la
    /// frontera que el diseño dice que hay que declarar a mano.
    ///
    /// El cerrojo es un `NSLock` sin contención real —una escritura cada 85 ms, una lectura
    /// por dictado—, así que no toca el presupuesto del hilo de audio de forma medible.
    func stamp(frames: AVAudioFrameCount) -> CMTime {
        lock.withLock {
            let start = CMTime(value: emittedFrames, timescale: CMTimeScale(sampleRate))
            emittedFrames += Int64(frames)
            return start
        }
    }

    /// Dónde acaba lo entregado hasta ahora. Lo usa la cola de silencio final.
    var end: CMTime {
        lock.withLock { CMTime(value: emittedFrames, timescale: CMTimeScale(sampleRate)) }
    }
}

/// El micrófono.
///
/// Confinada al actor de la sesión (ver `AudioSource`): el motor de audio, el
/// formato y el convertidor no salen de aquí. Lo único que cruza la frontera son
/// los `AnalyzerInput` que salen por la cola.
final class MicrophoneSource: AudioSource {
    /// Acotada: el micrófono no espera a nadie y lo que hay que preservar es el tiempo real.
    var bufferingPolicy: AsyncStream<AnalyzerInput>.Continuation.BufferingPolicy {
        AudioQueue.sourcePolicy(for: .microphone, targetSampleRate: target.sampleRate)
    }

    private let engine = AVAudioEngine()
    private let target: AVAudioFormat
    private var continuation: AsyncStream<AnalyzerInput>.Continuation?
    private var configurationObserver: NSObjectProtocol?
    /// Conversión + sellado. Lo escribe el hilo de audio y `sequenceEnd` lo lee el actor,
    /// así que su estado está protegido por un cerrojo: ver `SequenceClock`.
    private var stamped: StampedConverter?

    /// Se llama si el dispositivo de entrada cambia a mitad de sesión.
    ///
    /// Unos auriculares que se conectan invalidan el formato negociado, y
    /// AVFoundation además detiene el motor y exige reinstalar el tap. Sin
    /// observarlo, la sesión se quedaba en «escuchando» sin recibir nada, con el
    /// panel diciendo que escucha, hasta que el usuario soltara.
    var onConfigurationChange: (@Sendable () -> Void)?

    /// Tamaño del bloque que se pide al sistema. 4096 marcos a 48 kHz son unos
    /// 85 ms: suficientemente pequeño para que el texto en vivo no vaya a
    /// tirones, suficientemente grande para no despertar el hilo de audio a lo
    /// tonto.
    private static let chunkFrames: AVAudioFrameCount = 4096

    init(target: AVAudioFormat) {
        self.target = target
    }

    func start() throws -> AsyncStream<AnalyzerInput> {
        let input = engine.inputNode
        // El formato del nodo se lee DESPUÉS de que el sistema lo haya resuelto.
        // Es típicamente 44,1 o 48 kHz en Float32, nunca lo que el motor admite.
        let sourceFormat = input.outputFormat(forBus: 0)

        guard sourceFormat.sampleRate > 0 else {
            throw DictationEngineError.noInputDevice
        }
        // Convierte **y sella**, en una sola pieza que se puede probar sin micrófono. El
        // sellado tiene que ocurrir aquí, junto al tap, porque tiene que pasar **antes** de
        // que la cola pueda descartar: sellar más adelante daría marcas contiguas a bloques
        // que ya no lo son, que es justo el fallo que esto arregla.
        guard let stamped = StampedConverter(from: sourceFormat, to: target) else {
            throw DictationEngineError.incompatibleAudioFormat
        }
        self.stamped = stamped

        // La política sale de `AudioQueue.sourcePolicy`, no se escribe aquí: es lo que
        // permite afirmarla sin motor y lo que impide que alguien acote el carril
        // equivocado —el fallo que perdía el 97 % de un audio largo en silencio.
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream(
            bufferingPolicy: bufferingPolicy
        )
        self.continuation = continuation

        // El bloque del tap corre en el hilo de audio en tiempo real, así que
        // conviene ser exacto sobre lo que hace, y no solo sobre lo que no hace:
        //
        // - Convierte, y **eso asigna** un `AVAudioPCMBuffer` de salida por
        //   callback. No es gratis y no se puede fingir que lo es. Es lo que hace
        //   el patrón de Apple para alimentar a `SpeechAnalyzer`, y evitarlo
        //   exigiría un anillo de buffers reutilizados cuya vida no controlamos
        //   —los consume el analizador de forma asíncrona—, así que reciclarlos a
        //   ciegas cambiaría una asignación por una corrupción de datos.
        // - Encola con `yield`, que toma un cerrojo corto.
        //
        // Lo que NO ocurre aquí, y es lo que de verdad importa: nada de E/S, nada
        // de esperas, nada de análisis, nada de interfaz. Todo eso vive al otro
        // lado de la cola.
        input.installTap(onBus: 0, bufferSize: Self.chunkFrames, format: sourceFormat) { buffer, _ in
            guard let input = stamped.input(from: buffer) else { return }
            continuation.yield(input)
        }

        // La notificación llega en un hilo indeterminado; solo se reenvía el aviso,
        // sin tocar nada del motor desde aquí.
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { [onConfigurationChange] _ in
            onConfigurationChange?()
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            continuation.finish()
            throw DictationEngineError.audioEngineFailed
        }
        return stream
    }

    /// Dónde acaba lo entregado. Lo consulta la sesión para sellar el silencio final.
    var sequenceEnd: CMTime? { stamped?.sequenceEnd }

    /// Solo para tests: si `AVAudioEngine` sigue corriendo. Sin esto no había forma de
    /// observar desde fuera si `stop()` de verdad lo paraba.
    var isEngineRunningForTesting: Bool { engine.isRunning }

    /// Solo para tests: dispara la notificación de cambio de configuración como haría
    /// AVFoundation, para comprobar si el observador sigue enganchado tras `stop()`.
    func postConfigurationChangeForTesting() {
        NotificationCenter.default.post(name: .AVAudioEngineConfigurationChange, object: engine)
    }

    func stop() {
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
            self.configurationObserver = nil
        }
        // El tap se retira SIEMPRE, no solo si el motor sigue corriendo: tras una
        // parada por cambio de configuración o por fallo, el motor no está
        // corriendo y el tap —con el convertidor y la continuation que captura—
        // se quedaba instalado para siempre.
        engine.inputNode.removeTap(onBus: 0)
        if engine.isRunning { engine.stop() }
        continuation?.finish()
        continuation = nil
    }
}

/// Un fichero de audio.
///
/// **Hoy es solo la fuente de prueba del motor**, y es la única forma de tener tests
/// reales de transcripción sin un micrófono delante.
///
/// El comentario anterior la describía como producción —«la fuente cuando lo que se
/// transcribe es un audio que llegó al historial»— y ese carril no existe: `ClipboardKit`
/// no ingiere audio en ningún sitio. Había además una fábrica pública
/// (`makeFileSession`) sin un solo llamador, ni en producción ni en tests, que sostenía
/// esa ficción; se ha retirado. Los tests construyen la sesión directamente, que es lo
/// que hacían ya.
///
/// Transcribir un audio del historial sigue siendo la extensión natural, y cuando se
/// cablee esta es la pieza. Pero mientras no se cablee, se dice así.
final class FileSource: AudioSource {
    /// Sin acotar: un fichero no tiene ritmo propio y lo que hay que preservar es el audio
    /// íntegro. Descartar aquí mutila la transcripción en silencio.
    var bufferingPolicy: AsyncStream<AnalyzerInput>.Continuation.BufferingPolicy {
        AudioQueue.sourcePolicy(for: .file(url), targetSampleRate: target.sampleRate)
    }

    private let url: URL
    private let target: AVAudioFormat
    private var continuation: AsyncStream<AnalyzerInput>.Continuation?
    private var stamped: StampedConverter?

    private static let chunkFrames: AVAudioFrameCount = 4096

    /// Techo de duración de un audio a transcribir.
    ///
    /// No es una restricción del motor: es lo que mantiene acotada la memoria,
    /// porque el fichero se lee entero a la cola (ver `start()`). Diez minutos a
    /// 16 kHz mono Int16 son unos 19 MB. Sigue el mismo criterio que
    /// `CaptureLimits` en el historial: generoso para el uso real, suficiente para
    /// atajar el accidente.
    static let maximumDurationSeconds: Double = 600

    init(url: URL, target: AVAudioFormat) {
        self.url = url
        self.target = target
    }

    func start() throws -> AsyncStream<AnalyzerInput> {
        let file = try AVAudioFile(forReading: url)
        // `processingFormat` es Float32 aunque el fichero esté en Int16: la
        // conversión hace falta igual que con el micrófono.
        let sourceFormat = file.processingFormat
        guard sourceFormat.sampleRate > 0 else {
            throw DictationEngineError.incompatibleAudioFormat
        }
        let duration = Double(file.length) / sourceFormat.sampleRate
        guard duration <= Self.maximumDurationSeconds else {
            throw DictationEngineError.audioTooLong
        }
        guard let stamped = StampedConverter(from: sourceFormat, to: target) else {
            throw DictationEngineError.incompatibleAudioFormat
        }
        self.stamped = stamped

        // Sin acotar, al contrario que con el micrófono, y la decisión vive en
        // `AudioQueue.sourcePolicy` para que sea afirmable: un fichero no tiene ritmo propio
        // y descartar lo más antiguo mutilaría la transcripción en silencio.
        //
        // El techo de duración de arriba es lo que mantiene esto acotado en memoria: 10
        // minutos a 16 kHz mono Int16 son unos 19 MB.
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream(
            bufferingPolicy: bufferingPolicy
        )
        self.continuation = continuation

        // Lectura síncrona, deliberadamente. Meterla en una `Task` obliga a
        // capturar el `AVAudioFile`, que no es `Sendable`, y el comprobador de
        // aislamiento de Swift 6 rechaza ese patrón —literalmente responde que no
        // sabe analizarlo—. Como no hay tiempo real que respetar, no hay ningún
        // motivo para salir de este contexto.
        while file.framePosition < file.length {
            guard let buffer = AVAudioPCMBuffer(
                pcmFormat: sourceFormat,
                frameCapacity: Self.chunkFrames
            ) else { break }
            do {
                try file.read(into: buffer)
            } catch {
                break
            }
            guard buffer.frameLength > 0 else { break }
            if let input = stamped.input(from: buffer) {
                continuation.yield(input)
            }
        }
        continuation.finish()
        return stream
    }

    var sequenceEnd: CMTime? { stamped?.sequenceEnd }

    func stop() {
        continuation?.finish()
        continuation = nil
    }
}

/// Fallos del motor que la capa de sesión traduce a `DictationFailure`.
public enum DictationEngineError: Error, Equatable, Sendable {
    case noInputDevice
    case incompatibleAudioFormat
    case audioEngineFailed
    case audioTooLong
    case localeUnsupported
    case modelNotInstalled
    /// El cupo de idiomas reservados del sistema está lleno.
    case reservationQuotaExceeded
    /// Se pidió el resultado de una sesión que el techo de duración ya cerró.
    case sessionClosedByLimit
}
