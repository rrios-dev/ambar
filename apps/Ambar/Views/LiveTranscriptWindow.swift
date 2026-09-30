import AppKit
import CoreText
import Foundation

/// La ventana de texto que la banda enseña mientras se dicta: **las últimas líneas**.
///
/// Está aquí, calculado a mano, porque SwiftUI no sabe hacerlo. Ambas alternativas se
/// probaron rasterizando la banda real y las dos fallan:
///
/// - `.truncationMode(.head)` con `lineLimit(3)` recorta **solo la última línea**. Las dos
///   primeras siguen enseñando el principio del dictado para siempre, así que de las tres
///   líneas solo una cuenta lo que se acaba de decir.
/// - Dejar el texto entero y recortar por altura con `frame(height:alignment:.bottom)` +
///   `clipped()` no da una ventana inferior: `Text` respeta la altura propuesta y trunca
///   **por el final**, que es exactamente el defecto que se venía a arreglar.
///
/// Lo que sí funciona es decidir el texto antes de pintarlo: se mide dónde rompe cada línea
/// al ancho real y se entrega solo la cola. `.truncationMode(.head)` se mantiene en la vista
/// como red: si esta medición se queda corta por un pelo, lo que se pierde es el principio
/// —recuperable— y no el final, que es lo único que la banda existe para confirmar.
enum LiveTranscriptWindow {
    /// Carácter que anuncia que por arriba falta texto.
    static let ellipsis = "…"

    /// Cuánto texto se mide, como mucho.
    ///
    /// El motor reescribe la hipótesis varias veces por segundo y medir el dictado entero
    /// en cada una es trabajo que crece con la sesión: a los diez minutos se estaría
    /// framesetteando un folio para pintar tres líneas. Ningún ancho plausible mete dos mil
    /// caracteres en tres líneas, así que la cola cabe siempre dentro de este techo.
    static let scanLimit = 2_000

    /// Las últimas `lines` líneas de `text` al ancho dado, con `…` delante si se cortó algo.
    ///
    /// Devuelve el texto tal cual cuando ya cabe: mientras el dictado es corto no aparece
    /// ningún adorno.
    static func tail(
        of text: String,
        width: CGFloat,
        font: NSFont,
        lines: Int = 3
    ) -> String {
        guard lines > 0, width > 0, !text.isEmpty else { return text }

        var elided = text.count > scanLimit
        var body = elided ? String(text.suffix(scanLimit)) : text

        // Recortar cambia dónde rompen las líneas —el `…` que se añade delante ocupa— así
        // que el corte se reajusta hasta que cuadra. Converge en dos vueltas; el tope es
        // por si alguna combinación de fuente y ancho no lo hiciera.
        for _ in 0..<4 {
            let display = elided ? ellipsis + body : body
            let ranges = lineRanges(of: display, width: width, font: font)
            guard ranges.count > lines else { return display }

            let cutInDisplay = ranges[ranges.count - lines].location
            let cutInBody = max(0, Int(cutInDisplay) - (elided ? ellipsis.utf16.count : 0))
            let source = body as NSString
            guard cutInBody > 0, cutInBody < source.length else {
                // El `…` se ha quedado una línea entera para él solo. Pasa cuando lo que
                // sigue no tiene por dónde romper —una URL larga, un volcado en base64— y
                // la única rotura posible es la que va justo detrás del punto. Entonces el
                // cupo del texto es una línea menos: se pierde una línea de contexto, que
                // es lo barato; lo que no se puede perder es el final.
                guard lines > 1 else { return ellipsis + body }
                return ellipsis + lastLines(of: body, count: lines - 1, width: width, font: font)
            }

            // Sin el espacio de delante: una línea que empieza por hueco después del `…`
            // se lee como un error de composición.
            body = String(source.substring(from: cutInBody).drop(while: \.isWhitespace))
            elided = true
        }

        return elided ? ellipsis + body : body
    }

    /// Las últimas `count` líneas de `text`, sin adornos.
    private static func lastLines(
        of text: String,
        count: Int,
        width: CGFloat,
        font: NSFont
    ) -> String {
        let ranges = lineRanges(of: text, width: width, font: font)
        guard ranges.count > count else { return text }
        let source = text as NSString
        let cut = Int(ranges[ranges.count - count].location)
        guard cut > 0, cut < source.length else { return text }
        return String(source.substring(from: cut).drop(while: \.isWhitespace))
    }

    /// Dónde rompe cada línea al componer `string` en una columna de `width`.
    ///
    /// No es privada porque el test mide con ella: la promesa que hay que poder afirmar es
    /// «lo que devuelve `tail` cabe en tres líneas», y comprobarla contando caracteres sería
    /// comprobar otra cosa.
    static func lineRanges(of string: String, width: CGFloat, font: NSFont) -> [CFRange] {
        let attributed = NSAttributedString(string: string, attributes: [.font: font])
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        // Altura deliberadamente enorme: interesa dónde rompe el texto, no cuánto cabe.
        let path = CGPath(
            rect: CGRect(x: 0, y: 0, width: width, height: 1_000_000),
            transform: nil
        )
        let frame = CTFramesetterCreateFrame(
            framesetter,
            CFRange(location: 0, length: 0),
            path,
            nil
        )
        guard let lines = CTFrameGetLines(frame) as? [CTLine] else { return [] }
        return lines.map(CTLineGetStringRange)
    }
}
