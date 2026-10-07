import Foundation

/// Classifies literal arguments, not shell resolution or execution authority.
/// A read-only result still requires a trusted target and invocation at dispatch.
enum TerminalAICommandPolicy {
    struct Assessment: Equatable {
        let isReadOnly: Bool
        let reason: String
        let executable: String?
        let arguments: [String]
    }

    private static let executables = [
        "ps": "/bin/ps", "uname": "/usr/bin/uname", "id": "/usr/bin/id",
        "whoami": "/usr/bin/whoami", "uptime": "/usr/bin/uptime",
        "ls": "/bin/ls", "df": "/bin/df"
    ]

    static func assess(_ command: String) -> Assessment {
        guard let words = literalArguments(command), let input = words.first else {
            return approval("Shell syntax, expansion, or an invalid command requires individual approval.")
        }
        let name = String(input.split(separator: "/").last ?? "")
        guard let executable = executables[name] else { return approval(reason(for: name)) }
        guard input == name || input == executable else {
            return approval("This executable path is not the expected system diagnostic command.")
        }
        let arguments = Array(words.dropFirst())
        guard valid(arguments, for: name) else {
            return approval("These \(name) arguments are outside the read-only diagnostic allowlist.")
        }
        return Assessment(isReadOnly: true, reason: "Literal arguments describe a read-only system metadata query.",
                          executable: executable, arguments: arguments)
    }

    private static func approval(_ reason: String) -> Assessment {
        Assessment(isReadOnly: false, reason: reason, executable: nil, arguments: [])
    }

    private static func reason(for name: String) -> String {
        switch name {
        case "rm", "rmdir", "unlink", "shred", "truncate":
            return "Deleting or truncating data always requires individual approval."
        case "sudo", "su", "doas":
            return "Changing privileges always requires individual approval."
        case "chmod", "chown", "chgrp", "setfacl", "cp", "mv", "install", "dd", "tee", "touch", "mkdir", "mkfs", "mount", "umount":
            return "Changing files, permissions, or storage always requires individual approval."
        case "kill", "pkill", "killall", "reboot", "shutdown", "systemctl", "service", "launchctl":
            return "Changing processes, services, or machine state always requires individual approval."
        case "mysql", "psql", "sqlite3", "redis-cli", "mongosh":
            return "Database commands may write data and require individual approval."
        case "sh", "bash", "zsh", "fish", "python", "python3", "perl", "ruby", "node", "osascript", "eval", "exec", "env", "command", "builtin":
            return "Scripts and command wrappers require individual approval."
        default:
            return "This command is outside the read-only diagnostic allowlist and requires individual approval."
        }
    }

    /// Deliberately smaller than a shell parser. Only space-separated literal
    /// words and whole quoted words are accepted. Even quoted shell operators
    /// are rejected so this never has to infer expansion or evaluation rules.
    private static func literalArguments(_ command: String) -> [String]? {
        guard !command.isEmpty, command.utf8.count <= 16_384 else { return nil }
        let forbidden = CharacterSet(charactersIn: "\\$`;&|<>(){}[]*?!~^#")
        var words: [String] = []
        var word = ""
        var quote: Unicode.Scalar?
        var started = false
        var closedQuote = false
        for scalar in command.unicodeScalars {
            switch scalar.properties.generalCategory {
            case .control, .format, .lineSeparator, .paragraphSeparator: return nil
            default: break
            }
            if forbidden.contains(scalar) || (scalar.properties.isWhitespace && scalar != " ") { return nil }
            if let active = quote {
                if scalar == active {
                    quote = nil
                    closedQuote = true
                } else {
                    word.unicodeScalars.append(scalar)
                }
            } else if scalar == " " {
                if started {
                    guard !word.isEmpty else { return nil }
                    words.append(word)
                    guard words.count <= 128 else { return nil }
                    word = ""
                    started = false
                    closedQuote = false
                }
            } else if scalar == "'" || scalar == "\"" {
                guard !started else { return nil }
                started = true
                quote = scalar
            } else {
                guard !closedQuote else { return nil }
                started = true
                word.unicodeScalars.append(scalar)
            }
            guard word.utf8.count <= 4_096 else { return nil }
        }
        guard quote == nil else { return nil }
        if started {
            guard !word.isEmpty else { return nil }
            words.append(word)
            guard words.count <= 128 else { return nil }
        }
        return words.isEmpty ? nil : words
    }

