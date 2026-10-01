import Foundation
import Testing

@testable import Ambar

/// The age shown under each history entry.
@Suite("History row age")
struct HistoryRowAgeTests {
    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private let spanish = Locale(identifier: "es_ES")

    @Test("an entry stamped a moment after the clock was read is not from the future")
    func slightlyFutureEntryReadsNow() {
        // Reported on 2026-10-01: "Brave Browser · dentro de 0 segundos". The relative
        // style measures against the real clock, so this one uses the real clock too.
        let stampedJustAfter = Date().addingTimeInterval(0.4)
        let style = { (presentation: Date.RelativeFormatStyle.Presentation) in
            Date.RelativeFormatStyle(presentation: presentation).locale(spanish)
        }
        // The old rendering, to prove the case is the reported one.
        #expect(stampedJustAfter.formatted(style(.numeric)).contains("dentro"))

        let age = HistoryRow.age(of: stampedJustAfter)
        let rendered = age.date.formatted(style(age.presentation))
        #expect(!rendered.contains("dentro"), "an entry from the future: \(rendered)")
    }

    @Test("under a minute reads as now")
    func underAMinuteReadsNow() {
        let age = HistoryRow.age(of: now.addingTimeInterval(-30), now: now)
        #expect(age.date == now)
        #expect(age.presentation == .named)
    }

    @Test("older entries keep their numeric age")
    func olderEntriesKeepNumericAge() {
        let date = now.addingTimeInterval(-300)
        let age = HistoryRow.age(of: date, now: now)
        #expect(age.date == date)
        #expect(age.presentation == .numeric)
    }
}
