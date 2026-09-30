import Accessibility
import ClipboardKit
import Foundation

/// Con cuánta prisa se locuta un anuncio de VoiceOver.
///
/// Se nombra por lo que significa en el producto y no por la constante del sistema,
/// para que la decisión —qué no se puede perder— quede en un solo sitio.
enum AnnouncementUrgency: Equatable, Sendable {
    /// No se puede perder: el micrófono se ha abierto, o algo falló.
    case critical
    /// Informativo: si algo más importante llega encima, que pase por delante.
    case background
    case normal

    var priority: AttributeScopes.AccessibilityAttributes.AnnouncementPriorityAttribute.AnnouncementPriority {
        switch self {
        case .critical: .high
        case .background: .low
        case .normal: .default
        }
    }
}

/// Qué muestra el icono de la barra de menús.
///
/// Ámbar es un agente sin icono en el Dock: con el panel cerrado, esto es la única
/// presencia de la app y lo único que puede contestar dos preguntas que el usuario
/// tiene derecho a resolver de un vistazo — «¿me está escuchando?» y «¿está
/// guardando lo que copio?».
///
/// Es un tipo puro, y no una rama dentro del delegado, por dos razones que dieron la
/// cara:
///
/// - **El orden de prioridad hay que poder afirmarlo.** Escuchar manda sobre la
///   pausa; si no, pausar la captura mientras el micrófono está abierto **apagaba el
///   indicador del micrófono** dejando el micrófono abierto. Es el peor fallo posible
///   en esta superficie: la app deja de declarar que escucha mientras escucha.
/// - **El estado se deriva del reloj.** La pausa se guarda como fecha de
///   vencimiento, así que «pausado» caduca sin que nadie emita un evento. Con la
///   decisión metida en el delegado, no había forma de comprobar que a los quince
///   minutos el icono vuelve a decir la verdad.
struct MenuBarPresence: Equatable {
    /// Qué se pinta en la barra.
    ///
    /// No siempre es un símbolo del sistema: en reposo se pinta **la marca**,
    /// que es la que dice de quién es ese icono entre los otros doce. Los
    /// estados sí son del sistema, y deben serlo: un micrófono abierto y una
    /// pausa son conceptos que macOS ya dibuja, y reinventarlos obligaría a
    /// quien mira la barra a aprender dos símbolos nuevos para entender algo
    /// que ya sabe leer.
    enum Glyph: Equatable {
        /// La gota de Ámbar, dibujada en `MenuBarGlyph`.
        case mark
        /// Un símbolo SF, por su nombre.
        case system(String)
    }

    let glyph: Glyph
    /// Descripción para accesibilidad, ya resuelta.
    ///
    /// Se resuelve aquí y no en el delegado porque `String(localized:)` exige una clave
    /// literal: pasar una variable no compila, y el intento de hacerlo es lo que
    /// destapó que la cadena tenía que vivir junto al símbolo que describe.
    let description: String

    /// En reposo, la marca. Era `doc.on.clipboard`: un símbolo correcto y de
    /// nadie — el mismo que usan media docena de apps de portapapeles, y el
    /// único sitio donde Ámbar está presente todo el día.
    static let idle = MenuBarPresence(glyph: .mark, description: "Ámbar")
    static var listening: MenuBarPresence {
        MenuBarPresence(
            glyph: .system("mic.fill"),
            description: String(localized: "dictation.status.listening", bundle: .localized)
        )
    }
    static var paused: MenuBarPresence {
        MenuBarPresence(
            glyph: .system("pause.circle"),
            description: String(localized: "panel.pause.indefinite", bundle: .localized)
        )
    }

    /// Lo que hay que hacer con el icono ahora mismo.
    ///
    /// Existe porque `AppDelegate` es la última capa del proyecto sin tests, y las
    /// mutaciones que sobrevivían allí no eran cosméticas: ignorar `isDictating` **apaga el
    /// indicador del micrófono con el micrófono abierto** —el peor fallo posible en la única
    /// presencia permanente de la app— y saltarse la limpieza de la pausa vencida deja el
    /// icono afirmando una protección que ya expiró.
    ///
    /// Con la decisión como valor, esas dos cosas se afirman sin AppKit.
    struct Update: Equatable {
        let presence: MenuBarPresence
        /// `false` cuando lo que hay que pintar no ha cambiado: repintar en cada tic de la
        /// cuenta del gesto son 25 `NSImage` por segundo en el hilo principal, justo en la
        /// ventana donde el producto se define por la latencia.
        let needsRedraw: Bool
    }

    static func update(
        isDictating: Bool,
        pause: HistoryPause?,
        shown: MenuBarPresence?,
        now: Date = Date()
    ) -> Update {
        let presence = resolve(isDictating: isDictating, pause: pause, now: now)
        return Update(presence: presence, needsRedraw: presence != shown)
    }

    /// Resuelve el estado a partir de las dos fuentes de verdad y del reloj.
    static func resolve(
        isDictating: Bool,
        pause: HistoryPause?,
        now: Date = Date()
    ) -> MenuBarPresence {
        if isDictating { return .listening }
        if let pause, pause.isActive(at: now) { return .paused }
        return .idle
    }

    /// Cuándo hay que volver a mirar, si la pausa vence sola.
    ///
    /// `nil` cuando no hay nada que esperar: sin pausa, con pausa indefinida —que solo
    /// termina si alguien la termina— o ya vencida. Devolverlo aquí, y no calcularlo en
    /// el delegado, es lo que permite comprobar que una pausa temporal programa su
    /// propio despertar y una indefinida no deja un temporizador vivo para siempre.
    static func refreshDelay(pause: HistoryPause?, now: Date = Date()) -> TimeInterval? {
        guard let remaining = pause?.remaining(at: now), remaining > 0 else { return nil }
        // Un segundo de margen: despertar en el instante exacto del vencimiento deja
        // la comparación `now < until` del lado equivocado la mitad de las veces.
        return remaining + 1
    }
}