    private static func valid(_ arguments: [String], for name: String) -> Bool {
        switch name {
        case "whoami", "uptime": return arguments.isEmpty
        case "uname": return arguments.allSatisfy { shortFlags($0, allowed: "amnprsv") }
        case "id": return validIdentity(arguments)
        case "ps": return validProcesses(arguments)
        case "ls": return validPaths(arguments, flags: "ABCFGHLOSTUW@abcdefghiklmnopqrstux1")
        case "df": return validPaths(arguments, flags: "abghHiklmnP")
        default: return false
        }
    }

    private static func shortFlags(_ value: String, allowed: String) -> Bool {
        value.hasPrefix("-") && value.count > 1 && value.dropFirst().allSatisfy { allowed.contains($0) }
    }

    private static func validPaths(_ arguments: [String], flags: String) -> Bool {
        var optionsEnded = false
        for argument in arguments {
            if !optionsEnded && argument == "--" {
                optionsEnded = true
            } else if !optionsEnded && argument.hasPrefix("-") {
                guard shortFlags(argument, allowed: flags) else { return false }
            } else {
                // zsh's =word expansion and assignment-shaped arguments are not
                // part of this literal path grammar, including inside quotes.
                guard !argument.contains("="), argument != "-" else { return false }
            }
        }
        return true
    }

    private static func validIdentity(_ arguments: [String]) -> Bool {
        var flags = ""
        var users: [String] = []
        for argument in arguments {
            if argument.hasPrefix("-") {
                guard users.isEmpty, shortFlags(argument, allowed: "ugGnr") else { return false }
                flags += argument.dropFirst()
            } else {
                guard userName(argument) else { return false }
                users.append(argument)
            }
        }
        let selectors = flags.filter { "ugG".contains($0) }
        guard users.count <= 1, selectors.count <= 1 else { return false }
        if flags.contains("n") || flags.contains("r") { return selectors.count == 1 }
        return true
    }

    private static func validProcesses(_ arguments: [String]) -> Bool {
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if !argument.hasPrefix("-") {
                guard argument.allSatisfy({ "achjlmrSTuvwx".contains($0) }) else { return false }
                index += 1
                continue
            }
            let flags = Array(argument.dropFirst())
            guard !flags.isEmpty else { return false }
            var flagIndex = 0
            while flagIndex < flags.count {
                let flag = flags[flagIndex]
                if "aAcChjlMmrSTuvwx".contains(flag) {
                    flagIndex += 1
                    continue
                }
                guard "oOpUgGt".contains(flag) else { return false }
                let value: String
                if flagIndex + 1 < flags.count {
                    value = String(flags[(flagIndex + 1)...])
                } else {
                    index += 1
                    guard index < arguments.count else { return false }
                    value = arguments[index]
                }
                guard validProcessValue(value, flag: flag) else { return false }
                flagIndex = flags.count
            }
            index += 1
        }
        return true
    }

    private static func validProcessValue(_ value: String, flag: Character) -> Bool {
        let parts = value.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        guard !parts.isEmpty, parts.count <= 64 else { return false }
        switch flag {
        case "o", "O":
            let fields: Set<String> = ["pid", "ppid", "pgid", "sess", "jobc", "user", "uid", "ruid", "gid", "rgid",
                                       "%cpu", "%mem", "pcpu", "pmem", "etime", "time", "state", "stat", "tty", "tt",
                                       "tname", "comm", "command", "args", "pri", "nice", "rss", "rsz", "vsz", "start",
                                       "stime", "lstart", "wchan"]
            return parts.allSatisfy { fields.contains($0) }
        case "p", "g", "G":
            return parts.allSatisfy { $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) && (Int32($0) ?? 0) > 0 }
        case "U": return parts.allSatisfy(userName)
        case "t":
            return parts.allSatisfy { !$0.isEmpty && $0.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "/._-".contains($0)) } }
        default: return false
        }
    }

    private static func userName(_ value: String) -> Bool {
        !value.isEmpty && value.first != "-" && value.utf8.count <= 256 &&
        value.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "._-".contains($0)) }
    }
}
