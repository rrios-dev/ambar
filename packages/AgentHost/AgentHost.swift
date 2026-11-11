import Foundation
import MCPKit
import Observation

/// An app's side of agent access (docs/initiatives/mac-apps-mcp/DESIGN.md §3, §5): the
/// switch, the access log, the socket where the app's MCP executable hands over what only
/// the running app may do, and registering that executable with Claude Code and Codex.
///
/// Generic over the app's request and reply; the app gives it what is its own: the names,
/// the replies for a refused, a misunderstood and an orphaned request, and the handler.
/// Ámbar and Quill each grew this same shape as their `AgentService`; Batuta is the third
/// app and the first built on this type.
///
/// The switch is consent and clarity, not a security boundary (DESIGN §5): the MCP
/// executable reads the same file on every call, and this host refuses too, because the
/// app owns the switch. The socket listens only while access is on.
@MainActor
@Observable
public final class AgentHost<Request: Decodable & Sendable, Reply: Encodable & Sendable> {
    /// What is particular to one app.
    public struct Configuration: Sendable {
        /// The name agents see the MCP server under ("ambar").
        public var serverName: String
        /// The MCP executable, next to the app's own in `Contents/MacOS` ("ambar-mcp").
        public var serverExecutable: String
        /// What every request gets while access is off.
        public var refusal: Reply
        /// What a request gets when the app is going away and nobody can answer it.
        public var quitting: Reply
        /// What bytes that are not a request get: usually "update the app and its MCP
        /// executable together".
        public var notUnderstood: Reply
        /// The app's bundle, whose `Contents/MacOS` holds the MCP executable.
        public var bundleURL: URL
        /// How many entries of the access log the app shows.
        public var logLimit: Int

        public init(
            serverName: String,
            serverExecutable: String,
            refusal: Reply,
            quitting: Reply,
            notUnderstood: Reply,
            bundleURL: URL = Bundle.main.bundleURL,
            logLimit: Int = 12
        ) {
            self.serverName = serverName
            self.serverExecutable = serverExecutable
            self.refusal = refusal
            self.quitting = quitting
            self.notUnderstood = notUnderstood
            self.bundleURL = bundleURL
            self.logLimit = logLimit
        }
    }

    /// Something that went wrong without stopping the app, for its log.
    public enum Problem: Equatable, Sendable {
        /// The switch changed in memory but could not be written: the MCP executable, which
        /// reads the file, keeps the previous answer.
        case accessNotSaved(String)
        /// The socket could not be opened: requests that need the app fail as "not open".
        case socketUnavailable(String)
    }

    /// Registers or removes the MCP server with a client. `ClientRegistration.run` by
    /// default; tests pass a fake, since the real one runs the client's command line.
    public typealias Register = @Sendable (ClientRegistration, AgentClient) async -> AgentClient.Outcome

    public private(set) var access: AgentAccess
    /// The newest entries of the access log the MCP executable writes, newest first.
    public private(set) var recent: [AccessLog.Entry] = []
    /// What the last Connect or Disconnect said, per client.
    public private(set) var clientStatus: [AgentClient: ClientStatus] = [:]
    /// The client a Connect or Disconnect is running for.
    public private(set) var working: AgentClient?
    /// Whether the socket is open.
    public private(set) var isListening = false

    @ObservationIgnored public let directory: URL
    @ObservationIgnored public let configuration: Configuration
    @ObservationIgnored private let handler: @MainActor (Request) async -> Reply
    @ObservationIgnored private let register: Register
    @ObservationIgnored private let onProblem: @MainActor (Problem) -> Void
    @ObservationIgnored private let log: AccessLog
    @ObservationIgnored private var listener: LocalChannel.Listener?

    /// Reads the switch and the log from `directory`. Opens no socket: `start()` does, so
    /// tests can build a host without one.
    ///
    /// - Parameters:
    ///   - directory: the app's data directory, shared with its MCP executable.
    ///   - handler: answers a request while access is on; the app's own work.
    ///   - onProblem: told about what failed without stopping the app (a log line).
    public init(
        directory: URL,
        configuration: Configuration,
        register: @escaping Register = ClientRegistration.run,
        onProblem: @escaping @MainActor (Problem) -> Void = { _ in },
        handler: @escaping @MainActor (Request) async -> Reply
    ) {
        self.directory = directory
        self.configuration = configuration
        self.register = register
        self.onProblem = onProblem
        self.handler = handler
        access = AgentAccess.load(from: directory)
        log = AccessLog(directory: directory)
        refreshLog()
    }

    /// The MCP executable next to the app's own, the path agents are given.
    public var serverPath: String {
        configuration.bundleURL.appendingPathComponent("Contents/MacOS/\(configuration.serverExecutable)").path
    }

    /// The socket's path, inside the data directory.
    public var socketPath: String {
        AgentChannel.socketPath(dataDirectory: directory)
    }

    // MARK: Switch and socket

    /// Starts listening if access is on.
    public func start() {
        updateListener()
    }

    /// Closes the socket; the switch stays as it is.
    public func stop() {
        listener?.stop()
        listener = nil
        if isListening { isListening = false }
    }

    /// Turns access on or off: written to the data directory first (the MCP executable
    /// reads it on every call), then the socket opens or closes.
    public func setEnabled(_ enabled: Bool) {
        access.enabled = enabled
        // Private before the switch's file lands in it; a failure shows up as the save's.
        try? Self.makePrivate(directory)
        do {
            try access.save(to: directory)
        } catch {
            onProblem(.accessNotSaved("\(error)"))
        }
        updateListener()
    }

    /// Answers one request: the refusal while access is off, else the app's handler.
    public func handle(_ request: Request) async -> Reply {
        // The MCP executable checks the switch too, but the app owns it.
        guard access.enabled else { return configuration.refusal }
        defer { refreshLog() }
        return await handler(request)
    }

    /// The socket listens only while access is on.
    private func updateListener() {
        guard access.enabled else {
            stop()
            return
        }
        guard listener == nil else { return }
        let quitting = configuration.quitting
        let notUnderstood = configuration.notUnderstood
        do {
            try Self.makePrivate(directory)
            listener = try LocalChannel.Listener(path: socketPath) { [weak self] data in
                guard let request = AgentChannel.decode(Request.self, from: data) else {
                    return AgentChannel.encode(notUnderstood)
                }
                return AgentChannel.encode(await self?.handle(request) ?? quitting)
            }
            isListening = true
        } catch {
            onProblem(.socketUnavailable("\(error)"))
        }
    }

    /// Creates the data directory readable by this user only (0700), or closes an existing
    /// one to that: the socket, the switch and the access log live in it, and the MCP
    /// executable's log or an earlier version may have created it open to others.
    static func makePrivate(_ directory: URL) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    }

    // MARK: Access log

    public func refreshLog() {
        let entries = log.recent(configuration.logLimit)
        if entries != recent { recent = entries }
    }

    public func clearLog() {
        log.clear()
        refreshLog()
    }

    // MARK: Clients

    /// Registers the MCP executable with a client through its own command line. A previous
    /// registration is removed first, so connecting again after moving the app fixes the path.
    public func connect(_ client: AgentClient) async {
        await run(.connect(server: configuration.serverName, path: serverPath), with: client, connecting: true)
    }

    public func disconnect(_ client: AgentClient) async {
        await run(.disconnect(server: configuration.serverName), with: client, connecting: false)
    }

    private func run(_ registration: ClientRegistration, with client: AgentClient, connecting: Bool) async {
        working = client
        defer { working = nil }
        let outcome = await register(registration, client)
        clientStatus[client] = ClientStatus(outcome, connecting: connecting)
    }
}
