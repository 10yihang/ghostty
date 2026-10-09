import AppKit
import SwiftUI

extension Notification.Name {
    static let ghosttyToggleAI = Notification.Name("com.mitchellh.ghostty.toggle-ai")
    static let ghosttyAICommandEntry = Notification.Name("com.mitchellh.ghostty.ai-command-entry")
    static let ghosttyAskAI = Notification.Name("com.mitchellh.ghostty.ask-ai")
    static let ghosttyCommandFinished = Notification.Name("com.mitchellh.ghostty.command-finished")
    static let ghosttyTerminalUserInput = Notification.Name("com.mitchellh.ghostty.terminal-user-input")
}

enum TerminalAIPlacement: String, CaseIterable {
    case bottom, right, floating

    var title: String {
        switch self {
        case .bottom: return "Bottom"
        case .right: return "Right"
        case .floating: return "Floating"
        }
    }

    var symbol: String {
        switch self {
        case .bottom: return "rectangle.bottomthird.inset.filled"
        case .right: return "sidebar.right"
        case .floating: return "rectangle.on.rectangle"
        }
    }
}

/// Native terminal chrome surrounds a locally bundled assistant-ui conversation.
struct TerminalAIView: View {
    @ObservedObject var model: TerminalAIModel
    var terminalTitle: String = "Terminal"
    var contextTitle: String = "Selected text"
    @Binding var placement: TerminalAIPlacement
    var hasFailedCommand = false
    var onInvestigateFailure: () -> Void = {}
    var onMove: (CGSize) -> Void = { _ in }
    var onEndMove: () -> Void = {}
    var onClose: () -> Void

    @State private var settingsPresented = false
    @State private var historyPresented = false
    @State private var chatError: String?
    @State private var webViewID = UUID()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Divider()
            header
            Divider()
            if let chatError {
                VStack(alignment: .leading, spacing: 10) {
                    Label("Could not load the AI conversation", systemImage: "exclamationmark.triangle")
                    Text(chatError).font(.callout).textSelection(.enabled)
                    HStack {
                        Button("Reload conversation") {
                            self.chatError = nil
                            webViewID = UUID()
                        }
                        if model.isRunning { Button("Stop task", action: model.stop) }
                    }
                }
                .padding(14)
            }
            TerminalAIWebView(
                model: model,
                contextTitle: contextTitle,
                loadingError: $chatError,
                onSettings: { settingsPresented = true },
                onHide: onClose)
                .id(model.conversationID.uuidString + webViewID.uuidString)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        // Keep the floating resize grip outside the web composer's controls.
        .padding(.bottom, placement == .floating ? 22 : 0)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .onExitCommand(perform: onClose)
        .onChange(of: model.conversationID) { _ in chatError = nil }
        .popover(isPresented: $settingsPresented, arrowEdge: .top) {
            TerminalAISettingsView(model: model)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("AI conversation")
    }

