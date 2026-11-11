import Foundation
import Testing

@testable import AppCore

/// The update notice: what counts as newer, what GitHub's answer means, and when it asks.
@Suite("Update check")
@MainActor
struct UpdateCheckTests {
    nonisolated static func release(_ tag: String, draft: Bool = false, dmg: Bool = true) -> Data {
        let assets = dmg ? #"[{"name":"App-\#(tag).dmg","browser_download_url":"https://example.com/q.dmg"}]"# : "[]"
        return Data(#"{"tag_name":"\#(tag)","html_url":"https://example.com/r","draft":\#(draft),"prerelease":false,"assets":\#(assets)}"#.utf8)
    }

    nonisolated static func defaults() -> UserDefaults {
        let name = "update-check-tests-\(UUID().uuidString)"
        return UserDefaults(suiteName: name)!
    }

    @Test("versions compare by number, not by text")
    func comparison() {
        #expect(UpdateCheck.isNewer("1.10.0", than: "1.9.2"))
        #expect(UpdateCheck.isNewer("1.2", than: "1.1.9"))
        #expect(!UpdateCheck.isNewer("1.2.0", than: "1.2"))
        #expect(!UpdateCheck.isNewer("1.1.1", than: "1.2.0"))
        #expect(!UpdateCheck.isNewer("1.2.0-beta", than: "1.2.0"))
    }

    @Test("a release gives its version without the v, its page and its disk image; a draft is refused")
    func parsing() throws {
        let update = try UpdateCheck.parse(latestRelease: Self.release("v1.3.0"))
        #expect(update == AvailableUpdate(version: "1.3.0", page: URL(string: "https://example.com/r")!,
                                          download: URL(string: "https://example.com/q.dmg")!))
        #expect(try UpdateCheck.parse(latestRelease: Self.release("v1.3.0", dmg: false)).download == nil)
        #expect(throws: (any Error).self) { try UpdateCheck.parse(latestRelease: Self.release("v1.3.0", draft: true)) }
    }

    @Test("a newer release is announced and remembered across launches; the same version is not")
    func announce() async {
        let defaults = Self.defaults()
        let check = UpdateCheck(repository: "o/r", currentVersion: "1.2.0", defaults: defaults) { _ in Self.release("v1.3.0") }
        #expect(await check.checkNow() != .failed)
        #expect(check.available?.version == "1.3.0")
        let relaunched = UpdateCheck(repository: "o/r", currentVersion: "1.2.0", defaults: defaults) { _ in Data() }
        #expect(relaunched.available?.version == "1.3.0")
        let updated = UpdateCheck(repository: "o/r", currentVersion: "1.3.0", defaults: defaults) { _ in Data() }
        #expect(updated.available == nil)
        let same = UpdateCheck(repository: "o/r", currentVersion: "1.3.0", defaults: Self.defaults()) { _ in Self.release("v1.3.0") }
        #expect(await same.checkNow() == .upToDate)
    }

    @Test("it asks once a day, never when switched off, and a failure does not count as a check")
    func schedule() async {
        let defaults = Self.defaults()
        let now = Date()
        let failing = UpdateCheck(repository: "o/r", currentVersion: "1.2.0", defaults: defaults) { _ in throw URLError(.notConnectedToInternet) }
        #expect(await failing.checkIfDue(now: now) == .failed)
        #expect(failing.lastCheck == nil)
        let check = UpdateCheck(repository: "o/r", currentVersion: "1.2.0", defaults: defaults) { _ in Self.release("v1.2.0") }
        #expect(await check.checkIfDue(now: now) == .upToDate)
        #expect(await check.checkIfDue(now: now.addingTimeInterval(3600)) == nil)
        #expect(await check.checkIfDue(now: now.addingTimeInterval(25 * 3600)) == .upToDate)
        check.isEnabled = false
        #expect(await check.checkIfDue(now: now.addingTimeInterval(60 * 3600)) == nil)
    }

    @Test("a newer version is brought up once, also across launches; a later one is brought up again")
    func notice() async {
        let defaults = Self.defaults()
        let check = UpdateCheck(repository: "o/r", currentVersion: "1.2.0", defaults: defaults) { _ in Self.release("v1.3.0") }
        #expect(check.takeNotice() == nil)
        await check.checkNow()
        #expect(check.takeNotice()?.version == "1.3.0")
        #expect(check.takeNotice() == nil)
        let relaunched = UpdateCheck(repository: "o/r", currentVersion: "1.2.0", defaults: defaults) { _ in Self.release("v1.4.0") }
        #expect(relaunched.takeNotice() == nil)
        await relaunched.checkNow()
        #expect(relaunched.takeNotice()?.version == "1.4.0")
    }

    @Test("a shorter interval asks again sooner")
    func shorterInterval() async {
        let now = Date()
        let check = UpdateCheck(repository: "o/r", currentVersion: "1.2.0", defaults: Self.defaults(),
                                interval: 4 * 3600) { _ in Self.release("v1.2.0") }
        #expect(await check.checkIfDue(now: now) == .upToDate)
        #expect(await check.checkIfDue(now: now.addingTimeInterval(3 * 3600)) == nil)
        #expect(await check.checkIfDue(now: now.addingTimeInterval(5 * 3600)) == .upToDate)
    }

    @Test("skipping hides that version until a later one appears")
    func skipping() async {
        let defaults = Self.defaults()
        var tag = "v1.3.0"
        let check = UpdateCheck(repository: "o/r", currentVersion: "1.2.0", defaults: defaults) { [tag] _ in Self.release(tag) }
        await check.checkNow()
        check.skip()
        #expect(check.available == nil)
        await check.checkNow()
        #expect(check.available == nil)
        tag = "v1.4.0"
        let later = UpdateCheck(repository: "o/r", currentVersion: "1.2.0", defaults: defaults) { [tag] _ in Self.release(tag) }
        await later.checkNow()
        #expect(later.available?.version == "1.4.0")
    }
}
