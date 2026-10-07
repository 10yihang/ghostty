import SwiftUI
import GhosttyKit
import os

/// This delegate is notified of actions and property changes regarding the terminal view. This
/// delegate is optional and can be used by a TerminalView caller to react to changes such as
/// titles being set, cell sizes being changed, etc.
protocol TerminalViewDelegate: AnyObject {
    /// Called when the currently focused surface changed. This can be nil.
    func focusedSurfaceDidChange(to: Ghostty.SurfaceView?)

    /// The URL of the pwd should change.
    func pwdDidChange(to: URL?)

    /// The cell size changed.
    func cellSizeDidChange(to: NSSize)

    /// Perform an action. At the time of writing this is only triggered by the command palette.
    func performAction(_ action: String, on: Ghostty.SurfaceView)

    /// A split tree operation
    func performSplitAction(_ action: TerminalSplitOperation)
}

/// The view model is a required implementation for TerminalView callers. This contains
/// the main state between the TerminalView caller and SwiftUI. This abstraction is what
/// allows AppKit to own most of the data in SwiftUI.
protocol TerminalViewModel: ObservableObject {
    /// The tree of terminal surfaces (splits) within the view. This is mutated by TerminalView
    /// and children. This should be @Published.
    var surfaceTree: SplitTree<Ghostty.SurfaceView> { get set }

    /// The command palette state.
    var commandPaletteIsShowing: Bool { get set }

    /// The update overlay should be visible.
    var updateOverlayIsVisible: Bool { get }
}

/// The main terminal view. This terminal view supports splits.
struct TerminalView<ViewModel: TerminalViewModel>: View {
    private struct TerminalExitSnapshot {
        let surfaceID: UUID
        let exitCode: Int
        let directory: String?
        let output: String
        let recordID: String?
    }

    @ObservedObject var ghostty: Ghostty.App

    // The required view model
    @ObservedObject var viewModel: ViewModel

    // An optional delegate to receive information about terminal changes.
    weak var delegate: (any TerminalViewDelegate)?

    /// The most recently focused surface, equal to `focusedSurface` when it is non-nil.
    @State private var lastFocusedSurface: Weak<Ghostty.SurfaceView>?

    /// The AI session keeps its original surface even when another split gains focus.
    @StateObject private var terminalAI = TerminalAIModel()
    @State private var aiContextTitle = "Selected text"
    @State private var aiCompletionNotice: UUID?
    @State private var aiIssueDismissed = false
    @State private var terminalExitSnapshots: [UUID: TerminalExitSnapshot] = [:]
    @AppStorage("terminalAI.panelPlacement") private var panelPlacement = "right"
    @AppStorage("terminalAI.bottomPanelHeight") private var bottomPanelHeight = 340.0
    @AppStorage("terminalAI.rightPanelWidth") private var rightPanelWidth = 440.0
    @State private var floatingSize = CGSize(width: 560, height: 400)
    @State private var floatingOrigin: CGPoint?
    @State private var floatingMove = CGSize.zero
    @State private var floatingResizeStart: CGRect?
    @State private var dockResizeStart: CGSize?
    @GestureState private var dockResize = CGSize.zero
    @GestureState private var floatingResize = CGSize.zero

    // This seems like a crutch after switching from SwiftUI to AppKit lifecycle.
    @FocusState private var focused: Bool

    // Various state values sent back up from the currently focused terminals.
    @FocusedValue(\.ghosttySurfaceView) private var focusedSurface
    @FocusedValue(\.ghosttySurfacePwd) private var surfacePwd
    @FocusedValue(\.ghosttySurfaceCellSize) private var cellSize

    // The pwd of the focused surface as a URL
    private var pwdURL: URL? {
        guard let surfacePwd, surfacePwd != "" else { return nil }
        return URL(fileURLWithPath: surfacePwd)
    }

    private var aiPlacement: TerminalAIPlacement {
        TerminalAIPlacement(rawValue: panelPlacement) ?? .right
    }

    private var placementBinding: Binding<TerminalAIPlacement> {
        Binding(get: { aiPlacement }, set: { panelPlacement = $0.rawValue })
    }

