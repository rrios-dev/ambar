import Foundation
import Speech
import Testing

@testable import VoiceKit

/// The analysis context that carries the user's vocabulary into the engine.
///
/// The shape is asserted without a live engine because the failure is silent by
/// nature: a context under the wrong tag, or one that silently exceeded Apple's
/// documented cap of 100 phrases, still transcribes — just without the bias the
/// user taught. Nothing on screen would ever say so.
@Suite("Contexto de sesgo del motor")
struct AnalysisContextBiasTests {

    @Test("las frases viajan bajo la etiqueta general")
    func phrasesTravelUnderTheGeneralTag() {
        let context = SpeechSession.analysisContext(biasing: ["Anthropic", "Vercel"])

        #expect(context?.contextualStrings[.general] == ["Anthropic", "Vercel"])
    }

    @Test("sin frases útiles no se construye contexto")
    func blankInputYieldsNoContext() {
        #expect(SpeechSession.analysisContext(biasing: []) == nil)
        #expect(SpeechSession.analysisContext(biasing: ["", "   ", "\n"]) == nil)
    }

    @Test("el tope documentado se aplica DESPUÉS de filtrar")
    func capAppliesAfterFiltering() {
        // 100 valid terms plus blanks: the blanks must not consume valid slots.
        let input = (0..<SpeechSession.contextualStringsLimit).map { "term-\($0)" } + ["", "  "]
        let context = SpeechSession.analysisContext(biasing: input)

        #expect(
            context?.contextualStrings[.general]?.count == SpeechSession.contextualStringsLimit
        )
        #expect(context?.contextualStrings[.general]?.last == "term-99")
    }

    @Test("por encima del tope, sobrevive el principio de la lista")
    func overflowKeepsTheFrontOfTheList() {
        let input = (0..<150).map { "term-\($0)" }
        let context = SpeechSession.analysisContext(biasing: input)

        let phrases = context?.contextualStrings[.general]
        #expect(phrases?.count == SpeechSession.contextualStringsLimit)
        // The caller ranks best-first, so the trim must drop the tail, not the head.
        #expect(phrases?.first == "term-0")
        #expect(phrases?.last == "term-99")
    }
}
