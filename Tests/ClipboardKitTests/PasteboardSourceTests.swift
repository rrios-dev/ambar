import AppKit
import Foundation
import Testing

@testable import ClipboardKit

/// Who an entry says it came from, when the item itself declares it.
///
/// A copy made on another computer reaches the Mac's pasteboard through the app that syncs
/// it, while some unrelated Mac app is frontmost. Recording that frontmost app as the source
/// would be false: the entry must name the computer and the app the copy came from, and an
/// app's own declaration (`org.nspasteboard.source`) beats the frontmost guess.
@Suite("The source an item declares beats the frontmost app", .serialized)
@MainActor
struct PasteboardSourceTests {

    static let syncBundle = "dev.rrios.batuta"

    /// A private pasteboard holding one text item with the given extra types.
    static func board(
        _ text: String = "copied elsewhere",
        source: String? = nil,
        origin: String? = nil,
        originData: Data? = nil,
        extra: [String] = []
    ) -> NSPasteboard {
        let board = NSPasteboard(name: .init("dev.rrios.ambar.tests.source.\(UUID().uuidString)"))
        board.clearContents()
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        if let source { item.setString(source, forType: .init(UTIs.source)) }
        if let origin { item.setData(Data(origin.utf8), forType: .init(UTIs.remoteOrigin)) }
        if let originData { item.setData(originData, forType: .init(UTIs.remoteOrigin)) }
        for type in extra { item.setData(Data(), forType: .init(type)) }
        board.writeObjects([item])
        return board
    }

    static func monitor(_ board: NSPasteboard) -> ClipboardMonitor {
        let monitor = ClipboardMonitor(pasteboard: board, interval: 3600)
        monitor.frontmostApplication = { (bundleID: "com.apple.Terminal", name: "Terminal") }
        monitor.applicationName = { $0 == Self.syncBundle ? "Batuta" : nil }
        return monitor
    }

    /// Runs one real poll and returns what it captured and every outcome it reported.
    static func capture(_ monitor: ClipboardMonitor) -> (items: [CapturedItem], outcomes: [CaptureOutcome]) {
        var items: [CapturedItem] = []
        var outcomes: [CaptureOutcome] = []
        monitor.onOutcome = { outcomes.append($0) }
        monitor.start(captureExisting: true) { items.append($0) }
        monitor.stop()
        return (items, outcomes)
    }

    // MARK: - A remote copy

