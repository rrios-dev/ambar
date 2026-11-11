import Foundation

/// The PATH the user's terminal has, for an app started from the Finder.
///
/// An app launched by launchd gets a bare PATH (`/usr/bin:/bin:/usr/sbin:/sbin`), and a
/// plain login shell (`zsh -lc`) still skips `~/.zshrc`, which is where installers such as
/// Claude Code's, nvm or pnpm add their folders. So a tool the user runs every day reads as
/// "not installed" (seen on the owner's MacBook, 2026-11-11). This asks the user's own shell,
/// as a login *and* interactive one, for its environment once, and adds what is missing to
/// this process's PATH, so every child process — `zsh -lc` included — finds the same tools.
public enum LoginShellPath {
    static let startMarker = "__appcore_env_start__"
    static let endMarker = "__appcore_env_end__"

    /// Reads the shell's PATH and merges it into this process's. Safe to call more than once;
    /// a shell that fails, hangs past `timeout` or prints nothing leaves PATH as it was.
    @discardableResult
    public static func importIntoProcess(timeout: Duration = .seconds(5)) async -> Bool {
        guard let shellPath = await read(shell: userShell(), timeout: timeout) else { return false }
        let current = ProcessInfo.processInfo.environment["PATH"] ?? ""
        setenv("PATH", merge(shellPath, into: current), 1)
        return true
    }

    /// The shell's PATH entries first (the user's order), then this process's that it lacks.
    static func merge(_ shellPath: String, into current: String) -> String {
        var seen = Set<String>()
        return (shellPath.split(separator: ":") + current.split(separator: ":"))
            .map(String.init)
            .filter { !$0.isEmpty && seen.insert($0).inserted }
            .joined(separator: ":")
    }

    /// The PATH line between the markers of `env`'s output; anything a profile prints around
    /// it (banners, prompts, update notices) is ignored.
    static func parse(_ output: String) -> String? {
        guard let start = output.range(of: startMarker), let end = output.range(of: endMarker, range: start.upperBound..<output.endIndex)
        else { return nil }
        return output[start.upperBound..<end.lowerBound]
            .split(separator: "\n")
            .first { $0.hasPrefix("PATH=") }
            .map { String($0.dropFirst("PATH=".count)) }
            .flatMap { $0.isEmpty ? nil : $0 }
    }

    /// The user's login shell from the account database, else `SHELL`, else zsh.
    static func userShell() -> String {
        if let entry = getpwuid(getuid()), let shell = entry.pointee.pw_shell {
            let path = String(cString: shell)
            if !path.isEmpty { return path }
        }
        return ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
    }

    /// `env` run by a login, interactive shell (zsh, bash and fish all take `-ilc`), with no
    /// terminal on standard input so nothing can wait for a key.
    static func read(shell: String, timeout: Duration, environment: [String: String]? = nil) async -> String? {
        let process = Process()
        if let environment { process.environment = environment }
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-ilc", "echo \(startMarker); /usr/bin/env; echo \(endMarker)"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        // Read in chunks and stop at the end marker: a profile that leaves a background job
        // holding the pipe open would make a read-to-end wait forever.
        let collected = OutputBuffer()
        let done = AsyncStream<Void> { finished in
            output.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                if chunk.isEmpty || collected.append(chunk, until: endMarker) { finished.yield(); finished.finish() }
            }
        }
        let watchdog = Task {
            try await Task.sleep(for: timeout)
            if process.isRunning { process.terminate() }
        }
        await withTaskGroup(of: Void.self) { group in
            group.addTask { for await _ in done { return } }
            group.addTask { try? await Task.sleep(for: timeout + .seconds(1)) }
            await group.next()
            group.cancelAll()
        }
        output.fileHandleForReading.readabilityHandler = nil
        watchdog.cancel()
        if process.isRunning { process.terminate() }
        return parse(collected.text)
    }
}

/// Bytes read so far from a shell, shared with the pipe's handler.
private final class OutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    /// Appends `chunk`; true once `marker` has arrived.
    func append(_ chunk: Data, until marker: String) -> Bool {
        lock.withLock {
            data.append(chunk)
            return String(decoding: data, as: UTF8.self).contains(marker)
        }
    }

    var text: String { lock.withLock { String(decoding: data, as: UTF8.self) } }
}
