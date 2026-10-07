import AppKit
import Foundation

enum TerminalAISSHTools {
    static func quote(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    /// The user pastes this into their existing remote shell. It touches only a
    /// temporary directory and loads the same integration shipped with Ghostty.
    static func bootstrap(shell: String, resources: URL) throws -> String {
        guard ["zsh", "bash"].contains(shell) else { throw TerminalAIWorkflow.issue("Select zsh or bash.") }
        let path = shell == "zsh" ? "zsh/ghostty-integration" : "bash/ghostty.bash"
        var source = try Data(contentsOf: resources.appendingPathComponent(path))
        if shell == "bash" {
            // Bash 3.2 needs bash-preexec.sh beside ghostty.bash. USTAR avoids
            // AppleDouble/xattr payloads and keeps this single paste bounded.
            let archive = Process()
            let archiveOutput = Pipe()
            archive.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
            archive.arguments = ["--disable-copyfile", "--no-xattrs", "--format", "ustar", "-cf", "-", "-C",
                                 resources.appendingPathComponent("bash").path, "ghostty.bash", "bash-preexec.sh"]
            archive.standardOutput = archiveOutput
            try archive.run()
            source = try archiveOutput.fileHandleForReading.readToEnd() ?? Data()
            archive.waitUntilExit()
            guard archive.terminationStatus == 0 else { throw TerminalAIWorkflow.issue("Unable to package Bash integration.") }
        }
        let process = Process()
        let input = Pipe()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
        process.arguments = ["-9", "-c"]
        process.standardInput = input
        process.standardOutput = output
        try process.run()
        try input.fileHandleForWriting.write(contentsOf: source)
        try input.fileHandleForWriting.close()
        let compressed = try output.fileHandleForReading.readToEnd() ?? Data()
        process.waitUntilExit()
        guard process.terminationStatus == 0, !compressed.isEmpty else {
            throw TerminalAIWorkflow.issue("Unable to prepare the bundled shell integration.")
        }
        let payload = quote(compressed.base64EncodedString())
        let unpack = shell == "bash" ? "tar -xz -C \"$_ghostty_ai_setup_dir\"" : "gzip -dc > \"$_ghostty_ai_setup_dir/integration\""
        let file = shell == "bash" ? "ghostty.bash" : "integration"
        let command = "_ghostty_ai_setup_dir=$(mktemp -d \"${TMPDIR:-/tmp}/ghostty-ai.XXXXXX\") && printf '%s' \(payload) | (base64 -d 2>/dev/null || base64 -D) | \(unpack) && source \"$_ghostty_ai_setup_dir/\(file)\""
        guard command.utf8.count <= 16_384 else { throw TerminalAIWorkflow.issue("The integration payload is too large to paste as one command.") }
        return command
    }
}
