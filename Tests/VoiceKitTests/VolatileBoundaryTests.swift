import Foundation
import Testing

@testable import VoiceKit

/// The firm/volatile boundary that travels with each fragment.
///
/// The boundary is what lets the panel offer editing while the engine is still
/// talking: the firm prefix is stable by engine contract, the tail is rewritten
/// wholesale on the next result. A boundary that drifts by even the joining space
/// puts the editor's cursor inside text the engine is about to replace.
@Suite("Frontera firme/volátil de los fragmentos")
struct VolatileBoundaryTests {

    @Test("un fragmento volátil sin medida se asume volátil ENTERO")
    func defaultForVolatileIsEverything() {
        let fragment = TranscriptFragment(text: "hola mundo", isVolatile: true)
        #expect(fragment.volatileCharacterCount == 10)
    }

    @Test("un fragmento firme sin medida no tiene cola volátil")
    func defaultForFinalIsNothing() {
        let fragment = TranscriptFragment(text: "hola mundo", isVolatile: false)
        #expect(fragment.volatileCharacterCount == 0)
    }

    @Test("la medida se acota al texto: ni negativa ni mayor que él")
    func countIsClamped() {
        #expect(
            TranscriptFragment(text: "abc", isVolatile: true, volatileCharacterCount: -2)
                .volatileCharacterCount == 0
        )
        #expect(
            TranscriptFragment(text: "abc", isVolatile: true, volatileCharacterCount: 99)
                .volatileCharacterCount == 3
        )
    }

    @Test("la sesión mide la cola sobre el texto YA unido, espacio incluido")
    func sessionMeasuresAgainstTheJoinedText() async {
        let session = SpeechSession(locale: Locale(identifier: "es-ES"), mode: .live)

        // A closed sentence, then a hypothesis: the volatile part of the joined
        // text is " segunda" — the joining space belongs to the hypothesis, because
        // the engine may replace the whole continuation including how it attaches.
        _ = await session.recordAndMeasureForTesting("Primera frase", isFinal: true)
        let snapshot = await session.recordAndMeasureForTesting("segunda", isFinal: false)

        #expect(snapshot.text == "Primera frase segunda")
        #expect(snapshot.volatileCharacters == " segunda".count)
    }

    @Test("al cerrar la frase, la cola vuelve a cero")
    func finalizingClearsTheTail() async {
        let session = SpeechSession(locale: Locale(identifier: "es-ES"), mode: .live)

        _ = await session.recordAndMeasureForTesting("hola mun", isFinal: false)
        let snapshot = await session.recordAndMeasureForTesting("hola mundo", isFinal: true)

        #expect(snapshot.text == "hola mundo")
        #expect(snapshot.volatileCharacters == 0)
    }

    @Test("una hipótesis de solo espacios no deja cola fantasma")
    func whitespaceHypothesisMeasuresZero() async {
        let session = SpeechSession(locale: Locale(identifier: "es-ES"), mode: .live)

        _ = await session.recordAndMeasureForTesting("Primera frase", isFinal: true)
        // `join` trims the tail before appending, so the joined text does not grow;
        // measuring the raw input instead of the output would report 3 here.
        let snapshot = await session.recordAndMeasureForTesting("   ", isFinal: false)

        #expect(snapshot.text == "Primera frase")
        #expect(snapshot.volatileCharacters == 0)
    }
}
