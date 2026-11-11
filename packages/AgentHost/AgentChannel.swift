import Foundation
import MCPKit

/// The two ends of an app's agent socket, generic over the app's own request and reply.
///
/// An app's MCP executable (`ambar-mcp`, `quill-mcp`, `batuta-mcp`) hands the running app
/// what only the app may do over MCPKit's `LocalChannel`: one JSON request, one JSON reply,
/// on a socket named `agent` inside the app's data directory. Every app had its own copy of
/// these lines; the shape is the same, only the message types and the app's name differ.
public enum AgentChannel {
    /// The socket's name inside the data directory, the same in every app.
    public static let socketName = "agent"

    /// The app's socket, inside its data directory (or a short temporary path when the
    /// directory's path would not fit in `sun_path`, as `LocalChannel.path` decides).
    public static func socketPath(dataDirectory: URL) -> String {
        LocalChannel.path(named: socketName, in: dataDirectory)
    }

    /// Sends `request` to the running app and decodes its reply, once the process on the
    /// socket passes `trust` (ServerPeer.swift): the same user, and the same team when this
    /// executable is signed by one.
    ///
    /// - Throws: `Failure.untrustedServer` before anything is written when the process on
    ///   the socket is not the app; `LocalChannel.Failure` when the app is not running or
    ///   does not answer; a decoding error when the reply is not a `Reply`.
    public static func send<Reply: Decodable>(
        _ request: some Encodable,
        dataDirectory: URL,
        timeout: Duration,
        trust: ServerTrust = .sameUserAndTeam,
        expecting: Reply.Type = Reply.self
    ) async throws -> Reply {
        let data = try JSONEncoder().encode(request)
        let reply = try await send(data, to: socketPath(dataDirectory: dataDirectory), timeout: timeout, trust: trust)
        return try JSONDecoder().decode(Reply.self, from: reply)
    }

    /// The request in `data`, or nil when the bytes are not one (an `*-mcp` of another
    /// version, or anything else that reached the socket).
    public static func decode<Request: Decodable>(_ type: Request.Type, from data: Data) -> Request? {
        try? JSONDecoder().decode(Request.self, from: data)
    }

    /// The reply as the socket carries it; empty when it cannot be encoded, which the other
    /// end reads as no answer.
    public static func encode(_ reply: some Encodable) -> Data {
        (try? JSONEncoder().encode(reply)) ?? Data()
    }

    /// Runs one exchange with the app for a tool and turns a failed exchange into a
    /// `ToolError` the agent can act on: the app is not open, something that is not the app
    /// holds its socket (nothing is forwarded), it was updated since this server started
    /// (reconnect), or it did not answer. Other errors pass through.
    ///
    /// - Parameters:
    ///   - app: the app's name as the user knows it ("Ámbar").
    ///   - server: the name agents see the MCP server under ("ambar").
    ///   - reconnect: what to say when the app was updated after the server started
    ///     (`ExecutableIdentity.reconnectMessage`).
    ///   - replaced: whether the server's executable was replaced since it started.
    public static func exchange<Reply>(
        app: String,
        server: String,
        reconnect: String,
        replaced: () -> Bool,
        _ body: () async throws -> Reply
    ) async throws -> Reply {
        do {
            return try await body()
        } catch LocalChannel.Failure.notRunning {
            throw ToolError(notOpen(app: app))
        } catch Failure.untrustedServer {
            throw ToolError(notSafe(app: app))
        } catch LocalChannel.Failure.noReply where replaced() {
            // The app hangs up on a process whose code no longer matches its file on disk.
            throw ToolError(reconnect)
        } catch LocalChannel.Failure.noReply {
            throw ToolError(noAnswer(app: app, server: server))
        }
    }

    /// What a tool says when the app is not running.
    public static func notOpen(app: String) -> String {
        "\(app) is not open. Ask the user to open \(app), then try again."
    }

    /// What a tool says when the app did not answer in time.
    public static func noAnswer(app: String, server: String) -> String {
        "\(app) did not answer. If \(app) was just updated, reconnect the \(server) MCP server; otherwise try again."
    }
}
