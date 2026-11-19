import ImageIO
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// Native message field inset at the selected transcript edge, shaped like Chat's own composer:
/// a rounded field with the agent's name as placeholder and a separate send button beside it.
/// An add button beside the status dot offers Paste, Photo Library and Camera when Chat accepts
/// attachments, and is greyed out when it does not. Photos wait above the field until they are sent.
struct NativeChatComposer: View {
    @Binding var draft: String
    @Binding var attachments: [ChatHostBridge.Attachment]
    let bridge: ChatHostBridge
    let glassHeight: CGFloat?
    let focusOnAppear: Bool
    let onFocusChange: (Bool) -> Void
    @FocusState private var focused: Bool
    @State private var showingStatus = false
    @State private var showingLibrary = false
    @State private var showingCamera = false
    @State private var libraryPicks: [PhotosPickerItem] = []
    @State private var loadingPhotos = 0
    @State private var attachmentProblem: String?
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
    // A 34 pt status button with 7 pt above and below yields a 48 pt one-line row.
    private static let standardVerticalGap: CGFloat = 7
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
        attachments: Binding<[ChatHostBridge.Attachment]>,
        bridge: ChatHostBridge,
        glassHeight: CGFloat?,
        focusOnAppear: Bool = false,
        onFocusChange: @escaping (Bool) -> Void
    ) {
        _draft = draft
        _attachments = attachments
        self.bridge = bridge
        self.glassHeight = glassHeight
        self.focusOnAppear = focusOnAppear
        self.onFocusChange = onFocusChange
    }

    private var trimmed: String { draft.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var canSend: Bool {
        guard bridge.isReady, !bridge.isSending, loadingPhotos == 0 else { return false }
        // Photos go only to a Chat that accepts them; otherwise Send waits rather than dropping them.
        if !attachments.isEmpty { return bridge.attachmentCapabilities != nil }
        return !trimmed.isEmpty
    }

    private var offersPhotos: Bool { bridge.attachmentCapabilities?.acceptsPhotos ?? false }

    /// How many more photos Chat accepts in this message; nil when Chat sets no count.
    private var remainingAttachments: Int? {
        guard let limit = bridge.attachmentCapabilities?.maxAttachments else { return nil }
        return max(0, limit - attachments.count - loadingPhotos)
    }

    /// The add button always shows; it is greyed out and disabled while Chat takes no photos or the
    /// message already holds as many as Chat accepts.
    private var canAddAttachment: Bool { offersPhotos && (remainingAttachments.map { $0 > 0 } ?? true) }

    var body: some View {
        GlassEffectContainer(spacing: Self.glassMergeSpacing) {
            VStack(alignment: .leading, spacing: 8) {
                if !attachments.isEmpty || loadingPhotos > 0 {
                    DraftAttachmentStrip(attachments: $attachments, loading: loadingPhotos)
                }
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

                        addAttachmentMenu
                            .padding(.vertical, statusVerticalGap)

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
        .onChange(of: attachments) { attachmentProblem = nil }
        .onChange(of: draft) { attachmentProblem = nil }
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
        .photosPicker(isPresented: $showingLibrary, selection: $libraryPicks,
                      maxSelectionCount: remainingAttachments, selectionBehavior: .ordered,
                      matching: .images, preferredItemEncoding: .compatible)
        .onChange(of: libraryPicks) { _, picks in
            guard !picks.isEmpty else { return }
            libraryPicks = []
            addLibraryPhotos(picks)
        }
        .fullScreenCover(isPresented: $showingCamera) {
            CameraCapture { image in
                showingCamera = false
                guard let image else { return }
                if !add(PhotoAttachment.fromCamera(image)) { attachmentProblem = "Could not add the photo" }
            }
            .ignoresSafeArea()
        }
        .onChange(of: bridge.outgoing) { _, outgoing in
            guard let outgoing else { return }
            switch outgoing.status {
            case .failed, .uncertain, .interrupted: restoreDraft(outgoing)
            default: break
            }
        }
    }

    private var addAttachmentMenu: some View {
        Menu {
            Button("Paste", systemImage: "doc.on.clipboard", action: pastePhoto)
            Button("Photo Library", systemImage: "photo.on.rectangle") { showingLibrary = true }
            Button("Camera", systemImage: "camera") { showingCamera = true }
                .disabled(!UIImagePickerController.isSourceTypeAvailable(.camera))
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(canAddAttachment ? Color.nordicText : Color.nordicSecondaryText.opacity(0.5))
                .frame(width: Self.statusButtonSize, height: Self.statusButtonSize)
                .contentShape(.circle)
        }
        .disabled(!canAddAttachment)
        .accessibilityLabel("Add attachment")
    }

    /// Adds a photo Chat accepts; false when there is none or Chat does not take its type.
    private func add(_ attachment: ChatHostBridge.Attachment?) -> Bool {
        guard let attachment, bridge.attachmentCapabilities?.accepts(attachment.mimeType) == true else { return false }
        attachments.append(attachment)
        return true
    }

    private func pastePhoto() {
        let pasteboard = UIPasteboard.general
        if !add(pasteboard.hasImages ? PhotoAttachment.fromPasteboard(pasteboard) : nil) {
            attachmentProblem = "No photo to paste"
        }
    }

    private func addLibraryPhotos(_ picks: [PhotosPickerItem]) {
        let picks = remainingAttachments.map { Array(picks.prefix($0)) } ?? picks
        loadingPhotos += picks.count
        Task { @MainActor in
            var failed = 0
            for item in picks {
                // The compatible encoding gives JPEG for HEIC photos, as Safari's photo picker does.
                let data = try? await item.loadTransferable(type: Data.self)
                if !add(data.flatMap(PhotoAttachment.fromLibrary)) { failed += 1 }
                loadingPhotos -= 1
            }
            if failed > 0 { attachmentProblem = failed == 1 ? "Could not add a photo" : "Could not add \(failed) photos" }
        }
    }

    private var isRetry: Bool {
        guard let outgoing = bridge.outgoing,
              ChatHostBridge.isSameMessage(outgoing, content: draft, attachments: attachments) else { return false }
        switch outgoing.status {
        case .failed, .uncertain, .interrupted: return true
        default: return false
        }
    }

    private var sendTitle: String { isRetry ? "Retry" : "Send" }

    private var notice: String? {
        if let attachmentProblem { return attachmentProblem }
        guard let outgoing = bridge.outgoing,
              outgoing.content.isEmpty || outgoing.content == draft || draft.hasPrefix(outgoing.content + "\n\n"),
              outgoing.attachments.allSatisfy({ sent in attachments.contains { $0.id == sent.id } }) else { return nil }
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
        let missing = outgoing.attachments.filter { sent in !attachments.contains { $0.id == sent.id } }
        attachments = missing + attachments
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
        let files = attachments
        draft = ""
        attachments = []
        attachmentProblem = nil
        bridge.send(text, attachments: files)
    }
}

extension ChatHostBridge.Connection {
    /// Red: Chat cannot reach the conversation. The dot's details then offer Connect, as they
    /// also do once a reconnect has stalled (`ChatHostBridge.offersConnect`).
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
            if bridge.offersConnect {
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

/// Photos waiting to be sent with the message, each removable before Send.
private struct DraftAttachmentStrip: View {
    @Binding var attachments: [ChatHostBridge.Attachment]
    let loading: Int

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(attachments) { attachment in
                    DraftAttachmentThumbnail(attachment: attachment) {
                        attachments.removeAll { $0.id == attachment.id }
                    }
                }
                ForEach(0..<loading, id: \.self) { _ in
                    ProgressView()
                        .frame(width: DraftAttachmentThumbnail.size, height: DraftAttachmentThumbnail.size)
                        .accessibilityLabel("Adding photo")
                }
            }
            .padding(8)
        }
        .scrollIndicators(.hidden)
        .fixedSize(horizontal: false, vertical: true)
        .glassEffect(.regular, in: .rect(cornerRadius: 20, style: .continuous))
        .accessibilityLabel("Attachments in this draft")
    }
}

private struct DraftAttachmentThumbnail: View {
    static let size: CGFloat = 56
    let attachment: ChatHostBridge.Attachment
    let remove: () -> Void
    @State private var image: UIImage?
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if let image {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    Color.nordicSecondaryText.opacity(0.15)
                }
            }
            .frame(width: Self.size, height: Self.size)
            .clipShape(.rect(cornerRadius: 12, style: .continuous))

            Button(action: remove) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 20))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(Color.white, Color.black.opacity(0.6))
            }
            .buttonStyle(.plain)
            .offset(x: 6, y: -6)
            .accessibilityLabel("Remove \(attachment.filename)")
        }
        .padding(.top, 6)
        .padding(.trailing, 6)
        .task(id: attachment.id) {
            let data = attachment.data
            let side = Self.size * displayScale
            image = await Task.detached {
                UIImage(data: data)?.preparingThumbnail(of: CGSize(width: side, height: side))
            }.value
        }
    }
}

