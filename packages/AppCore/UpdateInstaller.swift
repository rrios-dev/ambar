import AppKit
import Foundation
import Security

/// Installs a newer release in one click: downloads its disk image, checks the
/// app inside is signed by the same team and accepted by Gatekeeper (notarized), puts it in
/// place of the running app and reopens it.
///
/// Native on purpose, like `UpdateCheck` (C-22): `hdiutil`, the Security framework and
/// `spctl` are what Sparkle uses underneath. Every step that can fail says so, and the app
/// falls back to opening the disk image as before: the worst case is the old drag.
public struct UpdateInstaller: Sendable {
    public enum Failure: Error, Equatable, Sendable {
        case download
        case mount
        case noApp
        /// Not signed by the expected team, or not this app.
        case signature
        /// Gatekeeper refuses it (not notarized).
        case notNotarized
        case notNewer(String)
        /// The app's folder cannot be written (a non-admin account, a read-only volume).
        case notWritable
        case replace
    }

    /// What a check of the new app needs to know about the running one.
    public struct Expectation: Sendable {
        public var bundleIdentifier: String
        public var teamIdentifier: String
        public var currentVersion: String

        public init(bundleIdentifier: String, teamIdentifier: String, currentVersion: String) {
            self.bundleIdentifier = bundleIdentifier
            self.teamIdentifier = teamIdentifier
            self.currentVersion = currentVersion
        }
    }

    /// The steps that touch the world, replaceable in tests.
    public struct Steps: Sendable {
        public var download: @Sendable (URL) async throws -> URL
        /// Runs a tool and returns its exit status.
        public var run: @Sendable (String, [String]) -> Int32
        public var signedBy: @Sendable (URL, Expectation) -> Bool
        public var version: @Sendable (URL) -> String?

        public init(download: @escaping @Sendable (URL) async throws -> URL,
                    run: @escaping @Sendable (String, [String]) -> Int32,
                    signedBy: @escaping @Sendable (URL, Expectation) -> Bool,
                    version: @escaping @Sendable (URL) -> String?) {
            self.download = download
            self.run = run
            self.signedBy = signedBy
            self.version = version
        }

        public static let live = Steps(
            download: { url in
                let (file, response) = try await URLSession.shared.download(from: url)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw Failure.download }
                return file
            },
            run: UpdateInstaller.runTool,
            signedBy: UpdateInstaller.isSigned,
            version: { Bundle(url: $0)?.infoDictionary?["CFBundleShortVersionString"] as? String })
    }

    public let expectation: Expectation
    public let steps: Steps

    public init(expectation: Expectation, steps: Steps = .live) {
        self.expectation = expectation
        self.steps = steps
    }

    /// Replaces `installedApp` with the app in the disk image at `image`. Returns the
    /// version installed; the caller relaunches (`relaunch(_:)`).
    public func install(image: URL, over installedApp: URL) async throws(Failure) -> String {
        let folder = installedApp.deletingLastPathComponent()
        guard FileManager.default.isWritableFile(atPath: folder.path) else { throw .notWritable }
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("update-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: work) }
        let mount = work.appendingPathComponent("mount")
        try? FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)

        let file: URL
        do {
            file = try await steps.download(image)
        } catch {
            throw .download
        }
        guard steps.run("/usr/bin/hdiutil", ["attach", file.path, "-nobrowse", "-readonly", "-noautoopen",
                                             "-mountpoint", mount.path]) == 0 else { throw .mount }
        defer { _ = steps.run("/usr/bin/hdiutil", ["detach", mount.path, "-force"]) }

        let name = installedApp.lastPathComponent
        let candidate = mount.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: candidate.path) else { throw .noApp }
        guard steps.signedBy(candidate, expectation) else { throw .signature }
        guard steps.run("/usr/sbin/spctl", ["--assess", "--type", "execute", candidate.path]) == 0 else { throw .notNotarized }
        let version = steps.version(candidate) ?? "0"
        guard UpdateCheck.isNewer(version, than: expectation.currentVersion) else { throw .notNewer(version) }

        // Copied next to the installed app first, so the swap is a rename on one volume.
        let staged = folder.appendingPathComponent(".\(name).update")
        try? FileManager.default.removeItem(at: staged)
        guard steps.run("/usr/bin/ditto", [candidate.path, staged.path]) == 0 else { throw .replace }
        do {
            _ = try FileManager.default.replaceItemAt(installedApp, withItemAt: staged)
        } catch {
            try? FileManager.default.removeItem(at: staged)
            throw .replace
        }
        return version
    }

    /// Opens `app` a moment after this process quits, then quits.
    @MainActor
    public static func relaunch(_ app: URL) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "sleep 1; /usr/bin/open \"$0\"", app.path]
        try? process.run()
        NSApplication.shared.terminate(nil)
    }

    // MARK: Live steps

    /// Signed by `teamIdentifier`, as `bundleIdentifier`, with a valid seal.
    public static func isSigned(_ app: URL, as expectation: Expectation) -> Bool {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code else { return false }
        let text = "anchor apple generic and identifier \"\(expectation.bundleIdentifier)\" and certificate leaf[subject.OU] = \"\(expectation.teamIdentifier)\""
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess else { return false }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSCheckNestedCode | kSecCSStrictValidate)
        return SecStaticCodeCheckValidity(code, flags, requirement) == errSecSuccess
    }

    public static func runTool(_ path: String, _ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return -1
        }
        process.waitUntilExit()
        return process.terminationStatus
    }
}
