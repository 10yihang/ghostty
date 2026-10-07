import Foundation
import GhosttyKit
import Testing
@testable import Ghostty

/// Real, isolated PTYs verify command records for human input as well as AI
/// input. No test locates the user's existing terminal or loads user rc files.
@Suite(.serialized)
@MainActor
struct TerminalAICommandHistoryTests {
    @Test func manualCommandsRetainTheirOwnOutputAndFailureContext() async throws {
        try await withFixture { fixture in
            let firstCommand = "printf 'manual-first-only\\n'; false"
            try await runManually(firstCommand, fixture: fixture)
            try await runManually("true", fixture: fixture)
            let thirdCommand = "printf 'manual-third-only\\n'"
            try await runManually(thirdCommand, fixture: fixture)

            let snapshot = try readJSON(fixture, identityOnly: false)
            let records = try #require(snapshot["commands"] as? [[String: Any]])
            #expect(records.count == 3)
            let first = try #require(records.first { $0["command"] as? String == firstCommand })
            let empty = try #require(records.first { $0["command"] as? String == "true" })
            let third = try #require(records.first { $0["command"] as? String == thirdCommand })
            #expect(first["exitCode"] as? Int == 1)
            #expect(first["output"] as? String == "manual-first-only")
            #expect(first["commandSource"] as? String == "screen")
            #expect(first["running"] as? Bool == false)
            #expect(first["interrupted"] as? Bool == false)
            #expect((first["durationMs"] as? UInt64) != nil)
            #expect((first["startedAt"] as? Double ?? 0) > 0)
            #expect((first["finishedAt"] as? Double ?? 0) >= (first["startedAt"] as? Double ?? 0))
            #expect(first["hostIsLocal"] as? Bool == true)
            #expect((first["host"] as? String)?.isEmpty == false)
            #expect((first["directory"] as? String)?.hasSuffix("tmp") == true)
            #expect(empty["exitCode"] as? Int == 0)
            #expect(empty["output"] as? String == "")
            #expect(third["output"] as? String == "manual-third-only")
            try await fixture.wait("The command-finished callbacks did not carry all three record identities") {
                fixture.records.commandFinished.count == 3
            }
            for record in [first, empty, third] {
                let sequence = try #require(record["sequence"] as? UInt64)
                let event = try #require(fixture.records.commandFinished.first { $0["recordSequence"] as? UInt64 == sequence })
                #expect(event["exitCode"] as? Int == record["exitCode"] as? Int)
            }

            fixture.assistant.recordCommandHistory(from: fixture.view!)
            let nativeFailure = try #require(fixture.assistant.commands.first { $0.command == firstCommand })
            let before = ghostty_surface_command_state(fixture.surface)
            fixture.assistant.attachCommand(nativeFailure.id)
            let attachment = try #require(fixture.assistant.attachments.first { $0.kind == "command" })
            #expect(attachment.text.contains("manual-first-only"))
            #expect(attachment.text.contains(firstCommand))
            #expect(!attachment.text.contains("manual-third-only"))
            fixture.assistant.explainCommand(nativeFailure.id)
            #expect(ghostty_surface_command_state(fixture.surface).started == before.started)
            #expect(fixture.assistant.attachments.contains { $0.text.contains(nativeFailure.id) })
            #expect(!fixture.view!.processExited)
        }
    }

