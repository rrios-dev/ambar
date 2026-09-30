import AppKit
import Carbon.HIToolbox
import Testing

@testable import AppCore

private func makePasteboard() -> NSPasteboard {
    NSPasteboard(name: NSPasteboard.Name("dev.rrios.ambar.paster.\(UUID().uuidString)"))
}

@Suite("Paster — escritura al portapapeles")
@MainActor
struct PasterTests {

    @Test("Escribir varias representaciones las deja todas disponibles")
    func writesEveryRepresentation() {
        let pasteboard = makePasteboard()
        let plain = Data("texto plano".utf8)
        let rtf = Data("{\\rtf1 texto plano}".utf8)

        Paster.write(
            [
                Paster.Payload(uti: "public.utf8-plain-text", data: plain),
                Paster.Payload(uti: "public.rtf", data: rtf),
            ],
            to: pasteboard
        )

        // La propiedad que hace posible pegar con formato: la app de destino
        // encuentra la variante que entiende porque están las dos.
        #expect(pasteboard.data(forType: .string) == plain)
        #expect(pasteboard.data(forType: .rtf) == rtf)
    }

    @Test("El texto con acentos sobrevive al portapapeles")
    func preservesUnicode() {
        let pasteboard = makePasteboard()
        let original = "canción · mañana · 1.240,00 €"

        Paster.write(
            [Paster.Payload(uti: "public.utf8-plain-text", data: Data(original.utf8))],
            to: pasteboard
        )

        #expect(pasteboard.string(forType: .string) == original)
    }

    @Test("Escribir en modo plano no arrastra el formato anterior")
    func plainTextReplacesPrevious() {
        let pasteboard = makePasteboard()

        Paster.write(
            [
                Paster.Payload(uti: "public.utf8-plain-text", data: Data("con formato".utf8)),
                Paster.Payload(uti: "public.rtf", data: Data("{\\rtf1 con formato}".utf8)),
            ],
            to: pasteboard
        )
        Paster.writePlainText("sin formato", to: pasteboard)

        #expect(pasteboard.string(forType: .string) == "sin formato")
        // Si el RTF anterior siguiera ahí, pegar en un editor con formato
        // traería el contenido viejo.
        #expect(pasteboard.data(forType: .rtf) == nil)
    }

    @Test("Escribir una lista vacía no borra lo que ya había")
    func emptyWriteIsNoOp() {
        let pasteboard = makePasteboard()
        Paster.writePlainText("contenido previo", to: pasteboard)

        Paster.write([], to: pasteboard)

        #expect(pasteboard.string(forType: .string) == "contenido previo")
    }
}

@Suite("Atajos de teclado")
struct KeyCombinationTests {

    @Test("El atajo por defecto es ⌘⇧V")
    func defaultShortcut() {
        let combination = KeyCombination.commandShiftV
        #expect(combination.keyCode == UInt32(kVK_ANSI_V))
        #expect(combination.modifiers & UInt32(cmdKey) != 0)
        #expect(combination.modifiers & UInt32(shiftKey) != 0)
        #expect(combination.displayString == "⇧⌘V")
    }

    @Test("Los modificadores se muestran en el orden de Apple")
    func modifierOrder() {
        // macOS los lista siempre ⌃⌥⇧⌘, sea cual sea el orden interno.
        let all = KeyCombination(
            keyCode: UInt32(kVK_ANSI_A),
            modifiers: UInt32(cmdKey | shiftKey | optionKey | controlKey)
        )
        #expect(all.displayString == "⌃⌥⇧⌘A")
    }

    @Test("El atajo se puede serializar y recuperar")
    func codableRoundTrip() throws {
        let original = KeyCombination.commandShiftV
        let data = try JSONEncoder().encode(original)
        let recovered = try JSONDecoder().decode(KeyCombination.self, from: data)
        #expect(recovered == original)
    }
}

@Suite("Captura de atajo")
struct ShortcutRecorderTests {

    @Test("Los modificadores de AppKit se traducen a los códigos de Carbon")
    @MainActor
    func translatesModifiers() throws {
        // Son dos vocabularios distintos: NSEvent usa una máscara propia y
        // RegisterEventHotKey espera las constantes clásicas. Sin traducción,
        // el atajo se registra con modificadores equivocados y nunca dispara.
        let event = try #require(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero,
                modifierFlags: [.command, .option],
                timestamp: 0, windowNumber: 0, context: nil,
                characters: "j", charactersIgnoringModifiers: "j",
                isARepeat: false, keyCode: UInt16(kVK_ANSI_J)
            )
        )

        let combination = KeyCombination(carbonFrom: event)
        #expect(combination.keyCode == UInt32(kVK_ANSI_J))
        #expect(combination.modifiers & UInt32(cmdKey) != 0)
        #expect(combination.modifiers & UInt32(optionKey) != 0)
        #expect(combination.modifiers & UInt32(shiftKey) == 0)
        #expect(combination.displayString == "⌥⌘J")
    }

    @Test("Las teclas que no son letras se muestran con su símbolo")
    func namesNonLetterKeys() {
        let cases: [(Int, String)] = [
            (kVK_Space, "␣"), (kVK_Return, "↩"), (kVK_LeftArrow, "←"),
            (kVK_ANSI_7, "7"), (kVK_F5, "F5"), (kVK_Escape, "⎋"),
        ]
        for (code, symbol) in cases {
            let combination = KeyCombination(keyCode: UInt32(code), modifiers: UInt32(cmdKey))
            // Antes solo se mapeaban letras y todo lo demás salía como "?",
            // inservible en un campo donde hay que reconocer lo pulsado.
            #expect(combination.displayString == "⌘" + symbol, "código \(code)")
        }
    }

    @Test("Una tecla sin nombre conocido muestra su código, no un interrogante")
    func unknownKeyShowsCode() {
        let combination = KeyCombination(keyCode: 999, modifiers: UInt32(cmdKey))
        #expect(combination.displayString == "⌘#999")
    }
}
