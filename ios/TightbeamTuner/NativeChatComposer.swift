import SwiftUI

struct NativeChatComposer: View {
    @Binding var draft: String
    let isReady: Bool
    let isSending: Bool
    let send: () -> Void

    private var canSend: Bool {
        isReady && !isSending && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 12) {
            TextField("Message", text: $draft, axis: .vertical)
                .lineLimit(1...6)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Message")

            Button("Send", systemImage: "arrow.up", action: send)
                .buttonStyle(.borderedProminent)
                .labelStyle(.iconOnly)
                .disabled(!canSend)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }
}
