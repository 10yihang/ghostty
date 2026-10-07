import AppKit
import GhosttyKit
import Testing
import WebKit
@testable import Ghostty

@Suite(.serialized)
@MainActor
struct TerminalAIClipboardTests {
    @Test func nativeCommandShortcutsCopyTranscriptAndDraftPasteAndCutWithoutSending() async throws {
        let fixture = try ClipboardFixture()
        defer { fixture.close() }
        try await fixture.load()
        let view = fixture.view

        _ = try await view.evaluateJavaScript("""
            document.querySelector('textarea[aria-label="Message AI"]').blur();
            const range = document.createRange();
            range.selectNodeContents(document.querySelector('.markdown p'));
            window.getSelection().removeAllRanges();
            window.getSelection().addRange(range);
            """)
        try await fixture.waitForNativeSelection("Rendered 中文 transcript 🐧")
        try fixture.key("c", code: 8)
        #expect(view.copies == 1)
        #expect(view.pasteboard.string(forType: .string) == "Rendered 中文 transcript 🐧")

        try await fixture.wait("document.querySelector('textarea[aria-label=\"Message AI\"]').value === 'Input 中文 draft'")
        _ = try await view.evaluateJavaScript("""
            window.getSelection().removeAllRanges();
            document.querySelector('textarea[aria-label="Message AI"]').focus();
            document.querySelector('textarea[aria-label="Message AI"]').setSelectionRange(0, 0);
            """)
        try fixture.key("a", code: 0)
        try await fixture.wait("document.querySelector('textarea[aria-label=\"Message AI\"]').value === 'Input 中文 draft' && document.querySelector('textarea[aria-label=\"Message AI\"]').selectionStart === 0 && document.querySelector('textarea[aria-label=\"Message AI\"]').selectionEnd === 14")
        try await fixture.waitForNativeSelection("Input 中文 draft")
        try fixture.key("c", code: 8)
        #expect(view.copies == 2)
        #expect(view.pasteboard.string(forType: .string) == "Input 中文 draft")

        let text = "第一行 🐧\nsecond line\n$(this stays draft)"
        view.pasteboard.clearContents()
        view.pasteboard.setString(text, forType: .string)
        try fixture.key("v", code: 9)
        try await fixture.wait("document.querySelector('textarea[aria-label=\"Message AI\"]').value.includes('this stays draft')")
        #expect(view.pastes == 1)
        #expect(try await view.evaluateJavaScript("document.querySelector('textarea[aria-label=\"Message AI\"]').value") as? String == text)
        #expect(fixture.actions.contains { $0["type"] as? String == "draft" && $0["text"] as? String == text })

        try fixture.key("a", code: 0)
        try await fixture.waitForNativeSelection(text)
        try fixture.key("x", code: 7)
        try await fixture.wait("document.querySelector('textarea[aria-label=\"Message AI\"]').value === ''")
        #expect(view.cuts == 1)
        #expect(view.pasteboard.string(forType: .string) == text)
        #expect(!fixture.actions.contains { ["send", "command_run", "command_fill", "approval"].contains($0["type"] as? String ?? "") })
        #expect(fixture.window.firstResponder === view)

        // Native menu actions use the same WebKit editing responder.
        let paste = NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        paste.target = view
        let editMenu = NSMenu(title: "Edit")
        editMenu.autoenablesItems = false
        editMenu.addItem(paste)
        #expect(editMenu.performKeyEquivalent(with: try fixture.event("v", code: 9)))
        try await fixture.wait("document.querySelector('textarea[aria-label=\"Message AI\"]').value.includes('this stays draft')")
        #expect(view.pastes == 2)
        #expect(!fixture.actions.contains { $0["type"] as? String == "send" })
    }

