import SwiftUI

/// Native message field inset at the selected transcript edge, shaped like Chat's own composer:
/// a rounded field with the agent's name as placeholder and a separate send button beside it.
struct NativeChatComposer: View {
    @Binding var draft: String
    let bridge: ChatHostBridge
    let glassHeight: CGFloat?
    let focusOnAppear: Bool
    let onFocusChange: (Bool) -> Void
    @FocusState private var focused: Bool
    @State private var showingStatus = false
    /// A comfortable line of body text, about 70 characters, plus the send button.
    /// Scales with Dynamic Type so the line length stays the same at any text size.
    @ScaledMetric(relativeTo: .body) private var maxWidth: CGFloat = 640

    // Compact Filter search is 38 pt tall. The backing UIKit text field can report taller bounds,
    // so use the visible capsule measurement for the composer instead of those transformed bounds.
    static let compactSearchHeight: CGFloat = 38
    private static let horizontalGap: CGFloat = 5
    // Keep adjacent glass shapes separate; the visible gap beside Send is 5 pt.
    private static let glassMergeSpacing: CGFloat = 4
    private static let statusButtonSize: CGFloat = 34
    // The glass button's natural circle around the 20 pt icon is 34 pt.
    private static let sendButtonBaseCircleSize: CGFloat = 34
    private static let standardVerticalGap: CGFloat = 5
    private static let standardContentHeight = statusButtonSize + 2 * standardVerticalGap
    private var matchesCompactSearchHeight: Bool {
        (glassHeight ?? Self.standardContentHeight) < Self.standardContentHeight
    }
    private var contentHeight: CGFloat {
        max(Self.standardContentHeight, glassHeight ?? Self.standardContentHeight)
    }
    private var statusVerticalGap: CGFloat {
        max(Self.standardVerticalGap, (contentHeight - Self.statusButtonSize) / 2)
    }
    private var sendLabelPadding: CGFloat {
        max(0, (contentHeight - Self.sendButtonBaseCircleSize) / 2)
    }
    private var textFieldVerticalPadding: CGFloat {
        guard matchesCompactSearchHeight else { return 11 }
        return 3
    }
    private var glassVerticalInset: CGFloat {
        max(0, ((glassHeight ?? contentHeight) - contentHeight) / 2)
    }
    private var cornerRadius: CGFloat { contentHeight / 2 + glassVerticalInset }
    init(
        draft: Binding<String>,
        bridge: ChatHostBridge,
        glassHeight: CGFloat?,
        focusOnAppear: Bool = false,
        onFocusChange: @escaping (Bool) -> Void
    ) {
        _draft = draft
        self.bridge = bridge
        self.glassHeight = glassHeight
        self.focusOnAppear = focusOnAppear
        self.onFocusChange = onFocusChange
    }

