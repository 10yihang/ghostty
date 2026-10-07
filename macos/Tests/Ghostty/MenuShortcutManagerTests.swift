import AppKit
import Foundation
import Testing
@testable import Ghostty

struct MenuShortcutManagerTests {
    @MainActor @Test func aiPanelShortcutTracksConfigReloadAndUnbind() throws {
        let config = try TemporaryConfig("")
        let item = NSMenuItem(title: "AI Panel", action: #selector(BaseTerminalController.toggleAIPanel(_:)), keyEquivalent: "")
        let manager = Ghostty.MenuShortcutManager()

        manager.syncMenuShortcut(config, action: "toggle_ai_panel", menuItem: item)
        #expect(item.keyEquivalent == "a")
        #expect(item.keyEquivalentModifierMask == [.command, .shift])

        try config.reload("keybind = super+shift+a=unbind\nkeybind = super+shift+i=toggle_ai_panel")
        manager.reset()
        manager.syncMenuShortcut(config, action: "toggle_ai_panel", menuItem: item)
        #expect(item.keyEquivalent == "i")
        #expect(item.keyEquivalentModifierMask == [.command, .shift])

        try config.reload("keybind = super+shift+a=unbind")
        manager.reset()
        manager.syncMenuShortcut(config, action: "toggle_ai_panel", menuItem: item)
        #expect(item.keyEquivalent.isEmpty)
        #expect(item.keyEquivalentModifierMask.isEmpty)
    }

    @Test(.bug("https://github.com/ghostty-org/ghostty/issues/779", id: 779))
    func unbindShouldDiscardDefault() async throws {
        let config = try TemporaryConfig("keybind = super+d=unbind")

        let item = NSMenuItem(title: "Split Right", action: #selector(BaseTerminalController.splitRight(_:)), keyEquivalent: "d")
        item.keyEquivalentModifierMask = .command
        let manager = await Ghostty.MenuShortcutManager()
        await manager.reset()
        await manager.syncMenuShortcut(config, action: "new_split:right", menuItem: item)

        #expect(item.keyEquivalent.isEmpty)
        #expect(item.keyEquivalentModifierMask.isEmpty)

        try config.reload("")

        await manager.reset()
        await manager.syncMenuShortcut(config, action: "new_split:right", menuItem: item)

        #expect(item.keyEquivalent == "d")
        #expect(item.keyEquivalentModifierMask == .command)
    }

    @MainActor @Test func physicalBackquoteUsesCurrentKeyboardLayout() throws {
        let config = try TemporaryConfig("keybind=super+backquote=toggle_quick_terminal")
        let expected = try #require(KeyboardLayout.character(for: 0x32, modifiers: .command))
        let item = NSMenuItem(title: "Quick Terminal", action: nil, keyEquivalent: "")
        let manager = Ghostty.MenuShortcutManager()

        manager.reset()
        manager.syncMenuShortcut(config, action: "toggle_quick_terminal", menuItem: item)

        #expect(item.keyEquivalent == String(expected))
        #expect(item.keyEquivalentModifierMask == .command)
        #expect(!item.allowsAutomaticKeyEquivalentLocalization)
        #expect(!item.allowsAutomaticKeyEquivalentMirroring)
    }

    @Test(.bug("https://github.com/ghostty-org/ghostty/issues/11396", id: 11396))
    func overrideDefault() async throws {
        let config = try TemporaryConfig("keybind=super+h=goto_split:left")

        let hideItem = NSMenuItem(title: "Hide Ghostty", action: "hide:", keyEquivalent: "h")
        hideItem.keyEquivalentModifierMask = .command

        let goToLeftItem = NSMenuItem(title: "Select Split Left", action: "splitMoveFocusLeft:", keyEquivalent: "")

        let manager = await Ghostty.MenuShortcutManager()
        await manager.reset()

        await manager.syncMenuShortcut(config, action: nil, menuItem: hideItem)
        await manager.syncMenuShortcut(config, action: "goto_split:left", menuItem: goToLeftItem)

        #expect(hideItem.keyEquivalent.isEmpty)
        #expect(hideItem.keyEquivalentModifierMask.isEmpty)

        #expect(goToLeftItem.keyEquivalent == "h")
        #expect(goToLeftItem.keyEquivalentModifierMask == .command)
    }
}
