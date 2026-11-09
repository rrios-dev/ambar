import AmbarAgent
import MCPKit
import SwiftUI

/// Settings › Agents: whether Claude Code, Codex and other agents may use Ámbar, connecting
/// them, and what they did (docs/initiatives/mac-apps-mcp/DESIGN.md §5–6).
struct AgentsSection: View {
    @Bindable var service: AgentService

    var body: some View {
        Section(t("agents.section")) {
            Toggle(t("agents.toggle"), isOn: Binding(get: { service.access.enabled }, set: { service.setEnabled($0) }))
            Text(t("agents.help"))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Text(t("agents.privacy"))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            ForEach(AgentClient.allCases) { client in
                LabeledContent(client.name) {
                    HStack {
                        if service.working == client { ProgressView().controlSize(.small) }
                        Button(t("agents.disconnect")) { Task { await service.disconnect(client) } }
                        Button(t("agents.connect")) { Task { await service.connect(client) } }
                            .buttonStyle(.borderedProminent)
                    }
                    .disabled(service.working != nil)
                }
                if let status = service.clientStatus[client] {
                    Text(status)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            Text(t("agents.connect.help"))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            ForEach(AgentClient.allCases) { client in
                Text(client.addCommand(server: AgentService.server, path: AgentService.serverPath))
                    .font(.system(size: 10, design: .monospaced))
                    .textSelection(.enabled)
            }

            if service.recent.isEmpty {
                Text(t("agents.log.empty"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } else {
                Text(t("agents.log"))
                    .font(.system(size: 11, weight: .semibold))
                ForEach(Array(service.recent.enumerated()), id: \.offset) { _, entry in
                    LabeledContent {
                        Text(entry.date, format: .dateTime.day().month().hour().minute())
                    } label: {
                        Text(verbatim: "\(entry.client ?? t("agents.client.unknown")) · \(entry.tool)")
                        if !entry.succeeded {
                            Text(t("agents.log.refused")).font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                    }
                }
                Button(t("agents.log.clear"), role: .destructive) { service.clearLog() }
            }
        }
        .onAppear { service.refreshLog() }
    }

    private func t(_ key: String.LocalizationValue) -> String {
        String(localized: key, bundle: .localized)
    }
}
