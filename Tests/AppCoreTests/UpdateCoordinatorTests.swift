import Foundation
import Testing
@testable import AppCore

/// The glue between "a newer release exists" and "it is installed": which way an install
/// goes, and that the app hears about every change. Network and disk are faked.
@MainActor
struct UpdateCoordinatorTests {
    static let page = URL(string: "https://example.com/releases/v1.4.0")!
    static let image = URL(string: "https://example.com/Example-1.4.0.dmg")!

    static func release(withImage: Bool = true) -> Data {
        let assets = withImage
            ? #"[{"name":"Example-1.4.0.dmg","browser_download_url":"\#(image.absoluteString)"}]"#
            : "[]"
        return Data(#"{"tag_name":"v1.4.0","html_url":"\#(page.absoluteString)","assets":\#(assets)}"#.utf8)
    }

    final class Calls {
        var opened: [URL] = []
        var relaunched: [URL] = []
        var changes = 0
    }

    static func coordinator(
        release: Data = release(),
        installs: Bool = true,
        calls: Calls
    ) throws -> (UpdateCoordinator, UpdateInstallerTests.Fixture) {
        let defaults = UserDefaults(suiteName: "updates.coordinator.\(UUID().uuidString)")!
        let check = UpdateCheck(repository: "example/app", currentVersion: "1.3.0", defaults: defaults,
                                fetch: { _ in release })
        let fixture = try UpdateInstallerTests.fixture()
        let ran = UpdateInstallerTests.Ran()
        let installer = UpdateInstaller(
            expectation: UpdateInstallerTests.expectation,
            steps: UpdateInstallerTests.steps(fixture, ran: ran, signed: installs)
        )
        let coordinator = UpdateCoordinator(
            check: check,
            expectation: UpdateInstallerTests.expectation,
            app: fixture.installed,
            installer: installer,
            open: { calls.opened.append($0) },
            relaunch: { calls.relaunched.append($0) }
        )
        coordinator.onChange = { calls.changes += 1 }
        return (coordinator, fixture)
    }

    @Test("a newer release is installed over the app, which relaunches")
    func installsAndRelaunches() async throws {
        let calls = Calls()
        let (coordinator, fixture) = try Self.coordinator(calls: calls)
        await coordinator.checkNow()
        #expect(coordinator.available?.version == "1.4.0")

        let result = await coordinator.install()

        #expect(result == .installed("1.4.0"))
        #expect(calls.relaunched == [fixture.installed])
        #expect(calls.opened.isEmpty)
        let marker = try String(contentsOf: fixture.installed.appendingPathComponent("marker"), encoding: .utf8)
        #expect(marker == "new")
    }

    @Test("an install that fails its checks opens the disk image instead, and never relaunches")
    func failedInstallOpensTheImage() async throws {
        let calls = Calls()
        let (coordinator, _) = try Self.coordinator(installs: false, calls: calls)
        await coordinator.checkNow()

        let result = await coordinator.install()

        #expect(result == .openedForManualInstall)
        #expect(calls.opened == [Self.image])
        #expect(calls.relaunched.isEmpty)
    }

    @Test("a release without a disk image opens its page")
    func noImageOpensThePage() async throws {
        let calls = Calls()
        let (coordinator, _) = try Self.coordinator(release: Self.release(withImage: false), calls: calls)
        await coordinator.checkNow()

        #expect(await coordinator.install() == .openedForManualInstall)
        #expect(calls.opened == [Self.page])
    }

    @Test("nothing newer: nothing is installed or opened")
    func nothingToInstall() async throws {
        let calls = Calls()
        let (coordinator, _) = try Self.coordinator(calls: calls)

        #expect(await coordinator.install() == .nothingToInstall)
        #expect(calls.opened.isEmpty && calls.relaunched.isEmpty)
    }

    @Test("checks and skips tell the app, so its menu follows")
    func changesAreReported() async throws {
        let calls = Calls()
        let (coordinator, _) = try Self.coordinator(calls: calls)
        await coordinator.checkNow()
        #expect(calls.changes == 1)

        coordinator.skip()

        #expect(calls.changes == 2)
        #expect(coordinator.available == nil)
    }
}
