import AppCore
import AppKit
import Foundation

/// Ámbar's side of the usage statistics, wired as Quill's (Quill J-11) and Batuta's: AppCore's
/// `UsageReport` with Ámbar's closed list, asked once after the first-run tour, a switch in
/// Settings. Nothing is counted before a yes; a no deletes what was kept and the
/// install id. Owner decision 2026-11-20: counts with consent, and the public promise
/// ("no telemetry") is rewritten to say so in the same release.
enum AmbarUsage {
    /// `services/usage` on genesis, in the EU (Quill's endpoint).
    static let endpoint = URL(string: "https://usage.rrios.dev/v1/usage")!

    /// Every count Ámbar may send. A name not here is never kept (`UsageReport.count`).
    enum Count: String, CaseIterable {
        case launches
        /// The history panel opened, by the shortcut or the menu bar.
        case panelOpens = "panel_opens"
        /// Something copied and kept in the history.
        case captures
        /// An entry put back on the pasteboard to paste, with or without its format.
        case pastes
        case pastesPlain = "pastes_plain"
        /// A dictation kept in the history.
        case dictations
    }

    static let counts: Set<String> = Set(Count.allCases.map(\.rawValue))

    /// The running version, as `services/usage` accepts it ("1.3.0").
    static var runningVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0"
    }

    @MainActor
    static func makeReport(defaults: UserDefaults = .standard) -> UsageReport {
        UsageReport(app: "ambar", version: runningVersion, allowedCounts: counts,
                    endpoint: .init(url: endpoint), defaults: defaults)
    }

    /// Asked once, never again whatever the answer: the switch in Settings changes it. A yes is
    /// a click, never a stray Return (AppCore's `ConsentAlert`).
    @MainActor
    static func ask(_ report: UsageReport) {
        report.setConsent(ConsentAlert.ask(
            title: String(localized: "usage.ask.title", bundle: .localized),
            message: String(localized: "usage.ask.body", bundle: .localized),
            yes: String(localized: "usage.ask.yes", bundle: .localized),
            no: String(localized: "usage.ask.no", bundle: .localized)))
    }
}

extension UsageReport {
    /// One use of one of Ámbar's counts; nothing without consent.
    @MainActor
    func count(_ count: AmbarUsage.Count, by amount: Int = 1) {
        self.count(count.rawValue, by: amount)
    }
}
