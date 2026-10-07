import SwiftUI

/// A focused command composer that never starts a terminal command during generation.
struct TerminalAICommandEntryView: View {
    @ObservedObject var model: TerminalAIModel
    var onOpenConversation: () -> Void
    var onClose: () -> Void
    @FocusState private var inputFocused: Bool
    @State private var commandDraft = ""

    private var busy: Bool { model.commandEntryBusy || model.isRunning || model.contextLoading }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Write a command", systemImage: "terminal")
                    .font(.headline)
                Spacer()
                Button(action: onClose) { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Close command entry")
            }
            Text("Describe what you need. Review the command before putting it in your terminal.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("Target: \(model.terminalIdentity["host"] as? String ?? "unknown") · \(model.terminalIdentity["directory"] as? String ?? model.terminalDirectory)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .textSelection(.enabled)
            HStack(spacing: 8) {
                TextField("For example: show the processes using the most CPU", text: $model.commandRequestDraft)
                    .textFieldStyle(.roundedBorder)
                    .focused($inputFocused)
                    .disabled(busy)
                    .onSubmit(generate)
                    .accessibilityLabel("Describe a command")
                Button("Generate", action: generate)
                    .disabled(busy || model.commandRequestDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if model.contextLoading {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Loading project context…").font(.caption)
                    Spacer()
                    Button("Cancel context load", action: model.stop)
                }
            } else if model.commandEntryBusy {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Writing your command…").font(.caption)
                }
            } else if model.isRunning {
                Text("Finish the current AI task before generating another command.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let error = model.commandEntryError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
            if !model.commandEntryCommand.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Suggested command").font(.caption).foregroundStyle(.secondary)
                    TextEditor(text: $commandDraft)
                        .font(.system(.body, design: .monospaced))
                        .frame(height: 60)
                        .scrollContentBackground(.hidden)
                        .padding(5)
                        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 5))
                        .accessibilityLabel("Edit generated command")
                    if !model.commandEntryExplanation.isEmpty {
                        Text(model.commandEntryExplanation)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    HStack {
                        Button("Fill terminal") {
                            model.fillSuggestedCommand(commandDraft)
                        }
                        .disabled(busy || commandDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        Button("Review & run") {
                            model.runSuggestedCommand(commandDraft)
                            onOpenConversation()
                        }
                        .disabled(busy || commandDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        Spacer()
                        Button("Open conversation", action: onOpenConversation)
                    }
                }
            }
        }
        .padding(16)
        .frame(width: 520)
        .onAppear {
            commandDraft = model.commandEntryCommand
            inputFocused = true
        }
        .onChange(of: model.commandEntryCommand) { commandDraft = $0 }
        .onExitCommand(perform: onClose)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("AI command entry")
    }

    private func generate() {
        guard !busy, !model.commandRequestDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        model.generateCommand()
    }
}
