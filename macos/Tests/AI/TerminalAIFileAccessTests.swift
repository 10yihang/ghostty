import Darwin
import Foundation
import Testing
@testable import Ghostty

@Suite(.serialized)
struct TerminalAIFileAccessTests {
    @Test func resolutionAcceptsMacAliasesButRejectsSiblingPrefixesAndEscapingSymlinks() throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let file = fixture.project.appendingPathComponent("inside.txt")
        try "inside".write(to: file, atomically: true, encoding: .utf8)
        let outside = fixture.sibling.appendingPathComponent("outside.txt")
        try "outside".write(to: outside, atomically: true, encoding: .utf8)
        let access = try TerminalAIFileAccess(directory: fixture.project.path)
        #expect(try access.resolve(path: ".").path == fixture.project.resolvingSymlinksInPath().path)
        #expect(try access.resolve(path: fixture.project.path).path == fixture.project.resolvingSymlinksInPath().path)
        let subdirectory = fixture.project.appendingPathComponent("subdirectory")
        try FileManager.default.createDirectory(at: subdirectory, withIntermediateDirectories: false)
        #expect(try access.resolve(path: "subdirectory").path == subdirectory.resolvingSymlinksInPath().path)
        #expect(try access.resolve(path: "inside.txt") == file.resolvingSymlinksInPath())
        #expect(try access.resolve(path: file.path) == file.resolvingSymlinksInPath())
        let canonical = file.resolvingSymlinksInPath().path
        let alias = canonical.replacingOccurrences(of: "/private/var/", with: "/var/")
        #expect(try access.resolve(path: alias).path == canonical)
        #expect(throws: (any Error).self) { try access.resolve(path: outside.path) }
        #expect(throws: (any Error).self) { try access.resolve(path: "../project-other/outside.txt") }
        let escape = fixture.project.appendingPathComponent("escape")
        try FileManager.default.createSymbolicLink(at: escape, withDestinationURL: fixture.sibling)
        #expect(throws: (any Error).self) { try access.resolve(path: "escape/outside.txt") }
        #expect(throws: (any Error).self) { try access.resolve(path: "escape/missing/new.txt", allowMissing: true) }
    }

    @Test func prepareIsReadOnlyAndApprovedApplyUsesItsNativeDiffAndPreservesPermissions() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let file = fixture.project.appendingPathComponent("example.txt")
        let original = Data("before 中文\n".utf8)
        try original.write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: file.path)
        let before = try identity(file)
        let access = try TerminalAIFileAccess(directory: fixture.project.path)
        let prepared = try await access.prepareWrite(path: "example.txt", content: "after 中文\n",
                                                    expectedSHA256: TerminalAIFileAccess.sha256(original))
        #expect(prepared.root == fixture.project.resolvingSymlinksInPath().path)
        #expect(prepared.path == file.resolvingSymlinksInPath().path)
        #expect(prepared.preview.contains("-before 中文"))
        #expect(prepared.preview.contains("+after 中文"))
        #expect(try Data(contentsOf: file) == original)
        #expect(try identity(file).st_ino == before.st_ino)
        let result = try access.apply(prepared)
        #expect(try String(contentsOf: file, encoding: .utf8) == "after 中文\n")
        #expect(result["changed"] as? Bool == true)
        #expect(result["bytes"] as? Int == "after 中文\n".utf8.count)
        #expect(result["sha256"] as? String == TerminalAIFileAccess.sha256(Data("after 中文\n".utf8)))
        let after = try identity(file)
        #expect(after.st_mode & 0o7777 == 0o640)
        #expect(after.st_uid == before.st_uid)
        #expect(after.st_gid == before.st_gid)
        #expect(throws: (any Error).self) { try access.apply(prepared) }
    }

    @Test func discardedPrepareCreatesNeitherTargetNorDirectoriesAndNilHashCannotOverwrite() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let access = try TerminalAIFileAccess(directory: fixture.project.path)
        let prepared = try await access.prepareWrite(path: "new/nested/file.txt", content: "new text\n", expectedSHA256: nil)
        #expect(prepared.preview.contains("--- /dev/null"))
        #expect(prepared.preview.contains("+new text"))
        #expect(!FileManager.default.fileExists(atPath: fixture.project.appendingPathComponent("new").path))
        let existing = fixture.project.appendingPathComponent("existing.txt")
        try "keep".write(to: existing, atomically: true, encoding: .utf8)
        await #expect(throws: (any Error).self) {
            try await access.prepareWrite(path: "existing.txt", content: "replace", expectedSHA256: nil)
        }
        #expect(try String(contentsOf: existing, encoding: .utf8) == "keep")
        _ = try access.apply(prepared)
        #expect(try String(contentsOfFile: prepared.path, encoding: .utf8) == "new text\n")
    }

    @Test func wrongHashAndChangesAfterReviewAreRejectedWithoutLosingTheNewerFile() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let file = fixture.project.appendingPathComponent("conflict.txt")
        let original = Data("original\n".utf8)
        try original.write(to: file)
        let access = try TerminalAIFileAccess(directory: fixture.project.path)
        await #expect(throws: (any Error).self) {
            try await access.prepareWrite(path: "conflict.txt", content: "model change", expectedSHA256: String(repeating: "0", count: 64))
        }
        let prepared = try await access.prepareWrite(path: "conflict.txt", content: "model change",
                                                    expectedSHA256: TerminalAIFileAccess.sha256(original))
        try "human change".write(to: file, atomically: true, encoding: .utf8)
        #expect(throws: (any Error).self) { try access.apply(prepared) }
        #expect(try String(contentsOf: file, encoding: .utf8) == "human change")
        try original.write(to: file, options: .atomic)
        #expect(throws: (any Error).self) { try access.apply(prepared) }
        #expect(try Data(contentsOf: file) == original)
    }

    @Test func aSymlinkChangeAfterReviewCannotModifyTheOutsideTarget() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let original = fixture.project.appendingPathComponent("target.txt")
        let outside = fixture.sibling.appendingPathComponent("target.txt")
        try "inside\n".write(to: original, atomically: true, encoding: .utf8)
        try "outside must stay\n".write(to: outside, atomically: true, encoding: .utf8)
        let link = fixture.project.appendingPathComponent("link.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: original)
        let access = try TerminalAIFileAccess(directory: fixture.project.path)
        let prepared = try await access.prepareWrite(path: "link.txt", content: "reviewed change\n",
                                                    expectedSHA256: TerminalAIFileAccess.sha256(Data("inside\n".utf8)))
        try FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        #expect(throws: (any Error).self) { try access.apply(prepared) }
        #expect(try String(contentsOf: outside, encoding: .utf8) == "outside must stay\n")
        #expect(try String(contentsOf: original, encoding: .utf8) == "inside\n")
    }

    @Test func replacingAParentAfterReviewCannotRedirectANewFileWrite() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let directory = fixture.project.appendingPathComponent("nested")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let access = try TerminalAIFileAccess(directory: fixture.project.path)
        let prepared = try await access.prepareWrite(path: "nested/new.txt", content: "reviewed", expectedSHA256: nil)
        try FileManager.default.removeItem(at: directory)
        try FileManager.default.createSymbolicLink(at: directory, withDestinationURL: fixture.sibling)
        #expect(throws: (any Error).self) { try access.apply(prepared) }
        #expect(!FileManager.default.fileExists(atPath: fixture.sibling.appendingPathComponent("new.txt").path))
    }

    @Test func nonregularBinaryOversizedAndAmbiguousPathsFailClosed() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let access = try TerminalAIFileAccess(directory: fixture.project.path)
        let fifo = fixture.project.appendingPathComponent("pipe")
        #expect(Darwin.mkfifo(fifo.path, 0o600) == 0)
        #expect(throws: (any Error).self) { try access.resolve(path: "pipe") }
        let binary = fixture.project.appendingPathComponent("binary")
        let binaryData = Data([0xFF, 0x00, 0xFE])
        try binaryData.write(to: binary)
        await #expect(throws: (any Error).self) {
            try await access.prepareWrite(path: "binary", content: "replace", expectedSHA256: TerminalAIFileAccess.sha256(binaryData))
        }
        for directory in [".", fixture.project.path] {
            await #expect(throws: (any Error).self) {
                try await access.prepareWrite(path: directory, content: "replace", expectedSHA256: nil)
            }
        }
        for path in ["", "file\u{0}suffix", "file\nother", "file\u{202E}other", String(repeating: "x", count: 4097)] {
            #expect(throws: (any Error).self) { try access.resolve(path: path, allowMissing: true) }
        }
        await #expect(throws: (any Error).self) {
            try await access.prepareWrite(path: "too-large", content: String(repeating: "x", count: 1_048_577), expectedSHA256: nil)
        }
        await #expect(throws: (any Error).self) {
            try await access.prepareWrite(path: "zero-byte", content: "text\u{0}binary", expectedSHA256: nil)
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.project.appendingPathComponent("too-large").path))
    }

    @Test func oversizedDiffIsRejectedAndAPreparedWriteCannotMoveToAnotherAccessRoot() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let access = try TerminalAIFileAccess(directory: fixture.project.path)
        await #expect(throws: (any Error).self) {
            try await access.prepareWrite(path: "large-preview", content: String(repeating: "new line\n", count: 10_000), expectedSHA256: nil)
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.project.appendingPathComponent("large-preview").path))
        let prepared = try await access.prepareWrite(path: "new.txt", content: "new", expectedSHA256: nil)
        let other = try TerminalAIFileAccess(directory: fixture.sibling.path)
        #expect(throws: (any Error).self) { try other.apply(prepared) }
        #expect(!FileManager.default.fileExists(atPath: fixture.sibling.appendingPathComponent("new.txt").path))
    }

    private func identity(_ url: URL) throws -> stat {
        var value = stat()
        try #require(Darwin.lstat(url.path, &value) == 0)
        return value
    }

    private struct Fixture {
        let temporary: URL
        let project: URL
        let sibling: URL
        init() throws {
            temporary = FileManager.default.temporaryDirectory.appendingPathComponent("GhosttyAIFileAccessTests.\(UUID())")
            project = temporary.appendingPathComponent("project")
            sibling = temporary.appendingPathComponent("project-other")
            for directory in [project, sibling] {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            }
        }
        func close() { try? FileManager.default.removeItem(at: temporary) }
    }
}
