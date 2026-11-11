import MCPKit

/// What the last Connect or Disconnect of an agent client came to, for the app to show.
///
/// An enum, not a sentence: each app words it in its own strings table, which is the one
/// thing that kept this shape out of a shared package.
public enum ClientStatus: Equatable, Sendable {
    /// The app's MCP server is registered with the client.
    case connected
    /// The registration was removed.
    case disconnected
    /// The client's command-line tool is not installed, or not on the user's PATH.
    case notInstalled
    /// The client's tool ran and failed: its last line of output.
    case failed(String)

    /// The status a client's command left, after connecting or disconnecting.
    public init(_ outcome: AgentClient.Outcome, connecting: Bool) {
        switch outcome {
        case .done: self = connecting ? .connected : .disconnected
        case .notInstalled: self = .notInstalled
        case .failed(let line): self = .failed(line)
        }
    }
}

/// What registering a server with an agent client asks for.
public enum ClientRegistration: Equatable, Sendable {
    /// Register `server` (the name the agent sees) at `path`, replacing a previous one.
    case connect(server: String, path: String)
    /// Remove the registration of `server`.
    case disconnect(server: String)

    /// Runs the registration through the client's own command-line tool
    /// (`AgentClient.connect` / `disconnect`, in a login shell). The default of `AgentHost`.
    @Sendable
    public static func run(_ registration: ClientRegistration, with client: AgentClient) async -> AgentClient.Outcome {
        switch registration {
        case .connect(let server, let path): await client.connect(server: server, path: path)
        case .disconnect(let server): await client.disconnect(server: server)
        }
    }
}
