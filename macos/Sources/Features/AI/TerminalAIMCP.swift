import Combine
import Darwin
import Foundation

struct TerminalAIMCPServer: Codable, Identifiable, Equatable {
    enum Transport: String, Codable, CaseIterable { case stdio, http }
    var id = UUID()
    var name = ""
    var transport = Transport.stdio
    var enabled = true
    var executable = ""
    var arguments: [String] = []
    var environmentKeys: [String] = []
    var endpoint = ""
    var workingDirectory = ""
    var revision: UUID?

    func validate() throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.count <= 200 else {
            throw TerminalAIMCPError.invalid("Give the MCP server a name.")
        }
        switch transport {
        case .stdio:
            guard executable.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: executable) else {
                throw TerminalAIMCPError.invalid("Choose an absolute path to an executable MCP server.")
            }
            guard arguments.count <= 256, arguments.reduce(0, { $0 + $1.utf8.count }) <= 65536,
                  !arguments.contains(where: { $0.contains("\0") }), !executable.contains("\0") else {
                throw TerminalAIMCPError.invalid("MCP executable arguments cannot contain NUL characters.")
            }
            if !workingDirectory.isEmpty {
                var folder: ObjCBool = false
                guard workingDirectory.hasPrefix("/"),
                      FileManager.default.fileExists(atPath: workingDirectory, isDirectory: &folder), folder.boolValue else {
                    throw TerminalAIMCPError.invalid("The MCP working directory must be an existing local folder.")
                }
            }
        case .http:
            guard let url = URL(string: endpoint), let host = url.host,
                  url.user == nil, url.password == nil, url.fragment == nil,
                  url.scheme == "https" || (url.scheme == "http" && ["localhost", "127.0.0.1", "[::1]", "::1"].contains(host)) else {
                throw TerminalAIMCPError.invalid("Use an HTTPS MCP endpoint, or HTTP on localhost. Put credentials in the token field.")
            }
        }
    }
}

struct TerminalAIMCPDiscovery {
    let serverInfo: [String: Any]
    let tools: [[String: Any]]
    let resources: [[String: Any]]
}

enum TerminalAIMCPError: LocalizedError {
    case invalid(String), server(String), disconnected, timedOut

    var errorDescription: String? {
        switch self {
        case .invalid(let message), .server(let message): return message
        case .disconnected: return "The MCP server disconnected. Reconnect before trying again."
        case .timedOut: return "The MCP request timed out. A tool's execution outcome may be unknown; check before retrying."
        }
    }
}

/// Server configuration is local; credentials stay in Ghostty's Keychain namespace.
/// No configured process or endpoint is contacted until the user tests it or approves agent access.
@MainActor
final class TerminalAIMCPManager: ObservableObject {
    @Published private(set) var servers: [TerminalAIMCPServer] = []
    @Published private(set) var statuses: [UUID: String] = [:]
    @Published private(set) var discoveries: [UUID: TerminalAIMCPDiscovery] = [:]
    @Published private(set) var error: String?

    private let directory: URL
    private var clients: [UUID: TerminalAIMCPClient] = [:]
    private var clientSignatures: [UUID: String] = [:]

    init(directory: URL) {
        self.directory = directory
        do { try refresh() } catch { self.error = "The saved MCP configuration could not be read. Check servers.json before saving changes." }
    }

    func refresh() throws {
        let lease = try profileLease()
        try withExtendedLifetime(lease) { try publish(readProfiles()) }
    }

    /// Capture the visible profile for approval; perform() checks it against authoritative storage.
    func configurationSignature(for id: UUID) throws -> String {
        guard let server = servers.first(where: { $0.id == id && $0.enabled }) else {
            throw TerminalAIMCPError.invalid("This MCP server is unavailable or disabled.")
        }
        return try signature(server)
    }

