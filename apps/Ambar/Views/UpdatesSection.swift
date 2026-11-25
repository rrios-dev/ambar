import AppCore
import SwiftUI

/// Settings → Updates: the automatic check, "Check now" with its answer, and the
/// one-click install when a newer release exists.
struct UpdatesSection: View {
    let updates: UpdateCoordinator
    @State private var checksAutomatically = true
    @State private var status: Status = .idle

    enum Status: Equatable { case idle, checking, upToDate, failed }

    var body: some View {
        Section(String(localized: "updates.section", bundle: .localized)) {
            Toggle(
                String(localized: "updates.toggle", bundle: .localized),
                isOn: Binding(
                    get: { checksAutomatically },
                    set: {
                        checksAutomatically = $0
                        updates.check.isEnabled = $0
                    }
                )
            )
            LabeledContent {
                if let update = updates.available {
                    Button(String(localized: "updates.install", bundle: .localized)) {
                        Task { await updates.install() }
                    }
                    .disabled(updates.isInstalling)
                    .accessibilityHint(String(localized: "updates.available \(update.version)", bundle: .localized))
                } else {
                    Button(String(localized: "updates.check_now", bundle: .localized)) {
                        Task {
                            status = .checking
                            status = switch await updates.checkNow() {
                            case .upToDate, .available: .upToDate
                            case .failed: .failed
                            }
                        }
                    }
                    .disabled(status == .checking)
                }
            } label: {
                Text(Self.statusText(available: updates.available?.version, status: status))
                    .foregroundStyle(.secondary)
            }
        }
        .onAppear { checksAutomatically = updates.check.isEnabled }
    }

    static func statusText(available: String?, status: Status) -> String {
        if let available { return String(localized: "updates.available \(available)", bundle: .localized) }
        return switch status {
        case .checking: String(localized: "updates.checking", bundle: .localized)
        case .failed: String(localized: "updates.failed", bundle: .localized)
        case .idle, .upToDate:
            String(localized: "updates.current \(AppModel.runningVersion)", bundle: .localized)
        }
    }
}
