import AppCore
import AppKit
import Foundation
import Testing
import VoiceKit

@testable import Ambar

/// The personal dictionary: what dictation learns from the user's corrections.
///
/// The promises worth asserting are the ones whose failure is silent: an upsert that
/// duplicates instead of merging quietly eats the 100 bias slots; a replacement that
/// fires inside a longer word corrupts text the user never touched; a ranking that
/// ignores use lets stale terms crowd out the ones that keep earning their place.
@Suite("Diccionario personal del dictado")
@MainActor
struct PersonalDictionaryTests {

    /// A fresh store in its own directory, so tests never share state.
    static func makeDictionary() -> (PersonalDictionary, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "ambar-dictionary-tests-\(UUID().uuidString)")
        return (PersonalDictionary(directory: directory), directory)
    }

    @Test("aprender crea la entrada con su forma oída")
    func learningCreatesAnEntry() {
        let (dictionary, _) = Self.makeDictionary()
        let entry = dictionary.learn(heard: "antropic", written: "Anthropic")

        #expect(entry?.written == "Anthropic")
        #expect(entry?.heard == ["antropic"])
        #expect(entry?.uses == 1)
        #expect(dictionary.entries.count == 1)
    }

    @Test("aprender la misma palabra acumula variantes en UNA entrada")
    func learningUpsertsByWrittenForm() {
        let (dictionary, _) = Self.makeDictionary()
        dictionary.learn(heard: "antropic", written: "Anthropic")
        dictionary.learn(heard: "antrópic", written: "anthropic")

        // One entry, not two: near-duplicates would each occupy a bias slot.
        #expect(dictionary.entries.count == 1)
        let entry = dictionary.entries[0]
        #expect(entry.heard == ["antropic", "antrópic"])
        #expect(entry.uses == 2)
        // The latest spelling wins, even when it only changes the case.
        #expect(entry.written == "anthropic")
    }

    @Test("una forma oída idéntica a la escrita no genera regla")
    func identicalHeardFormIsNotStored() {
        let (dictionary, _) = Self.makeDictionary()
        dictionary.learn(heard: "Anthropic", written: "Anthropic")

        #expect(dictionary.entries[0].heard.isEmpty)
        #expect(dictionary.replacementRules().isEmpty)
    }

    @Test("deshacer un aprendizaje recién creado elimina la entrada")
    func undoRemovesAFreshEntry() {
        let (dictionary, _) = Self.makeDictionary()
        guard let entry = dictionary.learn(heard: "bercel", written: "Vercel") else {
            Issue.record("learning produced no entry")
            return
        }
        dictionary.undoLearning(of: entry, heard: "bercel")

        #expect(dictionary.entries.isEmpty)
    }

    @Test("deshacer sobre una entrada veterana solo revierte ese uso")
    func undoOnAnExistingEntryRollsBackTheUse() {
        let (dictionary, _) = Self.makeDictionary()
        dictionary.learn(heard: "bercel", written: "Vercel")
        guard let second = dictionary.learn(heard: "versel", written: "Vercel") else {
            Issue.record("learning produced no entry")
            return
        }
        dictionary.undoLearning(of: second, heard: "versel")

        // The entry the user built earlier survives; only the undone variant leaves.
        #expect(dictionary.entries.count == 1)
        #expect(dictionary.entries[0].heard == ["bercel"])
        #expect(dictionary.entries[0].uses == 1)
    }

    @Test("las cadenas de sesgo van por uso y respetan el tope del motor")
    func contextualStringsAreRankedAndCapped() {
        let (dictionary, _) = Self.makeDictionary()
        for index in 0..<(SpeechSession.contextualStringsLimit + 5) {
            dictionary.add(written: "term-\(index)")
        }
        dictionary.learn(heard: "termo", written: "term-90")
        dictionary.learn(heard: "termo", written: "term-90")

        let strings = dictionary.contextualStrings()
        #expect(strings.count == SpeechSession.contextualStringsLimit)
        // The entry that keeps earning uses must lead, wherever it was added.
        #expect(strings.first == "term-90")
    }

    @Test("el diccionario sobrevive a un reinicio")
    func persistenceRoundTrips() {
        let (dictionary, directory) = Self.makeDictionary()
        dictionary.learn(heard: "antropic", written: "Anthropic")

        let reloaded = PersonalDictionary(directory: directory)
        #expect(reloaded.entries.count == 1)
        #expect(reloaded.entries[0].written == "Anthropic")
        #expect(reloaded.entries[0].heard == ["antropic"])
    }

    @Test("un fichero corrupto deja un diccionario vacío, no un cuelgue")
    func corruptFileYieldsEmptyDictionary() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "ambar-dictionary-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: directory.appending(path: "dictionary.json"))

        let dictionary = PersonalDictionary(directory: directory)
        #expect(dictionary.entries.isEmpty)
    }

    @Test("borrar una entrada la quita de las reglas y del sesgo")
    func removalReachesEveryConsumer() {
        let (dictionary, _) = Self.makeDictionary()
        guard let entry = dictionary.learn(heard: "antropic", written: "Anthropic") else {
            Issue.record("learning produced no entry")
            return
        }
        dictionary.remove(id: entry.id)

        #expect(dictionary.entries.isEmpty)
        #expect(dictionary.contextualStrings().isEmpty)
        #expect(dictionary.replacementRules().isEmpty)
    }
}

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

