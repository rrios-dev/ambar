import Foundation
import Testing

@testable import ClipboardKit

/// F4 — la pausa del historial.
///
/// El punto de todo esto es que la pausa **se deriva del reloj**, no de una
/// bandera. Los tests están escritos contra esa propiedad porque es la que evita
/// los dos fallos simétricos: creerse protegido cuando la pausa ya expiró, y
/// perder semanas de historial por una pausa que se quedó puesta.
@Suite("Pausa del historial")
struct HistoryPauseTests {

    static let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("una pausa de quince minutos vence sola")
    func fifteenMinutesExpires() {
        let pause = HistoryPause.starting(.fifteenMinutes, at: Self.t0)

        #expect(pause.isActive(at: Self.t0))
        #expect(pause.isActive(at: Self.t0.addingTimeInterval(14 * 60)))
        // En el instante exacto ya no está activa: el límite pertenece al lado
        // seguro, que es el de volver a capturar.
        #expect(!pause.isActive(at: Self.t0.addingTimeInterval(15 * 60)))
        #expect(!pause.isActive(at: Self.t0.addingTimeInterval(16 * 60)))
    }

    @Test("una pausa de una hora vence sola")
    func oneHourExpires() {
        let pause = HistoryPause.starting(.oneHour, at: Self.t0)
        #expect(pause.isActive(at: Self.t0.addingTimeInterval(59 * 60)))
        #expect(!pause.isActive(at: Self.t0.addingTimeInterval(60 * 60)))
    }

    @Test("la pausa indefinida no vence: hay que acordarse de volver")
    func indefinitePauseDoesNotExpire() {
        let pause = HistoryPause.starting(.untilResumed, at: Self.t0)
        #expect(pause.isIndefinite)
        #expect(pause.isActive(at: Self.t0.addingTimeInterval(365 * 24 * 3600)))
        // Y no se puede mostrar una cuenta atrás de algo que no acaba.
        #expect(pause.remaining(at: Self.t0) == nil)
    }

    @Test("el tiempo restante se puede decir en la interfaz")
    func remainingIsReportable() {
        let pause = HistoryPause.starting(.oneHour, at: Self.t0)
        let remaining = pause.remaining(at: Self.t0.addingTimeInterval(600))
        #expect(remaining != nil)
        #expect(abs((remaining ?? 0) - 3000) < 1)

        // Ya vencida: no queda nada que contar.
        #expect(pause.remaining(at: Self.t0.addingTimeInterval(7200)) == nil)
    }

    // MARK: - La protección caduca sola

    /// El invariante que justifica guardar una fecha y no un booleano.
    ///
    /// Estos casos se afirmaban contra `HistoryCaptureState`, un tipo público con siete
    /// tests y **cero llamadores** cuyo comentario decía «quien decide si un contenido se
    /// guarda es el ingestor, y esta es su condición de entrada» — y el ingestor no lo
    /// conocía. Era una segunda fuente de verdad para «¿está pausada la captura?» que se
    /// leía como cobertura de la puerta real. El tipo se ha retirado; los invariantes se
    /// quedan, afirmados sobre `HistoryPause`, que es lo que la app consulta de verdad
    /// (`ClipboardMonitor.isPausedNow` → `Settings.isPaused` → `pause.isActive()`).
    @Test("una pausa vencida deja de proteger sin que nadie la limpie")
    func expiredPauseStopsProtectingByItself() {
        // Nadie ha llamado a nada: ni «reanudar», ni un temporizador, ni un arranque de la
        // app. Simplemente ha pasado el tiempo.
        let pause = HistoryPause.starting(.fifteenMinutes, at: Self.t0)
        #expect(pause.isActive(at: Self.t0))
        #expect(!pause.isActive(at: Self.t0.addingTimeInterval(15 * 60 + 1)))
    }

    @Test("la pausa indefinida no caduca sola")
    func indefinitePauseNeverExpires() {
        let pause = HistoryPause.starting(.untilResumed, at: Self.t0)
        #expect(
            pause.isActive(at: Self.t0.addingTimeInterval(10 * 365 * 24 * 3600)),
            "una pausa indefinida no puede desaparecer sola"
        )
    }

    // MARK: - Persistencia

    @Test("la pausa sobrevive a un reinicio, y sigue venciendo cuando le toca")
    func pauseSurvivesRelaunch() throws {
        // Se guarda la fecha, no «cuánto queda»: si se guardara lo segundo, cada
        // reinicio reiniciaría la cuenta y una pausa de quince minutos podría
        // durar para siempre.
        let pause = HistoryPause.starting(.fifteenMinutes, at: Self.t0)
        let data = try JSONEncoder().encode(pause)
        let restored = try JSONDecoder().decode(HistoryPause.self, from: data)

        #expect(restored == pause)
        #expect(restored.isActive(at: Self.t0.addingTimeInterval(60)))
        #expect(!restored.isActive(at: Self.t0.addingTimeInterval(15 * 60 + 1)))
    }

    @Test("todas las duraciones ofrecidas producen una pausa coherente")
    func allDurationsAreCoherent() {
        for duration in HistoryPause.Duration.allCases {
            let pause = HistoryPause.starting(duration, at: Self.t0)
            #expect(pause.isActive(at: Self.t0), "\(duration) no protege ni al empezar")

            if let seconds = duration.seconds {
                #expect(!pause.isActive(at: Self.t0.addingTimeInterval(seconds + 1)))
            } else {
                #expect(pause.isIndefinite)
            }
        }
    }
}

/// La pausa que vence tiene que **reanudar la captura**, y ese es el camino que nadie
/// recorría: el vencimiento no emite ningún evento, así que cualquier copia del estado
/// se quedaba pausada para siempre mientras las tres superficies decían lo contrario.
@Suite("El vencimiento de la pausa reanuda la captura")
@MainActor
struct PauseExpiryResumesCaptureTests {

    /// Reloj falso para no esperar quince minutos.
    final class Clock {
        var now: Date
        init(_ now: Date) { self.now = now }
    }

    @Test("el monitor consulta la pausa en cada lectura, no una copia")
    func monitorDerivesPauseFromTheClock() {
        let clock = Clock(Date(timeIntervalSince1970: 10_000))
        let pause = HistoryPause.starting(.fifteenMinutes, at: clock.now)
        let monitor = ClipboardMonitor()
        monitor.isPausedNow = { pause.isActive(at: clock.now) }

        #expect(monitor.isPaused, "no reflejó la pausa recién puesta")

        // Pasan dieciséis minutos. Nadie emite ningún evento: es una fecha que pasa.
        clock.now = clock.now.addingTimeInterval(16 * 60)

        #expect(
            !monitor.isPaused,
            "la pausa venció y el monitor seguía descartando: se pierde todo lo copiado"
        )
    }

    @Test("asignar el booleano sigue funcionando para la pausa indefinida")
    func settingTheBooleanStillWorks() {
        // El menú de la barra y Ajustes lo asignan así; la compatibilidad no puede
        // romperse al derivar el estado.
        let monitor = ClipboardMonitor()
        monitor.isPaused = true
        #expect(monitor.isPaused)
        monitor.isPaused = false
        #expect(!monitor.isPaused)
    }
}
