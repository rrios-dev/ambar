import AppKit

/// La marca de Ámbar, dibujada para la barra de menús.
///
/// ## Por qué no es el icono de la app
///
/// Porque en la barra de menús **el color no viaja**. Un icono de estado es
/// una imagen de plantilla: se entrega solo con su silueta y el sistema la
/// tiñe —negra sobre barra clara, blanca sobre oscura, invertida cuando el
/// menú está abierto— y respeta el color de acento de quien lo haya cambiado.
/// Un icono de color ahí se ve mal en la mitad de las configuraciones y
/// desaparece en las otras. Lo que sube a la barra es la FORMA: la gota, con
/// su inclusión, que es lo que hace reconocible la marca sin una gota de
/// ámbar.
///
/// ## Por qué contorno y no relleno
///
/// Por peso óptico. Los símbolos del sistema que tiene al lado —Wi-Fi, sonido,
/// batería, centro de control— son trazos de poco más de un punto; una gota
/// maciza de quince puntos de alto se lee como un borrón y pesa el doble que
/// sus vecinas. Con la gota a contorno y la inclusión rellena, la marca se
/// reconoce y la barra sigue pareciendo la barra.
///
/// ## Por qué se dibuja aquí y no es un fichero
///
/// Es la misma razón por la que el icono de la app se dibuja por código: así
/// el diseño se revisa en un diff legible en vez de sustituir un binario a
/// ciegas. Y además hay que dibujarlo dos veces —a 1× y a 2×— para que no lo
/// escale nadie por nosotros.
enum MenuBarGlyph {
    /// Alto del glifo en puntos.
    ///
    /// 16 y no 18: la barra da 22 puntos de alto y los símbolos del sistema
    /// ocupan unos 16. Llenarla entera es lo que delata a un icono de terceros.
    static let height: CGFloat = 16

    /// La marca, lista para `NSStatusItem`.
    ///
    /// Se marca como plantilla en el propio `NSImage` y no en quien la usa:
    /// olvidarlo ahí fuera es el fallo clásico —el icono sale negro sobre la
    /// barra oscura y solo se ve al pasar el ratón.
    static func image() -> NSImage {
        // El ancho sale de la proporción del dibujo original (20 de ancho por
        // 27,4 de alto en el trazado de la marca), no de un número redondo:
        // una caja cuadrada dejaría la gota flotando descentrada.
        let size = NSSize(width: (height * 20 / 27.4).rounded(), height: height)

        let image = NSImage(size: size, flipped: false) { rect in
            draw(in: rect)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Ámbar"
        return image
    }

    /// El dibujo: la gota a contorno, con la inclusión rellena dentro.
    ///
    /// Las coordenadas son las de la marca (`viewBox` de 32) reescaladas a la
    /// caja que toque, para que la silueta sea EXACTAMENTE la del icono de la
    /// app y la de la web. Tres dibujos parecidos son tres dibujos; uno solo,
    /// escalado, es una marca.
    static func draw(in rect: NSRect) {
        let scale = rect.height / 27.4
        // Origen del trazado original dentro de su caja de 32: la gota va de
        // (6, 2.6) a (26, 30).
        let originX = rect.minX - 6 * scale
        // AppKit dibuja con el eje Y hacia arriba y el trazado está descrito
        // hacia abajo: se ancla por la parte de arriba y se resta.
        let originY = rect.maxY + 2.6 * scale
        func punto(_ x: CGFloat, _ y: CGFloat) -> NSPoint {
            NSPoint(x: originX + x * scale, y: originY - y * scale)
        }

        let drop = NSBezierPath()
        drop.move(to: punto(16, 2.6))
        drop.curve(to: punto(26, 19.8), controlPoint1: punto(20.1, 9.8), controlPoint2: punto(26, 13.7))
        drop.appendArc(
            withCenter: punto(16, 19.8),
            radius: 10 * scale,
            startAngle: 0,
            endAngle: 180,
            clockwise: true
        )
        drop.curve(to: punto(16, 2.6), controlPoint1: punto(6, 13.7), controlPoint2: punto(11.9, 9.8))
        drop.close()

        NSColor.black.setStroke()
        // 1,45 puntos: el peso al que se dibujan los símbolos del sistema en
        // esta barra. Medido comparándolo con los suyos, no elegido a ojo.
        drop.lineWidth = 1.45 * (rect.height / MenuBarGlyph.height)
        drop.lineJoinStyle = .round
        drop.stroke()

        // La inclusión, rellena: es el único macizo del glifo y por eso se lee
        // a 16 puntos. Sin ella la silueta es una gota de agua cualquiera.
        let seed = NSBezierPath(
            ovalIn: NSRect(
                x: punto(13.9, 22.7).x,
                y: punto(13.9, 22.7).y,
                width: 5.2 * scale,
                height: 4.2 * scale
            )
        )
        NSColor.black.setFill()
        seed.fill()
    }
}
