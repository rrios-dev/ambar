import Foundation
import Testing
@testable import AppCore

/// The installer's decisions with every outside step faked: the "disk image" is a folder
/// the fake `hdiutil attach` copies into the mount point.
struct UpdateInstallerTests {
    static let expectation = UpdateInstaller.Expectation(bundleIdentifier: "dev.example.app", teamIdentifier: "TEAM",
                                                         currentVersion: "1.3.0")

    final class Ran: @unchecked Sendable {
        private let lock = NSLock()
        private var all: [String] = []
        func add(_ line: String) { lock.withLock { all.append(line) } }
        var lines: [String] { lock.withLock { all } }
    }

    struct Fixture {
        let root: URL
        let installed: URL
        let image: URL
    }

    /// An installed app saying "old", and an image holding one saying "new".
    static func fixture(imageHoldsApp: Bool = true) throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("installer-\(UUID().uuidString)")
        let applications = root.appendingPathComponent("Applications")
        let installed = applications.appendingPathComponent("Example.app")
        let image = root.appendingPathComponent("image")
        try FileManager.default.createDirectory(at: installed, withIntermediateDirectories: true)
        try "old".write(to: installed.appendingPathComponent("marker"), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: image, withIntermediateDirectories: true)
        if imageHoldsApp {
            let app = image.appendingPathComponent("Example.app")
            try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
            try "new".write(to: app.appendingPathComponent("marker"), atomically: true, encoding: .utf8)
        }
        return Fixture(root: root, installed: installed, image: image)
    }

    static func steps(_ fixture: Fixture, ran: Ran, signed: Bool = true, notarized: Bool = true,
                      version: String = "1.4.0") -> UpdateInstaller.Steps {
        UpdateInstaller.Steps(
            download: { _ in fixture.image },
            run: { tool, arguments in
                ran.add(([tool] + arguments).joined(separator: " "))
                switch tool {
                case "/usr/bin/hdiutil" where arguments.first == "attach":
                    let mount = arguments[arguments.firstIndex(of: "-mountpoint")! + 1]
                    for item in (try? FileManager.default.contentsOfDirectory(atPath: arguments[1])) ?? [] {
                        try? FileManager.default.copyItem(atPath: arguments[1] + "/" + item, toPath: mount + "/" + item)
                    }
                    return 0
                case "/usr/sbin/spctl": return notarized ? 0 : 3
                case "/usr/bin/ditto":
                    return (try? FileManager.default.copyItem(atPath: arguments[0], toPath: arguments[1])) != nil ? 0 : 1
                default: return 0
                }
            },
            signedBy: { _, _ in signed },
            version: { _ in version })
    }

    static func marker(_ app: URL) -> String? {
        try? String(contentsOf: app.appendingPathComponent("marker"), encoding: .utf8)
    }

    @Test func aSignedNotarizedNewerAppReplacesTheInstalledOne() async throws {
        let fixture = try Self.fixture()
        let ran = Ran()
        let installer = UpdateInstaller(expectation: Self.expectation, steps: Self.steps(fixture, ran: ran))
        let version = try await installer.install(image: URL(string: "https://example.test/Example.dmg")!, over: fixture.installed)
        #expect(version == "1.4.0")
        #expect(Self.marker(fixture.installed) == "new")
        #expect(ran.lines.contains { $0.hasPrefix("/usr/bin/hdiutil detach") }, "the image is always detached")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: fixture.installed.deletingLastPathComponent().path)
        #expect(leftovers == ["Example.app"])
    }

    @Test(arguments: [
        (true, false, "1.4.0", UpdateInstaller.Failure.notNotarized),
        (false, true, "1.4.0", .signature),
        (true, true, "1.3.0", .notNewer("1.3.0")),
    ])
    func anythingDoubtfulLeavesTheInstalledAppAlone(signed: Bool, notarized: Bool, version: String,
                                                    expected: UpdateInstaller.Failure) async throws {
        let fixture = try Self.fixture()
        let installer = UpdateInstaller(expectation: Self.expectation,
                                        steps: Self.steps(fixture, ran: Ran(), signed: signed, notarized: notarized, version: version))
        await #expect(throws: expected) {
            _ = try await installer.install(image: URL(string: "https://example.test/Example.dmg")!, over: fixture.installed)
        }
        #expect(Self.marker(fixture.installed) == "old")
    }

    @Test func anImageWithoutTheAppIsRefused() async throws {
        let fixture = try Self.fixture(imageHoldsApp: false)
        let installer = UpdateInstaller(expectation: Self.expectation, steps: Self.steps(fixture, ran: Ran()))
        await #expect(throws: UpdateInstaller.Failure.noApp) {
            _ = try await installer.install(image: URL(string: "https://example.test/Example.dmg")!, over: fixture.installed)
        }
    }

    @Test func theRealSignatureCheckRefusesAnUnsignedFolder() throws {
        let fixture = try Self.fixture()
        #expect(!UpdateInstaller.isSigned(fixture.installed, as: Self.expectation))
    }
}

/// The real thing, opt-in (`APPCORE_LIVE_UPDATE=<dmg url>`, with `APPCORE_LIVE_APP_NAME`,
/// `APPCORE_LIVE_BUNDLE_ID` and `APPCORE_LIVE_TEAM` naming the app inside — its file name,
/// as the installer looks for it in the image — and its team): downloads a published,
/// notarized image and installs it over a stand-in app in a temporary folder.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["APPCORE_LIVE_UPDATE"] != nil))
struct UpdateInstallerLiveTests {
    @Test func installsAPublishedReleaseEndToEnd() async throws {
        let environment = ProcessInfo.processInfo.environment
        let image = try #require(environment["APPCORE_LIVE_UPDATE"].flatMap(URL.init(string:)))
        let appName = try #require(environment["APPCORE_LIVE_APP_NAME"])
        let bundleIdentifier = try #require(environment["APPCORE_LIVE_BUNDLE_ID"])
        let team = try #require(environment["APPCORE_LIVE_TEAM"])
        let applications = FileManager.default.temporaryDirectory.appendingPathComponent("live-\(UUID().uuidString)")
        let installed = applications.appendingPathComponent(appName)
        try FileManager.default.createDirectory(at: installed, withIntermediateDirectories: true)
        let installer = UpdateInstaller(expectation: .init(bundleIdentifier: bundleIdentifier, teamIdentifier: team,
                                                           currentVersion: "0.0.1"))
        let version = try await installer.install(image: image, over: installed)
        print("LIVE installed \(version)")
        #expect(UpdateInstaller.isSigned(installed, as: installer.expectation))
        // The wrong team is refused by the same check.
        #expect(!UpdateInstaller.isSigned(installed, as: .init(bundleIdentifier: bundleIdentifier, teamIdentifier: "XXXXXXXXXX",
                                                               currentVersion: "0.0.1")))
        try? FileManager.default.removeItem(at: applications)
    }
}
