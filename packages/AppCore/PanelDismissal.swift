import Foundation

/// Cuándo puede el panel cerrarse al perder la condición de ventana clave.
///
/// El panel se oculta en `resignKey` porque así se comporta una ventana de
/// utilidad: pinchas fuera y desaparece. Con el dictado en marcha eso deja de ser
/// correcto, y por dos motivos distintos:
///
/// 1. **Con una sesión viva**, ocultar el panel dejaría el micrófono abierto sin
///    ninguna interfaz visible. El indicador del sistema señalaría a una app que
///    no tiene icono en el Dock (`LSUIElement`), así que el usuario no tendría
///    forma de saber quién le está escuchando ni cómo pararlo.
/// 2. **Mientras se pide el permiso de micrófono**, el diálogo de TCC roba la
///    condición de ventana clave. Si el panel se cierra en ese instante, el
///    usuario concede el permiso y se queda sin nada delante; y `previousApplication`
///    se recaptura en la siguiente apertura, así que hasta el destino del pegado
///    cambia.
///
/// Los dos casos fueron bloqueantes de la auditoría. La decisión vive en un tipo
/// propio, y no como un `if` dentro del closure de `onResignKey`, para que se
/// pueda probar sin instanciar una ventana.
public struct PanelDismissalPolicy: Sendable, Equatable {
    /// Hay una sesión de dictado que ya toca el motor (preparando, escuchando o
    /// finalizando). La cuenta del gesto **no** cuenta: ahí no hay nada abierto y
    /// cerrar el panel es una cancelación legítima.
    public var dictationSessionActive: Bool

    /// Hay una petición de permiso del sistema en vuelo.
    public var permissionPromptInFlight: Bool

    public init(dictationSessionActive: Bool = false, permissionPromptInFlight: Bool = false) {
        self.dictationSessionActive = dictationSessionActive
        self.permissionPromptInFlight = permissionPromptInFlight
    }

    /// Comportamiento por defecto: el de siempre, ocultar al perder el foco.
    public static let `default` = PanelDismissalPolicy()

    public var shouldHideOnResignKey: Bool {
        !(dictationSessionActive || permissionPromptInFlight)
    }
}
