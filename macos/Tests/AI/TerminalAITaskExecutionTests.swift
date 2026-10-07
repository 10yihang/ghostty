import Foundation
import GhosttyKit
import Testing
@testable import Ghostty

/// Verification crosses the real native terminal bridge and saved conversation
/// boundary. The shell, startup files and fake Pi transport are fixture owned.
@Suite(.serialized)
@MainActor
struct TerminalAITaskExecutionTests {
    @Test func actualApprovedCommandCanVerifyTheTaskAndItsSavedWorkbench() async throws {
        let fixture = try TerminalFixture()
        do {
            try await fixture.wait("The isolated shell did not reach its integrated prompt", timeout: 10) {
                ghostty_surface_prompt_state(fixture.surface)
            }
            // Keep only the value identity so teardown can release the native
            // view before freeing its fixture-owned C app.
            let surfaceID = try #require(fixture.view?.id)
            fixture.assistant.present(surfaceID: surfaceID, directory: "/tmp", selection: nil)
            fixture.assistant.bindTerminal(try #require(fixture.view))
            fixture.assistant.prompt = "Inspect the fixture and verify the actual terminal result"
            fixture.assistant.submit()
            try #require(fixture.assistant.isRunning)
            let task = try #require(fixture.assistant.taskPlan)
            #expect(task.surfaceID == surfaceID)

            let plan = try await planRequest([
                "operation": "set_plan", "title": "Verify the isolated shell",
                "steps": [["id": "inspect", "title": "Inspect the shell"],
                          ["id": "verify", "title": "Run and check the result"]]
            ], fixture: fixture)
            #expect(plan["error"] == nil)
            let inspect = try await planRequest([
                "operation": "update_step", "stepId": "inspect", "status": "completed",
                "evidence": "The bound fixture has an integrated empty shell prompt."
            ], fixture: fixture)
            #expect(inspect["error"] == nil)
            let checking = try await planRequest([
                "operation": "update_step", "stepId": "verify", "status": "running",
                "evidence": "Waiting for the command to finish in the attached terminal."
            ], fixture: fixture)
            #expect(checking["error"] == nil)

            let command = "printf 'actual-task-verification-only\\n'"
            let baseline = ghostty_surface_command_state(fixture.surface)
            let requestID = try fixture.beginRequest(["operation": "run", "command": command, "timeout": 5])
            try #require(fixture.assistant.approval?.id == requestID)
            #expect(ghostty_surface_command_state(fixture.surface).started == baseline.started)
            fixture.assistant.respondToApproval(allow: true)
            let result = try await fixture.result(for: requestID)
            #expect(result["exitCode"] as? Int == 0)
            #expect((result["output"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) == "actual-task-verification-only")
            let commandID = try #require(result["commandId"] as? String)
            let record = try #require(fixture.assistant.commands.first { $0.id == commandID })
            #expect(record.surfaceID == surfaceID)
            #expect(record.startedAt >= task.startedAt)
            #expect(record.command == command)
            #expect(record.output == "actual-task-verification-only")
            #expect(record.exitCode == 0)
            #expect(!record.running)
            #expect(!record.interrupted)
            #expect(ghostty_surface_command_state(fixture.surface).finished == baseline.started + 1)

            let fabricated = try await planRequest([
                "operation": "verify", "status": "passed", "commandIds": ["fabricated-command-id"],
                "summary": "A fabricated result must not verify this task."
            ], fixture: fixture)
            #expect((fabricated["error"] as? String)?.contains("completed commands") == true)
            #expect(fixture.assistant.taskPlan?.verification.status == "pending")
            let completed = try await planRequest([
                "operation": "update_step", "stepId": "verify", "status": "completed",
                "evidence": "The real command returned its expected output and exit code 0."
            ], fixture: fixture)
            #expect(completed["error"] == nil)
            let verified = try await planRequest([
                "operation": "verify", "status": "passed", "commandIds": [commandID],
                "summary": "The attached shell produced the expected output and exited successfully."
            ], fixture: fixture)
            #expect(verified["error"] == nil)
            #expect(fixture.assistant.taskPlan?.verification.status == "passed")
            #expect(fixture.assistant.taskPlan?.verification.evidence.contains(commandID) == true)
            #expect(fixture.assistant.taskPlan?.verification.evidence.contains("actual-task-verification-only") == true)
            #expect(fixture.assistant.taskPlan?.verification.evidence.contains("Exit: 0") == true)
            #expect(fixture.assistant.taskPlan?.verification.evidence.contains("fabricated-command-id") == false)

            fixture.assistant.receive(["type": "agent_settled"])
            #expect(!fixture.assistant.isRunning)
            #expect(fixture.assistant.phase == .completed)
            #expect(fixture.assistant.taskPlan?.verification.status == "passed")
            #expect(fixture.assistant.taskPlan?.steps.allSatisfy { $0.status == "completed" } == true)
            let store = TerminalAIHistoryStore(directory: fixture.assistant.configurationDirectory.appendingPathComponent("conversations"))
            let saved = try store.read(id: fixture.assistant.conversationID)
            #expect(saved.phase == "completed")
            let workbenchJSON = try #require(saved.workbench)
            let workbench = try JSONDecoder().decode(TerminalAISavedWorkbench.self,
                from: JSONSerialization.data(withJSONObject: workbenchJSON))
            #expect(workbench.task?.id == task.id)
            #expect(workbench.task?.verification.status == "passed")
            #expect(workbench.task?.verification.evidence == fixture.assistant.taskPlan?.verification.evidence)
            #expect(workbench.task?.steps.allSatisfy { $0.status == "completed" } == true)
            #expect(!fixture.assistant.terminalControlAllowed)
            await fixture.close()
        } catch {
            await fixture.close()
            throw error
        }
    }

    private func planRequest(_ payload: [String: Any], fixture: TerminalFixture) async throws -> [String: Any] {
        let id = UUID().uuidString
        let data = try JSONSerialization.data(withJSONObject: payload)
        let wire = try #require(String(data: data, encoding: .utf8))
        fixture.assistant.receive(["type": "extension_ui_request", "id": id, "method": "input",
                                   "title": "ghostty-task-plan-v1", "placeholder": wire])
        return try await fixture.result(for: id)
    }
}
