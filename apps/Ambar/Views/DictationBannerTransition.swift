import GlassUI
import SwiftUI

/// Cómo entra y sale la banda del dictado.
///
/// Vive aparte de la vista por dos razones. La primera es que la elección **depende de una
/// preferencia de accesibilidad**, así que tiene que poder afirmarse en un test: con
/// «Reducir movimiento» no puede haber ninguna animación, y eso no se ve leyendo el cuerpo
/// de una vista. La segunda es que la transición es una promesa del diseño (§8.4) que
/// estuvo tres rondas sin implementarse mientras el documento decía que sí: la banda
/// aparecía de golpe.
enum DictationBannerTransition {
    /// Qué transición corresponde. Un valor, no un `AnyTransition`, porque
    /// `AnyTransition` no es comparable y la decisión hay que poder afirmarla.
    enum Kind: Equatable {
        /// Sin transición ninguna.
        case none
        /// Crece desde el borde superior.
        case growFromTop
    }

    /// - Parameter reduceMotion: preferencia del sistema, inyectada para poder probarla.
    static func kind(reduceMotion: Bool) -> Kind {
        // **Nada de movimiento** con la preferencia activa. Ni un desplazamiento corto, ni
        // un desvanecido: quien pide reducir movimiento no pide «menos movimiento», pide
        // que no haya. El avance del gesto sigue estando en la escalera de puntos.
        reduceMotion ? .none : .growFromTop
    }

    static func transition(for kind: Kind) -> AnyTransition {
        switch kind {
        case .none:
            .identity
        case .growFromTop:
            // Crece desde el borde superior y se desvanece a la vez. El desvanecido solo
            // acompaña: lo que comunica «esto está pasando ahora» es el crecimiento,
            // porque ocurre en la dirección en la que el panel gana altura.
            .asymmetric(
                insertion: .move(edge: .top).combined(with: .opacity),
                removal: .opacity
            )
        }
    }

    /// La transición que corresponde al estado actual del sistema.
    @MainActor
    static var current: AnyTransition {
        transition(for: kind(reduceMotion: AccessibilityPreferences.shared.reduceMotion))
    }

    /// Duración de la transición.
    ///
    /// Deliberadamente **más corta que el umbral del gesto** (550 ms): si durara lo mismo,
    /// la animación acabaría justo cuando el micrófono se abre y no habría dado ninguna
    /// ventana para soltar. Y no se ata al umbral por construcción: el umbral es un valor
    /// propio que se ajustará observando a gente real, y la animación no puede secuestrar
    /// esa decisión.
    static let duration: Duration = .milliseconds(220)

    /// La misma duración, en segundos, para SwiftUI.
    ///
    /// Derivada y no escrita otra vez: el literal `0.22` vivía suelto en la animación, así
    /// que `duration` —con todo el razonamiento de arriba colgando de ella y un test que lo
    /// afirma— **no gobernaba nada**. Subir el literal a 0,9 dejaba el test en verde y la
    /// animación acabando después de que se abriera el micrófono. Decidido en dos sitios,
    /// como tantas otras veces en este proyecto.
    static var durationInSeconds: Double {
        Double(duration.components.seconds)
            + Double(duration.components.attoseconds) / 1e18
    }

    @MainActor
    static var animation: Animation? {
        AccessibilityPreferences.shared.animation(.easeOut(duration: durationInSeconds))
    }
}
