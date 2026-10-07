import AppKit
import Testing
import WebKit
@testable import Ghostty

@MainActor
struct TerminalAIWebViewTests {
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

    private func wait(_ view: WKWebView, for condition: String) async throws {
        for _ in 0..<100 {
            if (try? await view.evaluateJavaScript(condition)) as? Bool == true { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        Issue.record("The bundled WKWebView did not satisfy: \(condition)")
        throw CocoaError(.coderReadCorrupt)
    }
}
