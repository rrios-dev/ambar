import Darwin
import Foundation
import MCPKit
import Security

// The client end of an app's socket, checking who listens before it writes a byte.
//
// Any process of the same user can unlink the app's `agent.sock` and bind its own. MCPKit's
// `Listener` checks the processes that connect to it, but its `LocalChannel.send` does not
// check the process it connects to, so an MCP executable would hand that stranger its
// request (a `type_text` payload included) and pass its forged reply to the agent as the
// app's. This file is that check on the client side, on the very descriptor that carries
// the request, so there is no window between checking and writing.
//
// It repeats MCPKit's socket plumbing because MCPKit keeps it internal; moving the check
// into `LocalChannel.send` is the follow-up (a new MCPKit tag, the owner's go).

extension AgentChannel {
    /// Why a checked exchange did not happen; the rest are `LocalChannel.Failure`.
    public enum Failure: Error, Equatable, CustomStringConvertible {
        /// Something listens on the app's socket, but it is not the app: another user, or,
        /// when this executable is signed by a team, code not signed by that team. Nothing
        /// was written to it and nothing was read from it.
        case untrustedServer

        public var description: String {
            switch self {
            case .untrustedServer: "the process on the app's socket is not the app"
            }
        }
    }

    /// Who the client accepts on the other end of the socket.
    ///
    /// A signed build compares the peer's code signature with its own team, as MCPKit's
    /// `Listener` does with its clients. An ad hoc debug build has no team, so it can only
    /// check the user: any process of the same user passes.
    public struct ServerTrust: Equatable, Sendable {
        /// The user the listening process must run as.
        public var uid: uid_t
        /// The team that must have signed the listening process; nil checks the user only.
        public var team: String?

        public init(uid: uid_t, team: String?) {
            self.uid = uid
            self.team = team
        }

        /// This process's user and team: the app and its MCP executable are signed together.
        public static var sameUserAndTeam: ServerTrust {
            ServerTrust(uid: getuid(), team: LocalChannel.ownTeam)
        }

        /// Whether the process listening at the other end of `descriptor` is admitted.
        func admits(_ descriptor: Int32) -> Bool {
            var peerUID: uid_t = 0
            var peerGID: gid_t = 0
            guard getpeereid(descriptor, &peerUID, &peerGID) == 0, peerUID == uid else { return false }
            guard let team else { return true }
            // The audit token, not the pid: a pid can be reused, an audit token cannot.
            var token = audit_token_t()
            var length = socklen_t(MemoryLayout<audit_token_t>.size)
            guard getsockopt(descriptor, SOL_LOCAL, LOCAL_PEERTOKEN, &token, &length) == 0 else { return false }
            let auditToken = withUnsafeBytes(of: &token) { Data($0) }
            var guest: SecCode?
            let attributes = [kSecGuestAttributeAudit: auditToken] as CFDictionary
            guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &guest) == errSecSuccess, let guest else { return false }
            var requirement: SecRequirement?
            let text = "anchor apple generic and certificate leaf[subject.OU] = \"\(team)\"" as CFString
            guard SecRequirementCreateWithString(text, [], &requirement) == errSecSuccess, let requirement else { return false }
            return SecCodeCheckValidity(guest, [], requirement) == errSecSuccess
        }
    }

    /// Sends `request` to the socket at `path` and waits up to `timeout` for the reply, once
    /// the listening process passes `trust`.
    ///
    /// - Throws: `Failure.untrustedServer` before writing anything when it does not pass;
    ///   `LocalChannel.Failure` as `LocalChannel.send` does otherwise.
    public static func send(
        _ request: Data,
        to path: String,
        timeout: Duration,
        trust: ServerTrust = .sameUserAndTeam
    ) async throws -> Data {
        try await Task.detached {
            guard request.count < LocalChannel.maxLine else { throw LocalChannel.Failure.tooLong }
            let descriptor = try AgentChannel.open(path, trust: trust)
            defer { close(descriptor) }
            var tv = timeval(tv_sec: max(1, Int(timeout.components.seconds)), tv_usec: 0)
            setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
            guard Socket.writeAll(descriptor, request + Data([0x0A])) else { throw LocalChannel.Failure.io(errno) }
            guard let reply = Socket.readLine(descriptor) else { throw LocalChannel.Failure.noReply }
            return reply
        }.value
    }

    /// Connects to the socket at `path` and returns the descriptor once the listening process
    /// passes `trust`, for a client that keeps the connection open for many lines (an app
    /// talking to another app's local API). Nothing has been written to it; SIGPIPE is off.
    /// The caller owns the descriptor and closes it. Blocking: call it off the main thread.
    ///
    /// - Throws: `Failure.untrustedServer` when the process does not pass (the descriptor is
    ///   closed first); `LocalChannel.Failure.notRunning` when nothing listens there;
    ///   `LocalChannel.Failure.tooLong` or `.io` when the path or the socket fails.
    public static func open(_ path: String, trust: ServerTrust) throws -> Int32 {
        let descriptor = try Socket.connect(path)
        guard trust.admits(descriptor) else {
            close(descriptor)
            throw Failure.untrustedServer
        }
        return descriptor
    }

    /// What a tool says when the process on the app's socket is not the app.
    public static func notSafe(app: String) -> String {
        "\(app) is not answering safely: the process on its socket is not \(app) itself, so nothing was sent. "
            + "Ask the user to quit and reopen \(app), then try again."
    }
}

/// MCPKit's client plumbing, which it keeps internal: newline-delimited messages over a Unix
/// domain socket, no SIGPIPE.
private enum Socket {
    static func connect(_ path: String) throws -> Int32 {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { throw LocalChannel.Failure.tooLong }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            for (index, byte) in bytes.enumerated() { buffer[index] = byte }
            buffer[bytes.count] = 0
        }
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw LocalChannel.Failure.io(errno) }
        var on: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else {
            close(descriptor)
            throw LocalChannel.Failure.notRunning
        }
        return descriptor
    }

    static func readLine(_ descriptor: Int32) -> Data? {
        var received = Data()
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            if let newline = received.firstIndex(of: 0x0A) { return Data(received[..<newline]) }
            guard received.count < LocalChannel.maxLine else { return nil }
            let count = read(descriptor, &buffer, buffer.count)
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { return received.isEmpty ? nil : received }
            received.append(contentsOf: buffer[0..<count])
        }
    }

    static func writeAll(_ descriptor: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let written = write(descriptor, buffer.baseAddress! + offset, buffer.count - offset)
                if written < 0, errno == EINTR { continue }
                guard written > 0 else { return false }
                offset += written
            }
            return true
        }
    }
}
