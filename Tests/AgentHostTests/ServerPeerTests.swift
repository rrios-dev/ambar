import AgentHost
import Darwin
import Foundation
import MCPKit
import Synchronization
import Testing

// Who answers on the app's socket. Any process of the same user can unlink `agent.sock` and
// bind its own: without a check, the MCP executable would hand it the request (a type_text
// payload included) and pass its forged reply to the agent as the app's. So the client
// checks the listening peer before it writes a byte: the same user always, and, when the
// MCP executable is signed by a team, code signed by that same team (the peer's audit
// token, as MCPKit's `Listener` checks its clients).
//
// An ad hoc debug build has no team, so it can only check the user: these tests pin that
// limit too.

private struct Message: Codable, Equatable, Sendable {
    var text: String
}

/// A short directory for a socket (`sun_path` holds 104 bytes).
private func makeSocketDirectory() -> URL {
    let name = "sp-" + UUID().uuidString.prefix(8).lowercased()
    let url = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true).appendingPathComponent(name, isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// The bytes a scratch listener received, shared with its thread.
private final class Received: Sendable {
    let bytes = Mutex<Data>(Data())
}

/// A listener that is not the app: a bare socket of this same user, signed by no team,
/// bound where the app's socket goes. It records every byte it receives on its first
/// connection and answers with a forged reply.
private final class ScratchListener: @unchecked Sendable {
    let path: String
    private let descriptor: Int32
    private let received = Received()
    private let done = DispatchSemaphore(value: 0)

    init(path: String, reply: Data) throws {
        self.path = path
        unlink(path)
        descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            for (index, byte) in bytes.enumerated() { buffer[index] = byte }
            buffer[bytes.count] = 0
        }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, listen(descriptor, 4) == 0 else {
            close(descriptor)
            throw LocalChannel.Failure.io(errno)
        }
        let listening = descriptor
        let received = self.received
        let done = self.done
        let thread = Thread {
            defer { done.signal() }
            let client = accept(listening, nil, nil)
            guard client >= 0 else { return }
            defer { close(client) }
            var on: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            var tv = timeval(tv_sec: 2, tv_usec: 0)
            setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
            var buffer = [UInt8](repeating: 0, count: 4096)
            while true {
                let count = read(client, &buffer, buffer.count)
                guard count > 0 else { break }
                received.bytes.withLock { $0.append(contentsOf: buffer[0..<count]) }
                if buffer[0..<count].contains(0x0A) { break }
            }
            // A client that hung up without a request gets no answer.
            guard received.bytes.withLock({ !$0.isEmpty }) else { return }
            let answer = reply + Data([0x0A])
            _ = answer.withUnsafeBytes { write(client, $0.baseAddress, answer.count) }
        }
        thread.start()
    }

    /// What the first connection sent, once it is over (or after two seconds).
    func bytes() async -> Data {
        let done = self.done
        await Task.detached { Self.waitBriefly(done) }.value
        return received.bytes.withLock { $0 }
    }

    private static func waitBriefly(_ semaphore: DispatchSemaphore) {
        _ = semaphore.wait(timeout: .now() + 2)
    }

    func stop() {
        close(descriptor)
        unlink(path)
    }
}

@Suite("AgentChannel: who answers on the socket", .serialized)
struct ServerPeerTests {
    private let forged = try! JSONEncoder().encode(Message(text: "forged"))

