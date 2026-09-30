import AppKit
import GlassUI
import SwiftUI

/// The full transcript, unfolded inside the banner — and editable, word by word.
///
/// Four promises define it, each the answer to a way the obvious implementation
/// fails:
///
/// - **Bounded height.** It grows with the text up to ten lines and then scrolls
///   inside; without the cap, a long dictation would swallow the whole panel and
///   push the history out from under the user searching it.
/// - **Anchored to the tail.** New text keeps the view pinned to the end — the tail
///   is what confirms the engine is hearing right. But the pin releases the moment
///   the user scrolls up to read the beginning, and re-engages when they return to
///   the end: auto-scroll that fights the reader teaches them not to scroll.
/// - **The firm/volatile boundary stays visible AND enforced.** The hypothesis tail
///   keeps the dimmed-italic treatment of the collapsed view, and it is the part
///   that cannot be edited: the engine rewrites it wholesale on its next result, so
///   an edit there would be silently overwritten within the second.
/// - **Editing is a double-click, in place.** The word becomes a text field where it
///   stands; ⏎ commits, ⎋ cancels. What the commit MEANS — replace everywhere,
///   maybe learn — is the controller's decision, not this view's.
struct ExpandedTranscript: View {
    let text: String
    /// Characters at the end of `text` that are still the engine's hypothesis.
    let volatileCharacters: Int
    /// Whether the newest fragment was a hypothesis (drives the tail styling).
    let isVolatile: Bool
    /// Called with (original, corrected) when the user commits an inline edit.
    var onEditWord: ((String, String) -> Void)?
    /// Reports whether an inline editor is open, so the panel can hand over the
    /// keyboard: its key monitor claims ⏎, ⎋ and the arrows, which are precisely
    /// what a text field needs.
    var onEditingChanged: ((Bool) -> Void)?

    /// Whether new text keeps the view pinned to the end.
    @State private var followsTail = true
    /// The word being edited, if any.
    @State private var editing: EditingWord?
    @FocusState private var editorFocused: Bool
    @State private var hoveredToken: Int?

    private var accessibility: AccessibilityPreferences { .shared }

