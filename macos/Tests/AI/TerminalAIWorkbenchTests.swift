import Foundation
import Testing
@testable import Ghostty

struct TerminalAIWorkbenchTests {
    @Test func commandRecordsKeepTerminalIdentityAndExactOutputAcrossRestarts() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let firstSurface = UUID()
        let secondSurface = UUID()
        let first = try record(surface: firstSurface, sequence: 7, started: 100, output: "first output\nnext line", exit: 2)
        let second = try record(surface: secondSurface, sequence: 7, started: 110, output: "", exit: 0)
        #expect(first.id != second.id)
        try fixture.store.saveCommands([first], surfaceID: firstSurface)
        try fixture.store.saveCommands([second], surfaceID: secondSurface)
        let reopened = TerminalAIWorkbenchStore(directory: fixture.store.directory)
        #expect(try reopened.commands() == [second, first])
        let replacement = try record(surface: firstSurface, sequence: 8, started: 120, output: "replacement", exit: 0)
        try reopened.saveCommands([replacement], surfaceID: firstSurface)
        #expect(try fixture.store.commands() == [replacement, second])
        #expect(replacement.webValue["startedAt"] as? Double == 120_000)
        #expect(replacement.webValue["duration"] as? Double == 1)
        #expect(second.output.isEmpty)
        #expect(first.contextText.contains("Exit: 2"))
        #expect(first.contextText.contains("first output\nnext line"))
        let permissions = try FileManager.default.attributesOfItem(atPath: fixture.store.directory.appendingPathComponent("commands/\(firstSurface.uuidString).json").path)
        #expect((permissions[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }

    @Test func commandSnapshotsBoundOutputSkipCorruptionAndKeepNewestRecords() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let surface = UUID()
        let oversized = try record(surface: surface, started: 1, output: String(repeating: "x", count: 70_000))
        #expect(oversized.output.utf8.count == 65_536)
        #expect(oversized.outputTruncated)
        #expect(oversized.contextText.contains("Output (truncated)"))
        #expect(oversized.webValue["outputTruncated"] as? Bool == true)
        let values = try (0..<105).map { try record(surface: surface, sequence: UInt64($0), started: Double($0)) }
        try fixture.store.saveCommands(values, surfaceID: surface)
        let recovered = try fixture.store.commands()
        #expect(recovered.count == 100)
        #expect(recovered.first?.sequence == 104)
        #expect(recovered.last?.sequence == 5)
        let broken = fixture.store.directory.appendingPathComponent("commands/corrupt.json")
        try Data("invalid json".utf8).write(to: broken)
        #expect(try fixture.store.commands() == recovered)
        #expect(TerminalAICommandRecord(value: ["sequence": UInt64(1), "startedAt": Double.nan, "output": "bad"], surfaceID: surface) == nil)
    }

    @Test func workflowsCreateEditDeleteAcrossIndependentStoresWithoutLosingOtherEntries() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let other = TerminalAIWorkbenchStore(directory: fixture.store.directory)
        var first = workflow(name: "Check port", prompt: "Inspect port {{port}}", parameters: [parameter("port", "8080")])
        let second = workflow(name: "CPU", prompt: "Show CPU usage")
        #expect(try fixture.store.saveWorkflow(first) == [first])
        #expect(try other.saveWorkflow(second) == [first, second])
        first.name = "Inspect service port"
        first.parameters = [parameter("port", "9000")]
        #expect(try fixture.store.saveWorkflow(first) == [second, first])
        #expect(try other.workflows() == [second, first])
        #expect(try other.removeWorkflow(first.id) == [second])
        #expect(try fixture.store.workflows() == [second])
        #expect(try fixture.store.removeWorkflow(UUID()) == [second])
        let permissions = try FileManager.default.attributesOfItem(atPath: fixture.store.directory.appendingPathComponent("workflows.json").path)
        #expect((permissions[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }

    @Test func workflowParametersExpandRepeatedTokensAndRejectMismatchesAndOversizedValues() throws {
        let value = workflow(name: "Inspect host", prompt: "Inspect {{port}} on {{host-name}} then check {{port}} again",
                             parameters: [parameter("port", "8080"), parameter("host-name", "localhost")])
        #expect(try TerminalAIWorkflow.placeholders(in: value.prompt) == ["host-name", "port"])
        #expect(try value.expanded(values: ["port": "9000"]) == "Inspect 9000 on localhost then check 9000 again")
        #expect(try value.expanded(values: ["port": "literal {{host-name}}", "host-name": "real-host"]) ==
                "Inspect literal {{host-name}} on real-host then check literal {{host-name}} again")
        #expect(throws: (any Error).self) { try value.expanded(values: ["other": "unexpected"]) }
        #expect(throws: (any Error).self) { try value.expanded(values: ["port": ""]) }
        #expect(throws: (any Error).self) { try value.expanded(values: ["port": String(repeating: "x", count: 4_097)]) }
        let mismatched = workflow(name: "Broken", prompt: "Inspect {{port}}", parameters: [parameter("host", "local")])
        #expect(throws: (any Error).self) { try mismatched.expanded(values: [:]) }
        let fixture = try Fixture()
        defer { fixture.remove() }
        #expect(throws: (any Error).self) { try fixture.store.saveWorkflow(mismatched) }
        let duplicate = workflow(name: "Duplicate", prompt: "Inspect {{port}}", parameters: [parameter("port", "80"), parameter("port", "81")])
        #expect(throws: (any Error).self) { try fixture.store.saveWorkflow(duplicate) }
        let malformed = workflow(name: "Unsupported token", prompt: "Inspect {{ port }}", parameters: [parameter("port", "80")])
        #expect(throws: (any Error).self) { try fixture.store.saveWorkflow(malformed) }
        #expect(try fixture.store.workflows().isEmpty)
    }

    @Test func workflowMutationReportsAnActiveCatalogLeaseWithoutOverwriting() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let existing = workflow(name: "CPU", prompt: "Inspect CPU usage")
        _ = try fixture.store.saveWorkflow(existing)
        let lockStore = TerminalAIHistoryStore(directory: fixture.store.directory.appendingPathComponent("locks"))
        let lease = try lockStore.acquire(id: try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000001")))
        try withExtendedLifetime(lease) { () throws in
            #expect(throws: TerminalAIHistoryStore.StoreError.busy) { try fixture.store.saveWorkflow(workflow(name: "Port", prompt: "Inspect a port")) }
            #expect(throws: TerminalAIHistoryStore.StoreError.busy) { try fixture.store.removeWorkflow(existing.id) }
            #expect(try fixture.store.workflows() == [existing])
        }
    }

    @Test func taskVerificationRequiresFreshCompletedEvidenceFromItsOwnTerminal() throws {
        let surface = UUID()
        var plan = task(surface: surface)
        let valid = try record(surface: surface, started: 101, output: "all tests passed", exit: 0)
        let old = try record(surface: surface, started: 99, output: "old tests passed", exit: 0)
        let foreign = try record(surface: UUID(), started: 102, output: "other terminal", exit: 0)
        let active = try record(surface: surface, started: 103, output: "still executing", exit: nil, running: true)
        let interrupted = try record(surface: surface, started: 104, output: "interrupted", exit: 130, interrupted: true)
        let failed = try record(surface: surface, started: 105, output: "tests failed", exit: 1)
        let unknownExit = try record(surface: surface, started: 106, exit: nil)
        let unfinished = try record(surface: surface, started: 107, exit: 0, finished: false)
        let records = [valid, old, foreign, active, interrupted, failed, unknownExit, unfinished]
        for id in [old.id, foreign.id, active.id, interrupted.id, failed.id, unknownExit.id, unfinished.id, "missing"] {
            #expect(throws: (any Error).self) {
                try plan.apply(["operation": "verify", "status": "passed", "commandIds": [id], "summary": "verified"], records: records)
            }
            #expect(plan.verification.status == "pending")
        }
        #expect(throws: (any Error).self) { try plan.apply(["operation": "verify", "status": "passed", "commandIds": [valid.id, valid.id]], records: records) }
        #expect(throws: (any Error).self) { try plan.apply(["operation": "verify", "status": "passed", "commandIds": [String]()], records: records) }
        try plan.apply(["operation": "verify", "status": "passed", "commandIds": [valid.id], "summary": "Actual tests passed"], records: records)
        #expect(plan.verification.status == "passed")
        #expect(plan.verification.summary == "Actual tests passed")
        #expect(plan.verification.evidence.contains(valid.id))
        #expect(plan.verification.evidence.contains("all tests passed"))
        #expect(!plan.verification.evidence.contains("old tests passed"))
        try plan.apply(["operation": "verify", "status": "failed", "commandIds": [failed.id], "summary": "Tests failed"], records: records)
        #expect(plan.verification.status == "failed")
        #expect(plan.verification.evidence.contains("Exit: 1"))
    }

    @Test func taskPlanRestorationMarksIncompleteStepsAndVerificationWithoutClaimingSuccess() throws {
        let surface = UUID()
        var plan = task(surface: surface)
        try plan.apply(["operation": "set_plan", "steps": [["id": "inspect", "title": "Inspect error"], ["id": "repair", "title": "Repair dependency"]]], records: [])
        try plan.apply(["operation": "update_step", "stepId": "inspect", "status": "completed", "evidence": "exit 2"], records: [])
        try plan.apply(["operation": "update_step", "stepId": "repair", "status": "running", "evidence": "editing"], records: [])
        var recovered = try JSONDecoder().decode(TerminalAITaskPlan.self, from: JSONEncoder().encode(plan))
        #expect(recovered == plan)
        recovered.finish(interrupted: true)
        #expect(recovered.steps[0].status == "completed")
        #expect(recovered.steps[0].evidence == "exit 2")
        #expect(recovered.steps[1].status == "failed")
        #expect(recovered.steps[1].evidence.contains("ended before"))
        #expect(recovered.verification.status == "unverified")
        #expect(recovered.verification.summary == "Interrupted before verification.")
        #expect(throws: (any Error).self) { try recovered.apply(["operation": "update_step", "stepId": "missing", "status": "completed"], records: []) }
        #expect(throws: (any Error).self) { try recovered.apply(["operation": "update_step", "stepId": "repair", "status": "invented"], records: []) }
        let before = recovered
        #expect(throws: (any Error).self) { try recovered.apply(["operation": "set_plan", "steps": [["id": "same", "title": "One"], ["id": "same", "title": "Two"]]], records: []) }
        #expect(recovered == before)
    }

    @Test func taskVerificationUsesMonotonicSequenceWhenWallClockMoves() throws {
        let surface = UUID()
        var plan = task(surface: surface)
        plan.startSequence = 10
        let old = try record(surface: surface, sequence: 9, started: 200)
        let fresh = try record(surface: surface, sequence: 11, started: 90)
        #expect(throws: (any Error).self) {
            try plan.apply(["operation": "verify", "status": "passed", "commandIds": [old.id]], records: [old])
        }
        try plan.apply(["operation": "verify", "status": "passed", "commandIds": [fresh.id]], records: [fresh])
        #expect(plan.verification.status == "passed")
        #expect(plan.verification.evidence.contains(fresh.id))
    }

    @Test func readingTaskPlanPreservesItsIdentityProgressAndVerification() throws {
        let surface = UUID()
        var plan = task(surface: surface)
        try plan.apply(["operation": "update_step", "stepId": "inspect", "status": "completed", "evidence": "Observed output"], records: [])
        let check = try record(surface: surface)
        try plan.apply(["operation": "verify", "status": "passed", "commandIds": [check.id], "summary": "Checked result"], records: [check])
        let before = plan
        try plan.apply(["operation": "get_plan"], records: [])
        #expect(plan == before)
        let context = plan.modelContext
        #expect(context.contains("Current investigation plan:"))
        let stateText = try #require(context.split(separator: "\n", maxSplits: 1).last)
        let state = try #require(JSONSerialization.jsonObject(with: Data(stateText.utf8)) as? [String: Any])
        #expect(state["id"] as? String == plan.id.uuidString)
        let steps = try #require(state["steps"] as? [[String: String]])
        #expect(steps.first?["id"] == "inspect")
        #expect(steps.first?["status"] == "completed")
        #expect(steps.first?["evidence"] == nil)
        #expect((state["verification"] as? [String: String])?["status"] == "passed")
    }

    @Test func taskPlanErrorsDistinguishMissingIDsFromInvalidStatusWithoutChangingProgress() throws {
        var plan = task(surface: UUID())
        let before = plan
        do {
            try plan.apply(["operation": "update_step", "stepId": "transient", "status": "completed"], records: [])
            Issue.record("An undeclared step was accepted")
        } catch {
            #expect(error.localizedDescription.contains("Unknown step ID \"transient\""))
            #expect(error.localizedDescription.contains("Existing step IDs: inspect"))
        }
        #expect(plan == before)
        for invalid in ["in_progress", "done", "passed"] {
            do {
                try plan.apply(["operation": "update_step", "stepId": "inspect", "status": invalid], records: [])
                Issue.record("An invalid status was accepted")
            } catch {
                #expect(error.localizedDescription == "update_step requires status: pending, running, completed, failed.")
            }
            #expect(plan == before)
        }
        #expect(throws: (any Error).self) { try plan.apply(["operation": "update_step", "status": "completed"], records: []) }
        #expect(plan == before)
    }

    @Test func taskPlanAcceptsDeclaredScreenshotStepAndBoundsVisibleStateWithoutDiscardingEvidence() throws {
        var plan = task(surface: UUID())
        try plan.apply(["operation": "set_plan", "steps": [["id": "transient", "title": "追踪短命进程"]]], records: [])
        try plan.apply(["evidence": String(repeating: "中", count: 9_000), "operation": "update_step", "status": "completed",
                        "stepId": "transient", "summary": "额外的总结字段不改变步骤状态"], records: [])
        #expect(plan.steps.first?.status == "completed")
        #expect(plan.steps.first?.evidence.count == 8_192)
        #expect(plan.modelContext.utf8.count < 2_048)
        #expect(plan.modelContext.contains("transient"))
        #expect(!plan.modelContext.contains(String(repeating: "中", count: 100)))
    }

    @Test func taskVerificationRejectsOtherOrUnknownHostsOnTheSameSurface() throws {
        let surface = UUID()
        var plan = task(surface: surface)
        let same = try record(surface: surface, sequence: 1, host: "fixture-host")
        let other = try record(surface: surface, sequence: 2, host: "other-host")
        let missing = try record(surface: surface, sequence: 3, host: nil)
        for invalid in [other, missing] {
            #expect(throws: (any Error).self) {
                try plan.apply(["operation": "verify", "status": "passed", "commandIds": [invalid.id]], records: [invalid])
            }
            #expect(plan.verification.status == "pending")
        }
        try plan.apply(["operation": "verify", "status": "passed", "commandIds": [same.id]], records: [same])
        #expect(plan.verification.status == "passed")
        #expect(plan.verification.evidence.contains("Reported host: fixture-host"))
        for unknown in [nil, "unknown", ""] as [String?] {
            plan.host = unknown
            plan.verification = .init()
            #expect(throws: (any Error).self) {
                try plan.apply(["operation": "verify", "status": "passed", "commandIds": [same.id]], records: [same])
            }
            #expect(plan.verification.status == "pending")
        }
    }

    @Test func legacyTaskPlanWithoutAHostRemainsReadableButCannotVerifyNewCommands() throws {
        let surface = UUID()
        let original = task(surface: surface)
        let data = try JSONEncoder().encode(original)
        var legacy = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        legacy.removeValue(forKey: "host")
        var recovered = try JSONDecoder().decode(TerminalAITaskPlan.self, from: JSONSerialization.data(withJSONObject: legacy))
        #expect(recovered.host == nil)
        #expect(recovered.id == original.id)
        #expect(recovered.surfaceID == original.surfaceID)
        #expect(recovered.steps == original.steps)
        let command = try record(surface: surface)
        #expect(throws: (any Error).self) {
            try recovered.apply(["operation": "verify", "status": "passed", "commandIds": [command.id]], records: [command])
        }
        #expect(recovered.verification.status == "pending")
    }

    private struct Fixture {
        let root: URL
        let store: TerminalAIWorkbenchStore

        init() throws {
            root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("TerminalAIWorkbenchTests.\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            store = TerminalAIWorkbenchStore(directory: root.appendingPathComponent("workbench"))
        }

        func remove() { try? FileManager.default.removeItem(at: root) }
    }

    private func parameter(_ name: String, _ defaultValue: String) -> TerminalAIWorkflow.Parameter {
        .init(name: name, defaultValue: defaultValue)
    }

    private func workflow(name: String, prompt: String, parameters: [TerminalAIWorkflow.Parameter] = []) -> TerminalAIWorkflow {
        .init(id: UUID(), name: name, description: "Fixture workflow", prompt: prompt, parameters: parameters)
    }

    private func task(surface: UUID) -> TerminalAITaskPlan {
        .init(id: UUID(), title: "Repair build", surfaceID: surface, host: "fixture-host", startedAt: 100,
              steps: [.init(id: "inspect", title: "Inspect error")])
    }

    private func record(surface: UUID, sequence: UInt64 = 1, started: Double = 101, host: String? = "fixture-host", output: String = "fixture output", exit: Int? = 0,
                        running: Bool = false, interrupted: Bool = false, finished: Bool = true) throws -> TerminalAICommandRecord {
        var value: [String: Any] = ["sequence": sequence, "startedAt": started, "command": "make test", "commandSource": "shell_integration",
                                    "directory": "/fixture/project", "hostIsLocal": false,
                                    "durationMs": UInt64(1_000), "running": running, "interrupted": interrupted, "output": output]
        if let host { value["host"] = host }
        if let exit { value["exitCode"] = exit }
        if finished && !running { value["finishedAt"] = started + 1 }
        return try #require(TerminalAICommandRecord(value: value, surfaceID: surface))
    }
}
