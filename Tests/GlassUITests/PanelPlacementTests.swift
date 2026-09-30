import CoreGraphics
import Testing

@testable import GlassUI

/// La posición del panel movible.
///
/// Lo que se prueba aquí es la decisión de si una posición guardada sigue
/// sirviendo. El caso que importa —desconectar el monitor donde estaba el
/// panel— no se descubre programando, sino el día que pasa: el atajo
/// responde, el panel se muestra fuera de toda pantalla, y quien lo usa cree
/// que la app está rota.
@Suite("Colocación del panel")
struct PanelPlacementTests {
    /// Un portátil solo.
    let laptop = CGRect(x: 0, y: 0, width: 1512, height: 945)
    /// Un monitor externo a la derecha del portátil.
    let external = CGRect(x: 1512, y: 0, width: 2560, height: 1440)
    let panel = CGSize(width: 720, height: 480)

    @Test("Una posición dentro de la pantalla sirve")
    func insideIsUsable() {
        let origin = CGPoint(x: 400, y: 200)
        #expect(PanelPlacement.isUsable(origin: origin, size: panel, screens: [laptop]))
    }

    @Test("La posición del monitor externo deja de servir al desconectarlo")
    func externalScreenRemoved() {
        // El panel estaba cómodamente en el monitor de la derecha…
        let origin = CGPoint(x: 2000, y: 400)
        #expect(PanelPlacement.isUsable(origin: origin, size: panel, screens: [laptop, external]))

        // …y al desconectarlo, esa posición ya no existe. Sin esta
        // comprobación el panel se abriría en la nada.
        #expect(!PanelPlacement.isUsable(origin: origin, size: panel, screens: [laptop]))
    }

    @Test("Asomar por un borde no cuenta como visible")
    func barelyOnScreenIsNotUsable() {
        // Solo el extremo izquierdo del panel queda dentro: técnicamente hay
        // superposición, pero es inservible.
        let origin = CGPoint(x: laptop.maxX - 80, y: 300)
        #expect(!PanelPlacement.isUsable(origin: origin, size: panel, screens: [laptop]))
    }

    @Test("Con dos tercios dentro sigue siendo manejable")
    func mostlyOnScreenIsUsable() {
        // Un 75 % del ancho dentro: se lee y se puede agarrar para devolverlo
        // al centro, que es el criterio.
        let origin = CGPoint(x: laptop.maxX - panel.width * 0.75, y: 300)
        #expect(PanelPlacement.isUsable(origin: origin, size: panel, screens: [laptop]))
    }

    @Test("Sin pantallas no hay posición válida")
    func noScreens() {
        #expect(!PanelPlacement.isUsable(origin: .zero, size: panel, screens: []))
    }

    @Test("El centrado queda por encima del centro geométrico")
    func centeredSitsAboveTheMiddle() {
        let origin = PanelPlacement.centered(in: laptop, size: panel)

        // Horizontalmente sí va exacto.
        #expect(origin.x == laptop.midX - panel.width / 2)

        // Verticalmente, más arriba: en AppKit el eje Y crece hacia arriba,
        // así que «más arriba» es una Y mayor. Una ventana centrada con
        // exactitud se percibe baja.
        #expect(origin.y > laptop.midY - panel.height / 2)
    }

    @Test("Lo que se centra queda dentro de su pantalla")
    func centeredIsUsable() {
        for screen in [laptop, external] {
            let origin = PanelPlacement.centered(in: screen, size: panel)
            #expect(PanelPlacement.isUsable(origin: origin, size: panel, screens: [screen]))
        }
    }
}
