import AppKit
import Testing
@testable import AppCore

// Shared-control S8 fix round, X1: a consent question that a stray Return or Space cannot answer yes.

@MainActor
struct ConsentAlertTests {
    @Test func noButtonAnswersReturnAndEscapeSaysNo() {
        let alert = ConsentAlert.make(title: "Help improve?", message: "Counts only.", yes: "Share", no: "No, thanks")
        #expect(alert.buttons.map(\.title) == ["Share", "No, thanks"])
        #expect(alert.buttons[0].keyEquivalent == "")
        #expect(alert.buttons.allSatisfy { $0.keyEquivalent != "\r" })
        #expect(alert.buttons[1].keyEquivalent == "\u{1b}")
    }

    @Test func yesNeverTakesTheKeyboardSoSpaceCannotPressIt() {
        let alert = ConsentAlert.make(title: "Help improve?", message: "Counts only.", yes: "Share", no: "No, thanks")
        #expect(!alert.buttons[0].acceptsFirstResponder)
        #expect(alert.window.initialFirstResponder !== alert.buttons[0])
        #expect(alert.window.defaultButtonCell !== alert.buttons[0].cell)
    }
}
