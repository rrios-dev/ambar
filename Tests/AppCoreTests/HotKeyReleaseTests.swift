import Carbon.HIToolbox
import Testing

@testable import AppCore

/// Soltar el atajo tiene que llegar a alguien.
///
/// El gesto de mantener vigila **solo los modificadores** (`HoldGesture.watchedFlags`),
/// porque `NSEvent.modifierFlags` es lo único que se puede leer sin permisos. La
/// consecuencia, encontrada por una auditoría independiente: con ⇧⌘V, soltar la V y
/// quedarse con ⇧⌘ puestos deja la cuenta viva, y a los 550 ms se abre el micrófono sin
/// que nadie esté manteniendo el atajo. Basta con quedarse quieto mirando la lista con
/// dos dedos apoyados.
///
/// La pieza que faltaba es `kEventHotKeyReleased` («A registered hot key was released»,
/// `CarbonEvents.h:4697-4715`), que llega por el mismo canal que la pulsación y no cuesta
/// ningún permiso adicional. Se descartó `CGEventSourceKeyState` —que también sabría si la
/// tecla sigue hundida— por el riesgo asimétrico: si devolviera `false` en alguna
/// configuración, el dictado no se dispararía **nunca**, en silencio, que es peor que el
/// fallo que arregla.
///
/// El reparto del evento sí se puede probar; la **entrega** por parte de Carbon no, porque
/// `swift test` no tiene despachador de eventos ni sesión gráfica. Queda como hueco
/// declarado, y por eso el registro de aquí abajo es real: al menos se comprueba contra el
/// `HotKeyCenter` de verdad y no contra una copia.
@Suite("El atajo avisa también al soltarse", .serialized)
@MainActor
struct HotKeyReleaseTests {

    /// ⌃⌥⇧⌘F19. Deliberadamente absurda: F19 no existe en los teclados de portátil, y con
    /// los cuatro modificadores no puede chocar con nada que el usuario pulse mientras la
    /// suite corre. Registrar el atajo de verdad (⇧⌘V) se lo robaría a la instancia de
    /// Ámbar que pueda estar abierta en la máquina.
    static let harmless = KeyCombination(
        keyCode: UInt32(kVK_F19),
        modifiers: UInt32(controlKey | optionKey | shiftKey | cmdKey)
    )

    @Test("soltar el atajo dispara onRelease, y no la acción de pulsar")
    func releaseDispatchesToItsOwnHandler() throws {
        var pressed = 0
        var released = 0
        let identifier = try #require(
            HotKeyCenter.shared.register(
                Self.harmless,
                action: { pressed += 1 },
                onRelease: { released += 1 }
            ),
            "no se pudo registrar el atajo de prueba"
        )
        defer { HotKeyCenter.shared.unregister(identifier) }

        HotKeyCenter.shared.simulateReleaseForTesting(identifier: identifier)

        #expect(released == 1, "soltar el atajo no llegó a onRelease")
        // La otra mitad: si el reparto mandara todo al mismo sitio, cada vez que el usuario
        // soltara el atajo se abriría o cerraría el panel.
        #expect(pressed == 0, "soltar el atajo ejecutó además la acción de pulsarlo")
    }

    @Test("dar de baja el atajo se lleva también el aviso de soltar")
    func unregisterRemovesTheReleaseHandler() throws {
        var released = 0
        let identifier = try #require(
            HotKeyCenter.shared.register(Self.harmless, action: {}, onRelease: { released += 1 }),
            "no se pudo registrar el atajo de prueba"
        )

        HotKeyCenter.shared.unregister(identifier)
        HotKeyCenter.shared.simulateReleaseForTesting(identifier: identifier)

        // Importa porque el atajo se re-registra cada vez que el usuario lo cambia en
        // Ajustes: un handler que sobreviviera a su baja cancelaría el gesto con el atajo
        // viejo, que ya no vigila nadie.
        #expect(released == 0, "el aviso siguió vivo tras dar de baja el atajo")
    }

    @Test("registrar sin onRelease sigue siendo válido")
    func onReleaseIsOptional() throws {
        // El parámetro se añadió con valor por defecto para no tocar a quien ya llamaba.
        // Si soltar el atajo reventara cuando nadie escucha, el arreglo sería peor que el
        // fallo.
        let identifier = try #require(
            HotKeyCenter.shared.register(Self.harmless, action: {}),
            "no se pudo registrar el atajo de prueba"
        )
        defer { HotKeyCenter.shared.unregister(identifier) }

        HotKeyCenter.shared.simulateReleaseForTesting(identifier: identifier)
    }
}