/// The vocabulary travelling through the dictation coordinator: bias out, corrections in.
@Suite("Vocabulario en el coordinador del dictado")
@MainActor
struct DictationVocabularyTests {

    static func makeDictionary() -> PersonalDictionary {
        PersonalDictionary(
            directory: FileManager.default.temporaryDirectory
                .appending(path: "ambar-dictionary-tests-\(UUID().uuidString)")
        )
    }

    @Test("las cadenas de sesgo del diccionario llegan al motor")
    func contextualStringsReachTheEngine() async throws {
        let dictionary = Self.makeDictionary()
        dictionary.learn(heard: "antropic", written: "Anthropic")
        let request = DictationControllerTests.SessionRequest()
        let controller = DictationController(
            engine: DictationControllerTests.FakeEngine(
                session: DictationControllerTests.FakeSession(),
                request: request
            ),
            gesture: HoldGesture(watchedFlags: [.command], threshold: .milliseconds(50)),
            deliver: { _ in },
            permission: { .granted },
            vocabulary: dictionary
        )

        controller.startWithoutGesture(locale: Locale(identifier: "es-ES"), mode: .live)
        await DictationControllerTests.waitUntil { controller.state.isMicrophoneOpen }
        try? await Task.sleep(for: .milliseconds(50))

        #expect(await request.contextualStrings == ["Anthropic"], "el sesgo no llegó al motor")
    }

    @Test("sin diccionario, el motor recibe una lista vacía")
    func withoutADictionaryTheEngineGetsNothing() async throws {
        let request = DictationControllerTests.SessionRequest()
        let controller = DictationController(
            engine: DictationControllerTests.FakeEngine(
                session: DictationControllerTests.FakeSession(),
                request: request
            ),
            gesture: HoldGesture(watchedFlags: [.command], threshold: .milliseconds(50)),
            deliver: { _ in },
            permission: { .granted }
        )

        controller.startWithoutGesture(locale: Locale(identifier: "es-ES"), mode: .live)
        await DictationControllerTests.waitUntil { controller.state.isMicrophoneOpen }
        try? await Task.sleep(for: .milliseconds(50))

        #expect(await request.contextualStrings == [])
    }

    @Test("el texto en vivo se pinta ya corregido")
    func liveFragmentsArriveCorrected() async throws {
        let dictionary = Self.makeDictionary()
        dictionary.learn(heard: "antropic", written: "Anthropic")
        let controller = DictationController(
            engine: DictationControllerTests.FakeEngine(
                session: DictationControllerTests.FakeSession(
                    fragments: ["habla de antropic ahora"]
                )
            ),
            gesture: HoldGesture(watchedFlags: [.command], threshold: .milliseconds(50)),
            deliver: { _ in },
            permission: { .granted },
            vocabulary: dictionary
        )

        controller.startWithoutGesture(locale: Locale(identifier: "es-ES"), mode: .live)
        await DictationControllerTests.waitUntil { !controller.liveText.isEmpty }

        #expect(controller.liveText == "habla de Anthropic ahora")
    }

