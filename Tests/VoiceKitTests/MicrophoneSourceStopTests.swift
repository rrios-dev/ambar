import AVFoundation
import Speech
import Testing

@testable import VoiceKit

/// `MicrophoneSource.stop()` de verdad para el motor y suelta el observador.
///
/// Hallazgo de la auditoría independiente: el comentario de `stop()` describe dos
/// fallos concretos que ya ocurrieron —«el motor sigue corriendo» y «el tap... se
/// quedaba instalado para siempre»— y ninguno de los dos tenía un test. La retirada del
/// tap no se prueba aparte: `AVAudioNode` no expone ninguna forma segura de preguntar
/// «¿hay un tap instalado?», y provocar el fallo de verdad —instalar dos veces sobre el
/// mismo bus— es una excepción de Objective-C que Swift no puede capturar: haría
/// abortar el proceso entero de test, no solo este test. Queda como hueco declarado, no
/// silencioso.
@Suite("MicrophoneSource.stop() libera de verdad lo que abrió")
struct MicrophoneSourceStopTests {

    static func makeFormat() -> AVAudioFormat {
        AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true)!
    }

    @Test("stop() para el AVAudioEngine")
    func stopStopsTheEngine() throws {
        let source = MicrophoneSource(target: Self.makeFormat())
        _ = try source.start()
        #expect(source.isEngineRunningForTesting, "caso mal montado: no llegó a arrancar")

        source.stop()

        #expect(!source.isEngineRunningForTesting, "el motor de audio sigue corriendo tras stop()")
    }

    /// Contador con cerrojo: `onConfigurationChange` es `@Sendable` y la notificación
    /// puede llegar de un hilo indeterminado, así que una `var` capturada sin más no
    /// compila en Swift 6 estricto.
    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func increment() { lock.withLock { value += 1 } }
        var current: Int { lock.withLock { value } }
    }

    @Test("stop() suelta el observador de cambio de configuración")
    func stopRemovesTheConfigurationObserver() throws {
        let source = MicrophoneSource(target: Self.makeFormat())
        let notified = Counter()
        source.onConfigurationChange = { notified.increment() }
        _ = try source.start()

        source.postConfigurationChangeForTesting()
        // Se afirma sobre la **diferencia**, no sobre números absolutos.
        //
        // `AVAudioEngineConfigurationChange` es una notificación de `NotificationCenter.default`,
        // o sea global al proceso, y la suite corre en paralelo: otro test que la postee —hay
        // uno en `SpeechEngineTests`— incrementa este contador y hacía fallar este test con
        // «(notified.current → 2) == 1» sin que nada estuviera roto. Medido al volver
        // determinista la espera del otro test, que amplió la ventana de solape.
        //
        // Lo que este test quiere afirmar no es cuántas llegaron, sino que **tras `stop()` no
        // llega ninguna más**, y eso se mide comparando antes y después.
        let recibidas = notified.current
        #expect(recibidas >= 1, "caso mal montado: el observador no llegó a engancharse")

        source.stop()
        let antesDelSegundoAviso = notified.current
        source.postConfigurationChangeForTesting()

        #expect(
            notified.current == antesDelSegundoAviso,
            "el observador seguía enganchado tras stop(): sigue en NotificationCenter"
        )
    }
}
