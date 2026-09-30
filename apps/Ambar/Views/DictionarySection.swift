import GlassUI
import SwiftUI

/// Settings section for the personal dictation vocabulary.
///
/// This screen is what makes automatic learning honest: entries save themselves
/// during dictation, so the ONLY place to see what accumulated — and to remove a
/// term learned by mistake — is here. Each row therefore shows the entry's whole
/// story: what the engine heard, how often the entry earned a replacement, and
/// when it last did. Without those three, a list of bare words gives the user no
/// way to judge which entry is the mislearned one.
struct DictionarySection: View {
    @Bindable var model: AppModel
    @State private var newWritten = ""
    @State private var newHeard = ""

    private var settings: Settings { model.settings }
    private var dictionary: PersonalDictionary { model.personalDictionary }

    var body: some View {
        Section(String(localized: "settings.dictionary", bundle: .localized)) {
            Toggle(
                String(localized: "settings.dictionary.learning", bundle: .localized),
                isOn: Binding(
                    get: { settings.isDictionaryLearningEnabled },
                    set: { settings.isDictionaryLearningEnabled = $0 }
                )
            )
            // Same reason as every other toggle in this window: inside a grouped
            // Form, SwiftUI leaves the checkbox unnamed for VoiceOver.
            .accessibilityLabel(
                String(localized: "settings.dictionary.learning", bundle: .localized)
            )
            Text(String(localized: "settings.dictionary.learning_help", bundle: .localized))
                .font(.system(size: 11))
                .foregroundStyle(Color.informational)

            if dictionary.entries.isEmpty {
                Text(String(localized: "settings.dictionary.empty", bundle: .localized))
                    .font(.system(size: 11))
                    .foregroundStyle(Color.informational)
            } else {
                Text(
                    String(
                        format: String(
                            localized: "settings.dictionary.count",
                            bundle: .localized
                        ),
                        dictionary.entries.count
                    )
                )
                .font(.system(size: 11))
                .foregroundStyle(Color.informational)

                // Most recently used first: the entry the user is looking for is
                // almost always the one dictation just touched.
                ForEach(
                    dictionary.entries.sorted { $0.lastUsedAt > $1.lastUsedAt }
                ) { entry in
                    row(for: entry)
                }
            }

            addControls
        }
    }

    private func row(for entry: DictionaryEntry) -> some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.written)
                    .font(.system(size: 13, weight: .medium))
                Text(detail(for: entry))
                    .font(.system(size: 11))
                    .foregroundStyle(Color.informational)
            }
            Spacer()
            Button {
                dictionary.remove(id: entry.id)
            } label: {
                Image(systemName: "trash")
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            // The name carries the TERM: ten unnamed delete buttons in a list are
            // indistinguishable to VoiceOver, and this one destroys user data.
            .accessibilityLabel(
                String(
                    format: String(localized: "settings.dictionary.delete", bundle: .localized),
                    entry.written
                )
            )
            .help(
                String(
                    format: String(localized: "settings.dictionary.delete", bundle: .localized),
                    entry.written
                )
            )
        }
    }

    /// The entry's story in one line: heard forms, uses, recency.
    ///
    /// Composed from separately localized pieces joined by "·" — a plural-aware
    /// single format string per language for a three-part sentence is where
    /// translations quietly break.
    private func detail(for entry: DictionaryEntry) -> String {
        let uses = String(
            format: String(localized: "settings.dictionary.uses", bundle: .localized),
            entry.uses
        )
        let when = Self.relativeFormatter.localizedString(
            for: entry.lastUsedAt,
            relativeTo: Date()
        )
        guard !entry.heard.isEmpty else { return "\(uses) · \(when)" }
        let heard = String(
            format: String(localized: "settings.dictionary.heard_as", bundle: .localized),
            entry.heard.joined(separator: ", ")
        )
        return "\(heard) · \(uses) · \(when)"
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter
    }()

    /// Manual addition: the written form, and optionally how the engine mis-hears
    /// it. For terms the user KNOWS will fail before dictating them even once.
    private var addControls: some View {
        HStack(spacing: 6) {
            TextField(
                String(localized: "settings.dictionary.add.written", bundle: .localized),
                text: $newWritten
            )
            .textFieldStyle(.roundedBorder)
            .frame(maxWidth: 160)
            TextField(
                String(localized: "settings.dictionary.add.heard", bundle: .localized),
                text: $newHeard
            )
            .textFieldStyle(.roundedBorder)
            .frame(maxWidth: 220)
            Button(String(localized: "settings.dictionary.add.confirm", bundle: .localized)) {
                addTerm()
            }
            .buttonStyle(.remedy)
            .disabled(newWritten.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    private func addTerm() {
        let written = newWritten.trimmingCharacters(in: .whitespaces)
        guard !written.isEmpty else { return }
        let heard = newHeard.trimmingCharacters(in: .whitespaces)
        dictionary.add(written: written, heard: heard.isEmpty ? nil : heard)
        newWritten = ""
        newHeard = ""
    }
}