    private var header: some View {
        HStack(spacing: 10) {
            Label("AI", systemImage: "sparkles")
                .font(.headline)
                .help("Conversation attached to \(terminalTitle)")
            Text("\(terminalTitle) · \(model.terminalDirectory)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help("Commands and diagnostics run in this attached terminal. Pi provides the agent connection on this Mac.")
            if !model.activeModelLabel.isEmpty {
                Text(model.activeModelLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(model.activeModelLabel)
            }
            Spacer(minLength: 0)
            Button { model.commandEntryPresented = true } label: {
                Image(systemName: "terminal")
            }
            .disabled(model.isRunning)
            .help("Write a command with AI")
            .accessibilityLabel("Write a command with AI")
            if hasFailedCommand && !model.isRunning {
                Button("Ask about last exit", action: onInvestigateFailure)
                    .help("Attach the visible screen captured at the last nonzero exit")
            }
            Button { historyPresented = true } label: {
                Image(systemName: "clock.arrow.circlepath")
            }
            .help("Conversation history")
            .accessibilityLabel("Conversation history")
            .popover(isPresented: $historyPresented, arrowEdge: .top) {
                TerminalAIHistoryView(model: model) {
                    historyPresented = false
                }
            }
            Button { model.reset() } label: {
                Image(systemName: "plus")
            }
            .disabled(model.isRunning)
            .help("New conversation")
            .accessibilityLabel("New conversation")
            Button { settingsPresented = true } label: {
                Image(systemName: "gearshape")
            }
            .help("AI settings")
            .accessibilityLabel("AI settings")
            Menu {
                ForEach(TerminalAIPlacement.allCases, id: \.self) { option in
                    Button {
                        placement = option
                    } label: {
                        Label(option.title, systemImage: placement == option ? "checkmark" : option.symbol)
                    }
                }
            } label: {
                Image(systemName: placement.symbol)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Panel position: \(placement.title). Drag the panel edge to resize.")
            .accessibilityLabel("AI panel position")
            Button(action: onClose) { Image(systemName: "xmark") }
                .help("Hide the AI panel; the task keeps running")
                .accessibilityLabel("Hide AI panel")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 5)
                .onChanged { onMove($0.translation) }
                .onEnded { _ in onEndMove() },
            including: placement == .floating ? .all : .subviews)
    }
}

struct TerminalAIHistoryView: View {
    @ObservedObject var model: TerminalAIModel
    var onOpen: () -> Void
    @State private var search = ""

    private var filteredHistory: [TerminalAIHistoryStore.Entry] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return model.history }
        return model.history.filter { entry in
            [entry.title, entry.sourceDirectory, entry.model].contains {
                $0.localizedCaseInsensitiveContains(query)
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Conversation history").font(.headline)
                Spacer()
                Button(action: model.refreshHistory) {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Refresh history")
                .accessibilityLabel("Refresh history")
            }
            .padding(.bottom, 12)

            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search conversations", text: $search)
                    .textFieldStyle(.plain)
                if !search.isEmpty {
                    Button { search = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear search")
                }
            }
            .padding(8)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            .padding(.bottom, 10)

            if model.isRunning {
                Label("Stop the current task to switch conversations.", systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 10)
            }
            if let historyError = model.historyError {
                Text(historyError)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .padding(.bottom, 10)
            }

            Divider()
            if filteredHistory.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "text.bubble")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                    Text(search.isEmpty ? "No saved conversations yet" : "No matching conversations")
                        .font(.callout)
                    Text(search.isEmpty ? "Start a conversation to find it here later." : "Try a title, directory or model name.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(filteredHistory, id: \.id) { entry in
                            historyRow(entry)
                        }
                    }
                    .padding(.vertical, 8)
                }
            }
        }
        .padding(14)
        .frame(width: 400, height: 440)
        .onAppear(perform: model.refreshHistory)
    }

    private func historyRow(_ entry: TerminalAIHistoryStore.Entry) -> some View {
        let isCurrent = entry.id == model.conversationID
        return Button {
            if model.openConversation(entry.id) { onOpen() }
        } label: {
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: isCurrent ? "checkmark.circle.fill" : "text.bubble")
                    .foregroundStyle(isCurrent ? Color.accentColor : Color.secondary)
                    .frame(width: 16)
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 4) {
                    Text(entry.title)
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(entry.sourceDirectory)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    HStack(spacing: 8) {
                        if !entry.model.isEmpty {
                            Text(entry.model)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Spacer(minLength: 0)
                        Text(entry.updatedAt, format: .dateTime.month(.abbreviated).day().hour().minute())
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
            }
            .padding(9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background(isCurrent ? Color.accentColor.opacity(0.12) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .disabled(model.isRunning)
        .help("Open conversation from \(entry.sourceDirectory)")
        .accessibilityLabel(isCurrent ? "Current conversation: \(entry.title)" : entry.title)
    }
}

private struct TerminalAISettingsView: View {
    @ObservedObject var model: TerminalAIModel
    @Environment(\.dismiss) private var dismiss
    @State private var folderError: String?
    @State private var pluginsPresented = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("AI Settings").font(.headline)
            Button("Pi plugins…") { pluginsPresented = true }
            DisclosureGroup("Pi MCP") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Uses the MCP servers enabled in your existing Pi configuration. Pi manages their connections and tools on This Mac.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Text(URL(fileURLWithPath: model.pluginsDirectory).appendingPathComponent("mcp.json").path)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                    Text("Manage servers with Pi:").font(.caption).foregroundStyle(.secondary)
                    Text("pi mcp add --help\npi mcp list")
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                    Text("For a custom Pi folder, set PI_CODING_AGENT_DIR to the parent folder of mcp.json. Previous Ghostty MCP servers are not migrated automatically; add them in Pi.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if !model.useExistingPiConfiguration {
                        Text("Enable Use existing Pi configuration to use your saved MCP servers.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Button("Show connection status") {
                        model.showPiMCPStatus()
                        dismiss()
                    }
                    .disabled(model.isRunning || model.commandEntryBusy || model.contextLoading || !model.useExistingPiConfiguration)
                }
            }
            Button("Connect current shell…", action: model.showSSHSetup)
                .disabled(model.isRunning && model.terminalIdentity["canSetupShell"] as? Bool != true)
            Form {
                TextField("Pi executable", text: $model.executablePath)
                    .help("Absolute path to the installed pi executable")
                TextField("Node executable", text: $model.nodePath)
                    .help("Absolute path to Node.js 22.19 or newer")
                Toggle("Use existing Pi configuration", isOn: $model.useExistingPiConfiguration)
                if model.useExistingPiConfiguration {
                    TextField("Pi configuration folder", text: $model.piConfigurationDirectory)
                } else {
                    TextField("Provider", text: $model.provider)
                        .help("A Pi provider identifier, such as openai or anthropic")
                    TextField("Model", text: $model.model)
                    TextField("Base URL (optional)", text: $model.baseURL)
                        .help("OpenAI-compatible API endpoint. Leave blank for a built-in Pi provider.")
                    SecureField("API key", text: $model.apiKey)
                }
                TextField("Pi working directory", text: $model.workingDirectory)
                    .help("Local directory for the Pi connection process. Commands use the attached terminal’s own directory.")
            }
            .textFieldStyle(.roundedBorder)
            .disabled(model.isRunning || model.commandEntryBusy)

            Text(model.useExistingPiConfiguration ?
                 "Uses the models, gateways and sign-in saved in Pi. No API key needs to be entered here. Ghostty manages this task's tools and keeps its conversation separate from your terminal Pi sessions." :
                 "Choose a provider and model. Add a base URL for an OpenAI-compatible service. The API key is stored in this Mac's Keychain.")
                .font(.callout)
                .foregroundStyle(.secondary)
            DisclosureGroup("Agent files") {
                VStack(alignment: .leading, spacing: 8) {
                    Text(model.useExistingPiConfiguration ? model.piConfigurationDirectory : model.configurationDirectory.path)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                    Button("Open Agent Folder") {
                        do {
                            let directory = model.useExistingPiConfiguration ?
                                URL(fileURLWithPath: (model.piConfigurationDirectory as NSString).expandingTildeInPath) : model.configurationDirectory
                            if !model.useExistingPiConfiguration {
                                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                            }
                            if !NSWorkspace.shared.open(directory) {
                                folderError = "Unable to open the agent folder. Copy the path above to open it in Finder."
                            }
                        } catch {
                            folderError = error.localizedDescription
                        }
                    }
                    if let folderError {
                        Text(folderError).font(.callout).foregroundStyle(.red)
                    }
                }
            }
            Text("Commands and diagnostics use the attached shell and require shell integration with an empty prompt. Auto-approve queries allows verified read-only system queries in a direct local, non-root shell. Writes, scripts, complex commands, SSH and root always require individual review.")
                .font(.callout)
                .foregroundStyle(.secondary)
            if model.isRunning {
                Text("Stop the current task to change these settings.")
                    .font(.caption)
            }
        }
        .padding(18)
        .frame(width: 440)
        .sheet(isPresented: $pluginsPresented) {
            TerminalAIPluginsView(model: model)
        }
        .onDisappear { model.saveCredentials() }
    }
}
