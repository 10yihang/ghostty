import AppKit
import SwiftUI
import WebKit

/// Only presentation data crosses this bridge. Pi configuration and credentials stay native.
struct TerminalAIWebView: NSViewRepresentable {
    @ObservedObject var model: TerminalAIModel
    var contextTitle: String
    @Binding var loadingError: String?
    var onSettings: () -> Void
    var onHide: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    func makeCoordinator() -> Coordinator { Coordinator(conversationID: model.conversationID) }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.add(context.coordinator, name: "ghosttyAI")
        let view = TerminalAIChatWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        context.coordinator.webView = view
        updateCoordinator(context.coordinator)
        guard let directory = Bundle.main.resourceURL?.appendingPathComponent("AIChat", isDirectory: true),
              FileManager.default.fileExists(atPath: directory.appendingPathComponent("index.html").path) else {
            DispatchQueue.main.async { loadingError = "The bundled AIChat resources are missing. Rebuild the app." }
            return view
        }
        let index = directory.appendingPathComponent("index.html")
        context.coordinator.documentURL = index
        view.loadFileURL(index, allowingReadAccessTo: directory)
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        updateCoordinator(context.coordinator)
    }

    static func dismantleNSView(_ view: WKWebView, coordinator: Coordinator) {
        coordinator.pendingPush?.cancel()
        coordinator.onAction = nil
        coordinator.onFailure = nil
        view.configuration.userContentController.removeScriptMessageHandler(forName: "ghosttyAI")
        view.navigationDelegate = nil
        // Hiding the renderer must not cancel the native Pi task.
    }

    private func updateCoordinator(_ coordinator: Coordinator) {
        guard coordinator.conversationID == model.conversationID else { return }
        coordinator.onFailure = { [weak coordinator] message in
            guard coordinator?.conversationID == model.conversationID else { return }
            loadingError = message
        }
        coordinator.onAction = { [weak coordinator] record in
            guard let coordinator, coordinator.conversationID == model.conversationID else { return }
            switch record["type"] as? String {
            case "send":
                guard let text = record["text"] as? String, text.utf8.count <= 65_536,
                      let mode = record["mode"] as? String,
                      ["prompt", "steer", "follow_up"].contains(mode),
                      coordinator.acceptDraftRevision(record) else { return }
                model.sendInput(text, mode: mode)
                if model.configurationIssue != nil { onSettings() }
            case "draft":
                guard let text = record["text"] as? String, text.utf8.count <= 65_536,
                      coordinator.acceptDraftRevision(record) else { return }
                model.prompt = text
            case "stop": model.stop()
            case "terminal_control":
                guard let allow = record["allow"] as? Bool else { return }
                model.terminalControlAllowed = allow
            case "approval":
                guard let id = record["id"] as? String, id == model.approval?.id,
                      let allow = record["allow"] as? Bool else { return }
                model.respondToApproval(allow: allow)
            case "settings": onSettings()
            case "hide": onHide()
            case "new": if !model.isRunning { model.reset() }
            case "copy":
                guard let text = record["text"] as? String, text.utf8.count <= 1_048_576 else { return }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            case "remove_context": if !model.isRunning { model.context = "" }
            case "command_fill": if let command = record["command"] as? String { model.fillSuggestedCommand(command) }
            case "command_run": if let command = record["command"] as? String { model.runSuggestedCommand(command) }
            case "command_explain": if let id = record["id"] as? String { model.explainCommand(id) }
            case "command_attach": if let id = record["id"] as? String { model.attachCommand(id) }
            case "attach_context": if let kind = record["kind"] as? String { model.attachContext(kind: kind, path: record["path"] as? String) }
            case "remove_attachment": if let id = record["id"] as? String { model.removeAttachment(id) }
            case "workflow_save": model.saveWorkflow(record)
            case "workflow_use":
                if let id = record["id"] as? String, let values = record["values"] as? [String: String] { model.useWorkflow(id, values: values) }
            case "workflow_remove": if let id = record["id"] as? String { model.removeWorkflow(id) }
            case "ssh_setup": model.showSSHSetup()
            default: break
            }
        }
        var snapshot = model.webSnapshot
        snapshot["contextTitle"] = contextTitle
        snapshot["appearance"] = colorScheme == .dark ? "dark" : "light"
        snapshot["draftRevision"] = coordinator.draftRevision
        coordinator.enqueue(snapshot)
    }

    @MainActor
    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        weak var webView: WKWebView?
        var documentURL: URL?
        var onAction: (([String: Any]) -> Void)?
        var onFailure: ((String) -> Void)?
        var pendingPush: DispatchWorkItem?
        private var ready = false
        private var snapshot: [String: Any] = [:]
        private(set) var draftRevision = 0
        let conversationID: UUID?

        init(conversationID: UUID? = nil) {
            self.conversationID = conversationID
            super.init()
        }

        func acceptDraftRevision(_ record: [String: Any]) -> Bool {
            guard let revision = record["revision"] as? Int, revision >= draftRevision else { return false }
            draftRevision = revision
            return true
        }

        func enqueue(_ snapshot: [String: Any]) {
            self.snapshot = snapshot
            guard ready, pendingPush == nil else { return }
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.pendingPush = nil
                self.push()
            }
            pendingPush = work
            // Coalesce fast token events without repeatedly replacing the React tree.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.04, execute: work)
        }

        private func push() {
            guard ready, let webView else { return }
            webView.callAsyncJavaScript(
                "window.ghosttyAI.update(snapshot)",
                arguments: ["snapshot": snapshot],
                in: nil,
                in: .page) { [weak self] result in
                    if case .failure(let error) = result {
                        self?.onFailure?("The AI view could not update: \(error.localizedDescription)")
                    }
                }
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.frameInfo.isMainFrame,
                  message.frameInfo.request.url?.standardizedFileURL == documentURL?.standardizedFileURL,
                  let record = message.body as? [String: Any] else { return }
            if record["type"] as? String == "ready" {
                ready = true
                if let webView { webView.window?.makeFirstResponder(webView) }
                push()
            } else {
                guard ready else { return }
                onAction?(record)
            }
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if let url = navigationAction.request.url, url.standardizedFileURL == documentURL?.standardizedFileURL,
               navigationAction.targetFrame?.isMainFrame == true {
                decisionHandler(.allow)
                return
            }
            if navigationAction.navigationType == .linkActivated,
               let url = navigationAction.request.url, ["https", "http", "mailto"].contains(url.scheme?.lowercased() ?? "") {
                NSWorkspace.shared.open(url)
            }
            decisionHandler(.cancel)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
            onFailure?(error.localizedDescription)
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
            onFailure?(error.localizedDescription)
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            ready = false
            onFailure?("The AI view stopped responding. Reload the conversation to reconnect to the running task.")
        }
    }
}

/// Keep standard macOS editing shortcuts on the focused chat's native responder.
/// WKWebView otherwise consumes the key equivalent before the Edit menu can act.
@MainActor
class TerminalAIChatWebView: WKWebView {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown,
              event.modifierFlags.intersection([.command, .control, .option, .shift]) == .command,
              let responder = window?.firstResponder,
              responder === self || (responder as? NSView)?.isDescendant(of: self) == true else {
            return super.performKeyEquivalent(with: event)
        }

        let action: Selector
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "c": action = #selector(NSText.copy(_:))
        case "v": action = #selector(NSText.paste(_:))
        case "x": action = #selector(NSText.cut(_:))
        case "a": action = #selector(NSText.selectAll(_:))
        default: return super.performKeyEquivalent(with: event)
        }
        return NSApp.sendAction(action, to: self, from: self)
    }
}
