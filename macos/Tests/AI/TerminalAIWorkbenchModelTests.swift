import Foundation
import Testing
@testable import Ghostty

@MainActor
struct TerminalAIWorkbenchModelTests {
    @Test func commandModeExposesOnlyProposalsAndNativeExecutionBridgesRejectIt() throws {
        let fixture = try WorkbenchModelFixture(mode: .command)
        defer { fixture.remove() }
        let configuration = try fixture.model.prepareConnectionConfiguration()
        let index = try #require(configuration.arguments.firstIndex(of: "--tools"))
        #expect(configuration.arguments[index + 1] == "ghostty_propose_command")
        #expect(configuration.environment["GHOSTTY_AI_MODE"] == "command")
        fixture.begin("Write a command")
        #expect(fixture.model.taskPlan == nil)
        for (title, id) in [("ghostty-terminal-v1", "terminal"), ("ghostty-mcp-v1", "mcp"), ("ghostty-context-v1", "context")] {
            try fixture.request(title: title, id: id, payload: ["operation": "run", "command": "touch forbidden", "reason": "fixture"])
            #expect(try fixture.response(id)["error"] is String)
        }
        #expect(fixture.model.approval == nil)
        #expect(!FileManager.default.fileExists(atPath: fixture.directory.appendingPathComponent("forbidden").path))
        #expect((fixture.recording.commands.first { $0["type"] as? String == "prompt" }?["message"] as? String)?.contains("do not execute anything") == true)
    }

