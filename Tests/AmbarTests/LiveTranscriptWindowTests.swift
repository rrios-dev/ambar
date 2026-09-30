import AppKit
import Foundation
import Testing

@testable import Ambar

/// La ventana de texto que se ve mientras se dicta.
///
/// Lo que protege es una promesa concreta: **el final del dictado se ve siempre**. Era falsa
/// —se veían las tres primeras líneas y lo que se acababa de decir quedaba fuera—, y las dos
/// formas de arreglarlo con modificadores de SwiftUI se descartaron tras medirlas en una
/// rasterización de la banda real, no por sospecha. De ahí que el cálculo esté a mano y que
/// haga falta afirmarlo aquí.
@Suite("Ventana del texto dictado")
// El ancho se toma de la banda, y una vista es `@MainActor`: sin esto, leerlo desde un
// contexto no aislado es un aviso, y este repositorio los trata como errores.
@MainActor
struct LiveTranscriptWindowTests {

    /// El ancho real de la columna en el panel, tomado de la banda y no copiado: medir con
    /// otro ancho comprobaría una composición que nadie ve.
    static var width: CGFloat { DictationBanner.liveTextWidth }
    static var font: NSFont { .systemFont(ofSize: 13) }

    static func lineCount(_ text: String) -> Int {
        LiveTranscriptWindow.lineRanges(of: text, width: width, font: font).count
    }

    static func windowed(_ text: String, lines: Int = 3) -> String {
        LiveTranscriptWindow.tail(of: text, width: width, font: font, lines: lines)
    }

    /// Un dictado largo de verdad: veinte veces la misma frase y un final reconocible.
    static let ending = "Y ESTE ES EL FINAL QUE TIENE QUE VERSE."
    static var longDictation: String {
        String(repeating: "esto es una prueba de dictado con bastantes palabras seguidas ", count: 20)
            + ending
    }

    @Test("Lo que cabe se enseña entero y sin adornos")
    func shortTextIsUntouched() {
        let short = "una frase corta que cabe de sobra"
        #expect(Self.windowed(short) == short)
    }

    @Test("El final del dictado se ve siempre")
    func tailIsAlwaysVisible() {
        let visible = Self.windowed(Self.longDictation)
        #expect(visible.hasSuffix(Self.ending))
    }

    @Test("Lo que se corta es el principio, y se anuncia")
    func headIsWhatDisappears() {
        let visible = Self.windowed(Self.longDictation)
        #expect(visible.hasPrefix(LiveTranscriptWindow.ellipsis))
        #expect(!Self.longDictation.hasPrefix(LiveTranscriptWindow.ellipsis))
    }

    @Test("Lo que se devuelve cabe en las líneas pedidas")
    func fitsWithinTheRequestedLines() {
        // Medido, no estimado: contar caracteres no dice nada sobre dónde rompe una línea, y
        // pasarse de largo es justo el defecto que se venía a arreglar —lo que sobra lo
        // recorta SwiftUI, y lo recorta por el final.
        for lines in 1...4 {
            #expect(Self.lineCount(Self.windowed(Self.longDictation, lines: lines)) <= lines)
        }
    }

    @Test("Un dictado por encima del techo de medición conserva su final")
    func beyondTheScanLimit() {
        let huge = String(repeating: "palabra ", count: 2_000) + Self.ending
        #expect(huge.count > LiveTranscriptWindow.scanLimit)

        let visible = Self.windowed(huge)
        #expect(visible.hasSuffix(Self.ending))
        #expect(Self.lineCount(visible) <= 3)
    }

    @Test("Una parrafada sin un solo espacio no atasca el cálculo")
    func textWithoutWordBreaks() {
        // El corte se busca por roturas de línea, no por palabras. Sin espacios, CoreText
        // rompe dentro de la palabra y el bucle tiene que converger igual.
        let wall = String(repeating: "0123456789", count: 300) + "FIN"
        let visible = Self.windowed(wall)
        #expect(visible.hasSuffix("FIN"))
        #expect(Self.lineCount(visible) <= 3)
    }

    @Test("El vacío se queda vacío")
    func emptyStaysEmpty() {
        #expect(Self.windowed("").isEmpty)
    }
}