    @Test("la entrega aplica el diccionario y acredita el uso")
    func deliveryIsCorrectedAndCredited() async throws {
        let dictionary = Self.makeDictionary()
        dictionary.learn(heard: "antropic", written: "Anthropic")
        let delivered = TestBox<Transcript?>(nil)
        let controller = DictationController(
            engine: DictationControllerTests.FakeEngine(
                session: DictationControllerTests.FakeSession(
                    transcript: Transcript(text: "saluda a antropic", mode: .live)
                )
            ),
            gesture: HoldGesture(watchedFlags: [.command], threshold: .milliseconds(50)),
            deliver: { delivered.value = $0 },
            permission: { .granted },
            vocabulary: dictionary
        )

        controller.startWithoutGesture(locale: Locale(identifier: "es-ES"), mode: .live)
        await DictationControllerTests.waitUntil { controller.state.isMicrophoneOpen }
        controller.stop()
        await DictationControllerTests.waitUntil { delivered.value != nil }

        // What the user watched — corrected — is what the destination receives.
        #expect(delivered.value?.text == "saluda a Anthropic")
        // And the entry earned its place in the ranking: learn once, deliver once.
        #expect(dictionary.entries[0].uses == 2)
    }
}

/// The transcript expansion state and the volatile boundary as the panel sees them.
@Suite("Expansión del transcript en vivo")
@MainActor
struct TranscriptExpansionTests {

    /// A session that publishes ONE fragment with an explicit volatile boundary,
    /// like the real engine does mid-sentence.
    actor BoundarySession: TranscriptionSession {
        let fragment: TranscriptFragment
        init(fragment: TranscriptFragment) { self.fragment = fragment }

        func prepare() async throws {}
        func start() async throws -> AsyncStream<TranscriptFragment> {
            let captured = fragment
            return AsyncStream { continuation in
                continuation.yield(captured)
                continuation.finish()
            }
        }
        func finish() async throws -> Transcript {
            Transcript(text: fragment.text, mode: .live)
        }
        func cancel() async {}
        func setDeviceChangeHandler(_ handler: @escaping @Sendable () -> Void) async {}
        func setSessionLimitHandler(_ handler: @escaping @Sendable () -> Void) async {}
    }

    static func makeDictionary() -> PersonalDictionary {
        PersonalDictionary(
            directory: FileManager.default.temporaryDirectory
                .appending(path: "ambar-dictionary-tests-\(UUID().uuidString)")
        )
    }

    @Test("la corrección de la parte firme no desplaza la frontera volátil")
    func correctionsDoNotShiftTheBoundary() async throws {
        let dictionary = Self.makeDictionary()
        dictionary.learn(heard: "antropic", written: "Anthropic")
        let controller = DictationController(
            engine: DictationControllerTests.FakeEngine(
                session: BoundarySession(
                    fragment: TranscriptFragment(
                        text: "habla de antropic ahora mismo",
                        isVolatile: true,
                        volatileCharacterCount: " ahora mismo".count
                    )
                )
            ),
            gesture: HoldGesture(watchedFlags: [.command], threshold: .milliseconds(50)),
            deliver: { _ in },
            permission: { .granted },
            vocabulary: dictionary
        )

        controller.startWithoutGesture(locale: Locale(identifier: "es-ES"), mode: .live)
        await DictationControllerTests.waitUntil { !controller.liveText.isEmpty }

        // The firm prefix grew by one character ("antropic" → "Anthropic"); the
        // volatile tail must still be exactly " ahora mismo". Splitting AFTER
        // correcting — instead of before — would swallow the "o" of "ahora".
        #expect(controller.liveText == "habla de Anthropic ahora mismo")
        #expect(controller.liveVolatileCharacters == " ahora mismo".count)
    }