    @Test func explicitFilesAndProjectContextReachOnlyTheAttachmentBridge() throws {
        let fixture = try WorkbenchModelFixture()
        defer { fixture.remove() }
        let file = fixture.directory.appendingPathComponent("diagnostic.txt")
        try "explicit fixture context 中文".write(to: file, atomically: true, encoding: .utf8)
        fixture.model.attachContext(kind: "file", path: file.path)
        #expect(fixture.model.attachments.count == 1)
        #expect(fixture.recording.commands.isEmpty)
        let project = fixture.directory.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try "project instructions fixture".write(to: project.appendingPathComponent("AGENTS.md"), atomically: true, encoding: .utf8)
        try "project readme fixture".write(to: project.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        fixture.model.attachContext(kind: "project", path: project.path)
        #expect(fixture.model.attachments.count == 3)
        fixture.begin("Inspect these attachments")
        let sentPrompt = try #require(fixture.recording.commands.first { $0["type"] as? String == "prompt" }?["message"] as? String)
        for attachment in fixture.model.attachments {
            #expect(sentPrompt.contains("<attachment id=\"\(attachment.id)\">"))
            #expect(sentPrompt.contains("Source: \(attachment.source)"))
            #expect(sentPrompt.contains("Reported host: \(attachment.host)"))
            #expect(sentPrompt.contains(attachment.text))
        }
        #expect(sentPrompt.contains("explicit fixture context 中文"))
        #expect(sentPrompt.contains("project instructions fixture"))
        #expect(sentPrompt.contains("project readme fixture"))
        try fixture.request(title: "ghostty-context-v1", id: "list", payload: ["operation": "list"])
        #expect((try fixture.response("list")["attachments"] as? [[String: Any]])?.count == 3)
        let attached = try #require(fixture.model.attachments.first { $0.source == file.path })
        try fixture.request(title: "ghostty-context-v1", id: "read", payload: ["operation": "read", "attachmentId": attached.id])
        #expect(try fixture.response("read")["output"] as? String == "explicit fixture context 中文")
        try fixture.request(title: "ghostty-context-v1", id: "unattached", payload: ["operation": "read", "attachmentId": "/etc/passwd"])
        #expect((try fixture.response("unattached")["error"] as? String)?.contains("explicitly attached") == true)
        #expect(fixture.model.approval == nil)
    }

    @Test func aggregateContextLimitKeepsTheErrorAndPreviouslyAttachedItems() throws {
        let fixture = try WorkbenchModelFixture()
        defer { fixture.remove() }
        for index in 0..<5 {
            let file = fixture.directory.appendingPathComponent("large-\(index).txt")
            try String(repeating: "x", count: 65_536).write(to: file, atomically: true, encoding: .utf8)
            fixture.model.attachContext(kind: "file", path: file.path)
        }
        #expect(fixture.model.attachments.count == 4)
        #expect(fixture.model.error?.contains("256 KiB") == true)
        #expect(fixture.model.attachments.reduce(0) { $0 + $1.text.utf8.count } == 262_144)
        #expect(fixture.recording.commands.isEmpty)
    }

    @Test func workflowSaveAcknowledgementsMatchRequestsAndExpansionOnlyCreatesADraft() throws {
        let fixture = try WorkbenchModelFixture()
        defer { fixture.remove() }
        fixture.model.saveWorkflow(["requestID": "save-good", "name": "Check port", "prompt": "Check port {{port}}",
                                    "parameters": [["name": "port", "defaultValue": "8080"]]])
        #expect(fixture.model.workflowSaveResult?["requestID"] as? String == "save-good")
        #expect(fixture.model.workflowSaveResult?["success"] as? Bool == true)
        let id = try #require(fixture.model.workflowSaveResult?["workflowID"] as? String)
        fixture.model.useWorkflow(id, values: ["port": "9000"])
        #expect(fixture.model.prompt == "Check port 9000")
        #expect(!fixture.model.isRunning)
        #expect(fixture.recording.commands.isEmpty)
        fixture.model.saveWorkflow(["requestID": "save-invalid", "name": "", "prompt": "broken", "parameters": []])
        #expect(fixture.model.workflowSaveResult?["requestID"] as? String == "save-invalid")
        #expect(fixture.model.workflowSaveResult?["success"] as? Bool == false)
        #expect(fixture.model.workflows.count == 1)
        fixture.begin("Investigate")
        fixture.model.saveWorkflow(["requestID": "save-busy", "name": "Busy", "prompt": "busy", "parameters": []])
        #expect(fixture.model.workflowSaveResult?["requestID"] as? String == "save-busy")
        #expect(fixture.model.workflowSaveResult?["success"] as? Bool == false)
        #expect(fixture.model.workflows.count == 1)
    }

    @Test func nativePlanBridgeUpdatesStepsAndRejectsInventedVerificationEvidence() throws {
        let fixture = try WorkbenchModelFixture()
        defer { fixture.remove() }
        fixture.begin("Investigate fixture failure")
        try fixture.request(title: "ghostty-task-plan-v1", id: "plan", payload: [
            "operation": "set_plan", "title": "Inspect fixture", "steps": [["id": "inspect", "title": "Read evidence"]]
        ])
        #expect(fixture.model.taskPlan?.steps.map(\.id) == ["inspect"])
        try fixture.request(title: "ghostty-task-plan-v1", id: "running", payload: [
            "operation": "update_step", "stepId": "inspect", "status": "running", "evidence": "Reading fixture output"
        ])
        #expect(fixture.model.taskPlan?.steps.first?.status == "running")
        try fixture.request(title: "ghostty-task-plan-v1", id: "done", payload: [
            "operation": "update_step", "stepId": "inspect", "status": "completed", "evidence": "Observed fixture output"
        ])
        #expect(fixture.model.taskPlan?.steps.first?.evidence == "Observed fixture output")
        try fixture.request(title: "ghostty-task-plan-v1", id: "fabricated", payload: [
            "operation": "verify", "status": "passed", "commandIds": ["invented-command"], "summary": "Pretend repaired"
        ])
        #expect((try fixture.response("fabricated")["error"] as? String)?.contains("completed commands") == true)
        #expect(fixture.model.taskPlan?.verification.status == "pending")
        fixture.model.receive(["type": "agent_settled"])
        #expect(fixture.model.taskPlan?.verification.status == "unverified")
    }

    @Test func mcpRequiresItsOwnApprovalThenActuallyInvokesConfiguredStdioTools() async throws {
        let fixture = try WorkbenchModelFixture()
        defer { fixture.remove() }
        let server = try fixture.installMCP()
        fixture.begin("Read fixture external evidence")
        fixture.model.terminalControlAllowed = true
        let payload: [String: Any] = ["operation": "call_tool", "server": server.id.uuidString,
                                      "toolName": "lookup", "arguments": [:], "reason": "Inspect fixture evidence"]
        try fixture.request(title: "ghostty-mcp-v1", id: "deny", payload: payload)
        #expect(fixture.model.approval?.id == "deny")
        #expect(fixture.model.approval?.message.contains(server.name) == true)
        #expect(!FileManager.default.fileExists(atPath: fixture.mcpLog.path))
        fixture.model.respondToApproval(allow: false)
        #expect((try fixture.response("deny")["error"] as? String)?.contains("not authorized") == true)
        #expect(!FileManager.default.fileExists(atPath: fixture.mcpLog.path))
        try fixture.request(title: "ghostty-mcp-v1", id: "allow", payload: payload)
        #expect(fixture.model.approval?.id == "allow")
        fixture.model.respondToApproval(allow: true)
        try await fixture.wait { fixture.recording.hasResponse("allow") }
        #expect(try fixture.response("allow")["isError"] as? Bool == false)
        #expect((try fixture.response("allow")["output"] as? String)?.contains("fixture external evidence") == true)
        #expect(try fixture.mcpRecords().filter { $0["method"] as? String == "tools/call" }.count == 1)
    }

    @Test func stoppingMCPRejectsLateResultsAndNewConversationCancelsResourceAttachment() async throws {
        let fixture = try WorkbenchModelFixture()
        defer { fixture.remove() }
        let server = try fixture.installMCP()
        fixture.begin("Inspect delayed fixture")
        try fixture.request(title: "ghostty-mcp-v1", id: "slow", payload: [
            "operation": "call_tool", "server": server.id.uuidString, "toolName": "lookup",
            "arguments": ["delay": true], "reason": "Exercise cancellation"
        ])
        fixture.model.respondToApproval(allow: true)
        try await fixture.wait { (try? fixture.mcpRecords().contains { $0["method"] as? String == "tools/call" }) == true }
        fixture.model.stop()
        #expect((try fixture.response("slow")["error"] as? String)?.contains("Stopped") == true)
        fixture.model.receive(["type": "agent_settled"])
        #expect(fixture.model.reset())
        fixture.model.attachMCPResource(serverID: server.id, uri: "fixture://slow", title: "Delayed resource")
        #expect(fixture.model.contextLoading)
        #expect(!fixture.model.canSubmit)
        try await fixture.wait { (try? fixture.mcpRecords().contains { $0["method"] as? String == "resources/read" }) == true }
        let previous = fixture.model.conversationID
        #expect(fixture.model.reset())
        #expect(fixture.model.conversationID != previous)
        #expect(!fixture.model.contextLoading)
        try await Task.sleep(for: .milliseconds(450))
        #expect(fixture.model.attachments.isEmpty)
        #expect(!fixture.model.isRunning)
        #expect(fixture.recording.commands.filter { $0["id"] as? String == "slow" }.count == 1)
    }

    @Test func switchingTerminalsDiscardsACommandGeneratorProposal() async throws {
        let fixture = try WorkbenchModelFixture(useOverride: false)
        defer { fixture.remove() }
        let script = fixture.directory.appendingPathComponent("fake-pi.py")
        try Self.piSource.write(to: script, atomically: true, encoding: .utf8)
        fixture.model.executablePath = script.path
        fixture.model.nodePath = "/usr/bin/python3"
        fixture.model.commandEntryPresented = true
        fixture.model.commandRequestDraft = "Write fixture command"
        fixture.model.generateCommand()
        try await fixture.wait(description: "Receive generator proposal") { fixture.model.commandEntryCommand == "echo old-target" }
        let original = fixture.model.surfaceID
        fixture.model.present(surfaceID: UUID(), directory: fixture.directory.path, selection: nil)
        #expect(fixture.model.surfaceID != original)
        try await Task.sleep(for: .milliseconds(650))
        #expect(fixture.model.commandEntryCommand.isEmpty)
        #expect(!fixture.model.commandEntryBusy)
        #expect(!fixture.model.isRunning)
    }

    @Test func canceledResourceLoadCannotClearOrReplaceTheSameConversationsNextLoad() async throws {
        let fixture = try WorkbenchModelFixture()
        defer { fixture.remove() }
        let server = try fixture.installMCP()
        fixture.model.attachMCPResource(serverID: server.id, uri: "fixture://first", title: "First conversation")
        try await fixture.wait { (try? fixture.mcpRecords().contains {
            $0["method"] as? String == "resources/read" && ($0["params"] as? [String: Any])?["uri"] as? String == "fixture://first"
        }) == true }
        let conversation = fixture.model.conversationID
        fixture.model.stop()
        #expect(fixture.model.conversationID == conversation)
        #expect(!fixture.model.contextLoading)
        fixture.model.attachMCPResource(serverID: server.id, uri: "fixture://second", title: "Second conversation")
        #expect(fixture.model.contextLoading)
        try await fixture.wait { (try? fixture.mcpRecords().contains {
            $0["method"] as? String == "resources/read" && ($0["params"] as? [String: Any])?["uri"] as? String == "fixture://second"
        }) == true }
        #expect(fixture.model.contextLoading)
        try Data().write(to: fixture.directory.appendingPathComponent("mcp-records.jsonl.release"))
        try await fixture.wait { !fixture.model.contextLoading }
        #expect(fixture.model.attachments.count == 1)
        #expect(fixture.model.attachments.first?.source == "fixture://second")
        #expect(fixture.model.attachments.first?.name == "Second conversation")
        #expect(fixture.model.conversationID == conversation)
        #expect(!fixture.model.isRunning)
    }

    private static let piSource = #"""
    import json, sys, time
    def send(value):
        with open(__file__ + '.events', 'a') as file: file.write('OUT ' + json.dumps(value) + '\n')
        print(json.dumps(value), flush=True)
    send({'type':'extension_ui_request','id':'ready','method':'setStatus','statusKey':'ghostty-policy','statusText':'ready'})
    for line in sys.stdin:
        message = json.loads(line)
        with open(__file__ + '.events', 'a') as file: file.write('IN ' + json.dumps(message) + '\n')
        if message.get('type') == 'get_state':
            send({'type':'response','id':message['id'],'success':True,'data':{'model':{'provider':'fixture','id':'fixture'}}})
        elif message.get('type') == 'prompt':
            send({'type':'response','id':message['id'],'success':True})
            send({'type':'tool_execution_start','toolCallId':'proposal','toolName':'ghostty_propose_command'})
            send({'type':'tool_execution_end','toolCallId':'proposal','isError':False,'result':{'content':[{'type':'text','text':'fixture command'}],'details':{'command':'echo old-target','explanation':'Old target fixture'}}})
            time.sleep(0.5)
            send({'type':'agent_settled'})
        elif message.get('type') == 'abort': send({'type':'agent_settled'})
    """#
}

@MainActor
private final class WorkbenchModelRecording {
    var commands: [[String: Any]] = []
    func hasResponse(_ id: String) -> Bool { commands.contains { $0["type"] as? String == "extension_ui_response" && $0["id"] as? String == id } }
}

@MainActor
private final class WorkbenchModelFixture {
    let directory: URL
    let mcpLog: URL
    let model: TerminalAIModel
    let recording = WorkbenchModelRecording()
    private let suite: String
    private let defaults: UserDefaults

    init(mode: TerminalAIModel.Mode = .assistant, useOverride: Bool = true) throws {
        suite = "TerminalAIWorkbenchModelTests.\(UUID().uuidString)"
        defaults = try #require(UserDefaults(suiteName: suite))
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        mcpLog = directory.appendingPathComponent("mcp-records.jsonl")
        defaults.set("/test/pi", forKey: "terminalAI.executablePath")
        defaults.set("", forKey: "terminalAI.nodePath")
        defaults.set(false, forKey: "terminalAI.useExistingPiConfiguration")
        defaults.set("fixture-\(UUID())", forKey: "terminalAI.provider")
        defaults.set("fixture-model", forKey: "terminalAI.model")
        let recorder = recording
        model = TerminalAIModel(defaults: defaults, sendCommand: useOverride ? { recorder.commands.append($0) } : nil,
                                configurationDirectory: directory.appendingPathComponent("configuration"), mode: mode)
        model.present(surfaceID: UUID(), directory: directory.path, selection: nil)
    }

    func begin(_ prompt: String) { model.prompt = prompt; model.submit() }

    func request(title: String, id: String, payload: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: payload)
        model.receive(["type": "extension_ui_request", "method": "input", "title": title, "id": id,
                       "placeholder": try #require(String(data: data, encoding: .utf8))])
    }

    func response(_ id: String) throws -> [String: Any] {
        let record = try #require(recording.commands.last { $0["id"] as? String == id && $0["type"] as? String == "extension_ui_response" })
        let text = try #require(record["value"] as? String)
        return try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }

    func wait(description: String = "Await native fixture", _ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        let trace = (try? String(contentsOf: directory.appendingPathComponent("fake-pi.py.events"), encoding: .utf8)) ?? "No fake Pi protocol trace."
        throw NSError(domain: "TerminalAIWorkbenchModelTests", code: 1, userInfo: [NSLocalizedDescriptionKey:
            "\(description) timed out. Status: \(model.statusLabel); generator busy: \(model.commandEntryBusy); generator error: \(model.commandEntryError ?? "none"); model error: \(model.error ?? "none"). \(trace)"])
    }

    func installMCP() throws -> TerminalAIMCPServer {
        let script = directory.appendingPathComponent("mcp.py")
        try Self.mcpSource.write(to: script, atomically: true, encoding: .utf8)
        var server = TerminalAIMCPServer()
        server.name = "Isolated native bridge fixture"
        server.executable = "/usr/bin/python3"
        server.arguments = [script.path, mcpLog.path]
        server.workingDirectory = directory.path
        try model.mcpManager.save(server)
        return server
    }

    func mcpRecords() throws -> [[String: Any]] {
        try String(contentsOf: mcpLog, encoding: .utf8).split(separator: "\n").map {
            try #require(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
        }
    }

    func remove() {
        model.stop()
        _ = model.reset()
        model.mcpManager.close()
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory)
    }

    private static let mcpSource = #"""
    import json, sys, time, os
    for line in sys.stdin:
        message = json.loads(line)
        with open(sys.argv[1], 'a') as file: file.write(json.dumps(message) + '\n')
        if 'id' not in message: continue
        method = message.get('method')
        if method == 'initialize': result = {'protocolVersion':'2025-11-25','serverInfo':{'name':'fixture','version':'1'},'capabilities':{'tools':{},'resources':{}}}
        elif method == 'tools/list': result = {'tools':[{'name':'lookup','inputSchema':{'type':'object'}}]}
        elif method == 'resources/list': result = {'resources':[{'name':'Slow fixture','uri':'fixture://slow'}]}
        elif method == 'tools/call':
            if message.get('params',{}).get('arguments',{}).get('delay'): time.sleep(0.35)
            result = {'content':[{'type':'text','text':'fixture external evidence'}],'isError':False}
        elif method == 'resources/read':
            if message.get('params',{}).get('uri') == 'fixture://second':
                deadline = time.monotonic() + 10
                while not os.path.exists(sys.argv[1] + '.release') and time.monotonic() < deadline: time.sleep(0.01)
            else: time.sleep(0.35)
            result = {'contents':[{'uri':message.get('params',{}).get('uri'),'text':'late resource evidence'}]}
        else: result = {}
        print(json.dumps({'jsonrpc':'2.0','id':message['id'],'result':result}), flush=True)
    """#
}
