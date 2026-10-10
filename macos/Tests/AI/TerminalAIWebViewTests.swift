import AppKit
import Testing
import WebKit
@testable import Ghostty

@MainActor
struct TerminalAIWebViewTests {
    @Test func snapshotFactoriesCoalesceBeforeReadinessAndReleaseCancelledWork() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let index = directory.appendingPathComponent("index.html")
        try """
        <script>
        window.ghosttyAI = { update(snapshot) { window.sequence = snapshot.sequence; } };
        window.webkit.messageHandlers.ghosttyAI.postMessage({ type: 'ready' });
        </script>
        """.write(to: index, atomically: true, encoding: .utf8)
        let coordinator = TerminalAIWebView.Coordinator()
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.add(coordinator, name: "ghosttyAI")
        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 420, height: 600), configuration: configuration)
        coordinator.webView = view
        coordinator.documentURL = index
        view.navigationDelegate = coordinator
        defer {
            coordinator.invalidate()
            configuration.userContentController.removeScriptMessageHandler(forName: "ghosttyAI")
            view.stopLoading()
        }
        var builds = 0
        for sequence in 1...100 {
            coordinator.enqueue {
                builds += 1
                return ["sequence": sequence]
            }
        }
        #expect(builds == 0)
        view.loadFileURL(index, allowingReadAccessTo: directory)
        try await wait(view, for: "window.sequence === 100")
        #expect(builds == 1)

        var latest = 101
        coordinator.enqueue {
            builds += 1
            return ["sequence": latest]
        }
        latest = 200
        try await wait(view, for: "window.sequence === 200")
        #expect(builds == 2)

        weak var captured: NSObject?
        do {
            let owner = NSObject()
            captured = owner
            coordinator.enqueue { [owner] in
                withExtendedLifetime(owner) { builds += 1 }
                return ["sequence": 300]
            }
        }
        #expect(captured != nil)
        coordinator.invalidate()
        #expect(captured == nil)
        try await Task.sleep(for: .milliseconds(100))
        #expect(builds == 2)
        #expect(try await view.evaluateJavaScript("window.sequence") as? Int == 200)
    }

    @Test func bridgeRejectsOlderDraftRevisions() {
        let coordinator = TerminalAIWebView.Coordinator()
        #expect(!coordinator.acceptDraftRevision(["revision": -1]))
        #expect(coordinator.acceptDraftRevision(["revision": 2]))
        #expect(!coordinator.acceptDraftRevision(["revision": 1]))
        #expect(coordinator.draftRevision == 2)
    }

    @Test func bundledChatRendersStructuredMessagesAndUsesNativeActions() async throws {
        let directory = try #require(Bundle.main.resourceURL?.appendingPathComponent("AIChat"))
        let index = directory.appendingPathComponent("index.html")
        #expect(FileManager.default.fileExists(atPath: index.path))
        let coordinator = TerminalAIWebView.Coordinator()
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.add(coordinator, name: "ghosttyAI")
        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 900, height: 420), configuration: configuration)
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        coordinator.webView = view
        coordinator.documentURL = index
        view.navigationDelegate = coordinator
        defer {
            configuration.userContentController.removeScriptMessageHandler(forName: "ghosttyAI")
            view.stopLoading()
            window.close()
        }
        var actions: [[String: Any]] = []
        coordinator.onAction = { actions.append($0) }
        var snapshot: [String: Any] = [
            "messages": [[
                "id": "assistant", "role": "assistant", "content": [
                    ["type": "text", "text": "## Verified heading\n\n| File | State |\n| --- | --- |\n| README | Ready |\n\n```sh\nprintf 'ok'\n```"],
                    ["type": "tool-call", "toolCallId": "read", "toolName": "ghostty_diagnose",
                     "args": ["operation": "read", "path": "README.md"],
                     "result": ["text": "fixture output", "label": "Read file", "detail": "README.md", "isRunning": false, "isError": false]],
                    ["type": "text", "text": "After the tool. <script>bad()</script>"]
                ]
            ]],
            "isRunning": true, "phase": "waiting_approval", "status": "Waiting for approval",
            "startedAt": Date().timeIntervalSince1970 * 1_000,
            "approval": ["id": "approval", "title": "Run command?", "message": "printf 'ok'"],
            "prompt": "", "context": "fixture", "contextTitle": "Selected text", "appearance": "dark",
            "suggestedCommand": "", "suggestedExplanation": ""
        ]
        coordinator.enqueue(snapshot)
        view.loadFileURL(index, allowingReadAccessTo: directory)
        try await wait(view, for: "document.querySelector('h2')?.textContent === 'Verified heading'")
        #expect(try await view.evaluateJavaScript("document.querySelectorAll('table').length") as? Int == 1)
        #expect(try await view.evaluateJavaScript("document.querySelector('pre code')?.textContent.includes(\"printf 'ok'\")") as? Bool == true)
        #expect(try await view.evaluateJavaScript("document.querySelector('.tool-card').compareDocumentPosition(document.querySelectorAll('.markdown')[1]) & Node.DOCUMENT_POSITION_FOLLOWING") as? Int == 4)
        #expect(try await view.evaluateJavaScript("document.querySelectorAll('.markdown script').length") as? Int == 0)
        #expect(try await view.evaluateJavaScript("document.querySelector('.run-label')?.textContent") as? String == "Waiting for approval")

        // Keep an actual WebKit render as useful diagnostics for native resource/bridge failures.
        let image = try await view.takeSnapshot(configuration: nil)
        if let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
           let png = bitmap.representation(using: .png, properties: [:]) {
            try png.write(to: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ghostty-ai-chat-wk.png"))
        }

        #expect(try await view.evaluateJavaScript("document.querySelector('.terminal-control')?.getAttribute('aria-pressed')") as? String == "false")
        _ = try await view.evaluateJavaScript("document.querySelector('.terminal-control').click()")
        #expect(actions.contains { $0["type"] as? String == "terminal_control" && $0["allow"] as? Bool == true })
        snapshot["terminalControlAllowed"] = true
        coordinator.enqueue(snapshot)
        try await wait(view, for: "document.querySelector('.terminal-control.active')?.textContent.includes('on') === true")
        _ = try await view.evaluateJavaScript("document.querySelector('.terminal-control').click()")
        #expect(actions.contains { $0["type"] as? String == "terminal_control" && $0["allow"] as? Bool == false })

        _ = try await view.evaluateJavaScript("document.querySelector('.approval-actions .primary').click()")
        try await wait(view, for: "document.querySelector('.approval-actions .primary')?.disabled === true")
        #expect(actions.contains { $0["type"] as? String == "approval" && $0["id"] as? String == "approval" && $0["allow"] as? Bool == true })
        _ = try await view.evaluateJavaScript("document.querySelector('[aria-label=\"Copy code\"]').click()")
        #expect(actions.contains { $0["type"] as? String == "copy" && ($0["text"] as? String)?.contains("printf 'ok'") == true })

        snapshot["terminalControlAllowed"] = false
        snapshot["isRunning"] = false
        snapshot["phase"] = "completed"
        snapshot["status"] = "Completed"
        snapshot["approval"] = nil
        coordinator.enqueue(snapshot)
        try await wait(view, for: "document.querySelector('.run-label')?.textContent === 'Completed'")
        #expect(try await view.evaluateJavaScript("document.querySelectorAll('.approval').length") as? Int == 0)
        #expect(try await view.evaluateJavaScript("document.querySelectorAll('.stop-button').length") as? Int == 0)
    }

    @Test func multilineDraftKeepsConversationScrollStableDuringNativeEcho() async throws {
        let directory = try #require(Bundle.main.resourceURL?.appendingPathComponent("AIChat"))
        let index = directory.appendingPathComponent("index.html")
        let coordinator = TerminalAIWebView.Coordinator()
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.add(coordinator, name: "ghosttyAI")
        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 520, height: 600), configuration: configuration)
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        // Animation frames must paint an owned test view, rather than a hidden page.
        window.orderFront(nil)
        coordinator.webView = view
        coordinator.documentURL = index
        view.navigationDelegate = coordinator
        defer {
            coordinator.invalidate()
            coordinator.onAction = nil
            configuration.userContentController.removeScriptMessageHandler(forName: "ghosttyAI")
            view.stopLoading()
            window.close()
        }
        let paragraphs = Array(repeating: "Observed **fixture evidence** in the attached terminal. Continue from the recorded output without changing the target.", count: 20).joined(separator: "\n\n")
        var snapshot: [String: Any] = [
            "messages": [["id": "assistant", "role": "assistant", "content": [
                ["type": "text", "text": "## Investigation\n\n\(paragraphs)\n\n```sh\nps -Ao pid,%cpu,comm -r | head\n```"],
                ["type": "tool-call", "toolCallId": "read", "toolName": "ghostty_terminal", "args": ["operation": "read"],
                 "result": ["text": "Fixture terminal output", "label": "Read terminal", "isRunning": false, "isError": false]]
            ]]],
            "isRunning": false, "phase": "completed", "status": "Completed", "appearance": "dark",
            "prompt": "第一行问题。\n第二行说明。", "draftRevision": 0, "context": "",
            "suggestedCommand": "", "suggestedExplanation": ""
        ]
        var echoCount = 0
        coordinator.onAction = { record in
            guard record["type"] as? String == "draft", let text = record["text"] as? String,
                  coordinator.acceptDraftRevision(record) else { return }
            snapshot["prompt"] = text
            snapshot["draftRevision"] = coordinator.draftRevision
            // The real coordinator coalesces for 40 ms and sends a fresh full
            // snapshot, including newly decoded message references in WebKit.
            coordinator.enqueue(snapshot)
            echoCount += 1
        }
        coordinator.enqueue(snapshot)
        view.loadFileURL(index, allowingReadAccessTo: directory)
        try await wait(view, for: "document.querySelector('.tool-card') !== null && document.querySelector('textarea[aria-label=\"Message AI\"]')?.value.includes('第二行说明。') === true")
        _ = try await view.evaluateJavaScript("""
        const viewport = document.querySelector('.transcript');
        viewport.scrollTop = viewport.scrollHeight;
        window.composerScrollFrames = [];
        window.sampleComposerScroll = true;
        window.nativeEchoReferences = [];
        const originalUpdate = window.ghosttyAI.update;
        let previousMessages;
        window.ghosttyAI.update = snapshot => {
            window.nativeEchoReferences.push(snapshot.messages !== previousMessages);
            previousMessages = snapshot.messages;
            originalUpdate(snapshot);
        };
        function sample() {
            if (!window.sampleComposerScroll) return;
            window.composerScrollFrames.push({ top: viewport.scrollTop, height: viewport.clientHeight,
                text: viewport.textContent.length, composer: document.querySelector('.composer').clientHeight });
            requestAnimationFrame(sample);
        }
        requestAnimationFrame(sample);
        """)
        try await Task.sleep(for: .milliseconds(100))
        for character in "继续输入测试文字" {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                view.callAsyncJavaScript("""
                const node = document.querySelector('textarea[aria-label="Message AI"]');
                Object.getOwnPropertyDescriptor(HTMLTextAreaElement.prototype, 'value').set.call(node, node.value + character);
                node.dispatchEvent(new Event('input', { bubbles: true }));
                """, arguments: ["character": String(character)], in: nil, in: .page) { result in
                    continuation.resume(with: result.map { _ in () })
                }
            }
            try await Task.sleep(for: .milliseconds(80))
        }
        try await Task.sleep(for: .milliseconds(100))
        let frames = try #require(try await view.evaluateJavaScript("window.sampleComposerScroll = false; window.composerScrollFrames") as? [[String: Any]])
        #expect(echoCount == 8)
        #expect(frames.count >= 8)
        #expect(try await view.evaluateJavaScript("window.nativeEchoReferences.length === 8 && window.nativeEchoReferences.every(Boolean)") as? Bool == true)
        let positions = frames.compactMap { $0["top"] as? Double }
        let heights = frames.compactMap { $0["height"] as? Double }
        let composerHeights = frames.compactMap { $0["composer"] as? Double }
        #expect(positions.count == frames.count && heights.count == frames.count && composerHeights.count == frames.count)
        #expect(Set(heights).count == 1, "The fixture continues typing within two existing lines.")
        #expect(Set(composerHeights).count == 1)
        #expect(Set(frames.compactMap { $0["text"] as? Int }).count == 1)
        #expect((positions.max() ?? 0) - (positions.min() ?? 0) <= 1,
                "Draft sizing and delayed native echoes must not move unchanged conversation content between frames.")
    }

    private func wait(_ view: WKWebView, for condition: String) async throws {
        for _ in 0..<100 {
            if (try? await view.evaluateJavaScript(condition)) as? Bool == true { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        Issue.record("The bundled WKWebView did not satisfy: \(condition)")
        throw CocoaError(.coderReadCorrupt)
    }
}
