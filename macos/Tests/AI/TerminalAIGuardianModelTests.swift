import Foundation
import Testing
@testable import Ghostty

@Suite(.serialized)
@MainActor
struct TerminalAIGuardianModelTests {
    @Test func readyGuardianFreezesHumanContextAndExecutesOnlyTheCorrelatedCommand() async throws {
        let fixture = try GuardianModelFixture(enabled: true)
        defer { fixture.close() }
        fixture.begin("Create the requested fixture marker")
        try fixture.terminalRequest(id: "terminal", command: "touch requested-marker")
        let review = try fixture.review()
        let action = try #require(review.packet["action"] as? [String: Any])
        let context = try #require(review.packet["context"] as? [String: Any])
        let target = try #require(context["target"] as? [String: Any])
        #expect(action["command"] as? String == "touch requested-marker")
        #expect(action["timeoutSeconds"] as? Int == 20)
        #expect(context["userMessages"] as? [String] == ["Create the requested fixture marker"])
        #expect(target["surfaceID"] as? String == fixture.model.surfaceID?.uuidString)
        #expect(target["directory"] as? String == fixture.directory.path)
        #expect(fixture.model.approval == nil && fixture.recording.operations.isEmpty)
        #expect(fixture.model.statusLabel.contains("reviewing"))
        try fixture.deliver(review, risk: "medium")
        try await fixture.wait { fixture.hasResponse("terminal") }
        #expect(fixture.recording.operations.count == 1)
        #expect(fixture.recording.operations[0]["command"] as? String == "touch requested-marker")
        #expect(fixture.recording.operations[0]["reason"] as? String == "Execute the exact requested fixture action")
        #expect(fixture.recording.operations[0]["timeout"] as? Int == 20)
        #expect(try fixture.response("terminal")["exitCode"] as? Int == 0)
        #expect(fixture.model.approval == nil)
        #expect(fixture.model.response.contains("Allowed · medium risk"))
        try fixture.deliver(review, responseID: "late-replay")
        #expect(fixture.recording.operations.count == 1)
        #expect(fixture.responseCount("terminal") == 1)
        #expect(try fixture.response("late-replay")["error"] is String)
    }

    @Test func approvedFileAppliesTheFrozenNativeDiffExactlyOnce() async throws {
        let fixture = try GuardianModelFixture(enabled: true)
        defer { fixture.close() }
        fixture.begin("Replace only the fixture file")
        let file = try fixture.originalFile()
        try fixture.fileRequest(id: "file", file: file)
        try await fixture.wait { fixture.hasReview }
        let review = try fixture.review()
        let action = try #require(review.packet["action"] as? [String: Any])
        #expect(action["kind"] as? String == "file")
        #expect(action["path"] as? String == file.path)
        #expect((action["diff"] as? String)?.contains("-original 中文") == true)
        #expect((action["diff"] as? String)?.contains("+approved 中文") == true)
        #expect(action["contentSHA256"] as? String == TerminalAIApprovalReview.sha256(Data("approved 中文\n".utf8)))
        #expect(review.packet["narrowScopeEvidence"] is String)
        #expect(try String(contentsOf: file, encoding: .utf8) == "original 中文\n")
        try fixture.deliver(review, risk: "high", authorization: "high")
        #expect(try String(contentsOf: file, encoding: .utf8) == "approved 中文\n")
        #expect(try fixture.response("file")["changed"] as? Bool == true)
        #expect(fixture.model.approval == nil && fixture.recording.operations.isEmpty)
        try fixture.deliver(review, responseID: "late-file-replay")
        #expect(fixture.responseCount("file") == 1)
        #expect(try fixture.response("late-file-replay")["error"] is String)
    }

    @Test(arguments: ["not-ready", "malformed", "fault", "high-no-scope", "rpc-failure"])
    func invalidOrUnavailableReviewFallsBackToManualWithoutExecuting(scenario: String) async throws {
        let fixture = try GuardianModelFixture(enabled: true)
        defer { fixture.close() }
        fixture.begin("Perform only the requested command", guardianReady: scenario != "not-ready")
        try fixture.terminalRequest(id: "terminal", command: "touch requested-marker")
        if scenario != "not-ready" {
            let review = try fixture.review()
            switch scenario {
            case "malformed": try fixture.deliver(review, envelopeChanges: ["assessment": NSNull()])
            case "fault": try fixture.deliver(review, error: "The reviewer is unavailable")
            case "high-no-scope": try fixture.deliver(review, risk: "high", authorization: "high")
            default:
                fixture.model.receive(["type": "response", "id": review.promptID, "success": false, "error": "Controlled review transport failure"])
            }
        }
        #expect(fixture.model.approval?.id == "terminal")
        #expect(fixture.model.phase == .waitingApproval && fixture.model.isRunning)
        #expect(fixture.recording.operations.isEmpty)
        #expect(!fixture.hasResponse("terminal"))
        fixture.model.respondToApproval(allow: false)
        #expect(fixture.recording.operations.isEmpty)
        #expect(try fixture.response("terminal")["error"] is String)
    }

