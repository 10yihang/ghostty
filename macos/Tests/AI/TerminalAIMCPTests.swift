import Foundation
import Testing
@testable import Ghostty

@MainActor
struct TerminalAIMCPTests {
    @Test func stdioNegotiatesCatalogsCallsAndResourcesWithoutShellExpansion() async throws {
        let fixture = try MCPFixture()
        defer { fixture.remove() }
        let client = TerminalAIMCPClient(server: fixture.server())
        defer { client.close() }
        try await client.initialize()
        #expect(client.serverInfo["name"] as? String == "ghostty-mcp-fixture")
        let tools = try await client.list("tools/list", key: "tools")
        #expect(tools.map { $0["name"] as? String } == ["echo", "verify"])
        let result = try await client.request(method: "tools/call", params: ["name": "echo", "arguments": ["value": "$(touch never-created)"]])
        let content = try #require(result["content"] as? [[String: Any]])
        #expect(content[0]["text"] as? String == "$(touch never-created)")
        #expect(!FileManager.default.fileExists(atPath: fixture.directory.appendingPathComponent("never-created").path))
        let resources = try await client.list("resources/list", key: "resources")
        #expect(resources[0]["uri"] as? String == "fixture://log")
        let read = try await client.request(method: "resources/read", params: ["uri": "fixture://log"])
        #expect((read["contents"] as? [[String: Any]])?[0]["text"] as? String == "fixture resource evidence")
        let methods = try fixture.records().compactMap { $0["method"] as? String }
        #expect(methods.first == "initialize")
        #expect(methods.dropFirst().first == "notifications/initialized")
    }

    @Test func streamableHTTPHandlesJSONAndSSEWithNegotiatedSessionHeaders() async throws {
        let fixture = try MCPFixture()
        defer { fixture.remove() }
        let server = try await fixture.httpServer()
        let client = TerminalAIMCPClient(server: server, token: "fixture-token")
        defer { client.close() }
        try await client.initialize()
        #expect(try await client.list("tools/list", key: "tools").count == 2)
        let result = try await client.request(method: "tools/call", params: ["name": "echo", "arguments": ["value": "http evidence"]])
        #expect((result["content"] as? [[String: Any]])?[0]["text"] as? String == "http evidence")
        #expect(try await client.list("resources/list", key: "resources").count == 1)
        let records = try fixture.records()
        let requests = records.filter { $0["method"] as? String != "initialize" }
        #expect(requests.allSatisfy { $0["session"] as? String == "fixture-session" })
        #expect(requests.allSatisfy { $0["protocol"] as? String == "2025-06-18" })
        #expect(records.allSatisfy { $0["authorization"] as? String == "Bearer fixture-token" })
        #expect(records.contains { ($0["message"] as? [String: Any])?["id"] as? String == "server-ping" })
    }

