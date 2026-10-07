import AppKit
import Darwin
import GhosttyKit
import Testing
@testable import Ghostty

/// These tests create their own C app, PTY and shell. They never locate or send
/// input to a window belonging to the running user's Ghostty app.
@Suite(.serialized)
@MainActor
struct TerminalAITerminalTests {
    @Test func attachedTerminalRunsInTheSameShellPreservesHumanInputAndStopsOwnedCommands() async throws {
        try await withTerminal { fixture in
            let first = try await fixture.request([
                "operation": "run", "command": "printf 'first-command-only\\n'", "timeout": 5
            ])
            #expect(first["exitCode"] as? Int == 0)
            #expect(first["outputCaptured"] as? Bool == true)
            #expect((first["output"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) == "first-command-only")

            let screen = try await fixture.request(["operation": "read"])
            #expect((screen["output"] as? String)?.contains("first-command-only") == true)
            #expect((screen["scope"] as? String)?.contains("visible terminal screen") == true)

            // Per-command approval uses the same real PTY even without a task grant.
            fixture.assistant.terminalControlAllowed = false
            let cpuCommand = "ps -Ao pid,%cpu,%mem,comm -r | head -n 6"
            let cpuBaseline = ghostty_surface_command_state(fixture.surface)
            let cpuID = try fixture.beginRequest(["operation": "run", "command": cpuCommand, "timeout": 5])
            #expect(fixture.assistant.approval?.id == cpuID)
            #expect(ghostty_surface_command_state(fixture.surface).started == cpuBaseline.started)
            fixture.assistant.respondToApproval(allow: true)
            let cpu = try await fixture.result(for: cpuID)
            #expect(cpu["exitCode"] as? Int == 0)
            #expect((cpu["output"] as? String)?.contains("%CPU") == true)
            #expect((cpu["output"] as? String)?.contains("%MEM") == true)
            #expect(fixture.view!.visibleTextSnapshot().contains("ps -Ao pid,%cpu,%mem"))
            #expect(!fixture.assistant.terminalControlAllowed)
            fixture.assistant.terminalControlAllowed = true

            let assignment = try await fixture.request([
                "operation": "run", "command": "GHOSTTY_AI_TEST_SESSION=kept-in-this-shell", "timeout": 5
            ])
            #expect(assignment["exitCode"] as? Int == 0)
            #expect((assignment["output"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true)

            let preserved = try await fixture.request([
                "operation": "run",
                "command": "printf '%s:%s\\n' \"$GHOSTTY_AI_TEST_SESSION\" \"$GHOSTTY_AI_CLEAN_FIXTURE\"; ghostty_fixture_alias",
                "timeout": 5
            ])
            #expect(preserved["exitCode"] as? Int == 0)
            #expect((preserved["output"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) == "kept-in-this-shell:1\nalias-ok")

            let failed = try await fixture.request([
                "operation": "run", "command": "false", "timeout": 5
            ])
            #expect(failed["exitCode"] as? Int == 1)
            #expect(failed["error"] == nil)
            #expect(!fixture.view!.processExited)

            // A no-output command must not inherit the preceding command's
            // semantic output, even though it is still on the visible screen.
            let noOutput = try await fixture.request([
                "operation": "run", "command": ":", "timeout": 5
            ])
            #expect(noOutput["exitCode"] as? Int == 0)
            #expect((noOutput["output"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true)
            #expect((noOutput["output"] as? String)?.contains("kept-in-this-shell") == false)
            let draft = "printf 'pending-human-input'"
            fixture.view!.surfaceModel!.sendText(draft)
            // Include text after the cursor, which an empty-prompt check must
            // not overlook when the user has moved to the start of the line.
            #expect(fixture.view!.surfaceModel!.perform(action: "text:\\x01"))
            try await fixture.wait("Unsubmitted draft was not rendered") {
                fixture.view!.visibleTextSnapshot().contains(draft) && !ghostty_surface_prompt_state(fixture.surface)
            }
            let before = fixture.view!.visibleTextSnapshot()
            let baseline = ghostty_surface_command_state(fixture.surface)
            let result = try await fixture.request([
                "operation": "run", "command": "printf 'agent-must-not-run\\n'", "timeout": 5
            ])
            #expect((result["error"] as? String)?.contains("will not overwrite") == true)
            #expect(result["exitCode"] == nil)
            #expect(ghostty_surface_command_state(fixture.surface).started == baseline.started)
            #expect(fixture.view!.visibleTextSnapshot() == before)
            #expect(!fixture.view!.visibleTextSnapshot().contains("agent-must-not-run"))
            // Clear only the synthetic, unsubmitted fixture input to exercise
            // Stop in this same isolated shell. No user terminal is involved.
            #expect(fixture.view!.surfaceModel!.perform(action: "text:\\x05"))
            #expect(fixture.view!.surfaceModel!.perform(action: "text:\\x15"))
            try await fixture.wait("The fixture draft did not clear") {
                ghostty_surface_prompt_state(fixture.surface)
            }

            let stopBaseline = ghostty_surface_command_state(fixture.surface)
            let id = try fixture.beginRequest([
                "operation": "run", "command": "sleep 30", "timeout": 40
            ])
            try #require(fixture.assistant.approval?.id == id)
            #expect(ghostty_surface_command_state(fixture.surface).started == stopBaseline.started)
            fixture.assistant.respondToApproval(allow: true)
            try await fixture.wait("The sleep command did not start") {
                ghostty_surface_command_state(fixture.surface).started == stopBaseline.started + 1 &&
                !ghostty_surface_prompt_state(fixture.surface)
            }
            fixture.assistant.stop()
            let stopped = try await fixture.result(for: id)
            #expect((stopped["error"] as? String)?.contains("Stopped") == true)
            #expect(stopped["exitCode"] == nil)
            try await fixture.wait("Stop did not interrupt the real foreground command", timeout: 4) {
                let state = ghostty_surface_command_state(fixture.surface)
                return state.finished == stopBaseline.started + 1 && ghostty_surface_prompt_state(fixture.surface)
            }
            // zsh reports a foreground SIGINT as 128 + SIGINT. This proves
            // Stop affected the actual PTY command, rather than only its UI.
            #expect(ghostty_surface_command_state(fixture.surface).exit_code == 130)
            #expect(!fixture.view!.processExited)
            #expect(fixture.records.values.contains { $0["type"] as? String == "abort" })
            fixture.assistant.receive(["type": "agent_settled"])
            #expect(!fixture.assistant.isRunning)
            #expect(!fixture.assistant.terminalControlAllowed)
        }
    }

