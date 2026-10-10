import Foundation
import GhosttyKit
import Testing
@testable import Ghostty

@MainActor
struct TerminalAIModelTests {
    @Test func selectionQuestionCanReachSetupAndSurvivesConfiguration() throws {
        let suite = "TerminalAIModelTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("/test/pi", forKey: "terminalAI.executablePath")
        var commands: [[String: Any]] = []
        let assistant = TerminalAIModel(defaults: defaults, sendCommand: { commands.append($0) },
                                        configurationDirectory: FileManager.default.temporaryDirectory.appendingPathComponent("TerminalAITests.\(UUID())"))
        assistant.useExistingPiConfiguration = false
        assistant.present(surfaceID: UUID(), directory: "/tmp", selection: "Example error output")
        assistant.prompt = "Explain this output and help me investigate the problem."

        #expect(assistant.canSubmit)
        assistant.submit()
        #expect(commands.isEmpty)
        #expect(assistant.error == assistant.configurationIssue)
        #expect(assistant.error?.contains("Provider") == true)
        #expect(assistant.error?.contains("Model") == true)
        #expect(assistant.context == "Example error output")
        #expect(assistant.prompt == "Explain this output and help me investigate the problem.")

        assistant.provider = "fixture"
        assistant.model = "fixture-model"
        #expect(assistant.configurationIssue == nil)
        #expect(assistant.canSubmit)
        assistant.submit()
        let prompt = try #require(humanPrompts(commands).first)
        #expect((prompt["message"] as? String)?.contains("Example error output") == true)
        #expect(!assistant.canSubmit)
        assistant.receive(["type": "agent_settled"])
        #expect(!assistant.canSubmit)
    }

    @Test func jsonLinesPreserveSplitUnicodeAndSeparators() throws {
        let wire = Data("{\"type\":\"message\",\"text\":\"中文\u{2028}🌏\"}\r\n{\"type\":\"done\"}\n".utf8)
        // Every byte boundary includes boundaries inside multibyte UTF-8 characters.
        for boundary in 0...wire.count {
            var parser = TerminalAIJSONLines()
            let first = try parser.append(Data(wire.prefix(boundary)))
            let second = try parser.append(Data(wire.dropFirst(boundary)))
            let records = first + second
            #expect(records.count == 2)
            #expect(records[0]["text"] as? String == "中文\u{2028}🌏")
            #expect(!parser.hasIncompleteRecord)
        }
    }

    @Test func jsonLinesRejectMalformedAndRetainPartialRecords() throws {
        var parser = TerminalAIJSONLines()
        #expect(try parser.append(Data("{\"type\":\"done\"}".utf8)).isEmpty)
        #expect(parser.hasIncompleteRecord)
        #expect(try parser.append(Data("\n".utf8)).count == 1)
        #expect(throws: (any Error).self) { try parser.append(Data("not json\n".utf8)) }
    }

    @Test func runWaitsForSettledAndUsesAuthoritativeMessage() {
        var commands: [[String: Any]] = []
        let assistant = makeModel { commands.append($0) }
        assistant.prompt = "Investigate"
        assistant.submit()
        #expect(assistant.isRunning)
        let prompt = humanPrompts(commands).first
        assistant.receive(["type": "response", "id": prompt?["id"] ?? "", "success": true])
        #expect(assistant.isRunning)
        assistant.receive(["type": "message_start", "message": ["role": "assistant"]])
        assistant.receive([
            "type": "message_update",
            "assistantMessageEvent": ["type": "text_delta", "contentIndex": 0, "delta": "partial"]
        ])
        #expect(assistant.response.hasSuffix("partial"))
        assistant.receive([
            "type": "message_end",
            "message": ["role": "assistant", "content": [["type": "text", "text": "final"]]]
        ])
        #expect(assistant.response.hasSuffix("final"))
        assistant.receive(["type": "agent_end", "willRetry": false])
        #expect(assistant.isRunning)
        assistant.receive(["type": "agent_settled"])
        #expect(!assistant.isRunning)
    }

    @Test func diagnosticSegmentsBindFrozenHumanWireAndRemainPrivate() throws {
        var commands: [[String: Any]] = []
        let assistant = makeModel { commands.append($0) }
        assistant.sendInput("调查 CPU 中文")
        #expect(commands.count == 2)
        let initial = try #require(humanPrompts(commands).first)
        let wire = try #require(initial["message"] as? String)
        let segment = commands[0]
        #expect(segment["type"] as? String == "prompt")
        #expect(segment["message"] as? String == "/_ghostty_begin_work_segment \(TerminalAIApprovalReview.sha256(Data(wire.utf8)))")
        #expect(segment["streamingBehavior"] == nil)
        #expect(segment["id"] as? String != initial["id"] as? String)
        let before = try JSONSerialization.data(withJSONObject: assistant.webSnapshot, options: [.sortedKeys])
        assistant.receive(["type": "response", "id": segment["id"] ?? "", "success": true, "data": ["disposition": "handled"]])
        #expect(assistant.isRunning)
        #expect(assistant.error == nil)
        #expect(commands.count == 2, "A private acknowledgement must not request state or finish the main prompt")
        #expect(try JSONSerialization.data(withJSONObject: assistant.webSnapshot, options: [.sortedKeys]) == before)
        assistant.receive(["type": "response", "id": segment["id"] ?? "", "success": false])
        #expect(assistant.error == nil, "A consumed private response must not affect another request")
        assistant.sendInput("继续检查进程", mode: "steer")
        #expect(commands.count == 4)
        #expect(commands[2]["message"] as? String == "/_ghostty_begin_work_segment \(TerminalAIApprovalReview.sha256(Data("继续检查进程".utf8)))")
        #expect(commands[3]["message"] as? String == "继续检查进程")
        #expect(commands[3]["streamingBehavior"] as? String == "steer")
        assistant.receive(["type": "response", "id": commands[2]["id"] ?? "", "success": true, "data": ["disposition": "handled"]])
        #expect((assistant.webSnapshot["queuedInputs"] as? [[String: String]])?.isEmpty == true)
        #expect(assistant.messages.filter { $0.role == "user" }.count == 1)
        #expect(!assistant.response.contains("/_ghostty_begin_work_segment"))
        assistant.receive(["type": "response", "id": commands[3]["id"] ?? "", "success": true, "data": ["disposition": "queued"]])
        #expect((assistant.webSnapshot["queuedInputs"] as? [[String: String]])?.first?["text"] == "继续检查进程")
    }

