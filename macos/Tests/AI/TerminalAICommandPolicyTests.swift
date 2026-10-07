import Foundation
import Testing
@testable import Ghostty

struct TerminalAICommandPolicyTests {
    @Test func knownMetadataQueriesReturnExpectedSystemPathAndLiteralArguments() {
        let cases: [(String, String, [String])] = [
            ("ps -Ao pid,%cpu,%mem,etime,command -r", "/bin/ps", ["-Ao", "pid,%cpu,%mem,etime,command", "-r"]),
            ("ps aux", "/bin/ps", ["aux"]),
            ("ps -p1,23 -o pid,command", "/bin/ps", ["-p1,23", "-o", "pid,command"]),
            ("/bin/ps -U root,admin -t ttys001", "/bin/ps", ["-U", "root,admin", "-t", "ttys001"]),
            ("uname -amr", "/usr/bin/uname", ["-amr"]),
            ("id -un admin", "/usr/bin/id", ["-un", "admin"]),
            ("/usr/bin/id -G", "/usr/bin/id", ["-G"]),
            ("whoami", "/usr/bin/whoami", []),
            ("uptime", "/usr/bin/uptime", []),
            ("ls -lah '/Library/Application Support'", "/bin/ls", ["-lah", "/Library/Application Support"]),
            ("ls -- -strange-file", "/bin/ls", ["--", "-strange-file"]),
            ("df -h /", "/bin/df", ["-h", "/"]),
            ("  '/bin/ls' \"中文目录 name\"  ", "/bin/ls", ["中文目录 name"])
        ]
        for (command, executable, arguments) in cases {
            let assessment = TerminalAICommandPolicy.assess(command)
            #expect(assessment.isReadOnly, "\(command): \(assessment.reason)")
            #expect(assessment.executable == executable)
            #expect(assessment.arguments == arguments)
            #expect(!assessment.reason.isEmpty)
        }
    }

    @Test func allShellCompositionAndExpansionRequiresIndividualApproval() {
        let commands = [
            "ps -A | head -20", "ps -A; rm -rf /tmp/x", "ps -A && rm /tmp/x", "ps -A || true",
            "ps -A > /tmp/result", "ps -A 2>&1", "ps -A &", "(ps -A)", "{ ps -A; }", "ps -A # comment",
            "ls $(touch /tmp/x)", "ls `touch /tmp/x`", "ls $HOME", "ls ${HOME}", "ls <(id)", "ls >(id)",
            "ls *.log", "ls ?", "ls [abc]", "ls ~", "ls ^file", "ls {a,b}", "ps !-1", "LC_ALL=C ps -A",
            "l's'", "p\"s\"", "\\ps -A", "ps\\ -A", "ps -A\\\nrm /tmp/x", "ls '\\x'",
            "ls '$HOME'", "ls '$(id)'", "ls \"`id`\"", "ls 'x;y'", "ls \"a|b\""
        ]
        for command in commands { expectApproval(command) }
    }

    @Test func dangerousCommandsHaveNativeReasonAndCannotMasqueradeAsDiagnostics() {
        let cases = [
            "rm -rf /tmp/x": "Deleting", "/bin/rm -i /tmp/x": "Deleting", "truncate -s 0 /tmp/x": "truncating",
            "sudo ps -A": "privileges", "su root": "privileges", "chmod 777 /tmp/x": "permissions",
            "tee /tmp/x": "files", "kill -9 123": "processes", "systemctl restart nginx": "services",
            "reboot": "machine", "psql -c 'DROP TABLE users'": "Database", "python3 script.py": "Scripts",
            "command ps -A": "wrappers", "builtin command ps -A": "wrappers", "env ps -A": "wrappers"
        ]
        for (command, reason) in cases {
            let assessment = TerminalAICommandPolicy.assess(command)
            #expect(!assessment.isReadOnly)
            #expect(assessment.reason.contains(reason))
            #expect(assessment.executable == nil)
            #expect(assessment.arguments.isEmpty)
        }
    }

    @Test func unknownCommandsAndExecutablePathsRemainApprovalOnly() {
        for command in [
            "git status", "git diff", "find . -delete", "rg --pre script.py text", "sed -i '' s/a/b/ file",
            "awk END file", "curl https://example.com", "du -sh .", "head -20 file", "tail -f file", "wc -l file",
            "pwd", "pwd -P", "pwd -L", "/bin/pwd -P",
            "top -l 1", "./ps -A", "../bin/ls", "/tmp/ps -A", "/usr/bin/ps -A", "//bin/ps -A",
            "/bin/../bin/ps -A", "/bin/ls/", "ps.exe", "ＬＳ", "true", "echo safe"
        ] { expectApproval(command) }
    }

    @Test func commandSpecificGrammarsRejectUnknownOrAmbiguousOptions() {
        for command in [
            "ps -p", "ps -p -1", "ps -p 0", "ps -p 2147483648", "ps -p 1,,2", "ps -p １２３",
            "ps -o", "ps -o command=other", "ps -o pid,,command", "ps -o pid,notAField", "ps --sort=-pcpu",
            "ps --help", "ps 123", "ps -t ../x=evil", "ps -U -root", "ps -aZ", "ps --",
            "id -x", "id -n", "id -r", "id -ug", "id -u -u", "id root admin", "id root -u",
            "whoami root", "uptime -s", "pwd -P -L", "uname --all", "uname name", "uname -Z",
            "ls -R /", "ls -w /tmp", "ls --recursive", "ls -D custom", "ls --color=always", "ls =ps", "ls -", "ls ''",
            "df --sync", "df --output=source", "df -T apfs", "df -Z", "df x=y"
        ] { expectApproval(command) }
    }

    @Test func controlCharactersInvisibleUnicodeAndInputBoundsFailClosed() {
        for scalar in [UInt32(0), 9, 10, 13, 27, 127, 159, 0x200B, 0x202E, 0x2028, 0x2029, 0xFEFF] {
            let value = String(UnicodeScalar(scalar)!)
            expectApproval("ls a\(value)b")
            expectApproval("ls 'a\(value)b'")
        }
        for command in ["", "   ", "ls 'unterminated", "ls \"unterminated", "ls 'path'other", "ls a'b'",
                        "ls a\u{00A0}b", "ls " + String(repeating: "a", count: 4_097),
                        "ls " + Array(repeating: "x", count: 128).joined(separator: " "),
                        "ls " + String(repeating: " x", count: 8_192)] {
            expectApproval(command)
        }
    }

    @Test func wrappingAnyApprovedQueryInShellSyntaxNeverInheritsItsClassification() {
        for query in ["ps -A", "uname -a", "id -u", "whoami", "uptime", "ls /tmp", "df -h /"] {
            #expect(TerminalAICommandPolicy.assess(query).isReadOnly)
            for modified in ["sudo \(query)", "env \(query)", "command \(query)", "builtin \(query)",
                             "bash -c '\(query)'", "\(query); id", "\(query) | cat", "\(query) > /tmp/file"] {
                expectApproval(modified)
            }
        }
    }

    private func expectApproval(_ command: String) {
        let assessment = TerminalAICommandPolicy.assess(command)
        #expect(!assessment.isReadOnly, "\(command) unexpectedly classified read-only")
        #expect(assessment.executable == nil)
        #expect(assessment.arguments.isEmpty)
        #expect(!assessment.reason.isEmpty)
    }
}