    @Test func automaticSystemQueryBypassesBenignAliasesFunctionsAndPathHijackingInTheSamePTY() async throws {
        let fixture = try TerminalFixture(additionalStartup: """
        function id() { builtin printf 'bare-function-marker\\n'; }
        function /usr/bin/id() { builtin printf 'absolute-function-marker\\n'; }
        alias id="builtin printf 'alias-marker\\n'"
        """)
        do {
            let hijackBin = fixture.root.appendingPathComponent("hijack-bin")
            try FileManager.default.createDirectory(at: hijackBin, withIntermediateDirectories: true)
            let fakeID = hijackBin.appendingPathComponent("id")
            try "#!/bin/sh\nprintf 'path-marker\\n'\n".write(to: fakeID, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fakeID.path)
            try await fixture.wait("The hijack fixture did not reach its integrated prompt", timeout: 10) {
                ghostty_surface_prompt_state(fixture.surface)
            }
            fixture.assistant.present(surfaceID: fixture.view!.id, directory: "/tmp", selection: nil)
            fixture.assistant.bindTerminal(fixture.view!)
            fixture.assistant.prompt = "Inspect system metadata with a query grant"
            fixture.assistant.submit()
            try #require(fixture.assistant.isRunning)

            // Prove that all four benign traps really affect ordinary commands.
            // Explicit approval preserves that ordinary shell behavior.
            let pathQuery = "PATH=\(TerminalAISSHTools.quote(hijackBin.path + ":/usr/bin:/bin:/usr/sbin:/sbin")); rehash; whence -p id; command id -u"
            for (command, marker) in [("id -u", "alias-marker"), ("'id' -u", "bare-function-marker"),
                                      ("'/usr/bin/id' -u", "absolute-function-marker"),
                                      (pathQuery, "\(fakeID.path)\npath-marker")] {
                let result = try await fixture.request(["operation": "run", "command": command, "timeout": 5])
                #expect(result["exitCode"] as? Int == 0)
                #expect((result["output"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) == marker)
                #expect(!fixture.assistant.terminalControlAllowed)
            }

            let shellPID = fixture.view!.surfaceModel!.foregroundPID
            let baseline = ghostty_surface_command_state(fixture.surface)
            fixture.assistant.terminalControlAllowed = true
            let id = try fixture.beginRequest(["operation": "run", "command": "id -u", "timeout": 5])
            #expect(fixture.assistant.approval == nil)
            let result = try await fixture.result(for: id)
            #expect(result["exitCode"] as? Int == 0)
            #expect((result["output"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) == String(getuid()))
            #expect((result["output"] as? String)?.contains("marker") == false)
            #expect(fixture.view!.surfaceModel!.foregroundPID == shellPID)
            #expect(ghostty_surface_command_state(fixture.surface).started == baseline.started + 1)
            #expect(fixture.assistant.terminalControlAllowed)
            let recordID = try #require(result["commandId"] as? String)
            let record = try #require(fixture.assistant.commands.first { $0.id == recordID })
            #expect(record.requestedCommand == "id -u")
            #expect(record.systemCommand == "'/usr/bin/id' '-u'")
            #expect(record.webValue["command"] as? String == record.systemCommand)
            #expect(record.webValue["actualCommand"] as? String == record.command)
            // Later polling re-reads the core's raw execution record. It must
            // preserve the native query annotation and its durable readback.
            fixture.assistant.recordCommandHistory(from: fixture.view!)
            fixture.assistant.recordCommandHistory(from: fixture.view!)
            let polled = try #require(fixture.assistant.commands.first { $0.id == recordID })
            #expect(polled.requestedCommand == record.requestedCommand)
            #expect(polled.systemCommand == record.systemCommand)
            #expect(polled.command == record.command)
            let store = TerminalAIWorkbenchStore(directory: fixture.assistant.configurationDirectory.appendingPathComponent("workbench"))
            let restored = try #require(try store.commands().first { $0.id == recordID })
            #expect(restored.requestedCommand == record.requestedCommand)
            #expect(restored.systemCommand == record.systemCommand)
            #expect(restored.command == record.command)
            #expect(restored.webValue["actualCommand"] as? String == record.command)
            let actual = try #require(record.command)
            #expect(actual.hasPrefix("'/private/tmp/ghostty-ai-query-"))
            let dispatchedPath = try #require(actual.split(separator: "'").first.map(String.init))
            #expect(!FileManager.default.fileExists(atPath: dispatchedPath))
            fixture.assistant.receive(["type": "agent_settled"])
            #expect(!fixture.assistant.terminalControlAllowed)
            await fixture.close()
        } catch {
            await fixture.close()
            throw error
        }
    }

