import AppKit
import Testing
import WebKit
@testable import Ghostty

@MainActor
struct TerminalAIWorkbenchWebViewTests {
    @Test func bundledWorkbenchFitsSidebarAndBottomPanelAndDispatchesNativeActions() async throws {
        let directory = try #require(Bundle.main.resourceURL?.appendingPathComponent("AIChat"))
        let index = directory.appendingPathComponent("index.html")
        let coordinator = TerminalAIWebView.Coordinator()
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.add(coordinator, name: "ghosttyAI")
        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 380, height: 650), configuration: configuration)
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
        let snapshot: [String: Any] = [
            "messages": [["id": "question", "role": "user", "content": [["type": "text", "text": "Investigate this failed build."]]]],
            "isRunning": false, "phase": "completed", "status": "Completed", "prompt": "", "context": "", "appearance": "dark",
            "suggestedCommand": "make test", "suggestedExplanation": "Run the repaired build's tests in the attached terminal.",
            "terminalIdentity": ["host": "build-host", "directory": "/srv/project", "isRemote": true, "readiness": "Ready", "canRun": true],
            "commands": [["id": "failed-build", "command": "make test", "directory": "/srv/project", "host": "build-host",
                          "startedAt": Date().timeIntervalSince1970 * 1_000, "duration": 2.1, "exitCode": 2,
                          "output": "Missing dependency\nOnly this command's output", "state": "completed"]],
            "attachments": [["id": "build-log", "name": "build.log", "kind": "log", "source": "/srv/project/build.log",
                             "host": "build-host", "preview": "Build failed: missing dependency", "lineCount": 1]],
            "workflows": [["id": "port-check", "name": "Check port", "description": "Inspect a listener", "prompt": "Inspect port {{port}}",
                           "parameters": [["name": "port", "defaultValue": "8080"]]]],
            "task": ["id": "task", "title": "Repair build dependency", "steps": [
                ["id": "read", "title": "Read failure", "status": "completed", "evidence": "make test exited with code 2"],
                ["id": "verify", "title": "Verify repair", "status": "pending", "evidence": ""]
            ], "verification": ["status": "unverified", "summary": "Tests have not run after the repair.", "evidence": ""]]
        ]
        coordinator.enqueue(snapshot)
        view.loadFileURL(index, allowingReadAccessTo: directory)
        try await wait(view, for: "document.querySelector('.task-verification')?.textContent.includes('Not verified') === true")
        _ = try await view.evaluateJavaScript("document.querySelector('[aria-label=\"Show command history\"]').click()")
        try await wait(view, for: "document.querySelector('.command-record') !== null")
        _ = try await view.evaluateJavaScript("document.querySelector('.command-record').open = true")
        #expect(try await view.evaluateJavaScript("document.querySelector('.command-record pre').textContent") as? String == "Missing dependency\nOnly this command's output")
        for size in [NSSize(width: 380, height: 650), NSSize(width: 1200, height: 360)] {
            window.setContentSize(size)
            view.frame.size = size
            try await Task.sleep(for: .milliseconds(100))
            #expect(try await view.evaluateJavaScript("document.querySelector('.chat').scrollWidth <= document.documentElement.clientWidth") as? Bool == true)
            #expect(try await view.evaluateJavaScript("document.querySelector('.transcript').getBoundingClientRect().height >= 48") as? Bool == true)
            let image = try await view.takeSnapshot(configuration: nil)
            if let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
               let png = bitmap.representation(using: .png, properties: [:]) {
                let suffix = size.width < 500 ? "sidebar" : "bottom"
                try png.write(to: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ghostty-ai-workbench-\(suffix).png"))
            }
        }
        _ = try await view.evaluateJavaScript("Array.from(document.querySelectorAll('.command-record button')).find(button => button.textContent === 'Explain').click()")
        #expect(actions.contains { $0["type"] as? String == "command_explain" && $0["id"] as? String == "failed-build" })
        _ = try await view.evaluateJavaScript("document.querySelector('[aria-label=\"Show workflows\"]').click()")
        try await wait(view, for: "document.querySelector('.workflow-select') !== null")
        _ = try await view.evaluateJavaScript("document.querySelector('.workflow-select').click()")
        try await wait(view, for: "document.querySelector('[aria-label=\"Workflow parameter port\"]')?.value === '8080'")
        _ = try await view.evaluateJavaScript("document.querySelector('.workflow-form .primary').click()")
        #expect(actions.contains { $0["type"] as? String == "workflow_use" && $0["id"] as? String == "port-check" })
        #expect(!actions.contains { $0["type"] as? String == "send" || $0["type"] as? String == "command_run" })

        var recovery = snapshot
        recovery["isRunning"] = true
        recovery["phase"] = "thinking"
        recovery["status"] = "Thinking"
        recovery["task"] = nil
        recovery["terminalIdentity"] = ["host": "remote-root-shell", "directory": "/root", "isRemote": true,
                                        "canRun": false, "canSetupShell": true,
                                        "readiness": "A foreground program or an unintegrated nested shell is active. If you are at an idle SSH/su/sudo su prompt, use Connect shell, or type exit manually to return to an integrated parent. Otherwise finish the program first. A terminal control grant does not bypass this check."]
        coordinator.enqueue(recovery)
        try await wait(view, for: "Array.from(document.querySelectorAll('button')).some(button => button.textContent === 'Connect shell…' && !button.disabled)")
        for size in [NSSize(width: 380, height: 650), NSSize(width: 1200, height: 360)] {
            window.setContentSize(size)
            view.frame.size = size
            try await Task.sleep(for: .milliseconds(100))
            #expect(try await view.evaluateJavaScript("document.querySelector('.chat').scrollWidth <= document.documentElement.clientWidth") as? Bool == true)
            #expect(try await view.evaluateJavaScript("document.querySelector('.terminal-readiness').getBoundingClientRect().height <= 64") as? Bool == true)
            #expect(try await view.evaluateJavaScript("document.querySelector('.transcript').getBoundingClientRect().height >= 48") as? Bool == true)
            let image = try await view.takeSnapshot(configuration: nil)
            if let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
               let png = bitmap.representation(using: .png, properties: [:]) {
                let suffix = size.width < 500 ? "sidebar" : "bottom"
                try png.write(to: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ghostty-ai-shell-recovery-\(suffix).png"))
            }
        }
        _ = try await view.evaluateJavaScript("Array.from(document.querySelectorAll('button')).find(button => button.textContent === 'Connect shell…').click()")
        #expect(actions.contains { $0["type"] as? String == "ssh_setup" })
        #expect(!actions.contains { $0["type"] as? String == "send" || $0["type"] as? String == "command_run" })
    }

    private func wait(_ view: WKWebView, for condition: String) async throws {
        for _ in 0..<100 {
            if (try? await view.evaluateJavaScript(condition)) as? Bool == true { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        Issue.record("The bundled workbench did not satisfy: \(condition)")
        throw CocoaError(.coderReadCorrupt)
    }
}
