import Foundation
import Testing
@testable import Ghostty

@MainActor
struct TerminalAIPluginModelTests {
    @Test func selectedPluginsPersistAndOnlyTheirResourcesLoad() async throws {
        let fixture = try PluginModelFixture()
        defer { fixture.remove() }
        try fixture.package("chosen")
        try fixture.package("not-chosen")
        let model = fixture.makeModel()
        await model.refreshPlugins()
        #expect(model.enabledPluginIDs.isEmpty)
        let chosen = try #require(model.availablePlugins.first { $0.name == "chosen" })
        model.setPluginEnabled(chosen, enabled: true)
        let restored = fixture.makeModel()
        #expect(restored.enabledPluginIDs == [chosen.id])
        let config = try restored.prepareConnectionConfiguration()
        let extensions = config.arguments.indices.compactMap { index in
            config.arguments[index] == "--extension" ? config.arguments[index + 1] : nil
        }
        #expect(extensions.count == 5)
        #expect(extensions[0].hasSuffix("ghostty-tools.mjs"))
        #expect(Array(extensions[1...3]) == ["builtin:mcp", "builtin:codemode", "builtin:tool-search"])
        #expect(extensions[4] == chosen.extensionPaths[0])
        #expect(!extensions.contains { $0.contains("not-chosen") })
        #expect(config.arguments.contains("--no-extensions"))
        #expect(config.arguments.contains("--no-builtin-tools"))
        let tools = try #require(config.arguments.firstIndex(of: "--tools"))
        #expect(config.arguments[tools + 1] == TerminalAIPolicy.assistantToolSelection)
        let excluded = try #require(config.arguments.firstIndex(of: "--exclude-tools"))
        #expect(config.arguments[excluded + 1] == "bash,powershell")
        #expect(!config.arguments.contains("--no-mcp"))
        #expect(config.environment["GHOSTTY_AI_TRUSTED_EXTENSIONS"] == "true")
        let pathsJSON = try #require(config.environment["GHOSTTY_AI_TRUSTED_EXTENSION_PATHS"]?.data(using: .utf8))
        #expect(try JSONDecoder().decode([String].self, from: pathsJSON) == chosen.extensionPaths)
        #expect(config.arguments.contains("--skill"))
        #expect(config.arguments.contains("--prompt-template"))
        model.disableAllPlugins()
        #expect(fixture.makeModel().enabledPluginIDs.isEmpty)
    }