    @Test func failedOrUnhandledDiagnosticHandshakeStopsTheMainTask() throws {
        let responses: [[String: Any]] = [
            ["success": false, "error": "Private command failed"],
            ["success": true],
            ["success": true, "data": ["disposition": "started"]],
            ["success": true, "data": ["disposition": "queued"]],
            ["data": ["disposition": "handled"]]
        ]
        for response in responses {
            var commands: [[String: Any]] = []
            let assistant = makeModel { commands.append($0) }
            assistant.sendInput("A real human request")
            let segment = try #require(commands.first)
            var record = response
            record["type"] = "response"
            record["id"] = segment["id"]
            assistant.receive(record)
            #expect(assistant.error?.contains("Pi could not start a diagnostic work segment") == true)
            #expect(assistant.phase == .failed)
            #expect(!assistant.isRunning)
            #expect((assistant.webSnapshot["queuedInputs"] as? [[String: String]])?.isEmpty == true)
            #expect(!assistant.response.contains("/_ghostty_begin_work_segment"))
        }
    }

    @Test func diagnosticPauseSettlesWithContinueHintAndHumanReadinessClearsIt() throws {
        var commands: [[String: Any]] = []
        let assistant = makeModel { commands.append($0) }
        assistant.sendInput("Investigate")
        assistant.receive(["type": "extension_ui_request", "id": "budget-paused", "method": "setStatus",
                           "statusKey": "ghostty-diagnostics", "statusText": "paused"])
        assistant.receive(["type": "agent_end"])
        #expect(assistant.isRunning, "Wait for authoritative settlement after the tool-free summary")
        assistant.receive(["type": "agent_settled"])
        #expect(!assistant.isRunning)
        #expect(assistant.phase == .stopped)
        #expect(assistant.statusLabel == "Paused · Send a message to continue")
        #expect(assistant.error == nil)
        assistant.prompt = "请继续"
        #expect(assistant.canSubmit)
        assistant.receive(["type": "extension_ui_request", "id": "late-ready", "method": "setStatus",
                           "statusKey": "ghostty-diagnostics", "statusText": "ready"])
        #expect(assistant.phase == .stopped, "Stale readiness cannot restart a settled task")
        assistant.sendInput("请继续")
        #expect(assistant.isRunning)
        #expect((humanPrompts(commands).last?["message"] as? String)?.contains("请继续") == true)
        assistant.receive(["type": "extension_ui_request", "id": "another-pause", "method": "setStatus",
                           "statusKey": "ghostty-diagnostics", "statusText": "paused"])
        assistant.receive(["type": "extension_ui_request", "id": "human-ready", "method": "setStatus",
                           "statusKey": "ghostty-diagnostics", "statusText": "ready"])
        assistant.receive(["type": "agent_settled"])
        #expect(!assistant.isRunning)
        #expect(assistant.phase == .completed)
        #expect(assistant.statusLabel == "Completed")
        #expect(assistant.error == nil)
    }

    @Test func rejectionAndStopNeverApprovePendingCommand() {
        var commands: [[String: Any]] = []
        let assistant = makeModel { commands.append($0) }
        assistant.prompt = "Check the port"
        assistant.submit()
        assistant.receive(["type": "extension_ui_request", "id": "deny", "method": "confirm", "message": "kill 42"])
        assistant.respondToApproval(allow: false)
        #expect(commands.last?["confirmed"] as? Bool == false)
        assistant.receive(["type": "extension_ui_request", "id": "stop", "method": "confirm"])
        assistant.stop()
        #expect(assistant.approval == nil)
        #expect(assistant.isRunning)
        #expect(commands.contains { $0["id"] as? String == "stop" && $0["confirmed"] as? Bool == false })
        #expect(commands.suffix(2).compactMap { $0["type"] as? String } == ["clear_queue", "abort"])
        assistant.receive(["type": "extension_ui_request", "id": "late", "method": "confirm"])
        #expect(commands.last?["confirmed"] as? Bool == false)
        assistant.receive(["type": "agent_settled"])
        #expect(!assistant.isRunning)
    }

    @Test func correlateFailuresAndReplaceToolSnapshots() {
        var commands: [[String: Any]] = []
        let assistant = makeModel { commands.append($0) }
        assistant.prompt = "Suggest a command"
        assistant.submit()
        assistant.receive(["type": "response", "id": "unrelated", "success": false, "error": "ignore"])
        #expect(assistant.error == nil)
        assistant.receive(["type": "tool_execution_start", "toolCallId": "tool", "toolName": "ghostty_propose_command"])
        assistant.receive([
            "type": "tool_execution_update", "toolCallId": "tool",
            "partialResult": ["content": [["type": "text", "text": "partial"]]]
        ])
        assistant.receive([
            "type": "tool_execution_end", "toolCallId": "tool", "isError": false,
            "result": [
                "content": [["type": "text", "text": "complete"]],
                "details": ["command": "lsof -i :8080", "explanation": "Check the port"]
            ]
        ])
        #expect(assistant.toolExecutions.first?.output == "complete")
        #expect(assistant.toolExecutions.first?.isRunning == false)
        #expect(assistant.suggestedCommand == "lsof -i :8080")
        assistant.receive(["type": "response", "id": humanPrompts(commands).first?["id"] ?? "", "success": false, "error": "bad model"])
        #expect(assistant.error == "bad model")
        #expect(!assistant.isRunning)
    }

    @Test func terminalBindingAndConfigurationChangesKeepConversationUntilNew() {
        let assistant = makeModel { _ in }
        let original = assistant.surfaceID
        assistant.prompt = "Investigate"
        assistant.submit()
        assistant.present(surfaceID: UUID(), directory: "/tmp", selection: "other terminal")
        #expect(assistant.surfaceID == original)
        #expect(assistant.context.isEmpty)
        assistant.receive(["type": "agent_settled"])
        assistant.model = "different-model"
        assistant.prompt = "New task"
        assistant.submit()
        #expect(assistant.response.contains("Investigate"))
        assistant.reset()
        #expect(!assistant.isRunning)
        #expect(assistant.response.isEmpty)
    }

    @Test func invalidTerminalDirectoryRequiresExplicitLocalSelectionAndPreservesIt() {
        var commands: [[String: Any]] = []
        let assistant = makeModel { commands.append($0) }
        let surfaceID = UUID()
        assistant.present(surfaceID: surfaceID, directory: "/a-remote-directory-that-does-not-exist", selection: "old")
        assistant.prompt = "Investigate"
        assistant.submit()
        #expect(!assistant.isRunning)
        #expect(commands.isEmpty)
        assistant.workingDirectory = "/tmp"
        assistant.submit()
        #expect(assistant.isRunning)
        assistant.receive(["type": "agent_settled"])
        let response = assistant.response
        assistant.present(surfaceID: surfaceID, directory: "/a-remote-directory-that-does-not-exist", selection: nil)
        #expect(assistant.workingDirectory == "/tmp")
        #expect(assistant.context.isEmpty)
        #expect(assistant.response == response)
    }