    @Test("expandir y contraer es un conmutador")
    func expansionToggles() {
        let controller = DictationController(
            engine: DictationControllerTests.FakeEngine(
                session: DictationControllerTests.FakeSession()
            ),
            gesture: HoldGesture(watchedFlags: [.command], threshold: .milliseconds(50)),
            deliver: { _ in },
            permission: { .granted }
        )

        #expect(controller.isTranscriptExpanded == false)
        controller.toggleTranscriptExpansion()
        #expect(controller.isTranscriptExpanded == true)
        controller.toggleTranscriptExpansion()
        #expect(controller.isTranscriptExpanded == false)
    }

    @Test("una sesión nueva arranca SIEMPRE contraída")
    func aNewSessionStartsCollapsed() async throws {
        let controller = DictationController(
            engine: DictationControllerTests.FakeEngine(
                session: DictationControllerTests.FakeSession()
            ),
            gesture: HoldGesture(watchedFlags: [.command], threshold: .milliseconds(50)),
            deliver: { _ in },
            permission: { .granted }
        )
        controller.toggleTranscriptExpansion()

        controller.startWithoutGesture(locale: Locale(identifier: "es-ES"), mode: .live)
        await DictationControllerTests.waitUntil { controller.state.isMicrophoneOpen }

        // The expansion belonged to the previous transcript; inheriting it would
        // open the next dictation with ten lines of empty banner.
        #expect(controller.isTranscriptExpanded == false)
    }
}

/// The expanded window's height decision, asserted against the same measuring
/// machinery that paints it.
@Suite("Altura del transcript expandido")
@MainActor
struct ExpandedTranscriptHeightTests {

    static var lineHeight: CGFloat {
        let font = NSFont.systemFont(ofSize: 13)
        // The flow layout adds its line spacing to every line; the height must
        // account for it or the tenth line gets clipped by exactly that gap.
        return ceil(font.ascender - font.descender + font.leading)
            + ExpandedTranscript.lineSpacing
    }

    @Test("una línea ocupa una línea, no el tope")
    func shortTextHugsItsContent() {
        #expect(ExpandedTranscript.height(for: "hola") == Self.lineHeight)
    }

    @Test("el tope son diez líneas aunque el texto siga")
    func tallTextIsCapped() {
        let text = Array(repeating: "una frase que ocupa espacio de sobra", count: 60)
            .joined(separator: " ")
        #expect(
            ExpandedTranscript.height(for: text)
                == CGFloat(ExpandedTranscript.maxLines) * Self.lineHeight
        )
    }

    @Test("pasado el límite de medición se asume el tope sin medir")
    func hugeTextSkipsMeasuring() {
        let text = String(repeating: "a", count: ExpandedTranscript.measureLimit + 1)
        #expect(
            ExpandedTranscript.height(for: text)
                == CGFloat(ExpandedTranscript.maxLines) * Self.lineHeight
        )
    }
}

/// The gate that decides what automatic learning may keep.
@Suite("Qué correcciones son vocabulario")
struct DictationLearningTests {

    @Test("una o dos palabras por lado es un término")
    func shortSubstitutionsAreLearnable() {
        #expect(DictationLearning.isLearnable(original: "antropic", corrected: "Anthropic"))
        #expect(DictationLearning.isLearnable(original: "visual estudio", corrected: "Visual Studio"))
    }

    @Test("cambiar solo las mayúsculas también es corregir")
    func caseOnlyIsLearnable() {
        #expect(DictationLearning.isLearnable(original: "poesía", corrected: "Poesía"))
    }

    @Test("tres palabras ya son redacción, no vocabulario")
    func rewritesAreNotLearnable() {
        #expect(!DictationLearning.isLearnable(
            original: "lo que dije antes",
            corrected: "otra cosa distinta"
        ))
        #expect(!DictationLearning.isLearnable(original: "palabra", corrected: "tres palabras ahora"))
    }

    @Test("sin cambio no hay nada que aprender")
    func identicalSidesTeachNothing() {
        #expect(!DictationLearning.isLearnable(original: "igual", corrected: "igual"))
        #expect(!DictationLearning.isLearnable(original: "  igual ", corrected: "igual"))
    }

    @Test("vacíos, kilométricos o con salto de línea quedan fuera")
    func degenerateEditsAreRejected() {
        #expect(!DictationLearning.isLearnable(original: "", corrected: "algo"))
        #expect(!DictationLearning.isLearnable(original: "algo", corrected: ""))
        let long = String(repeating: "a", count: DictationLearning.maximumTermLength + 1)
        #expect(!DictationLearning.isLearnable(original: long, corrected: "corto"))
        #expect(!DictationLearning.isLearnable(original: "dos\nlíneas", corrected: "una"))
    }
}

