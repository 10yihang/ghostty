import SwiftUI

struct TerminalAIPluginsView: View {
    @ObservedObject var model: TerminalAIModel
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    @State private var presentedPlugin: TerminalAIPlugin?
    @State private var pluginAlertPresented = false

    private var selectionLocked: Bool { model.isRunning || model.commandEntryBusy }

    private var filteredPlugins: [TerminalAIPlugin] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return model.availablePlugins }
        return model.availablePlugins.filter { plugin in
            [plugin.name, plugin.summary, plugin.root.path].contains {
                $0.localizedCaseInsensitiveContains(query)
            }
        }
    }

    private var missingSelectionCount: Int {
        model.enabledPluginIDs.subtracting(Set(model.availablePlugins.map(\.id))).count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Pi Plugins").font(.title2.bold())
                Spacer()
                Button("Refresh") { refresh() }
                    .disabled(model.pluginsLoading)
                Button("Disable all", action: model.disableAllPlugins)
                    .disabled(selectionLocked || model.enabledPluginIDs.isEmpty)
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Text("Selected plugins run on This Mac with your user permissions. Enable only plugins you trust. Changes apply to the next task.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search plugins", text: $search)
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

            HStack {
                Text("\(model.enabledPluginIDs.count) enabled")
                Spacer()
                if model.pluginsLoading {
                    ProgressView().controlSize(.small)
                    Text("Scanning…")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            if selectionLocked {
                Label("Wait for the current task to finish to change plugins.", systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if missingSelectionCount > 0, !model.pluginsLoading, model.pluginScanError == nil {
                Text("\(missingSelectionCount) selected plugins are no longer installed. Disable all to clear them.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let error = model.pluginScanError {
                HStack(alignment: .top) {
                    Text("Could not scan plugins: \(error)")
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Button("Retry") { refresh() }.disabled(model.pluginsLoading)
                }
                .font(.callout)
            }

            if filteredPlugins.isEmpty {
                emptyState
            } else {
                List {
                    ForEach(filteredPlugins, id: \.id) { plugin in
                        pluginRow(plugin)
                    }
                }
                .listStyle(.inset)
            }

            DisclosureGroup("Plugin folder") {
                Text(model.pluginsDirectory)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(.caption)
        }
        .padding(18)
        .frame(width: 560, height: 620)
        .background(Color(nsColor: .windowBackgroundColor))
        .task { await model.refreshPlugins() }
        .alert(alertTitle, isPresented: $pluginAlertPresented, presenting: presentedPlugin) { plugin in
            if plugin.unavailableReason != nil {
                Button("Close", role: .cancel) {}
            } else {
                Button("Cancel", role: .cancel) {}.keyboardShortcut(.defaultAction)
                Button("Trust and enable") {
                    guard !selectionLocked else { return }
                    model.setPluginEnabled(plugin, enabled: true)
                }
                .disabled(selectionLocked)
            }
        } message: { plugin in
            if let reason = plugin.unavailableReason {
                Text(reason)
            } else {
                Text("\(plugin.name) can run code on This Mac with your user permissions, including while your terminal is connected over SSH. Enable it only if you trust this plugin. It will be used for the next task.")
            }
        }
    }

    private var alertTitle: String {
        guard let plugin = presentedPlugin else { return "Enable plugin?" }
        return plugin.unavailableReason == nil ? "Trust \(plugin.name)?" : "\(plugin.name) is unavailable"
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "shippingbox").font(.title2).foregroundStyle(.secondary)
            Text(emptyTitle).font(.callout)
            Text(emptyMessage)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyTitle: String {
        if model.pluginsLoading { return "Scanning Pi plugins…" }
        if model.pluginScanError != nil { return "Plugins could not be loaded" }
        return search.isEmpty ? "No Pi plugins found" : "No matching plugins"
    }

    private var emptyMessage: String {
        if model.pluginScanError != nil { return "Use Retry to scan your personal Pi packages again." }
        return search.isEmpty ?
            "Installed personal Pi packages appear here. Refresh after installing a package in Pi." :
            "Try a plugin name, description or folder."
    }

    private func pluginRow(_ plugin: TerminalAIPlugin) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(plugin.name).fontWeight(.medium).lineLimit(1)
                        if !plugin.version.isEmpty {
                            Text(plugin.version).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    if !plugin.summary.isEmpty {
                        Text(plugin.summary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Toggle("Enable \(plugin.name)", isOn: Binding(
                    get: { plugin.unavailableReason == nil && model.enabledPluginIDs.contains(plugin.id) },
                    set: { setEnabled($0, for: plugin) }))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .disabled(selectionLocked || hasNoResources(plugin))
                    .help(plugin.unavailableReason ?? "Changes apply to the next task")
            }
            if let reason = plugin.unavailableReason {
                Text(reason).font(.caption).foregroundStyle(.secondary)
            } else if let note = plugin.compatibilityNote {
                Text(note).font(.caption).foregroundStyle(.secondary)
            }
            DisclosureGroup("Resources · \(plugin.extensionPaths.count) extensions · \(plugin.skillPaths.count) skills · \(plugin.promptPaths.count) prompts") {
                VStack(alignment: .leading, spacing: 4) {
                    Text(plugin.root.path).textSelection(.enabled)
                    ForEach(plugin.discoveryWarnings, id: \.self) { warning in
                        Text(warning)
                    }
                }
                .foregroundStyle(.secondary)
            }
            .font(.caption)
        }
        .padding(.vertical, 5)
    }

    private func hasNoResources(_ plugin: TerminalAIPlugin) -> Bool {
        plugin.extensionPaths.isEmpty && plugin.skillPaths.isEmpty && plugin.promptPaths.isEmpty
    }

    private func setEnabled(_ enabled: Bool, for plugin: TerminalAIPlugin) {
        guard !selectionLocked, !hasNoResources(plugin) else { return }
        if !enabled {
            model.setPluginEnabled(plugin, enabled: false)
        } else {
            presentedPlugin = plugin
            pluginAlertPresented = true
        }
    }

    private func refresh() {
        Task { await model.refreshPlugins() }
    }
}
