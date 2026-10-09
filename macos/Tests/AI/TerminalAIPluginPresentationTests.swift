import AppKit
import SwiftUI
import Testing
@testable import Ghostty

@Suite(.serialized)
@MainActor
struct TerminalAIPluginPresentationTests {
    @Test(arguments: TerminalAIPlacement.allCases)
    func pluginPickerUsesTheConversationWindowAndCanBeReopened(placement: TerminalAIPlacement) async throws {
        let fixture = try PluginPresentationFixture(placement: placement)
        defer { fixture.close() }
        try await fixture.openSettings()
        try await fixture.openPlugins()
        let firstSheet = try #require(fixture.pluginSheet)
        #expect(firstSheet.sheetParent === fixture.window)
        #expect(fixture.settingsPopover == nil)
        #expect(fixture.model.availablePlugins.isEmpty)
        #expect(fixture.sentCommands.isEmpty)

        fixture.click(firstSheet, NSPoint(x: 514, y: firstSheet.contentView!.bounds.height - 30))
        try await fixture.wait("Done did not dismiss the plugin picker") { fixture.pluginSheet == nil }
        try await fixture.openSettings()
        try await fixture.openPlugins()
        let secondSheet = try #require(fixture.pluginSheet)
        #expect(secondSheet.sheetParent === fixture.window)
        #expect(fixture.settingsPopover == nil)
        #expect(fixture.sentCommands.isEmpty)
    }
}

/// All input stays inside this test's window. There is no terminal, Pi process,
/// real configuration, global input event, or user pasteboard in this fixture.
@MainActor
private final class PluginPresentationFixture {
    let directory: URL
    let defaults: UserDefaults
    let suite: String
    let model: TerminalAIModel
    let window: NSWindow
    let host: NSHostingView<TerminalAIView>
    private let records: PluginPresentationRecords
    private var ownedPopovers: [NSWindow] = []

    var sentCommands: [[String: Any]] { records.commands }

    var settingsPopover: NSWindow? {
        NSApp.windows.first {
            $0.isVisible && $0.parent === window && String(describing: type(of: $0)).contains("PopoverWindow")
        }
    }

    var pluginSheet: NSWindow? {
        NSApp.windows.first {
            guard $0.isVisible, String(describing: type(of: $0)).contains("SheetPresentationWindow") else { return false }
            let parent = $0.sheetParent
            return parent === window || ownedPopovers.contains { $0 === parent }
        }
    }

    init(placement: TerminalAIPlacement) throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ghostty-plugin-presentation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        suite = "ghostty-plugin-presentation.\(UUID().uuidString)"
        defaults = try #require(UserDefaults(suiteName: suite))
        defaults.set(true, forKey: "terminalAI.useExistingPiConfiguration")
        defaults.set(directory.path, forKey: "terminalAI.piConfigurationDirectory")
        defaults.set("/fixture/pi", forKey: "terminalAI.executablePath")
        defaults.set("/fixture/node", forKey: "terminalAI.nodePath")
        records = PluginPresentationRecords()
        let records = self.records
        model = TerminalAIModel(defaults: defaults, sendCommand: { records.commands.append($0) },
                                configurationDirectory: directory.appendingPathComponent("ghostty-ai"))
        host = NSHostingView(rootView: TerminalAIView(model: model, placement: .constant(placement), onClose: {}))
        host.frame = NSRect(x: 0, y: 0, width: 1_000, height: 700)
        window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
    }

    func openSettings() async throws {
        window.makeKey()
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(200))
        try preview("panel", view: host)
        // These coordinates are in our fixed-size native host, inside the
        // actual AI settings gear. No event enters the system event queue.
        click(window, NSPoint(x: host.bounds.width - 94, y: host.bounds.height - 16), trackingButton: true)
        try await wait("The actual AI settings gear did not open its popover") { settingsPopover != nil }
        try preview("settings", view: try #require(settingsPopover?.contentView))
    }

    func openPlugins() async throws {
        let popover = try #require(settingsPopover)
        ownedPopovers.append(popover)
        let content = try #require(popover.contentView)
        let point = NSPoint(x: 70, y: content.isFlipped ? 74 : content.bounds.height - 74)
        let location = content.convert(point, to: nil)
        popover.makeKey()
        click(popover, location)
        try await wait("The actual Pi plugins button did not present a plugin picker") { pluginSheet != nil }
        try preview("picker", view: try #require(pluginSheet?.contentView))
    }

    func click(_ target: NSWindow, _ location: NSPoint, trackingButton: Bool = false) {
        let time = ProcessInfo.processInfo.systemUptime
        let down = NSEvent.mouseEvent(with: .leftMouseDown, location: location, modifierFlags: [], timestamp: time,
                                      windowNumber: target.windowNumber, context: nil, eventNumber: 1,
                                      clickCount: 1, pressure: 1)!
        let up = NSEvent.mouseEvent(with: .leftMouseUp, location: location, modifierFlags: [], timestamp: time + 0.01,
                                    windowNumber: target.windowNumber, context: nil, eventNumber: 2,
                                    clickCount: 1, pressure: 0)!
        // AppKit buttons consume mouse-up inside their nested tracking loop.
        // Queue it in this test process before invoking mouse-down directly.
        if trackingButton { NSApp.postEvent(up, atStart: true) }
        target.sendEvent(down)
        // SwiftUI's drawn buttons do not enter AppKit's tracking loop.
        // A duplicate mouse-up after native tracking has no active press to end.
        target.sendEvent(up)
    }

    func wait(_ message: String, until predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !predicate() {
            guard ContinuousClock.now < deadline else {
                throw NSError(domain: "PluginPresentationFixture", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    func preview(_ name: String, view: NSView) throws {
        view.layoutSubtreeIfNeeded()
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: FileManager.default.temporaryDirectory.appendingPathComponent("ghostty-plugin-presentation-\(name).png"))
    }

    func close() {
        for child in NSApp.windows where child.sheetParent === window || ownedPopovers.contains(where: { $0 === child.sheetParent }) {
            child.close()
        }
        for popover in ownedPopovers { popover.close() }
        window.close()
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory)
    }
}

@MainActor
private final class PluginPresentationRecords {
    var commands: [[String: Any]] = []
}
