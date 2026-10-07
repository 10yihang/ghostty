import Foundation
import GhosttyKit
import Testing
@testable import Ghostty

@MainActor
struct TerminalAIHistoryModelTests {
    @Test func anotherModelLoadsHistoryWithoutSendingOrChangingTerminalBinding() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let original = fixture.makeModel()
        original.prompt = "Remember this diagnosis"
        original.submit()
        fixture.complete(original, text: "The first answer")
        let id = original.conversationID
        try fixture.writePiContext(id)
        #expect(original.reset())

        let currentSurface = UUID()
        let restored = fixture.makeModel(surfaceID: currentSurface)
        fixture.commands = []
        restored.refreshHistory()
        #expect(restored.history.contains { $0.id == id && $0.title == "Remember this diagnosis" })
        #expect(restored.openConversation(id))
        #expect(restored.surfaceID == currentSurface)
        #expect(restored.conversationID == id)
        #expect(restored.response.contains("The first answer"))
        #expect(!restored.isRunning)
        #expect(fixture.commands.isEmpty)
        restored.prompt = "Continue"
        restored.submit()
        #expect(restored.conversationID == id)
        #expect(restored.response.contains("Remember this diagnosis"))
        #expect(fixture.commands.contains { $0["type"] as? String == "prompt" })
        fixture.complete(restored)
        #expect(restored.reset())
    }

    @Test func interruptedHistoryFinalizesToolsAndDoesNotRestoreLiveAuthorization() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let id = UUID()
        try fixture.store.save(.init(entry: fixture.entry(id, count: 2), messages: [
            ["id": "question", "role": "user", "content": [["type": "text", "text": "Investigate"]]],
            ["id": "answer", "role": "assistant", "content": [[
                "type": "tool-call", "toolCallId": "pending", "toolName": "ghostty_terminal",
                "args": ["operation": "run", "command": "fixture only"],
                "result": ["text": "partial", "detail": "fixture only", "label": "Use current terminal",
                           "isRunning": true, "isError": false]
            ]]]
        ], phase: "waiting_approval"))
        let restored = fixture.makeModel()
        restored.terminalControlAllowed = true
        restored.context = "Old selection"
        restored.receive(["type": "extension_ui_request", "id": "old-approval", "method": "confirm"])
        fixture.commands = []
        #expect(restored.openConversation(id))
        #expect(restored.phase == .stopped)
        #expect(restored.statusLabel == "Interrupted")
        #expect(restored.approval == nil)
        #expect(!restored.terminalControlAllowed)
        #expect(restored.context.isEmpty)
        #expect((restored.webSnapshot["queuedInputs"] as? [[String: Any]])?.isEmpty == true)
        let tool = try #require(restored.toolExecutions.first)
        #expect(!tool.isRunning)
        #expect(tool.isError)
        #expect(tool.output.contains("Interrupted"))
        #expect(!fixture.commands.contains { $0["type"] as? String == "prompt" })
        #expect(!fixture.commands.contains { $0["confirmed"] as? Bool == true })
    }

    @Test func runningTaskCannotSwitchConversation() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let targetID = UUID()
        try fixture.store.save(.init(entry: fixture.entry(targetID, count: 1), messages: [
            ["id": "older", "role": "user", "content": [["type": "text", "text": "Older task"]]]
        ], phase: "completed"))
        let active = fixture.makeModel()
        active.prompt = "Current task"
        active.submit()
        let id = active.conversationID
        let before = active.response
        #expect(!active.openConversation(targetID))
        #expect(active.conversationID == id)
        #expect(active.response == before)
        #expect(active.isRunning)
        #expect(active.historyError?.contains("Stop") == true)
        fixture.complete(active)
        #expect(active.reset())
    }

    @Test func missingOrCorruptPiContextCannotSubmitFromReadableHistory() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let original = fixture.makeModel()
        original.prompt = "Saved readable task"
        original.submit()
        fixture.complete(original)
        let id = original.conversationID
        #expect(original.reset())
        let payloads: [Data?] = [nil, Data("not json\n".utf8), Data("{\"type\":\"session\",\"cwd\":\"/tmp\"}\n".utf8)]
        for payload in payloads {
            let url = fixture.store.sessionURL(id: id)
            try? FileManager.default.removeItem(at: url)
            if let payload { try payload.write(to: url) }
            let restored = fixture.makeModel()
            #expect(restored.openConversation(id))
            let before = restored.response
            fixture.commands = []
            restored.prompt = "Do not lose this draft"
            restored.submit()
            #expect(!restored.isRunning)
            #expect(restored.conversationID == id)
            #expect(restored.response == before)
            #expect(restored.prompt == "Do not lose this draft")
            #expect(restored.error?.contains("saved Pi context") == true)
            #expect(fixture.commands.isEmpty)
        }
    }

    @Test func busyWriterBlocksContinuationThenReloadsLatestTranscriptOnRelease() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let owner = fixture.makeModel()
        owner.prompt = "First task"
        owner.submit()
        fixture.complete(owner, text: "First result")
        let id = owner.conversationID
        try fixture.writePiContext(id)
        let reader = fixture.makeModel()
        #expect(reader.openConversation(id))
        fixture.commands = []
        reader.prompt = "Reader continuation"
        reader.submit()
        #expect(!reader.isRunning)
        #expect(reader.error?.contains("another AI panel") == true)
        #expect(fixture.commands.isEmpty)

        owner.prompt = "Owner follow up"
        owner.submit()
        fixture.complete(owner, text: "Latest owner result")
        #expect(owner.reset())
        #expect(!reader.response.contains("Latest owner result"))
        reader.submit()
        #expect(reader.isRunning)
        #expect(reader.response.contains("Latest owner result"))
        #expect(reader.response.contains("Reader continuation"))
        fixture.complete(reader)
        #expect(reader.reset())
    }

    @Test func saveFailurePreservesConversationAndBlocksResetAndOpeningAnother() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let target = UUID()
        try fixture.store.save(.init(entry: fixture.entry(target, count: 1), messages: [
            ["id": "target", "role": "user", "content": [["type": "text", "text": "Another task"]]]
        ], phase: "completed"))
        let active = fixture.makeModel()
        active.prompt = "Keep this transcript"
        active.submit()
        fixture.complete(active, text: "Keep this answer")
        let id = active.conversationID
        let before = active.response
        let destination = fixture.store.sessionURL(id: id).deletingLastPathComponent().appendingPathComponent("conversation.json")
        try FileManager.default.removeItem(at: destination)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        #expect(!active.reset())
        #expect(active.conversationID == id)
        #expect(active.response == before)
        #expect(active.historyError?.contains("save") == true)
        #expect(!active.openConversation(target))
        #expect(active.conversationID == id)
        #expect(active.response == before)
        try FileManager.default.removeItem(at: destination)
        #expect(active.reset())
        #expect(active.conversationID != id)
        #expect(active.response.isEmpty)
        #expect(try fixture.store.read(id: id).messages.count == 2)
    }

    @MainActor
    private final class Fixture {
        let directory: URL
        let defaults: UserDefaults
        let suite = "TerminalAIHistoryModelTests.\(UUID())"
        var commands: [[String: Any]] = []
        var store: TerminalAIHistoryStore { .init(directory: directory.appendingPathComponent("conversations")) }

        init() throws {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent("TerminalAIHistoryModelTests.\(UUID())")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defaults = try #require(UserDefaults(suiteName: suite))
            defaults.set(true, forKey: "terminalAI.useExistingPiConfiguration")
            defaults.set(directory.path, forKey: "terminalAI.piConfigurationDirectory")
            defaults.set("/test/pi", forKey: "terminalAI.executablePath")
        }

        func makeModel(surfaceID: UUID = UUID()) -> TerminalAIModel {
            let model = TerminalAIModel(defaults: defaults, sendCommand: { [self] in commands.append($0) },
                                        configurationDirectory: directory)
            model.present(surfaceID: surfaceID, directory: "/tmp", selection: nil)
            return model
        }

        func complete(_ model: TerminalAIModel, text: String = "Fixture answer") {
            model.receive(["type": "message_start", "message": ["role": "assistant"]])
            model.receive(["type": "message_end", "message": ["role": "assistant", "content": [["type": "text", "text": text]]]])
            model.receive(["type": "agent_settled"])
        }

        func entry(_ id: UUID, count: Int) -> TerminalAIHistoryStore.Entry {
            .init(id: id, title: "Fixture history", updatedAt: Date(), sourceDirectory: "/tmp",
                  workingDirectory: "/tmp", model: "fixture/model", messageCount: count)
        }

        func writePiContext(_ id: UUID) throws {
            let records: [[String: Any]] = [
                ["type": "session", "cwd": "/tmp"],
                ["type": "message", "message": ["role": "user", "content": "Fixture saved context"]]
            ]
            let lines = try records.map { try JSONSerialization.data(withJSONObject: $0) }
            var data = Data()
            for line in lines { data.append(line); data.append(0x0A) }
            try data.write(to: store.sessionURL(id: id))
        }

        func cleanUp() {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
    }
}
