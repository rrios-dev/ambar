import AmbarAgent
import Foundation
import MCPKit
import Observation

/// Ámbar's side of agent access (docs/initiatives/mac-apps-mcp/DESIGN.md): the switch, the
/// access log, the socket where `ambar-mcp` hands over what only the app may change (the
/// dictionary it keeps in memory), and registering `ambar-mcp` with Claude Code and Codex.
@MainActor
@Observable
final class AgentService {
    private(set) var access: AgentAccess
    private(set) var recent: [AccessLog.Entry] = []
    /// What the last Connect or Disconnect said, per client.
    private(set) var clientStatus: [AgentClient: String] = [:]
    private(set) var working: AgentClient?

    @ObservationIgnored private let directory: URL
    @ObservationIgnored private let dictionary: PersonalDictionary
    @ObservationIgnored private var listener: LocalChannel.Listener?
    @ObservationIgnored private let log: AccessLog

    init(directory: URL, dictionary: PersonalDictionary) {
        self.directory = directory
        self.dictionary = dictionary
        access = AgentAccess.load(from: directory)
        log = AccessLog(directory: directory)
        refreshLog()
    }

    /// Starts listening if access is on. Not in `init`: tests build the model without a socket.
    func start() { updateListener() }

    /// `ambar-mcp` next to the app's own executable.
    static var serverPath: String {
        Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/ambar-mcp").path
    }

    func setEnabled(_ enabled: Bool) {
        access.enabled = enabled
        try? access.save(to: directory)
        updateListener()
    }

    func refreshLog() { recent = log.recent(12) }

    func clearLog() {
        log.clear()
        refreshLog()
    }

    /// The socket listens only while access is on.
    private func updateListener() {
        guard access.enabled else {
            listener?.stop()
            listener = nil
            return
        }
        guard listener == nil else { return }
        listener = try? LocalChannel.Listener(path: AmbarRequest.socketPath(dataDirectory: directory)) { [weak self] data in
            let reply: AmbarReply
            if let request = try? JSONDecoder().decode(AmbarRequest.self, from: data) {
                reply = await self?.handle(request) ?? .failure("Ámbar is quitting.")
            } else {
                reply = .failure("Ámbar did not understand the request; update Ámbar and ambar-mcp together.")
            }
            return (try? JSONEncoder().encode(reply)) ?? Data()
        }
    }

    func handle(_ request: AmbarRequest) -> AmbarReply {
        // The server checks the switch too, but the app owns it.
        guard access.enabled else { return .failure(AmbarTools.refusal) }
        defer { refreshLog() }
        switch request {
        case .addWord(let written, let heard):
            let existed = dictionary.entries.contains { $0.written.caseInsensitiveCompare(written) == .orderedSame }
            guard let entry = dictionary.add(written: written, heard: heard) else {
                return .failure("“\(written)” cannot be added to the dictionary.")
            }
            return AmbarReply(text: existed
                ? "“\(entry.written)” was already in the dictionary; it now also knows it as: \(entry.heard.joined(separator: ", "))."
                : "Added “\(entry.written)” to Ámbar's dictation dictionary.")
        }
    }

    // MARK: Clients

    /// Registers `ambar-mcp` with a client through its own CLI, in a login shell so the user's
    /// PATH applies. A previous registration is removed first, so connecting again after
    /// moving Ámbar fixes the path.
    /// The name agents see this server under.
    static let server = "ambar"

    func connect(_ client: AgentClient) async {
        working = client
        defer { working = nil }
        clientStatus[client] = Self.status(await client.connect(server: Self.server, path: Self.serverPath), connected: true, client: client)
    }

    func disconnect(_ client: AgentClient) async {
        working = client
        defer { working = nil }
        clientStatus[client] = Self.status(await client.disconnect(server: Self.server), connected: false, client: client)
    }

    private static func status(_ outcome: AgentClient.Outcome, connected: Bool, client: AgentClient) -> String {
        switch outcome {
        case .done:
            connected
                ? String(localized: "agents.connected \(client.name)", bundle: .localized)
                : String(localized: "agents.disconnected \(client.name)", bundle: .localized)
        case .notInstalled:
            String(localized: "agents.notInstalled \(client.name)", bundle: .localized)
        case .failed(let line):
            String(localized: "agents.failed \(line)", bundle: .localized)
        }
    }
}
