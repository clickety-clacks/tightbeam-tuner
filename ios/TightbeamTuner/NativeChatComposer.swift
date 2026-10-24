import SwiftUI

/// Native message field that floats over the transcript, shaped like Chat's own composer:
/// a rounded field with the agent's name as placeholder and a round send button inside it.
struct NativeChatComposer: View {
    @Binding var draft: String
    let bridge: ChatHostBridge
    @FocusState private var focused: Bool

    private var trimmed: String { draft.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var canSend: Bool {
        bridge.isReady && !bridge.isSending && !trimmed.isEmpty
    }

    var body: some View {
        GlassEffectContainer(spacing: 8) {
            VStack(alignment: .leading, spacing: 8) {
                if let notice {
                    Label(notice, systemImage: "exclamationmark.circle")
                        .font(.footnote)
                        .foregroundStyle(Color.nordicText)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .glassEffect(.regular, in: .capsule)
                        .transition(.opacity)
                }
                HStack(alignment: .bottom, spacing: 4) {
                    TextField(bridge.agentName ?? "Message", text: $draft, axis: .vertical)
                        .lineLimit(1...6)
                        .foregroundStyle(Color.nordicText)
                        .focused($focused)
                        .submitLabel(.send)
                        .padding(.leading, 16)
                        .padding(.vertical, 11)
                        .accessibilityLabel("Message")

                    Button(sendTitle, systemImage: isRetry ? "arrow.clockwise" : "arrow.up", action: send)
                        .labelStyle(.iconOnly)
                        .fontWeight(.semibold)
                        .foregroundStyle(Color.nordicOnAccent)
                        .tint(Color(.accent))
                        .buttonStyle(.glassProminent)
                        .buttonBorderShape(.circle)
                        .disabled(!canSend)
                        .padding(5)
                }
                .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 22, style: .continuous))
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
        .animation(.default, value: notice)
        .onChange(of: bridge.outgoing) { _, outgoing in
            guard let outgoing else { return }
            switch outgoing.status {
            case .failed, .uncertain:
                // Give the words back so the user can retry or edit them.
                if trimmed.isEmpty { draft = outgoing.content }
            default: break
            }
        }
    }

    private var isRetry: Bool {
        guard let outgoing = bridge.outgoing, outgoing.content == draft else { return false }
        switch outgoing.status {
        case .failed, .uncertain: return true
        default: return false
        }
    }

    private var sendTitle: String { isRetry ? "Retry" : "Send" }

    private var notice: String? {
        if case .unavailable = bridge.phase { return "Reconnecting…" }
        guard let outgoing = bridge.outgoing, outgoing.content == draft else { return nil }
        switch outgoing.status {
        case .failed: return "Not sent"
        case .uncertain: return "May not have sent"
        default: return nil
        }
    }

    private func send() {
        guard canSend else { return }
        let text = draft
        draft = ""
        bridge.send(text)
    }
}