    @Test(arguments: ["terminal", "file"])
    func criticalRiskDeniesEvenAnAllowVerdict(kind: String) async throws {
        let fixture = try GuardianModelFixture(enabled: true)
        defer { fixture.close() }
        fixture.begin("Perform the fixture action")
        let file = try fixture.originalFile()
        if kind == "file" {
            try fixture.fileRequest(id: "action", file: file)
        } else {
            try fixture.terminalRequest(id: "action", command: "touch requested-marker")
        }
        try await fixture.wait { fixture.hasReview }
        try fixture.deliver(fixture.review(), risk: "critical", authorization: "high")
        #expect((try fixture.response("action")["error"] as? String)?.contains("critical") == true)
        #expect(fixture.model.approval == nil && fixture.recording.operations.isEmpty)
        #expect(try String(contentsOf: file, encoding: .utf8) == "original 中文\n")
        #expect(fixture.model.response.contains("Denied · critical risk"))
    }

    @Test(arguments: ["terminal", "file"])
    func taskOrTargetChangesRejectLateVerdictsWithoutAnyMutation(kind: String) async throws {
        for change in ["stop", "steer", "workspace", "agent-directory", "target"] {
            let fixture = try GuardianModelFixture(enabled: true)
            defer { fixture.close() }
            fixture.begin("Perform the fixture action")
            let file = try fixture.originalFile()
            if kind == "file" {
                try fixture.fileRequest(id: "action", file: file)
            } else {
                try fixture.terminalRequest(id: "action", command: "touch requested-marker")
            }
            try await fixture.wait { fixture.hasReview }
            let review = try fixture.review()
            switch change {
            case "stop": fixture.model.stop()
            case "steer": fixture.model.sendInput("Do not change the file or run the command", mode: "steer")
            case "workspace": fixture.model.workingDirectory = fixture.otherDirectory.path
            case "agent-directory": fixture.model.piConfigurationDirectory = fixture.otherDirectory.path
            default:
                fixture.model.stop()
                fixture.model.receive(["type": "agent_settled"])
                fixture.model.present(surfaceID: UUID(), directory: fixture.otherDirectory.path, selection: nil)
            }
            try fixture.deliver(review)
            #expect(fixture.recording.operations.isEmpty, "Unexpected terminal execution after \(change)")
            #expect(try String(contentsOf: file, encoding: .utf8) == "original 中文\n", "Unexpected file mutation after \(change)")
            #expect(try fixture.response("action")["error"] is String)
            #expect(fixture.responseCount("action") == 1)
            #expect(fixture.model.approval == nil)
        }
    }

    @Test func staleFileIsPreservedAfterAnOtherwiseValidAutomaticApproval() async throws {
        let fixture = try GuardianModelFixture(enabled: true)
        defer { fixture.close() }
        fixture.begin("Replace only the fixture file")
        let file = try fixture.originalFile()
        try fixture.fileRequest(id: "file", file: file)
        try await fixture.wait { fixture.hasReview }
        let review = try fixture.review()
        try "New human edit\n".write(to: file, atomically: true, encoding: .utf8)
        try fixture.deliver(review)
        #expect(try String(contentsOf: file, encoding: .utf8) == "New human edit\n")
        #expect(try fixture.response("file")["error"] is String)
        #expect(fixture.recording.operations.isEmpty && fixture.model.approval == nil)
    }

    @Test func previousVerdictCannotApproveTheNextAction() async throws {
        let fixture = try GuardianModelFixture(enabled: true)
        defer { fixture.close() }
        fixture.begin("Perform only the two specified fixture commands")
        try fixture.terminalRequest(id: "first", command: "touch first-marker")
        let first = try fixture.review()
        try fixture.deliver(first)
        try await fixture.wait { fixture.hasResponse("first") }
        try fixture.terminalRequest(id: "second", command: "touch second-marker")
        let second = try fixture.review()
        #expect(first.packet["reviewId"] as? String != second.packet["reviewId"] as? String)
        try fixture.deliver(first, responseID: "replayed-previous")
        #expect(fixture.model.approval == nil && fixture.model.isRunning)
        #expect(fixture.recording.operations.count == 1 && !fixture.hasResponse("second"))
        fixture.deliverRaw("not JSON", responseID: "unbound-reply")
        #expect(fixture.model.approval == nil && !fixture.hasResponse("second"))
        #expect(fixture.recording.operations.count == 1)
        try fixture.deliver(second, responseID: "matching-second")
        try await fixture.wait { fixture.hasResponse("second") }
        #expect(fixture.recording.operations.count == 2)
        #expect(fixture.recording.operations.last?["command"] as? String == "touch second-marker")
        #expect(try fixture.response("second")["exitCode"] as? Int == 0)
    }