    @Test("a remote copy names the computer and the app, with the writer's bundle")
    func remoteCopyNamesDeviceAndApp() {
        let board = Self.board(source: Self.syncBundle, origin: #"{"device":"Linux","app":"firefox"}"#)
        let (items, _) = Self.capture(Self.monitor(board))

        #expect(items.count == 1)
        #expect(items.first?.sourceName == "Linux · Firefox")
        #expect(items.first?.sourceBundle == Self.syncBundle)
    }

    @Test("an app name that is not a lowercase class keeps its own capitals")
    func remoteAppNameKeepsItsCapitals() {
        let board = Self.board(source: Self.syncBundle, origin: #"{"device":"Linux","app":"LibreOffice"}"#)
        #expect(Self.capture(Self.monitor(board)).items.first?.sourceName == "Linux · LibreOffice")
    }

    @Test("with no app, or an empty one, the source is the computer alone")
    func remoteCopyWithoutApp() {
        for origin in [#"{"device":"Linux"}"#, #"{"device":"Linux","app":""}"#, #"{"device":"Linux","app":"  "}"#] {
            let board = Self.board(source: Self.syncBundle, origin: origin)
            #expect(Self.capture(Self.monitor(board)).items.first?.sourceName == "Linux", "origin \(origin)")
        }
    }

    @Test("a remote copy with no declared writer still never claims the frontmost app")
    func remoteCopyWithoutWriter() {
        let board = Self.board(origin: #"{"device":"Linux","app":"firefox"}"#)
        let item = Self.capture(Self.monitor(board)).items.first
        #expect(item?.sourceName == "Linux · Firefox")
        #expect(item?.sourceBundle == nil)
    }

    @Test("a name with line breaks or runs of spaces reads as one line")
    func remoteNamesAreOneLine() {
        let board = Self.board(origin: #"{"device":"  Linux\n  box ","app":"gnome\tterminal"}"#)
        #expect(Self.capture(Self.monitor(board)).items.first?.sourceName == "Linux box · Gnome terminal")
    }

    // MARK: - Malformed origins fall back

    @Test("malformed, empty-device or oversized origin JSON is ignored: the frontmost app as today")
    func malformedOriginFallsBack() {
        let oversized = #"{"device":"Linux","app":""# + String(repeating: "a", count: 5000) + #""}"#
        let origins = [
            "not json",
            #"{"app":"firefox"}"#,
            #"{"device":"","app":"firefox"}"#,
            #"{"device":42}"#,
            #"["Linux"]"#,
            oversized,
        ]
        for origin in origins {
            let board = Self.board(origin: origin)
            let item = Self.capture(Self.monitor(board)).items.first
            #expect(item?.sourceName == "Terminal", "origin \(origin.prefix(40))")
            #expect(item?.sourceBundle == "com.apple.Terminal")
        }
    }

    @Test("an origin that is not UTF-8 is ignored")
    func nonUTF8OriginFallsBack() {
        let board = Self.board(originData: Data([0xFF, 0xFE, 0x7B]))
        #expect(Self.capture(Self.monitor(board)).items.first?.sourceName == "Terminal")
    }

    @Test("a malformed origin from a declared writer falls back to the writer, not the frontmost app")
    func malformedOriginWithWriter() {
        let board = Self.board(source: Self.syncBundle, origin: "{")
        let item = Self.capture(Self.monitor(board)).items.first
        #expect(item?.sourceName == "Batuta")
        #expect(item?.sourceBundle == Self.syncBundle)
    }

    // MARK: - A declared source alone

    @Test("org.nspasteboard.source alone names the declaring app instead of the frontmost one")
    func declaredSourceAlone() {
        let board = Self.board(source: Self.syncBundle)
        let item = Self.capture(Self.monitor(board)).items.first
        #expect(item?.sourceBundle == Self.syncBundle)
        #expect(item?.sourceName == "Batuta")
    }

    @Test("a declared source whose name cannot be resolved keeps the bundle and no name")
    func declaredSourceUnresolved() {
        let board = Self.board(source: "com.example.not-installed")
        let item = Self.capture(Self.monitor(board)).items.first
        #expect(item?.sourceBundle == "com.example.not-installed")
        #expect(item?.sourceName == nil)
    }

    @Test("a declared source that is not a bundle identifier is ignored")
    func invalidDeclaredSource() {
        for source in ["", "   ", "has space.id", String(repeating: "a", count: 300)] {
            let board = Self.board(source: source)
            let item = Self.capture(Self.monitor(board)).items.first
            #expect(item?.sourceBundle == "com.apple.Terminal", "source \(source.prefix(20))")
        }
    }

    // MARK: - Exclusions

    @Test("a remote copy is kept while an excluded app is frontmost on the Mac")
    func remoteCopyIgnoresFrontmostExclusion() {
        let board = Self.board(source: Self.syncBundle, origin: #"{"device":"Linux","app":"firefox"}"#)
        let monitor = Self.monitor(board)
        monitor.frontmostApplication = { (bundleID: "com.1password.1password", name: "1Password") }
        monitor.excludedBundleIDs = ["com.1password.1password"]

        #expect(Self.capture(monitor).items.first?.sourceName == "Linux · Firefox")
    }

    @Test("a remote copy is dropped when its writer itself is excluded, and says why")
    func remoteCopyFromExcludedWriter() {
        let board = Self.board(source: Self.syncBundle, origin: #"{"device":"Linux","app":"firefox"}"#)
        let monitor = Self.monitor(board)
        monitor.excludedBundleIDs = [Self.syncBundle]

        let (items, outcomes) = Self.capture(monitor)
        #expect(items.isEmpty)
        #expect(outcomes.contains {
            if case .ignored(.excludedApp(Self.syncBundle)) = $0 { return true } else { return false }
        })
    }

    @Test("a declared source alone is dropped if either it or the frontmost app is excluded")
    func declaredSourceAloneHonoursBothExclusions() {
        let excludedFrontmost = Self.monitor(Self.board(source: "com.example.writer"))
        excludedFrontmost.excludedBundleIDs = ["com.apple.Terminal"]
        #expect(Self.capture(excludedFrontmost).items.isEmpty)

        let excludedWriter = Self.monitor(Self.board(source: "com.example.writer"))
        excludedWriter.excludedBundleIDs = ["com.example.writer"]
        #expect(Self.capture(excludedWriter).items.isEmpty)

        let neither = Self.monitor(Self.board(source: "com.example.writer"))
        neither.excludedBundleIDs = ["com.1password.1password"]
        #expect(Self.capture(neither).items.first?.sourceBundle == "com.example.writer")
    }

    // MARK: - Private marks still win

    @Test("a private mark still drops an item that declares a remote origin")
    func privateMarksStillWin() {
        for mark in [UTIs.concealed, UTIs.transient, UTIs.autoGenerated] {
            let board = Self.board(
                source: Self.syncBundle,
                origin: #"{"device":"Linux","app":"firefox"}"#,
                extra: [mark]
            )
            #expect(Self.capture(Self.monitor(board)).items.isEmpty, "mark \(mark)")
        }
    }

    @Test("the origin types are never stored, so pasting the entry back cannot replay them")
    func originTypesAreNotStored() {
        let board = Self.board(source: Self.syncBundle, origin: #"{"device":"Linux","app":"firefox"}"#)
        let utis = Self.capture(Self.monitor(board)).items.first?.representations.map(\.uti) ?? []
        #expect(!utis.isEmpty)
        #expect(!utis.contains(UTIs.source))
        #expect(!utis.contains(UTIs.remoteOrigin))
    }

    // MARK: - Pure pieces

    @Test("only an all-lowercase app name gets its first letter capitalised")
    func appDisplayName() {
        #expect(PasteboardSource.displayAppName("firefox") == "Firefox")
        #expect(PasteboardSource.displayAppName("gnome-terminal") == "Gnome-terminal")
        #expect(PasteboardSource.displayAppName("LibreOffice") == "LibreOffice")
        #expect(PasteboardSource.displayAppName("code") == "Code")
        #expect(PasteboardSource.displayAppName("über") == "Über")
        #expect(PasteboardSource.displayAppName("1password") == "1password")
    }
}
