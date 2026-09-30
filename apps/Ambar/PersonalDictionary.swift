import Foundation
import Observation
import VoiceKit

/// One term the user taught the app.
///
/// `written` is the form that must reach the document; `heard` records every
/// misrecognition observed for it. Keeping the misrecognitions — instead of just the
/// correct form — is what makes the learning loop close: they feed the deterministic
/// replacement layer that fixes what the engine keeps getting wrong, and they are shown
/// in Settings so the user can see WHY an entry exists before deleting it.
struct DictionaryEntry: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    var written: String
    /// Misrecognized forms, most recent last. Deduplicated case-insensitively.
    var heard: [String]
    /// How many times this entry earned its place: once when learned, once per
    /// delivery in which one of its `heard` forms was actually replaced.
    var uses: Int
    var lastUsedAt: Date
    let addedAt: Date
}

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
        self.fileURL = directory.appending(path: "dictionary.json")
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

    /// The written forms, best first, capped to the engine's documented limit.
    ///
    /// Ranking is uses-then-recency: an entry that keeps earning replacements matters
    /// more than one taught once months ago, so when the list outgrows the 100-slot
    /// cap it is the stale tail that falls off — the self-curating part of the loop.
    func contextualStrings() -> [String] {
        entries
            .sorted { lhs, rhs in
                if lhs.uses != rhs.uses { return lhs.uses > rhs.uses }
                return lhs.lastUsedAt > rhs.lastUsedAt
            }
            .prefix(SpeechSession.contextualStringsLimit)
            .map(\.written)
    }

    /// Every misrecognition → correct form pair, for the deterministic layer.
    func replacementRules() -> [VocabularyCorrector.Rule] {
        entries.flatMap { entry in
            entry.heard.map { VocabularyCorrector.Rule(from: $0, to: entry.written) }
        }
    }

    // MARK: - Persistence

    private func indexOfEntry(written: String) -> Int? {
        entries.firstIndex { $0.written.caseInsensitiveCompare(written) == .orderedSame }
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        // A corrupt file yields an empty dictionary, not a crash: the dictionary is an
        // accelerator, and dictation must keep working without it.
        entries = (try? decoder.decode([DictionaryEntry].self, from: data)) ?? []
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

/// Deterministic word replacement over transcribed text.
///
/// This is the layer that guarantees the correction even when the engine bias does
/// not: whatever the engine still gets wrong, the known misrecognitions are rewritten
/// before the text is shown or delivered. Pure and stateless so it can be asserted
/// exhaustively without an engine.
enum VocabularyCorrector {
    struct Rule: Equatable, Sendable {
        let from: String
        let to: String
    }

    /// Applies every rule, whole-word and case-insensitive, and reports which
    /// replacements fired (by their `to` form) so the caller can credit the entries.
    ///
    /// Whole-word via letter/number lookaround, not `\b`: the rules carry accented
    /// vocabulary, and the lookaround states the actual invariant — "not glued to
    /// another letter or digit" — which is what keeps "Antropical" safe from an
    /// "Antropic" rule while still matching next to punctuation.
    ///
    /// A rule whose sides are byte-identical is skipped: it could never change the
    /// text and would report a phantom replacement. Case-only differences DO pass —
    /// "poesía" → "Poesía" is a real correction.
    static func apply(_ rules: [Rule], to text: String) -> (text: String, applied: Set<String>) {
        var result = text
        var applied: Set<String> = []
        for rule in rules {
            let from = rule.from.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !from.isEmpty, from != rule.to else { continue }
            let pattern = "(?<![\\p{L}\\p{N}])" + NSRegularExpression.escapedPattern(for: from)
                + "(?![\\p{L}\\p{N}])"
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
                continue
            }
            let range = NSRange(result.startIndex..., in: result)
            guard regex.firstMatch(in: result, range: range) != nil else { continue }
            let replaced = regex.stringByReplacingMatches(
                in: result,
                range: range,
                withTemplate: NSRegularExpression.escapedTemplate(for: rule.to)
            )
            // Matching is case-insensitive, so "Anthropic" already in the text matches
            // its own rule without changing anything: that is not a correction and must
            // not count as one.
            guard replaced != result else { continue }
            result = replaced
            applied.insert(rule.to)
        }
        return (result, applied)
    }
}
