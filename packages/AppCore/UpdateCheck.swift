import Foundation
import Observation

/// A newer release, as the app's public repository publishes it.
public struct AvailableUpdate: Sendable, Equatable, Codable {
    /// "1.3.0", without the tag's "v".
    public var version: String
    /// The release page: notes and every asset.
    public var page: URL
    /// The disk image to install from, when the release has one.
    public var download: URL?

    public init(version: String, page: URL, download: URL? = nil) {
        self.version = version
        self.page = page
        self.download = download
    }
}

/// Tells an app outside the App Store that a newer version exists.
///
/// macOS updates only App Store apps, so a downloaded app has to ask. It asks GitHub for
/// the repository's latest release at most once a day, compares versions and keeps the
/// answer; installing stays the user's (open the disk image, drag to Applications).
/// Nothing about the user is sent: one anonymous GET to the public API.
///
/// Native on purpose (URLSession, no Sparkle): a notice was chosen over one-click
/// installs, and a notice needs no framework.
@MainActor
@Observable
public final class UpdateCheck {
    public enum Outcome: Equatable, Sendable {
        case upToDate
        case available(AvailableUpdate)
        case failed
    }

    /// "owner/name" on GitHub.
    public let repository: String
    public let currentVersion: String
    /// The newer release found by the last check, unless the user skipped it.
    public private(set) var available: AvailableUpdate?

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let fetch: @Sendable (URL) async throws -> Data
    @ObservationIgnored private let interval: TimeInterval

    private var lastCheckKey: String { "updates.lastCheck" }
    private var enabledKey: String { "updates.enabled" }
    private var skippedKey: String { "updates.skipped" }
    private var foundKey: String { "updates.found" }

    public init(repository: String, currentVersion: String, defaults: UserDefaults = .standard,
                interval: TimeInterval = 24 * 3600,
                fetch: @escaping @Sendable (URL) async throws -> Data = UpdateCheck.download) {
        self.repository = repository
        self.currentVersion = currentVersion
        self.defaults = defaults
        self.interval = interval
        self.fetch = fetch
        // What an earlier check found survives a relaunch, unless this version caught up.
        if let data = defaults.data(forKey: foundKey),
           let found = try? JSONDecoder().decode(AvailableUpdate.self, from: data),
           Self.isNewer(found.version, than: currentVersion), found.version != skipped {
            available = found
        }
    }

    /// Checking automatically; on by default, a switch in Settings.
    public var isEnabled: Bool {
        get { defaults.object(forKey: enabledKey) as? Bool ?? true }
        set { defaults.set(newValue, forKey: enabledKey) }
    }

    public var lastCheck: Date? { defaults.object(forKey: lastCheckKey) as? Date }

    private var skipped: String? { defaults.string(forKey: skippedKey) }

    /// Checks when enabled and the last check is older than the interval.
    @discardableResult
    public func checkIfDue(now: Date = Date()) async -> Outcome? {
        guard isEnabled else { return nil }
        if let lastCheck, now.timeIntervalSince(lastCheck) < interval { return nil }
        return await checkNow(now: now)
    }

    /// Asks now, whatever the schedule ("Check now" in Settings). A failure leaves the
    /// last answer as it was and the schedule untouched, so the next launch tries again.
    @discardableResult
    public func checkNow(now: Date = Date()) async -> Outcome {
        guard let url = URL(string: "https://api.github.com/repos/\(repository)/releases/latest"),
              let data = try? await fetch(url),
              let latest = try? Self.parse(latestRelease: data) else { return .failed }
        defaults.set(now, forKey: lastCheckKey)
        guard Self.isNewer(latest.version, than: currentVersion) else {
            available = nil
            defaults.removeObject(forKey: foundKey)
            return .upToDate
        }
        defaults.set(try? JSONEncoder().encode(latest), forKey: foundKey)
        available = latest.version == skipped ? nil : latest
        return .available(latest)
    }

    /// "Not this one": the notice goes away until a later version appears.
    public func skip() {
        guard let available else { return }
        defaults.set(available.version, forKey: skippedKey)
        self.available = nil
    }

    // MARK: Pieces

    /// GitHub's `releases/latest`: drafts and prereleases never count; the first `.dmg`
    /// asset is the download.
    public nonisolated static func parse(latestRelease data: Data) throws -> AvailableUpdate {
        struct Release: Decodable {
            struct Asset: Decodable {
                var name: String
                var browser_download_url: URL
            }
            var tag_name: String
            var html_url: URL
            var draft: Bool?
            var prerelease: Bool?
            var assets: [Asset]?
        }
        let release = try JSONDecoder().decode(Release.self, from: data)
        guard release.draft != true, release.prerelease != true else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "not a published release"))
        }
        let version = release.tag_name.hasPrefix("v") ? String(release.tag_name.dropFirst()) : release.tag_name
        let image = release.assets?.first { $0.name.lowercased().hasSuffix(".dmg") }?.browser_download_url
        return AvailableUpdate(version: version, page: release.html_url, download: image)
    }

    /// Dotted numeric comparison: "1.10.0" is newer than "1.9.2"; a missing part is 0.
    /// Anything after a "-" (a prerelease suffix) is ignored.
    public nonisolated static func isNewer(_ candidate: String, than current: String) -> Bool {
        func parts(_ version: String) -> [Int] {
            let core = version.split(separator: "-").first.map(String.init) ?? version
            return core.split(separator: ".").map { Int($0) ?? 0 }
        }
        let a = parts(candidate), b = parts(current)
        for index in 0..<max(a.count, b.count) {
            let x = index < a.count ? a[index] : 0, y = index < b.count ? b[index] : 0
            if x != y { return x > y }
        }
        return false
    }

    public nonisolated static func download(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return data
    }
}