    func save(_ server: TerminalAIMCPServer, bearerToken: String? = nil, environment: [String: String]? = nil) throws {
        try server.validate()
        if let environment {
            guard environment.keys.allSatisfy({ !$0.isEmpty && !$0.contains("=") && !$0.contains("\0") }),
                  environment.values.allSatisfy({ !$0.contains("\0") }) else {
                throw TerminalAIMCPError.invalid("Environment names cannot contain '=' or NUL; values cannot contain NUL.")
            }
        }
        let lease = try profileLease()
        try withExtendedLifetime(lease) {
            var next = try readProfiles()
            let previous = next.first { $0.id == server.id }
            guard previous == nil || previous?.revision == server.revision else {
                throw TerminalAIMCPError.invalid("This MCP profile changed in another window. Refresh and reopen its editor before saving.")
            }
            var updated = server
            updated.revision = UUID()
            let token = bearerToken ?? previous.flatMap { TerminalAICredentials.load(provider: credentialKey($0, kind: "token")) } ?? ""
            let oldEnvironment = previous.flatMap { TerminalAICredentials.load(provider: credentialKey($0, kind: "environment")) } ?? ""
            let encoded = try environment.map { try JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys]) }
            let values = encoded.flatMap { String(data: $0, encoding: .utf8) } ?? oldEnvironment
            if let environment { updated.environmentKeys = environment.keys.sorted() } else if let previous { updated.environmentKeys = previous.environmentKeys }
            next.removeAll { $0.id == server.id }
            next.append(updated)
            do {
                // New secrets are staged separately; the atomic profile rename commits their revision.
                try TerminalAICredentials.store(token, provider: credentialKey(updated, kind: "token"))
                try TerminalAICredentials.store(values, provider: credentialKey(updated, kind: "environment"))
                try persist(next)
            } catch {
                clearCredentials(updated)
                throw error
            }
            if let previous { clearCredentials(previous) }
            try publish(next)
        }
    }

    func remove(_ id: UUID) throws {
        let lease = try profileLease()
        try withExtendedLifetime(lease) {
            let current = try readProfiles()
            try persist(current.filter { $0.id != id })
            if let previous = current.first(where: { $0.id == id }) { clearCredentials(previous) }
            try publish(current.filter { $0.id != id })
        }
    }

    func test(_ id: UUID) async throws -> TerminalAIMCPDiscovery {
        statuses[id] = "Connecting…"
        let client = try connection(id)
        do {
            try await client.initialize()
            let tools = try await client.list("tools/list", key: "tools")
            let resources = try await client.list("resources/list", key: "resources")
            try refresh()
            guard clients[id] === client else { throw TerminalAIMCPError.invalid("The MCP profile changed while discovering its tools. Test the current profile again.") }
            let discovery = TerminalAIMCPDiscovery(serverInfo: client.serverInfo, tools: tools, resources: resources)
            discoveries[id] = discovery
            statuses[id] = "Connected · \(tools.count) tools · \(resources.count) resources"
            return discovery
        } catch {
            if clients[id] === client {
                statuses[id] = error.localizedDescription
                clients.removeValue(forKey: id)?.close()
            }
            throw error
        }
    }

    /// The native host authorizes calls and resource reads before entering this method.
    func perform(request: [String: Any]) async throws -> [String: Any] {
        let operation = request["operation"] as? String ?? ""
        if operation == "list_servers" {
            try refresh()
            let available = servers.filter(\.enabled).map { ["id": $0.id.uuidString, "name": $0.name, "transport": $0.transport.rawValue] }
            return response(operation: operation, server: "", result: ["servers": available])
        }
        guard ["list_tools", "list_resources", "call_tool", "read_resource"].contains(operation) else {
            throw TerminalAIMCPError.invalid("Unsupported MCP operation.")
        }
        guard let raw = request["server"] as? String, let id = UUID(uuidString: raw) else {
            throw TerminalAIMCPError.invalid("Choose an enabled MCP server ID from list_servers.")
        }
        let client = try connection(id, approved: request["_approvedConfiguration"] as? String)
        do {
            try await client.initialize()
            let result: [String: Any]
            switch operation {
            case "list_tools": result = ["tools": try await client.list("tools/list", key: "tools")]
            case "list_resources": result = ["resources": try await client.list("resources/list", key: "resources")]
            case "call_tool":
                guard let name = request["toolName"] as? String, !name.isEmpty,
                      let arguments = request["arguments"] as? [String: Any], JSONSerialization.isValidJSONObject(arguments) else {
                    throw TerminalAIMCPError.invalid("An MCP tool call needs a tool name and an arguments object.")
                }
                let tools = try await client.list("tools/list", key: "tools")
                guard tools.contains(where: { $0["name"] as? String == name }) else {
                    throw TerminalAIMCPError.invalid("This MCP server did not advertise the requested tool.")
                }
                result = try await client.request(method: "tools/call", params: ["name": name, "arguments": arguments])
            case "read_resource":
                guard let uri = request["uri"] as? String, !uri.isEmpty, uri.utf8.count <= 16384 else {
                    throw TerminalAIMCPError.invalid("Provide a resource URI from this MCP server.")
                }
                result = try await client.request(method: "resources/read", params: ["uri": uri])
            default: throw TerminalAIMCPError.invalid("Unsupported MCP operation.")
            }
            return response(operation: operation, server: raw, result: result)
        } catch {
            if clients[id] === client { clients.removeValue(forKey: id)?.close() }
            throw error
        }
    }

    func close() {
        for client in clients.values { client.close() }
        clients.removeAll()
        clientSignatures.removeAll()
    }

    private func connection(_ id: UUID, approved: String? = nil) throws -> TerminalAIMCPClient {
        let lease = try profileLease()
        return try withExtendedLifetime(lease) {
            try publish(readProfiles())
            let current = try configurationSignature(for: id)
            if let approved, approved != current {
                throw TerminalAIMCPError.invalid("The MCP server configuration changed after review. Review the new target and credentials before retrying.")
            }
            guard let server = servers.first(where: { $0.id == id && $0.enabled }) else {
                throw TerminalAIMCPError.invalid("This MCP server is unavailable or disabled.")
            }
            if let client = clients[id], clientSignatures[id] == current { return client }
            try server.validate()
            let token = TerminalAICredentials.load(provider: credentialKey(server, kind: "token"))
            let environment = TerminalAICredentials.load(provider: credentialKey(server, kind: "environment"))
            .flatMap { $0.data(using: .utf8) }
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: String] } ?? [:]
            let client = TerminalAIMCPClient(server: server, token: token, environment: environment)
            clients[id] = client
            clientSignatures[id] = current
            return client
        }
    }

    private func response(operation: String, server: String, result: [String: Any]) -> [String: Any] {
        let data = (try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])) ?? Data()
        let text = String(data: data, encoding: .utf8) ?? ""
        return ["operation": operation, "server": server, "result": result, "output": text, "isError": result["isError"] as? Bool ?? false]
    }

    private func credentialKey(_ server: TerminalAIMCPServer, kind: String) -> String {
        "mcp.\(server.id.uuidString)\(server.revision.map { ".\($0.uuidString)" } ?? "").\(kind)"
    }

    private func clearCredentials(_ server: TerminalAIMCPServer) {
        try? TerminalAICredentials.store("", provider: credentialKey(server, kind: "token"))
        try? TerminalAICredentials.store("", provider: credentialKey(server, kind: "environment"))
    }

    private func profileLease() throws -> TerminalAIHistoryStore.Lease {
        do {
            return try TerminalAIHistoryStore(directory: directory.appendingPathComponent("locks"))
                .acquire(id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!)
        } catch TerminalAIHistoryStore.StoreError.busy {
            throw TerminalAIMCPError.invalid("MCP settings are being updated in another window. Try again.")
        }
    }

    private func readProfiles() throws -> [TerminalAIMCPServer] {
        let file = directory.appendingPathComponent("servers.json")
        guard FileManager.default.fileExists(atPath: file.path) else { return [] }
        let values = try JSONDecoder().decode([TerminalAIMCPServer].self, from: Data(contentsOf: file))
        guard Set(values.map(\.id)).count == values.count else { throw TerminalAIMCPError.invalid("Duplicate MCP server IDs.") }
        return values
    }

    private func signature(_ server: TerminalAIMCPServer) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(server).base64EncodedString()
    }

    private func publish(_ values: [TerminalAIMCPServer]) throws {
        let latest = try Dictionary(uniqueKeysWithValues: values.map { ($0.id, try signature($0)) })
        let previous = try Dictionary(uniqueKeysWithValues: servers.map { ($0.id, try signature($0)) })
        for id in Set(previous.keys).union(clients.keys)
            where latest[id] != previous[id] || (clients[id] != nil && latest[id] != clientSignatures[id]) {
            clients.removeValue(forKey: id)?.close()
            clientSignatures.removeValue(forKey: id)
            discoveries.removeValue(forKey: id)
            statuses.removeValue(forKey: id)
        }
        servers = values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        error = nil
    }

    private func persist(_ values: [TerminalAIMCPServer]) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let file = directory.appendingPathComponent("servers.json")
        let temporary = directory.appendingPathComponent(".\(UUID().uuidString).tmp")
        let descriptor = Darwin.open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, mode_t(0o600))
        guard descriptor >= 0 else { throw POSIXError(.EIO) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close(); try? FileManager.default.removeItem(at: temporary) }
        try handle.write(contentsOf: JSONEncoder().encode(values))
        try handle.synchronize()
        try handle.close()
        guard Darwin.rename(temporary.path, file.path) == 0 else { throw POSIXError(.EIO) }
    }
}

