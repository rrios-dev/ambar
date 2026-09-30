import AppKit
import Foundation
import Testing

@testable import ClipboardKit

/// Pasteboard privado, nunca el general: los tests no deben pisar lo que el
/// usuario tenga copiado mientras se ejecutan.
private func makePasteboard() -> NSPasteboard {
    NSPasteboard(name: NSPasteboard.Name("dev.rrios.ambar.tests.\(UUID().uuidString)"))
}

@Suite("PasteboardReader")
struct PasteboardReaderTests {

    @Test("El texto con acentos se lee sin alterar un solo byte")
    func readsUnicodeText() {
        let pasteboard = makePasteboard()
        let original = "Ámbar: canción con tildes ÑÁÉÍÓÚ y emoji 🟠"

        pasteboard.clearContents()
        pasteboard.setString(original, forType: .string)

        let captured = PasteboardReader.read(from: pasteboard)

        #expect(captured?.preview == original)
        #expect(captured?.searchableText == original)
        #expect(Array(captured!.preview.utf8.prefix(2)) == [0xC3, 0x81])
    }

    @Test("El contenido marcado como confidencial no se captura")
    func ignoresConcealedContent() {
        let pasteboard = makePasteboard()
        pasteboard.clearContents()

        let item = NSPasteboardItem()
        item.setString("contraseña-secreta", forType: .string)
        item.setData(Data(), forType: NSPasteboard.PasteboardType(UTIs.concealed))
        pasteboard.writeObjects([item])

        #expect(PasteboardReader.read(from: pasteboard) == nil)
    }

    @Test("El contenido transitorio tampoco se captura")
    func ignoresTransientContent() {
        let pasteboard = makePasteboard()
        pasteboard.clearContents()

        let item = NSPasteboardItem()
        item.setString("temporal", forType: .string)
        item.setData(Data(), forType: NSPasteboard.PasteboardType(UTIs.transient))
        pasteboard.writeObjects([item])

        #expect(PasteboardReader.read(from: pasteboard) == nil)
    }

    @Test("Un pasteboard vacío o en blanco no genera entrada")
    func ignoresEmpty() {
        let pasteboard = makePasteboard()
        pasteboard.clearContents()
        #expect(PasteboardReader.read(from: pasteboard) == nil)

        pasteboard.clearContents()
        pasteboard.setString("   \n\t  ", forType: .string)
        #expect(PasteboardReader.read(from: pasteboard) == nil)
    }

    @Test("Un enlace se clasifica como enlace, no como texto suelto")
    func detectsURL() {
        let pasteboard = makePasteboard()
        pasteboard.clearContents()
        pasteboard.setString("https://www.dittostack.com/precios", forType: .string)

        #expect(PasteboardReader.read(from: pasteboard)?.kind == .url)
    }

    @Test("Una frase que contiene dos puntos no se confunde con un enlace")
    func doesNotOverDetectURL() {
        #expect(PasteboardReader.isLikelyURL("nota: comprar pan") == false)
        #expect(PasteboardReader.isLikelyURL("12:30") == false)
        #expect(PasteboardReader.isLikelyURL("https://ejemplo.com") == true)
    }

    @Test("El texto con formato conserva todas sus representaciones")
    func keepsAllRepresentations() {
        let pasteboard = makePasteboard()
        pasteboard.clearContents()

        let attributed = NSAttributedString(
            string: "texto con estilo",
            attributes: [.font: NSFont.boldSystemFont(ofSize: 14)]
        )
        let rtf = attributed.rtf(
            from: NSRange(location: 0, length: attributed.length),
            documentAttributes: [:]
        )!

        let item = NSPasteboardItem()
        item.setString("texto con estilo", forType: .string)
        item.setData(rtf, forType: .rtf)
        pasteboard.writeObjects([item])

        let captured = PasteboardReader.read(from: pasteboard)

        #expect(captured?.kind == .richText)
        // La clave del pegado con formato: se guardan las dos variantes, y es
        // la app de destino la que elige cuál entiende.
        let utis = Set(captured?.representations.map(\.uti) ?? [])
        #expect(utis.contains(UTIs.rtf))
        #expect(utis.contains(UTIs.plainText))
    }

