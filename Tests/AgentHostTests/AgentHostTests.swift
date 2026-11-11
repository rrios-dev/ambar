import AgentHost
import Foundation
import MCPKit
import Synchronization
import Testing

// The generic side of agent access every app shares: the switch, the socket that opens only
// while it is on, the access log, the client registrations, and the exchange as a tool sees
// it. Exercised with a made-up request and reply, so nothing here is any one app's.

private enum Ask: Codable, Equatable, Sendable {
    case echo(String)
}

private struct Answer: Codable, Equatable, Sendable {
    var text: String?
    var error: String?
}

private let configuration = AgentHost<Ask, Answer>.Configuration(
    serverName: "sample",
    serverExecutable: "sample-mcp",
    refusal: Answer(error: "off"),
    quitting: Answer(error: "quitting"),
    notUnderstood: Answer(error: "did not understand"),
    bundleURL: URL(fileURLWithPath: "/Applications/Sample.app"),
    logLimit: 3
)

/// What the handler was asked, on the main actor like the handler itself.
@MainActor
private final class Handled {
    var requests: [Ask] = []
}

/// The registrations a fake client was asked for.
private final class Registrations: Sendable {
    private let calls = Mutex<[ClientRegistration]>([])

    func record(_ registration: ClientRegistration) { calls.withLock { $0.append(registration) } }

    var all: [ClientRegistration] { calls.withLock { $0 } }
}

