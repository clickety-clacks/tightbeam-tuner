import SwiftUI

/// Native message field that floats over the transcript, shaped like Chat's own composer:
/// a rounded field with the agent's name as placeholder and a round send button inside it.
struct NativeChatComposer: View {
    @Binding var draft: String
    let bridge: ChatHostBridge
    @FocusState private var focused: Bool
    @State private var showingStatus = false
    /// A comfortable line of body text, about 70 characters, plus the send button.
    /// Scales with Dynamic Type so the line length stays the same at any text size.
    @ScaledMetric(relativeTo: .body) private var maxWidth: CGFloat = 640

    // The field's ends are concentric with the send button: corner radius = button radius + gap.
    // One line of text is exactly two corner radii tall, so each end is a half circle.
    private static let gap: CGFloat = 5
    private static let buttonSize: CGFloat = 34
    private static let cornerRadius = buttonSize / 2 + gap

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
                HStack(alignment: .bottom, spacing: 0) {
                    // Connection status, the same dot Chat's own composer shows at its left.
                    Button {
                        showingStatus = true
                    } label: {
                        Circle()
                            .fill(bridge.connection.color)
                            .frame(width: 11.5, height: 11.5)
                            .frame(width: Self.buttonSize, height: Self.buttonSize)
                            .contentShape(.circle)
                    }
                    .buttonStyle(.plain)
                    .padding(Self.gap)
                    .accessibilityLabel("Connection status: \(bridge.connection.label). Show details")
                    .popover(isPresented: $showingStatus) {
                        ConnectionDetails(bridge: bridge)
                            .presentationCompactAdaptation(.popover)
                    }

                    TextField(bridge.agentName ?? "Message", text: $draft, axis: .vertical)
                        .lineLimit(1...6)
                        .foregroundStyle(Color.nordicText)
                        .focused($focused)
                        .padding(.trailing, 4)
                        .padding(.vertical, 11)
                        .accessibilityLabel("Message")

                    Button(action: send) {
                        Image(systemName: isRetry ? "arrow.clockwise" : "arrow.up")
                            .frame(width: 20, height: 20)
                    }
                        .accessibilityLabel(sendTitle)
                        .fontWeight(.semibold)
                        .foregroundStyle(Color.nordicOnAccent)
                        .tint(Color(.accent))
                        .buttonStyle(.glassProminent)
                        .buttonBorderShape(.circle)
                        // The glass style pads wider than tall and centers its circle in that
                        // width; pin the layout to the circle so the gap is the same on every side.
                        .frame(width: Self.buttonSize, height: Self.buttonSize)
                        .disabled(!canSend)
                        .padding(Self.gap)
                }
                .glassEffect(.regular.interactive(), in: .rect(cornerRadius: Self.cornerRadius, style: .continuous))
            }
        }
        .frame(maxWidth: maxWidth)
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
        .animation(.default, value: notice)
        .onChange(of: focused, initial: true) { _, focused in bridge.nativeComposerFocused = focused }
        .onDisappear { bridge.nativeComposerFocused = false }
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

extension ChatHostBridge.Connection {
    /// Chat's status colors: moss when connected, ochre while connecting, red when it cannot connect.
    var color: Color {
        switch self {
        case .connected: .nordicOk
        case .connecting, .reconnecting: .nordicCaution
        case .disconnected, .unsupported, .unauthorized: .nordicDanger
        }
    }
}

/// The details Chat's status popup shows, as far as Chat shares them with Tuner.
private struct ConnectionDetails: View {
    let bridge: ChatHostBridge

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label {
                Text(bridge.connection.label).font(.headline)
            } icon: {
                Circle().fill(bridge.connection.color).frame(width: 11.5, height: 11.5)
            }
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                row("Gateway", bridge.gatewayOrigin)
                row("Session", bridge.sessionKey)
                row("Agent", bridge.agentName)
            }
            .font(.subheadline)
        }
        .foregroundStyle(Color.nordicText)
        .padding()
        .frame(idealWidth: 320)
    }

    private func row(_ name: String, _ value: String?) -> some View {
        GridRow {
            Text(name).foregroundStyle(Color.nordicSecondaryText)
            Text(value ?? "Unavailable").textSelection(.enabled)
        }
    }
}