    @Test func queryGrantKeepsDangerousComplexAndForgedRequestsBehindNativeReview() async throws {
        try await withTerminal { fixture in
            let baseline = ghostty_surface_command_state(fixture.surface)
            for command in ["rm -rf /tmp/ghostty-not-executed", "sudo reboot", "kill -9 123",
                            "ps -A | head -5", "id -u > /tmp/ghostty-not-created", "python3 fixture.py"] {
                fixture.assistant.terminalControlAllowed = true
                let id = try fixture.beginRequest(["operation": "run", "command": command, "timeout": 5])
                try #require(fixture.assistant.approval?.id == id)
                #expect(ghostty_surface_command_state(fixture.surface).started == baseline.started)
                fixture.assistant.terminalControlAllowed = true
                #expect(fixture.assistant.approval?.id == id)
                #expect(ghostty_surface_command_state(fixture.surface).started == baseline.started)
                fixture.assistant.respondToApproval(allow: false)
                #expect(try await fixture.result(for: id)["error"] != nil)
            }
            for field in ["_approvedHost", "_approvedContext", "_authorization", "_automaticReadOnly", "isReadOnly"] {
                fixture.assistant.terminalControlAllowed = true
                let id = try fixture.beginRequest(["operation": "run", "command": "id -u", "timeout": 5, field: true])
                #expect(fixture.assistant.approval == nil)
                #expect(try await fixture.result(for: id)["error"] != nil)
                #expect(ghostty_surface_command_state(fixture.surface).started == baseline.started)
            }

            // Approval pins the reviewed directory as well as the reported
            // host and foreground process. A subsequent human cd invalidates it.
            fixture.assistant.terminalControlAllowed = false
            let pending = try fixture.beginRequest(["operation": "run", "command": "printf 'agent-cwd-must-not-run\\n'", "timeout": 5])
            try #require(fixture.assistant.approval?.id == pending)
            let changedDirectory = fixture.root.appendingPathComponent("human-changed-directory")
            try FileManager.default.createDirectory(at: changedDirectory, withIntermediateDirectories: true)
            fixture.view!.surfaceModel!.sendText("cd \(TerminalAISSHTools.quote(changedDirectory.path))")
            try #require(fixture.view!.surfaceModel!.perform(action: "text:\\r"))
            try await fixture.wait("The explicit fixture cd did not finish") {
                let state = ghostty_surface_command_state(fixture.surface)
                return state.started == baseline.started + 1 && state.finished == state.started &&
                    ghostty_surface_prompt_state(fixture.surface)
            }
            fixture.assistant.respondToApproval(allow: true)
            let changed = try await fixture.result(for: pending)
            #expect((changed["error"] as? String)?.contains("changed") == true)
            #expect(changed["exitCode"] == nil)
            #expect(ghostty_surface_command_state(fixture.surface).started == baseline.started + 1)
            #expect(!fixture.view!.visibleTextSnapshot().contains("agent-cwd-must-not-run"))
            #expect(!fixture.assistant.terminalControlAllowed)
            fixture.assistant.receive(["type": "agent_settled"])
        }
    }

