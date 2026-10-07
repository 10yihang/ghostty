import Darwin
import Foundation

/// Ghostty owns these transcripts and Pi session files independently of the user's Pi history.
struct TerminalAIHistoryStore {
    struct Entry: Codable, Identifiable, Equatable {
        let id: UUID
        var title: String
        var updatedAt: Date
        var sourceDirectory: String
        var workingDirectory: String
        var model: String
        var messageCount: Int
    }

    struct Snapshot {
        var entry: Entry
        var messages: [[String: Any]]
        var phase: String
        var workbench: [String: Any]?
    }

    enum StoreError: LocalizedError, Equatable {
        case busy, missing, corrupt

        var errorDescription: String? {
            switch self {
            case .busy: return "This conversation is already open in another AI panel."
            case .missing: return "This conversation is no longer available."
            case .corrupt: return "This conversation could not be read. Start a new conversation instead."
            }
        }
    }

    /// Keep this alive until the corresponding Pi process has terminated.
    final class Lease: @unchecked Sendable {
        private let descriptor: Int32

        fileprivate init(descriptor: Int32) { self.descriptor = descriptor }

        deinit { Darwin.close(descriptor) }
    }

    let directory: URL

    func list() throws -> [Entry] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
            .compactMap { folder in
                guard let id = UUID(uuidString: folder.lastPathComponent) else { return nil }
                return try? read(id: id).entry
            }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    func read(id: UUID) throws -> Snapshot {
        let url = folder(id).appendingPathComponent("conversation.json")
        guard FileManager.default.fileExists(atPath: url.path) else { throw StoreError.missing }
        let data = try Data(contentsOf: url)
        guard let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              value["schemaVersion"] as? Int == 1,
              let metadata = value["entry"] as? [String: Any],
              let metadataData = try? JSONSerialization.data(withJSONObject: metadata),
              let entry = try? decoder().decode(Entry.self, from: metadataData), entry.id == id,
              let messages = value["messages"] as? [[String: Any]],
              let phase = value["phase"] as? String,
              Self.validMessages(messages), entry.messageCount == messages.count,
              entry.updatedAt.timeIntervalSince1970.isFinite else { throw StoreError.corrupt }
        return Snapshot(entry: entry, messages: messages, phase: phase, workbench: value["workbench"] as? [String: Any])
    }

    func save(_ snapshot: Snapshot) throws {
        guard Self.validMessages(snapshot.messages), snapshot.entry.messageCount == snapshot.messages.count,
              snapshot.entry.updatedAt.timeIntervalSince1970.isFinite else { throw StoreError.corrupt }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        let metadata = try JSONSerialization.jsonObject(with: encoder.encode(snapshot.entry))
        var document: [String: Any] = [
            "schemaVersion": 1, "entry": metadata,
            "messages": snapshot.messages, "phase": snapshot.phase
        ]
        if let workbench = snapshot.workbench { document["workbench"] = workbench }
        guard JSONSerialization.isValidJSONObject(document) else { throw StoreError.corrupt }
        let data = try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys])
        let destination = try prepareFolder(snapshot.entry.id).appendingPathComponent("conversation.json")
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).tmp")
        let descriptor = Darwin.open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, mode_t(0o600))
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer {
            try? handle.close()
            try? FileManager.default.removeItem(at: temporary)
        }
        try handle.write(contentsOf: data)
        try handle.synchronize()
        try handle.close()
        guard Darwin.rename(temporary.path, destination.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    func sessionURL(id: UUID) -> URL { folder(id).appendingPathComponent("session.jsonl") }

    /// Pi writes its own valid header into this empty file and then persists prompts immediately.
    func prepareSession(id: UUID) throws -> URL {
        _ = try prepareFolder(id)
        let url = sessionURL(id: id)
        let descriptor = Darwin.open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, mode_t(0o600))
        if descriptor >= 0 {
            Darwin.close(descriptor)
        } else if errno != EEXIST {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw StoreError.corrupt
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return url
    }

    func acquire(id: UUID) throws -> Lease {
        let url = try prepareFolder(id).appendingPathComponent(".lock")
        let descriptor = Darwin.open(url.path, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, mode_t(0o600))
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        guard Darwin.fchmod(descriptor, mode_t(0o600)) == 0 else {
            let error = errno
            Darwin.close(descriptor)
            throw POSIXError(POSIXErrorCode(rawValue: error) ?? .EIO)
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let error = errno
            Darwin.close(descriptor)
            if error == EWOULDBLOCK { throw StoreError.busy }
            throw POSIXError(POSIXErrorCode(rawValue: error) ?? .EIO)
        }
        return Lease(descriptor: descriptor)
    }

    private func folder(_ id: UUID) -> URL { directory.appendingPathComponent(id.uuidString, isDirectory: true) }

    private func prepareFolder(_ id: UUID) throws -> URL {
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let url = folder(id)
        try manager.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url
    }

    private func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }

    private static func validMessages(_ messages: [[String: Any]]) -> Bool {
        var ids = Set<String>()
        return messages.allSatisfy { message in
            guard let id = message["id"] as? String, !id.isEmpty, ids.insert(id).inserted,
                  let role = message["role"] as? String, ["user", "assistant"].contains(role),
                  let content = message["content"] as? [[String: Any]] else { return false }
            return content.allSatisfy { block in
                switch block["type"] as? String {
                case "text": return block["text"] is String
                case "tool-call":
                    guard role == "assistant", let id = block["toolCallId"] as? String, !id.isEmpty,
                          block["toolName"] is String, block["args"] is [String: Any] else { return false }
                    guard let result = block["result"] else { return true }
                    guard let value = result as? [String: Any] else { return false }
                    return value["text"] is String && value["detail"] is String && value["label"] is String &&
                        value["isRunning"] is Bool && value["isError"] is Bool
                default: return false
                }
            }
        }
    }
}