    @Test func chatDoesNotConsumeClipboardShortcutWhenAnotherNativeFieldHasFocus() throws {
        let fixture = try ClipboardFixture()
        defer { fixture.close() }
        let sibling = NSTextView(frame: NSRect(x: 0, y: 0, width: 100, height: 30))
        let container = NSView(frame: fixture.window.contentView!.frame)
        container.addSubview(fixture.view)
        container.addSubview(sibling)
        fixture.window.contentView = container
        #expect(fixture.window.makeFirstResponder(sibling))
        #expect(!fixture.view.performKeyEquivalent(with: try fixture.event("c", code: 8)))
        #expect(!fixture.view.performKeyEquivalent(with: try fixture.event("v", code: 9)))
        #expect(fixture.view.copies == 0)
        #expect(fixture.view.pastes == 0)
        #expect(fixture.window.firstResponder === sibling)
    }

    @Test func nativePasteInChatDoesNotReachTheRealTerminalSibling() async throws {
        let terminal = try TerminalFixture()
        let fixture = try ClipboardFixture()
        let inputLog = TerminalRecords()
        let observer = NotificationCenter.default.addObserver(forName: .ghosttyTerminalUserInput, object: terminal.view!, queue: .main) { _ in
            MainActor.assumeIsolated { inputLog.values.append(["type": "terminal_input"]) }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        do {
            try await terminal.wait("The clipboard fixture terminal did not reach an empty prompt", timeout: 10) {
                ghostty_surface_prompt_state(terminal.surface)
            }
            try await fixture.load()
            _ = terminal.view!.window?.makeFirstResponder(nil)
            let container = NSView(frame: NSRect(x: 0, y: 0, width: 960, height: 420))
            terminal.view!.frame = NSRect(x: 0, y: 0, width: 480, height: 420)
            fixture.view.frame = NSRect(x: 480, y: 0, width: 480, height: 420)
            container.addSubview(terminal.view!)
            container.addSubview(fixture.view)
            fixture.window.contentView = container
            fixture.window.setContentSize(NSSize(width: 960, height: 420))
            container.layoutSubtreeIfNeeded()
            #expect(fixture.window.makeFirstResponder(terminal.view!))
            #expect(terminal.view!.focused)
            #expect(fixture.window.makeFirstResponder(fixture.view))
            #expect(!terminal.view!.focused)
            // Moving the real terminal into this fixture window asynchronously
            // resizes its PTY and redraws zsh's right prompt. Capture the baseline
            // only after app ticks and the resulting screen have settled.
            var stableText = terminal.view!.visibleTextSnapshot()
            var unchangedSince = ContinuousClock.now
            try await terminal.wait("The clipboard fixture terminal did not settle after layout") {
                let text = terminal.view!.visibleTextSnapshot()
                if text != stableText {
                    stableText = text
                    unchangedSince = .now
                }
                return unchangedSince.duration(to: .now) >= .milliseconds(250)
            }
            let before = stableText
            let baseline = ghostty_surface_command_state(terminal.surface)
            let text = "ghostty-copy-paste-must-stay-chat 中文\nsecond line"
            fixture.view.pasteboard.clearContents()
            fixture.view.pasteboard.setString(text, forType: .string)
            _ = try await fixture.view.evaluateJavaScript("document.querySelector('textarea[aria-label=\"Message AI\"]').focus(); document.querySelector('textarea[aria-label=\"Message AI\"]').setSelectionRange(0, 14)")
            try fixture.key("v", code: 9)
            try await fixture.wait("document.querySelector('textarea[aria-label=\"Message AI\"]').value.includes('must-stay-chat')")
            try await Task.sleep(for: .milliseconds(250))
            #expect(inputLog.values.isEmpty)
            #expect(ghostty_surface_command_state(terminal.surface).started == baseline.started)
            #expect(ghostty_surface_command_state(terminal.surface).finished == baseline.finished)
            #expect(terminal.view!.visibleTextSnapshot() == before)
            #expect(ghostty_surface_prompt_state(terminal.surface))
            #expect(!fixture.actions.contains { ["send", "command_run", "command_fill"].contains($0["type"] as? String ?? "") })
            terminal.view!.removeFromSuperview()
            fixture.close()
            await terminal.close()
        } catch {
            terminal.view?.removeFromSuperview()
            fixture.close()
            await terminal.close()
            throw error
        }
    }
}

/// Test-only edit actions redirect WebKit's native Services to a private board.
/// The user's general pasteboard is never read, cleared, or replaced.
@MainActor
private final class ClipboardWebView: TerminalAIChatWebView {
    let pasteboard = NSPasteboard.withUniqueName()
    var copies = 0
    var pastes = 0
    var cuts = 0

