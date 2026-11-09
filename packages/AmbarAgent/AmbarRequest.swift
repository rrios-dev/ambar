import Foundation
import MCPKit

/// What `ambar-mcp` asks the running app to do: change what the app keeps in memory and
/// writes itself (the personal dictionary), which a second writer would race.
public enum AmbarRequest: Codable, Equatable, Sendable {
    /// Teach the dictation dictionary a word, with what the engine mishears it as.
    case addWord(written: String, heard: String?)

    /// The app's socket, inside its data directory.
    public static func socketPath(dataDirectory: URL) -> String {
        LocalChannel.path(named: "agent", in: dataDirectory)
    }

    public func send(dataDirectory: URL) async throws -> AmbarReply {
        let reply = try await LocalChannel.send(try JSONEncoder().encode(self), to: Self.socketPath(dataDirectory: dataDirectory),
                                                timeout: .seconds(10))
        return try JSONDecoder().decode(AmbarReply.self, from: reply)
    }
}

/// The app's answer: what happened, or why not.
public struct AmbarReply: Codable, Equatable, Sendable {
    public var text: String?
    public var error: String?

    public init(text: String? = nil, error: String? = nil) {
        self.text = text
        self.error = error
    }

    public static func failure(_ message: String) -> AmbarReply { AmbarReply(error: message) }
}