    @Test func timeoutAndCancellationSendCancellationWithoutReportingSuccess() async throws {
        let fixture = try MCPFixture()
        defer { fixture.remove() }
        let client = TerminalAIMCPClient(server: fixture.server(), timeout: 2)
        defer { client.close() }
        try await client.initialize()
        do {
            _ = try await client.request(method: "tools/call", params: ["name": "echo", "arguments": ["delay": true]])
            Issue.record("A delayed tool should time out.")
        } catch { #expect(error is TerminalAIMCPError) }
        let task = Task { @MainActor in
            try await client.request(method: "tools/call", params: ["name": "echo", "arguments": ["delay": true]])
        }
        try await Task.sleep(nanoseconds: 30_000_000)
        task.cancel()
        do { _ = try await task.value; Issue.record("A cancelled tool should not report success.") } catch { #expect(error is CancellationError) }
        try await Task.sleep(nanoseconds: 30_000_000)
        #expect(try fixture.records().filter { $0["method"] as? String == "notifications/cancelled" }.count == 2)
    }

    @Test func httpTimeoutCancelsAndExpiredSessionsNeverReplayToolCalls() async throws {
        let fixture = try MCPFixture()
        defer { fixture.remove() }
        let server = try await fixture.httpServer()
        let client = TerminalAIMCPClient(server: server)
        defer { client.close() }
        try await client.initialize()
        do {
            _ = try await client.request(method: "tools/call", params: ["name": "echo", "arguments": ["delay": true]], timeout: 2)
            Issue.record("A delayed HTTP tool must time out.")
        } catch { #expect(error is TerminalAIMCPError) }
        #expect(try fixture.records().contains { $0["method"] as? String == "notifications/cancelled" })
        do {
            _ = try await client.request(method: "tools/call", params: ["name": "echo", "arguments": ["expired": true]])
            Issue.record("An expired session cannot return success.")
        } catch { #expect(error.localizedDescription.contains("expired")) }
        try await client.initialize()
        let records = try fixture.records()
        #expect(records.filter { $0["method"] as? String == "tools/call" }.count == 2)
        let initializations = records.filter { $0["method"] as? String == "initialize" }
        #expect(initializations.count == 2)
        #expect(initializations.allSatisfy { $0["session"] is NSNull })
    }

    @Test func httpRedirectsAndMismatchedResponsesAreRejected() async throws {
        let fixture = try MCPFixture()
        defer { fixture.remove() }
        let server = try await fixture.httpServer()
        let client = TerminalAIMCPClient(server: server, token: "fixture-token")
        defer { client.close() }
        try await client.initialize()
        for arguments in [["redirect": true], ["mismatch": true]] {
            do {
                _ = try await client.request(method: "tools/call", params: ["name": "echo", "arguments": arguments])
                Issue.record("Redirects and mismatched RPC responses cannot return success.")
            } catch { #expect(error is TerminalAIMCPError) }
        }
        #expect(try fixture.records().filter { $0["method"] as? String == "tools/call" }.count == 2)
    }

    @Test func latestHTTPResumesPrimedSSEWithGETAndNeverRepostsTheTool() async throws {
        let fixture = try MCPFixture()
        defer { fixture.remove() }
        let server = try await fixture.httpServer(version: "2025-11-25")
        let client = TerminalAIMCPClient(server: server, token: "fixture-token")
        defer { client.close() }
        try await client.initialize()
        let result = try await client.request(method: "tools/call", params: ["name": "echo", "arguments": ["resume": true, "value": "resumed once"]])
        #expect((result["content"] as? [[String: Any]])?[0]["text"] as? String == "resumed once")
        let records = try fixture.records()
        #expect(records.filter { $0["method"] as? String == "tools/call" }.count == 1)
        let resumed = try #require(records.first { $0["method"] as? String == "fixture/resume" })
        #expect(resumed["lastEvent"] as? String == "fixture-stream")
        #expect(resumed["protocol"] as? String == "2025-11-25")
        #expect(resumed["session"] as? String == "fixture-session")
        #expect(resumed["authorization"] as? String == "Bearer fixture-token")
        #expect((resumed["time"] as? Double ?? 0) - (records.first { $0["method"] as? String == "tools/call" }?["time"] as? Double ?? 0) >= 0.02)
    }

    @Test func savedConfigurationIsPrivateDisabledServersDoNotLaunchAndCallsPreserveToolErrors() async throws {
        let fixture = try MCPFixture()
        defer { fixture.remove() }
        let directory = fixture.directory.appendingPathComponent("configuration")
        let manager = TerminalAIMCPManager(directory: directory)
        defer { manager.close() }
        var server = fixture.server()
        try manager.save(server)
        #expect(!FileManager.default.fileExists(atPath: fixture.log.path))
        let recovered = TerminalAIMCPManager(directory: directory)
        #expect(recovered.servers == manager.servers)
        #expect(recovered.servers.first?.id == server.id)
        let available = try await manager.perform(request: ["operation": "list_servers"])
        #expect((available["result"] as? [String: Any])?["servers"] != nil)
        #expect(!FileManager.default.fileExists(atPath: fixture.log.path))
        let test = try await manager.test(server.id)
        #expect(test.tools.count == 2)
        let failed = try await manager.perform(request: ["operation": "call_tool", "server": server.id.uuidString,
                                                        "toolName": "echo", "arguments": ["fail": true]])
        #expect(failed["isError"] as? Bool == true)
        do {
            _ = try await manager.perform(request: ["operation": "call_tool", "server": server.id.uuidString,
                                                   "toolName": "unadvertised", "arguments": [:]])
            Issue.record("An unadvertised tool cannot execute.")
        } catch { #expect(error is TerminalAIMCPError) }
        server = try #require(manager.servers.first)
        server.enabled = false
        try manager.save(server)
        do { _ = try await manager.test(server.id); Issue.record("Disabled servers cannot connect.") } catch { #expect(error is TerminalAIMCPError) }
        let file = directory.appendingPathComponent("servers.json")
        #expect((try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        #expect((try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? NSNumber)?.intValue == 0o700)
        let saved = try String(contentsOf: file, encoding: .utf8)
        #expect(!saved.contains("bearerToken"))
        #expect(!saved.contains("environmentValues"))
    }

    @Test func malformedProtocolAndRemotePlainHTTPAreRejected() async throws {
        let fixture = try MCPFixture()
        defer { fixture.remove() }
        var server = fixture.server()
        server.transport = .http
        server.endpoint = "http://example.com/mcp"
        #expect(throws: (any Error).self) { try server.validate() }
        server.endpoint = "https://user:password@example.com/mcp"
        #expect(throws: (any Error).self) { try server.validate() }
        server = fixture.server()
        let client = TerminalAIMCPClient(server: server)
        defer { client.close() }
        try await client.initialize()
        do {
            _ = try await client.request(method: "fixture/malformed", params: [:])
            Issue.record("Invalid JSON-RPC must not produce success.")
        } catch { #expect(error is TerminalAIMCPError) }
    }

    @Test func anotherWindowChangingEndpointAndCredentialsInvalidatesReviewedProfiles() async throws {
        let oldFixture = try MCPFixture()
        let newFixture = try MCPFixture()
        defer { oldFixture.remove(); newFixture.remove() }
        let directory = oldFixture.directory.appendingPathComponent("shared-profiles")
        let first = TerminalAIMCPManager(directory: directory)
        defer { first.close() }
        var server = try await oldFixture.httpServer()
        try first.save(server, bearerToken: "fixture-old-token")
        let second = TerminalAIMCPManager(directory: directory)
        defer { second.close(); try? first.remove(server.id) }
        let reviewed = try second.configurationSignature(for: server.id)
        _ = try await second.test(server.id)
        #expect(try oldFixture.records().allSatisfy { $0["authorization"] as? String == "Bearer fixture-old-token" })
        let replacement = try await newFixture.httpServer()
        server = try #require(first.servers.first)
        server.endpoint = replacement.endpoint
        try first.save(server, bearerToken: "fixture-new-token")
        do {
            _ = try await second.perform(request: ["operation": "call_tool", "server": server.id.uuidString,
                "toolName": "echo", "arguments": [:], "_approvedConfiguration": reviewed])
            Issue.record("A changed endpoint or credential requires new review.")
        } catch { #expect(error.localizedDescription.contains("configuration changed")) }
        #expect(try oldFixture.records().filter { $0["method"] as? String == "tools/call" }.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: newFixture.log.path))
        #expect(second.servers.first?.endpoint == replacement.endpoint)
        #expect(second.discoveries[server.id] == nil)
        let nextReview = try second.configurationSignature(for: server.id)
        #expect(nextReview != reviewed)
        _ = try await second.perform(request: ["operation": "call_tool", "server": server.id.uuidString,
            "toolName": "echo", "arguments": ["value": "newly reviewed"], "_approvedConfiguration": nextReview])
        #expect(try newFixture.records().allSatisfy { $0["authorization"] as? String == "Bearer fixture-new-token" })
        #expect(try newFixture.records().filter { $0["method"] as? String == "tools/call" }.count == 1)
        #expect(try oldFixture.records().filter { $0["method"] as? String == "tools/call" }.isEmpty)
    }

    @Test func multipleManagersMergeIndependentProfileWritesAndDoNotResurrectRemovedServers() throws {
        let fixture = try MCPFixture()
        defer { fixture.remove() }
        let directory = fixture.directory.appendingPathComponent("shared-profiles")
        let first = TerminalAIMCPManager(directory: directory)
        let second = TerminalAIMCPManager(directory: directory)
        defer { first.close(); second.close() }
        var alpha = fixture.server()
        alpha.name = "Alpha"
        var beta = fixture.server()
        beta.name = "Beta"
        try first.save(alpha)
        try second.save(beta)
        alpha = try #require(first.servers.first { $0.id == alpha.id })
        beta = try #require(second.servers.first { $0.id == beta.id })
        alpha.name = "Alpha edited"
        beta.name = "Beta edited"
        try first.save(alpha)
        try second.save(beta)
        try first.refresh()
        #expect(Set(first.servers.map(\.name)) == ["Alpha edited", "Beta edited"])
        #expect(first.servers.allSatisfy { $0.revision != nil })
        let before = try first.configurationSignature(for: alpha.id)
        let outdated = alpha
        alpha = try #require(first.servers.first { $0.id == alpha.id })
        try first.save(alpha)
        #expect(try first.configurationSignature(for: alpha.id) != before)
        #expect(throws: (any Error).self) { try second.save(outdated) }
        try first.remove(alpha.id)
        let third = fixture.server()
        try second.save(third)
        try first.refresh()
        #expect(Set(first.servers.map(\.id)) == [beta.id, third.id])
        #expect(!FileManager.default.fileExists(atPath: fixture.log.path))
    }
}

@MainActor
private final class MCPFixture {
    let directory: URL
    let log: URL
    let script: URL
    private var http: Process?

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("ghostty-mcp-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        log = directory.appendingPathComponent("records.jsonl")
        script = directory.appendingPathComponent("fixture.py")
        try Self.source.write(to: script, atomically: true, encoding: .utf8)
    }

    func server() -> TerminalAIMCPServer {
        var server = TerminalAIMCPServer()
        server.name = "Isolated fixture"
        server.executable = "/usr/bin/python3"
        server.arguments = [script.path, "stdio", log.path]
        server.workingDirectory = directory.path
        return server
    }

    func httpServer(version: String = "2025-06-18") async throws -> TerminalAIMCPServer {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        let ready = directory.appendingPathComponent("port")
        process.arguments = [script.path, "http", log.path, ready.path, version]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        http = process
        for _ in 0..<100 {
            if let data = try? String(contentsOf: ready, encoding: .utf8), let port = Int(data) {
                var server = TerminalAIMCPServer()
                server.name = "Isolated HTTP fixture"
                server.transport = .http
                server.endpoint = "http://127.0.0.1:\(port)/mcp"
                return server
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        throw TerminalAIMCPError.timedOut
    }

    func records() throws -> [[String: Any]] {
        let data = try String(contentsOf: log, encoding: .utf8)
        return try data.split(separator: "\n").map {
            try #require(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
        }
    }

    func remove() {
        if let http, http.isRunning { http.terminate() }
        try? FileManager.default.removeItem(at: directory)
    }

    static let source = #"""
    import json, sys, time, threading
    from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
    lock = threading.Lock()
    resumed = {}
    def record(message, headers=None):
        row = dict(message)
        if headers is not None:
            row.update(session=headers.get('Mcp-Session-Id'), protocol=headers.get('MCP-Protocol-Version'), authorization=headers.get('Authorization'), lastEvent=headers.get('Last-Event-ID'), time=time.monotonic(), message=message)
        with lock:
            with open(sys.argv[2], 'a') as file: file.write(json.dumps(row) + '\n')
    def result(message):
        method = message.get('method')
        params = message.get('params', {})
        if method == 'initialize': return {'protocolVersion': sys.argv[4] if len(sys.argv) > 4 else '2025-06-18', 'serverInfo': {'name': 'ghostty-mcp-fixture', 'version': '1'}, 'capabilities': {'tools': {}, 'resources': {}}}
        if method == 'tools/list':
            name = 'verify' if params.get('cursor') else 'echo'
            page = {'tools': [{'name': name, 'description': 'Isolated fixture', 'inputSchema': {'type': 'object'}}]}
            if name == 'echo': page['nextCursor'] = 'second'
            return page
        if method == 'resources/list': return {'resources': [{'name': 'Fixture log', 'uri': 'fixture://log'}]}
        if method == 'resources/read': return {'contents': [{'uri': 'fixture://log', 'mimeType': 'text/plain', 'text': 'fixture resource evidence'}]}
        if method == 'tools/call':
            args = params.get('arguments', {})
            if args.get('delay'): time.sleep(3)
            return {'content': [{'type': 'text', 'text': args.get('value', 'fixture failure')}], 'isError': args.get('fail', False)}
        return {}
    def response(message): return {'jsonrpc': '2.0', 'id': message['id'], 'result': result(message)}
    if sys.argv[1] == 'stdio':
        def emit(message):
            if message.get('method') == 'fixture/malformed':
                print('not json', flush=True)
            elif 'id' in message:
                data = response(message)
                with lock: print(json.dumps(data), flush=True)
        for line in sys.stdin:
            message = json.loads(line)
            record(message)
            threading.Thread(target=emit, args=(message,), daemon=True).start()
    else:
        class Handler(BaseHTTPRequestHandler):
            protocol_version = 'HTTP/1.1'
            def log_message(self, *args): pass
            def do_POST(self):
                message = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
                record(message, self.headers)
                args = message.get('params', {}).get('arguments', {})
                if args.get('resume'):
                    resumed['fixture-stream'] = response(message)
                    self.send_response(200); self.send_header('Content-Type', 'text/event-stream'); self.send_header('Connection', 'close'); self.end_headers()
                    self.wfile.write(b'id: fixture-stream\r\nretry: 20\r\ndata:\r\n\r\n'); self.wfile.flush(); self.close_connection = True; return
                if args.get('expired'):
                    self.send_response(404); self.send_header('Content-Length', '0'); self.end_headers(); return
                if args.get('redirect'):
                    self.send_response(302); self.send_header('Location', '/redirected'); self.send_header('Content-Length', '0'); self.end_headers(); return
                if args.get('mismatch'):
                    data = json.dumps({'jsonrpc': '2.0', 'id': message['id'] + 1, 'result': {}}).encode()
                    self.send_response(200); self.send_header('Content-Type', 'application/json'); self.send_header('Content-Length', str(len(data))); self.end_headers(); self.wfile.write(data); return
                if 'method' not in message or 'id' not in message:
                    self.send_response(202); self.send_header('Content-Length', '0'); self.end_headers(); return
                if message['method'] == 'tools/call':
                    self.send_response(200); self.send_header('Content-Type', 'text/event-stream'); self.send_header('Connection', 'close'); self.end_headers()
                    for item in [{'jsonrpc': '2.0', 'method': 'notifications/progress', 'params': {'progress': 1}}, {'jsonrpc': '2.0', 'id': 'server-ping', 'method': 'ping'}, response(message)]:
                        self.wfile.write(('data: ' + json.dumps(item) + '\n\n').encode()); self.wfile.flush()
                    self.close_connection = True
                else:
                    data = json.dumps(response(message)).encode()
                    self.send_response(200); self.send_header('Content-Type', 'application/json'); self.send_header('Content-Length', str(len(data)))
                    if message['method'] == 'initialize': self.send_header('Mcp-Session-Id', 'fixture-session')
                    self.end_headers(); self.wfile.write(data)
            def do_DELETE(self):
                self.send_response(204); self.send_header('Content-Length', '0'); self.end_headers()
            def do_GET(self):
                record({'method': 'fixture/resume'}, self.headers)
                data = json.dumps(resumed[self.headers.get('Last-Event-ID')])
                self.send_response(200); self.send_header('Content-Type', 'text/event-stream'); self.send_header('Connection', 'close'); self.end_headers()
                self.wfile.write(('data: ' + data + '\n\n').encode()); self.wfile.flush(); self.close_connection = True
        server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        with open(sys.argv[3], 'w') as file: file.write(str(server.server_port))
        server.serve_forever()
    """#
}
