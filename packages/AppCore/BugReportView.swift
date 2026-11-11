import AppKit
import SwiftUI

/// The bug report form (shared-control J-28), one window for every app: the fields, the two
/// attachments off until ticked, the exact JSON before sending, and what happened after.
///
/// Plain SwiftUI `Form` in the grouped style, the way the apps' Settings panes are built, so
/// it reads as part of macOS in any of them. The state is `BugReportForm`'s.
///
/// Shared-control S9 V2 (visual audit 5, 6, 7): the text areas take the card as their surface, the form
/// scrolls above a fixed bar of buttons, the privacy notice is the form's last footer at full width, and
/// the review shows what is sent as labelled values, with the exact JSON one click away.
public struct BugReportView: View {
    @Bindable var form: BugReportForm
    let appName: String
    let close: () -> Void

    public init(form: BugReportForm, appName: String, close: @escaping () -> Void) {
        self.form = form
        self.appName = appName
        self.close = close
    }

    public var body: some View {
        Group {
            switch form.phase {
            case .editing:
                editing
            case .reviewing(let preview):
                reviewing(preview)
            case .sending:
                sending
            case .sent:
                sent
            case .failed(let failure):
                failed(failure)
            }
        }
        .frame(minWidth: 480, idealWidth: 520, minHeight: 460, idealHeight: BugReportWindow.idealHeight)
        // Each step is said out loud and VoiceOver's cursor moves to its heading (S8 fix round, X4), as
        // the apps' permission windows announce a change.
        // Docs: https://developer.apple.com/documentation/accessibility/accessibilitynotification/announcement
        .onChange(of: form.phase) { _, phase in
            if let announcement = BugReportForm.announcement(for: phase) {
                AccessibilityNotification.Announcement(announcement).post()
            }
            headingFocused = phase != .editing
        }
    }

    /// VoiceOver's cursor on the new step's heading after each change.
    @AccessibilityFocusState private var headingFocused: Bool

    // MARK: Editing

