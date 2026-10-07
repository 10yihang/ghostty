import Darwin
import Foundation
import GhosttyKit
import Testing
@testable import Ghostty

@Suite(.serialized)
@MainActor
struct TerminalAITerminalAuthorizationTests {
    @Test func kernelFactsAllowOnlyTheDirectOrdinaryShellAndItsLoginParent() throws {
        let surface = UUID()
        let direct = try process(["parentPID": 10])
        let identity = try #require(TerminalAITerminalAuthorization.validate(
            process: direct, parent: nil, surfaceID: surface, appPID: 10, userID: 502))
        #expect(identity.process.path == "/bin/zsh")
        #expect(identity.parent == nil)
        #expect(try JSONDecoder().decode(TerminalAITerminalAuthorization.Identity.self,
                                        from: JSONEncoder().encode(identity)) == identity)

        let loginShell = try process([:])
        let login = try parent([:])
        let wrapped = try #require(TerminalAITerminalAuthorization.validate(
            process: loginShell, parent: login, surfaceID: surface, appPID: 10, userID: 502))
        #expect(wrapped.parent?.path == "/usr/bin/login")
        #expect(wrapped != identity)
        let reused = try process(["parentPID": 10, "startMicroseconds": 2])
        #expect(TerminalAITerminalAuthorization.validate(
            process: reused, parent: nil, surfaceID: surface, appPID: 10, userID: 502) != identity)
    }

    @Test func unknownRootNestedOrUnverifiableProcessesFailClosed() throws {
        let failures: [[String: Any]] = [
            ["uid": 0], ["realUID": 0], ["savedUID": 0], ["uid": 503],
            ["pid": 0], ["processGroup": 99], ["foregroundGroup": 99],
            ["ttyDevice": UInt32.max], ["startSeconds": 0], ["startMicroseconds": 1_000_000],
            ["path": "/usr/bin/ssh"], ["path": "/usr/local/bin/zsh"], ["path": ""],
            ["parentPID": 99]
        ]
        for change in failures {
            #expect(TerminalAITerminalAuthorization.validate(
                process: try process(change), parent: try parent([:]), surfaceID: UUID(), appPID: 10, userID: 502) == nil)
        }
        let invalidParents: [[String: Any]] = [
            ["pid": 99], ["parentPID": 99], ["path": "/bin/zsh"], ["path": "/usr/bin/sudo"],
            ["uid": 503], ["ttyDevice": 99], ["startSeconds": 101], ["startSeconds": 0],
            ["startMicroseconds": 1_000_000]
        ]
        for change in invalidParents {
            #expect(TerminalAITerminalAuthorization.validate(
                process: try process([:]), parent: try parent(change), surfaceID: UUID(), appPID: 10, userID: 502) == nil)
        }
        #expect(TerminalAITerminalAuthorization.validate(
            process: try process([:]), parent: nil, surfaceID: UUID(), appPID: 10, userID: 502) == nil)
        #expect(TerminalAITerminalAuthorization.validate(
            process: try process([:]), parent: try parent([:]), surfaceID: UUID(), appPID: 10, userID: 0) == nil)
    }

    @Test func realPTYAllowsTheLocalShellButRejectsAnUnintegratedNestedBash() async throws {
        try await withFixture { fixture in
            let original = try #require(TerminalAITerminalAuthorization.snapshot(view: fixture.view!))
            #expect(original.process.uid == getuid())
            #expect(original.process.realUID == getuid())
            #expect(original.process.savedUID == getuid())
            #expect(original.process.path == "/bin/zsh")
            #expect(original.process.pid == original.process.foregroundGroup)
            #expect(TerminalAITerminalAuthorization.snapshot(view: fixture.view!) == original)
            try send("PS1='nested-bash> ' /bin/bash --noprofile --norc -i", fixture: fixture)
            try await fixture.wait("The isolated nested Bash did not become the foreground shell", timeout: 10) {
                fixture.view?.surfaceModel?.foregroundPID != Int(original.process.pid) &&
                    foregroundExecutable(fixture) == "/bin/bash" &&
                    fixture.view!.visibleTextSnapshot().contains("nested-bash> ")
            }
            #expect(TerminalAITerminalAuthorization.context(view: fixture.view!)?.path == "/bin/bash")
            #expect(TerminalAITerminalAuthorization.snapshot(view: fixture.view!) == nil)
            try send("exit", fixture: fixture)
            try await fixture.wait("The direct local shell did not return", timeout: 10) {
                ghostty_surface_prompt_state(fixture.surface) &&
                    TerminalAITerminalAuthorization.snapshot(view: fixture.view!) == original
            }
        }
    }

    @Test func aReportedRemoteHostCannotAuthorizeALocalNestedShell() async throws {
        try await withFixture { fixture in
            let original = try #require(TerminalAITerminalAuthorization.snapshot(view: fixture.view!))
            let nested = fixture.root.appendingPathComponent("nested-risk-context")
            try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
            try "".write(to: nested.appendingPathComponent(".zshenv"), atomically: true, encoding: .utf8)
            let integration = try #require(Bundle.main.resourceURL?.appendingPathComponent("ghostty/shell-integration/zsh/ghostty-integration"))
            try """
            PROMPT='nested-risk> '
            RPROMPT=''
            HISTFILE=/dev/null
            SAVEHIST=0
            source \(TerminalAISSHTools.quote(integration.path))
            HOST=ghostty-risk-context-remote.invalid
            """.write(to: nested.appendingPathComponent(".zshrc"), atomically: true, encoding: .utf8)
            try send("ZDOTDIR=\(TerminalAISSHTools.quote(nested.path)) /bin/zsh -d", fixture: fixture)
            try await fixture.wait("The nested shell did not publish its synthetic remote identity", timeout: 10) {
                reportedHost(fixture) == "ghostty-risk-context-remote.invalid" && ghostty_surface_prompt_state(fixture.surface)
            }
            #expect(fixture.view?.surfaceModel?.foregroundPID != Int(original.process.pid))
            #expect(TerminalAITerminalAuthorization.context(view: fixture.view!)?.path == "/bin/zsh")
            #expect(TerminalAITerminalAuthorization.snapshot(view: fixture.view!) == nil)
            try send("exit", fixture: fixture)
            try await fixture.wait("The original process identity did not return", timeout: 10) {
                ghostty_surface_prompt_state(fixture.surface) &&
                    TerminalAITerminalAuthorization.snapshot(view: fixture.view!) == original
            }
        }
    }

    private func process(_ changes: [String: Any]) throws -> TerminalAITerminalAuthorization.ProcessFacts {
        var facts: [String: Any] = ["pid": 30, "parentPID": 20, "uid": 502, "realUID": 502, "savedUID": 502,
                                  "processGroup": 30, "foregroundGroup": 30, "ttyDevice": 7,
                                  "startSeconds": 100, "startMicroseconds": 1, "path": "/bin/zsh"]
        facts.merge(changes) { _, new in new }
        return try JSONDecoder().decode(TerminalAITerminalAuthorization.ProcessFacts.self,
                                        from: JSONSerialization.data(withJSONObject: facts))
    }

    private func parent(_ changes: [String: Any]) throws -> TerminalAITerminalAuthorization.ParentFacts {
        var facts: [String: Any] = ["pid": 20, "parentPID": 10, "uid": 0, "ttyDevice": 7,
                                  "startSeconds": 99, "startMicroseconds": 1, "path": "/usr/bin/login"]
        facts.merge(changes) { _, new in new }
        return try JSONDecoder().decode(TerminalAITerminalAuthorization.ParentFacts.self,
                                        from: JSONSerialization.data(withJSONObject: facts))
    }

    private func send(_ command: String, fixture: TerminalFixture) throws {
        let surfaceModel = try #require(fixture.view?.surfaceModel)
        surfaceModel.sendText(command)
        try #require(surfaceModel.perform(action: "text:\\r"))
    }

    private func reportedHost(_ fixture: TerminalFixture) -> String? {
        var text = ghostty_text_s()
        guard ghostty_surface_read_terminal_identity(fixture.surface, &text) else { return nil }
        defer { ghostty_surface_free_text(fixture.surface, &text) }
        guard let data = String(cString: text.text).data(using: .utf8),
              let identity = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return identity["host"] as? String
    }

    private func foregroundExecutable(_ fixture: TerminalFixture) -> String? {
        guard let rawPID = fixture.view?.surfaceModel?.foregroundPID, let pid = Int32(exactly: rawPID) else { return nil }
        var bytes = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &bytes, UInt32(bytes.count)) > 0 else { return nil }
        return String(cString: bytes)
    }

    private func withFixture(_ body: (TerminalFixture) async throws -> Void) async throws {
        let fixture = try TerminalFixture()
        do {
            try await fixture.wait("The isolated shell did not reach its own local prompt", timeout: 10) {
                ghostty_surface_prompt_state(fixture.surface) &&
                    TerminalAITerminalAuthorization.snapshot(view: fixture.view!) != nil
            }
            try await body(fixture)
            await fixture.close()
        } catch {
            await fixture.close()
            throw error
        }
    }
}