/// Only MCP JSON-RPC reaches this client. It never accepts a shell command string.
@MainActor
final class TerminalAIMCPClient {
    private(set) var serverInfo: [String: Any] = [:]
    private let server: TerminalAIMCPServer
    private let token: String?
    private let environment: [String: String]
    private let timeout: TimeInterval
    private var initialized = false
    private var initialization: Task<Void, Error>?
    private var protocolVersion = "2025-11-25"
    private var capabilities: [String: Any] = [:]
    private var sessionID: String?
    private var sequence = 0
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var errors: FileHandle?
    private var buffer = Data()
    private var pending: [Int: CheckedContinuation<[String: Any], Error>] = [:]
    private var timers: [Int: Task<Void, Never>] = [:]
    private let writes = DispatchQueue(label: "com.mitchellh.ghostty.mcp-stdin")
    private let session = URLSession(configuration: .ephemeral, delegate: TerminalAIMCPHTTPDelegate(), delegateQueue: nil)
    private let maxBytes = 4 * 1024 * 1024

    init(server: TerminalAIMCPServer, token: String? = nil, environment: [String: String] = [:], timeout: TimeInterval = 30) {
        self.server = server
        self.token = token
        self.environment = environment
        self.timeout = timeout
    }

    deinit {
        initialization?.cancel()
        for timer in timers.values { timer.cancel() }
        for continuation in pending.values { continuation.resume(throwing: TerminalAIMCPError.disconnected) }
        output?.readabilityHandler = nil
        errors?.readabilityHandler = nil
        try? input?.close()
        try? output?.close()
        try? errors?.close()
        process?.terminationHandler = nil
        if let process, process.isRunning { process.terminate() }
        session.invalidateAndCancel()
    }

