import SwiftUI

struct NativeChatComposer: View {
    @Binding var draft: String
    let bridge: ChatHostBridge
    @FocusState private var focused: Bool

    private var trimmed: String { draft.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var canSend: Bool {
        bridge.isReady && !bridge.isSending && !trimmed.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let notice {
                Label(notice, systemImage: "exclamationmark.circle")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            HStack(alignment: .bottom, spacing: 12) {
                TextField("Message", text: $draft, axis: .vertical)
                    .lineLimit(1...6)
                    .textFieldStyle(.roundedBorder)
                    .focused($focused)
                    .submitLabel(.send)
                    .accessibilityLabel("Message")

                Button(sendTitle, systemImage: isRetry ? "arrow.clockwise" : "arrow.up", action: send)
                    .buttonStyle(.borderedProminent)
                    .labelStyle(.iconOnly)
                    .disabled(!canSend)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
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
