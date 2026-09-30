import AppKit
import Testing

@testable import Ambar

/// En un gestor de portapapeles, no poder pegar en su propio campo de búsqueda.
///
/// Ámbar no tenía menú principal, y AppKit reparte los equivalentes de teclado de edición
/// por ahí. Medido con una sonda aislada sobre un `NSTextField` enfocado, preguntando a las
/// dos puertas que AppKit consulta por dentro (`NSMenu.performKeyEquivalent` y
/// `NSWindow.performKeyEquivalent`):
///
///     SIN menú principal → menú:false ventana:false
///     CON menú de Edición → menú:true  ventana:false
///
/// La columna de la ventana es la que zanja el asunto: la jerarquía de vistas no atiende la
/// tecla, así que sin menú no la atiende nadie.
///
/// Lo que estos tests sujetan es la tabla de entradas. La **entrega** de la pulsación real
/// por parte de AppKit no se puede probar desde `swift test`: los eventos de teclado
/// sintéticos no se reparten como equivalentes (comprobado con `sendEvent` y con
/// `postEvent`, ambos sin efecto), y hacerlo de verdad exigiría postear un `CGEvent` a la
/// sesión —permiso de accesibilidad y teclas viajando a lo que el usuario tenga delante—,
/// que es exactamente el incidente que esta suite ya provocó dos veces. Hueco declarado.
@Suite("Se puede editar texto dentro de Ámbar")
@MainActor
struct EditMenuTests {

    static func editMenu() throws -> NSMenu {
        let main = EditMenu.makeMainMenu()
        return try #require(main.items.first?.submenu, "el menú principal no lleva submenú de edición")
    }

    @Test("pegar, copiar, cortar, seleccionar todo y deshacer tienen su tecla")
    func everyEditingCommandIsBound() throws {
        let menu = try Self.editMenu()

        // El caso que motivó todo esto va primero y por su nombre: ⌘V.
        let paste = try #require(
            menu.items.first { $0.keyEquivalent == "v" },
            "no hay entrada para ⌘V: no se puede pegar en el campo de búsqueda"
        )
        #expect(paste.action == #selector(NSText.paste(_:)), "⌘V no está atado a pegar")
        #expect(paste.keyEquivalentModifierMask == [.command], "⌘V pide otros modificadores")

        for expected in ["z", "x", "c", "v", "a"] {
            #expect(
                menu.items.contains { $0.keyEquivalent == expected },
                "falta el equivalente ⌘\(expected.uppercased())"
            )
        }
    }

    @Test("rehacer se distingue de deshacer por el modificador")
    func redoIsShiftedUndo() throws {
        let menu = try Self.editMenu()
        let zItems = menu.items.filter { $0.keyEquivalent == "z" }

        #expect(zItems.count == 2, "deshacer y rehacer no comparten tecla como deberían: \(zItems.count)")
        #expect(
            zItems.contains { $0.keyEquivalentModifierMask == [.command] },
            "deshacer no responde a ⌘Z"
        )
        #expect(
            zItems.contains { $0.keyEquivalentModifierMask == [.command, .shift] },
            "rehacer no responde a ⇧⌘Z"
        )
    }

    @Test("ninguna entrada fija destino: la acción sube por la cadena de respondedores")
    func nothingIsBoundToAFixedTarget() throws {
        let menu = try Self.editMenu()

        // Con un destino fijo, la acción dejaría de aplicarse en cuanto el foco cambiara
        // —y el foco cambia constantemente: campo de búsqueda, lista, ajustes.
        for item in menu.items {
            #expect(item.target == nil, "«\(item.title)» está atado a un objeto concreto")
        }
    }
}