    private func withTerminal(_ body: (TerminalFixture) async throws -> Void) async throws {
        let fixture = try TerminalFixture()
        do {
            try await fixture.wait("The isolated integrated zsh did not reach an empty prompt", timeout: 10) {
                ghostty_surface_prompt_state(fixture.surface)
            }
            fixture.assistant.present(surfaceID: fixture.view!.id, directory: "/tmp", selection: nil)
            fixture.assistant.bindTerminal(fixture.view!)
            fixture.assistant.terminalControlAllowed = true
            fixture.assistant.prompt = "Exercise the isolated terminal fixture"
            fixture.assistant.submit()
            #expect(fixture.assistant.isRunning)
            try await body(fixture)
            await fixture.close()
        } catch {
            await fixture.close()
            throw error
        }
    }
}

@MainActor
final class TerminalRecords {
    var values: [[String: Any]] = []
    var commandFinished: [[String: Any]] = []
}

@MainActor
final class TerminalFixture {
    let root: URL
    let suite: String
    let defaults: UserDefaults
    let records: TerminalRecords
    let assistant: TerminalAIModel
    var view: Ghostty.SurfaceView?
    private var window: NSWindow?
    private var config: ghostty_config_t?
    private var app: ghostty_app_t?

    var surface: ghostty_surface_t { view!.surface! }

