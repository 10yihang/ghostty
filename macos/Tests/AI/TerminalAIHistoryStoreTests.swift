import Foundation
import Testing
@testable import Ghostty

struct TerminalAIHistoryStoreTests {
    @Test func structuredTranscriptRoundTripsAndListsNewestFirst() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let older = snapshot(updatedAt: Date(timeIntervalSince1970: 100))
        let newer = snapshot(updatedAt: Date(timeIntervalSince1970: 200))
        try fixture.store.save(older)
        try fixture.store.save(newer)

        let recovered = try fixture.store.read(id: newer.entry.id)
        #expect(recovered.entry == newer.entry)
        #expect(recovered.phase == "completed")
        #expect(try JSONSerialization.data(withJSONObject: recovered.messages, options: [.sortedKeys]) ==
                JSONSerialization.data(withJSONObject: newer.messages, options: [.sortedKeys]))
        #expect(try fixture.store.list().map(\.id) == [newer.entry.id, older.entry.id])
        let document = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: fixture.transcript(newer.entry.id))) as? [String: Any])
        #expect(Set(document.keys) == ["schemaVersion", "entry", "messages", "phase", "nativeUserMessages"])
    }

    @Test func nativeHumanHistoryRoundTripsWithoutPromotingPiUserMessages() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        var conversation = snapshot()
        conversation.nativeUserMessages = ["检查 CPU 占用，只读排查。", "请继续"]
        conversation.messages[0]["content"] = [["type": "text", "text": "A Pi extension inserted this user prompt."]]
        try fixture.store.save(conversation)

        let recovered = try fixture.store.read(id: conversation.entry.id)
        #expect(recovered.nativeUserMessages == conversation.nativeUserMessages)
        #expect(recovered.nativeUserMessages.allSatisfy { !$0.contains("Pi extension") })
    }

    @Test func legacyTranscriptDoesNotSupplyHumanAuthorization() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let conversation = snapshot()
        try fixture.store.save(conversation)
        let path = fixture.transcript(conversation.entry.id)
        var document = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any])
        document.removeValue(forKey: "nativeUserMessages")
        try JSONSerialization.data(withJSONObject: document).write(to: path)

        let recovered = try fixture.store.read(id: conversation.entry.id)
        #expect(!recovered.messages.isEmpty)
        #expect(recovered.nativeUserMessages.isEmpty)
    }

    @Test(arguments: ["null", "\"not an array\"", "[\"valid\", 7]"])
    func malformedNativeHumanHistoryIsRejected(json: String) throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let conversation = snapshot()
        try fixture.store.save(conversation)
        let path = fixture.transcript(conversation.entry.id)
        var document = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any])
        document["nativeUserMessages"] = try JSONSerialization.jsonObject(with: Data(json.utf8), options: [.fragmentsAllowed])
        try JSONSerialization.data(withJSONObject: document).write(to: path)

        #expect(throws: TerminalAIHistoryStore.StoreError.corrupt) { try fixture.store.read(id: conversation.entry.id) }
    }

    @Test func malformedRecordsAreSkippedAndExplicitReadReportsCorruption() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let valid = snapshot()
        let corrupt = snapshot()
        try fixture.store.save(valid)
        try fixture.store.save(corrupt)
        try Data("broken JSON".utf8).write(to: fixture.transcript(corrupt.entry.id))
        #expect(try fixture.store.list().map(\.id) == [valid.entry.id])
        #expect(throws: TerminalAIHistoryStore.StoreError.corrupt) { try fixture.store.read(id: corrupt.entry.id) }
        #expect(throws: TerminalAIHistoryStore.StoreError.missing) { try fixture.store.read(id: UUID()) }

        var wrongID = snapshot()
        try fixture.store.save(wrongID)
        let path = fixture.transcript(wrongID.entry.id)
        wrongID.entry = entry(id: UUID())
        var document = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any])
        var metadata = try #require(document["entry"] as? [String: Any])
        metadata["id"] = wrongID.entry.id.uuidString
        document["entry"] = metadata
        try JSONSerialization.data(withJSONObject: document).write(to: path)
        #expect(try fixture.store.list().map(\.id) == [valid.entry.id])
    }

    @Test func directoriesAndFilesRemainPrivateAndSessionContentsArePreserved() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let conversation = snapshot()
        let session = try fixture.store.prepareSession(id: conversation.entry.id)
        #expect(try Data(contentsOf: session).isEmpty)
        let piHeader = Data("{\"type\":\"session\",\"version\":3}\n".utf8)
        try piHeader.write(to: session)
        #expect(try fixture.store.prepareSession(id: conversation.entry.id) == session)
        #expect(try Data(contentsOf: session) == piHeader)
        try fixture.store.save(conversation)
        let lease = try fixture.store.acquire(id: conversation.entry.id)
        try withExtendedLifetime(lease) { () throws in
            #expect(try permissions(fixture.store.directory) == 0o700)
            #expect(try permissions(session.deletingLastPathComponent()) == 0o700)
            #expect(try permissions(session) == 0o600)
            #expect(try permissions(fixture.transcript(conversation.entry.id)) == 0o600)
            #expect(try permissions(session.deletingLastPathComponent().appendingPathComponent(".lock")) == 0o600)
        }
        try fixture.store.save(conversation)
        #expect(try permissions(fixture.transcript(conversation.entry.id)) == 0o600)
        let files = try FileManager.default.contentsOfDirectory(atPath: session.deletingLastPathComponent().path)
        #expect(Set(files) == ["conversation.json", "session.jsonl", ".lock"])
    }

    @Test func leaseIsExclusiveAndReleasedWithoutUnlinkingLock() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let id = UUID()
        var first: TerminalAIHistoryStore.Lease? = try fixture.store.acquire(id: id)
        #expect(first != nil)
        _ = withExtendedLifetime(first) {
            #expect(throws: TerminalAIHistoryStore.StoreError.busy) { try fixture.store.acquire(id: id) }
        }
        first = nil
        let next = try fixture.store.acquire(id: id)
        withExtendedLifetime(next) {
            #expect(FileManager.default.fileExists(atPath: fixture.store.sessionURL(id: id).deletingLastPathComponent().appendingPathComponent(".lock").path))
            #expect(throws: TerminalAIHistoryStore.StoreError.busy) {
                try TerminalAIHistoryStore(directory: fixture.store.directory).acquire(id: id)
            }
        }
    }

    @Test func unsupportedMessageShapesAndCountsAreRejected() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        var conversation = snapshot()
        conversation.messages[0]["role"] = "system"
        #expect(throws: TerminalAIHistoryStore.StoreError.corrupt) { try fixture.store.save(conversation) }
        conversation = snapshot()
        conversation.messages[1]["content"] = [["type": "tool-call", "toolCallId": "unfinished"]]
        #expect(throws: TerminalAIHistoryStore.StoreError.corrupt) { try fixture.store.save(conversation) }
        conversation = snapshot()
        conversation.entry.messageCount += 1
        #expect(throws: TerminalAIHistoryStore.StoreError.corrupt) { try fixture.store.save(conversation) }
        #expect(try fixture.store.list().isEmpty)
    }

    private struct Fixture {
        let root: URL
        let store: TerminalAIHistoryStore

        init() throws {
            root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("TerminalAIHistoryStoreTests.\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            store = TerminalAIHistoryStore(directory: root.appendingPathComponent("conversations"))
        }

        func transcript(_ id: UUID) -> URL {
            store.sessionURL(id: id).deletingLastPathComponent().appendingPathComponent("conversation.json")
        }

        func remove() { try? FileManager.default.removeItem(at: root) }
    }

    private func entry(id: UUID = UUID(), updatedAt: Date = Date(timeIntervalSince1970: 100)) -> TerminalAIHistoryStore.Entry {
        TerminalAIHistoryStore.Entry(id: id, title: "检查 CPU 占用", updatedAt: updatedAt,
                                     sourceDirectory: "/fixture/project", workingDirectory: "/fixture/pi",
                                     model: "fixture/model", messageCount: 2)
    }

    private func snapshot(updatedAt: Date = Date(timeIntervalSince1970: 100)) -> TerminalAIHistoryStore.Snapshot {
        TerminalAIHistoryStore.Snapshot(entry: entry(updatedAt: updatedAt), messages: [
            ["id": "user", "role": "user", "content": [["type": "text", "text": "检查 CPU 占用"]]],
            ["id": "assistant", "role": "assistant", "content": [
                ["type": "text", "text": "查看当前终端的进程。"],
                ["type": "tool-call", "toolCallId": "cpu", "toolName": "ghostty_terminal",
                 "args": ["operation": "run", "command": "ps -Ao pid,%cpu,comm -r | head -n 6"],
                 "result": ["text": "PID %CPU COMM\n42 12.5 fixture", "detail": "ps", "label": "Run in terminal",
                            "isRunning": false, "isError": false]]
            ]]
        ], phase: "completed")
    }

    private func permissions(_ url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (try #require(attributes[.posixPermissions] as? NSNumber)).intValue & 0o777
    }
}
