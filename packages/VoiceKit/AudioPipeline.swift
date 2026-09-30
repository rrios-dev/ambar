import AVFoundation
import CoreMedia
import Foundation
import Speech

/// Convierte los buffers de una fuente al formato que exige el motor.
///
/// No es un paso opcional. El transcriptor solo admite **16 kHz mono Int16** (o
/// 8 kHz), mientras que un micrófono entrega típicamente 44,1 o 48 kHz en Float32
/// y `AVAudioFile.processingFormat` es Float32 aunque el fichero sea Int16.
/// Alimentar al analizador con el formato equivocado no da un error legible:
/// **aborta el proceso**. Se descubrió así, con un SIGTRAP sin mensaje.
///
/// La conversión ocurre en el lado del productor, antes de encolar, y lo que
/// viaja por la cola es `AnalyzerInput` —que Apple declara `Sendable`— en lugar
/// de un `AVAudioPCMBuffer` desnudo, que no lo es.
struct AudioFormatConverter {
    private let converter: AVAudioConverter
    private let source: AVAudioFormat
    private let target: AVAudioFormat

    init?(from source: AVAudioFormat, to target: AVAudioFormat) {
        guard let converter = AVAudioConverter(from: source, to: target) else { return nil }
        self.converter = converter
        self.source = source
        self.target = target
    }

    /// Convierte un buffer. Devuelve `nil` si no sale nada aprovechable.
    func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard buffer.frameLength > 0 else { return nil }

        let ratio = target.sampleRate / source.sampleRate
        // El margen extra absorbe el redondeo del remuestreo: quedarse corto
        // trunca audio, y pasarse solo cuesta unos kilobytes efímeros.
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else {
            return nil
        }

        var error: NSError?
        // `convert(to:error:withInputFrom:)` invoca este bloque de forma
        // **sincrónica**, en este mismo hilo, antes de retornar. El comprobador de
        // aislamiento no puede saberlo y lo trata como código concurrente, así que
        // la garantía se declara aquí en lugar de marcar un tipo entero como
        // `@unchecked Sendable`, que sería una promesa mucho más amplia.
        nonisolated(unsafe) var consumed = false
        nonisolated(unsafe) let input = buffer
        converter.convert(to: output, error: &error) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return input
        }

        guard error == nil, output.frameLength > 0 else { return nil }
        return output
    }

    /// Buffer de silencio en el formato del motor.
    ///
    /// Se usa como cola al terminar de hablar: **sin silencio final el motor no
    /// cierra la última palabra**. Medido con voz sintética: sin cola, «…con
    /// Ámbar» se queda en «…con A»; con 0,6 s aparece completo. Es la diferencia
    /// entre un dictado usable y uno que se come el final de cada frase.
    static func silence(in format: AVAudioFormat, seconds: Double) -> AVAudioPCMBuffer? {
        let frames = AVAudioFrameCount(format.sampleRate * seconds)
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else {
            return nil
        }
        buffer.frameLength = frames

        // Los buffers recién creados no están garantizados a cero.
        if let channels = buffer.int16ChannelData {
            for channel in 0..<Int(format.channelCount) {
                for frame in 0..<Int(frames) { channels[channel][frame] = 0 }
            }
        } else if let channels = buffer.floatChannelData {
            for channel in 0..<Int(format.channelCount) {
                for frame in 0..<Int(frames) { channels[channel][frame] = 0 }
            }
        }
        return buffer
    }
}

/// De dónde sale el audio.
///
/// Existe como protocolo porque hay **dos** fuentes de producción: el micrófono, que es
/// la del dictado, y el fichero, que es la de la **sonda de capacidad** —transcribe una
/// frase sintetizada para medir si esta máquina puede seguir al habla— y la que permite
/// probar el motor sin micrófono.
///
/// Lo que **no** es: el carril del historial. Este comentario afirmó durante tres rondas
/// que el fichero era «la fuente cuando lo que se transcribe es un audio que ya pasó por
/// el portapapeles», y `ClipboardKit` no ingiere audio en ningún sitio. La corrección
/// aterrizó en `FileSource` y sobrevivió intacta aquí, en el protocolo que lo declara.
///
/// **No es `Sendable`, y es deliberado.** Ninguna clase de AVFAudio está anotada
/// como `Sendable` en el SDK 26 (comprobado en sus cabeceras), así que dejarlas
/// cruzar fronteras de aislamiento exigiría un `@unchecked Sendable` nuestro —
/// es decir, una promesa sin comprobar. En su lugar la fuente queda **confinada
/// al actor que la posee** y lo único que sale de ahí es `AnalyzerInput`, que
/// Apple ya declara `Sendable`.
///
/// El formato objetivo se fija en el `init`, en el mismo dominio donde se crea la
/// fuente, para que ningún `AVAudioFormat` tenga que viajar después.
protocol AudioSource {
    /// Empieza a producir audio ya convertido al formato del motor.
    func start() throws -> AsyncStream<AnalyzerInput>