    @objc func copy(_ sender: Any?) {
        copies += 1
        perform(NSSelectorFromString("writeSelectionToPasteboard:types:"), with: pasteboard, with: ["NSStringPboardType"])
    }

    @objc func paste(_ sender: Any?) {
        pastes += 1
        perform(NSSelectorFromString("readSelectionFromPasteboard:"), with: pasteboard)
    }

    @objc func cut(_ sender: Any?) {
        cuts += 1
        copy(sender)
        NSApp.sendAction(NSSelectorFromString("deleteBackward:"), to: self, from: sender)
    }
}

@MainActor
private final class ClipboardFixture {
    let view: ClipboardWebView
    let window: NSWindow
    let coordinator = TerminalAIWebView.Coordinator()
    let directory: URL
    var actions: [[String: Any]] = []

    init() throws {
        directory = try #require(Bundle.main.resourceURL?.appendingPathComponent("AIChat"))
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.add(coordinator, name: "ghosttyAI")
        view = ClipboardWebView(frame: NSRect(x: 0, y: 0, width: 480, height: 420), configuration: configuration)
        window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        coordinator.webView = view
        coordinator.documentURL = directory.appendingPathComponent("index.html")
        view.navigationDelegate = coordinator
        coordinator.onAction = { [weak self] in self?.actions.append($0) }
    }

    func load() async throws {
        coordinator.enqueue([
            "messages": [["id": "assistant", "role": "assistant", "content": [["type": "text", "text": "Rendered 中文 transcript 🐧"]]]],
            "isRunning": false, "phase": "completed", "status": "Completed", "appearance": "dark",
            "prompt": "Input 中文 draft", "context": "", "suggestedCommand": "", "suggestedExplanation": ""
        ])
        view.loadFileURL(directory.appendingPathComponent("index.html"), allowingReadAccessTo: directory)
        try await wait("document.querySelector('.markdown p')?.textContent === 'Rendered 中文 transcript 🐧'")
        try await wait("document.querySelector('textarea[aria-label=\"Message AI\"]').value === 'Input 中文 draft'")
        #expect(window.makeFirstResponder(view))
    }

    func event(_ character: String, code: UInt16) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
                                     timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                     context: nil, characters: character, charactersIgnoringModifiers: character,
                                     isARepeat: false, keyCode: code))
    }

    func key(_ character: String, code: UInt16) throws {
        #expect(window.performKeyEquivalent(with: try event(character, code: code)))
    }

    func wait(_ condition: String) async throws {
        for _ in 0..<100 {
            if (try? await view.evaluateJavaScript(condition)) as? Bool == true { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        Issue.record("The native clipboard fixture did not satisfy: \(condition)")
        throw CocoaError(.coderReadCorrupt)
    }

    func waitForNativeSelection(_ expected: String) async throws {
        // DOM selection and WebKit's native editor state arrive independently.
        // Probe native Services with a separate board before dispatching Copy or
        // Cut; this never seeds the board whose exact shortcut result we assert.
        let readinessBoard = NSPasteboard.withUniqueName()
        defer { readinessBoard.releaseGlobally() }
        for _ in 0..<100 {
            view.perform(NSSelectorFromString("writeSelectionToPasteboard:types:"), with: readinessBoard, with: ["NSStringPboardType"])
            if readinessBoard.string(forType: .string) == expected { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        Issue.record("WebKit's native clipboard selection did not become: \(expected)")
        throw CocoaError(.coderReadCorrupt)
    }

    func close() {
        view.configuration.userContentController.removeScriptMessageHandler(forName: "ghosttyAI")
        coordinator.onAction = nil
        view.stopLoading()
        window.makeFirstResponder(nil)
        window.contentView = nil
        window.close()
        view.pasteboard.releaseGlobally()
    }
}