/// Turns a photo from the library, camera or pasteboard into the JPEG or PNG bytes Tuner hands to
/// Chat. Chat then prepares them exactly as it does a photo picked in its own composer.
enum PhotoAttachment {
    static func fromLibrary(_ data: Data) -> ChatHostBridge.Attachment? {
        encoded(data, name: "photo")
    }

    static func fromCamera(_ image: UIImage) -> ChatHostBridge.Attachment? {
        guard let data = image.jpegData(compressionQuality: 0.9) else { return nil }
        return ChatHostBridge.Attachment(filename: filename("camera", "jpg"), mimeType: "image/jpeg", data: data)
    }

    static func fromPasteboard(_ pasteboard: UIPasteboard) -> ChatHostBridge.Attachment? {
        for type in [UTType.png, UTType.jpeg, UTType.heic, UTType.image] {
            if let data = pasteboard.data(forPasteboardType: type.identifier), let attachment = encoded(data, name: "pasted-image") {
                return attachment
            }
        }
        guard let image = pasteboard.image, let data = image.pngData() else { return nil }
        return ChatHostBridge.Attachment(filename: filename("pasted-image", "png"), mimeType: "image/png", data: data)
    }

    /// JPEG and PNG pass through unchanged; any other image format is re-encoded as JPEG,
    /// keeping its orientation.
    static func encoded(_ data: Data, name: String) -> ChatHostBridge.Attachment? {
        if data.starts(with: [0xFF, 0xD8, 0xFF]) {
            return ChatHostBridge.Attachment(filename: filename(name, "jpg"), mimeType: "image/jpeg", data: data)
        }
        if data.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) {
            return ChatHostBridge.Attachment(filename: filename(name, "png"), mimeType: "image/png", data: data)
        }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) > 0 else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImageFromSource(destination, source, 0,
                                             [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return ChatHostBridge.Attachment(filename: filename(name, "jpg"), mimeType: "image/jpeg", data: output as Data)
    }

    private static func filename(_ name: String, _ ext: String) -> String {
        "\(name)-\(Int(Date().timeIntervalSince1970 * 1000)).\(ext)"
    }
}

/// The system camera, returning the captured photo or nil when the user cancels.
private struct CameraCapture: UIViewControllerRepresentable {
    let finish: (UIImage?) -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.cameraCaptureMode = .photo
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(finish: finish) }

    @MainActor final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let finish: (UIImage?) -> Void
        init(finish: @escaping (UIImage?) -> Void) { self.finish = finish }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            finish(info[.originalImage] as? UIImage)
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { finish(nil) }
    }
}