    @Test("a client with a team sends nothing to a listener of its user that is not signed by that team")
    func unsignedListenerGetsNothing() async throws {
        let directory = makeSocketDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let listener = try ScratchListener(path: AgentChannel.socketPath(dataDirectory: directory), reply: forged)
        defer { listener.stop() }
        let trust = AgentChannel.ServerTrust(uid: getuid(), team: "TESTTEAM00")

        await #expect(throws: AgentChannel.Failure.untrustedServer) {
            let _: Message = try await AgentChannel.send(
                Message(text: "secret to type"), dataDirectory: directory, timeout: .seconds(5), trust: trust)
        }
        #expect(await listener.bytes().isEmpty)
    }

    @Test("a listener of another user is refused before a byte is written, team or not")
    func otherUserGetsNothing() async throws {
        let directory = makeSocketDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let listener = try ScratchListener(path: AgentChannel.socketPath(dataDirectory: directory), reply: forged)
        defer { listener.stop() }
        let trust = AgentChannel.ServerTrust(uid: getuid() &+ 1, team: nil)

        await #expect(throws: AgentChannel.Failure.untrustedServer) {
            let _: Message = try await AgentChannel.send(
                Message(text: "secret to type"), dataDirectory: directory, timeout: .seconds(5), trust: trust)
        }
        #expect(await listener.bytes().isEmpty)
    }

    @Test("an ad hoc build has no team to compare: it can only check the user, so a listener of the same user is answered")
    func adHocChecksTheUserOnly() async throws {
        let directory = makeSocketDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let listener = try ScratchListener(path: AgentChannel.socketPath(dataDirectory: directory), reply: forged)
        defer { listener.stop() }
        let trust = AgentChannel.ServerTrust(uid: getuid(), team: nil)

        let answer: Message = try await AgentChannel.send(
            Message(text: "hello"), dataDirectory: directory, timeout: .seconds(5), trust: trust)
        #expect(answer == Message(text: "forged"))
        #expect(await listener.bytes().isEmpty == false)
    }

    @Test("a kept connection is opened only to a listener that passes, and nothing is written by opening it")
    func openChecksBeforeHandingTheDescriptor() async throws {
        let directory = makeSocketDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = AgentChannel.socketPath(dataDirectory: directory)

        #expect(throws: LocalChannel.Failure.notRunning) { _ = try AgentChannel.open(path, trust: .sameUserAndTeam) }

        let impostor = try ScratchListener(path: path, reply: forged)
        #expect(throws: AgentChannel.Failure.untrustedServer) {
            _ = try AgentChannel.open(path, trust: AgentChannel.ServerTrust(uid: getuid(), team: "TESTTEAM00"))
        }
        #expect(await impostor.bytes().isEmpty)
        impostor.stop()

        let listener = try ScratchListener(path: path, reply: forged)
        defer { listener.stop() }
        let descriptor = try AgentChannel.open(path, trust: AgentChannel.ServerTrust(uid: getuid(), team: nil))
        #expect(descriptor >= 0)
        close(descriptor)
        #expect(await listener.bytes().isEmpty)
    }

    @Test("by default the client expects its own user and its own team")
    func defaultTrust() {
        #expect(AgentChannel.ServerTrust.sameUserAndTeam == AgentChannel.ServerTrust(uid: getuid(), team: LocalChannel.ownTeam))
    }

    @Test("an untrusted server becomes a tool error that forwards nothing: the app is not answering safely")
    func untrustedIsAToolError() async {
        do {
            _ = try await AgentChannel.exchange(app: "Sample", server: "sample", reconnect: "reconnect it", replaced: { false }) {
                () async throws -> Message in throw AgentChannel.Failure.untrustedServer
            }
            Issue.record("expected a ToolError")
        } catch let error as ToolError {
            #expect(error.message.hasPrefix("Sample is not answering safely"))
            #expect(error.message.contains("nothing was sent"))
        } catch {
            Issue.record("expected a ToolError, got \(error)")
        }
    }
}

@Suite("AgentHost: the data directory", .serialized)
@MainActor
struct DataDirectoryTests {
    private func permissions(_ url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }

    private func host(_ directory: URL) -> AgentHost<Message, Message> {
        AgentHost(
            directory: directory,
            configuration: .init(
                serverName: "sample", serverExecutable: "sample-mcp",
                refusal: Message(text: "off"), quitting: Message(text: "quitting"), notUnderstood: Message(text: "?"),
                bundleURL: URL(fileURLWithPath: "/Applications/Sample.app")),
            register: { _, _ in .done },
            handler: { $0 })
    }

    @Test("turning access on creates the data directory readable by this user only")
    func createdPrivate() throws {
        let parent = makeSocketDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let directory = parent.appendingPathComponent("data", isDirectory: true)
        let host = host(directory)
        host.setEnabled(true)
        defer { host.stop() }
        #expect(host.isListening)
        #expect(try permissions(directory) == 0o700)
    }

    @Test("a data directory left open to others, by an earlier version or the MCP executable's log, is closed to 0700")
    func tightened() throws {
        let directory = makeSocketDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
        let host = host(directory)
        host.setEnabled(true)
        defer { host.stop() }
        #expect(try permissions(directory) == 0o700)
    }
}
