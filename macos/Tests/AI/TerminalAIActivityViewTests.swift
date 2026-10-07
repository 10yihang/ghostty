import AppKit
import SwiftUI
import Testing
@testable import Ghostty

@MainActor
struct TerminalAIActivityViewTests {
    @Test func idleAndOldCompletionLeaveTheTerminalUnobstructed() {
        for phase in [TerminalAIModel.Phase.idle, .completed, .stopped] {
            #expect(presentation(phase: phase) == nil)
        }
        #expect(presentation(phase: .completed, completionVisible: true)?.kind == .completed)
        #expect(presentation(phase: .stopped, completionVisible: true)?.kind == .stopped)
        #expect(presentation(phase: .thinking, completionVisible: true) == nil)
    }

    @Test func activeWorkAndApprovalRemainActionableUntilThePanelOpens() throws {
        let running = try #require(presentation(phase: .executing, isRunning: true))
        #expect(running.showsProgress && running.canStop && !running.canDismiss)
        let approval = try #require(presentation(phase: .waitingApproval, isRunning: true))
        #expect(approval.kind == .approval && !approval.showsProgress && approval.canStop && !approval.canDismiss)
        let stopping = try #require(presentation(phase: .stopping, isRunning: true))
        #expect(stopping.showsProgress && !stopping.canStop && !stopping.canDismiss)
        #expect(presentation(phase: .waitingApproval, isRunning: true, isPresented: true) == nil)
        #expect(presentation(phase: .failed, hasError: true, isPresented: true) == nil)
        #expect(presentation(phase: .completed, completionVisible: true, isPresented: true) == nil)
    }

    @Test func anAcknowledgedIssueDoesNotKeepBlockingTheTerminal() throws {
        let failure = try #require(presentation(phase: .failed, hasError: true))
        #expect(failure.kind == .failed && failure.canDismiss && !failure.canStop)
        #expect(presentation(phase: .failed, hasError: true, issueDismissed: true) == nil)
        #expect(presentation(phase: .idle, hasError: true)?.kind == .failed)
        #expect(presentation(phase: .thinking, isRunning: true, issueDismissed: true)?.kind == .working)
    }

    @Test func compactNativeNoticePreservesPromptHitTestingAndFirstResponder() async throws {
        for phase in [TerminalAIModel.Phase.waitingApproval, .completed, .failed] {
            let activity = try #require(presentation(
                phase: phase, isRunning: phase == .waitingApproval,
                hasError: phase == .failed, completionVisible: phase == .completed))
            let terminal = NSTextView(frame: NSRect(x: 0, y: 0, width: 720, height: 200))
            terminal.string = "root@fixture-host:admin# "
            terminal.font = .monospacedSystemFont(ofSize: 15, weight: .regular)
            terminal.backgroundColor = NSColor(red: 0.12, green: 0.12, blue: 0.18, alpha: 1)
            terminal.textColor = NSColor(red: 0.72, green: 0.85, blue: 0.62, alpha: 1)
            terminal.textContainerInset = NSSize(width: 10, height: 12)
            let container = NSView(frame: terminal.frame)
            container.addSubview(terminal)
            let host = NSHostingView(rootView: TerminalAIActivityView(
                presentation: activity, detail: activity.title, onOpen: {}, onStop: {}, onDismiss: {}))
            host.appearance = NSAppearance(named: .darkAqua)
            let noticeSize = host.fittingSize
            #expect(noticeSize.width < 280 && noticeSize.height <= 40)
            host.frame = NSRect(x: container.bounds.width - noticeSize.width - 10,
                                y: container.bounds.height - noticeSize.height - 10,
                                width: noticeSize.width, height: noticeSize.height)
            container.addSubview(host)
            let window = NSWindow(contentRect: container.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: .darkAqua)
            window.contentView = container
            defer { window.close() }
            #expect(window.makeFirstResponder(terminal))
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(100))
            #expect(window.firstResponder === terminal)
            #expect(container.hitTest(NSPoint(x: 20, y: 20)) === terminal)
            #expect(terminal.frame == container.bounds)
            let bitmap = try #require(container.bitmapImageRepForCachingDisplay(in: container.bounds))
            container.cacheDisplay(in: container.bounds, to: bitmap)
            let png = try #require(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("ghostty-ai-activity-\(phase.rawValue).png"))
        }
    }

    private func presentation(
        phase: TerminalAIModel.Phase,
        isRunning: Bool = false,
        hasError: Bool = false,
        completionVisible: Bool = false,
        issueDismissed: Bool = false,
        isPresented: Bool = false
    ) -> TerminalAIActivityPresentation? {
        TerminalAIActivityPresentation.resolve(
            isPresented: isPresented, isRunning: isRunning, phase: phase,
            hasError: hasError, completionVisible: completionVisible, issueDismissed: issueDismissed)
    }
}
