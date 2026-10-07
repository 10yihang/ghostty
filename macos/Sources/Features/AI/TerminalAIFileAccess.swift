import CryptoKit
import Darwin
import Foundation

/// File changes are prepared independently of model-provided patches. The
/// caller owns approval; applying a prepared change never follows a writable
/// path out of the captured local directory.
final class TerminalAIFileAccess {
    private static let limit = 1_048_576
    private let rootURL: URL
    private let rootFD: Int32
    private let rootIdentity: DirectoryIdentity
    private let owner = UUID()

    struct PreparedWrite: Sendable {
        let path: String
        let root: String
        let preview: String
        fileprivate let requestedPath: String
        fileprivate let owner: UUID
        fileprivate let original: Data?
        fileprivate let fingerprint: Fingerprint?
        fileprivate let directories: [DirectoryIdentity]
        fileprivate let content: Data
    }

    fileprivate struct DirectoryIdentity: Equatable, Sendable {
        let device: dev_t
        let inode: ino_t
        init(_ info: stat) { device = info.st_dev; inode = info.st_ino }
    }

    fileprivate struct Fingerprint: Equatable, Sendable {
        let directory: DirectoryIdentity
        let mode: mode_t
        let uid: uid_t
        let gid: gid_t
        let size: off_t
        let modifiedSeconds: Int
        let modifiedNanoseconds: Int
        let changedSeconds: Int
        let changedNanoseconds: Int
        init(_ info: stat) {
            directory = DirectoryIdentity(info)
            mode = info.st_mode
            uid = info.st_uid
            gid = info.st_gid
            size = info.st_size
            modifiedSeconds = info.st_mtimespec.tv_sec
            modifiedNanoseconds = info.st_mtimespec.tv_nsec
            changedSeconds = info.st_ctimespec.tv_sec
            changedNanoseconds = info.st_ctimespec.tv_nsec
        }
    }

    private struct State {
        let data: Data?
        let fingerprint: Fingerprint?
        let directories: [DirectoryIdentity]
    }