    var body: some View {
        switch ghostty.readiness {
        case .loading:
            Text("Loading")
        case .error:
            ErrorView()
        case .ready:
            ZStack {
                VStack(spacing: 0) {
                    // If we're running in debug mode we show a warning so that users
                    // know that performance will be degraded.
                    if Ghostty.info.mode == GHOSTTY_BUILD_MODE_DEBUG || Ghostty.info.mode == GHOSTTY_BUILD_MODE_RELEASE_SAFE {
                        DebugBuildWarningView()
                    }

                    GeometryReader { geometry in
                        terminalWorkspace(in: geometry.size)
                    }

                }
                // Ignore safe area to extend up in to the titlebar region if we have the "hidden" titlebar style
                .ignoresSafeArea(.container, edges: ghostty.config.macosTitlebarStyle == .hidden ? .top : [])
                .popover(isPresented: $terminalAI.commandEntryPresented, arrowEdge: .bottom) {
                    TerminalAICommandEntryView(model: terminalAI, onOpenConversation: {
                        terminalAI.commandEntryPresented = false
                        terminalAI.isPresented = true
                    }, onClose: { terminalAI.commandEntryPresented = false })
                }

                if let surfaceView = lastFocusedSurface?.value {
                    TerminalCommandPaletteView(
                        surfaceView: surfaceView,
                        isPresented: $viewModel.commandPaletteIsShowing,
                        ghosttyConfig: ghostty.config,
                        updateViewModel: (NSApp.delegate as? AppDelegate)?.updateViewModel,
                        onAskAI: { presentAI(on: surfaceView) },
                        onAction: { action in
                            self.delegate?.performAction(action, on: surfaceView)
                        })
                }

                // Show update information above all else.
                if viewModel.updateOverlayIsVisible {
                    UpdateOverlay()
                }
            }
            .frame(maxWidth: .greatestFiniteMagnitude, maxHeight: .greatestFiniteMagnitude)
            .onReceive(NotificationCenter.default.publisher(for: .ghosttyToggleAI)) { notification in
                guard let surface = notification.object as? Ghostty.SurfaceView,
                      viewModel.surfaceTree.find(id: surface.id) != nil else { return }
                if terminalAI.isPresented && (terminalAI.surfaceID == surface.id || terminalAI.isRunning) {
                    closeAI()
                } else {
                    presentAI(on: surface)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .ghosttyAskAI)) { notification in
                guard let surface = notification.object as? Ghostty.SurfaceView,
                      viewModel.surfaceTree.find(id: surface.id) != nil else { return }
                presentAI(on: surface, selection: notification.userInfo?["selection"] as? String)
                if !terminalAI.isRunning {
                    terminalAI.prompt = "Explain the selected terminal text."
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .ghosttyAICommandEntry)) { notification in
                guard let surface = notification.object as? Ghostty.SurfaceView,
                      viewModel.surfaceTree.find(id: surface.id) != nil, !terminalAI.isRunning else { return }
                let wasPresented = terminalAI.isPresented
                terminalAI.present(surfaceID: surface.id, directory: surface.pwd, selection: surface.accessibilitySelectedText())
                terminalAI.bindTerminal(surface)
                terminalAI.isPresented = wasPresented
                terminalAI.commandEntryPresented.toggle()
            }
            .onReceive(NotificationCenter.default.publisher(for: .ghosttyCommandFinished)) { notification in
                guard let surface = notification.object as? Ghostty.SurfaceView,
                      let exitCode = notification.userInfo?["exitCode"] as? Int,
                      viewModel.surfaceTree.find(id: surface.id) != nil else { return }
                terminalAI.recordCommandHistory(from: surface)
                if exitCode == 0 {
                    terminalExitSnapshots[surface.id] = nil
                    return
                }
                guard ![130, 141, 143].contains(exitCode) else { return }
                let sequence = notification.userInfo?["recordSequence"] as? UInt64
                let record = terminalAI.commands.first {
                    $0.surfaceID == surface.id && $0.sequence == sequence && !$0.running && $0.exitCode == exitCode
                }
                terminalExitSnapshots[surface.id] = TerminalExitSnapshot(
                    surfaceID: surface.id,
                    exitCode: exitCode,
                    directory: record?.directory,
                    output: String(surface.visibleTextSnapshot().prefix(32_768)),
                    recordID: record?.id)
            }
            .onChange(of: viewModel.surfaceTree.map(\.id)) { ids in
                if let id = terminalAI.surfaceID, !ids.contains(id) {
                    terminalAI.stop()
                    terminalAI.isPresented = false
                }
                terminalExitSnapshots = terminalExitSnapshots.filter { ids.contains($0.key) }
            }
            .onChange(of: terminalAI.phase) { phase in
                aiCompletionNotice = !terminalAI.isPresented && (phase == .completed || phase == .stopped) ? UUID() : nil
                if phase == .failed { aiIssueDismissed = false }
            }
            .onChange(of: terminalAI.startedAt) { _ in aiIssueDismissed = false }
            .onChange(of: terminalAI.error) { _ in aiIssueDismissed = false }
            .onChange(of: terminalAI.isPresented) { presented in
                if presented {
                    aiCompletionNotice = nil
                    aiIssueDismissed = true
                }
            }
            .task(id: aiCompletionNotice) {
                guard let notice = aiCompletionNotice else { return }
                do {
                    try await Task.sleep(for: .seconds(6))
                    if aiCompletionNotice == notice { aiCompletionNotice = nil }
                } catch { /* A newer run or opening the panel supersedes this notice. */ }
            }
        }
    }

