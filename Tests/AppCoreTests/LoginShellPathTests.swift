import Foundation
import Testing

@testable import AppCore

/// The user's terminal PATH for an app started from the Finder. The live test reproduces
/// the owner's MacBook (2026-11-11): a folder added in `~/.zshrc` is invisible to
/// `zsh -lc` and found by the login, interactive shell.
@Suite("Login shell PATH")
struct LoginShellPathTests {
    @Test("the shell's entries come first, then this process's missing ones, without repeats")
    func merge() {
        #expect(LoginShellPath.merge("/a:/usr/bin:/b", into: "/usr/bin:/bin:/a") == "/a:/usr/bin:/b:/bin")
        #expect(LoginShellPath.merge("", into: "/usr/bin") == "/usr/bin")
    }

    @Test("PATH is read between the markers, whatever a profile prints around them")
    func parse() {
        let output = """
            Welcome back! Updating plugins…
            \(LoginShellPath.startMarker)
            HOME=/Users/someone
            PATH=/Users/someone/.local/bin:/usr/bin
            \(LoginShellPath.endMarker)
            bye
            """
        #expect(LoginShellPath.parse(output) == "/Users/someone/.local/bin:/usr/bin")
        #expect(LoginShellPath.parse("PATH=/usr/bin") == nil, "no markers, no answer")
        #expect(LoginShellPath.parse("\(LoginShellPath.startMarker)\nPATH=\n\(LoginShellPath.endMarker)") == nil)
    }

    @Test("a folder added in .zshrc is found, where zsh -lc does not see it")
    func zshrcOnly() async throws {
        let home = FileManager.default.temporaryDirectory.appending(path: "login-shell-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        try #"export PATH="$HOME/tools-from-zshrc:$PATH""#.write(to: home.appending(path: ".zshrc"), atomically: true, encoding: .utf8)
        let environment = ["HOME": home.path, "ZDOTDIR": home.path, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]

        let plain = Process()
        plain.executableURL = URL(fileURLWithPath: "/bin/zsh")
        plain.arguments = ["-lc", "echo $PATH"]
        plain.environment = environment
        let pipe = Pipe()
        plain.standardOutput = pipe
        try plain.run()
        plain.waitUntilExit()
        let loginOnly = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        #expect(!loginOnly.contains("tools-from-zshrc"), "the bug: a login shell alone skips .zshrc")

        let path = try #require(await LoginShellPath.read(shell: "/bin/zsh", timeout: .seconds(10), environment: environment))
        #expect(path.split(separator: ":").first == "\(home.path)/tools-from-zshrc")
    }

    @Test("a shell that never answers gives up at the timeout")
    func hangingShell() async throws {
        let script = FileManager.default.temporaryDirectory.appending(path: "hang-\(UUID().uuidString).sh")
        try "#!/bin/sh\nsleep 30\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        defer { try? FileManager.default.removeItem(at: script) }

        let started = ContinuousClock.now
        #expect(await LoginShellPath.read(shell: script.path, timeout: .milliseconds(300)) == nil)
        #expect(ContinuousClock.now - started < .seconds(5))
    }
}