/// A short directory for a socket (`sun_path` holds 104 bytes).
private func makeShortDirectory() -> URL {
    let name = "ah-" + UUID().uuidString.prefix(8).lowercased()
    let url = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true).appendingPathComponent(name, isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@MainActor
private struct Rig {
    let host: AgentHost<Ask, Answer>
    let handled: Handled
    let directory: URL
    let registrations: Registrations
    let problems: ProblemLog

    init(directory: URL = makeShortDirectory(), outcome: AgentClient.Outcome = .done) {
        let handled = Handled()
        let registrations = Registrations()
        let problems = ProblemLog()
        self.handled = handled
        self.directory = directory
        self.registrations = registrations
        self.problems = problems
        host = AgentHost(
            directory: directory,
            configuration: configuration,
            register: { registration, _ in
                registrations.record(registration)
                return outcome
            },
            onProblem: { problems.all.append($0) },
            handler: { request in
                handled.requests.append(request)
                switch request {
                case .echo(let text): return Answer(text: text)
                }
            })
    }

    var socketExists: Bool { FileManager.default.fileExists(atPath: host.socketPath) }

    func finish() {
        host.stop()
        try? FileManager.default.removeItem(at: directory)
    }
}

@MainActor
private final class ProblemLog {
    var all: [AgentHost<Ask, Answer>.Problem] = []
}

@Suite("AgentHost: the switch and the socket", .serialized)
@MainActor
struct AgentHostSwitchTests {
    @Test("a fresh app has access off, opens no socket on start, and refuses without asking the handler")
    func offByDefault() async {
        let rig = Rig()
        defer { rig.finish() }
        #expect(rig.host.access.enabled == false)
        rig.host.start()
        #expect(rig.host.isListening == false)
        #expect(rig.socketExists == false)
        #expect(await rig.host.handle(.echo("hi")) == Answer(error: "off"))
        #expect(rig.handled.requests.isEmpty)
    }

    @Test("turning it on writes the file, opens the socket and lets requests through")
    func turningOn() async {
        let rig = Rig()
        defer { rig.finish() }
        rig.host.setEnabled(true)
        #expect(AgentAccess.load(from: rig.directory).enabled)
        #expect(rig.host.isListening)
        #expect(rig.socketExists)
        #expect(await rig.host.handle(.echo("hi")) == Answer(text: "hi"))
        #expect(rig.handled.requests == [.echo("hi")])
    }

    @Test("turning it off writes the file, closes the socket and refuses again")
    func turningOff() async {
        let rig = Rig()
        defer { rig.finish() }
        rig.host.setEnabled(true)
        rig.host.setEnabled(false)
        #expect(AgentAccess.load(from: rig.directory).enabled == false)
        #expect(rig.host.isListening == false)
        #expect(rig.socketExists == false)
        #expect(await rig.host.handle(.echo("hi")) == Answer(error: "off"))
        #expect(rig.handled.requests.isEmpty)
    }

    @Test("the choice of an earlier run is read on init, and the socket waits for start")
    func remembered() {
        let first = Rig()
        defer { first.finish() }
        first.host.setEnabled(true)
        first.host.stop()
        #expect(first.socketExists == false)
        let second = Rig(directory: first.directory)
        #expect(second.host.access.enabled)
        #expect(second.host.isListening == false)
        second.host.start()
        #expect(second.host.isListening)
        second.host.start()
        #expect(second.host.isListening)
        second.host.stop()
        #expect(second.host.isListening == false)
    }

    @Test("a request crosses the socket to the handler and the answer comes back")
    func roundTrip() async throws {
        let rig = Rig()
        defer { rig.finish() }
        rig.host.setEnabled(true)
        let answer: Answer = try await AgentChannel.send(Ask.echo("hola"), dataDirectory: rig.directory, timeout: .seconds(5))
        #expect(answer == Answer(text: "hola"))
        #expect(rig.handled.requests == [.echo("hola")])
    }

    @Test("bytes that are not a request get the app's not-understood reply, and the handler is not asked")
    func garbage() async throws {
        let rig = Rig()
        defer { rig.finish() }
        rig.host.setEnabled(true)
        let data = try await LocalChannel.send(Data("not json".utf8), to: rig.host.socketPath, timeout: .seconds(5))
        #expect(try JSONDecoder().decode(Answer.self, from: data) == Answer(error: "did not understand"))
        #expect(rig.handled.requests.isEmpty)
    }

    @Test("after the switch goes off, the next request finds nobody")
    func offClosesTheDoor() async throws {
        let rig = Rig()
        defer { rig.finish() }
        rig.host.setEnabled(true)
        rig.host.setEnabled(false)
        await #expect(throws: LocalChannel.Failure.notRunning) {
            let _: Answer = try await AgentChannel.send(Ask.echo("x"), dataDirectory: rig.directory, timeout: .seconds(5))
        }
    }

    @Test("a directory that cannot be written is reported, not fatal: the switch holds in memory and no socket opens")
    func problemsAreReported() throws {
        let parent = makeShortDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let blocker = parent.appendingPathComponent("file")
        try Data("x".utf8).write(to: blocker)
        let rig = Rig(directory: blocker)
        rig.host.setEnabled(true)
        #expect(rig.host.access.enabled)
        #expect(rig.host.isListening == false)
        #expect(rig.problems.all.count == 2)
        if case .accessNotSaved = rig.problems.all.first {} else { Issue.record("expected accessNotSaved first") }
        if case .socketUnavailable = rig.problems.all.last {} else { Issue.record("expected socketUnavailable last") }
        rig.host.stop()
    }
}

@Suite("AgentHost: the log, the server path and the clients")
@MainActor
struct AgentHostClientTests {
    @Test("the access log shows newest first, as many as configured, and clears")
    func accessLog() {
        let rig = Rig()
        defer { rig.finish() }
        #expect(rig.host.recent.isEmpty)
        let log = AccessLog(directory: rig.directory)
        for (offset, tool) in ["a", "b", "c", "d"].enumerated() {
            log.append(AccessLog.Entry(date: Date(timeIntervalSince1970: 1_791_970_200 + Double(offset)), client: "claude-code", tool: tool, succeeded: true))
        }
        rig.host.refreshLog()
        #expect(rig.host.recent.map(\.tool) == ["d", "c", "b"])
        rig.host.clearLog()
        #expect(rig.host.recent.isEmpty)
    }

    @Test("a handled request refreshes the log the MCP executable wrote")
    func handleRefreshesTheLog() async {
        let rig = Rig()
        defer { rig.finish() }
        rig.host.setEnabled(true)
        AccessLog(directory: rig.directory).append(AccessLog.Entry(date: Date(), client: nil, tool: "echo", succeeded: true))
        _ = await rig.host.handle(.echo("x"))
        #expect(rig.host.recent.map(\.tool) == ["echo"])
    }

