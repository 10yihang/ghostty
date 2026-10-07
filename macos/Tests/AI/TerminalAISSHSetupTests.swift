import Foundation
import GhosttyKit
import Testing
@testable import Ghostty

/// The same PTY runs a nested shell with no integration, then the real bundled
/// setup command. The reported host is synthetic; these are not SSH transport
/// tests and never use a user's shell files or a real remote machine.
@Suite(.serialized)
@MainActor
struct TerminalAISSHSetupTests {
    @Test func zshSetupRecoversAnUnintegratedShellAndApprovedAIUsesThatSameShell() async throws {
        try await recoverUnintegratedShell("zsh")
    }

    @Test func bashSetupRecoversAnUnintegratedShellAndApprovedAIUsesThatSameShell() async throws {
        try await recoverUnintegratedShell("bash")
    }

    private func recoverUnintegratedShell(_ shell: String) async throws {
        let fixture = try TerminalFixture()
        do {
            try await fixture.wait("The initial integrated fixture did not reach its prompt", timeout: 10) {
                ghostty_surface_prompt_state(fixture.surface)
            }
            fixture.assistant.present(surfaceID: fixture.view!.id, directory: "/tmp", selection: nil)
            fixture.assistant.bindTerminal(fixture.view!)
            let originalZshrc = fixture.root.appendingPathComponent(".zshrc")
            let originalZshenv = fixture.root.appendingPathComponent(".zshenv")
            let originalFiles = [originalZshrc: try Data(contentsOf: originalZshrc),
                                 originalZshenv: try Data(contentsOf: originalZshenv)]
            let nested = fixture.root.appendingPathComponent("unintegrated-\(shell)")
            let setupTemporaryDirectory = nested.appendingPathComponent("temporary")
            try FileManager.default.createDirectory(at: setupTemporaryDirectory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            let remoteHost = "ghostty-ai-setup-\(shell).invalid"
            let prompt = "unintegrated-\(shell)-fixture> "
            let marker = "setup-\(shell)-same-shell"
            let startup = nested.appendingPathComponent(shell == "zsh" ? ".zshrc" : ".bashrc")
            let startupText: String
            let entry: String
            if shell == "zsh" {
                try "".write(to: nested.appendingPathComponent(".zshenv"), atomically: true, encoding: .utf8)
                startupText = """
                PROMPT=\(TerminalAISSHTools.quote(prompt))
                RPROMPT=''
                HOST=\(TerminalAISSHTools.quote(remoteHost))
                HISTFILE=/dev/null
                SAVEHIST=0
                export TMPDIR=\(TerminalAISSHTools.quote(setupTemporaryDirectory.path))
                GHOSTTY_AI_REMOTE_STYLE=\(TerminalAISSHTools.quote(marker))
                cd \(TerminalAISSHTools.quote(nested.path))
                """
                entry = "ZDOTDIR=\(TerminalAISSHTools.quote(nested.path)) /bin/zsh -d"
            } else {
                startupText = """
                PS1=\(TerminalAISSHTools.quote(prompt))
                PS2='continuation> '
                HOSTNAME=\(TerminalAISSHTools.quote(remoteHost))
                HISTFILE=/dev/null
                HISTFILESIZE=0
                export TMPDIR=\(TerminalAISSHTools.quote(setupTemporaryDirectory.path))
                GHOSTTY_AI_REMOTE_STYLE=\(TerminalAISSHTools.quote(marker))
                cd \(TerminalAISSHTools.quote(nested.path))
                """
                entry = "/bin/bash --noprofile --rcfile \(TerminalAISSHTools.quote(startup.path)) -i"
            }
            try startupText.write(to: startup, atomically: true, encoding: .utf8)
            let startupBefore = try Data(contentsOf: startup)
            try sendHumanInput(entry, fixture: fixture)
            try await fixture.wait("The unintegrated nested shell did not show its raw prompt", timeout: 10) {
                fixture.view!.visibleTextSnapshot().contains(prompt)
            }
            // The parent shell's integration state must not falsely certify
            // this new foreground shell's unmarked input as an empty prompt.
            #expect(!ghostty_surface_prompt_state(fixture.surface))

            // A query grant cannot certify this nested shell or replace its
            // missing integration. Even explicit approval must still block run.
            fixture.assistant.recordCommandHistory(from: fixture.view!)
            fixture.assistant.prompt = "Inspect this idle nested shell"
            fixture.assistant.submit()
            fixture.assistant.terminalControlAllowed = true
            let blockedBaseline = ghostty_surface_command_state(fixture.surface)
            let blocked = try await fixture.request(["operation": "run", "command": "printf 'must-not-run-before-integration\\n'", "timeout": 5])
            #expect((blocked["error"] as? String)?.contains("does not bypass") == true)
            #expect((blocked["error"] as? String)?.contains("Connect shell") == true)
            #expect(ghostty_surface_command_state(fixture.surface).started == blockedBaseline.started)
            #expect(!fixture.view!.visibleTextSnapshot().contains("must-not-run-before-integration"))
            #expect(fixture.assistant.terminalIdentity["canSetupShell"] as? Bool == true)
            fixture.assistant.receive(["type": "agent_settled"])

            let resources = try #require(Bundle.main.resourceURL?.appendingPathComponent("ghostty/shell-integration"))
            let bootstrap = try TerminalAISSHTools.bootstrap(shell: shell, resources: resources)
            #expect(bootstrap.utf8.count <= 16_384)
            #expect(!bootstrap.unicodeScalars.contains { $0.value < 32 })
            // This models the explicit human paste/Enter described by the
            // setup UI, rather than bypassing the AI's prompt safety checks.
            try sendHumanInput(bootstrap, fixture: fixture)
            try await fixture.wait("Bundled \(shell) setup did not establish the remote-style integrated prompt", timeout: 12) {
                guard let snapshot = try? identity(fixture) else { return false }
                return snapshot["host"] as? String == remoteHost &&
                    snapshot["hostIsLocal"] as? Bool == false && ghostty_surface_prompt_state(fixture.surface)
            }
            fixture.assistant.recordCommandHistory(from: fixture.view!)
            let remoteDirectory = try #require(identity(fixture)["directory"] as? String)
            #expect(remoteDirectory != fixture.view!.pwd)
            #expect(fixture.assistant.terminalIdentity["host"] as? String == remoteHost)
            #expect(fixture.assistant.terminalIdentity["isRemote"] as? Bool == true)
            #expect(fixture.assistant.terminalIdentity["canRun"] as? Bool == true)
            #expect(!fixture.assistant.terminalControlAllowed)
            #expect(try Data(contentsOf: startup) == startupBefore)
            for (path, data) in originalFiles { #expect(try Data(contentsOf: path) == data) }
            let setupFiles = try FileManager.default.contentsOfDirectory(at: setupTemporaryDirectory, includingPropertiesForKeys: nil)
            #expect(!setupFiles.isEmpty)

            // Even a known read-only query cannot use automatic approval on
            // an SSH/root-style nested target. No real remote host is involved.
            fixture.assistant.prompt = "Review a read-only query on this nested target"
            fixture.assistant.submit()
            fixture.assistant.terminalControlAllowed = true
            let queryBaseline = ghostty_surface_command_state(fixture.surface)
            let queryID = try fixture.beginRequest(["operation": "run", "command": "id -u", "timeout": 5])
            try #require(fixture.assistant.approval?.id == queryID)
            #expect(fixture.assistant.approval?.message.contains(remoteHost) == true)
            #expect(ghostty_surface_command_state(fixture.surface).started == queryBaseline.started)
            fixture.assistant.terminalControlAllowed = true
            #expect(fixture.assistant.approval?.id == queryID)
            fixture.assistant.respondToApproval(allow: false)
            #expect(try await fixture.result(for: queryID)["error"] != nil)
            #expect(ghostty_surface_command_state(fixture.surface).started == queryBaseline.started)
            fixture.assistant.receive(["type": "agent_settled"])
            #expect(!fixture.assistant.terminalControlAllowed)

            if shell == "zsh" {
                try await verifyRemoteContextAttachments(fixture: fixture, directory: nested,
                                                         host: remoteHost, reportedDirectory: remoteDirectory)
            }

            fixture.assistant.prompt = "Verify the shell I have explicitly set up"
            fixture.assistant.submit()
            try #require(fixture.assistant.isRunning)
            let screen = try await fixture.request(["operation": "read"])
            #expect(screen["host"] as? String == remoteHost)
            #expect(screen["cwd"] as? String == remoteDirectory)
            let command = "printf '%s\\n' \"$GHOSTTY_AI_REMOTE_STYLE\""
            let before = ghostty_surface_command_state(fixture.surface)
            let requestID = try fixture.beginRequest(["operation": "run", "command": command, "timeout": 5])
            try #require(fixture.assistant.approval?.id == requestID)
            #expect(fixture.assistant.approval?.message.contains(remoteHost) == true)
            #expect(fixture.assistant.approval?.message.contains("Reported directory: \(remoteDirectory)") == true)
            #expect(ghostty_surface_command_state(fixture.surface).started == before.started)
            fixture.assistant.respondToApproval(allow: true)
            let result = try await fixture.result(for: requestID)
            #expect(result["exitCode"] as? Int == 0)
            #expect((result["output"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) == marker)
            #expect(result["host"] as? String == remoteHost)
            #expect(result["cwd"] as? String == remoteDirectory)
            let recordID = try #require(result["commandId"] as? String)
            let record = try #require(fixture.assistant.commands.first { $0.id == recordID })
            #expect(record.command == command)
            #expect(record.host == remoteHost)
            #expect(record.directory == remoteDirectory)
            #expect(record.hostIsLocal == false)
            #expect(record.output == marker)
            #expect(record.exitCode == 0)
            #expect(ghostty_surface_command_state(fixture.surface).started == before.started + 1)
            #expect(!fixture.assistant.terminalControlAllowed)
            #expect(try Data(contentsOf: startup) == startupBefore)
            for (path, data) in originalFiles { #expect(try Data(contentsOf: path) == data) }
            fixture.assistant.receive(["type": "agent_settled"])
            await fixture.close()
        } catch {
            await fixture.close()
            throw error
        }
    }

    private func verifyRemoteContextAttachments(fixture: TerminalFixture, directory: URL,
                                                host: String, reportedDirectory: String) async throws {
        let diagnostic = directory.appendingPathComponent("diagnostic.txt")
        let log = directory.appendingPathComponent("build.log")
        let fileText = "remote file fixture only"
        let logText = String(repeating: "discarded older diagnostic line\n", count: 1_500) + "latest remote failure fixture"
        #expect(logText.utf8.count > 32_768 && logText.utf8.count < 65_536)
        let instructions = "remote project instructions fixture"
        let originalReadme = "original tracked project fixture\n"
        let changedReadme = "modified tracked project fixture\n"
        try fileText.write(to: diagnostic, atomically: true, encoding: .utf8)
        try logText.write(to: log, atomically: true, encoding: .utf8)
        try instructions.write(to: directory.appendingPathComponent("AGENTS.md"), atomically: true, encoding: .utf8)
        let readme = directory.appendingPathComponent("README.md")
        try originalReadme.write(to: readme, atomically: true, encoding: .utf8)
        let template = directory.appendingPathComponent("empty-git-template")
        try FileManager.default.createDirectory(at: template, withIntermediateDirectories: true)
        let seed = "unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_CONFIG GIT_CONFIG_PARAMETERS; " +
            "export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_COUNT=0; " +
            "git -c init.defaultBranch=main -c init.templateDir=\(TerminalAISSHTools.quote(template.path)) -c core.hooksPath=/dev/null init -q && " +
            "git -c core.hooksPath=/dev/null add -- README.md && " +
            "git -c core.hooksPath=/dev/null -c commit.gpgsign=false -c user.name='Ghostty fixture' -c user.email=fixture@example.invalid commit -q -m fixture"
        let seedBaseline = ghostty_surface_command_state(fixture.surface)
        try sendHumanInput(seed, fixture: fixture)
        try await fixture.wait("The isolated remote-style Git fixture did not finish seeding", timeout: 10) {
            let state = ghostty_surface_command_state(fixture.surface)
            return state.started == seedBaseline.started + 1 && state.finished == state.started &&
                ghostty_surface_prompt_state(fixture.surface)
        }
        #expect(ghostty_surface_command_state(fixture.surface).exit_code == 0)
        try changedReadme.write(to: readme, atomically: true, encoding: .utf8)

        for (kind, path) in [("file", Optional(diagnostic.path)), ("log", Optional(log.path)),
                             ("project", nil), ("git_diff", nil)] {
            let before = ghostty_surface_command_state(fixture.surface)
            let previousCount = fixture.assistant.attachments.count
            fixture.assistant.attachContext(kind: kind, path: path)
            try #require(fixture.assistant.approval != nil)
            #expect(fixture.assistant.approval?.message.contains(host) == true)
            #expect(fixture.assistant.approval?.message.contains("Reported directory: \(reportedDirectory)") == true)
            #expect(ghostty_surface_command_state(fixture.surface).started == before.started)
            #expect(fixture.assistant.attachments.count == previousCount)
            fixture.assistant.respondToApproval(allow: true)
            try await fixture.wait("The approved remote-style \(kind) read did not become an attachment", timeout: 10) {
                !fixture.assistant.isRunning && fixture.assistant.attachments.count == previousCount + 1
            }
            let attachment = try #require(fixture.assistant.attachments.last)
            #expect(attachment.kind == kind)
            #expect(attachment.host == host)
            #expect(attachment.text.utf8.count <= 65_536)
            #expect(attachment.scope?.contains("KiB") == true)
            #expect(ghostty_surface_command_state(fixture.surface).finished == before.started + 1)
            #expect(!fixture.assistant.terminalControlAllowed)
            switch kind {
            case "file":
                #expect(attachment.source == diagnostic.path)
                #expect(attachment.text == fileText)
            case "log":
                #expect(attachment.source == log.path)
                #expect(attachment.text == logText)
                #expect(attachment.text.hasSuffix("latest remote failure fixture"))
                #expect(!attachment.truncated)
                #expect(attachment.scope?.contains("Last") == true)
                #expect(attachment.webValue["previewTruncated"] as? Bool == true)
            case "project":
                #expect(attachment.source == "Current terminal project instructions")
                #expect(attachment.text.contains("File: AGENTS.md"))
                #expect(attachment.text.contains(instructions))
                #expect(attachment.text.contains("File: README.md"))
                #expect(attachment.text.contains(changedReadme.trimmingCharacters(in: .newlines)))
            case "git_diff":
                #expect(attachment.source == "Tracked working changes relative to HEAD")
                #expect(attachment.text.contains("diff --git a/README.md b/README.md"))
                #expect(attachment.text.contains("-original tracked project fixture"))
                #expect(attachment.text.contains("+modified tracked project fixture"))
                #expect(!attachment.text.contains(fileText))
            default: break
            }
        }
    }

    private func sendHumanInput(_ command: String, fixture: TerminalFixture) throws {
        let surfaceModel = try #require(fixture.view?.surfaceModel)
        surfaceModel.sendText(command)
        try #require(surfaceModel.perform(action: "text:\\r"))
    }

    private func identity(_ fixture: TerminalFixture) throws -> [String: Any] {
        var text = ghostty_text_s()
        try #require(ghostty_surface_read_terminal_identity(fixture.surface, &text))
        defer { ghostty_surface_free_text(fixture.surface, &text) }
        let bytes = try #require(text.text)
        return try #require(JSONSerialization.jsonObject(with: Data(bytes: bytes, count: Int(text.text_len))) as? [String: Any])
    }
}
