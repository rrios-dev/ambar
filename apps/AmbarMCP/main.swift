import AmbarAgent
import Foundation
import MCPKit

// ambar-mcp: Ámbar's MCP server (docs/initiatives/mac-apps-mcp/DESIGN.md). It lives in
// Ambar.app/Contents/MacOS, next to the app, so it always reads the database format of the
// app beside it. An agent launches it over stdio:
//
//   claude mcp add --scope user ambar -- /Applications/Ambar.app/Contents/MacOS/ambar-mcp
//
// stdout carries only the protocol.

var dataDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    .appending(path: "Ambar", directoryHint: .isDirectory)
#if DEBUG
// The app's own debug hook, honoured only by debug builds as in the app.
if let override = ProcessInfo.processInfo.environment["AMBAR_DATA_DIR"], !override.isEmpty {
    dataDirectory = URL(fileURLWithPath: override, isDirectory: true)
}
#endif
let directory = dataDirectory

let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
let log = AccessLog(directory: directory)
let tools = AmbarTools(dataDirectory: directory, replaced: ExecutableIdentity.replacedSinceLaunch())

let server = Server(
    info: Server.Info(name: "ambar", title: "Ámbar", version: version, instructions: AmbarTools.instructions),
    tools: tools.all,
    gate: { AgentAccess.load(from: directory).enabled ? nil : AmbarTools.refusal },
    onCall: log.recorder()
)
await server.run()