    @Test func steeringAfterApprovalButBeforeDispatchNeverCallsTheTerminalOverride() async throws {
        let fixture = try GuardianModelFixture(enabled: true)
        defer { fixture.close() }
        fixture.begin("Perform the fixture action")
        try fixture.terminalRequest(id: "terminal", command: "touch requested-marker")
        try fixture.deliver(fixture.review())
        // No await occurs between approval and steer: the scheduled terminal task
        // has not received a chance to dispatch the frozen payload.
        fixture.model.sendInput("Cancel that action", mode: "steer")
        try await fixture.wait { fixture.hasResponse("terminal") }
        await Task.yield()
        #expect(fixture.recording.operations.isEmpty)
        #expect(try fixture.response("terminal")["error"] is String)
    }

    @Test func guardianDefaultsOffCanBeDisabledAndNeverLoadsInCommandMode() async throws {
        let fixture = try GuardianModelFixture()
        defer { fixture.close() }
        #expect(!fixture.model.isAutomaticReviewEnabled)
        #expect(fixture.model.webSnapshot["automaticReviewEnabled"] as? Bool == false)
        await fixture.model.refreshPlugins()
        let guardian = try #require(fixture.model.availablePlugins.first { $0.id == TerminalAIPluginCatalog.builtinGuardianID })
        fixture.model.setPluginEnabled(guardian, enabled: true)
        #expect(fixture.model.webSnapshot["automaticReviewEnabled"] as? Bool == true)
        #expect(try fixture.model.prepareConnectionConfiguration().environment["GHOSTTY_AI_GUARDIAN"] == "true")
        fixture.model.disableAutomaticReview()
        #expect(!fixture.model.isAutomaticReviewEnabled && fixture.model.enabledPluginIDs.isEmpty)
        #expect(fixture.model.webSnapshot["automaticReviewEnabled"] as? Bool == false)
        #expect(try fixture.model.prepareConnectionConfiguration().environment["GHOSTTY_AI_GUARDIAN"] == nil)
        let command = try GuardianModelFixture(enabled: true, mode: .command)
        defer { command.close() }
        #expect(!command.model.isAutomaticReviewEnabled)
        #expect(command.model.webSnapshot["automaticReviewEnabled"] as? Bool == false)
        let configuration = try command.model.prepareConnectionConfiguration()
        #expect(configuration.environment["GHOSTTY_AI_GUARDIAN"] == nil)
        #expect(!configuration.arguments.contains(command.guardianDirectory.appendingPathComponent("index.ts").path))
    }
}

@MainActor
private final class GuardianModelRecording {
    var commands: [[String: Any]] = []
    var operations: [[String: Any]] = []
}

@MainActor
private final class GuardianModelFixture {
    struct Review {
        let promptID: String
        let packet: [String: Any]
    }

    let directory: URL
    let otherDirectory: URL
    let guardianDirectory: URL
    let defaults: UserDefaults
    let model: TerminalAIModel
    let recording = GuardianModelRecording()
    private let suite = "TerminalAIGuardianModelTests.\(UUID().uuidString)"
    private let reviewPrefix = "/_ghostty_guardian_review "

