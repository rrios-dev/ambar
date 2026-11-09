import AppKit

/// Brings one of an accessory app's windows forward, with the keyboard.
///
/// A menu bar app (`LSUIElement`) stays inactive while the user works elsewhere, and since
/// macOS 14 `NSApplication.activate()` is only a request the system may decline. It does
/// decline it: Settings opened behind the frontmost app, without the keyboard (reported in
/// three of the menu bar apps, 2026-11-06 and 2026-11-09). Measured on 2026-11-09 with Finder
/// in front and a tiling window manager: `makeKeyAndOrderFront` + `activate()` left the
/// window behind Finder and the app inactive; adding an activation handed over by the frontmost app put
/// it in front, key, every time. That hand-over is what the system honours for an action
/// the user has just taken in the app.
///
/// The window is also ordered front regardless of activation, so if the system still
/// declines, the window is at least seen in front and one click gives it the keyboard.
@MainActor
public enum WindowFocus {
    public static func bringForward(_ window: NSWindow?) {
        guard let window else { return }
        bringForward(window, activation: SystemActivation())
    }

    static func bringForward(_ window: NSWindow, activation: some AppActivation) {
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        if let front = activation.otherFrontmostApp {
            activation.activate(handedOverFrom: front)
        }
        activation.activate()
    }
}

/// The activation calls `WindowFocus` makes, so a test can read their order.
@MainActor
protocol AppActivation {
    /// The app the user is in, when it is not this one.
    var otherFrontmostApp: NSRunningApplication? { get }
    func activate(handedOverFrom app: NSRunningApplication)
    func activate()
}

@MainActor
struct SystemActivation: AppActivation {
    var otherFrontmostApp: NSRunningApplication? {
        guard let front = NSWorkspace.shared.frontmostApplication, front != .current else { return nil }
        return front
    }

    func activate(handedOverFrom app: NSRunningApplication) {
        NSRunningApplication.current.activate(from: app, options: [])
    }

    func activate() {
        NSApplication.shared.activate()
    }
}