    private var terminalSurface: some View {
        TerminalSplitTreeView(
            tree: viewModel.surfaceTree,
            action: { delegate?.performSplitAction($0) })
            .environmentObject(ghostty)
            .ghosttyLastFocusedSurface(lastFocusedSurface)
            .focused($focused)
            .onAppear { self.focused = true }
            .onChange(of: focusedSurface) { newValue in
                if newValue != nil {
                    lastFocusedSurface = .init(newValue)
                    self.delegate?.focusedSurfaceDidChange(to: newValue)
                }
            }
            .onChange(of: pwdURL) { self.delegate?.pwdDidChange(to: $0) }
            .onChange(of: cellSize) { newValue in
                guard let size = newValue else { return }
                self.delegate?.cellSizeDidChange(to: size)
            }
            .frame(idealWidth: lastFocusedSurface?.value?.initialSize?.width,
                   idealHeight: lastFocusedSurface?.value?.initialSize?.height)
    }

    private func terminalWorkspace(in size: CGSize) -> some View {
        let panel = aiPanelFrame(in: size)
        let terminalSize = CGSize(
            width: terminalAI.isPresented && aiPlacement == .right ? max(0, panel.minX - 5) : size.width,
            height: terminalAI.isPresented && aiPlacement == .bottom ? max(0, panel.minY - 5) : size.height)

        return ZStack(alignment: .topLeading) {
            // Keep both child identities stable while changing their geometry.
            terminalSurface
                .frame(width: terminalSize.width, height: terminalSize.height)
                .overlay(alignment: .topTrailing) {
                    if let activity = TerminalAIActivityPresentation.resolve(
                        isPresented: terminalAI.isPresented,
                        isRunning: terminalAI.isRunning,
                        phase: terminalAI.phase,
                        hasError: terminalAI.error != nil,
                        completionVisible: aiCompletionNotice != nil,
                        issueDismissed: aiIssueDismissed) {
                        TerminalAIActivityView(
                            presentation: activity,
                            detail: terminalAI.statusLabel,
                            onOpen: { terminalAI.isPresented = true },
                            onStop: terminalAI.stop,
                            onDismiss: {
                                aiCompletionNotice = nil
                                aiIssueDismissed = true
                            })
                            .padding(10)
                    }
                }

            if terminalAI.isPresented {
                TerminalAIView(
                    model: terminalAI,
                    terminalTitle: viewModel.surfaceTree.first(where: { $0.id == terminalAI.surfaceID })?.title ?? "Terminal",
                    contextTitle: aiContextTitle,
                    placement: placementBinding,
                    hasFailedCommand: terminalAI.surfaceID.flatMap { terminalExitSnapshots[$0] } != nil,
                    onInvestigateFailure: investigateLastExit,
                    onMove: { floatingMove = $0 },
                    onEndMove: { finishFloatingMove(in: size) },
                    onClose: closeAI)
                    .frame(width: panel.width, height: panel.height)
                    .clipShape(RoundedRectangle(cornerRadius: aiPlacement == .floating ? 12 : 0))
                    .shadow(color: .black.opacity(aiPlacement == .floating ? 0.2 : 0), radius: 12, x: 0, y: 4)
                    .offset(x: panel.minX, y: panel.minY)

                if aiPlacement == .floating {
                    floatingResizeHandle(in: size, panel: panel)
                } else {
                    dockResizeHandle(in: size, panel: panel)
                        .id(aiPlacement)
                }
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .onChange(of: size) { newSize in
            let panel = aiPanelFrame(in: newSize)
            if aiPlacement == .floating {
                let origin = CGPoint(x: panel.minX - floatingMove.width, y: panel.minY - floatingMove.height)
                floatingOrigin = origin
                if floatingResizeStart != nil {
                    floatingResizeStart = CGRect(
                        origin: origin,
                        size: CGSize(width: panel.width - floatingResize.width, height: panel.height - floatingResize.height))
                }
            } else if dockResizeStart != nil {
                dockResizeStart = CGSize(width: panel.width + dockResize.width, height: panel.height + dockResize.height)
            }
        }
        .onChange(of: aiPlacement) { _ in clearPanelDragState() }
        .onChange(of: terminalAI.isPresented) { presented in
            if !presented { clearPanelDragState() }
        }
    }

    private func aiPanelFrame(in size: CGSize) -> CGRect {
        switch aiPlacement {
        case .bottom:
            let start = dockResizeStart?.height ?? bounded(CGFloat(bottomPanelHeight), lower: 240, upper: size.height * 0.8)
            let height = bounded(start - dockResize.height, lower: 240, upper: size.height * 0.8)
            return CGRect(x: 0, y: size.height - height, width: size.width, height: height)
        case .right:
            let start = dockResizeStart?.width ?? bounded(CGFloat(rightPanelWidth), lower: 280, upper: size.width * 0.6)
            let width = bounded(start - dockResize.width, lower: 280, upper: size.width * 0.6)
            return CGRect(x: size.width - width, y: 0, width: width, height: size.height)
        case .floating:
            let baseSize = floatingResizeStart?.size ?? CGSize(
                width: bounded(floatingSize.width, lower: 320, upper: size.width - 40),
                height: bounded(floatingSize.height, lower: 240, upper: size.height - 40))
            let origin = floatingResizeStart?.origin ?? floatingOrigin ?? CGPoint(x: size.width - baseSize.width - 20, y: 20)
            let maximumWidth = floatingResizeStart == nil ? size.width - 40 : size.width - origin.x - 20
            let maximumHeight = floatingResizeStart == nil ? size.height - 40 : size.height - origin.y - 20
            let width = bounded(baseSize.width + floatingResize.width, lower: 320, upper: maximumWidth)
            let height = bounded(baseSize.height + floatingResize.height, lower: 240, upper: maximumHeight)
            let x = bounded(origin.x + floatingMove.width, lower: min(20, size.width - width), upper: size.width - width - 20)
            let y = bounded(origin.y + floatingMove.height, lower: min(20, size.height - height), upper: size.height - height - 20)
            return CGRect(x: x, y: y, width: width, height: height)
        }
    }

    private func bounded(_ value: CGFloat, lower: CGFloat, upper: CGFloat) -> CGFloat {
        let maximum = max(0, upper)
        return min(max(value, min(lower, maximum)), maximum)
    }

    private func dockResizeHandle(in size: CGSize, panel: CGRect) -> some View {
        let bottom = aiPlacement == .bottom
        return ZStack {
            Color(nsColor: .windowBackgroundColor)
            Rectangle().fill(Color(nsColor: .separatorColor))
                .frame(width: bottom ? panel.width : 1, height: bottom ? 1 : panel.height)
        }
        .frame(width: bottom ? panel.width : 5, height: bottom ? 5 : panel.height)
        .contentShape(Rectangle())
        .offset(x: bottom ? 0 : panel.minX - 5, y: bottom ? panel.minY - 5 : 0)
        .gesture(DragGesture(minimumDistance: 0)
            .updating($dockResize) { value, state, _ in state = value.translation }
            .onChanged { _ in
                if dockResizeStart == nil { dockResizeStart = panel.size }
            }
            .onEnded { value in
                let start = dockResizeStart ?? panel.size
                if bottom {
                    bottomPanelHeight = Double(bounded(start.height - value.translation.height,
                                                       lower: 240, upper: size.height * 0.8))
                } else {
                    rightPanelWidth = Double(bounded(start.width - value.translation.width,
                                                     lower: 280, upper: size.width * 0.6))
                }
                dockResizeStart = nil
            })
        .onHover { inside in
            if inside {
                (bottom ? NSCursor.resizeUpDown : NSCursor.resizeLeftRight).set()
            } else {
                NSCursor.arrow.set()
            }
        }
        .accessibilityLabel("Resize AI panel")
        .help("Drag to resize the AI panel")
    }

    private func floatingResizeHandle(in size: CGSize, panel: CGRect) -> some View {
        Image(systemName: "arrow.up.left.and.arrow.down.right")
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
            .frame(width: 20, height: 20)
            .contentShape(Rectangle())
            .offset(x: panel.maxX - 22, y: panel.maxY - 22)
            .gesture(DragGesture(minimumDistance: 0)
                .updating($floatingResize) { value, state, _ in state = value.translation }
                .onChanged { _ in
                    if floatingResizeStart == nil { floatingResizeStart = panel }
                }
                .onEnded { value in
                    let start = floatingResizeStart ?? panel
                    floatingSize = CGSize(
                        width: bounded(start.width + value.translation.width, lower: 320, upper: size.width - start.minX - 20),
                        height: bounded(start.height + value.translation.height, lower: 240, upper: size.height - start.minY - 20))
                    floatingOrigin = start.origin
                    floatingResizeStart = nil
                })
            .accessibilityLabel("Resize floating AI panel")
            .help("Drag to resize the AI panel")
    }

    private func finishFloatingMove(in size: CGSize) {
        if aiPlacement == .floating { floatingOrigin = aiPanelFrame(in: size).origin }
        floatingMove = .zero
    }

    private func clearPanelDragState() {
        floatingResizeStart = nil
        dockResizeStart = nil
        floatingMove = .zero
    }

    private func presentAI(on surface: Ghostty.SurfaceView, selection: String? = nil) {
        if !terminalAI.isRunning { aiContextTitle = "Selected text" }
        terminalAI.present(
            surfaceID: surface.id,
            directory: surface.pwd,
            selection: selection ?? surface.accessibilitySelectedText())
        terminalAI.bindTerminal(surface)
    }

    private func investigateLastExit() {
        guard !terminalAI.isRunning,
              let id = terminalAI.surfaceID,
              let failure = terminalExitSnapshots[id],
              case .leaf(let surface) = viewModel.surfaceTree.find(id: failure.surfaceID) else { return }
        terminalAI.present(surfaceID: surface.id, directory: failure.directory, selection: nil)
        terminalAI.bindTerminal(surface)
        if let recordID = failure.recordID, let record = terminalAI.commands.first(where: { $0.id == recordID }) {
            aiContextTitle = "Failed command"
            terminalAI.explainCommand(record.id)
            terminalAI.prompt = "Explain this failed command and help me investigate the problem."
            return
        }
        aiContextTitle = "Visible screen at exit"
        terminalAI.context = """
        Exit code reported by terminal: \(failure.exitCode)
        Terminal-reported directory at exit: \(failure.directory ?? "unknown")
        Context: visible screen captured when the terminal reported an exit, with no exact command block boundaries or command identity.
        The screen may include unrelated output or a remote SSH session. Use the attached terminal to verify the host before running commands; do not assume this output describes the local host.

        \(failure.output.isEmpty ? "(No visible output was available.)" : failure.output)
        """
        terminalAI.prompt = "Explain the last reported nonzero exit and the visible terminal output. Use the attached terminal to inspect relevant evidence, identify likely causes and continue troubleshooting with approved commands."
        terminalAI.submit()
    }

    private func closeAI() {
        terminalAI.isPresented = false
        guard let id = terminalAI.surfaceID,
              case .leaf(let surface) = viewModel.surfaceTree.find(id: id) else { return }
        DispatchQueue.main.async {
            surface.window?.makeFirstResponder(surface)
        }
    }
}

private struct UpdateOverlay: View {
    var body: some View {
        if let appDelegate = NSApp.delegate as? AppDelegate {
            VStack {
                Spacer()

                HStack {
                    Spacer()
                    UpdatePill(model: appDelegate.updateViewModel)
                        .padding(.bottom, 9)
                        .padding(.trailing, 9)
                }
            }
        }
    }
}

struct DebugBuildWarningView: View {
    @State private var isPopover = false

    var body: some View {
        HStack {
            Spacer()

            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.yellow)

            Text("You're running a debug build of Ghostty! Performance will be degraded.")
                .padding(.all, 8)
                .popover(isPresented: $isPopover, arrowEdge: .bottom) {
                    Text("""
                    Debug builds of Ghostty are very slow and you may experience
                    performance problems. Debug builds are only recommended during
                    development.
                    """)
                    .padding(.all)
                }

            Spacer()
        }
        .background(Color(.windowBackgroundColor))
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Debug build warning")
        .accessibilityValue("Debug builds of Ghostty are very slow and you may experience performance problems. Debug builds are only recommended during development.")
        .accessibilityAddTraits(.isStaticText)
        .onTapGesture {
            isPopover = true
        }
    }
}