/// The inline edit, end to end: text now, engine later, dictionary maybe.
@Suite("Edición inline durante el dictado")
@MainActor
struct DictationEditingTests {

    static func makeDictionary() -> PersonalDictionary {
        PersonalDictionary(
            directory: FileManager.default.temporaryDirectory
                .appending(path: "ambar-dictionary-tests-\(UUID().uuidString)")
        )
    }

    /// A controller listening over a fragment whose firm/volatile split is explicit.
    static func makeController(
        fragmentText: String,
        volatileCharacters: Int,
        dictionary: PersonalDictionary,
        learns: Bool = true,
        feedback: Duration = DictationController.defaultLearningFeedbackDuration,
        deliver: @escaping @MainActor (Transcript) -> Void = { _ in },
        announcer: @escaping @MainActor (String, AnnouncementUrgency) -> Void = { _, _ in }
    ) -> DictationController {
        DictationController(
            engine: DictationControllerTests.FakeEngine(
                session: TranscriptExpansionTests.BoundarySession(
                    fragment: TranscriptFragment(
                        text: fragmentText,
                        isVolatile: true,
                        volatileCharacterCount: volatileCharacters
                    )
                )
            ),
            gesture: HoldGesture(watchedFlags: [.command], threshold: .milliseconds(50)),
            deliver: deliver,
            permission: { .granted },
            vocabulary: dictionary,
            learnsVocabulary: { learns },
            learningFeedbackDuration: feedback,
            announcer: announcer
        )
    }

