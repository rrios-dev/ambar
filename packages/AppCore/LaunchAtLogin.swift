import Foundation
import ServiceManagement

/// Arranque automático al iniciar sesión.
///
/// `SMAppService.mainApp` es la vía moderna: no necesita un helper aparte ni
/// tocar `~/Library/LaunchAgents`, y el usuario puede revocarlo desde Ajustes
/// del Sistema como cualquier otra app.
public enum LaunchAtLogin {
    /// Lo que el sistema dice, que no es lo mismo que lo que la app crea recordar.
    public enum State: Equatable {
        /// Registrada: arrancará al iniciar sesión.
        case registered
        /// Nadie lo ha pedido nunca. Es el estado tras reinstalar o mover la app.
        case notRegistered
        /// El usuario la desactivó en Ajustes del Sistema. Aquí manda él.
        case revokedByUser
        /// El sistema no puede decidirlo — normalmente, ejecutándose desde una ruta
        /// que no considera estable.
        case unavailable
    }

    public static var state: State {
        switch SMAppService.mainApp.status {
        case .enabled: .registered
        case .notRegistered: .notRegistered
        case .requiresApproval: .revokedByUser
        case .notFound: .unavailable
        @unknown default: .unavailable
        }
    }

    public static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Vuelve a poner de acuerdo la preferencia guardada con el registro real, y
    /// devuelve el valor que la preferencia debe tener a partir de ahora.
    ///
    /// Hace falta porque la preferencia solo se aplicaba **al cambiarla**: guardada como
    /// activa, nadie la volvía a mirar. Si el registro se perdía —reinstalar la app,
    /// moverla, o que `register()` fallara el día que se marcó la casilla— quedaba la
    /// casilla puesta, la app sin arrancar sola, y nada que lo dijera.
    ///
    /// Solo se registra desde `notRegistered`, que es «nadie lo ha pedido nunca». Con
    /// `revokedByUser` la preferencia se corrige al valor real en lugar de volver a
    /// registrar por encima: quitarlo en Ajustes del Sistema es una decisión, no un
    /// desajuste que reparar.
    @discardableResult
    public static func reconcile(preference: Bool) -> Bool {
        switch decision(preference: preference, state: state) {
        case .on: return true
        case .off: return false
        case .register:
            set(true)
            return isEnabled
        }
    }

    /// Qué hacer, decidido aparte de hacerlo.
    ///
    /// Va separado porque lo que importa aquí es la tabla —sobre todo que una revocación
    /// del usuario gane a una preferencia guardada en `true`— y `SMAppService` es estado
    /// del sistema: un test que lo tocara cambiaría la máquina de quien lo corre y no
    /// podría montar los cuatro estados.
    public enum Decision: Equatable {
        /// Dejar la preferencia activa; el sistema ya la respeta.
        case on
        /// Dejar la preferencia apagada, aunque estuviera guardada como activa.
        case off
        /// Pedir el registro al sistema.
        case register
    }

    public static func decision(preference: Bool, state: State) -> Decision {
        switch state {
        // Registrada, pero puede estar apuntando a una copia anterior de la app. Se vuelve
        // a registrar para que la ruta sea la de este bundle.
        case .registered: .register
        // El usuario lo quitó fuera de la app: eso es una decisión suya, no un desajuste
        // que reparar. Volver a registrar aquí sería devolverle una casilla que él acaba
        // de apagar.
        case .revokedByUser: .off
        case .notRegistered: preference ? .register : .off
        // Sin veredicto del sistema no se toca nada: es lo normal ejecutando desde la
        // carpeta de compilación, y apagar la preferencia ahí borraría la del usuario.
        case .unavailable: preference ? .on : .off
        }
    }

    /// Devuelve `true` si el cambio se aplicó.
    ///
    /// Falla cuando la app no está firmada o se ejecuta desde una ruta que el
    /// sistema no considera estable —lo normal mientras se desarrolla—, así que
    /// la interfaz debe tratar el fallo como información, no como un error.
    @discardableResult
    public static func set(_ enabled: Bool) -> Bool {
        do {
            if enabled {
                // Se registra **aunque ya lo esté**. `register()` graba la ruta del bundle
                // que llama, y el sistema solo guarda una por identificador: si la app se
                // mueve —de Descargas a Aplicaciones, que es el primer paso de la
                // presentación, o al reemplazarla por una versión nueva— el apunte se queda
                // señalando a la copia vieja y al iniciar sesión arranca esa, o ninguna.
                // Volver a registrar es idempotente y vuelve a apuntar aquí.
                try SMAppService.mainApp.register()
            } else {
                if SMAppService.mainApp.status == .enabled {
                    try SMAppService.mainApp.unregister()
                }
            }
            return true
        } catch {
            return false
        }
    }
}