    @Test func rpcTransportDrainsChunkedUnicodeBeforeReportingExit() async throws {
        var records: [[String: Any]] = []
        var failures: [String] = []
        let script = """
        import json, sys, time
        request = json.loads(sys.stdin.readline())
        data = (json.dumps({'type':'response', 'id':request['id'], 'text':'中文🌏'}, ensure_ascii=False) + '\\n').encode()
        for byte in data:
            sys.stdout.buffer.write(bytes([byte]))
            sys.stdout.buffer.flush()
            time.sleep(0.001)
        sys.stderr.write('fixture diagnostic')
        sys.stderr.flush()
        sys.exit(3)
        """
        let connection = try TerminalAIRPC(
            executable: URL(fileURLWithPath: "/usr/bin/python3"), arguments: ["-c", script],
            directory: "/tmp", environment: ["PATH": "/usr/bin:/bin"],
            onRecord: { records.append($0) }, onFailure: { failures.append($0) })
        defer { connection.close() }
        try connection.send(["type": "get_state", "id": "fixture"])
        for _ in 0..<100 where failures.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
        #expect(records.count == 1)
        #expect(records.first?["text"] as? String == "中文🌏")
        #expect(failures.count == 1)
        #expect(failures.first?.contains("Pi exited (3). fixture diagnostic") == true)
    }

    @Test func closingRPCSuppressesLateCallbacksAndRejectsWrites() async throws {
        var failures: [String] = []
        let connection = try TerminalAIRPC(
            executable: URL(fileURLWithPath: "/usr/bin/python3"), arguments: ["-c", "import time; time.sleep(10)"],
            directory: "/tmp", environment: ["PATH": "/usr/bin:/bin"],
            onRecord: { _ in }, onFailure: { failures.append($0) })
        connection.close()
        #expect(throws: (any Error).self) { try connection.send(["type": "get_state"]) }
        try await Task.sleep(for: .milliseconds(100))
        #expect(failures.isEmpty)
    }

    @Test func closingRPCKeepsSessionLeaseUntilProcessActuallyExits() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("TerminalAILeaseTests.\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = TerminalAIHistoryStore(directory: directory)
        let id = UUID()
        var lease: TerminalAIHistoryStore.Lease? = try store.acquire(id: id)
        var ready = false
        let script = """
        import json, signal, sys, time
        def finish(signum, frame):
            time.sleep(0.3)
            sys.exit(0)
        signal.signal(signal.SIGTERM, finish)
        print(json.dumps({'type':'ready'}), flush=True)
        while True: time.sleep(0.1)
        """
        let connection = try TerminalAIRPC(
            executable: URL(fileURLWithPath: "/usr/bin/python3"), arguments: ["-c", script],
            directory: "/tmp", environment: ["PATH": "/usr/bin:/bin"], sessionLease: lease,
            onRecord: { _ in ready = true }, onFailure: { _ in })
        for _ in 0..<100 where !ready { try await Task.sleep(for: .milliseconds(10)) }
        #expect(ready)
        connection.close()
        lease = nil
        #expect(throws: TerminalAIHistoryStore.StoreError.busy) { try store.acquire(id: id) }
        for _ in 0..<100 where !connection.hasExited { try await Task.sleep(for: .milliseconds(10)) }
        #expect(connection.hasExited)
        // Process.isRunning becomes false before waitUntilExit's background
        // closure necessarily returns. Wait for that owner to release its lease.
        var next: TerminalAIHistoryStore.Lease?
        for _ in 0..<200 {
            do {
                next = try store.acquire(id: id)
                break
            } catch TerminalAIHistoryStore.StoreError.busy {
                try await Task.sleep(for: .milliseconds(10))
            }
        }
        #expect(next != nil)
        withExtendedLifetime(next) {}
    }

    @Test func connectionConfigurationsAreIsolatedAndKeepEnvironmentSnapshots() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("TerminalAIConnectionTests.\(UUID())")
        let firstDirectory = root.appendingPathComponent("first", isDirectory: true)
        let secondDirectory = root.appendingPathComponent("second", isDirectory: true)
        try FileManager.default.createDirectory(at: firstDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: secondDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let userFile = root.appendingPathComponent("models.json")
        try Data("user-owned configuration".utf8).write(to: userFile)
        let first = makeModel(configurationDirectory: root) { _ in }
        let second = makeModel(configurationDirectory: root) { _ in }
        first.workingDirectory = firstDirectory.path
        first.baseURL = "https://first.example/v1"
        first.apiKey = "fixture-first-key"
        second.workingDirectory = secondDirectory.path
        second.baseURL = "https://second.example/v1"
        second.apiKey = "fixture-second-key"
        let firstConfiguration = try first.prepareConnectionConfiguration()
        let secondConfiguration = try second.prepareConnectionConfiguration()
        first.baseURL = "https://next.example/v1"
        first.workingDirectory = secondDirectory.path
        let nextConfiguration = try first.prepareConnectionConfiguration()
        #expect(Set([firstConfiguration.agentDirectory, secondConfiguration.agentDirectory, nextConfiguration.agentDirectory]).count == 3)
        #expect(firstConfiguration.directory == firstDirectory.path)
        #expect(firstConfiguration.environment["GHOSTTY_AI_WORKSPACE"] == firstDirectory.path)
        #expect(firstConfiguration.environment["GHOSTTY_AI_API_KEY"] == "fixture-first-key")
        #expect(secondConfiguration.environment["GHOSTTY_AI_API_KEY"] == "fixture-second-key")
        for configuration in [firstConfiguration, secondConfiguration, nextConfiguration] {
            let toolsIndex = try #require(configuration.arguments.firstIndex(of: "--tools"))
            #expect(configuration.arguments[toolsIndex + 1] == TerminalAIPolicy.assistantToolSelection)
            #expect(configuration.environment["PI_CODING_AGENT_DIR"] == configuration.agentDirectory.path)
            #expect(configuration.arguments.contains(configuration.agentDirectory.appendingPathComponent("ghostty-tools.mjs").path))
        }
        let data = try Data(contentsOf: firstConfiguration.agentDirectory.appendingPathComponent("models.json"))
        let providers = (try JSONSerialization.jsonObject(with: data) as? [String: Any])?["providers"] as? [String: Any]
        let provider = providers?["test-provider"] as? [String: Any]
        #expect(provider?["baseUrl"] as? String == "https://first.example/v1")
        #expect(provider?["apiKey"] as? String == "$GHOSTTY_AI_API_KEY")
        #expect(String(data: data, encoding: .utf8)?.contains("fixture-first-key") == false)
        #expect(try Data(contentsOf: userFile) == Data("user-owned configuration".utf8))
    }

