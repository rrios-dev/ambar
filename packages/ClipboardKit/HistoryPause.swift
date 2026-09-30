import Foundation

/// Pausa del historial.
///
/// Es la respuesta a «ahora no quiero que quede rastro», y es deliberadamente un
/// interruptor **global** en lugar de un modo efímero por elemento: mucho más
/// fácil de entender, y no obliga a decidir antes de cada acción.
///
/// La pausa se guarda como **una fecha de vencimiento**, no como un booleano. Esa
/// elección es lo que evita los dos fallos simétricos de una pausa indefinida:
/// olvidarse de que está activa y perder semanas de historial, o creerse protegido
/// cuando ya expiró. Con una fecha, el estado se **deriva del reloj** y nadie
/// tiene que acordarse de limpiar una bandera — tampoco después de reiniciar.
public struct HistoryPause: Sendable, Equatable, Codable {
    /// Instante en el que la pausa deja de valer.
    public let until: Date

    public init(until: Date) {
        self.until = until
    }

    /// Cuánto dura una pausa.
    ///
    /// Se ofrecen duraciones concretas porque son las que resuelven el caso real
    /// —«voy a escribir algo que no quiero que quede»— y porque devuelven al
    /// estado seguro sin intervención. `untilResumed` existe para quien de verdad
    /// lo quiera indefinido, y es la única opción que exige acordarse de volver.
    public enum Duration: String, Sendable, Equatable, CaseIterable, Codable {
        case fifteenMinutes
        case oneHour
        case untilResumed

        public var seconds: TimeInterval? {
            switch self {
            case .fifteenMinutes: 15 * 60
            case .oneHour: 60 * 60
            case .untilResumed: nil
            }
        }
    }

    public static func starting(
        _ duration: Duration,
        at now: Date = Date()
    ) -> HistoryPause {
        if let seconds = duration.seconds {
            HistoryPause(until: now.addingTimeInterval(seconds))
        } else {
            HistoryPause(until: .distantFuture)
        }
    }

    public func isActive(at now: Date = Date()) -> Bool {
        now < until
    }

    /// Cuánto queda, para poder decirlo en la interfaz. `nil` si es indefinida o
    /// si ya expiró.
    public func remaining(at now: Date = Date()) -> TimeInterval? {
        guard isActive(at: now), until != .distantFuture else { return nil }
        return until.timeIntervalSince(now)
    }

    public var isIndefinite: Bool { until == .distantFuture }
}