    private var trimmed: String { draft.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var canSend: Bool {
        bridge.isReady && !bridge.isSending && !trimmed.isEmpty
    }

    var body: some View {
        GlassEffectContainer(spacing: Self.glassMergeSpacing) {
            VStack(alignment: .leading, spacing: 8) {
                if let notice {
                    Label(notice, systemImage: "exclamationmark.circle")
                        .font(TunerTypography.supporting)
                        .foregroundStyle(Color.chatDanger)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .glassEffect(.regular, in: .capsule)
                        .transition(.opacity)
                }
                HStack(alignment: .bottom, spacing: Self.horizontalGap) {
                    HStack(alignment: .bottom, spacing: 0) {
                        // Connection status, the same dot Chat's own composer shows at its left.
                        Button {
                            showingStatus = true
                        } label: {
                            Circle()
                                .fill(bridge.connection.color)
                                .frame(width: 11.5, height: 11.5)
                                .frame(width: Self.statusButtonSize, height: Self.statusButtonSize)
                                .contentShape(.circle)
                        }
                        .buttonStyle(.plain)
                        // Keep the status dot centered as before; its trailing inset is now the
                        // external 5 pt gap before Send, preserving the text field's usable width.
                        .padding(.leading, Self.horizontalGap)
                        .padding(.vertical, statusVerticalGap)
                        .accessibilityLabel("Connection status: \(bridge.connection.label). Show details")
                        .popover(isPresented: $showingStatus) {
                            ConnectionDetails(bridge: bridge) { showingStatus = false }
                                .presentationCompactAdaptation(.popover)
                        }

                        TextField(bridge.agentName ?? "Message", text: $draft, axis: .vertical)
                            .lineLimit(1...6)
                            .foregroundStyle(Color.nordicText)
                            .focused($focused)
                            .padding(.trailing, 4)
                            .padding(.vertical, textFieldVerticalPadding)
                            .frame(minHeight: contentHeight, alignment: .center)
                            .accessibilityLabel("Message")
                    }
                    .padding(.vertical, glassVerticalInset)
                    .glassEffect(.regular.interactive(), in: .rect(cornerRadius: cornerRadius, style: .continuous))

                    // Size the label so the glass style draws its circle at contentHeight.
                    Button(action: send) {
                        Image(systemName: isRetry ? "arrow.clockwise" : "arrow.up")
                            .frame(width: 20, height: 20)
                            .padding(sendLabelPadding)
                    }
                        .accessibilityLabel(sendTitle)
                        .fontWeight(.semibold)
                        .foregroundStyle(canSend ? Color.chatOnAccent : Color.nordicSecondaryText)
                        // Grey whenever a tap would not send, so Send never looks available when it is not.
                        .tint(canSend ? Color.chatAccent : Color.nordicSecondaryText.opacity(0.25))
                        .buttonStyle(.glassProminent)
                        .buttonBorderShape(.circle)
                        // The glass style pads wider than tall and centers its circle in that
                        // width; pin the layout to the circle so the gap is the same on every side.
                        .frame(width: contentHeight, height: contentHeight)
                        .disabled(!canSend)
                        .contentShape(Rectangle())
                }
            }
        }
        .frame(maxWidth: maxWidth)
        .padding(.horizontal, 12)
        .tint(Color.chatAccent)
        .animation(.default, value: notice)
        .onChange(of: focused, initial: true) { _, focused in
            bridge.nativeComposerFocused = focused
            onFocusChange(focused)
        }
        .onAppear {
            if focusOnAppear { focused = true }
            if let outgoing = bridge.outgoing, outgoing.status == .interrupted { restoreDraft(outgoing) }
            if bridge.overlayOpen { focusChatPage() }
        }
        .onDisappear {
            bridge.nativeComposerFocused = false
            onFocusChange(false)
        }
        .onChange(of: bridge.overlayOpen) { _, open in
            if open {
                focusChatPage()
            } else {
                focused = true
            }
        }
        .onChange(of: bridge.outgoing) { _, outgoing in
            guard let outgoing else { return }
            switch outgoing.status {
            case .failed, .uncertain, .interrupted: restoreDraft(outgoing)
            default: break
            }
        }
    }

    private var isRetry: Bool {
        guard let outgoing = bridge.outgoing, outgoing.content == draft else { return false }
        switch outgoing.status {
        case .failed, .uncertain, .interrupted: return true
        default: return false
        }
    }

    private var sendTitle: String { isRetry ? "Retry" : "Send" }

    private var notice: String? {
        guard let outgoing = bridge.outgoing,
              outgoing.content == draft || draft.hasPrefix(outgoing.content + "\n\n") else { return nil }
        switch outgoing.status {
        case .failed: return "Not sent"
        default: return nil
        }
    }

    private func restoreDraft(_ outgoing: ChatHostBridge.Outgoing) {
        // Give the words back so the user can retry or edit them, ahead of anything
        // typed since, so nothing is lost.
        if trimmed.isEmpty { draft = outgoing.content }
        else if !draft.contains(outgoing.content) { draft = outgoing.content + "\n\n" + draft }
    }

    private func focusChatPage() {
        focused = false
        Task { @MainActor in
            await Task.yield()
            _ = bridge.webView?.becomeFirstResponder()
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
    /// Red: Chat cannot reach the conversation. The dot's details then offer Connect.
    var isDown: Bool {
        switch self {
        case .disconnected, .unsupported, .unauthorized: true
        case .connecting, .connected, .reconnecting: false
        }
    }

    /// Chat's status colors: moss when connected, ochre while connecting, red when it cannot connect.
    var color: Color {
        switch self {
        case .connected: .chatOk
        case .connecting, .reconnecting: .chatCaution
        case .disconnected, .unsupported, .unauthorized: .chatDanger
        }
    }
}

/// The details Chat's status popup shows, as far as Chat shares them with Tuner.
private struct ConnectionDetails: View {
    let bridge: ChatHostBridge
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label {
                Text(bridge.connection.label).font(TunerTypography.title)
            } icon: {
                Circle().fill(bridge.connection.color).frame(width: 11.5, height: 11.5)
            }
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                row("Gateway", bridge.gatewayOrigin)
                row("Session", bridge.sessionKey)
                row("Agent", bridge.agentName)
            }
            .font(TunerTypography.compactBody)
            if bridge.connection.isDown {
                Button("Connect", systemImage: "arrow.clockwise") {
                    dismiss()
                    bridge.reconnect()
                }
                .buttonStyle(.glassProminent)
                .tint(Color.chatAccent)
            }
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
