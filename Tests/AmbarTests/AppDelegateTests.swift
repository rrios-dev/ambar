import Foundation
import Testing

@testable import Ambar

/// Que el estado del dictado llegue de verdad al icono de la barra de menús.
///
/// `MenuBarPresenceTests` prueba `MenuBarPresence.resolve(isDictating:pause:)` — la
/// función pura que consume el estado una vez que ya está en `AppDelegate.isDictating`.
/// Lo que faltaba, y lo que la auditoría independiente encontró: nadie probaba que ese
/// valor **llegara** ahí. `AppDelegate` es la única presencia permanente de una app sin
/// icono en el Dock, así que si esta asignación se pierde, el usuario no tiene NINGÚN
/// otro sitio donde ver que el micrófono sigue abierto con el panel cerrado.
///
/// No se instancia `AppDelegate` a través de `applicationDidFinishLaunching`: eso llama a
/// `installStatusItem()` y `registerHotKey()`, que tocan recursos reales del sistema —la
/// barra de estado, un atajo global Carbon— y podrían interferir con una instancia de
/// Ámbar de verdad corriendo en la máquina donde se ejecuta la suite. `wireDictationStateChange()`
/// existe separado exactamente para poder ejercitar esto sin acercarse a esos dos.
@Suite("El estado del dictado llega al icono de la barra de menús", .serialized)
@MainActor
struct AppDelegateDictationWiringTests {

    @Test("el micrófono abierto se refleja en el icono")
    func microphoneOpenReachesTheIcon() {
        let delegate = AppDelegate()
        delegate.wireDictationStateChange()

        #expect(!delegate.isDictatingForTesting, "nace ya escuchando: caso mal montado")

        delegate.callOnDictationStateChangeForTesting(true)
        #expect(delegate.isDictatingForTesting, "el icono no se enteró de que el micrófono se abrió")

        delegate.callOnDictationStateChangeForTesting(false)
        #expect(!delegate.isDictatingForTesting, "el icono se quedó encendido tras cerrar")
    }
}