    func initialize() async throws {
        if initialized { return }
        if let initialization { return try await initialization.value }
        let task = Task { @MainActor in
            try server.validate()
            if server.transport == .stdio { try launch() }
            let result = try await request(method: "initialize", params: [
                "protocolVersion": protocolVersion, "capabilities": [:] as [String: Any],
                "clientInfo": ["name": "ghostty-terminal-ai", "version": "1.0"]
            ])
            guard let version = result["protocolVersion"] as? String,
                  ["2024-11-05", "2025-03-26", "2025-06-18", "2025-11-25"].contains(version),
                  let info = result["serverInfo"] as? [String: Any], let advertised = result["capabilities"] as? [String: Any] else {
                throw TerminalAIMCPError.server("The MCP server returned an unsupported initialization response.")
            }
            protocolVersion = version
            serverInfo = info
            capabilities = advertised
            try await notify(method: "notifications/initialized", params: nil)
            initialized = true
        }
        initialization = task
        do { try await task.value; initialization = nil } catch { initialization = nil; close(); throw error }
    }

    func list(_ method: String, key: String) async throws -> [[String: Any]] {
        let capability = key == "tools" ? "tools" : "resources"
        guard capabilities[capability] != nil else { return [] }
        var items: [[String: Any]] = []
        var cursor: String?
        var seen = Set<String>()
        repeat {
            let result = try await request(method: method, params: cursor.map { ["cursor": $0] } ?? [:])
            guard let page = result[key] as? [[String: Any]] else {
                throw TerminalAIMCPError.server("The MCP server returned an invalid \(key) list.")
            }
            items.append(contentsOf: page)
            guard items.count <= 2000 else { throw TerminalAIMCPError.server("The MCP catalog exceeded 2,000 entries.") }
            cursor = result["nextCursor"] as? String
            if let cursor, !seen.insert(cursor).inserted { throw TerminalAIMCPError.server("The MCP server repeated a pagination cursor.") }
        } while cursor != nil
        return items
    }

