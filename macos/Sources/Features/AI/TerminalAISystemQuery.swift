import Darwin
import Foundation

/// A fresh pathname invokes a fixed metadata utility in the existing PTY. It
/// avoids the current shell's PATH, aliases and pre-existing named functions.
/// The current user and shell hooks remain trusted ambient authority; this is
/// not a sandbox or a separate command runner.
final class TerminalAISystemQuery {
    let directory: URL
    let executableURL: URL
    let command: String
    let systemCommand: String
    private var cleanedUp = false

    init(assessment: TerminalAICommandPolicy.Assessment) throws {
        guard assessment.isReadOnly, let path = assessment.executable else {
            throw Self.issue("Only an assessed read-only system query can use trusted dispatch.")
        }
        // Reconstruct the policy's deliberately small whole-word grammar. The
        // actual dispatch uses standard single-quote escaping instead.
        let literal = try ([path] + assessment.arguments).map(Self.policyWord).joined(separator: " ")
        let verified = TerminalAICommandPolicy.assess(literal)
        guard verified.isReadOnly, verified.executable == path, verified.arguments == assessment.arguments else {
            throw Self.issue("The query path or literal arguments do not match the read-only allowlist.")
        }
        let canonical = ([path] + assessment.arguments).map(Self.quote).joined(separator: " ")
        let directory = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("ghostty-ai-query-\(UUID().uuidString)", isDirectory: true)
        let executable = directory.appendingPathComponent(URL(fileURLWithPath: path).lastPathComponent)
        let command = ([executable.path] + assessment.arguments).map(Self.quote).joined(separator: " ")
        guard command.utf8.count <= 16_384 else { throw Self.issue("The trusted query is too large for one terminal command.") }
        // mkdir is exclusive: an existing name is never adopted or reused.
        guard directory.path.withCString({ Darwin.mkdir($0, 0o700) }) == 0 else {
            throw Self.issue("Unable to create a private directory for the system query.")
        }
        do {
            try FileManager.default.createSymbolicLink(atPath: executable.path, withDestinationPath: path)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
        self.directory = directory
        executableURL = executable
        self.command = command
        systemCommand = canonical
    }

    deinit { cleanup() }

    func cleanup() {
        guard !cleanedUp else { return }
        // A live query owns precisely this fresh directory and its one link.
        try? FileManager.default.removeItem(at: directory)
        cleanedUp = true
    }

    private static func policyWord(_ word: String) throws -> String {
        if !word.contains("'") { return "'\(word)'" }
        guard !word.contains("\"") else { throw issue("Ambiguous quoted arguments require individual approval.") }
        return "\"\(word)\""
    }

    private static func quote(_ word: String) -> String { "'" + word.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    private static func issue(_ message: String) -> NSError {
        NSError(domain: "GhosttyAISystemQuery", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
