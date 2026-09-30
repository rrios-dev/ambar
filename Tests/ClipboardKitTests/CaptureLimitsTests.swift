import AppKit
import Foundation
import Testing

@testable import ClipboardKit

private func makePasteboard() -> NSPasteboard {
    NSPasteboard(name: NSPasteboard.Name("dev.rrios.ambar.limits.\(UUID().uuidString)"))
}

@Suite("Límites de captura")
struct CaptureLimitsTests {

    @Test("Un texto por encima del límite no entra en el historial")
    func oversizedTextIsRejected() throws {
        let pasteboard = makePasteboard()
        let limits = CaptureLimits(maximumTextBytes: 1_000)

        pasteboard.clearContents()
        pasteboard.setString(String(repeating: "x", count: 5_000), forType: .string)

        let outcome = PasteboardReader.inspect(pasteboard, limits: limits)

        guard case .ignored(.tooLarge(let bytes, let limit)) = outcome else {
            Issue.record("se capturó un texto que supera el límite: \(outcome)")
            return
        }
        #expect(bytes == 5_000)
        #expect(limit == 1_000)
    }

    @Test("Un texto por debajo del límite entra con normalidad")
    func normalTextIsAccepted() throws {
        let pasteboard = makePasteboard()
        pasteboard.clearContents()
        pasteboard.setString("una nota corriente", forType: .string)

        #expect(PasteboardReader.inspect(pasteboard).item != nil)
    }

    @Test("El límite se mide en bytes UTF-8, no en caracteres")
    func limitCountsBytesNotCharacters() {
        let pasteboard = makePasteboard()
        // 300 emoji son 300 caracteres pero 1200 bytes: lo que importa para la
        // memoria y el disco es lo segundo.
        let emoji = String(repeating: "🟠", count: 300)
        #expect(emoji.count == 300)
        #expect(emoji.utf8.count == 1_200)

        pasteboard.clearContents()
        pasteboard.setString(emoji, forType: .string)

        let outcome = PasteboardReader.inspect(
            pasteboard, limits: CaptureLimits(maximumTextBytes: 1_000)
        )
        guard case .ignored(.tooLarge(let bytes, _)) = outcome else {
            Issue.record("no se aplicó el límite por bytes")
            return
        }
        #expect(bytes == 1_200)
    }

    @Test("El texto justo en el límite se acepta")
    func textAtExactLimitIsAccepted() {
        let pasteboard = makePasteboard()
        let text = String(repeating: "a", count: 1_000)
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        let outcome = PasteboardReader.inspect(
            pasteboard, limits: CaptureLimits(maximumTextBytes: 1_000)
        )
        #expect(outcome.item != nil, "el límite debe ser inclusivo")
    }

    @Test("Una imagen que pesa poco pero se descomprime enorme se rechaza")
    func hugePixelCountIsRejectedEvenWhenBytesAreSmall() throws {
        let pasteboard = makePasteboard()

        // Una imagen de color liso comprime a muy pocos bytes, pero al
        // descomprimirse ocupa cuatro bytes por píxel. Es el caso que el
        // límite por bytes NO atrapa y que de verdad agota la memoria.
        let side = 3_000
        let image = NSImage(size: NSSize(width: side, height: side))
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: side, height: side).fill()
        image.unlockFocus()

        let tiff = try #require(image.tiffRepresentation)
        let png = try #require(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))

        let item = NSPasteboardItem()
        item.setData(png, forType: .png)
        pasteboard.clearContents()
        pasteboard.writeObjects([item])

        // Holgado en bytes, estrecho en píxeles: 9 millones contra 1 millón.
        let limits = CaptureLimits(
            maximumImageBytes: 64 * 1024 * 1024,
            maximumImagePixels: 1_000_000
        )
        #expect(png.count < limits.maximumImageBytes, "la premisa del test: el PNG pesa poco")

        guard case .ignored(.tooLarge) = PasteboardReader.inspect(pasteboard, limits: limits) else {
            Issue.record("se aceptó una imagen de \(side)×\(side) con el límite en un megapíxel")
            return
        }
    }

    @Test("Una imagen de tamaño normal se acepta")
    func normalImageIsAccepted() throws {
        let pasteboard = makePasteboard()
        let image = NSImage(size: NSSize(width: 400, height: 300))
        image.lockFocus()
        NSColor.systemBlue.setFill()
        NSRect(x: 0, y: 0, width: 400, height: 300).fill()
        image.unlockFocus()

        let tiff = try #require(image.tiffRepresentation)
        let png = try #require(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))

        let item = NSPasteboardItem()
        item.setData(png, forType: .png)
        pasteboard.clearContents()
        pasteboard.writeObjects([item])

        #expect(PasteboardReader.inspect(pasteboard).item?.kind == .image)
    }

    @Test("El motivo del descarte distingue confidencial de demasiado grande")
    func reasonsAreDistinguishable() {
        let pasteboard = makePasteboard()

        pasteboard.clearContents()
        let concealed = NSPasteboardItem()
        concealed.setString("clave", forType: .string)
        concealed.setData(Data(), forType: NSPasteboard.PasteboardType(UTIs.concealed))
        pasteboard.writeObjects([concealed])

        guard case .ignored(let reason) = PasteboardReader.inspect(pasteboard) else {
            Issue.record("se capturó contenido marcado como confidencial")
            return
        }
        // La distinción importa: lo confidencial se descarta en silencio, pero
        // lo grande hay que decirlo o parece que la app no funciona.
        #expect(reason == .markedPrivate)
    }

    @Test("Los valores por defecto son generosos, no restrictivos")
    func defaultsAreGenerous() {
        let limits = CaptureLimits.standard
        // Cinco millones de caracteres: del orden de mil quinientas páginas.
        #expect(limits.maximumTextBytes >= 5 * 1024 * 1024)
        // Por encima de cualquier captura de pantalla razonable.
        #expect(limits.maximumImageBytes >= 32 * 1024 * 1024)
        #expect(limits.maximumImagePixels >= 50_000_000)
    }
}