    init(enabled: Bool = false, mode: TerminalAIModel.Mode = .assistant) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite, isDirectory: true)
            .standardizedFileURL.resolvingSymlinksInPath()
        otherDirectory = directory.appendingPathComponent("other-workspace", isDirectory: true)
        guardianDirectory = directory.appendingPathComponent("guardian", isDirectory: true)
        for path in [directory, otherDirectory, guardianDirectory] {
            try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        }
        let manifest: [String: Any] = ["name": "codex-guardian", "pi": ["extensions": ["index.ts"]]]
        try JSONSerialization.data(withJSONObject: manifest).write(to: guardianDirectory.appendingPathComponent("package.json"))
        try Data("throw new Error('Never import a native test fixture');".utf8).write(to: guardianDirectory.appendingPathComponent("index.ts"))
        defaults = try #require(UserDefaults(suiteName: suite))
        defaults.set("/fixture/pi", forKey: "terminalAI.executablePath")
        defaults.set("", forKey: "terminalAI.nodePath")
        defaults.set(true, forKey: "terminalAI.useExistingPiConfiguration")
        defaults.set(directory.path, forKey: "terminalAI.piConfigurationDirectory")
        if enabled { defaults.set([TerminalAIPluginCatalog.builtinGuardianID], forKey: "terminalAI.enabledPluginIDs") }
        let recording = self.recording
        model = TerminalAIModel(defaults: defaults, sendCommand: { recording.commands.append($0) },
                                terminalOperation: { payload in
                                    recording.operations.append(payload)
                                    return ["output": "Controlled terminal result", "exitCode": 0]
                                }, configurationDirectory: directory.appendingPathComponent("ghostty-ai"), mode: mode,
                                builtinPluginDirectory: guardianDirectory)
        model.present(surfaceID: UUID(), directory: directory.path, selection: "Untrusted terminal text")
    }

    func begin(_ goal: String, guardianReady: Bool = true) {
        model.prompt = goal
        model.submit()
        if guardianReady {
            model.receive(["type": "extension_ui_request", "method": "setStatus", "id": "guardian-ready",
                           "statusKey": "ghostty-guardian", "statusText": "ready"])
        }
    }

    func terminalRequest(id: String, command: String) throws {
        try request(title: "ghostty-terminal-v1", id: id,
                    payload: ["operation": "run", "command": command, "reason": "Execute the exact requested fixture action", "timeout": 20])
    }

    func originalFile() throws -> URL {
        let file = directory.appendingPathComponent("review.txt")
        try "original 中文\n".write(to: file, atomically: true, encoding: .utf8)
        return file
    }

    func fileRequest(id: String, file: URL) throws {
        try request(title: "ghostty-file-v1", id: id,
                    payload: ["operation": "write", "path": file.path, "content": "approved 中文\n",
                              "originalSHA256": TerminalAIApprovalReview.sha256(Data("original 中文\n".utf8))])
    }

    private func request(title: String, id: String, payload: [String: Any]) throws {
        let wire = try #require(String(bytes: JSONSerialization.data(withJSONObject: payload), encoding: .utf8))
        model.receive(["type": "extension_ui_request", "method": "input", "title": title, "id": id,
                       "placeholder": wire])
    }

    var hasReview: Bool { recording.commands.contains { ($0["message"] as? String)?.hasPrefix(reviewPrefix) == true } }

    func review() throws -> Review {
        let record = try #require(recording.commands.last { ($0["message"] as? String)?.hasPrefix(reviewPrefix) == true })
        let message = try #require(record["message"] as? String)
        let data = try #require(Data(base64Encoded: String(message.dropFirst(reviewPrefix.count))))
        return Review(promptID: try #require(record["id"] as? String),
                      packet: try #require(JSONSerialization.jsonObject(with: data) as? [String: Any]))
    }

    func deliver(_ review: Review, risk: String = "low", authorization: String = "unknown", error: String? = nil,
                 responseID: String = "review-result", envelopeChanges: [String: Any] = [:]) throws {
        var envelope = Dictionary(uniqueKeysWithValues: ["version", "reviewId", "nonce", "actionDigest", "generation"]
            .compactMap { key in review.packet[key].map { (key, $0) } })
        if let error {
            envelope["error"] = error
        } else {
            envelope["assessment"] = ["outcome": "allow", "risk_level": risk, "user_authorization": authorization, "rationale": "Controlled reviewer assessment"]
        }
        envelope.merge(envelopeChanges) { _, replacement in replacement }
        let json = try #require(String(bytes: JSONSerialization.data(withJSONObject: envelope), encoding: .utf8))
        deliverRaw(json, responseID: responseID)
    }

    func deliverRaw(_ json: String, responseID: String = "review-result") {
        model.receive(["type": "extension_ui_request", "method": "input", "title": "ghostty-approval-review-v1",
                       "id": responseID, "placeholder": json])
    }

    func responseCount(_ id: String) -> Int {
        recording.commands.filter { $0["type"] as? String == "extension_ui_response" && $0["id"] as? String == id }.count
    }

    func hasResponse(_ id: String) -> Bool { responseCount(id) > 0 }

    func response(_ id: String) throws -> [String: Any] {
        let response = try #require(recording.commands.last { $0["type"] as? String == "extension_ui_response" && $0["id"] as? String == id })
        let value = try #require(response["value"] as? String)
        return try #require(JSONSerialization.jsonObject(with: Data(value.utf8)) as? [String: Any])
    }

    func wait(_ predicate: () -> Bool) async throws {
        for _ in 0..<200 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Controlled Guardian model fixture did not settle: \(model.statusLabel)")
        throw NSError(domain: "GuardianModelFixture", code: 1)
    }

    func close() {
        model.stop()
        model.receive(["type": "agent_settled"])
        _ = model.reset()
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory)
    }
}