    @Test("the server path is the executable next to the app's own")
    func serverPath() {
        let rig = Rig()
        defer { rig.finish() }
        #expect(rig.host.serverPath == "/Applications/Sample.app/Contents/MacOS/sample-mcp")
        #expect(rig.host.socketPath == AgentChannel.socketPath(dataDirectory: rig.directory))
        #expect(rig.host.socketPath == LocalChannel.path(named: "agent", in: rig.directory))
    }

    @Test("connect registers the server's name at its path, disconnect removes it, and each leaves a status")
    func connectAndDisconnect() async {
        let rig = Rig()
        defer { rig.finish() }
        await rig.host.connect(.claudeCode)
        #expect(rig.host.clientStatus[.claudeCode] == .connected)
        #expect(rig.host.working == nil)
        await rig.host.disconnect(.codex)
        #expect(rig.host.clientStatus[.codex] == .disconnected)
        #expect(rig.registrations.all == [
            .connect(server: "sample", path: "/Applications/Sample.app/Contents/MacOS/sample-mcp"),
            .disconnect(server: "sample"),
        ])
    }

    @Test("a client that is missing or fails says so in its status", arguments: [
        (AgentClient.Outcome.notInstalled, ClientStatus.notInstalled),
        (.failed("boom"), .failed("boom")),
    ])
    func failures(outcome: AgentClient.Outcome, status: ClientStatus) async {
        let rig = Rig(outcome: outcome)
        defer { rig.finish() }
        await rig.host.connect(.claudeCode)
        #expect(rig.host.clientStatus[.claudeCode] == status)
    }

    @Test("an outcome maps to a status, by direction")
    func statusMapping() {
        #expect(ClientStatus(.done, connecting: true) == .connected)
        #expect(ClientStatus(.done, connecting: false) == .disconnected)
        #expect(ClientStatus(.notInstalled, connecting: false) == .notInstalled)
        #expect(ClientStatus(.failed("x"), connecting: true) == .failed("x"))
    }
}

@Suite("AgentChannel: the exchange as a tool sees it")
struct AgentChannelTests {
    private func exchange(replaced: Bool = false, _ failure: any Error) async -> String {
        do {
            _ = try await AgentChannel.exchange(app: "Sample", server: "sample", reconnect: "reconnect it", replaced: { replaced }) {
                () async throws -> Answer in throw failure
            }
            return "no error"
        } catch let error as ToolError {
            return error.message
        } catch {
            return "passed through: \(error)"
        }
    }

    @Test("an app that is not running is reported as not open, by name")
    func notOpen() async {
        #expect(await exchange(LocalChannel.Failure.notRunning) == "Sample is not open. Ask the user to open Sample, then try again.")
    }

    @Test("no answer says so, and says to reconnect when the server was replaced")
    func noAnswer() async {
        #expect(await exchange(LocalChannel.Failure.noReply).contains("did not answer"))
        #expect(await exchange(replaced: true, LocalChannel.Failure.noReply) == "reconnect it")
    }

    @Test("any other failure passes through untouched")
    func other() async {
        #expect(await exchange(LocalChannel.Failure.io(61)).hasPrefix("passed through"))
    }

    @Test("a success passes through")
    func success() async throws {
        let answer = try await AgentChannel.exchange(app: "Sample", server: "sample", reconnect: "", replaced: { false }) {
            Answer(text: "ok")
        }
        #expect(answer == Answer(text: "ok"))
    }

    @Test("sending to an app that is not running fails with notRunning")
    func notRunning() async {
        let directory = makeShortDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        await #expect(throws: LocalChannel.Failure.notRunning) {
            let _: Answer = try await AgentChannel.send(Ask.echo("x"), dataDirectory: directory, timeout: .seconds(5))
        }
    }

    @Test("bytes decode to a request or to nothing, and a reply encodes")
    func coding() throws {
        #expect(AgentChannel.decode(Ask.self, from: try JSONEncoder().encode(Ask.echo("a"))) == .echo("a"))
        #expect(AgentChannel.decode(Ask.self, from: Data("{}".utf8)) == nil)
        #expect(try JSONDecoder().decode(Answer.self, from: AgentChannel.encode(Answer(text: "a"))) == Answer(text: "a"))
    }
}
