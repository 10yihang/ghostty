import AppKit
import SwiftUI
import Testing
import Vision
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

    @Test func pluginSwitchesShowInlineTrustAndCompatibilityAndPersistOnlyApproval() async throws {
        let fixture = try PluginPresentationFixture(placement: .right, packages: ["fixture-plugin", "pi-cc-extensions"])
        defer { fixture.close() }
        try await fixture.openSettings()
        try await fixture.openPlugins()
        try await fixture.wait("The controlled plugin catalog did not finish loading") {
            fixture.model.availablePlugins.count == 2 && !fixture.model.pluginsLoading && fixture.pluginSwitches.count == 2
        }
        let normal = try #require(fixture.model.availablePlugins.first { $0.name == "fixture-plugin" })
        let unavailable = try #require(fixture.model.availablePlugins.first { $0.name == "pi-cc-extensions" })
        let picker = try #require(fixture.pluginSheet)
        let windows = fixture.visibleWindowNumbers
        #expect(fixture.model.enabledPluginIDs.isEmpty)
        for control in fixture.pluginSwitches { #expect(control.isEnabled) }

        try fixture.clickPluginSwitch(0)
        try await fixture.wait("Clicking the real plugin switch did not present Trust and enable") {
            try fixture.inlineActionFrame("Trust and enable") != nil
        }
        #expect(fixture.model.enabledPluginIDs.isEmpty)
        #expect(fixture.visibleWindowNumbers == windows)
        #expect(fixture.pluginSheet === picker)
        try fixture.preview("trust-inline", view: try #require(fixture.pluginSheet?.contentView))
        try fixture.clickInlineAction("Cancel")
        try await fixture.wait("Cancel did not leave the plugin switch off") {
            try fixture.inlineActionFrame("Trust and enable") == nil && fixture.pluginSwitches.first?.state == .off
        }
        #expect(fixture.model.enabledPluginIDs.isEmpty)
        #expect(fixture.pluginSheet === picker && picker.isVisible)

        try fixture.clickPluginSwitch(0)
        try await fixture.wait("The inline trust confirmation could not be reopened") { try fixture.inlineActionFrame("Trust and enable") != nil }
        try fixture.clickInlineAction("Trust and enable")
        try await fixture.wait("Trust and enable did not turn on the real plugin switch") {
            fixture.model.enabledPluginIDs == [normal.id] && fixture.pluginSwitches.first?.state == .on
        }
        #expect(fixture.defaults.stringArray(forKey: "terminalAI.enabledPluginIDs") == [normal.id])

        try fixture.clickPluginSwitch(1)
        try await fixture.wait("The unavailable plugin switch did not explain its limitation") { try fixture.inlineActionFrame("Close") != nil }
        #expect(fixture.visibleWindowNumbers == windows)
        try fixture.preview("unavailable-inline", view: try #require(fixture.pluginSheet?.contentView))
        #expect(try fixture.inlineActionFrame("Trust and enable") == nil)
        #expect(!fixture.model.enabledPluginIDs.contains(unavailable.id))
        try fixture.clickInlineAction("Close")
        try await fixture.wait("The unavailable plugin switch did not stay off") {
            try fixture.inlineActionFrame("Close") == nil && fixture.pluginSwitches.last?.state == .off
        }
        #expect(fixture.defaults.stringArray(forKey: "terminalAI.enabledPluginIDs") == [normal.id])
        #expect(fixture.pluginSheet === picker && picker.isVisible)
        #expect(fixture.visibleWindowNumbers == windows)
        #expect(fixture.sentCommands.isEmpty)
    }

    @Test func aRunningTaskDisablesSwitchesAndShowsWhy() async throws {
        let fixture = try PluginPresentationFixture(placement: .right, packages: ["fixture-plugin"])
        defer { fixture.model.stop(); fixture.close() }
        fixture.model.present(surfaceID: UUID(), directory: fixture.directory.path, selection: nil)
        fixture.model.prompt = "Controlled UI task"
        fixture.model.submit()
        #expect(fixture.model.isRunning)
        try await fixture.openSettings()
        try await fixture.openPlugins()
        try await fixture.wait("The disabled plugin switch and explanation did not render") {
            try fixture.renders("Wait for the current task") && fixture.pluginSwitches.count == 1
        }
        #expect(fixture.pluginSwitches.first?.isEnabled == false)
        #expect(try fixture.inlineActionFrame("Trust and enable") == nil)
        fixture.model.stop()
        fixture.model.receive(["type": "agent_settled"])
        try await fixture.wait("Finishing the task did not unlock the plugin switch") { fixture.pluginSwitches.first?.isEnabled == true }
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

    var pluginSwitches: [NSSwitch] {
        guard let content = pluginSheet?.contentView else { return [] }
        return descendants(content).compactMap { $0 as? NSSwitch }.sorted {
            $0.convert($0.bounds, to: nil).midY > $1.convert($1.bounds, to: nil).midY
        }
    }

    var visibleWindowNumbers: Set<Int> {
        Set(NSApp.windows.filter { candidate in
            guard candidate.isVisible else { return false }
            var owner: NSWindow? = candidate
            while let current = owner {
                if current === window || ownedPopovers.contains(where: { $0 === current }) { return true }
                owner = current.sheetParent ?? current.parent
            }
            return false
        }.map(\.windowNumber))
    }

    func clickPluginSwitch(_ index: Int) throws {
        let control = try #require(pluginSwitches.indices.contains(index) ? pluginSwitches[index] : nil)
        #expect(control.isEnabled)
        control.performClick(nil)
    }

    // Only controlled English labels in this fixture's own rendered bitmap
    // enter Vision. No screen, application inventory, or user content is read.
    private func recognizedText() throws -> [VNRecognizedText] {
        guard let view = pluginSheet?.contentView else { return [] }
        view.layoutSubtreeIfNeeded()
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let image = try #require(bitmap.cgImage)
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["en-US"]
        request.usesLanguageCorrection = false
        try VNImageRequestHandler(cgImage: image).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first }
    }

    func inlineActionFrame(_ title: String) throws -> CGRect? {
        guard let view = pluginSheet?.contentView else { return nil }
        for candidate in try recognizedText() {
            guard let range = candidate.string.range(of: title), let observation = try candidate.boundingBox(for: range) else { continue }
            let box = observation.boundingBox
            let point = NSPoint(x: view.bounds.minX + box.midX * view.bounds.width,
                                y: view.bounds.minY + (view.isFlipped ? 1 - box.midY : box.midY) * view.bounds.height)
            let center = view.convert(point, to: nil)
            return CGRect(x: center.x - 1, y: center.y - 1, width: 2, height: 2)
        }
        return nil
    }

    func clickInlineAction(_ title: String) throws {
        let picker = try #require(pluginSheet)
        let frame = try #require(try inlineActionFrame(title))
        picker.makeKey()
        click(picker, NSPoint(x: frame.midX, y: frame.midY))
    }

    func renders(_ text: String) throws -> Bool {
        try recognizedText().map(\.string).joined(separator: " ").contains(text)
    }

    private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { descendants($0) }
    }

    init(placement: TerminalAIPlacement, packages: [String] = []) throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ghostty-plugin-presentation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for name in packages {
            let package = directory.appendingPathComponent("npm/node_modules/\(name)", isDirectory: true)
            try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
            let manifest: [String: Any] = ["name": name, "version": "1.0.0", "description": "Controlled UI test metadata",
                                           "pi": ["extensions": ["index.ts"]]]
            try JSONSerialization.data(withJSONObject: manifest).write(to: package.appendingPathComponent("package.json"))
            try Data("throw new Error('UI fixtures must never import plugin code');\n".utf8)
                .write(to: package.appendingPathComponent("index.ts"))
        }
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
        host.appearance = NSAppearance(named: .aqua)
        host.frame = NSRect(x: 0, y: 0, width: 1_000, height: 700)
        window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .aqua)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
    }

    func openSettings() async throws {
        window.makeKey()
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(200))
        try preview("panel", view: host)
        // The header's native event handler tracks the release inside mouse-down.
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
        // Send a direct release only when mouse-down did not consume it while tracking.
        if !trackingButton { target.sendEvent(up) }
    }

    func wait(_ message: String, until predicate: () throws -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while try !predicate() {
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