    func request(method: String, params: [String: Any], timeout requestTimeout: TimeInterval? = nil) async throws -> [String: Any] {
        try Task.checkCancellation()
        let deadline = requestTimeout ?? timeout
        guard deadline.isFinite, deadline > 0, deadline <= 300 else { throw TerminalAIMCPError.invalid("The MCP request timeout must be positive and at most 300 seconds.") }
        sequence += 1
        let id = sequence
        let message: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": method, "params": params]
        if server.transport == .http {
            do {
                guard let record = try await http(message, expectedID: id, timeout: deadline) else { throw TerminalAIMCPError.disconnected }
                return try result(record)
            } catch {
                let cancel: Bool
                switch error {
                case is CancellationError, TerminalAIMCPError.timedOut: cancel = true
                case let urlError as URLError where urlError.code == .cancelled: cancel = true
                default: cancel = false
                }
                if cancel {
                    let cancellation = Task { @MainActor in
                        try await notify(method: "notifications/cancelled", params: ["requestId": id, "reason": "Cancelled by Ghostty"])
                    }
                    try? await cancellation.value
                }
                throw error
            }
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard let input, process?.isRunning == true else { continuation.resume(throwing: TerminalAIMCPError.disconnected); return }
                pending[id] = continuation
                timers[id] = Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: UInt64(deadline * 1_000_000_000))
                    guard !Task.isCancelled else { return }
                    self?.cancel(id, error: TerminalAIMCPError.timedOut)
                }
                do {
                    let data = try encode(message)
                    writes.async { [weak self] in
                        do { try input.write(contentsOf: data) } catch { Task { @MainActor in self?.complete(id, outcome: .failure(error)) } }
                    }
                } catch { complete(id, outcome: .failure(error)) }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancel(id, error: CancellationError()) }
        }
    }

    func close() {
        initialized = false
        initialization?.cancel()
        initialization = nil
        for id in Array(pending.keys) { complete(id, outcome: .failure(TerminalAIMCPError.disconnected)) }
        output?.readabilityHandler = nil
        errors?.readabilityHandler = nil
        try? input?.close()
        try? output?.close()
        try? errors?.close()
        input = nil
        output = nil
        errors = nil
        if let process, process.isRunning {
            process.terminate()
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
            }
        }
        process = nil
        session.invalidateAndCancel()
        if server.transport == .http, let sessionID, let url = URL(string: server.endpoint) {
            var request = URLRequest(url: url, timeoutInterval: 3)
            request.httpMethod = "DELETE"
            request.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id")
            request.setValue(protocolVersion, forHTTPHeaderField: "MCP-Protocol-Version")
            if let token, !token.isEmpty { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
            Task {
                let closingSession = URLSession(configuration: .ephemeral, delegate: TerminalAIMCPHTTPDelegate(), delegateQueue: nil)
                defer { closingSession.invalidateAndCancel() }
                _ = try? await closingSession.data(for: request)
            }
        }
        sessionID = nil
    }

    private func launch() throws {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: server.executable)
        child.arguments = server.arguments
        child.environment = ProcessInfo.processInfo.environment.merging(environment) { _, configured in configured }
        if !server.workingDirectory.isEmpty { child.currentDirectoryURL = URL(fileURLWithPath: server.workingDirectory) }
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        child.standardInput = stdin
        child.standardOutput = stdout
        child.standardError = stderr
        input = stdin.fileHandleForWriting
        output = stdout.fileHandleForReading
        errors = stderr.fileHandleForReading
        output?.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil }
            DispatchQueue.main.async { [weak self] in self?.receive(data) }
        }
        // Drain diagnostic output without exposing server environment or tokens in the UI.
        errors?.readabilityHandler = { handle in
            if handle.availableData.isEmpty { handle.readabilityHandler = nil }
        }
        // Stdout EOF closes the connection after its final response has been drained.
        process = child
        try child.run()
    }

    private func receive(_ data: Data) {
        guard !data.isEmpty else { close(); return }
        buffer.append(data)
        guard buffer.count <= maxBytes else { close(); return }
        while let newline = buffer.firstIndex(of: 10) {
            let line = buffer[..<newline]
            buffer.removeSubrange(...newline)
            guard let message = try? JSONSerialization.jsonObject(with: line) as? [String: Any], message["jsonrpc"] as? String == "2.0" else {
                close(); return
            }
            if let id = message["id"] as? Int, message["method"] == nil {
                do { complete(id, outcome: .success(try result(message))) } catch { complete(id, outcome: .failure(error)) }
            } else if message["method"] != nil, let id = message["id"] {
                let reply = serverReply(message, id: id)
                if let data = try? encode(reply), let input { writes.async { try? input.write(contentsOf: data) } }
            }
        }
    }

    private func complete(_ id: Int, outcome: Result<[String: Any], Error>) {
        timers.removeValue(forKey: id)?.cancel()
        pending.removeValue(forKey: id)?.resume(with: outcome)
    }

    private func cancel(_ id: Int, error: Error) {
        guard pending[id] != nil else { return }
        if let data = try? encode(["jsonrpc": "2.0", "method": "notifications/cancelled", "params": ["requestId": id, "reason": "Cancelled by Ghostty"]]), let input {
            writes.async { try? input.write(contentsOf: data) }
        }
        complete(id, outcome: .failure(error))
    }

    private func notify(method: String, params: [String: Any]?) async throws {
        var message: [String: Any] = ["jsonrpc": "2.0", "method": method]
        if let params { message["params"] = params }
        if server.transport == .http { _ = try await http(message, expectedID: nil) } else {
            guard let input else { throw TerminalAIMCPError.disconnected }
            let data = try encode(message)
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                writes.async {
                    do { try input.write(contentsOf: data); continuation.resume() } catch { continuation.resume(throwing: error) }
                }
            }
        }
    }

    private func encode(_ message: [String: Any]) throws -> Data {
        var data = try JSONSerialization.data(withJSONObject: message)
        guard data.count <= maxBytes else { throw TerminalAIMCPError.invalid("The MCP request exceeds 4 MiB.") }
        data.append(10)
        return data
    }

    private func result(_ message: [String: Any]) throws -> [String: Any] {
        if let error = message["error"] as? [String: Any] {
            throw TerminalAIMCPError.server("MCP error \(error["code"] as? Int ?? 0): \((error["message"] as? String ?? "Request failed").prefix(1024))")
        }
        guard let result = message["result"] as? [String: Any] else {
            throw TerminalAIMCPError.server("The MCP server returned an invalid JSON-RPC result.")
        }
        return result
    }

    private func serverReply(_ message: [String: Any], id: Any) -> [String: Any] {
        if message["method"] as? String == "ping" { return ["jsonrpc": "2.0", "id": id, "result": [:] as [String: Any]] }
        return ["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "Ghostty does not support server-initiated sampling, elicitation, or filesystem roots."]]
    }

    private func http(_ message: [String: Any], expectedID: Int?, timeout requestTimeout: TimeInterval? = nil) async throws -> [String: Any]? {
        let deadline = requestTimeout ?? timeout
        return try await withThrowingTaskGroup(of: [String: Any]?.self) { group in
            group.addTask { @MainActor [self] in try await httpStream(message, expectedID: expectedID) }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(deadline * 1_000_000_000))
                throw TerminalAIMCPError.timedOut
            }
            defer { group.cancelAll() }
            return try await group.next() ?? nil
        }
    }

    private func httpStream(_ message: [String: Any], expectedID: Int?) async throws -> [String: Any]? {
        guard let url = URL(string: server.endpoint) else { throw TerminalAIMCPError.invalid("Invalid MCP endpoint.") }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: message)
        guard (request.httpBody?.count ?? 0) <= maxBytes else { throw TerminalAIMCPError.invalid("The MCP request exceeds 4 MiB.") }
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        if initialized || message["method"] as? String != "initialize" {
            request.setValue(protocolVersion, forHTTPHeaderField: "MCP-Protocol-Version")
        }
        if let sessionID { request.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id") }
        if let token, !token.isEmpty { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        var lastEventID: String?
        var retryMilliseconds: UInt64 = 1000
        while true {
            let (bytes, response) = try await session.bytes(for: request)
            guard let response = response as? HTTPURLResponse else { throw TerminalAIMCPError.disconnected }
            guard (200..<300).contains(response.statusCode) else {
                if response.statusCode == 404, sessionID != nil {
                    initialized = false
                    sessionID = nil
                    throw TerminalAIMCPError.server("The MCP session expired. Reconnect before retrying; a tool call was not replayed.")
                }
                throw TerminalAIMCPError.server("MCP endpoint returned HTTP \(response.statusCode). Check the endpoint and credentials.")
            }
            if let assigned = response.value(forHTTPHeaderField: "Mcp-Session-Id") {
                guard !assigned.isEmpty, assigned.utf8.allSatisfy({ $0 >= 0x21 && $0 <= 0x7e }) else {
                    throw TerminalAIMCPError.server("The MCP endpoint returned an invalid session ID.")
                }
                sessionID = assigned
            }
            guard let expectedID else {
                guard response.statusCode == 202 else { throw TerminalAIMCPError.server("The MCP server did not accept a protocol notification.") }
                return nil
            }
            let type = response.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
            if type.hasPrefix("application/json") {
                var data = Data()
                for try await byte in bytes {
                    data.append(byte)
                    guard data.count <= maxBytes else { throw TerminalAIMCPError.server("The MCP response exceeds 4 MiB.") }
                }
                guard let record = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      record["jsonrpc"] as? String == "2.0", record["id"] as? Int == expectedID else {
                    throw TerminalAIMCPError.server("The MCP server returned a mismatched JSON-RPC response.")
                }
                return record
            }
            guard type.hasPrefix("text/event-stream") else { throw TerminalAIMCPError.server("The MCP endpoint must return JSON or Server-Sent Events.") }
            let outcome = try await readEvents(bytes, expectedID: expectedID, lastEventID: lastEventID, retryMilliseconds: retryMilliseconds)
            if let response = outcome.response { return response }
            guard let cursor = outcome.lastEventID, !cursor.isEmpty else { throw TerminalAIMCPError.disconnected }
            lastEventID = cursor
            retryMilliseconds = outcome.retryMilliseconds
            try await Task.sleep(nanoseconds: min(retryMilliseconds, UInt64.max / 1_000_000) * 1_000_000)
            // Resume the same request stream with GET. Never re-POST a tool call.
            request.httpMethod = "GET"
            request.httpBody = nil
            request.setValue(nil, forHTTPHeaderField: "Content-Type")
            request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
            request.setValue(cursor, forHTTPHeaderField: "Last-Event-ID")
            request.setValue(protocolVersion, forHTTPHeaderField: "MCP-Protocol-Version")
            if let sessionID { request.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id") }
        }
    }

    private struct EventOutcome {
        var response: [String: Any]?
        var lastEventID: String?
        var retryMilliseconds: UInt64
    }

    private func readEvents(_ bytes: URLSession.AsyncBytes, expectedID: Int, lastEventID: String?, retryMilliseconds: UInt64) async throws -> EventOutcome {
        var outcome = EventOutcome(lastEventID: lastEventID, retryMilliseconds: retryMilliseconds)
        var eventID: String?
        var payload: [String] = []
        var count = 0
        var lineData = Data()
        var previousCR = false
        // AsyncBytes.lines drops blank lines on some supported macOS versions.
        // SSE needs those event delimiters, including CRLF and bare CR.
        for try await byte in bytes {
            count += 1
            guard count <= maxBytes else { throw TerminalAIMCPError.server("The MCP response exceeds 4 MiB.") }
            if byte == 10, previousCR { previousCR = false; continue }
            previousCR = byte == 13
            guard byte == 10 || byte == 13 else { lineData.append(byte); continue }
            guard let line = String(data: lineData, encoding: .utf8) else { throw TerminalAIMCPError.server("Invalid MCP event encoding.") }
            lineData.removeAll(keepingCapacity: true)
            if line.isEmpty {
                if let eventID { outcome.lastEventID = eventID }
                eventID = nil
                let data = Data(payload.joined(separator: "\n").utf8)
                payload.removeAll()
                // Newer servers prime resumable streams using an empty data event.
                guard !data.isEmpty else { continue }
                guard let record = try JSONSerialization.jsonObject(with: data) as? [String: Any], record["jsonrpc"] as? String == "2.0" else {
                    throw TerminalAIMCPError.server("The MCP endpoint returned invalid SSE JSON.")
                }
                if record["id"] as? Int == expectedID, record["method"] == nil { outcome.response = record; return outcome }
                if let id = record["id"], record["method"] != nil { _ = try await http(serverReply(record, id: id), expectedID: nil) }
            } else if line.hasPrefix("data:") {
                let data = String(line.dropFirst(5))
                payload.append(data.hasPrefix(" ") ? String(data.dropFirst()) : data)
            } else if line.hasPrefix("id:") {
                let raw = String(line.dropFirst(3))
                let id = raw.hasPrefix(" ") ? String(raw.dropFirst()) : raw
                guard !id.utf8.contains(where: { $0 < 0x20 || $0 == 0x7f }) else {
                    throw TerminalAIMCPError.server("The MCP endpoint returned an invalid SSE event ID.")
                }
                eventID = id
            } else if line.hasPrefix("retry:") {
                let raw = String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces)
                if raw.utf8.allSatisfy({ (48...57).contains($0) }), let retry = UInt64(raw) { outcome.retryMilliseconds = retry }
            }
        }
        return outcome
    }
}

/// An endpoint redirect must be confirmed by editing the server URL, especially when a token is attached.
private final class TerminalAIMCPHTTPDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
