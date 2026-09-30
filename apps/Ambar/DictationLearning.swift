import Foundation

/// Decides whether an inline correction is vocabulary or just writing.
///
/// Saving happens automatically — there is no confirmation dialog — so this gate is
/// the only thing standing between the dictionary and garbage. The distinction it
/// draws: replacing one or two words with one or two words looks like teaching the
/// app a term ("antropic" → "Anthropic"); anything longer is the user REWRITING,
/// and rewrites must apply to the text without ever becoming a replacement rule —
/// a learned rewrite would silently rewrite every future dictation that happens to
/// contain the same phrase.
enum DictationLearning {
    /// Longest side of a correction that can still be a term, in characters.
    /// Brand names and jargon fit comfortably; half a sentence does not.
    static let maximumTermLength = 40

    /// Most words a side can have and still be a term. Two covers compound names
    /// ("Visual Studio"); three is already prose.
    static let maximumTermWords = 2

    static func isLearnable(original: String, corrected: String) -> Bool {
        let original = original.trimmingCharacters(in: .whitespacesAndNewlines)
        let corrected = corrected.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !original.isEmpty, !corrected.isEmpty else { return false }
        // Identical sides teach nothing. Case differences DO count as corrections:
        // "poesía" → "Poesía" is exactly the kind of term the dictionary is for.
        guard original != corrected else { return false }
        guard original.count <= maximumTermLength, corrected.count <= maximumTermLength else {
            return false
        }
        // A newline in either side means the edit crossed sentence structure.
        guard !original.contains(where: \.isNewline), !corrected.contains(where: \.isNewline) else {
            return false
        }
        return wordCount(of: original) <= maximumTermWords
            && wordCount(of: corrected) <= maximumTermWords
    }

    private static func wordCount(of text: String) -> Int {
        text.split(whereSeparator: \.isWhitespace).count
    }
}
