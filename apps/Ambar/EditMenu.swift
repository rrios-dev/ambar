import AppKit

/// El menú de edición que hace que ⌘V, ⌘C, ⌘X, ⌘A y ⌘Z funcionen dentro de Ámbar.
///
/// Suena absurdo en una app cuyo trabajo **es** el portapapeles, y sin embargo era cierto:
/// no se podía pegar en su propio campo de búsqueda. Ámbar no tenía menú principal, y en
/// AppKit los equivalentes de teclado de edición los reparte el menú, no el campo.
///
/// Medido con una sonda aislada sobre un `NSTextField` enfocado, preguntando a las dos
/// puertas que AppKit consulta por dentro:
///
///     SIN menú principal → menú:false ventana:false
///     CON menú de Edición → menú:true  ventana:false
///
/// La segunda columna es la que zanja el asunto: la jerarquía de vistas **no** atiende la
/// tecla. Sin menú no la atiende nadie, y ⌘V no hace nada.
///
/// Los títulos no se traducen, y no es un descuido. Ámbar corre como app accesoria
/// (`LSUIElement`): no tiene barra de menús, así que estos títulos no se dibujan en ningún
/// sitio. Lo que se usa de estas entradas es el equivalente de teclado y el selector.
/// Traducirlos a los diez idiomas sería inventar texto que nadie puede leer, y daría a la
/// auditoría de localización diez cadenas que revisar sin ninguna superficie donde
/// comprobarlas.
enum EditMenu {

    /// Cada entrada: qué tecla, qué acción, y por qué está.
    ///
    /// El destino es `nil` a propósito: así la acción sube por la cadena de respondedores
    /// hasta el editor de campo que tenga el foco. Fijar un destino la ataría a un objeto
    /// concreto y dejaría de funcionar en cuanto el foco cambiara.
    static let items: [(title: String, action: Selector, key: String, modifiers: NSEvent.ModifierFlags)] = [
        ("Undo", Selector(("undo:")), "z", [.command]),
        ("Redo", Selector(("redo:")), "z", [.command, .shift]),
        ("Cut", #selector(NSText.cut(_:)), "x", [.command]),
        ("Copy", #selector(NSText.copy(_:)), "c", [.command]),
        ("Paste", #selector(NSText.paste(_:)), "v", [.command]),
        ("Select All", #selector(NSText.selectAll(_:)), "a", [.command]),
    ]

    /// Construye el menú principal completo.
    static func makeMainMenu() -> NSMenu {
        let mainMenu = NSMenu()
        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")

        for entry in items {
            let item = NSMenuItem(title: entry.title, action: entry.action, keyEquivalent: entry.key)
            item.keyEquivalentModifierMask = entry.modifiers
            editMenu.addItem(item)
        }

        editItem.submenu = editMenu
        mainMenu.addItem(editItem)
        return mainMenu
    }
}
