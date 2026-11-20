import AppCore
import Foundation
import Testing

@testable import Ambar

/// Ámbar's usage statistics (owner decision 2026-11-20): nothing kept before a yes, only the
/// closed list's names, and the question and the switch readable in every language Ámbar ships.
@Suite("Ámbar usage statistics")
@MainActor
struct AmbarUsageTests {
    private func freshDefaults() -> UserDefaults {
        let name = "AmbarUsageTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    private let afterToday = Date().addingTimeInterval(2 * 86_400)

    @Test("nothing is kept before the user says yes")
    func nothingWithoutConsent() {
        let report = AmbarUsage.makeReport(defaults: freshDefaults())
        #expect(report.consent == nil)
        report.count(.pastes)
        report.count(.captures, by: 3)
        report.setConsent(true)
        #expect(report.preview(now: afterToday).isEmpty)
    }

    @Test("after a yes, each count is kept under its name and sent as Ámbar's")
    func countsAfterConsent() throws {
        let report = AmbarUsage.makeReport(defaults: freshDefaults())
        report.setConsent(true)
        report.count(.pastes)
        report.count(.pastesPlain)
        report.count(.dictations, by: 2)
        let day = try #require(report.preview(now: afterToday).first)
        #expect(day.app == "ambar")
        #expect(day.counts == ["pastes": 1, "pastes_plain": 1, "dictations": 2])
    }

    @Test("a no deletes what was kept")
    func noDeletes() {
        let report = AmbarUsage.makeReport(defaults: freshDefaults())
        report.setConsent(true)
        report.count(.launches)
        report.setConsent(false)
        report.setConsent(true)
        #expect(report.preview(now: afterToday).isEmpty)
    }

    /// `services/usage` refuses a whole request with one name outside `^[a-z][a-z_]{0,31}$`.
    @Test("every name is one the server accepts")
    func namesTheServerAccepts() {
        let shape = /^[a-z][a-z_]{0,31}$/
        for name in AmbarUsage.counts { #expect(name.wholeMatch(of: shape) != nil, "\(name)") }
        #expect(AmbarUsage.counts.count == AmbarUsage.Count.allCases.count)
    }

    @Test("the model's paste, capture and dictation paths share one report")
    func modelHoldsTheReport() {
        let report = AmbarUsage.makeReport(defaults: freshDefaults())
        let model = AppModel(usage: report)
        #expect(model.usage === report)
    }

    @Test("the question and the switch exist in every language Ámbar ships")
    func everyLanguageHasTheStrings() throws {
        let keys = ["usage.section", "usage.toggle", "usage.note", "usage.pending.none", "usage.pending %lld",
                    "usage.ask.title", "usage.ask.body", "usage.ask.yes", "usage.ask.no"]
        let bundle = Bundle.localized
        let languages = bundle.localizations.filter { $0 != "Base" }
        #expect(languages.count >= 10)
        for language in languages {
            let url = try #require(bundle.url(forResource: "Localizable", withExtension: "strings",
                                              subdirectory: nil, localization: language), "\(language)")
            let table = try #require(NSDictionary(contentsOf: url) as? [String: String], "\(language)")
            for key in keys { #expect(table[key]?.isEmpty == false, "\(language): \(key)") }
        }
    }
}
