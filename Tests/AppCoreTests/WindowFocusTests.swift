import AppKit
import Testing

@testable import AppCore

/// How an accessory app's window is brought forward.
///
/// Whether the system grants the activation cannot be tested in a suite (the test runner is
/// not the app the user is in); what can is that the activation is handed over by the
/// frontmost app, which is the request the system honours, and that the window is in front
/// even when nothing is granted.
@MainActor
@Suite("Bringing a window forward")
struct WindowFocusTests {
    @MainActor
    final class Recorder: AppActivation {
        var otherFrontmostApp: NSRunningApplication?
        var calls: [String] = []

        init(front: NSRunningApplication?) { otherFrontmostApp = front }

        func activate(handedOverFrom app: NSRunningApplication) {
            calls.append("handedOver:\(app.processIdentifier)")
        }

        func activate() { calls.append("activate") }
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 120),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        return window
    }

    @Test("with another app in front, it hands the activation over before asking for it")
    func handsOverFromTheFrontmostApp() throws {
        let finder = try #require(
            NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first)
        let recorder = Recorder(front: finder)
        let window = makeWindow()
        defer { window.close() }

        WindowFocus.bringForward(window, activation: recorder)

        #expect(recorder.calls == ["handedOver:\(finder.processIdentifier)", "activate"])
    }

    @Test("when the app is already in front, it only asks for the activation")
    func alreadyFrontmost() {
        let recorder = Recorder(front: nil)
        let window = makeWindow()
        defer { window.close() }

        WindowFocus.bringForward(window, activation: recorder)

        #expect(recorder.calls == ["activate"])
    }

    @Test("the window is on screen even when no activation is granted")
    func orderedFrontWithoutActivation() {
        let window = makeWindow()
        defer { window.close() }
        #expect(!window.isVisible)

        WindowFocus.bringForward(window, activation: Recorder(front: nil))

        #expect(window.isVisible)
    }

    @Test("no window, nothing happens")
    func noWindow() {
        WindowFocus.bringForward(nil)
    }
}