    @Test func gatewayCredentialsDoNotCarryAcrossEndpointsOrProviders() {
        let assistant = makeModel { _ in }
        assistant.apiKey = "fixture-original-key"
        assistant.baseURL = "https://\(UUID().uuidString.lowercased()).example/v1"
        #expect(assistant.apiKey.isEmpty)
        assistant.apiKey = "fixture-new-key"
        assistant.provider = "fixture-provider-\(UUID())"
        #expect(assistant.apiKey.isEmpty)
    }

    @Test func existingPiConfigurationIsTheDefaultAndDoesNotRequireProviderOrModel() throws {
        let suite = "TerminalAIModelTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("/test/pi", forKey: "terminalAI.executablePath")
        var commands: [[String: Any]] = []
        let assistant = TerminalAIModel(defaults: defaults, sendCommand: { commands.append($0) },
                                        configurationDirectory: FileManager.default.temporaryDirectory.appendingPathComponent("TerminalAITests.\(UUID())"))
        #expect(assistant.useExistingPiConfiguration)
        let expectedDirectory = ProcessInfo.processInfo.environment["PI_CODING_AGENT_DIR"]
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".pi/agent").path
        #expect(assistant.piConfigurationDirectory == expectedDirectory)

        let source = FileManager.default.temporaryDirectory.appendingPathComponent("TerminalAIExistingPiTests.\(UUID())")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: source) }
        assistant.piConfigurationDirectory = source.path
        assistant.present(surfaceID: UUID(), directory: source.path, selection: "fixture error output")
        assistant.prompt = "Explain this error"
        #expect(assistant.provider.isEmpty)
        #expect(assistant.model.isEmpty)
        #expect(assistant.configurationIssue == nil)
        assistant.submit()
        #expect(assistant.isRunning)
        let prompt = try #require(humanPrompts(commands).first)
        #expect((prompt["message"] as? String)?.contains("fixture error output") == true)
    }

    @Test func existingPiConfigurationStaysUntouchedAndOnlyTheGhosttyExtensionIsGenerated() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("TerminalAIExistingPiTests.\(UUID())")
        let source = root.appendingPathComponent("existing-pi", isDirectory: true)
        let generated = root.appendingPathComponent("ghostty", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixtures = [
            "models.json": Data("{\"providers\":{\"fixture\":{\"apiKey\":\"fixture-source-key\"}}}".utf8),
            "settings.json": Data("{\"defaultProvider\":\"fixture\",\"defaultModel\":\"fixture-model\"}".utf8),
            "auth.json": Data("{\"fixture\":{\"type\":\"api_key\",\"key\":\"fixture-source-auth\"}}".utf8)
        ]
        for (name, data) in fixtures { try data.write(to: source.appendingPathComponent(name)) }
        let assistant = makeModel(configurationDirectory: generated) { _ in }
        assistant.useExistingPiConfiguration = true
        assistant.piConfigurationDirectory = source.path
        assistant.baseURL = "https://unused-custom.example/v1"
        assistant.apiKey = "fixture-custom-key-must-not-be-forwarded"
        let first = try assistant.prepareConnectionConfiguration()
        let second = try assistant.prepareConnectionConfiguration()

        for configuration in [first, second] {
            let toolsIndex = try #require(configuration.arguments.firstIndex(of: "--tools"))
            #expect(configuration.arguments[toolsIndex + 1] == TerminalAIPolicy.assistantToolSelection)
        }
        #expect(first.agentDirectory == source)
        #expect(first.environment["PI_CODING_AGENT_DIR"] == source.path)
        #expect(first.environment["GHOSTTY_AI_API_KEY"] == nil)
        #expect(!first.arguments.contains("--provider"))
        #expect(!first.arguments.contains("--model"))
        #expect(!first.arguments.contains("https://unused-custom.example/v1"))
        #expect(first.arguments.contains("--no-extensions"))
        #expect(first.arguments.contains("--no-builtin-tools"))
        #expect(first.arguments.contains("--no-context-files"))
        let firstExtension = try extensionPath(in: first)
        let secondExtension = try extensionPath(in: second)
        #expect(firstExtension != secondExtension)
        #expect(firstExtension.hasPrefix(generated.appendingPathComponent("runs").path + "/"))
        #expect(URL(fileURLWithPath: firstExtension).lastPathComponent == "ghostty-tools.mjs")
        #expect(FileManager.default.fileExists(atPath: firstExtension))
        #expect(!FileManager.default.fileExists(atPath: source.appendingPathComponent("ghostty-tools.mjs").path))
        #expect(!FileManager.default.fileExists(atPath: URL(fileURLWithPath: firstExtension)
            .deletingLastPathComponent().appendingPathComponent("models.json").path))
        #expect(Set(try FileManager.default.contentsOfDirectory(atPath: source.path)) == Set(fixtures.keys))
        for (name, data) in fixtures {
            #expect(try Data(contentsOf: source.appendingPathComponent(name)) == data)
        }
    }

    @Test func changingTheExistingPiDirectoryReconnectsWithoutClearingConversation() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("TerminalAIExistingPiTests.\(UUID())")
        let first = root.appendingPathComponent("first", isDirectory: true)
        let second = root.appendingPathComponent("second", isDirectory: true)
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let assistant = makeModel { _ in }
        assistant.useExistingPiConfiguration = true
        assistant.piConfigurationDirectory = first.path
        assistant.prompt = "First directory task"
        assistant.submit()
        assistant.receive(["type": "agent_settled"])
        #expect(assistant.response.contains("First directory task"))
        assistant.piConfigurationDirectory = second.path
        assistant.prompt = "Second directory task"
        assistant.submit()
        #expect(assistant.response.contains("First directory task"))
        #expect(assistant.response.contains("Second directory task"))
    }

    @Test func existingPiModelLabelComesFromRPCStateWithoutOverwritingCustomConfiguration() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("TerminalAIExistingPiTests.\(UUID())")
        let source = root.appendingPathComponent("existing-pi", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let script = root.appendingPathComponent("fixture-pi.py")
        let fixture = """
        import json, sys
        print(json.dumps({'type':'extension_ui_request', 'id':'ready', 'method':'setStatus',
                          'statusKey':'ghostty-policy', 'statusText':'ready'}), flush=True)
        for line in sys.stdin:
            request = json.loads(line)
            if request['type'] == 'get_state':
                print(json.dumps({'type':'response', 'id':request['id'], 'command':'get_state',
                                  'success':True, 'data':{'model':{'provider':'fixture-active',
                                                                'id':'fixture-active-model'}}}), flush=True)
            elif request['type'] == 'prompt':
                if request.get('message', '').startswith('/_ghostty_begin_work_segment '):
                    print(json.dumps({'type':'response', 'id':request['id'], 'success':True,
                                      'data':{'disposition':'handled'}}), flush=True)
                    continue
                print(json.dumps({'type':'agent_settled'}), flush=True)
        """
        try Data(fixture.utf8).write(to: script)
        let suite = "TerminalAIModelTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let assistant = TerminalAIModel(defaults: defaults, configurationDirectory: root.appendingPathComponent("ghostty"))
        defer { assistant.reset() }
        assistant.executablePath = script.path
        assistant.nodePath = "/usr/bin/python3"
        assistant.piConfigurationDirectory = source.path
        assistant.provider = "fixture-custom"
        assistant.model = "fixture-custom-model"
        assistant.present(surfaceID: UUID(), directory: root.path, selection: nil)
        assistant.prompt = "Investigate"
        assistant.submit()
        for _ in 0..<100 where assistant.activeModelLabel.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
        #expect(assistant.activeModelLabel == "fixture-active/fixture-active-model")
        #expect(assistant.provider == "fixture-custom")
        #expect(assistant.model == "fixture-custom-model")
        #expect(assistant.error == nil)
    }

    private func extensionPath(in configuration: TerminalAIModel.ConnectionConfiguration) throws -> String {
        let index = try #require(configuration.arguments.firstIndex(of: "--extension"))
        #expect(configuration.arguments.indices.contains(index + 1))
        return configuration.arguments[index + 1]
    }

    @Test func structuredConversationKeepsToolPositionAndAuthoritativeContent() throws {
        let assistant = makeModel { _ in }
        assistant.sendInput("Investigate")
        assistant.receive(["type": "message_start", "message": ["role": "assistant", "timestamp": 100]])
        assistant.receive([
            "type": "message_update", "assistantMessageEvent": ["type": "text_delta", "contentIndex": 2, "delta": "after"]
        ])
        assistant.receive([
            "type": "message_update", "assistantMessageEvent": ["type": "text_delta", "contentIndex": 0, "delta": "before"]
        ])
        assistant.receive([
            "type": "message_update", "assistantMessageEvent": [
                "type": "toolcall_start", "contentIndex": 1, "id": "read", "toolName": "ghostty_diagnose"
            ]
        ])
        let tool: [String: Any] = ["type": "toolCall", "id": "read", "name": "ghostty_diagnose",
                                   "arguments": ["operation": "read", "path": "server.log"]]
        assistant.receive([
            "type": "message_update", "assistantMessageEvent": ["type": "toolcall_end", "contentIndex": 1, "toolCall": tool]
        ])
        assistant.receive(["type": "tool_execution_start", "toolCallId": "read", "toolName": "ghostty_diagnose",
                           "args": ["operation": "read", "path": "server.log"]])
        assistant.receive(["type": "tool_execution_update", "toolCallId": "read",
                           "partialResult": ["content": [["type": "text", "text": "partial output"]]]])
        assistant.receive(["type": "tool_execution_end", "toolCallId": "read", "isError": false,
                           "result": ["content": [["type": "text", "text": "final output"]]]])
        let ending: [String: Any] = ["type": "message_end", "message": [
            "role": "assistant", "timestamp": 100,
            "content": [["type": "text", "text": "authoritative before"], tool,
                        ["type": "text", "text": "authoritative after"]]
        ]]
        assistant.receive(ending)
        assistant.receive(ending)
        assistant.receive(["type": "tool_execution_start", "toolCallId": "read", "toolName": "ghostty_diagnose"])
        let snapshot = assistant.webSnapshot
        #expect(JSONSerialization.isValidJSONObject(snapshot))
        let messages = try #require(snapshot["messages"] as? [[String: Any]])
        #expect(messages.count == 2)
        let content = try #require(messages[1]["content"] as? [[String: Any]])
        #expect(content.map { $0["type"] as? String } == ["text", "tool-call", "text"])
        #expect(content[0]["text"] as? String == "authoritative before")
        #expect(content[2]["text"] as? String == "authoritative after")
        #expect(content[1]["label"] as? String == "Read file")
        #expect(content[1]["detail"] as? String == "server.log")
        let result = try #require(content[1]["result"] as? [String: Any])
        #expect(result["text"] as? String == "final output")
        #expect(result["isRunning"] as? Bool == false)
        #expect(assistant.toolExecutions.count == 1)
        assistant.receive(["type": "message_start", "message": ["role": "assistant", "timestamp": 101]])
        assistant.receive(["type": "message_end", "message": ["role": "assistant", "timestamp": 101,
                           "content": [["type": "text", "text": "conclusion"]]]])
        assistant.receive(["type": "agent_settled"])
        #expect(assistant.messages.count == 3)
        #expect(assistant.phase == .completed)
        #expect(assistant.response.hasSuffix("conclusion"))
    }

    @Test func queuedInputsAppearOnceWhenPiConsumesThem() throws {
        var commands: [[String: Any]] = []
        let assistant = makeModel { commands.append($0) }
        assistant.sendInput("Initial question")
        let initial = try #require(humanPrompts(commands).first?["message"] as? String)
        assistant.receive(["type": "message_start", "message": ["role": "user", "timestamp": 1, "content": initial]])
        assistant.receive(["type": "message_end", "message": ["role": "user", "timestamp": 1, "content": initial]])
        #expect(assistant.messages.count == 1)
        #expect(assistant.response == "You: Initial question")
        assistant.sendInput("Investigate the port instead", mode: "steer")
        assistant.sendInput("Then summarize", mode: "follow_up")
        #expect(humanPrompts(commands).suffix(2).compactMap { $0["type"] as? String } == ["prompt", "prompt"])
        #expect(humanPrompts(commands).suffix(2).compactMap { $0["streamingBehavior"] as? String } == ["steer", "followUp"])
        for command in humanPrompts(commands).suffix(2) {
            assistant.receive(["type": "response", "id": command["id"] ?? "", "success": true])
        }
        #expect((assistant.webSnapshot["queuedInputs"] as? [[String: String]])?.count == 2)
        #expect(assistant.messages.count == 1)
        let consumed: [String: Any] = ["role": "user", "timestamp": 2, "content": "Investigate the port instead"]
        assistant.receive(["type": "message_start", "message": consumed])
        assistant.receive(["type": "message_end", "message": consumed])
        assistant.receive(["type": "message_start", "message": consumed])
        #expect(assistant.messages.count == 2)
        #expect(assistant.response.hasSuffix("Investigate the port instead"))
        assistant.receive(["type": "agent_settled"])
        #expect(!assistant.response.contains("Then summarize"))
        #expect((assistant.webSnapshot["queuedInputs"] as? [[String: String]])?.first?["text"] == "Then summarize")
    }

    @Test func queuedPromptSurvivesSettlementAndStartsWithoutLosingInput() throws {
        var commands: [[String: Any]] = []
        let assistant = makeModel { commands.append($0) }
        assistant.sendInput("First task")
        assistant.sendInput("Next task", mode: "follow_up")
        let request = try #require(commands.last)
        #expect(request["type"] as? String == "prompt")
        #expect(request["streamingBehavior"] as? String == "followUp")
        assistant.receive(["type": "agent_settled"])
        #expect(assistant.isRunning)
        #expect(assistant.statusLabel == "Queued")
        #expect((assistant.webSnapshot["queuedInputs"] as? [[String: String]])?.isEmpty == true)
        assistant.receive(["type": "response", "id": request["id"] ?? "", "success": true])
        let waiting = try #require(assistant.webSnapshot["queuedInputs"] as? [[String: String]])
        #expect(waiting.count == 1)
        #expect(waiting[0]["text"] == "Next task")
        #expect(waiting[0]["mode"] == "follow_up")
        assistant.receive(["type": "agent_start"])
        #expect(assistant.isRunning)
        #expect(assistant.phase == .thinking)
        let input: [String: Any] = ["role": "user", "timestamp": 10, "content": "Next task"]
        assistant.receive(["type": "message_start", "message": input])
        assistant.receive(["type": "message_end", "message": input])
        #expect((assistant.webSnapshot["queuedInputs"] as? [[String: String]])?.isEmpty == true)
        #expect(assistant.messages.filter { $0.role == "user" }.count == 2)
        assistant.receive(["type": "agent_settled"])
        assistant.receive(["type": "agent_start"])
        #expect(!assistant.isRunning)
    }

    @Test func thirdInputDuringQueuedSettlementUsesAtomicFollowUp() throws {
        var commands: [[String: Any]] = []
        let assistant = makeModel { commands.append($0) }
        assistant.sendInput("First task")
        #expect(humanPrompts(commands).first?["streamingBehavior"] as? String == "followUp")
        assistant.sendInput("Second task", mode: "follow_up")
        let second = try #require(commands.last)
        assistant.receive(["type": "response", "id": second["id"] ?? "", "success": true])
        assistant.receive(["type": "agent_settled"])
        #expect(assistant.isRunning)
        #expect(assistant.phase == .thinking)
        #expect(assistant.statusLabel == "Queued")
        assistant.sendInput("Third task")
        let third = try #require(commands.last)
        #expect(third["type"] as? String == "prompt")
        #expect(third["message"] as? String == "Third task")
        #expect(third["streamingBehavior"] as? String == "followUp")
        assistant.receive(["type": "response", "id": third["id"] ?? "", "success": true])
        #expect((assistant.webSnapshot["queuedInputs"] as? [[String: String]])?.count == 2)
        assistant.receive(["type": "agent_start"])
        for (timestamp, text) in [(20, "Second task"), (21, "Third task")] {
            let input: [String: Any] = ["role": "user", "timestamp": timestamp, "content": text]
            assistant.receive(["type": "message_start", "message": input])
            assistant.receive(["type": "message_end", "message": input])
        }
        assistant.receive(["type": "agent_settled"])
        #expect(!assistant.isRunning)
        #expect(assistant.phase == .completed)
        #expect(assistant.error == nil)
        #expect(assistant.messages.filter { $0.role == "user" }.count == 3)
    }

    @Test func submittingFrozenPromptDoesNotEraseANewerDraft() throws {
        var assistant: TerminalAIModel?
        defer { assistant = nil }
        var commands: [[String: Any]] = []
        assistant = makeModel { command in
            commands.append(command)
            if command["type"] as? String == "prompt" { assistant?.prompt = "New draft typed while Pi starts" }
        }
        let model = try #require(assistant)
        model.prompt = "Original submitted question"
        model.submit()
        #expect(model.prompt == "New draft typed while Pi starts")
        #expect((humanPrompts(commands).first?["message"] as? String)?.contains("Original submitted question") == true)
        #expect((humanPrompts(commands).first?["message"] as? String)?.contains("New draft typed while Pi starts") == false)
        #expect(model.response == "You: Original submitted question")
        model.sendInput("Queued submitted question", mode: "follow_up")
        #expect(model.prompt == "New draft typed while Pi starts")
        #expect(commands.last?["message"] as? String == "Queued submitted question")
    }

    @Test func failedPromptWriteRestoresSubmittedQuestionWithoutOverwritingNewDraft() throws {
        let suite = "TerminalAIModelTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var assistant: TerminalAIModel?
        defer { assistant = nil }
        var writeNewDraft = false
        assistant = TerminalAIModel(defaults: defaults, sendCommand: { _ in
            if writeNewDraft { assistant?.prompt = "New draft" }
            throw CocoaError(.fileWriteUnknown)
        }, configurationDirectory: FileManager.default.temporaryDirectory.appendingPathComponent("TerminalAITests.\(UUID())"))
        let model = try #require(assistant)
        model.useExistingPiConfiguration = false
        model.executablePath = "/test/pi"
        model.provider = "fixture"
        model.model = "fixture-model"
        model.present(surfaceID: UUID(), directory: "/tmp", selection: nil)
        model.prompt = "Original submitted question"
        model.submit()
        #expect(model.prompt == "Original submitted question")
        #expect(model.phase == .failed)
        writeNewDraft = true
        model.submit()
        #expect(model.prompt == "New draft")
        #expect(model.phase == .failed)
    }

    @Test func queuedPromptStopAndRejectionClearPendingInputs() throws {
        var commands: [[String: Any]] = []
        let assistant = makeModel { commands.append($0) }
        assistant.sendInput("First task")
        assistant.sendInput("Steer task", mode: "steer")
        let request = try #require(commands.last)
        assistant.receive(["type": "agent_settled"])
        assistant.receive(["type": "response", "id": request["id"] ?? "", "success": true])
        assistant.stop()
        #expect(assistant.phase == .stopping)
        #expect((assistant.webSnapshot["queuedInputs"] as? [[String: String]])?.isEmpty == true)
        assistant.receive(["type": "agent_settled"])
        assistant.receive(["type": "agent_start"])
        #expect(assistant.phase == .stopped)
        #expect(!assistant.isRunning)
        assistant.sendInput("New task")
        assistant.sendInput("Rejected task", mode: "follow_up")
        let rejected = try #require(commands.last)
        assistant.receive(["type": "response", "id": rejected["id"] ?? "", "success": false, "error": "Queue rejected"])
        #expect(assistant.phase == .failed)
        #expect(assistant.prompt == "Rejected task")
        #expect((assistant.webSnapshot["queuedInputs"] as? [[String: String]])?.isEmpty == true)
    }

    @Test func lifecycleCoversThinkingApprovalRecoveryAndStaleEvents() throws {
        let assistant = makeModel { _ in }
        assistant.sendInput("Investigate")
        #expect(assistant.startedAt != nil)
        #expect(assistant.phase == .thinking)
        assistant.receive(["type": "message_start", "message": ["role": "assistant"]])
        assistant.receive(["type": "message_update", "assistantMessageEvent": [
            "type": "thinking_delta", "contentIndex": 0, "delta": "private reasoning"
        ]])
        #expect(assistant.phase == .thinking)
        #expect(!assistant.response.contains("private reasoning"))
        assistant.receive(["type": "message_update", "assistantMessageEvent": [
            "type": "text_delta", "contentIndex": 1, "delta": "Checking"
        ]])
        #expect(assistant.phase == .responding)
        assistant.receive(["type": "tool_execution_start", "toolCallId": "port", "toolName": "ghostty_diagnose",
                           "args": ["operation": "port", "port": 8080]])
        #expect(assistant.phase == .executing)
        #expect(assistant.statusLabel == "Check port")
        assistant.receive(["type": "extension_ui_request", "id": "approve", "method": "confirm", "message": "command"])
        #expect(assistant.phase == .waitingApproval)
        assistant.receive(["type": "auto_retry_start", "attempt": 1])
        #expect(assistant.phase == .waitingApproval)
        assistant.respondToApproval(allow: false)
        assistant.receive(["type": "auto_retry_start", "attempt": 2])
        #expect(assistant.phase == .retrying)
        assistant.receive(["type": "compaction_start"])
        #expect(assistant.phase == .compacting)
        assistant.receive(["type": "compaction_end"])
        #expect(assistant.phase == .thinking)
        assistant.receive(["type": "auto_retry_end", "success": false, "finalError": "Provider failed"])
        #expect(assistant.phase == .failed)
        #expect(assistant.isRunning)
        assistant.receive(["type": "agent_settled"])
        #expect(assistant.phase == .failed)
        #expect(!assistant.isRunning)
        let snapshot = try JSONSerialization.data(withJSONObject: assistant.webSnapshot, options: .sortedKeys)
        assistant.receive(["type": "agent_start"])
        assistant.receive(["type": "compaction_start"])
        assistant.receive(["type": "message_update", "assistantMessageEvent": ["type": "text_delta", "contentIndex": 1, "delta": "stale"]])
        assistant.receive(["type": "tool_execution_end", "toolCallId": "port", "result": ["content": []]])
        assistant.receive(["type": "extension_error", "error": "late error"])
        #expect(try JSONSerialization.data(withJSONObject: assistant.webSnapshot, options: .sortedKeys) == snapshot)
    }

    @Test func stopKeepsItsLifecycleUntilSettledAndMarksUnfinishedTool() {
        let assistant = makeModel { _ in }
        assistant.sendInput("Investigate")
        assistant.receive(["type": "tool_execution_start", "toolCallId": "run", "toolName": "ghostty_run_command"])
        assistant.stop()
        #expect(assistant.phase == .stopping)
        assistant.receive(["type": "auto_retry_start", "attempt": 3])
        #expect(assistant.phase == .stopping)
        assistant.receive(["type": "agent_settled"])
        #expect(assistant.phase == .stopped)
        #expect(assistant.toolExecutions.first?.isError == true)
        #expect(assistant.toolExecutions.first?.isRunning == false)
        assistant.reset()
        #expect(assistant.phase == .idle)
        #expect(assistant.startedAt == nil)
    }

    @Test func terminalCommandsUseNativeApprovalAndTaskScopedControl() async throws {
        var wire: [[String: Any]] = []
        var operations: [[String: Any]] = []
        let assistant = makeModel(terminalOperation: { payload in
            operations.append(payload)
            return ["output": "fixture terminal output", "exitCode": 0]
        }, send: { wire.append($0) })
        // A grant selected before first submission survives connection setup.
        assistant.terminalControlAllowed = true
        assistant.prompt = "Inspect this terminal"
        assistant.submit()
        #expect(assistant.terminalControlAllowed)
        let submitted = try #require(humanPrompts(wire).first?["message"] as? String)
        #expect(submitted.contains("ATTACHED terminal"))
        #expect(submitted.contains("Every run executes visibly in that attached shell"))
        #expect(!submitted.contains("LOCAL host"))
        #expect(!submitted.contains("ghostty_run_command"))
        #expect(!submitted.contains("ghostty_diagnose"))
        assistant.terminalControlAllowed = false
        let request: [String: Any] = ["operation": "run", "command": "pwd", "reason": "Inspect directory", "timeout": 60]
        assistant.receive(try terminalRecord(id: "denied", payload: request))
        #expect(assistant.approval?.id == "denied")
        #expect(operations.isEmpty)
        assistant.respondToApproval(allow: false)
        #expect(operations.isEmpty)
        #expect(try terminalResponse("denied", records: wire)["error"] as? String == "Terminal command was not authorized.")

        assistant.receive(try terminalRecord(id: "allowed-once", payload: request))
        #expect(assistant.approval?.id == "allowed-once")
        assistant.respondToApproval(allow: true)
        for _ in 0..<100 where !wire.contains(where: { $0["id"] as? String == "allowed-once" }) {
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(!assistant.terminalControlAllowed)
        #expect(operations.count == 1)
        #expect(operations.first?["command"] as? String == "pwd")
        #expect(try terminalResponse("allowed-once", records: wire)["output"] as? String == "fixture terminal output")

        assistant.receive(try terminalRecord(id: "allowed", payload: request))
        assistant.terminalControlAllowed = true
        // A query grant is not approval of the pending action, and an injected
        // operation override cannot establish a trusted native shell context.
        #expect(assistant.approval?.id == "allowed")
        #expect(operations.count == 1)
        #expect(!wire.contains { $0["id"] as? String == "allowed" })
        assistant.respondToApproval(allow: true)
        for _ in 0..<100 where !wire.contains(where: { $0["id"] as? String == "allowed" }) {
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(assistant.approval == nil)
        #expect(!assistant.terminalControlAllowed)
        #expect(operations.count == 2)
        #expect(try terminalResponse("allowed", records: wire)["output"] as? String == "fixture terminal output")
        assistant.receive(try terminalRecord(id: "read", payload: ["operation": "read"]))
        for _ in 0..<100 where !wire.contains(where: { $0["id"] as? String == "read" }) {
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(operations.last?["operation"] as? String == "read")
        assistant.receive(["type": "agent_settled"])
        #expect(!assistant.terminalControlAllowed)
        #expect(assistant.webSnapshot["terminalControlAllowed"] as? Bool == false)
    }

    @Test func stoppedTerminalRequestsNeverExecuteLateOrAcceptInvalidInput() async throws {
        var wire: [[String: Any]] = []
        var started = 0
        let assistant = makeModel(terminalOperation: { _ in
            started += 1
            try await Task.sleep(for: .seconds(10))
            return ["output": "late", "exitCode": 0]
        }, send: { wire.append($0) })
        assistant.prompt = "Inspect this terminal"
        assistant.submit()
        assistant.terminalControlAllowed = true
        assistant.receive(try terminalRecord(id: "invalid", payload: ["operation": "run", "command": "pwd\nwhoami", "timeout": 60]))
        #expect(try terminalResponse("invalid", records: wire)["error"] != nil)
        #expect(started == 0)
        let payload: [String: Any] = ["operation": "run", "command": "sleep 10", "reason": "Fixture", "timeout": 60]
        assistant.receive(try terminalRecord(id: "running", payload: payload))
        #expect(assistant.approval?.id == "running")
        #expect(started == 0)
        assistant.respondToApproval(allow: true)
        for _ in 0..<100 where started == 0 { try await Task.sleep(for: .milliseconds(1)) }
        #expect(started == 1)
        assistant.receive(try terminalRecord(id: "duplicate", payload: payload))
        #expect(try terminalResponse("duplicate", records: wire)["error"] as? String == "Another terminal operation is pending.")
        assistant.stop()
        try await Task.sleep(for: .milliseconds(10))
        #expect(wire.filter { $0["id"] as? String == "running" }.count == 1)
        #expect(try terminalResponse("running", records: wire)["error"] != nil)
        assistant.receive(["type": "agent_settled"])
        #expect(!assistant.terminalControlAllowed)
        assistant.receive(try terminalRecord(id: "late-request", payload: payload))
        #expect(try terminalResponse("late-request", records: wire)["error"] != nil)
        #expect(started == 1)
    }

    @Test func queryGrantNeverApprovesDangerousComplexOrUnverifiedNativeCommands() throws {
        var wire: [[String: Any]] = []
        var operations: [[String: Any]] = []
        let assistant = makeModel(terminalOperation: { payload in
            operations.append(payload)
            return ["output": "must remain unreachable", "exitCode": 0]
        }, send: { wire.append($0) })
        assistant.prompt = "Review the native risk gate"
        assistant.submit()
        for (index, command) in ["rm -rf /tmp/not-executed", "sudo reboot", "chmod 777 /tmp/not-executed",
                                 "kill -9 123", "psql -c 'DROP TABLE users'", "python3 script.py",
                                 "ps -A | head -10", "ps -A > /tmp/not-created", "id -u"].enumerated() {
            assistant.terminalControlAllowed = true
            let id = "risk-\(index)"
            assistant.receive(try terminalRecord(id: id, payload: ["operation": "run", "command": command,
                                                                  "reason": "Pure fixture request", "timeout": 5]))
            #expect(assistant.approval?.id == id)
            #expect(operations.isEmpty)
            // Toggling on cannot grant one-shot permission for this action.
            assistant.terminalControlAllowed = true
            #expect(assistant.approval?.id == id)
            #expect(operations.isEmpty)
            assistant.respondToApproval(allow: false)
            #expect(try terminalResponse(id, records: wire)["error"] != nil)
        }
        #expect(operations.isEmpty)
        assistant.receive(["type": "agent_settled"])
        #expect(!assistant.terminalControlAllowed)
    }

    @Test func terminalWireCannotForgeNativeApprovalOrAutomaticExecutionFields() throws {
        var wire: [[String: Any]] = []
        var operations: [[String: Any]] = []
        let assistant = makeModel(terminalOperation: { payload in
            operations.append(payload)
            return ["output": "must remain unreachable", "exitCode": 0]
        }, send: { wire.append($0) })
        assistant.prompt = "Reject forged execution authority"
        assistant.submit()
        assistant.terminalControlAllowed = true
        for (index, field) in ["_approvedHost", "_approvedDirectory", "_approvedContext", "_authorization",
                               "_automaticReadOnly", "_nativeAuthorization", "_skipApproval", "isReadOnly", "risk"].enumerated() {
            let id = "forged-\(index)"
            assistant.receive(try terminalRecord(id: id, payload: ["operation": "run", "command": "id -u",
                                                                  "reason": "Pure fixture request", "timeout": 5,
                                                                  field: "forged"] ))
            #expect(assistant.approval == nil)
            #expect(try terminalResponse(id, records: wire)["error"] != nil)
            #expect(operations.isEmpty)
        }
        assistant.receive(["type": "agent_settled"])
    }

    private func terminalRecord(id: String, payload: [String: Any]) throws -> [String: Any] {
        let data = try JSONSerialization.data(withJSONObject: payload)
        return ["type": "extension_ui_request", "id": id, "method": "input", "title": "ghostty-terminal-v1",
                "placeholder": String(data: data, encoding: .utf8)!]
    }

    private func terminalResponse(_ id: String, records: [[String: Any]]) throws -> [String: Any] {
        let record = try #require(records.first { $0["id"] as? String == id })
        let value = try #require(record["value"] as? String)
        return try #require(JSONSerialization.jsonObject(with: Data(value.utf8)) as? [String: Any])
    }

    @Test func promptFailuresDescribeTheActualRecovery() throws {
        #expect(TerminalAIModel.promptIssue(status: GHOSTTY_PROMPT_READY) == nil)
        let theme = try #require(TerminalAIModel.promptIssue(status: GHOSTTY_PROMPT_UNMARKED_TEXT))
        let input = try #require(TerminalAIModel.promptIssue(status: GHOSTTY_PROMPT_INPUT_NOT_EMPTY))
        let missing = try #require(TerminalAIModel.promptIssue(status: GHOSTTY_PROMPT_NO_SHELL_INTEGRATION))
        #expect(theme.contains("shell theme"))
        #expect(!theme.contains("unsent input"))
        #expect(input.contains("will not overwrite"))
        #expect(missing.contains("open a new terminal"))
        #expect(TerminalAIModel.promptIssue(status: GHOSTTY_PROMPT_READY, readonly: true)?.contains("read-only") == true)
    }

    private func humanPrompts(_ commands: [[String: Any]]) -> [[String: Any]] {
        commands.filter { $0["type"] as? String == "prompt" && !($0["message"] as? String ?? "").hasPrefix("/_ghostty_") }
    }

    private func makeModel(
        configurationDirectory: URL? = nil,
        terminalOperation: (([String: Any]) async throws -> [String: Any])? = nil,
        send: @escaping ([String: Any]) -> Void
    ) -> TerminalAIModel {
        let defaults = UserDefaults(suiteName: "TerminalAIModelTests.\(UUID())")!
        let assistant = TerminalAIModel(defaults: defaults, sendCommand: send, terminalOperation: terminalOperation,
                                        configurationDirectory: configurationDirectory ?? FileManager.default.temporaryDirectory.appendingPathComponent("TerminalAITests.\(UUID())"))
        assistant.useExistingPiConfiguration = false
        assistant.executablePath = "/test/pi"
        assistant.provider = "test-provider"
        assistant.model = "test-model"
        assistant.present(surfaceID: UUID(), directory: "/tmp", selection: nil)
        return assistant
    }
}