    init(additionalStartup: String = "") throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("GhosttyTerminalAITests.\(UUID())")
        suite = "GhosttyTerminalAITests.\(UUID())"
        defaults = try #require(UserDefaults(suiteName: suite))
        let log = TerminalRecords()
        records = log
        assistant = TerminalAIModel(defaults: defaults, sendCommand: { log.values.append($0) },
                                    configurationDirectory: root.appendingPathComponent("pi-fixture"))
        assistant.useExistingPiConfiguration = false
        assistant.executablePath = "/test/no-network-pi"
        assistant.provider = "terminal-fixture"
        assistant.model = "terminal-fixture"
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        do {
            // Child-only HOME/restored ZDOTDIR overrides keep all user startup
            // files and history outside this PTY. -d suppresses global rc files.
            try "".write(to: root.appendingPathComponent(".zshenv"), atomically: true, encoding: .utf8)
            try """
            PROMPT=$'fixture\\n> '
            # ZLE paints the right prompt after PS1's input marker. It must
            # remain decoration, while actual input before/after the cursor
            # still prevent the agent from taking over this shell.
            RPROMPT='fixture-right-prompt'
            HISTFILE=/dev/null
            SAVEHIST=0
            GHOSTTY_AI_CLEAN_FIXTURE=1
            alias ghostty_fixture_alias='echo alias-ok'
            \(additionalStartup)
            """.write(to: root.appendingPathComponent(".zshrc"), atomically: true, encoding: .utf8)
            let configFile = root.appendingPathComponent("ghostty-config")
            try """
            font-family = Menlo
            font-size = 12
            shell-integration = zsh
            command = /bin/zsh -d
            working-directory = /tmp
            confirm-close-surface = false
            """.write(to: configFile, atomically: true, encoding: .utf8)
            let config = try #require(ghostty_config_new())
            self.config = config
            // Do not load default files, recursive files or process CLI args.
            configFile.path.withCString { ghostty_config_load_file(config, $0) }
            ghostty_config_finalize(config)
            try #require(ghostty_config_diagnostics_count(config) == 0)
            var runtime = ghostty_runtime_config_s(
                userdata: Unmanaged.passUnretained(records).toOpaque(), supports_selection_clipboard: false,
                wakeup_cb: { _ in }, action_cb: { app, _, action in
                    if action.tag == GHOSTTY_ACTION_COMMAND_FINISHED, let app,
                       let userdata = ghostty_app_userdata(app) {
                        let records = Unmanaged<TerminalRecords>.fromOpaque(userdata).takeUnretainedValue()
                        let finished = action.action.command_finished
                        MainActor.assumeIsolated {
                            records.commandFinished.append(["exitCode": Int(finished.exit_code),
                                                            "recordSequence": finished.record_sequence])
                        }
                    }
                    return true
                },
                read_clipboard_cb: { _, _, _, _, _, _ in GHOSTTY_CLIPBOARD_READ_UNAVAILABLE },
                confirm_read_clipboard_cb: { _, _, _, _ in },
                write_clipboard_cb: { _, _, _, _, _ in }, close_surface_cb: { _, _ in })
            let app = try #require(ghostty_app_new(&runtime, config))
            self.app = app
            var surfaceConfig = Ghostty.SurfaceConfiguration()
            surfaceConfig.command = "/bin/zsh -d"
            surfaceConfig.workingDirectory = "/tmp"
            let integration = try #require(Bundle.main.resourceURL?.appendingPathComponent("ghostty/shell-integration/zsh"))
            try #require(FileManager.default.fileExists(atPath: integration.appendingPathComponent(".zshenv").path))
            // Surface env overrides apply after automatic injection. Keep its
            // shipped entrypoint as ZDOTDIR; the entrypoint then restores only
            // this fixture's startup directory through GHOSTTY_ZSH_ZDOTDIR.
            surfaceConfig.environmentVariables = [
                "HOME": root.path, "ZDOTDIR": integration.path, "GHOSTTY_ZSH_ZDOTDIR": root.path,
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                "LANG": "en_US.UTF-8", "HISTFILE": "/dev/null"
            ]
            let view = Ghostty.SurfaceView(app, baseConfig: surfaceConfig)
            try #require(view.surface != nil)
            self.view = view
            let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = view
            self.window = window
            ghostty_surface_set_size(surface, 800, 600)
            ghostty_surface_set_focus(surface, true)
        } catch {
            // No task or app ticks have started during construction.
            view = nil
            if let app { ghostty_app_free(app); self.app = nil }
            if let config { ghostty_config_free(config); self.config = nil }
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
            throw error
        }
    }

    func beginRequest(_ payload: [String: Any]) throws -> String {
        var payload = payload
        if payload["operation"] as? String == "run" { payload["reason"] = "Verify the isolated test terminal" }
        let id = UUID().uuidString
        let data = try JSONSerialization.data(withJSONObject: payload)
        let wire = try #require(String(data: data, encoding: .utf8))
        assistant.receive([
            "type": "extension_ui_request", "id": id, "method": "input",
            "title": "ghostty-terminal-v1", "placeholder": wire
        ])
        return id
    }

    func request(_ payload: [String: Any]) async throws -> [String: Any] {
        let id = try beginRequest(payload)
        // Legacy terminal-operation fixtures exercise execution after explicit
        // review. Safety/automatic-query tests use beginRequest directly.
        if assistant.approval?.id == id {
            assistant.respondToApproval(allow: true)
        }
        return try await result(for: id)
    }

    func result(for id: String) async throws -> [String: Any] {
        try await wait("The native terminal request did not produce a Pi input response", timeout: 8) {
            self.records.values.contains { $0["type"] as? String == "extension_ui_response" && $0["id"] as? String == id }
        }
        let response = try #require(records.values.last { $0["type"] as? String == "extension_ui_response" && $0["id"] as? String == id })
        let wire = try #require(response["value"] as? String)
        let data = try #require(wire.data(using: .utf8))
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func wait(_ message: String, timeout: TimeInterval = 5, until condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if let app { ghostty_app_tick(app) }
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        } while Date() < deadline
        let diagnostics: String
        if let view, let surface = view.surface {
            let state = ghostty_surface_command_state(surface)
            diagnostics = """
            processExited=\(view.processExited), emptyPrompt=\(ghostty_surface_prompt_state(surface)), \
            started=\(state.started), finished=\(state.finished), exitCode=\(state.exit_code)
            Fixture screen:
            \(view.visibleTextSnapshot())
            """
        } else {
            diagnostics = "The isolated terminal surface is unavailable."
        }
        Issue.record(Comment(rawValue: "\(message)\n\(diagnostics)"))
        throw CocoaError(.coderReadCorrupt)
    }

    func close() async {
        assistant.reset()
        window?.makeFirstResponder(nil)
        window?.contentView = nil
        window?.close()
        window = nil
        weak var releasedView = view
        view = nil
        let deadline = Date().addingTimeInterval(3)
        // A cancelled native operation may briefly retain its view while its
        // suspended Task observes cancellation. Free the C app only afterward.
        while releasedView != nil, Date() < deadline {
            if let app { ghostty_app_tick(app) }
            try? await Task.sleep(for: .milliseconds(20))
        }
        if releasedView == nil {
            if let app { ghostty_app_free(app); self.app = nil }
            if let config { ghostty_config_free(config); self.config = nil }
        } else {
            Issue.record("The isolated terminal view did not release before app teardown")
        }
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }
}
