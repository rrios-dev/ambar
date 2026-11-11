import AppKit
import Foundation

/// The source a pasteboard item declares about itself, read before the frontmost app is
/// consulted.
///
/// Two declarations, from the most specific to the least:
///
/// 1. **A remote origin** (`UTIs.remoteOrigin`): UTF-8 JSON
///    `{"device": "<computer>", "app": "<app on that computer>"}`, written by an app that
///    syncs copies made on another computer. The Mac's frontmost app had nothing to do with
///    such a copy, so it is never recorded as its source.
/// 2. **The writer** (`UTIs.source`, the nspasteboard.org convention): the bundle identifier
///    of the app that wrote the item. It is a fact; the frontmost app is only a guess.
///
/// Both are untrusted input from any process on the Mac: the JSON is capped, every field is
/// validated, and anything malformed is ignored as if it were absent.
public struct PasteboardSource: Sendable, Equatable {
    /// Where a copy made on another computer came from.
    public struct RemoteOrigin: Sendable, Equatable {
        public let device: String
        public let app: String?
    }

    /// The bundle identifier of the app that wrote the item, if it said so.
    public let writerBundleID: String?
    /// The computer and app of a remote copy, if the item carries a valid origin.
    public let remote: RemoteOrigin?

    /// Above this the origin JSON is ignored: it names a computer and an app, and a few
    /// hundred bytes are plenty. The cap keeps a hostile writer from making every poll parse
    /// megabytes.
    public static let maximumOriginBytes = 4 * 1024
    /// Longest name kept for a device or an app; longer ones are cut with an ellipsis.
    static let maximumNameLength = 64
    /// Reverse-DNS identifiers are short; anything longer is not one.
    static let maximumBundleIDLength = 255

    /// Reads the declarations of an item. `nil` when it declares nothing usable.
    public static func read(from item: NSPasteboardItem) -> PasteboardSource? {
        let writer = item.string(forType: .init(UTIs.source)).flatMap(validBundleID)
        let remote = item.data(forType: .init(UTIs.remoteOrigin)).flatMap(parseRemoteOrigin)
        guard writer != nil || remote != nil else { return nil }
        return PasteboardSource(writerBundleID: writer, remote: remote)
    }

    /// Parses the origin JSON; `nil` when it is oversized, not UTF-8 JSON, or has no device.
    static func parseRemoteOrigin(_ data: Data) -> RemoteOrigin? {
        guard !data.isEmpty, data.count <= maximumOriginBytes else { return nil }
        struct Payload: Decodable {
            let device: String
            let app: String?
        }
        guard let payload = try? JSONDecoder().decode(Payload.self, from: data) else { return nil }
        guard let device = oneLine(payload.device) else { return nil }
        return RemoteOrigin(device: device, app: payload.app.flatMap(oneLine))
    }

    /// The name an entry shows: "<device> · <App>" for a remote copy, else `nil` (the
    /// writer's name is resolved by the caller, which knows how to look apps up).
    public var remoteDisplayName: String? {
        guard let remote else { return nil }
        guard let app = remote.app else { return remote.device }
        return "\(remote.device) · \(Self.displayAppName(app))"
    }

    /// X11 window classes arrive in lowercase (`firefox`, `gnome-terminal`); the first
    /// letter is capitalised so they read like app names. A name with any capital already
    /// chose its own casing (`LibreOffice`) and is kept as it is.
    static func displayAppName(_ app: String) -> String {
        guard app == app.lowercased(), let first = app.first else { return app }
        return first.uppercased() + app.dropFirst()
    }

    private static func validBundleID(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= maximumBundleIDLength else { return nil }
        guard !trimmed.contains(where: { $0.isWhitespace || $0.isNewline }) else { return nil }
        return trimmed
    }

    /// Collapses whitespace so a name always reads as one line, and caps its length.
    private static func oneLine(_ raw: String) -> String? {
        let collapsed = PasteboardReader.singleLinePreview(raw, limit: maximumNameLength)
        return collapsed.isEmpty ? nil : collapsed
    }

    /// Name of an installed or running app, from its bundle identifier.
    ///
    /// The running app is asked first: whoever just wrote to the pasteboard is almost always
    /// still running, and its localized name needs no disk access. `nil` when the identifier
    /// matches nothing on this Mac — a dev build under another identifier, say — and the entry
    /// then shows no name rather than a bundle identifier nobody reads.
    @MainActor
    public static func installedApplicationName(_ bundleID: String) -> String? {
        if let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .first?.localizedName
        {
            return running
        }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return nil
        }
        let name = FileManager.default.displayName(atPath: url.path(percentEncoded: false))
        return name.hasSuffix(".app") ? String(name.dropLast(4)) : name
    }
}