    @Test("la edición corrige el texto visible en TODAS sus apariciones")
    func editCorrectsTheVisibleText() async throws {
        let controller = Self.makeController(
            fragmentText: "antropic habla de antropic",
            volatileCharacters: 0,
            dictionary: Self.makeDictionary()
        )
        controller.startWithoutGesture(locale: Locale(identifier: "es-ES"), mode: .live)
        await DictationControllerTests.waitUntil { !controller.liveText.isEmpty }

        controller.applyEdit(original: "antropic", corrected: "Anthropic")

        #expect(controller.liveText == "Anthropic habla de Anthropic")
        #expect(controller.sessionCorrections == [
            VocabularyCorrector.Rule(from: "antropic", to: "Anthropic")
        ])
    }

    @Test("la edición corrige también la cola, y la frontera se mueve con ella")
    func editReachesTheVolatileTail() async throws {
        let controller = Self.makeController(
            fragmentText: "antropic dice antropic ahora",
            volatileCharacters: " antropic ahora".count,
            dictionary: Self.makeDictionary()
        )
        controller.startWithoutGesture(locale: Locale(identifier: "es-ES"), mode: .live)
        await DictationControllerTests.waitUntil { !controller.liveText.isEmpty }

        controller.applyEdit(original: "antropic", corrected: "Anthropic")

        // Both occurrences correct. Skipping the tail was a real defect: a correction
        // made mid-sentence did nothing visible until the next word arrived — and
        // nothing at all if the speaker had stopped. The rule lives in the session, so
        // this is exactly what the next fragment would paint anyway.
        #expect(controller.liveText == "Anthropic dice Anthropic ahora")
        // The tail grew by the same character the correction added, and the boundary
        // must follow it — a stale count would put the firm/volatile split inside a word.
        #expect(controller.liveVolatileCharacters == " Anthropic ahora".count)
    }

    @Test("la entrega respeta la edición, también en lo que era cola")
    func deliveryHonorsTheEdit() async throws {
        let delivered = TestBox<Transcript?>(nil)
        let controller = Self.makeController(
            fragmentText: "antropic dice antropic ahora",
            volatileCharacters: " antropic ahora".count,
            dictionary: Self.makeDictionary(),
            deliver: { delivered.value = $0 }
        )
        controller.startWithoutGesture(locale: Locale(identifier: "es-ES"), mode: .live)
        await DictationControllerTests.waitUntil { !controller.liveText.isEmpty }

        controller.applyEdit(original: "antropic", corrected: "Anthropic")
        controller.stop()
        await DictationControllerTests.waitUntil { delivered.value != nil }

        // At delivery everything is final, so the rule now applies everywhere.
        #expect(delivered.value?.text == "Anthropic dice Anthropic ahora")
    }

    @Test("una corrección de término entra sola al diccionario, y se anuncia")
    func learnableEditEntersTheDictionary() async throws {
        let dictionary = Self.makeDictionary()
        let announced = TestBox<[String]>([])
        let controller = Self.makeController(
            fragmentText: "habla de antropic",
            volatileCharacters: 0,
            dictionary: dictionary,
            announcer: { text, _ in announced.value.append(text) }
        )
        controller.startWithoutGesture(locale: Locale(identifier: "es-ES"), mode: .live)
        await DictationControllerTests.waitUntil { !controller.liveText.isEmpty }

        controller.applyEdit(original: "antropic", corrected: "Anthropic")

        #expect(dictionary.entries.count == 1)
        #expect(dictionary.entries[0].written == "Anthropic")
        #expect(dictionary.entries[0].heard == ["antropic"])
        #expect(controller.recentLearning?.entry.written == "Anthropic")
        // The screen shows a pill; VoiceOver must receive the same fact.
        #expect(announced.value.contains { $0.contains("Anthropic") })
    }

    @Test("una reescritura larga corrige el texto pero NO aprende")
    func rewritesApplyWithoutLearning() async throws {
        let dictionary = Self.makeDictionary()
        let controller = Self.makeController(
            fragmentText: "lo que dije antes queda",
            volatileCharacters: 0,
            dictionary: dictionary
        )
        controller.startWithoutGesture(locale: Locale(identifier: "es-ES"), mode: .live)
        await DictationControllerTests.waitUntil { !controller.liveText.isEmpty }

        controller.applyEdit(original: "lo que dije antes", corrected: "otra cosa distinta")

        #expect(controller.liveText == "otra cosa distinta queda")
        #expect(dictionary.entries.isEmpty)
        #expect(controller.recentLearning == nil)
    }

    @Test("con el interruptor apagado se corrige, pero no se guarda nada")
    func learningCanBeSwitchedOff() async throws {
        let dictionary = Self.makeDictionary()
        let controller = Self.makeController(
            fragmentText: "habla de antropic",
            volatileCharacters: 0,
            dictionary: dictionary,
            learns: false
        )
        controller.startWithoutGesture(locale: Locale(identifier: "es-ES"), mode: .live)
        await DictationControllerTests.waitUntil { !controller.liveText.isEmpty }

        controller.applyEdit(original: "antropic", corrected: "Anthropic")

        #expect(controller.liveText == "habla de Anthropic")
        #expect(dictionary.entries.isEmpty)
        #expect(controller.recentLearning == nil)
    }

    @Test("deshacer desde la píldora borra la entrada y mantiene el texto")
    func undoKeepsTheTextAndForgetsTheEntry() async throws {
        let dictionary = Self.makeDictionary()
        let controller = Self.makeController(
            fragmentText: "habla de antropic",
            volatileCharacters: 0,
            dictionary: dictionary
        )
        controller.startWithoutGesture(locale: Locale(identifier: "es-ES"), mode: .live)
        await DictationControllerTests.waitUntil { !controller.liveText.isEmpty }

        controller.applyEdit(original: "antropic", corrected: "Anthropic")
        controller.undoRecentLearning()

        #expect(controller.liveText == "habla de Anthropic", "undo reverts the LEARNING, not the edit")
        #expect(dictionary.entries.isEmpty)
        #expect(controller.recentLearning == nil)
    }

    @Test("la píldora se va sola cuando pasa su tiempo")
    func theFeedbackLeavesOnItsOwn() async throws {
        let dictionary = Self.makeDictionary()
        let controller = Self.makeController(
            fragmentText: "habla de antropic",
            volatileCharacters: 0,
            dictionary: dictionary,
            feedback: .milliseconds(40)
        )
        controller.startWithoutGesture(locale: Locale(identifier: "es-ES"), mode: .live)
        await DictationControllerTests.waitUntil { !controller.liveText.isEmpty }

        controller.applyEdit(original: "antropic", corrected: "Anthropic")
        #expect(controller.recentLearning != nil)

        await DictationControllerTests.waitUntil { controller.recentLearning == nil }
        #expect(controller.recentLearning == nil)
        // The entry stays: the pill leaving is not an undo.
        #expect(dictionary.entries.count == 1)
    }
}

