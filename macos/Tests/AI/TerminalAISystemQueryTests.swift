import Darwin
import Foundation
import Testing
@testable import Ghostty

struct TerminalAISystemQueryTests {
    @Test func freshPrivateLinkPinsTheSystemPathAndIsCleanedUp() throws {
        let query = try TerminalAISystemQuery(assessment: TerminalAICommandPolicy.assess("id -u"))
        defer { query.cleanup() }
        #expect(query.directory.deletingLastPathComponent().path == "/private/tmp")
        #expect(query.directory.lastPathComponent.hasPrefix("ghostty-ai-query-"))
        #expect(query.executableURL.lastPathComponent == "id")
        let attributes = try FileManager.default.attributesOfItem(atPath: query.directory.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
        #expect(try FileManager.default.contentsOfDirectory(atPath: query.directory.path) == ["id"])
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: query.executableURL.path) == "/usr/bin/id")
        #expect(query.command == "'\(query.executableURL.path)' '-u'")
        #expect(query.systemCommand == "'/usr/bin/id' '-u'")
        query.cleanup()
        #expect(!FileManager.default.fileExists(atPath: query.directory.path))
        query.cleanup()
        #expect(!FileManager.default.fileExists(atPath: query.directory.path))
    }

    @Test func eachCallUsesANewPathAndDeinitAlsoCleansIt() throws {
        var paths = Set<String>()
        for _ in 0..<12 {
            let query = try TerminalAISystemQuery(assessment: TerminalAICommandPolicy.assess("uname -m"))
            #expect(paths.insert(query.executableURL.path).inserted)
            query.cleanup()
        }
        let directory = try makeTemporaryQuery()
        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }

    @Test func reassessmentRejectsForgedAuthorityOrUnsafeArguments() {
        let invalid: [TerminalAICommandPolicy.Assessment] = [
            .init(isReadOnly: false, reason: "requires approval", executable: "/usr/bin/id", arguments: ["-u"]),
            .init(isReadOnly: true, reason: "forged", executable: nil, arguments: []),
            .init(isReadOnly: true, reason: "forged", executable: "/tmp/id", arguments: ["-u"]),
            .init(isReadOnly: true, reason: "forged", executable: "id", arguments: ["-u"]),
            .init(isReadOnly: true, reason: "forged", executable: "/bin/rm", arguments: ["-rf", "/tmp/x"]),
            .init(isReadOnly: true, reason: "forged", executable: "/bin/ls", arguments: ["$(id)"]),
            .init(isReadOnly: true, reason: "forged", executable: "/bin/ls", arguments: ["file; id"]),
            .init(isReadOnly: true, reason: "forged", executable: "/usr/bin/id", arguments: ["-x"]),
            .init(isReadOnly: true, reason: "forged", executable: "/bin/ls", arguments: ["both'and\"quotes"])
        ]
        for assessment in invalid {
            #expect(throws: (any Error).self) { try TerminalAISystemQuery(assessment: assessment) }
        }
    }

    @Test func literalArgumentsAreSingleQuotedIncludingEmbeddedApostrophes() throws {
        let assessment = TerminalAICommandPolicy.assess("ls -- \"it's 中文.txt\"")
        #expect(assessment.isReadOnly)
        let query = try TerminalAISystemQuery(assessment: assessment)
        defer { query.cleanup() }
        #expect(query.systemCommand == "'/bin/ls' '--' 'it'\\''s 中文.txt'")
        #expect(query.command == "'\(query.executableURL.path)' '--' 'it'\\''s 中文.txt'")
    }

    @Test func existingShellFunctionsAliasesAndPATHCannotReplaceTheFreshQuery() throws {
        for (shell, arguments) in [("/bin/bash", ["--noprofile", "--norc", "-c"]), ("/bin/zsh", ["-f", "-c"])] {
            let query = try TerminalAISystemQuery(assessment: TerminalAICommandPolicy.assess("id -u"))
            defer { query.cleanup() }
            let enableAliases = shell == "/bin/bash" ? "shopt -s expand_aliases" : ""
            let script = """
            \(enableAliases)
            function /usr/bin/id { printf 'absolute-function-override\\n'; }
            /usr/bin/id -u
            alias id='printf alias-override\\\\n'
            function id { printf 'named-function-override\\n'; }
            function command { printf 'command-function-override\\n'; }
            function builtin { printf 'builtin-function-override\\n'; }
            PATH=/ghostty-fixture-no-executables
            \(query.command)
            """
            let result = try run(shell: shell, arguments: arguments + [script])
            #expect(result.status == 0)
            #expect(result.output == "absolute-function-override\n\(getuid())\n")
        }
    }

    private func makeTemporaryQuery() throws -> URL {
        let query = try TerminalAISystemQuery(assessment: TerminalAICommandPolicy.assess("uname -a"))
        return query.directory
    }

    private func run(shell: String, arguments: [String]) throws -> (status: Int32, output: String) {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = arguments
        process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "C", "HOME": "/private/tmp"]
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = try output.fileHandleForReading.readToEnd() ?? Data()
        process.waitUntilExit()
        return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }
}