    private var editing: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextEditor(text: $form.happened)
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: 72)
                        .accessibilityLabel(String(localized: "bugreport.happened.title", bundle: .localized))
                } header: {
                    Text(String(localized: "bugreport.happened.title", bundle: .localized))
                } footer: {
                    problem(for: [.nothingHappened, .happenedTooLong])
                }
                Section {
                    TextEditor(text: $form.expected)
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: 48)
                        .accessibilityLabel(String(localized: "bugreport.expected.title", bundle: .localized))
                } header: {
                    Text(String(localized: "bugreport.expected.title", bundle: .localized))
                } footer: {
                    problem(for: [.expectedTooLong])
                }
                Section {
                    TextField(String(localized: "bugreport.email.title", bundle: .localized), text: $form.email,
                              prompt: Text(String(localized: "bugreport.email.placeholder", bundle: .localized)))
                        .textContentType(.emailAddress)
                        .labelsHidden()
                        .accessibilityLabel(String(localized: "bugreport.email.title", bundle: .localized))
                } header: {
                    Text(String(localized: "bugreport.email.title", bundle: .localized))
                } footer: {
                    problem(for: [.emailMalformed])
                }
                Section {
                    Toggle(isOn: $form.attachLog) {
                        Text(String(localized: "bugreport.attach.log", bundle: .localized))
                        Text(String(localized: "bugreport.attach.log.detail \(appName)", bundle: .localized))
                    }
                    Toggle(isOn: $form.attachFacts) {
                        Text(String(localized: "bugreport.attach.facts", bundle: .localized))
                        Text(String(localized: "bugreport.attach.facts.detail", bundle: .localized))
                    }
                } header: {
                    Text(String(localized: "bugreport.attach.title", bundle: .localized))
                } footer: {
                    // Who keeps the report and for how long, under the choice it is about, at the form's
                    // full width rather than squeezed beside the buttons.
                    Text(form.configuration.privacyNotice)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .formStyle(.grouped)
            Divider()
            footer(note: nil) {
                Button(String(localized: "bugreport.cancel", bundle: .localized), role: .cancel, action: close)
                    .keyboardShortcut(.cancelAction)
                Button(String(localized: "bugreport.review", bundle: .localized)) { Task { await form.review() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!form.canReview)
                    // Why the button waits, for a pointer and for VoiceOver: an empty report.
                    .help(form.problems.contains(.nothingHappened)
                          ? String(localized: "bugreport.problem.nothing", bundle: .localized) : "")
            }
        }
    }

    /// The first problem among `kinds`, said under its field.
    @ViewBuilder
    private func problem(for kinds: [BugReportForm.Problem]) -> some View {
        if let found = form.problems.first(where: { kinds.contains($0) }), found != .nothingHappened {
            Label(Self.problemText(found), systemImage: "exclamationmark.circle")
                .foregroundStyle(.secondary)
        }
    }

    static func problemText(_ problem: BugReportForm.Problem) -> String {
        switch problem {
        case .nothingHappened: String(localized: "bugreport.problem.nothing", bundle: .localized)
        case .happenedTooLong, .expectedTooLong:
            String(localized: "bugreport.problem.tooLong \(BugReportLimits.text)", bundle: .localized)
        case .emailMalformed: String(localized: "bugreport.problem.email", bundle: .localized)
        }
    }

    // MARK: Reviewing

    private func reviewing(_ preview: String) -> some View {
        let payload = try? JSONDecoder().decode(BugReportPayload.self, from: Data(preview.utf8))
        return VStack(alignment: .leading, spacing: 0) {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(String(localized: "bugreport.preview.title", bundle: .localized))
                            .font(.headline)
                            .accessibilityAddTraits(.isHeader)
                            .accessibilityFocused($headingFocused)
                        Text(String(localized: "bugreport.preview.detail", bundle: .localized))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if let payload {
                    Section {
                        reviewed(String(localized: "bugreport.happened.title", bundle: .localized), payload.happened)
                        if let expected = payload.expected {
                            reviewed(String(localized: "bugreport.expected.title", bundle: .localized), expected)
                        }
                        if let email = payload.email {
                            reviewed(String(localized: "bugreport.email.title", bundle: .localized), email)
                        }
                        if let facts = payload.facts {
                            reviewed(String(localized: "bugreport.review.facts", bundle: .localized),
                                     [facts.appVersion, facts.macOS, facts.model, facts.language].joined(separator: " · "))
                        }
                        if let log = payload.log {
                            reviewed(String(localized: "bugreport.review.log", bundle: .localized), log, monospaced: true)
                        }
                    }
                }
                // What leaves, byte for byte: one click away, for whoever wants to read it.
                Section {
                    DisclosureGroup(String(localized: "bugreport.review.json", bundle: .localized)) {
                        Text(preview)
                            .font(.system(.callout, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .accessibilityLabel(String(localized: "bugreport.preview.label", bundle: .localized))
                    }
                }
            }
            .formStyle(.grouped)
            Divider()
            footer(note: nil) {
                Button(String(localized: "bugreport.back", bundle: .localized)) { form.edit() }
                    .keyboardShortcut(.cancelAction)
                Button(String(localized: "bugreport.send", bundle: .localized)) { Task { await form.submit() } }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    /// One value of the report as it is sent, under its label.
    private func reviewed(_ label: String, _ value: String, monospaced: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.callout)
                .foregroundStyle(.secondary)
            Text(value)
                .font(monospaced ? .system(.callout, design: .monospaced) : .body)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    // MARK: After

    private var sending: some View {
        ProgressView(String(localized: "bugreport.sending", bundle: .localized))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityFocused($headingFocused)
    }

    private var sent: some View {
        outcome(symbol: "checkmark.circle", title: String(localized: "bugreport.sent.title", bundle: .localized),
                detail: form.email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? String(localized: "bugreport.sent.noReply", bundle: .localized)
                    : String(localized: "bugreport.sent.reply \(form.email.trimmingCharacters(in: .whitespacesAndNewlines))",
                             bundle: .localized)) {
            Button(String(localized: "bugreport.another", bundle: .localized)) { form.startOver() }
            Button(String(localized: "bugreport.close", bundle: .localized)) {
                close()
                form.startOver()
            }
            .keyboardShortcut(.defaultAction)
        }
    }

    private func failed(_ failure: BugReportForm.Failure) -> some View {
        outcome(symbol: "exclamationmark.triangle", title: String(localized: "bugreport.failed.title", bundle: .localized),
                detail: Self.failureText(failure)) {
            Button(String(localized: "bugreport.back", bundle: .localized)) { form.edit() }
                .keyboardShortcut(.cancelAction)
            Button(String(localized: "bugreport.retry", bundle: .localized)) { Task { await form.submit() } }
                .keyboardShortcut(.defaultAction)
        }
    }

    static func failureText(_ failure: BugReportForm.Failure) -> String {
        switch failure {
        case .unreachable: String(localized: "bugreport.failed.unreachable", bundle: .localized)
        case .refused: String(localized: "bugreport.failed.refused", bundle: .localized)
        case .busy: String(localized: "bugreport.failed.busy", bundle: .localized)
        }
    }

    private func outcome(symbol: String, title: String, detail: String,
                         @ViewBuilder actions: () -> some View) -> some View {
        VStack(spacing: 0) {
            VStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.system(size: 40, weight: .regular))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text(title)
                    .font(.title3.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                Text(detail)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 380)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(24)
            .accessibilityElement(children: .combine)
            .accessibilityFocused($headingFocused)
            footer(note: nil, actions: actions)
        }
    }

    // MARK: Pieces

    private func footer(note: String?, @ViewBuilder actions: () -> some View) -> some View {
        HStack(alignment: .center, spacing: 12) {
            if let note {
                Text(note)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            actions()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }
}

/// The form's window, opened from an app's menu or Settings. One per app: opening it again
/// brings the same window, with whatever the user had written, to the front.
@MainActor
public final class BugReportWindow {
    public let form: BugReportForm
    private let appName: String
    private var window: NSWindow?

    public init(form: BugReportForm, appName: String) {
        self.form = form
        self.appName = appName
    }

    /// Tall enough that both attachments and the privacy notice show without scrolling.
    public static let idealHeight: CGFloat = 660

    public func show() {
        if window == nil {
            let hosting = NSHostingController(rootView: BugReportView(form: form, appName: appName) { [weak self] in
                self?.window?.performClose(nil)
            })
            hosting.sizingOptions = [.minSize]
            let window = NSWindow(contentViewController: hosting)
            window.title = String(localized: "bugreport.window.title", bundle: .localized)
            window.styleMask = [.titled, .closable, .resizable]
            window.isReleasedWhenClosed = false
            window.setContentSize(NSSize(width: 520, height: Self.idealHeight))
            window.center()
            self.window = window
        }
        // An accessory (menu bar) app has to be handed the activation for its window to take the keyboard.
        WindowFocus.bringForward(window)
    }
}