    init(directory: String) throws {
        try Self.validatePath(directory)
        guard directory.hasPrefix("/") else { throw Self.issue("Select an absolute local project directory.") }
        let root = URL(fileURLWithPath: directory).resolvingSymlinksInPath().standardizedFileURL
        let fd = Darwin.open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw Self.issue("The local project directory is unavailable.") }
        do {
            let info = try Self.info(fd)
            guard info.st_mode & S_IFMT == S_IFDIR else { throw Self.issue("Select a local project directory.") }
            rootURL = root
            rootFD = fd
            rootIdentity = DirectoryIdentity(info)
        } catch { Darwin.close(fd); throw error }
    }

    deinit { Darwin.close(rootFD) }

    func resolve(path: String, allowMissing: Bool = false) throws -> URL {
        try Self.validatePath(path)
        try validateRoot()
        let input = path.hasPrefix("/") ? URL(fileURLWithPath: path) : rootURL.appendingPathComponent(path)
        // Resolve first: macOS /var and /private/var may name the same root.
        let url = input.resolvingSymlinksInPath().standardizedFileURL
        let prefix = rootURL.path == "/" ? "/" : rootURL.path + "/"
        guard url.path == rootURL.path || url.path.hasPrefix(prefix) else {
            throw Self.issue("The file must stay inside the attached local project directory.")
        }
        let metadata = try metadata(url)
        guard allowMissing || metadata != nil else { throw Self.issue("The requested path does not exist.") }
        if let metadata {
            guard metadata.st_mode & S_IFMT == S_IFREG || metadata.st_mode & S_IFMT == S_IFDIR else {
                throw Self.issue("Access regular project files or directories.")
            }
        }
        return url
    }

    func prepareWrite(path: String, content: String, expectedSHA256: String?) async throws -> PreparedWrite {
        let bytes = Data(content.utf8)
        guard bytes.count <= Self.limit, !bytes.contains(0) else { throw Self.issue("Write one UTF-8 text file of at most 1 MiB.") }
        let url = try resolve(path: path, allowMissing: true)
        guard url.path != rootURL.path else { throw Self.issue("Write a regular file inside the project directory.") }
        let state = try readState(url)
        if let expectedSHA256 {
            guard expectedSHA256.count == 64, expectedSHA256.allSatisfy({ $0.isASCII && $0.isHexDigit }),
                  let data = state.data, Self.sha256(data) == expectedSHA256.lowercased() else {
                throw Self.issue("The file changed since it was read. Read it again before preparing a write.")
            }
        } else if state.data != nil {
            throw Self.issue("An existing file requires its original SHA-256 before preparing a write.")
        }
        let label = String(url.path.dropFirst(rootURL.path == "/" ? 1 : rootURL.path.count + 1))
        let before = state.data
        let preview = try await Task.detached(priority: .utility) {
            try Self.diff(before: before, after: bytes, label: label)
        }.value
        try Task.checkCancellation()
        return PreparedWrite(path: url.path, root: rootURL.path, preview: preview, requestedPath: path,
                             owner: owner, original: before, fingerprint: state.fingerprint,
                             directories: state.directories, content: bytes)
    }

    func apply(_ prepared: PreparedWrite) throws -> [String: Any] {
        guard prepared.owner == owner, prepared.root == rootURL.path,
              try resolve(path: prepared.requestedPath, allowMissing: true).path == prepared.path else {
            throw Self.issue("The file target changed after review. Prepare the write again.")
        }
        let url = URL(fileURLWithPath: prepared.path)
        try validate(try readState(url), against: prepared)
        if prepared.original == prepared.content { return result(prepared, changed: false) }
        let (parent, directories) = try openParent(url, create: true)
        guard let parent else { throw Self.issue("The file's parent directory is unavailable.") }
        defer { Darwin.close(parent) }
        guard Array(directories.prefix(prepared.directories.count)) == prepared.directories else {
            throw Self.issue("The file's parent directory changed after review.")
        }
        let temporary = ".ghostty-ai-write-\(UUID().uuidString)"
        let fd = Darwin.openat(parent, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw Self.issue("Unable to prepare an atomic file write.") }
        defer { Darwin.close(fd); Darwin.unlinkat(parent, temporary, 0) }
        try write(prepared.content, to: fd)
        if let original = prepared.fingerprint {
            let current = try Self.info(fd)
            if (current.st_uid != original.uid || current.st_gid != original.gid) && Darwin.fchown(fd, original.uid, original.gid) != 0 {
                throw Self.issue("Unable to preserve the original file ownership.")
            }
            guard Darwin.fchmod(fd, original.mode & 0o7777) == 0 else { throw Self.issue("Unable to preserve the original file permissions.") }
        }
        guard Darwin.fsync(fd) == 0 else { throw Self.issue("Unable to finish the atomic file write.") }
        try validateRoot()
        guard try resolve(path: prepared.requestedPath, allowMissing: true).path == prepared.path else {
            throw Self.issue("The file target changed while preparing its write.")
        }
        // Recheck immediately before commit. The anchored parent and rename
        // keep the write confined even if the final leaf becomes a symlink.
        try validate(try readState(url), against: prepared)
        let flags: UInt32 = prepared.original == nil ? UInt32(RENAME_EXCL) : 0
        guard Darwin.renameatx_np(parent, temporary, parent, url.lastPathComponent, flags) == 0 else {
            throw Self.issue("The atomic write could not commit; the target may have changed.")
        }
        return result(prepared, changed: true)
    }

    static func sha256(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    private func result(_ prepared: PreparedWrite, changed: Bool) -> [String: Any] {
        ["path": prepared.path, "root": prepared.root, "sha256": Self.sha256(prepared.content),
         "bytes": prepared.content.count, "changed": changed, "output": changed ? "Updated \(prepared.path)" : "No content changes."]
    }

    private func validate(_ state: State, against prepared: PreparedWrite) throws {
        guard state.data == prepared.original, state.fingerprint == prepared.fingerprint,
              Array(state.directories.prefix(prepared.directories.count)) == prepared.directories else {
            throw Self.issue("The file or its parent changed after review. Read it again before writing.")
        }
    }

    private func validateRoot() throws {
        var pathInfo = stat()
        guard rootURL.resolvingSymlinksInPath().standardizedFileURL.path == rootURL.path,
              Darwin.lstat(rootURL.path, &pathInfo) == 0, pathInfo.st_mode & S_IFMT == S_IFDIR,
              DirectoryIdentity(pathInfo) == rootIdentity, DirectoryIdentity(try Self.info(rootFD)) == rootIdentity else {
            throw Self.issue("The local project directory changed. Attach it again before accessing files.")
        }
    }

    private func openParent(_ url: URL, create: Bool) throws -> (Int32?, [DirectoryIdentity]) {
        let prefix = rootURL.path == "/" ? 1 : rootURL.path.count + 1
        let components = String(url.path.dropFirst(prefix)).split(separator: "/").map(String.init)
        var fd = Darwin.openat(rootFD, ".", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw Self.issue("The project directory is unavailable.") }
        defer { if fd >= 0 { Darwin.close(fd) } }
        var directories: [DirectoryIdentity] = []
        for component in components.dropLast() {
            var next = Darwin.openat(fd, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            if next < 0, errno == ENOENT {
                if !create { return (nil, directories) }
                guard Darwin.mkdirat(fd, component, 0o755) == 0 || errno == EEXIST else { throw Self.issue("Unable to create the reviewed parent directory.") }
                next = Darwin.openat(fd, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            }
            guard next >= 0 else { throw Self.issue("The parent path is not a safe project directory.") }
            do { directories.append(DirectoryIdentity(try Self.info(next))) } catch { Darwin.close(next); throw error }
            Darwin.close(fd)
            fd = next
        }
        let result = fd
        fd = -1
        return (result, directories)
    }

    private func metadata(_ url: URL) throws -> stat? {
        if url.path == rootURL.path { return try Self.info(rootFD) }
        let (parent, _) = try openParent(url, create: false)
        guard let parent else { return nil }
        defer { Darwin.close(parent) }
        var value = stat()
        if Darwin.fstatat(parent, url.lastPathComponent, &value, AT_SYMLINK_NOFOLLOW) == 0 { return value }
        if errno == ENOENT { return nil }
        throw Self.issue("The requested path is unavailable.")
    }

    private func readState(_ url: URL) throws -> State {
        let (parent, directories) = try openParent(url, create: false)
        guard let parent else { return State(data: nil, fingerprint: nil, directories: directories) }
        defer { Darwin.close(parent) }
        let fd = Darwin.openat(parent, url.lastPathComponent, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if fd < 0, errno == ENOENT { return State(data: nil, fingerprint: nil, directories: directories) }
        guard fd >= 0 else { throw Self.issue("The requested file is not a safe regular text file.") }
        defer { Darwin.close(fd) }
        let before = try Self.info(fd)
        guard before.st_mode & S_IFMT == S_IFREG, before.st_size <= Self.limit else { throw Self.issue("Read one regular UTF-8 text file of at most 1 MiB.") }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        var data = Data()
        while let chunk = try handle.read(upToCount: 65_536), !chunk.isEmpty {
            data.append(chunk)
            guard data.count <= Self.limit else { throw Self.issue("The file exceeds the 1 MiB text limit.") }
        }
        guard Fingerprint(try Self.info(fd)) == Fingerprint(before), !data.contains(0), String(data: data, encoding: .utf8) != nil else {
            throw Self.issue("The file changed while being read or is not UTF-8 text.")
        }
        return State(data: data, fingerprint: Fingerprint(before), directories: directories)
    }

    private func write(_ data: Data, to fd: Int32) throws {
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw Self.issue("Unable to write the reviewed file contents.") }
                offset += count
            }
        }
    }

    private static func diff(before: Data?, after: Data, label: String) throws -> String {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("GhosttyAIFileDiff.\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let old = directory.appendingPathComponent("before")
        let new = directory.appendingPathComponent("after")
        try (before ?? Data()).write(to: old)
        try after.write(to: new)
        for file in [old, new] { try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path) }
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/diff")
        process.arguments = ["-u", "-L", before == nil ? "/dev/null" : "a/" + label, "-L", "b/" + label, old.path, new.path]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = try output.fileHandleForReading.readToEnd() ?? Data()
        process.waitUntilExit()
        guard process.terminationStatus == 0 || process.terminationStatus == 1,
              data.count <= 65_536, let text = String(data: data, encoding: .utf8) else {
            throw issue("The independent diff could not be prepared within the 64 KiB preview limit.")
        }
        if before == nil, after.isEmpty { return "Create empty file: \(label)" }
        return text
    }

    private static func info(_ fd: Int32) throws -> stat {
        var value = stat()
        guard Darwin.fstat(fd, &value) == 0 else { throw issue("The file identity is unavailable.") }
        return value
    }

    private static func validatePath(_ path: String) throws {
        guard !path.isEmpty, path.utf8.count <= 4096,
              !path.unicodeScalars.contains(where: {
                  switch $0.properties.generalCategory {
                  case .control, .format, .lineSeparator, .paragraphSeparator: return true
                  default: return false
                  }
              }) else { throw issue("Use a nonempty file path without control characters.") }
    }

    private static func issue(_ message: String) -> NSError {
        NSError(domain: "GhosttyAIFileAccess", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