/// The word the editor actually opens when a token carries punctuation.
@Suite("Núcleo editable de un token")
struct EditableCoreTests {

    @Test("la puntuación pegada no entra al editor")
    func punctuationIsStripped() {
        #expect(ExpandedTranscript.editableCore(of: "antropic,") == "antropic")
        #expect(ExpandedTranscript.editableCore(of: "«antropic»") == "antropic")
        #expect(ExpandedTranscript.editableCore(of: "¿antropic?") == "antropic")
    }

    @Test("los símbolos que SON parte del término sobreviven")
    func symbolsSurvive() {
        // "+" is a math symbol, not punctuation: "c++" must edit as "c++".
        #expect(ExpandedTranscript.editableCore(of: "c++") == "c++")
    }
}

/// The learning switch as Settings persists it.
@Suite("Interruptor de aprendizaje en Ajustes")
@MainActor
struct DictionaryLearningSettingTests {

    private func makeSettings() -> Settings {
        let suite = "dictionary-learning-tests-\(UUID().uuidString)"
        return Settings(defaults: UserDefaults(suiteName: suite)!)
    }

    @Test("nace encendido: corregir sin guardar sería corregir dos veces")
    func learningIsOnByDefault() {
        #expect(makeSettings().isDictionaryLearningEnabled == true)
    }

    @Test("apagarlo persiste")
    func switchingOffPersists() {
        let settings = makeSettings()
        settings.isDictionaryLearningEnabled = false
        #expect(settings.isDictionaryLearningEnabled == false)
    }
}

/// The three gates that made inline editing unreachable in the first build.
///
/// Each one failed silently — the click landed, nothing happened — so each gets an
/// assertion. They are the difference between a feature that exists and one that
/// can be used.
@Suite("Puertas de la edición inline")
@MainActor
struct InlineEditingReachabilityTests {

    private func makeController() -> DictationController {
        DictationController(
            engine: DictationControllerTests.FakeEngine(
                session: DictationControllerTests.FakeSession()
            ),
            gesture: HoldGesture(watchedFlags: [.command], threshold: .milliseconds(50)),
            deliver: { _ in },
            permission: { .granted }
        )
    }

    @Test("el editor abierto se declara, para que el panel suelte el teclado")
    func editingIsAnnouncedToThePanel() {
        let controller = makeController()
        #expect(controller.isEditingWord == false)

        controller.setWordEditing(true)
        // The panel's key monitor reads exactly this: without it, ⏎ stopped the
        // dictation instead of committing, and ⎋ closed the whole panel.
        #expect(controller.isEditingWord == true)

        controller.setWordEditing(false)
        #expect(controller.isEditingWord == false)
    }

    @Test("contraer el transcript devuelve el teclado al panel")
    func collapsingReleasesTheKeyboard() {
        let controller = makeController()
        controller.toggleTranscriptExpansion()
        controller.setWordEditing(true)

        controller.toggleTranscriptExpansion()

        // Otherwise the panel keeps yielding its keys to a field that no longer
        // exists, and ⎋ silently stops closing the panel.
        #expect(controller.isTranscriptExpanded == false)
        #expect(controller.isEditingWord == false)
    }

    @Test("una sesión nueva no hereda un editor abierto")
    func aNewSessionClearsTheEditor() async throws {
        let controller = makeController()
        controller.setWordEditing(true)

        controller.startWithoutGesture(locale: Locale(identifier: "es-ES"), mode: .live)
        await DictationControllerTests.waitUntil { controller.state.isMicrophoneOpen }

        #expect(controller.isEditingWord == false)
    }
}
