import Foundation

enum TerminalAIText {
    static func prefix(_ text: String, bytes: Int) -> String {
        var data = Data(text.utf8.prefix(bytes))
        for _ in 0..<4 {
            if let value = String(data: data, encoding: .utf8) { return value }
            if !data.isEmpty { data.removeLast() }
        }
        return ""
    }

    static func decode(_ data: Data) -> String? {
        for leading in 0...3 {
            for trailing in 0...3 {
                let slice = Data(data.dropFirst(leading).dropLast(trailing))
                if let value = String(data: slice, encoding: .utf8) { return value }
            }
        }
        return nil
    }
}

struct TerminalAICommandRecord: Codable, Identifiable, Equatable {
    let id: String
    let surfaceID: UUID
    let sequence: UInt64
    let command: String?
    var requestedCommand: String?
    var systemCommand: String?
    let commandSource: String
    let directory: String?
    let host: String?
    let hostIsLocal: Bool?
    let startedAt: Double
    let finishedAt: Double?
    let durationMs: UInt64?
    let exitCode: Int?
    let running: Bool
    let output: String
    let outputTruncated: Bool
    let interrupted: Bool

    init?(value: [String: Any], surfaceID: UUID) {
        guard let sequence = value["sequence"] as? UInt64,
              let startedAt = value["startedAt"] as? Double, startedAt.isFinite,
              let output = value["output"] as? String else { return nil }
        self.surfaceID = surfaceID
        self.sequence = sequence
        self.startedAt = startedAt
        id = "\(surfaceID.uuidString):\(sequence):\(startedAt)"
        command = value["command"] as? String
        commandSource = value["commandSource"] as? String ?? "unknown"
        directory = value["directory"] as? String
        host = value["host"] as? String
        hostIsLocal = value["hostIsLocal"] as? Bool
        finishedAt = value["finishedAt"] as? Double
        durationMs = value["durationMs"] as? UInt64
        exitCode = value["exitCode"] as? Int
        running = value["running"] as? Bool ?? false
        self.output = TerminalAIText.prefix(output, bytes: 65_536)
        outputTruncated = value["outputTruncated"] as? Bool == true || output.utf8.count > 65_536
        interrupted = value["interrupted"] as? Bool ?? false
    }

    var webValue: [String: Any] {
        let displayCommand = systemCommand ?? command
        var value: [String: Any] = [
            "id": id, "command": displayCommand ?? "", "commandAvailable": displayCommand?.isEmpty == false, "commandSource": commandSource,
            "directory": directory ?? "unknown", "host": host ?? "unknown",
            "startedAt": startedAt * 1_000, "duration": Double(durationMs ?? 0) / 1_000,
            "output": output, "outputTruncated": outputTruncated,
            "state": running ? "running" : interrupted ? "interrupted" : exitCode == 0 ? "completed" : "failed"
        ]
        if let requestedCommand { value["requestedCommand"] = requestedCommand }
        if let systemCommand { value["systemCommand"] = systemCommand }
        if systemCommand != nil, let command { value["actualCommand"] = command }
        if let exitCode { value["exitCode"] = exitCode }
        return value
    }

    var contextText: String {
        """
        Command record: \(id)
        Command: \(command ?? "unknown; do not infer it from nearby text")
        \(systemCommand.map { "Verified system query: \($0)\nRequested query: \(requestedCommand ?? "unknown")" } ?? "")
        Reported host: \(host ?? "unknown")
        Directory: \(directory ?? "unknown")
        Exit: \(exitCode.map(String.init) ?? "unconfirmed")
        Duration: \(durationMs.map { "\($0) ms" } ?? "unconfirmed")
        Output\(outputTruncated ? " (truncated)" : ""):
        \(output)
        """
    }
}

struct TerminalAIContextAttachment: Codable, Identifiable, Equatable {
    let id: String
    let name: String
    let kind: String
    let source: String
    let host: String
    let text: String
    var truncated = false
    var scope: String?

    var webValue: [String: Any] {
        var value: [String: Any] = ["id": id, "name": name, "kind": kind, "source": source, "host": host,
         "preview": String(text.prefix(8_192)), "truncated": truncated,
         "previewTruncated": text.count > 8_192,
         "lineCount": text.split(separator: "\n", omittingEmptySubsequences: false).count]
        if let scope { value["scope"] = scope }
        return value
    }
}

struct TerminalAISavedWorkbench: Codable {
    var attachments: [TerminalAIContextAttachment]
    var task: TerminalAITaskPlan?
}

struct TerminalAIWorkflow: Codable, Identifiable, Equatable {
    struct Parameter: Codable, Equatable {
        let name: String
        let defaultValue: String
    }
    let id: UUID
    var name: String
    var description: String
    var prompt: String
    var parameters: [Parameter]

    var webValue: [String: Any] {
        ["id": id.uuidString, "name": name, "description": description, "prompt": prompt,
         "parameters": parameters.map { ["name": $0.name, "defaultValue": $0.defaultValue] }]
    }

