import AppKit
import SwiftUI
import Testing
@testable import Ghostty

@MainActor
struct TerminalAIHistoryViewTests {
    @Test func savedConversationsRenderInNativeHistoryPopover() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ghostty-history-render-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = TerminalAIHistoryStore(directory: directory.appendingPathComponent("conversations"))
        let titles = ["排查 CPU 占用最高的进程", "Investigate failed build", "解释终端选中的日志", "Review service startup"]
        for (index, title) in titles.enumerated() {
            let entry = TerminalAIHistoryStore.Entry(
                id: UUID(), title: title, updatedAt: Date().addingTimeInterval(Double(-index * 3600)),
                sourceDirectory: "/Users/developer/code/observability/platform/one-agent/very-long-workspace-directory",
                workingDirectory: directory.path, model: index.isMultiple(of: 2) ? "dms-adapter/kimi-k3" : "openai/gpt-5",
                messageCount: 2)
            try store.save(.init(entry: entry, messages: [
                ["id": "user", "role": "user", "content": [["type": "text", "text": title]]],
                ["id": "assistant", "role": "assistant", "content": [["type": "text", "text": "Saved response"]]]
            ], phase: "completed"))
        }

        let suite = "ghostty-history-render.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = TerminalAIModel(defaults: defaults, configurationDirectory: directory)
        model.refreshHistory()
        #expect(model.history.count == titles.count)
        #expect(model.history.allSatisfy { $0.messageCount == 2 })

        let view = NSHostingView(rootView: TerminalAIHistoryView(model: model, onOpen: {})
            .background(Color(nsColor: .windowBackgroundColor)))
        view.appearance = NSAppearance(named: .darkAqua)
        view.frame = NSRect(x: 0, y: 0, width: 400, height: 440)
        let window = NSWindow(contentRect: view.frame, styleMask: [], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        defer { window.close() }
        view.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(200))
        view.layoutSubtreeIfNeeded()
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        #expect(bitmap.pixelsWide >= 400 && bitmap.pixelsHigh >= 440)
        #expect(png.count > 1_000)
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("ghostty-history-popover.png")
        try png.write(to: output)
        print("History popover preview: \(output.path)")
    }
}