    @Test func identityReportsRemoteShellClaimsWithoutTreatingThemAsLocalPaths() async throws {
        try await withFixture { fixture in
            let local = try readJSON(fixture, identityOnly: true)
            let localHost = try #require(local["host"] as? String)
            let localDirectory = try #require(local["directory"] as? String)
            #expect(local["hostIsLocal"] as? Bool == true)
            #expect(local["shellIntegrated"] as? Bool == true)
            #expect(local["promptStatus"] as? Int == 0)
            fixture.assistant.terminalControlAllowed = true

            // This is a nested integrated shell in the same isolated PTY. Its
            // OSC 7 host is deliberately synthetic; it is not an SSH transport
            // test and never connects to or modifies a remote machine.
            let remoteRoot = fixture.root.appendingPathComponent("remote-style-shell")
            try FileManager.default.createDirectory(at: remoteRoot, withIntermediateDirectories: true)
            try "".write(to: remoteRoot.appendingPathComponent(".zshenv"), atomically: true, encoding: .utf8)
            let integration = try #require(Bundle.main.resourceURL?.appendingPathComponent("ghostty/shell-integration/zsh/ghostty-integration"))
            try """
            PROMPT='remote-fixture> '
            RPROMPT=''
            HISTFILE=/dev/null
            SAVEHIST=0
            source \(shellQuote(integration.path))
            HOST=ghostty-ai-test-remote.invalid
            """.write(to: remoteRoot.appendingPathComponent(".zshrc"), atomically: true, encoding: .utf8)
            let entry = "ZDOTDIR=\(shellQuote(remoteRoot.path)) /bin/zsh -d"
            try sendManually(entry, fixture: fixture)
            try await fixture.wait("The nested remote-style shell did not report a ready prompt", timeout: 10) {
                guard let identity = try? readJSON(fixture, identityOnly: true) else { return false }
                return identity["host"] as? String == "ghostty-ai-test-remote.invalid" &&
                    identity["hostIsLocal"] as? Bool == false && ghostty_surface_prompt_state(fixture.surface)
            }
            let remote = try readJSON(fixture, identityOnly: true)
            #expect(remote["shellIntegrated"] as? Bool == true)
            #expect(remote["promptStatus"] as? Int == 0)
            fixture.assistant.recordCommandHistory(from: fixture.view!)
            #expect(fixture.assistant.terminalIdentity["host"] as? String == "ghostty-ai-test-remote.invalid")
            #expect(!fixture.assistant.terminalControlAllowed)
            #expect(fixture.assistant.error?.contains("host changed") == true)
            let outer = try #require(fixture.assistant.commands.first { $0.command == entry })
            #expect(outer.host == localHost)
            #expect(outer.interrupted)
            #expect(outer.exitCode == nil)

            try await runManually("printf 'remote-command-only\\n'", fixture: fixture)
            let history = try readJSON(fixture, identityOnly: false)
            let records = try #require(history["commands"] as? [[String: Any]])
            let command = try #require(records.first { $0["output"] as? String == "remote-command-only" })
            #expect(command["host"] as? String == "ghostty-ai-test-remote.invalid")
            #expect(command["hostIsLocal"] as? Bool == false)
            #expect(command["exitCode"] as? Int == 0)

            try sendManually("exit", fixture: fixture)
            try await fixture.wait("The original local shell identity did not return", timeout: 10) {
                guard let identity = try? readJSON(fixture, identityOnly: true) else { return false }
                return identity["host"] as? String == localHost &&
                    identity["hostIsLocal"] as? Bool == true && ghostty_surface_prompt_state(fixture.surface)
            }
            let returned = try readJSON(fixture, identityOnly: true)
            #expect(returned["directory"] as? String == localDirectory)
            #expect(!fixture.view!.processExited)
        }
    }

    @Test func editableCommandIsFilledWithoutExecutingOrOverwritingHumanInput() async throws {
        try await withFixture { fixture in
            let baseline = ghostty_surface_command_state(fixture.surface)
            let draft = "printf 'reviewed-but-not-executed\\n'"
            fixture.assistant.fillSuggestedCommand(draft)
            try await fixture.wait("The reviewed command was not filled into the prompt") {
                fixture.view!.visibleTextSnapshot().contains(draft) && !ghostty_surface_prompt_state(fixture.surface)
            }
            #expect(ghostty_surface_command_state(fixture.surface).started == baseline.started)
            #expect(ghostty_surface_command_state(fixture.surface).finished == baseline.finished)
            let before = fixture.view!.visibleTextSnapshot()
            fixture.assistant.fillSuggestedCommand("printf 'must-not-replace-the-draft\\n'")
            #expect(fixture.assistant.error != nil)
            #expect(fixture.view!.visibleTextSnapshot() == before)
            #expect(ghostty_surface_command_state(fixture.surface).started == baseline.started)
            let history = try readJSON(fixture, identityOnly: false)
            #expect((history["commands"] as? [[String: Any]])?.isEmpty == true)
        }
    }

    private func withFixture(_ body: (TerminalFixture) async throws -> Void) async throws {
        let fixture = try TerminalFixture()
        do {
            try await fixture.wait("The isolated shell did not reach its prompt", timeout: 10) {
                ghostty_surface_prompt_state(fixture.surface)
            }
            fixture.assistant.present(surfaceID: fixture.view!.id, directory: "/tmp", selection: nil)
            fixture.assistant.bindTerminal(fixture.view!)
            try await body(fixture)
            await fixture.close()
        } catch {
            await fixture.close()
            throw error
        }
    }

    private func sendManually(_ command: String, fixture: TerminalFixture) throws {
        let view = try #require(fixture.view)
        let surfaceModel = try #require(view.surfaceModel)
        try #require(ghostty_surface_prompt_state(fixture.surface))
        surfaceModel.sendText(command)
        try #require(surfaceModel.perform(action: "text:\\r"))
    }

    private func runManually(_ command: String, fixture: TerminalFixture) async throws {
        let before = ghostty_surface_command_state(fixture.surface)
        try sendManually(command, fixture: fixture)
        try await fixture.wait("The manual fixture command did not finish", timeout: 8) {
            let state = ghostty_surface_command_state(fixture.surface)
            return state.started == before.started + 1 && state.finished == state.started &&
                ghostty_surface_prompt_state(fixture.surface)
        }
    }

    private func readJSON(_ fixture: TerminalFixture, identityOnly: Bool) throws -> [String: Any] {
        var text = ghostty_text_s()
        let read = identityOnly ? ghostty_surface_read_terminal_identity(fixture.surface, &text) :
            ghostty_surface_read_command_history(fixture.surface, &text)
        try #require(read)
        defer { ghostty_surface_free_text(fixture.surface, &text) }
        let bytes = try #require(text.text)
        return try #require(JSONSerialization.jsonObject(with: Data(bytes: bytes, count: Int(text.text_len))) as? [String: Any])
    }

    private func shellQuote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
