import Foundation
import Testing
import VoiceKit

/// The deterministic replacement layer. Pure, so it can be asserted exhaustively.
@Suite("Corrector de vocabulario")
struct VocabularyCorrectorTests {

    private func rule(_ from: String, _ to: String) -> VocabularyCorrector.Rule {
        VocabularyCorrector.Rule(from: from, to: to)
    }

    @Test("reemplaza palabra completa, también pegada a puntuación")
    func replacesWholeWords() {
        let (text, applied) = VocabularyCorrector.apply(
            [rule("antropic", "Anthropic")],
            to: "Habla de antropic, y de antropic."
        )
        #expect(text == "Habla de Anthropic, y de Anthropic.")
        #expect(applied == ["Anthropic"])
    }

    @Test("no toca una palabra que solo CONTIENE la forma oída")
    func doesNotFireInsideLongerWords() {
        let (text, applied) = VocabularyCorrector.apply(
            [rule("antropic", "Anthropic")],
            to: "un tratado antropical"
        )
        #expect(text == "un tratado antropical")
        #expect(applied.isEmpty)
    }

    @Test("la coincidencia ignora mayúsculas; el reemplazo impone la forma enseñada")
    func matchingIsCaseInsensitive() {
        let (text, _) = VocabularyCorrector.apply(
            [rule("bercel", "Vercel")],
            to: "Bercel y bercel y BERCEL"
        )
        #expect(text == "Vercel y Vercel y Vercel")
    }

    @Test("una corrección solo de mayúsculas es una corrección real")
    func caseOnlyRulesApply() {
        let (text, applied) = VocabularyCorrector.apply(
            [rule("poesía", "Poesía")],
            to: "el sistema poesía"
        )
        #expect(text == "el sistema Poesía")
        #expect(applied == ["Poesía"])
    }

    @Test("texto ya correcto no cuenta como reemplazo")
    func noChangeIsNotCredited() {
        let (text, applied) = VocabularyCorrector.apply(
            [rule("anthropic", "Anthropic")],
            to: "Anthropic ya está bien"
        )
        #expect(text == "Anthropic ya está bien")
        #expect(applied.isEmpty)
    }

    @Test("las formas oídas de varias palabras también corrigen")
    func multiWordFormsApply() {
        let (text, applied) = VocabularyCorrector.apply(
            [rule("open ia", "OpenAI")],
            to: "compáralo con open ia hoy"
        )
        #expect(text == "compáralo con OpenAI hoy")
        #expect(applied == ["OpenAI"])
    }

    @Test("reglas vacías o idénticas se ignoran")
    func degenerateRulesAreSkipped() {
        let (text, applied) = VocabularyCorrector.apply(
            [rule("", "algo"), rule("  ", "algo"), rule("igual", "igual")],
            to: "igual que antes"
        )
        #expect(text == "igual que antes")
        #expect(applied.isEmpty)
    }

    @Test("los caracteres especiales de la forma oída no rompen el patrón")
    func specialCharactersAreEscaped() {
        let (text, _) = VocabularyCorrector.apply(
            [rule("c++", "C++")],
            to: "programa en c++ desde ayer"
        )
        #expect(text == "programa en C++ desde ayer")
    }
}

/// The dictionary file one app writes and another reads (EFFICIENCY.md E8): the shape
/// Ámbar's `PersonalDictionary` saves, read back as Quill reads it.
@Suite("Dictation dictionary file")
struct DictationDictionaryFileTests {
    @Test("entries written with ISO 8601 dates are read back, ranked and turned into rules")
    func roundTrip() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let old = Date(timeIntervalSince1970: 1_000), new = Date(timeIntervalSince1970: 2_000)
        let entries = [
            DictionaryEntry(id: UUID(), written: "Anthropic", heard: ["antropic", "an tropic"], uses: 1, lastUsedAt: old, addedAt: old),
            DictionaryEntry(id: UUID(), written: "Kubernetes", heard: ["cuber netes"], uses: 4, lastUsedAt: new, addedAt: old),
        ]
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let url = directory.appendingPathComponent(DictationDictionary.fileName)
        try encoder.encode(entries).write(to: url)

        let read = DictationDictionary.load(from: url)
        #expect(read == entries)
        #expect(DictationDictionary.contextualStrings(read) == ["Kubernetes", "Anthropic"], "more uses first")
        let rules = DictationDictionary.replacementRules(read)
        #expect(rules.count == 3)
        #expect(VocabularyCorrector.apply(rules, to: "Lo subo a cuber netes con antropic").text == "Lo subo a Kubernetes con Anthropic")
    }

    @Test("a missing or damaged file is an empty dictionary, never a failure")
    func missingOrDamaged() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        #expect(DictationDictionary.load(from: url).isEmpty)
        try Data("{not json".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(DictationDictionary.load(from: url).isEmpty)
    }
}