    @Test("Una imagen se lee como imagen y con sus bytes intactos")
    func readsImage() throws {
        let pasteboard = makePasteboard()
        pasteboard.clearContents()

        let image = NSImage(size: NSSize(width: 12, height: 12))
        image.lockFocus()
        NSColor.orange.setFill()
        NSRect(x: 0, y: 0, width: 12, height: 12).fill()
        image.unlockFocus()

        let tiff = try #require(image.tiffRepresentation)
        let png = try #require(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))

        let item = NSPasteboardItem()
        item.setData(png, forType: .png)
        pasteboard.writeObjects([item])

        let captured = try #require(PasteboardReader.read(from: pasteboard))
        #expect(captured.kind == .image)
        #expect(captured.imageData == png)
    }

    @Test("El preview colapsa saltos de línea y espacios repetidos")
    func previewIsSingleLine() {
        let messy = "línea uno\n\n\tlínea    dos\r\nlínea tres"
        let preview = PasteboardReader.singleLinePreview(messy)

        #expect(!preview.contains("\n"))
        #expect(!preview.contains("  "))
        #expect(preview == "línea uno línea dos línea tres")
    }

    @Test("Un preview larguísimo se recorta con puntos suspensivos")
    func previewIsTruncated() {
        let long = String(repeating: "a", count: 5_000)
        let preview = PasteboardReader.singleLinePreview(long, limit: 100)

        #expect(preview.count == 101)  // 100 caracteres + el carácter de elisión
        #expect(preview.hasSuffix("…"))
    }
}

@Suite("SearchQuery — análisis")
struct SearchQueryTests {

    @Test("Texto suelto se convierte en términos de búsqueda")
    func plainTerms() {
        let query = SearchQuery.parse("factura septiembre")
        #expect(query.terms == ["factura", "septiembre"])
        #expect(query.kinds.isEmpty)
    }

    @Test("El prefijo de tipo filtra y deja buscar a la vez")
    func kindPrefix() {
        let query = SearchQuery.parse("img: factura")
        #expect(query.kinds == [.image])
        #expect(query.terms == ["factura"])

        let combined = SearchQuery.parse("img:factura")
        #expect(combined.kinds == [.image])
        #expect(combined.terms == ["factura"])
    }

    @Test("Los prefijos funcionan en los dos idiomas de la interfaz")
    func bilingualPrefixes() {
        #expect(SearchQuery.parse("imagen:").kinds == [.image])
        #expect(SearchQuery.parse("archivo:").kinds == [.file])
        #expect(SearchQuery.parse("enlace:").kinds == [.url])
        #expect(SearchQuery.parse("file:").kinds == [.file])
    }

    @Test("El prefijo de app acota por origen")
    func appPrefix() {
        let query = SearchQuery.parse("app:safari contrato")
        #expect(query.app == "safari")
        #expect(query.terms == ["contrato"])
    }

    @Test("Una URL pegada en el buscador se busca, no se interpreta")
    func urlIsNotAPrefix() {
        let query = SearchQuery.parse("https://ejemplo.com")
        #expect(query.terms == ["https://ejemplo.com"])
        #expect(query.kinds.isEmpty)
        #expect(query.app == nil)
    }

    @Test("Los términos se entrecomillan para que la puntuación no explote")
    func expressionEscapesQuotes() {
        #expect(SearchQuery.parse("hola").ftsExpression == "\"hola\"*")
        #expect(SearchQuery.parse("C++").ftsExpression == "\"C++\"*")

        // Una comilla dentro del término se duplica, que es como FTS5 escapa.
        let quoted = SearchQuery(terms: ["di \"hola\""])
        #expect(quoted.ftsExpression == "\"di \"\"hola\"\"\"*")
    }

    @Test("Una consulta vacía no produce expresión de búsqueda")
    func emptyQuery() {
        #expect(SearchQuery.parse("").ftsExpression == nil)
        #expect(SearchQuery.parse("").isEmpty)
    }
}
