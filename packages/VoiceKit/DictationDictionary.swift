import Foundation

/// One term the user taught dictation.
///
/// `written` is the form that must reach the document; `heard` records every
/// misrecognition observed for it. Keeping the misrecognitions — instead of just the
/// correct form — is what makes the learning loop close: they feed the deterministic
/// replacement layer that fixes what the engine keeps getting wrong, and they are shown
/// in Settings so the user can see WHY an entry exists before deleting it.
public struct DictionaryEntry: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var written: String
    /// Misrecognized forms, most recent last. Deduplicated case-insensitively.
    public var heard: [String]
    /// How many times this entry earned its place: once when learned, once per
    /// delivery in which one of its `heard` forms was actually replaced.
    public var uses: Int
    public var lastUsedAt: Date
    public let addedAt: Date

    public init(id: UUID, written: String, heard: [String], uses: Int, lastUsedAt: Date, addedAt: Date) {
        self.id = id
        self.written = written
        self.heard = heard
        self.uses = uses
        self.lastUsedAt = lastUsedAt
        self.addedAt = addedAt
    }
}

/// The dictation dictionary as a file: `dictionary.json`, a JSON array of
/// `DictionaryEntry` with ISO 8601 dates. The app that owns it writes it; any app that
/// dictates for the same user can read it, so a word taught once is written right
/// everywhere (Quill reads Ámbar's, EFFICIENCY.md E8).
public enum DictationDictionary {
    public static let fileName = "dictionary.json"

    /// The entries in `url`; none when the file is missing or unreadable. A corrupt file
    /// yields an empty dictionary, not a crash: the dictionary is an accelerator, and
    /// dictation must keep working without it.
    public static func load(from url: URL) -> [DictionaryEntry] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([DictionaryEntry].self, from: data)) ?? []
    }

    /// The written forms, best first, capped to the engine's documented limit.
    ///
    /// Ranking is uses-then-recency: an entry that keeps earning replacements matters
    /// more than one taught once months ago, so when the list outgrows the 100-slot
    /// cap it is the stale tail that falls off — the self-curating part of the loop.
    public static func contextualStrings(_ entries: [DictionaryEntry]) -> [String] {
        entries
            .sorted { lhs, rhs in
                if lhs.uses != rhs.uses { return lhs.uses > rhs.uses }
                return lhs.lastUsedAt > rhs.lastUsedAt
            }
            .prefix(SpeechSession.contextualStringsLimit)
            .map(\.written)
    }

    /// Every misrecognition → correct form pair, for the deterministic layer.
    public static func replacementRules(_ entries: [DictionaryEntry]) -> [VocabularyCorrector.Rule] {
        entries.flatMap { entry in
            entry.heard.map { VocabularyCorrector.Rule(from: $0, to: entry.written) }
        }
    }
}

/// Deterministic word replacement over transcribed text.
///
/// This is the layer that guarantees the correction even when the engine bias does
/// not: whatever the engine still gets wrong, the known misrecognitions are rewritten
/// before the text is shown or delivered. Pure and stateless so it can be asserted
/// exhaustively without an engine.
public enum VocabularyCorrector {
    public struct Rule: Equatable, Sendable {
        public let from: String
        public let to: String

        public init(from: String, to: String) {
            self.from = from
            self.to = to
        }
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
    public static func apply(_ rules: [Rule], to text: String) -> (text: String, applied: Set<String>) {
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
