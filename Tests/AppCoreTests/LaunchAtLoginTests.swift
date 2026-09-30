import Testing

@testable import AppCore

/// Que la preferencia de arranque y el registro del sistema no se separen en silencio.
///
/// La preferencia solo se aplicaba **al cambiarla**, así que guardada como activa nadie
/// la volvía a mirar. Reinstalar la app o moverla pierde el registro: quedaba la casilla
/// marcada, Ámbar sin arrancar sola, y nada que lo dijera. Ahora se reconcilia al
/// arrancar, y lo que decide esa reconciliación es esta tabla.
@Suite("Arranque al iniciar sesión")
struct LaunchAtLoginTests {

    /// Registrada no basta: el sistema guarda **una ruta** por identificador, y si la app
    /// se movió —de Descargas a Aplicaciones, o al reemplazarla por una versión nueva— el
    /// apunte sigue señalando la copia anterior. Al iniciar sesión arrancaría esa, o
    /// ninguna. Ocurrió de verdad: ejecutar la copia de compilación dejó el registro
    /// apuntando a la carpeta de build.
    @Test("registrada: se vuelve a registrar para que apunte a ESTA copia de la app")
    func registeredIsReasserted() {
        #expect(LaunchAtLogin.decision(preference: false, state: .registered) == .register)
        #expect(LaunchAtLogin.decision(preference: true, state: .registered) == .register)
    }

    /// El caso que hace falta acertar: quien lo apaga en Ajustes del Sistema no quiere
    /// que la app se lo vuelva a poner en el siguiente arranque.
    @Test("revocada por el usuario: gana él, aunque la preferencia siga guardada")
    func userRevocationWins() {
        #expect(LaunchAtLogin.decision(preference: true, state: .revokedByUser) == .off)
        #expect(LaunchAtLogin.decision(preference: false, state: .revokedByUser) == .off)
    }

    /// Y el que arregla el desajuste: preferencia activa, registro perdido.
    @Test("sin registrar con la preferencia activa: se vuelve a pedir el registro")
    func staleRegistrationIsRepaired() {
        #expect(LaunchAtLogin.decision(preference: true, state: .notRegistered) == .register)
    }

    @Test("sin registrar y sin preferencia: no se pide nada")
    func nothingIsRegisteredUnasked() {
        #expect(LaunchAtLogin.decision(preference: false, state: .notRegistered) == .off)
    }

    /// Ejecutar desde la carpeta de compilación cae aquí. Apagar la preferencia entonces
    /// borraría la del usuario por un veredicto que el sistema no ha dado.
    @Test("sin veredicto del sistema, la preferencia se conserva tal cual")
    func unavailableLeavesThePreferenceAlone() {
        #expect(LaunchAtLogin.decision(preference: true, state: .unavailable) == .on)
        #expect(LaunchAtLogin.decision(preference: false, state: .unavailable) == .off)
    }
}
