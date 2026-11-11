import Foundation
import Observation
import VoiceKit

/// The user's personal vocabulary: learned from corrections, editable in Settings.
///
/// Persistence is a JSON file under Application Support, not UserDefaults and not the
/// history database. Not UserDefaults because the list grows without bound and defaults
/// are read wholesale at launch; not the history database because the dictionary must
/// survive a full history wipe — it is something the user taught the app, not something
/// the app captured.
@MainActor
@Observable
final class PersonalDictionary {
    private(set) var entries: [DictionaryEntry] = []

    private let fileURL: URL

    /// - Parameter directory: where `dictionary.json` lives. Injectable so tests get an
    ///   isolated store; production passes `AppModel.applicationSupportDirectory()`.
    init(directory: URL) {
        self.fileURL = directory.appending(path: DictationDictionary.fileName)
        load()
    }

    // MARK: - Learning

    /// Records that `heard` should have been `written`. Returns the entry, so the
    /// interface can name what it just learned — and offer to undo it.
    ///
    /// Upserts by `written`, compared case-insensitively: correcting "antropic" and
    /// later "Antropic" must grow ONE entry's heard list, not create near-duplicates
    /// that each occupy one of the 100 contextual-string slots.
    @discardableResult
    func learn(heard: String, written: String) -> DictionaryEntry? {
        let written = written.trimmingCharacters(in: .whitespacesAndNewlines)
        let heard = heard.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !written.isEmpty else { return nil }

        if let index = indexOfEntry(written: written) {
            var entry = entries[index]
            // The user's latest spelling wins — correcting "poesía" to "Poesía" is a
            // case fix, and keeping the old casing would keep delivering the mistake.
            entry.written = written
            if !heard.isEmpty, !entry.heard.contains(where: { $0.caseInsensitiveCompare(heard) == .orderedSame }),
               heard.caseInsensitiveCompare(written) != .orderedSame {
                entry.heard.append(heard)
            }
            entry.uses += 1
            entry.lastUsedAt = Date()
            entries[index] = entry
            save()
            return entry
        }

        let entry = DictionaryEntry(
            id: UUID(),
            written: written,
            // A heard form identical to the written one carries no information and
            // would produce a self-replacement rule.
            heard: heard.isEmpty || heard.caseInsensitiveCompare(written) == .orderedSame ? [] : [heard],
            uses: 1,
            lastUsedAt: Date(),
            addedAt: Date()
        )
        entries.append(entry)
        save()
        return entry
    }

    /// Manual addition from Settings. Same upsert semantics as `learn`.
    @discardableResult
    func add(written: String, heard: String? = nil) -> DictionaryEntry? {
        learn(heard: heard ?? "", written: written)
    }

    func remove(id: UUID) {
        entries.removeAll { $0.id == id }
        save()
    }

    /// Undo of a just-learned correction: removes the entry only if the learning
    /// CREATED it, otherwise rolls back the use it recorded. Deleting a pre-existing
    /// entry because its latest correction was undone would throw away history the
    /// user built across sessions.
    func undoLearning(of entry: DictionaryEntry, heard: String) {
        guard let index = entries.firstIndex(where: { $0.id == entry.id }) else { return }
        var current = entries[index]
        if current.uses <= 1 {
            entries.remove(at: index)
        } else {
            current.uses -= 1
            let heard = heard.trimmingCharacters(in: .whitespacesAndNewlines)
            current.heard.removeAll { $0.caseInsensitiveCompare(heard) == .orderedSame }
            entries[index] = current
        }
        save()
    }

    /// A delivery replaced one of this entry's heard forms: the entry earned a use.
    /// Called once per delivery, not per fragment — fragments repeat the same text
    /// many times per second and would inflate the ranking within one breath.
    func noteUse(ofWritten written: String) {
        guard let index = indexOfEntry(written: written) else { return }
        entries[index].uses += 1
        entries[index].lastUsedAt = Date()
        save()
    }

    // MARK: - What the engine and the corrector consume

    /// The written forms, best first, capped to the engine's documented limit
    /// (`DictationDictionary.contextualStrings`).
    func contextualStrings() -> [String] { DictationDictionary.contextualStrings(entries) }

    /// Every misrecognition → correct form pair, for the deterministic layer.
    func replacementRules() -> [VocabularyCorrector.Rule] { DictationDictionary.replacementRules(entries) }

    // MARK: - Persistence

    private func indexOfEntry(written: String) -> Int? {
        entries.firstIndex { $0.written.caseInsensitiveCompare(written) == .orderedSame }
    }

    private func load() {
        entries = DictationDictionary.load(from: fileURL)
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(entries) else { return }
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        // Atomic: a crash mid-write must not destroy the vocabulary the user built.
        try? data.write(to: fileURL, options: .atomic)
    }
}
