import SwiftUI

struct TerminalAIMCPSettingsView: View {
    @ObservedObject var manager: TerminalAIMCPManager
    var attachResource: ((UUID, String, String) -> Void)?
    @Environment(\.dismiss) private var dismiss
    @State private var editing: TerminalAIMCPServer?
    @State private var selected: UUID?
    @State private var testing = Set<UUID>()
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("MCP tools").font(.title2.bold())
                Spacer()
                Button("Refresh") { refresh() }
                Button { editing = TerminalAIMCPServer() } label: { Label("Add server", systemImage: "plus") }
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Text("Connect services you choose. Agent tool calls and resource reads ask for approval separately from automatic terminal queries.")
                .foregroundStyle(.secondary)
            if let message = error ?? manager.error { Text(message).foregroundStyle(.red).textSelection(.enabled) }
            HSplitView {
                List(selection: $selected) {
                    ForEach(manager.servers) { server in
                        VStack(alignment: .leading, spacing: 5) {
                            HStack {
                                Image(systemName: server.transport == .stdio ? "terminal" : "network")
                                Text(server.name).fontWeight(.medium)
                                if !server.enabled { Text("Disabled").foregroundStyle(.secondary) }
                            }
                            Text(manager.statuses[server.id] ?? server.transport.rawValue)
                                .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            HStack {
                                Button(testing.contains(server.id) ? "Connecting…" : "Test connection") { test(server.id) }
                                    .disabled(testing.contains(server.id) || !server.enabled)
                                Button("Edit") { editing = server }
                                Button("Remove", role: .destructive) {
                                    do { try manager.remove(server.id) } catch { self.error = error.localizedDescription }
                                }
                            }.buttonStyle(.borderless).font(.caption)
                        }.padding(.vertical, 5).tag(server.id)
                    }
                }.frame(minWidth: 260)
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        if let selected, let discovery = manager.discoveries[selected] {
                            Text("Tools · \(discovery.tools.count)").font(.headline)
                            ForEach(Array(discovery.tools.enumerated()), id: \.offset) { _, tool in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(tool["name"] as? String ?? "Tool").fontWeight(.medium)
                                    if let description = tool["description"] as? String {
                                        Text(description).font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                            Divider()
                            Text("Resources · \(discovery.resources.count)").font(.headline)
                            ForEach(Array(discovery.resources.enumerated()), id: \.offset) { _, resource in
                                if let uri = resource["uri"] as? String {
                                    VStack(alignment: .leading, spacing: 4) {
                                        let title = resource["name"] as? String ?? uri
                                        Text(title).fontWeight(.medium)
                                        Text(uri).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                                        if let attachResource {
                                            Button("Attach to conversation") { attachResource(selected, uri, title) }
                                        }
                                    }
                                }
                            }
                        } else {
                            Text(manager.servers.isEmpty ? "Add a stdio or Streamable HTTP server to get started." : "Select a server and test its connection to inspect tools and resources.")
                                .foregroundStyle(.secondary)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding()
                }.frame(minWidth: 300)
            }
        }.padding(18).frame(width: 760, height: 540)
            .onAppear { refresh() }
            .sheet(item: $editing) { server in
                TerminalAIMCPServerEditor(manager: manager, server: server)
            }
    }

    private func test(_ id: UUID) {
        testing.insert(id)
        selected = id
        error = nil
        Task { @MainActor in
            defer { testing.remove(id) }
            do { _ = try await manager.test(id) } catch { self.error = error.localizedDescription }
        }
    }

    private func refresh() {
        do { try manager.refresh(); error = nil } catch { self.error = error.localizedDescription }
    }
}

private struct TerminalAIMCPServerEditor: View {
    @ObservedObject var manager: TerminalAIMCPManager
    @State var server: TerminalAIMCPServer
    @Environment(\.dismiss) private var dismiss
    @State private var arguments = ""
    @State private var environment = ""
    @State private var token = ""
    @State private var clearToken = false
    @State private var clearEnvironment = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("MCP server").font(.title2.bold())
            Form {
                TextField("Name", text: $server.name)
                Toggle("Enabled", isOn: $server.enabled)
                Picker("Transport", selection: $server.transport) {
                    Text("Local process (stdio)").tag(TerminalAIMCPServer.Transport.stdio)
                    Text("Streamable HTTP").tag(TerminalAIMCPServer.Transport.http)
                }
                if server.transport == .stdio {
                    TextField("Executable · absolute path", text: $server.executable)
                    TextField("Working directory · optional", text: $server.workingDirectory)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Arguments · one per line").font(.caption)
                        TextEditor(text: $arguments).font(.system(.body, design: .monospaced)).frame(height: 65)
                        Text("Arguments are passed directly; shell quotes and variable expansion are not applied.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Environment · NAME=value, one per line").font(.caption)
                        TextEditor(text: $environment).font(.system(.body, design: .monospaced)).frame(height: 65)
                        if !server.environmentKeys.isEmpty {
                            Text("Saved keys: \(server.environmentKeys.joined(separator: ", ")). Leave blank to keep saved values.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Toggle("Clear saved environment", isOn: $clearEnvironment)
                    }
                } else {
                    TextField("MCP endpoint", text: $server.endpoint)
                    SecureField("Bearer token · optional; blank keeps saved token", text: $token)
                    Toggle("Clear saved token", isOn: $clearToken)
                    Text("Tokens and environment values are saved in Keychain. OAuth sign-in is not supported here; use a service token.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            Spacer(minLength: 0)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") { save() }.keyboardShortcut(.defaultAction)
            }
        }.padding(20).frame(width: 620, height: server.transport == .stdio ? 540 : 350)
            .onAppear { arguments = server.arguments.joined(separator: "\n") }
    }

    private func save() {
        do {
            server.arguments = arguments.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            if arguments.isEmpty { server.arguments = [] }
            var values: [String: String]?
            if clearEnvironment { values = [:] } else if !environment.isEmpty {
                var parsed: [String: String] = [:]
                for line in environment.split(separator: "\n") {
                    guard let boundary = line.firstIndex(of: "="), boundary != line.startIndex else {
                        throw TerminalAIMCPError.invalid("Each environment line must be NAME=value.")
                    }
                    let key = String(line[..<boundary])
                    guard parsed[key] == nil else { throw TerminalAIMCPError.invalid("Environment names must be unique.") }
                    parsed[key] = String(line[line.index(after: boundary)...])
                }
                values = parsed
            }
            try manager.save(server, bearerToken: clearToken ? "" : token.isEmpty ? nil : token, environment: values)
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}
