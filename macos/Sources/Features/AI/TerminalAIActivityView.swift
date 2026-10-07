import SwiftUI

/// The hidden conversation only needs attention while work is active or newly settled.
struct TerminalAIActivityPresentation: Equatable {
    enum Kind { case working, approval, failed, completed, stopped }

    let kind: Kind
    let title: String
    let symbol: String
    let showsProgress: Bool
    let canStop: Bool
    let canDismiss: Bool

    static func resolve(
        isPresented: Bool,
        isRunning: Bool,
        phase: TerminalAIModel.Phase,
        hasError: Bool,
        completionVisible: Bool,
        issueDismissed: Bool
    ) -> Self? {
        guard !isPresented else { return nil }
        if isRunning {
            if phase == .waitingApproval {
                return Self(kind: .approval, title: "Approval needed", symbol: "hand.raised",
                            showsProgress: false, canStop: true, canDismiss: false)
            }
            return Self(kind: .working, title: phase == .stopping ? "Stopping" : "Working", symbol: "sparkles",
                        showsProgress: true, canStop: phase != .stopping, canDismiss: false)
        }
        if (phase == .failed || hasError) && !issueDismissed {
            return Self(kind: .failed, title: "Needs attention", symbol: "exclamationmark.circle",
                        showsProgress: false, canStop: false, canDismiss: true)
        }
        guard completionVisible else { return nil }
        switch phase {
        case .completed:
            return Self(kind: .completed, title: "Completed", symbol: "checkmark.circle",
                        showsProgress: false, canStop: false, canDismiss: true)
        case .stopped:
            return Self(kind: .stopped, title: "Stopped", symbol: "stop.circle",
                        showsProgress: false, canStop: false, canDismiss: true)
        default:
            return nil
        }
    }
}

/// A compact overlay leaves the terminal grid and its first responder intact.
struct TerminalAIActivityView: View {
    let presentation: TerminalAIActivityPresentation
    let detail: String
    let onOpen: () -> Void
    let onStop: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Button(action: onOpen) {
                HStack(spacing: 6) {
                    if presentation.showsProgress {
                        ProgressView().controlSize(.small)
                            .frame(width: 14, height: 14)
                    } else {
                        Image(systemName: presentation.symbol)
                            .foregroundStyle(presentation.kind == .failed ? Color.red : Color.primary)
                    }
                    Text("AI · \(presentation.title)")
                        .lineLimit(1)
                }
                .padding(.horizontal, 6)
                .frame(height: 24)
                .contentShape(Rectangle())
            }
            .help("Open AI conversation · \(detail)")
            .accessibilityLabel("Open AI conversation: \(presentation.title)")
            .accessibilityHint(detail)

            if presentation.canStop {
                Button(action: onStop) {
                    Image(systemName: "stop.circle").frame(width: 24, height: 24)
                }
                .help("Stop AI task")
                .accessibilityLabel("Stop AI task")
            }
            if presentation.canDismiss {
                Button(action: onDismiss) {
                    Image(systemName: "xmark").font(.system(size: 10)).frame(width: 24, height: 24)
                }
                .help("Dismiss AI notice · The conversation remains available from the View menu")
                .accessibilityLabel("Dismiss AI notice")
            }
        }
        .font(.system(size: 12))
        .buttonStyle(.plain)
        .padding(4)
        .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(nsColor: .separatorColor), lineWidth: 1))
        .fixedSize()
        .accessibilityElement(children: .contain)
    }
}