    @Test func commandModeDoesNotLoadPluginsEvenWhenAssistantHasEnabledThem() async throws {
        let fixture = try PluginModelFixture()
        defer { fixture.remove() }
        try fixture.package("chosen")
        let model = fixture.makeModel()
        await model.refreshPlugins()
        model.setPluginEnabled(try #require(model.availablePlugins.first), enabled: true)
        let config = try fixture.makeModel(mode: .command).prepareConnectionConfiguration()
        #expect(config.arguments.filter { $0 == "--extension" }.count == 1)
        #expect(!config.arguments.contains("--skill"))
        #expect(!config.arguments.contains("--prompt-template"))
        #expect(!config.arguments.contains("--exclude-tools"))
        #expect(config.arguments.contains("--no-mcp"))
        #expect(config.environment["GHOSTTY_AI_TRUSTED_EXTENSIONS"] == nil)
        #expect(config.environment["GHOSTTY_AI_TRUSTED_EXTENSION_PATHS"] == nil)
        let tools = try #require(config.arguments.firstIndex(of: "--tools"))
        #expect(config.arguments[tools + 1] == "ghostty_propose_command")
    }

    @Test func TUIOnlyAndMissingEntriesCannotBeEnabled() async throws {
        let fixture = try PluginModelFixture()
        defer { fixture.remove() }
        try fixture.package("pi-cc-extensions")
        try fixture.package("missing", entry: false)
        let model = fixture.makeModel()
        await model.refreshPlugins()
        for plugin in model.availablePlugins { model.setPluginEnabled(plugin, enabled: true) }
        #expect(model.enabledPluginIDs.isEmpty)
    }

    @Test func changingAgentDirectoryClearsSelectionAndMissingPackageCanBeRecovered() async throws {
        let fixture = try PluginModelFixture()
        defer { fixture.remove() }
        try fixture.package("chosen")
        let model = fixture.makeModel()
        await model.refreshPlugins()
        model.setPluginEnabled(try #require(model.availablePlugins.first), enabled: true)
        try FileManager.default.removeItem(at: fixture.agentDirectory.appendingPathComponent("npm/node_modules/chosen"))
        #expect(throws: (any Error).self) { try model.prepareConnectionConfiguration() }
        model.disableAllPlugins()
        #expect(throws: Never.self) { try model.prepareConnectionConfiguration() }
        try fixture.package("chosen")
        await model.refreshPlugins()
        model.setPluginEnabled(try #require(model.availablePlugins.first), enabled: true)
        model.piConfigurationDirectory = fixture.directory.appendingPathComponent("other-agent").path
        #expect(model.enabledPluginIDs.isEmpty)
        #expect(model.availablePlugins.isEmpty)
        #expect(fixture.defaults.stringArray(forKey: "terminalAI.enabledPluginIDs") == nil)
    }

    @Test func currentTaskLocksPluginSelection() async throws {
        let fixture = try PluginModelFixture()
        defer { fixture.remove() }
        try fixture.package("chosen")
        let model = fixture.makeModel()
        await model.refreshPlugins()
        let plugin = try #require(model.availablePlugins.first)
        model.present(surfaceID: UUID(), directory: fixture.directory.path, selection: nil)
        model.prompt = "Fixture task"
        model.submit()
        #expect(model.isRunning)
        model.setPluginEnabled(plugin, enabled: true)
        #expect(model.enabledPluginIDs.isEmpty)
        model.stop()
    }

    @Test func handledExtensionCommandsFinishWithoutAnAgentSettledEvent() throws {
        let fixture = try PluginModelFixture()
        defer { fixture.remove() }
        var sent: [[String: Any]] = []
        let model = TerminalAIModel(defaults: fixture.defaults, sendCommand: { sent.append($0) },
                                    configurationDirectory: fixture.directory.appendingPathComponent("handled"),
                                    builtinPluginDirectory: fixture.directory.appendingPathComponent("absent-builtin"))
        model.present(surfaceID: UUID(), directory: fixture.directory.path, selection: nil)
        model.prompt = "/fixture-command"
        model.submit()
        let promptID = try #require(sent.last { $0["type"] as? String == "prompt" }?["id"] as? String)
        model.receive(["type": "response", "id": promptID, "success": true, "data": ["disposition": "handled"]])
        let stateID = try #require(sent.last { $0["type"] as? String == "get_state" }?["id"] as? String)
        model.receive(["type": "response", "id": stateID, "success": true,
                       "data": ["isStreaming": false, "isCompacting": false, "pendingMessageCount": 0]])
        #expect(!model.isRunning)
        #expect(model.phase == .completed)
    }

    @Test func pluginMessagesRenderOnceAndHiddenContextStaysHidden() throws {
        let fixture = try PluginModelFixture()
        defer { fixture.remove() }
        let model = fixture.makeModel()
        let message: [String: Any] = ["role": "custom", "customType": "fixture-review", "timestamp": 42,
                                      "display": true, "content": "Review completed"]
        model.receive(["type": "message_start", "message": message])
        model.receive(["type": "message_end", "message": message])
        #expect(model.response == "fixture-review\n\nReview completed")
        var hidden = message
        hidden["display"] = false
        hidden["timestamp"] = 43
        hidden["content"] = "Hidden plugin context"
        model.receive(["type": "message_end", "message": hidden])
        #expect(!model.response.contains("Hidden plugin context"))
    }

    @Test func nativeMCPStatusPreservesDraftAndDisplaysPiNotifications() throws {
        let fixture = try PluginModelFixture()
        defer { fixture.remove() }
        var sent: [[String: Any]] = []
        let model = TerminalAIModel(defaults: fixture.defaults, sendCommand: { sent.append($0) },
                                    configurationDirectory: fixture.directory.appendingPathComponent("mcp-status"),
                                    builtinPluginDirectory: fixture.directory.appendingPathComponent("absent-builtin"))
        model.present(surfaceID: UUID(), directory: fixture.directory.path, selection: nil)
        model.prompt = "Suggest a diagnostic command"
        model.submit()
        model.receive(["type": "tool_execution_end", "toolCallId": "fixture-suggestion", "toolName": "ghostty_propose_command",
                       "result": ["content": "Suggested command", "details": ["command": "pwd", "explanation": "Show directory"]]])
        model.receive(["type": "agent_settled"])
        let previousPlan = try #require(model.taskPlan)
        model.prompt = "Unsent draft 中文"
        model.showPiMCPStatus()
        #expect(sent.last { $0["type"] as? String == "prompt" }?["message"] as? String == "/mcp")
        #expect(model.prompt == "Unsent draft 中文")
        model.receive(["type": "extension_ui_request", "method": "notify", "id": "fixture-status",
                       "notifyType": "info", "message": "fixture connected · 2 tools"])
        #expect(model.response.contains("fixture connected · 2 tools"))
        #expect(model.error == nil)
        let promptID = try #require(sent.last { $0["type"] as? String == "prompt" }?["id"] as? String)
        model.receive(["type": "response", "id": promptID, "success": true, "data": ["disposition": "handled"]])
        let stateID = try #require(sent.last { $0["type"] as? String == "get_state" }?["id"] as? String)
        model.receive(["type": "response", "id": stateID, "success": true,
                       "data": ["isStreaming": false, "isCompacting": false, "pendingMessageCount": 0]])
        #expect(!model.isRunning)
        #expect(model.suggestedCommand == "pwd")
        #expect(model.suggestedExplanation == "Show directory")
        let restoredPlan = try #require(model.taskPlan)
        #expect(restoredPlan.id == previousPlan.id)
        #expect(restoredPlan.verification.status == previousPlan.verification.status)
        #expect(restoredPlan.verification.summary == previousPlan.verification.summary)
    }

    @Test func absolutePathQuestionsKeepSelectedTerminalContext() throws {
        let fixture = try PluginModelFixture()
        defer { fixture.remove() }
        for question in ["/tmp/fixture-log.txt 帮我分析", "/tmp 帮我分析"] {
            var sent: [[String: Any]] = []
            let model = TerminalAIModel(defaults: fixture.defaults, sendCommand: { sent.append($0) },
                                        configurationDirectory: fixture.directory.appendingPathComponent(UUID().uuidString),
                                        builtinPluginDirectory: fixture.directory.appendingPathComponent("absent-builtin"))
            model.present(surfaceID: UUID(), directory: fixture.directory.path, selection: "selected terminal evidence")
            model.prompt = question
            model.submit()
            let wire = try #require(sent.last { $0["type"] as? String == "prompt" }?["message"] as? String)
            #expect(wire.contains("selected terminal evidence"))
            #expect(wire.contains("User request: \(question)"))
            #expect(wire.contains("ghostty_terminal"))
            model.stop()
        }
    }
}

@MainActor
private final class PluginModelFixture {
    let directory: URL
    let agentDirectory: URL
    let defaults: UserDefaults
    private let suite: String

    init() throws {
        suite = "TerminalAIPluginModelTests.\(UUID().uuidString)"
        defaults = try #require(UserDefaults(suiteName: suite))
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        agentDirectory = directory.appendingPathComponent("agent")
        try FileManager.default.createDirectory(at: agentDirectory, withIntermediateDirectories: true)
        defaults.set("/test/pi", forKey: "terminalAI.executablePath")
        defaults.set("", forKey: "terminalAI.nodePath")
        defaults.set(true, forKey: "terminalAI.useExistingPiConfiguration")
        defaults.set(agentDirectory.path, forKey: "terminalAI.piConfigurationDirectory")
    }

    func makeModel(mode: TerminalAIModel.Mode = .assistant) -> TerminalAIModel {
        let model = TerminalAIModel(defaults: defaults, sendCommand: { _ in },
                                    configurationDirectory: directory.appendingPathComponent("configuration"), mode: mode,
                                    builtinPluginDirectory: directory.appendingPathComponent("absent-builtin"))
        model.workingDirectory = directory.path
        return model
    }

    func package(_ name: String, entry: Bool = true) throws {
        let package = agentDirectory.appendingPathComponent("npm/node_modules/\(name)")
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        let manifest: [String: Any] = ["name": name, "version": "1.0.0", "description": "Fixture plugin",
                                       "pi": ["extensions": ["index.js"], "skills": ["skills"], "prompts": ["prompts"]]]
        try JSONSerialization.data(withJSONObject: manifest).write(to: package.appendingPathComponent("package.json"))
        guard entry else { return }
        try "throw new Error('A metadata scan must never import this fixture');".write(
            to: package.appendingPathComponent("index.js"), atomically: true, encoding: .utf8)
        for path in ["skills/example", "prompts"] {
            try FileManager.default.createDirectory(at: package.appendingPathComponent(path), withIntermediateDirectories: true)
        }
        try "---\nname: fixture\ndescription: Fixture skill\n---\nFixture".write(
            to: package.appendingPathComponent("skills/example/SKILL.md"), atomically: true, encoding: .utf8)
        try "Fixture prompt".write(to: package.appendingPathComponent("prompts/example.md"), atomically: true, encoding: .utf8)
    }

    func remove() {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory)
    }
}
