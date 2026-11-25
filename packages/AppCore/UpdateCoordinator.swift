import AppKit
import Foundation
import Observation

/// Keeps an app outside the App Store up to date: checks on a schedule and on waking,
/// installs a newer release in one click, and falls back to opening the disk image.
///
/// The pieces were already here — `UpdateCheck` asks, `UpdateInstaller` verifies and
/// swaps — but the glue lived inside one app, so the next app had none: Ámbar shipped
/// five releases its users never heard of. This is that glue, with what is product
/// specific (copy, when not to interrupt, where to show it) left to the app.
@MainActor
@Observable
public final class UpdateCoordinator {
    public let check: UpdateCheck
    /// A newer release, unless skipped. What a menu item or a badge shows.
    public var available: AvailableUpdate? { check.available }
    public private(set) var isInstalling = false

    /// Called after every check and skip, so the app can redraw its menu or badge.
    @ObservationIgnored public var onChange: (() -> Void)?

    @ObservationIgnored private let expectation: UpdateInstaller.Expectation
    @ObservationIgnored private let app: URL
    @ObservationIgnored private let installer: UpdateInstaller
    @ObservationIgnored private let open: @MainActor (URL) -> Void
    @ObservationIgnored private let relaunch: @MainActor (URL) -> Void
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var wakeObserver: NSObjectProtocol?

    public init(
        check: UpdateCheck,
        expectation: UpdateInstaller.Expectation,
        app: URL = Bundle.main.bundleURL,
        installer: UpdateInstaller? = nil,
        open: @escaping @MainActor (URL) -> Void = { NSWorkspace.shared.open($0) },
        relaunch: @escaping @MainActor (URL) -> Void = { UpdateInstaller.relaunch($0) }
    ) {
        self.check = check
        self.expectation = expectation
        self.app = app
        self.installer = installer ?? UpdateInstaller(expectation: expectation)
        self.open = open
        self.relaunch = relaunch
    }

    /// Checks now if due, then every `tick` and a moment after waking. `UpdateCheck`
    /// still asks the network only once its own interval has passed; the tick exists
    /// because a Mac that sleeps through the night would otherwise wait a whole interval.
    public func start(tick: TimeInterval = 3600, afterWake: Duration = .seconds(20)) {
        guard timer == nil else { return }
        Task { await checkIfDue() }
        let timer = Timer(timeInterval: tick, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.checkIfDue() }
        }
        timer.tolerance = tick / 10
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                // The network comes back a moment after the lid opens.
                try? await Task.sleep(for: afterWake)
                await self?.checkIfDue()
            }
        }
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        wakeObserver = nil
    }

    public func checkIfDue() async {
        await check.checkIfDue()
        onChange?()
    }

    /// "Check now": whatever the schedule.
    @discardableResult
    public func checkNow() async -> UpdateCheck.Outcome {
        let outcome = await check.checkNow()
        onChange?()
        return outcome
    }

    /// "Not this one".
    public func skip() {
        check.skip()
        onChange?()
    }

    public enum InstallResult: Equatable, Sendable {
        /// Installed; the app is relaunching.
        case installed(String)
        /// One click was not possible; the release's disk image or page was opened.
        case openedForManualInstall
        case nothingToInstall
    }

    /// Downloads, verifies (this team's signature, notarized, newer) and replaces the app,
    /// then relaunches it. Anything that goes wrong opens the disk image instead, the
    /// drag-to-Applications of before, so the user is never left without a way forward.
    @discardableResult
    public func install() async -> InstallResult {
        guard let update = check.available, !isInstalling else { return .nothingToInstall }
        guard let image = update.download else {
            open(update.page)
            return .openedForManualInstall
        }
        isInstalling = true
        defer { isInstalling = false }
        do {
            let version = try await installer.install(image: image, over: app)
            relaunch(app)
            return .installed(version)
        } catch {
            open(image)
            return .openedForManualInstall
        }
    }
}