    /// Dónde acaba, en la base de tiempo del motor, lo entregado hasta ahora.
    ///
    /// Lo necesita la cola de silencio final: si se le da tiempo 0 —o ninguno— el motor
    /// la coloca al principio en lugar de al final, y el silencio que existe para cerrar
    /// la última palabra pasa a competir con la primera.
    var sequenceEnd: CMTime? { get }

    func stop()

    /// La política de descarte de **esta** fuente.
    ///
    /// Vive en la fuente y no en quien la consume porque hay dos colas en serie —la que
    /// crea la fuente y la que interpone la sesión— y la decisión tiene que ser una sola.
    /// Mientras cada una la calculaba por su cuenta, acotar cualquiera de las dos perdía
    /// audio en silencio y el CI seguía en verde.
    var bufferingPolicy: AsyncStream<AnalyzerInput>.Continuation.BufferingPolicy { get }
}

/// Cuánta latencia de audio se admite antes de empezar a tirar buffers.
///
/// La cola entre el hilo de audio y el analizador es **acotada**: si el análisis
/// se retrasa, se descartan los buffers más antiguos en lugar de acumular sin
/// techo. La alternativa —una cola infinita— convierte un retraso pasajero en
/// consumo de memoria creciente y en un texto que llega cada vez más tarde,
/// que es peor que perder un fragmento y seguir en tiempo real.
///
/// Se descarta lo **más antiguo** y no lo más nuevo porque en dictado lo que
/// importa es seguir el habla actual.
enum AudioQueue {
    /// Segundos de audio que caben en la cola.
    static let bufferedSeconds: Double = 2.0

    /// Marcos que trae un buffer una vez convertido al formato del motor.
    ///
    /// El tap entrega 4096 marcos al ritmo del micrófono (44,1 o 48 kHz); tras
    /// remuestrear a 16 kHz quedan ~1365. Contar la capacidad con los 4096 de
    /// origen y el ritmo de destino mezcla dos dominios y da un margen tres veces
    /// menor que el declarado.
    static func convertedChunkFrames(
        targetSampleRate: Double,
        tapFrames: AVAudioFrameCount = 4096,
        typicalSourceRate: Double = 48000
    ) -> AVAudioFrameCount {
        guard typicalSourceRate > 0, targetSampleRate > 0 else { return tapFrames }
        let ratio = targetSampleRate / typicalSourceRate
        return max(1, AVAudioFrameCount(Double(tapFrames) * ratio))
    }

    /// La política de descarte de **la cola de la fuente**.
    ///
    /// Hay **dos** colas en serie en el camino de audio: la que crea la fuente y la que
    /// interpone la sesión. La ronda 7 movió la garantía a la de la sesión y dejó esta sin
    /// nada que la protegiera: acotar la cola de `FileSource` a cuatro buffers dejaba el CI
    /// en verde y la transcripción de un audio largo caía de 68 caracteres a 8. Es el
    /// bloqueante 3 de la ronda 1, reintroducible con una línea.
    ///
    /// Y ya no es hipotético que el carril del fichero sea producción: `CapabilityProbe`
    /// transcribe por ahí, y esa sonda la dispara un botón de Ajustes.
    static func sourcePolicy(
        for kind: SpeechSession.SourceKind,
        targetSampleRate: Double
    ) -> AsyncStream<AnalyzerInput>.Continuation.BufferingPolicy {
        switch kind {
        case .microphone:
            // El micrófono no espera a nadie: si el análisis se retrasa hay que preservar
            // el tiempo real y tirar lo más antiguo.
            .bufferingNewest(
                capacity(
                    chunkFrames: convertedChunkFrames(targetSampleRate: targetSampleRate),
                    sampleRate: targetSampleRate
                )
            )
        case .file:
            // Un fichero no tiene ritmo propio: lo que hay que preservar es el audio
            // íntegro, y el productor puede esperar. Acotar aquí mutila la transcripción
            // **en silencio**.
            .unbounded
        }
    }

    /// Número de buffers para un tamaño de chunk dado.
    static func capacity(chunkFrames: AVAudioFrameCount, sampleRate: Double) -> Int {
        guard chunkFrames > 0, sampleRate > 0 else { return 8 }
        let perSecond = sampleRate / Double(chunkFrames)
        return max(4, Int((perSecond * bufferedSeconds).rounded()))
    }
}
