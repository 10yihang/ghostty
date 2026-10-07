import Foundation

/// Split bytes on LF, never on Unicode separators or partially received UTF-8 characters.
struct TerminalAIJSONLines {
    private var buffer = Data()

    mutating func append(_ data: Data) throws -> [[String: Any]] {
        buffer.append(data)
        var records: [[String: Any]] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            var line = Data(buffer[..<newline])
            buffer.removeSubrange(...newline)
            if line.last == 0x0D { line.removeLast() }
            guard !line.isEmpty else { continue }
            guard line.count <= 8 * 1_024 * 1_024 else { throw CocoaError(.fileReadTooLarge) }
            guard let record = try JSONSerialization.jsonObject(with: line) as? [String: Any] else {
                throw CocoaError(.propertyListReadCorrupt)
            }
            records.append(record)
        }
        guard buffer.count <= 8 * 1_024 * 1_024 else { throw CocoaError(.fileReadTooLarge) }
        return records
    }

    var hasIncompleteRecord: Bool { !buffer.isEmpty }
}

/// Stdout is protocol data. Stderr is bounded diagnostics, drained independently.
@MainActor
final class TerminalAIRPC {
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let diagnostics = Pipe()
    private var lines = TerminalAIJSONLines()
    private var stderr = Data()
    private var closed = false
    private var stdoutEnded = false
    private var stderrEnded = false
    private var exitStatus: Int32?
    private let onRecord: ([String: Any]) -> Void
    private let onFailure: (String) -> Void

    init(
        executable: URL,
        arguments: [String],
        directory: String,
        environment: [String: String],
        sessionLease: TerminalAIHistoryStore.Lease? = nil,
        onRecord: @escaping ([String: Any]) -> Void,
        onFailure: @escaping (String) -> Void
    ) throws {
        self.onRecord = onRecord
        self.onFailure = onFailure
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: directory, isDirectory: true)
        process.environment = environment
        process.standardInput = input
        process.standardOutput = output
        process.standardError = diagnostics
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil }
            DispatchQueue.main.async { [weak self] in self?.consume(data) }
        }
        diagnostics.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil }
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.closed else { return }
                self.stderr.append(data)
                self.stderr = Data(self.stderr.suffix(4_096))
                if data.isEmpty {
                    self.stderrEnded = true
                    self.reportExit()
                }
            }
        }
        process.terminationHandler = { [weak self] process in
            let status = process.terminationStatus
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.closed else { return }
                self.exitStatus = status
                self.reportExit()
            }
        }
        try process.run()
        // close() sends SIGTERM asynchronously. Keep the conversation's exclusive
        // writer lease until the child actually exits, including after this RPC deinitializes.
        if let sessionLease {
            let child = process
            DispatchQueue.global(qos: .utility).async {
                child.waitUntilExit()
                withExtendedLifetime(sessionLease) {}
            }
        }
    }

    func send(_ command: [String: Any]) throws {
        guard !closed, process.isRunning else { throw CocoaError(.fileWriteUnknown) }
        var data = try JSONSerialization.data(withJSONObject: command)
        data.append(0x0A)
        try input.fileHandleForWriting.write(contentsOf: data)
    }

    var hasExited: Bool { !process.isRunning }

    func close() {
        guard !closed else { return }
        closed = true
        output.fileHandleForReading.readabilityHandler = nil
        diagnostics.fileHandleForReading.readabilityHandler = nil
        process.terminationHandler = nil
        try? input.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }
    }

    private func consume(_ data: Data) {
        guard !closed else { return }
        do {
            for record in try lines.append(data) { onRecord(record) }
            if data.isEmpty, lines.hasIncompleteRecord {
                onFailure("Pi ended with an incomplete JSON response.")
            } else if data.isEmpty {
                stdoutEnded = true
                reportExit()
            }
        } catch {
            onFailure("Invalid Pi RPC response: \(error.localizedDescription)")
        }
    }

    private func reportExit() {
        guard stdoutEnded, stderrEnded, let status = exitStatus, !closed else { return }
        let details = (String(data: stderr, encoding: .utf8) ?? "Pi emitted non-UTF-8 diagnostics.")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        onFailure("Pi exited (\(status)). \(details)")
    }

    deinit {
        output.fileHandleForReading.readabilityHandler = nil
        diagnostics.fileHandleForReading.readabilityHandler = nil
        process.terminationHandler = nil
        try? input.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }
    }
}
