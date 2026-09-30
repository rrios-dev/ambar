import AppKit
import ApplicationServices

/// Recorre el árbol de accesibilidad **real** del panel y lo publica.
///
/// Existe por un hueco que tres auditorías seguidas señalaron y que ninguna cerró: en un
/// proceso de `swift test` el árbol de accesibilidad está vacío, así que ninguna prueba
/// puede ver lo que SwiftUI publica. Medido: borrar `.accessibilityLabel(label)` de los
/// botones de la banda de dictado —parar, descartar, cerrar— dejaba las 481 pruebas en
/// verde con esos controles sin nombre para VoiceOver, que es la única forma que tiene de
/// nombrarlos.
///
/// El diagnóstico correcto («el árbol está vacío en un test») se había tratado como final
/// de la conversación. No lo es: el árbol **sí** existe en la app lanzada, y la app se
/// puede lanzar. Es la misma lección que costó un bloqueante de arranque — una comprobación
/// que solo se puede hacer con la app en pie hay que hacerla con la app en pie.
///
/// Publica una línea por elemento con rol, nombre y tamaño, en un formato que un guion
/// puede afirmar sin ambigüedad.
enum AccessibilityDump {

    /// Un elemento del árbol, aplanado.
    struct Element {
        let depth: Int
        let role: String
        let label: String
        let size: CGSize
    }

    /// Recorre en profundidad con `AXUIElement`, la misma API que usa VoiceOver.
    ///
    /// **No** se usan los métodos `accessibility*()` de `NSView`: medido, devuelven la
    /// jerarquía vacía —solo la raíz, `AXUnknown`— porque SwiftUI construye su árbol bajo
    /// demanda cuando un cliente de accesibilidad pregunta, y una llamada interna no lo es.
    /// `AXUIElementCreateApplication(getpid())` sí lo es: se pregunta el proceso a sí mismo
    /// por el mismo canal que VoiceOver, y el árbol se materializa.
    static func walk(
        _ element: AXUIElement,
        depth: Int = 0,
        into result: inout [Element],
        seen: inout [AXUIElement]
    ) {
        // Acotado por IDENTIDAD, no solo por profundidad: medido, la propia `AXApplication`
        // se publica como hija de sí misma, así que un recorrido que solo mire la
        // profundidad devuelve 1882 elementos donde hay una veintena.
        guard depth < 40 else { return }
        if seen.contains(where: { CFEqual($0, element) }) { return }
        seen.append(element)

        func string(_ attribute: String) -> String? {
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success
            else { return nil }
            return value as? String
        }

        var size = CGSize.zero
        var sizeValue: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue) == .success,
           let axValue = sizeValue, CFGetTypeID(axValue) == AXValueGetTypeID() {
            AXValueGetValue(axValue as! AXValue, .cgSize, &size)
        }

        result.append(
            Element(
                depth: depth,
                role: string(kAXRoleAttribute) ?? "—",
                label: string(kAXDescriptionAttribute)
                    ?? string(kAXTitleAttribute)
                    ?? string(kAXValueAttribute)
                    ?? "",
                size: size
            )
        )

        var childrenValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenValue) == .success,
              let children = childrenValue as? [AXUIElement]
        else { return }
        for child in children {
            walk(child, depth: depth + 1, into: &result, seen: &seen)
        }
    }

    /// Imprime el árbol del panel con el prefijo `A11Y`, una línea por elemento.
    ///
    /// El formato es deliberadamente rígido —`A11Y <profundidad> <rol> <ancho>x<alto> <nombre>`—
    /// porque quien lo consume es un guion, y un formato que se puede leer de dos maneras
    /// es un guion que puede afirmar dos cosas.
    @MainActor
    static func dump(panel: NSWindow) {
        let application = AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier)

        // El panel se busca por su POSICIÓN en pantalla, no enumerando las ventanas del
        // proceso.
        //
        // `kAXWindowsAttribute` resultó no ser fiable aquí: en una sesión devolvió el panel
        // y en otra devolvió la propia `AXApplication` —que además se publica como hija de
        // sí misma, así que el recorrido daba 1882 elementos, todos menús, y el gate
        // acusaba de «sin nombre» a controles que sí lo tienen—. La diferencia no estaba en
        // el código: el mismo binario, verde y rojo, según el estado de la sesión gráfica.
        //
        // `AXUIElementCopyElementAtPosition` hace prueba de impacto por orden de
        // superposición («based on window z-order», `AXUIElement.h:337`) y devuelve el
        // elemento que hay bajo ese punto. Desde él se sube a su ventana con
        // `kAXWindowAttribute`. Es un camino que no depende de qué considere el proceso una
        // «ventana suya».
        let frame = panel.frame
        guard let screen = panel.screen ?? NSScreen.main else {
            print("A11Y ERROR no hay pantalla donde localizar el panel")
            return
        }
        // AX usa coordenadas con el origen ARRIBA a la izquierda; AppKit, abajo.
        let center = CGPoint(
            x: frame.midX,
            y: screen.frame.maxY - frame.midY
        )

        var hit: AXUIElement?
        if AXUIElementCopyElementAtPosition(application, Float(center.x), Float(center.y), &hit) != .success {
            print("A11Y ERROR no hay ningún elemento accesible en el centro del panel")
            return
        }
        guard let element = hit else {
            print("A11Y ERROR la prueba de impacto no devolvió elemento")
            return
        }

        var windowValue: CFTypeRef?
        let root: AXUIElement
        if AXUIElementCopyAttributeValue(element, kAXWindowAttribute as CFString, &windowValue) == .success,
           let window = windowValue, CFGetTypeID(window) == AXUIElementGetTypeID() {
            root = window as! AXUIElement
        } else {
            // Sin ventana bajo el punto, el panel NO está en pantalla — y eso no es un
            // fallo de accesibilidad, es una precondición que no se cumple.
            //
            // Distinguirlo importa más de lo que parece: mientras el volcado salía vacío,
            // el gate decía «ningún AXButton se llama «Detener»», que es exactamente lo que
            // diría si alguien hubiera borrado la etiqueta. Un instrumento que da el mismo
            // veredicto ante un defecto y ante su propia imposibilidad de medir manda al
            // siguiente lector a buscar un fallo que no existe.
            print("A11Y ERROR el panel no está en pantalla: la prueba de impacto en su centro")
            print("A11Y ERROR no encontró ninguna ventana. Sin sesión gráfica activa —pantalla")
            print("A11Y ERROR bloqueada, sin escritorio, o el proceso sin poder mostrar ventanas—")
            print("A11Y ERROR este volcado no puede medir nada.")
            return
        }

        var elements: [Element] = []
        var seen: [AXUIElement] = []
        walk(root, into: &elements, seen: &seen)

        for element in elements {
            let size = "\(Int(element.size.width.rounded()))x\(Int(element.size.height.rounded()))"
            print("A11Y \(element.depth) \(element.role) \(size) \(element.label)")
        }
        print("A11Y TOTAL \(elements.count)")
    }
}