    struct EditingWord: Equatable {
        let token: Int
        let original: String
        var draft: String
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 0) {
                    FlowLayout(spacing: Self.wordSpacing, lineSpacing: Self.lineSpacing) {
                        ForEach(tokens) { token in
                            tokenView(token)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Color.clear.frame(height: 1).id(Self.tailAnchor)
                }
            }
            .frame(height: Self.height(for: text))
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentOffset.y + geometry.containerSize.height
                    >= geometry.contentSize.height - Self.tailTolerance
            } action: { _, isNearTail in
                followsTail = isNearTail
            }
            .onChange(of: text) {
                guard followsTail, editing == nil else { return }
                proxy.scrollTo(Self.tailAnchor, anchor: .bottom)
            }
            // The view opens where the collapsed window was looking: at the end.
            .onAppear { proxy.scrollTo(Self.tailAnchor, anchor: .bottom) }
            // A transcript that goes away with an editor open must hand the keyboard
            // back, or ⎋ would stop closing the panel with nothing on screen to explain
            // it. The controller clears its own flag too; this covers the view dying
            // for reasons the controller never hears about.
            .onDisappear { onEditingChanged?(false) }
        }
    }

    // MARK: - Tokens

    /// One word of the transcript, with everything the view needs to paint it.
    struct Token: Identifiable, Equatable {
        let id: Int
        let word: String
        let isVolatile: Bool
    }

    /// The transcript as words. Indices are stable for the firm prefix — the engine
    /// only appends to it — which is what keeps an open editor from jumping to a
    /// different word when a new fragment arrives.
    private var tokens: [Token] {
        let boundary = text.index(
            text.endIndex,
            offsetBy: -min(max(volatileCharacters, 0), text.count)
        )
        let firm = text[..<boundary].split(whereSeparator: \.isWhitespace).map(String.init)
        let tail = text[boundary...].split(whereSeparator: \.isWhitespace).map(String.init)
        return firm.enumerated().map { Token(id: $0.offset, word: $0.element, isVolatile: false) }
            + tail.enumerated().map {
                Token(id: firm.count + $0.offset, word: $0.element, isVolatile: true)
            }
    }

    @ViewBuilder
    private func tokenView(_ token: Token) -> some View {
        if let editing, editing.token == token.id {
            editorField(for: editing)
        } else {
            wordView(token)
        }
    }

    private func wordView(_ token: Token) -> some View {
        let style = DictationBanner.transcriptStyle(
            isVolatile: isVolatile,
            increaseContrast: accessibility.increaseContrast
        )
        // EVERY word is editable, hypothesis included. Refusing the tail looked
        // prudent — the engine rewrites it wholesale on the next result — but it made
        // the feature unusable for its stated purpose: mid-sentence, the sentence being
        // spoken is entirely volatile, so "correct while speaking" had nothing to
        // correct. It is safe because the correction becomes a session RULE, which
        // re-applies to every later fragment: the engine may rewrite the word, and the
        // rule fixes it again. Styling still marks the tail as a hypothesis.
        let editable = onEditWord != nil
        return Text(token.word)
            .font(token.isVolatile && style.italic ? .system(size: 13).italic() : .system(size: 13))
            .foregroundStyle(
                Color(nsColor: .labelColor).opacity(token.isVolatile ? style.opacity : 1)
            )
            // The hover tint is the discoverability of a hidden gesture: it says
            // "this word is an object" before the user ever double-clicks one.
            .background(
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color(nsColor: .labelColor).opacity(
                        editable && hoveredToken == token.id ? 0.12 : 0
                    ))
                    .padding(-2)
            )
            .onHover { inside in
                guard editable else { return }
                hoveredToken = inside ? token.id : (hoveredToken == token.id ? nil : hoveredToken)
            }
            .onTapGesture(count: 2) {
                guard editable else { return }
                let core = Self.editableCore(of: token.word)
                guard !core.isEmpty else { return }
                editing = EditingWord(token: token.id, original: core, draft: core)
                editorFocused = true
                onEditingChanged?(true)
            }
            .help(
                editable
                    ? String(localized: "dictation.transcript.hint", bundle: .localized)
                    : ""
            )
    }

    private func editorField(for word: EditingWord) -> some View {
        TextField(
            "",
            text: Binding(
                get: { editing?.draft ?? word.draft },
                set: { editing?.draft = $0 }
            )
        )
        .textFieldStyle(.plain)
        .font(.system(size: 13))
        .padding(.horizontal, 3)
        .background(
            RoundedRectangle(cornerRadius: 3)
                .fill(Color(nsColor: .labelColor).opacity(0.12))
                .padding(.vertical, -1)
        )
        .fixedSize()
        .focused($editorFocused)
        .onSubmit { commitEdit() }
        // ⎋ cancels without committing: the field disappears and the word stays.
        .onExitCommand {
            editing = nil
            onEditingChanged?(false)
        }
        // Losing focus commits too — clicking elsewhere to "get out" must not
        // silently discard a correction the user already typed.
        .onChange(of: editorFocused) {
            guard !editorFocused, editing != nil else { return }
            commitEdit()
        }
    }

    private func commitEdit() {
        onEditingChanged?(false)
        guard let editing else { return }
        self.editing = nil
        let corrected = editing.draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !corrected.isEmpty, corrected != editing.original else { return }
        onEditWord?(editing.original, corrected)
    }

    /// The word without its surrounding punctuation: "antropic," edits as
    /// "antropic". `.punctuationCharacters` deliberately — it excludes math
    /// symbols, so "c++" survives whole.
    nonisolated static func editableCore(of token: String) -> String {
        token.trimmingCharacters(in: .punctuationCharacters)
    }

    // MARK: - Geometry

    private static let tailAnchor = "transcript-tail"
    static let wordSpacing: CGFloat = 4
    static let lineSpacing: CGFloat = 3

    /// How close to the end still counts as "following the tail", in points.
    /// One line of slack: pixel-exact equality would release the pin on every
    /// layout rounding and the view would silently stop following.
    static let tailTolerance: CGFloat = 24

    /// The expanded window's ceiling, in lines.
    ///
    /// Ten: enough to read a paragraph of context around the tail, small enough
    /// that the history list — the panel's reason to exist — stays usable below.
    static let maxLines = 10

    /// Text length beyond which the height measurement stops being exact.
    ///
    /// Measuring line breaks costs work proportional to the text, on every render.
    /// Past this size the transcript cannot possibly fit in ten lines, so the exact
    /// count buys nothing — same reasoning as `LiveTranscriptWindow.scanLimit`.
    static let measureLimit = 2_000

    /// The height the scroll view takes: the text's real height up to `maxLines`.
    ///
    /// Measured with the same machinery the collapsed window uses. The word flow
    /// spaces lines a hair differently than a `Text` block, so this is approximate
    /// by design — a mismatch costs a few points of scroll position, not a
    /// truncated line, because the scroll view absorbs the difference. That is why
    /// this can be approximate where `LiveTranscriptWindow` could not.
    static func height(for text: String) -> CGFloat {
        let font = NSFont.systemFont(ofSize: 13)
        let lineHeight = ceil(font.ascender - font.descender + font.leading) + lineSpacing
        guard text.count <= measureLimit else { return CGFloat(maxLines) * lineHeight }
        let lines = LiveTranscriptWindow.lineRanges(
            of: text,
            width: DictationBanner.liveTextWidth,
            font: font
        ).count
        return CGFloat(min(max(lines, 1), maxLines)) * lineHeight
    }
}

/// A leading-aligned wrapping layout: words flow left to right and break onto new
/// lines like text. SwiftUI has no built-in equivalent, and faking it with `Text`
/// concatenation loses per-word hit targets, which the editor is built on.
struct FlowLayout: Layout {
    var spacing: CGFloat = 4
    var lineSpacing: CGFloat = 2

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrangement(for: subviews, width: proposal.width ?? .infinity).size
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        let frames = arrangement(for: subviews, width: bounds.width).frames
        for (subview, frame) in zip(subviews, frames) {
            subview.place(
                at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                proposal: ProposedViewSize(frame.size)
            )
        }
    }

    private func arrangement(
        for subviews: Subviews,
        width: CGFloat
    ) -> (frames: [CGRect], size: CGSize) {
        var frames: [CGRect] = []
        var origin = CGPoint.zero
        var lineHeight: CGFloat = 0
        var maxX: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if origin.x > 0, origin.x + size.width > width {
                origin.x = 0
                origin.y += lineHeight + lineSpacing
                lineHeight = 0
            }
            frames.append(CGRect(origin: origin, size: size))
            origin.x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
            maxX = max(maxX, origin.x - spacing)
        }
        return (frames, CGSize(width: maxX, height: origin.y + lineHeight))
    }
}