    func expanded(values: [String: String]) throws -> String {
        let placeholders = try Self.placeholders(in: prompt)
        guard Set(parameters.map(\.name)) == Set(placeholders), values.keys.allSatisfy(placeholders.contains) else {
            throw Self.issue("Workflow parameters do not match its placeholders.")
        }
        var resolved: [String: String] = [:]
        for parameter in parameters {
            let value = values[parameter.name] ?? parameter.defaultValue
            guard !value.isEmpty, value.utf8.count <= 4_096 else {
                throw Self.issue("Fill the workflow parameter '\(parameter.name)' (up to 4096 bytes).")
            }
            resolved[parameter.name] = value
        }
        let expression = try NSRegularExpression(pattern: #"\{\{([A-Za-z_][A-Za-z0-9_-]*)\}\}"#)
        let original = prompt as NSString
        let expandedText = NSMutableString(string: prompt)
        for match in expression.matches(in: prompt, range: NSRange(location: 0, length: original.length)).reversed() {
            expandedText.replaceCharacters(in: match.range, with: resolved[original.substring(with: match.range(at: 1))] ?? "")
        }
        let expanded = expandedText as String
        guard expanded.utf8.count <= 65_536 else { throw Self.issue("The expanded workflow is too large.") }
        return expanded
    }

    static func placeholders(in prompt: String) throws -> [String] {
        let expression = try NSRegularExpression(pattern: #"\{\{([A-Za-z_][A-Za-z0-9_-]*)\}\}"#)
        let text = prompt as NSString
        return Array(Set(expression.matches(in: prompt, range: NSRange(location: 0, length: text.length)).map {
            text.substring(with: $0.range(at: 1))
        })).sorted()
    }

    static func issue(_ message: String) -> NSError {
        NSError(domain: "TerminalAIWorkbench", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

struct TerminalAITaskPlan: Codable, Identifiable, Equatable {
    static let stepStatuses = ["pending", "running", "completed", "failed"]

    struct Step: Codable, Identifiable, Equatable {
        let id: String
        let title: String
        var status = "pending"
        var evidence = ""
    }
    struct Verification: Codable, Equatable {
        var status = "pending"
        var summary = "Run a check in the attached terminal to verify the result."
        var evidence = ""
    }
    let id: UUID
    var title: String
    let surfaceID: UUID
    var host: String?
    let startedAt: Double
    var startSequence: UInt64?
    var steps: [Step]
    var verification = Verification()

    var webValue: [String: Any] {
        var value: [String: Any] = ["id": id.uuidString, "title": title,
         "steps": steps.map { ["id": $0.id, "title": $0.title, "status": $0.status, "evidence": $0.evidence] },
         "verification": ["status": verification.status, "summary": verification.summary, "evidence": verification.evidence]]
        if let host { value["host"] = host }
        return value
    }

    var modelContext: String {
        let state: [String: Any] = [
            "id": id.uuidString, "title": title, "host": host ?? "unknown",
            "steps": steps.map { ["id": $0.id, "title": $0.title, "status": $0.status] },
            "verification": ["status": verification.status, "summary": verification.summary]
        ]
        let data = try? JSONSerialization.data(withJSONObject: state, options: [.sortedKeys])
        return "Current investigation plan:\n" + (data.flatMap { String(data: $0, encoding: .utf8) } ?? "Unavailable")
    }

    mutating func apply(_ request: [String: Any], records: [TerminalAICommandRecord]) throws {
        switch request["operation"] as? String {
        case "get_plan": break
        case "set_plan":
            guard let proposed = request["steps"] as? [[String: Any]], (1...12).contains(proposed.count) else {
                throw TerminalAIWorkflow.issue("Provide 1–12 troubleshooting steps.")
            }
            var ids = Set<String>()
            let nextSteps = try proposed.map { value in
                guard let id = value["id"] as? String, !id.isEmpty, id.utf8.count <= 100, ids.insert(id).inserted,
                      let title = value["title"] as? String, !title.isEmpty, title.utf8.count <= 300 else {
                    throw TerminalAIWorkflow.issue("Each step needs a unique ID and a concise title.")
                }
                return Step(id: id, title: title)
            }
            steps = nextSteps
            if let title = request["title"] as? String, !title.isEmpty { self.title = String(title.prefix(300)) }
            verification = Verification()
        case "update_step":
            guard let id = request["stepId"] as? String, !id.isEmpty else {
                throw TerminalAIWorkflow.issue("update_step requires stepId. Read get_plan for the existing step IDs.")
            }
            guard let index = steps.firstIndex(where: { $0.id == id }) else {
                throw TerminalAIWorkflow.issue("Unknown step ID \(String(reflecting: String(id.prefix(100)))). Existing step IDs: \(steps.map(\.id).joined(separator: ", ")).")
            }
            guard let status = request["status"] as? String, Self.stepStatuses.contains(status) else {
                throw TerminalAIWorkflow.issue("update_step requires status: \(Self.stepStatuses.joined(separator: ", ")).")
            }
            steps[index].status = status
            steps[index].evidence = String((request["evidence"] as? String ?? "").prefix(8_192))
        case "verify":
            guard let ids = request["commandIds"] as? [String], !ids.isEmpty, ids.count <= 12,
                  Set(ids).count == ids.count,
                  let status = request["status"] as? String, ["passed", "failed"].contains(status) else {
                throw TerminalAIWorkflow.issue("Verification needs actual command record IDs and a passed/failed result.")
            }
            let checks = try ids.map { id -> TerminalAICommandRecord in
                guard let record = records.first(where: { $0.id == id }), record.surfaceID == surfaceID,
                      startSequence.map({ record.sequence > $0 }) ?? (record.startedAt >= startedAt),
                      !record.running, !record.interrupted,
                      record.finishedAt != nil, record.exitCode != nil else {
                    throw TerminalAIWorkflow.issue("Verification must reference completed commands from this task's attached terminal.")
                }
                return record
            }
            guard let host, !host.isEmpty, host != "unknown" else {
                throw TerminalAIWorkflow.issue("Verification requires a known host bound to this task. Continue the task to refresh the terminal target.")
            }
            guard checks.allSatisfy({ $0.host == host }) else {
                throw TerminalAIWorkflow.issue("Verification must reference commands from this task's attached host.")
            }
            if status == "passed", checks.contains(where: { $0.exitCode != 0 }) {
                throw TerminalAIWorkflow.issue("A failed command cannot prove a passed verification.")
            }
            verification = Verification(status: status, summary: String((request["summary"] as? String ?? "Command checks \(status)").prefix(1_024)),
                                        evidence: checks.map(\.contextText).joined(separator: "\n\n"))
        default: throw TerminalAIWorkflow.issue("Unknown task-plan operation.")
        }
    }

    mutating func finish(interrupted: Bool) {
        for index in steps.indices where steps[index].status == "running" {
            steps[index].status = "failed"
            steps[index].evidence += "\nThe task ended before this step completed."
        }
        if ["pending", "running"].contains(verification.status) {
            verification.status = "unverified"
            verification.summary = interrupted ? "Interrupted before verification." : "The agent finished without a verified command check."
        }
    }
}

/// Small local catalogs. Commands are isolated per terminal; workflows are edited under a file lock.
struct TerminalAIWorkbenchStore {
    let directory: URL

    func saveCommands(_ records: [TerminalAICommandRecord], surfaceID: UUID) throws {
        try write(Array(records.suffix(100)), to: directory.appendingPathComponent("commands/\(surfaceID.uuidString).json"))
    }

    func commands() throws -> [TerminalAICommandRecord] {
        let location = directory.appendingPathComponent("commands")
        guard FileManager.default.fileExists(atPath: location.path) else { return [] }
        let files = try FileManager.default.contentsOfDirectory(at: location, includingPropertiesForKeys: [.contentModificationDateKey])
            .filter { $0.pathExtension == "json" }
            .sorted { ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) >
                ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
        return Array(files.prefix(20).flatMap { (try? read([TerminalAICommandRecord].self, at: $0)) ?? [] }
            .sorted { $0.startedAt > $1.startedAt }.prefix(200))
    }

    func workflows() throws -> [TerminalAIWorkflow] {
        let url = directory.appendingPathComponent("workflows.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try read([TerminalAIWorkflow].self, at: url)
    }

    func saveWorkflow(_ workflow: TerminalAIWorkflow) throws -> [TerminalAIWorkflow] {
        guard !workflow.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              workflow.name.utf8.count <= 200, !workflow.prompt.isEmpty, workflow.prompt.utf8.count <= 32_768,
              workflow.description.utf8.count <= 2_048, workflow.parameters.count <= 16,
              Set(workflow.parameters.map(\.name)).count == workflow.parameters.count,
              Set(try TerminalAIWorkflow.placeholders(in: workflow.prompt)) == Set(workflow.parameters.map(\.name)) else {
            throw TerminalAIWorkflow.issue("Provide a workflow name, task prompt and matching unique parameters.")
        }
        let lease = try catalogLease()
        return try withExtendedLifetime(lease) {
            var values = try workflows()
            values.removeAll { $0.id == workflow.id }
            values.append(workflow)
            guard values.count <= 200 else { throw TerminalAIWorkflow.issue("The workflow catalog has reached 200 entries.") }
            try write(values, to: directory.appendingPathComponent("workflows.json"))
            return values
        }
    }

    func removeWorkflow(_ id: UUID) throws -> [TerminalAIWorkflow] {
        let lease = try catalogLease()
        return try withExtendedLifetime(lease) {
            var values = try workflows()
            values.removeAll { $0.id == id }
            try write(values, to: directory.appendingPathComponent("workflows.json"))
            return values
        }
    }

    private func catalogLease() throws -> TerminalAIHistoryStore.Lease {
        try TerminalAIHistoryStore(directory: directory.appendingPathComponent("locks"))
            .acquire(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)
    }

    private func read<T: Decodable>(_ type: T.Type, at url: URL) throws -> T {
        try JSONDecoder().decode(type, from: Data(contentsOf: url))
    }

    private func write<T: Encodable>(_ value: T, to url: URL) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                    attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(value).write(to: url, options: .atomic)
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
