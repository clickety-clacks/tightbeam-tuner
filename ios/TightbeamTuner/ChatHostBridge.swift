import CoreFoundation
import Foundation
import Observation
import WebKit

/// Tuner's side of Chat's host composer seam (version 1).
///
/// When `ready` advertises `capabilities.attachments`, a send may carry JPEG/PNG photos as
/// `attachments: [{filename, mimeType, data}]` with base64 bytes. Non-photo files additionally
/// require `capabilities.fileAttachments == 1`. Chat prepares and uploads these bytes as it does
/// for its own composer. A retry resends the same text and ordered attachments.
///
/// Tuner also opts into Chat's optional `restore-requested` event. When the person taps Edit and
/// resend on a prompt whose turn failed, Chat hands Tuner that prompt's words (and attachments it still
/// holds); Tuner puts them in the native composer for editing and sends them only when the person
/// taps Send, as a new message.
///
/// Chat keeps its own composer until it reports `ready` for the page it is running.
/// Tuner shows its native composer only between `ready` and the end of that page or lifetime,
/// sends only to the conversation named by the latest `ready`, and never resends on its own.
@MainActor @Observable
final class ChatHostBridge: NSObject, WKScriptMessageHandler {
    // Names published in Chat's seam contract. They stay fixed within version 1.
    static let declarationName = "__TIGHTBEAM_CHAT_HOST__"
    static let commandEntryName = "__TIGHTBEAM_CHAT_COMMAND__"
    static let messageHandlerName = "tunerChatHost"

    enum Phase: Equatable {
        /// No `ready` yet for this page; Chat's own composer serves.
        case waiting
        case ready(lifetimeId: String, sessionKey: String)
        /// Chat cannot accept sends for this lifetime.
        case unavailable(lifetimeId: String)
    }

    enum Status: Equatable {
        case sending
        case accepted
        case delivered
        case failed(String)
        case uncertain(String)
        /// Its page ended before Chat reported an outcome.
        case interrupted
    }

    /// A photo or file the user added to a message. Chat prepares and uploads the bytes
    /// exactly as it does for a pick in its own composer.
    struct Attachment: Equatable, Identifiable {
        let id: UUID
        let filename: String
        let mimeType: String
        let data: Data

        init(id: UUID = UUID(), filename: String, mimeType: String, data: Data) {
            self.id = id
            self.filename = filename
            self.mimeType = mimeType
            self.data = data
        }

        /// Same bytes under the same name and type: a retry may resend it.
        func sameContent(as other: Attachment) -> Bool {
            filename == other.filename && mimeType == other.mimeType && data == other.data
        }
    }

    /// What Chat accepts from the host for the current lifetime, from `ready.capabilities.attachments`.
    /// Only limits Chat actually reports are set.
    struct AttachmentCapabilities: Equatable {
        var mediaTypes: [String]?
        var maxAttachments: Int?
        var maxAttachmentBytes: Int?
        var maxTotalBytes: Int?

        init?(_ value: Any?) {
            guard let value = value as? [String: Any] else { return nil }
            mediaTypes = value["mediaTypes"] as? [String]
            maxAttachments = value["maxAttachments"] as? Int
            maxAttachmentBytes = value["maxAttachmentBytes"] as? Int
            maxTotalBytes = value["maxTotalBytes"] as? Int
        }

        /// Photos are offered when Chat names no type list or lists JPEG or PNG.
        var acceptsPhotos: Bool {
            guard let mediaTypes else { return true }
            return mediaTypes.contains("image/jpeg") || mediaTypes.contains("image/png")
        }

        /// Chat's list, or any type when it names none.
        func accepts(_ mimeType: String) -> Bool {
            mediaTypes?.contains(mimeType) ?? true
        }

        /// Validates the complete ordered manifest before send or restore. JPEG/PNG continue to use
        /// Chat's existing photo capability; other types need the separately negotiated file
        /// capability. Limits apply to photos and files together.
        func validationFailure(for attachments: [Attachment], fileAttachmentsEnabled: Bool) -> String? {
            if let maxAttachments, attachments.count > maxAttachments { return "attachment-count-limit" }

            var totalBytes = 0
            for attachment in attachments {
                guard !attachment.filename.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      !attachment.data.isEmpty,
                      Self.isValidMIMEType(attachment.mimeType) else { return "invalid-attachment" }

                let isExistingPhoto = attachment.mimeType == "image/jpeg" || attachment.mimeType == "image/png"
                if isExistingPhoto {
                    guard accepts(attachment.mimeType) else { return "attachment-unavailable" }
                } else {
                    guard fileAttachmentsEnabled else { return "attachment-unavailable" }
                }

                if let maxAttachmentBytes, attachment.data.count > maxAttachmentBytes {
                    return "attachment-byte-limit"
                }
                let (sum, overflow) = totalBytes.addingReportingOverflow(attachment.data.count)
                guard !overflow else { return "attachment-byte-limit" }
                totalBytes = sum
            }
            if let maxTotalBytes, totalBytes > maxTotalBytes { return "attachment-byte-limit" }
            return nil
        }

        fileprivate static func isValidMIMEType(_ value: String) -> Bool {
            let parts = value.split(separator: "/", omittingEmptySubsequences: false)
            guard parts.count == 2 else { return false }
            let tokenCharacters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789!#$&^_.+-")
            return parts.allSatisfy { part in
                !part.isEmpty && part.unicodeScalars.allSatisfy(tokenCharacters.contains)
            }
        }
    }

    /// The message the user last sent, or an earlier one that did not send. Kept until it is
    /// delivered or replaced, so it can be retried.
    struct Outgoing: Equatable {
        let correlationId: String
        let sessionKey: String
        let content: String
        var attachments: [Attachment] = []
        var lifetimeId: String
        var attempt: Int?
        var status: Status
        /// Chat may have started an attempt for this message (any later send of it is a retry).
        var attempted = false
    }

    /// A failed-turn prompt Chat handed back after the person tapped Edit and resend, waiting for
    /// the composer to put it in the draft. It is never sent by itself.
    struct RestoreRequest: Equatable {
        /// Distinguishes two taps on the same prompt.
        let id = UUID()
        /// Chat's canonical row ID of the failed prompt. Its client correlation is never reused.
        let messageId: String
        let content: String
        let attachments: [Attachment]
        /// The prompt had attachments that cannot come back as a complete manifest.
        let attachmentsUnavailable: Bool
    }

    typealias OutgoingObserver = @MainActor (Outgoing) -> Void

    @ObservationIgnored private let outgoingObserver: OutgoingObserver?
    @ObservationIgnored var recoveryStateObserver: (@MainActor () -> Void)?
    @ObservationIgnored private(set) var hostModeDeclined = false

    private(set) var phase: Phase = .waiting
    private(set) var outgoing: Outgoing?
    /// The latest Edit and resend from Chat that the composer has not yet taken.
    private(set) var pendingRestore: RestoreRequest?
    /// Earlier messages Chat accepted but has not yet reported delivered, oldest first.
    /// The user can send again once a message is accepted; each message keeps its own outcome.
    private(set) var earlier: [Outgoing] = []
    /// True once Chat has hidden its composer in this page load (it stays hidden until the next page).
    private(set) var hostComposerActive = false
    /// True while Tuner's message field has the keyboard. The page then leaves focus with it.
    @ObservationIgnored var nativeComposerFocused = false
    /// The agent's display name from Chat's latest `ready`.
    private(set) var agentName: String?
    /// The gateway from Chat's latest `ready`.
    private(set) var gatewayOrigin: String?
    /// Why Chat last reported the conversation unavailable.
    private(set) var unavailableReason: String?
    private(set) var overlayOpen = false
    private(set) var lastCommandJSON: String?
    /// Set when `ready` advertises existing photo support and upload limits; nil keeps its action disabled.
    private(set) var attachmentCapabilities: AttachmentCapabilities?
    /// File support is separately negotiated and scoped to the current Chat lifetime.
    private(set) var fileAttachmentsEnabled = false
    private var reconnectSupported = false
    private var reportedConnection: Connection?
    /// True once Chat has reported `reconnecting` for `stalledReconnectDelay` without a change.
    private(set) var reconnectStalled = false
    @ObservationIgnored private var stallTask: Task<Void, Never>?
    @ObservationIgnored private let stalledReconnectDelay: Duration

    /// How long Chat may report `reconnecting` before Tuner offers Connect and lets its own
    /// recovery run, as it does for `disconnected`. Chat turns the dot yellow 1 s into an outage
    /// and, through v0.1.106, red at 10 s, so Connect appeared 9 s after yellow. Chat that keeps
    /// reporting `reconnecting` while it retries gets Connect at that same moment; older Chat turns
    /// red at that moment, so its behavior is unchanged.
    static let defaultStalledReconnectDelay: Duration = .seconds(9)

    /// Chat's connection state, as its own composer's status dot shows it.
    enum Connection: Equatable {
        case connecting, connected, reconnecting, disconnected, unsupported, unauthorized

        var label: String {
            switch self {
            case .connecting: "Connecting"
            case .connected: "Connected"
            case .reconnecting: "Reconnecting; conversation may be out of date"
            case .disconnected: "Disconnected"
            case .unsupported: "This conversation is not supported"
            case .unauthorized: "Access to this conversation is unavailable"
            }
        }
    }

    /// The state Connect and Tuner's own recovery act on. It is Chat's state, except that a
    /// stalled reconnect counts as `disconnected`. The dot and its label follow `connection`.
    var recoveryConnection: Connection {
        let connection = connection
        return connection == .reconnecting && reconnectStalled ? .disconnected : connection
    }

    /// The connection details offer Connect.
    var offersConnect: Bool { recoveryConnection.isDown }

    var connection: Connection {
        if let reportedConnection { return reportedConnection }
        switch phase {
        case .waiting: return .connecting
        case .ready: return .connected
        case .unavailable:
            switch unavailableReason {
            case "connecting": return .connecting
            case "disconnected", "lifetime-ended": return .disconnected
            case "unsupported": return .unsupported
            case "unauthorized": return .unauthorized
            default: return .reconnecting
            }
        }
    }

    var sessionKey: String? {
        if case let .ready(_, key) = phase { return key }
        return nil
    }

    private let allowedOrigin: String
    weak var webView: WKWebView?

    init(
        chatURL: URL,
        outgoingObserver: OutgoingObserver? = nil,
        stalledReconnectDelay: Duration = ChatHostBridge.defaultStalledReconnectDelay
    ) {
        self.stalledReconnectDelay = stalledReconnectDelay
        var parts = URLComponents()
        parts.scheme = chatURL.scheme
        parts.host = chatURL.host
        parts.port = chatURL.port
        allowedOrigin = parts.url?.absoluteString ?? ""
        self.outgoingObserver = outgoingObserver
    }

    /// Document-start script that declares Tuner as a host, only on the configured Chat origin.
    var declarationScript: WKUserScript {
        let origin = Self.jsonString(allowedOrigin)
        let source = """
        (() => {
          if (window.location.origin !== \(origin)) return;
          const handler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.\(Self.messageHandlerName);
          if (!handler) return;
          window.\(Self.declarationName) = Object.freeze({
            versions: [1],
            capabilities: Object.freeze({ fileAttachments: Object.freeze([1]) }),
            events: Object.freeze({ 'restore-requested': Object.freeze([1]) }),
            onEvent: (event) => handler.postMessage(JSON.stringify(event))
          });
        })();
        """
        return WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: true)
    }

    var isReady: Bool {
        if case .ready = phase { return true }
        return false
    }

    var canReconnectInPlace: Bool {
        if case .ready = phase { return reconnectSupported }
        return false
    }

    /// Chat is reconnecting and has not stalled; Tuner leaves it to its own retries.
    var isReconnectInProgress: Bool {
        reportedConnection == .reconnecting && !reconnectStalled
    }

    var phaseIsUnavailable: Bool {
        if case .unavailable = phase { return true }
        return false
    }

    /// Only a message Chat has not yet accepted holds the Send button.
    var isSending: Bool {
        outgoing?.status == .sending
    }

    /// Reconnects the live feed in place when Chat advertises support; older Chat reloads.
    func reconnect() {
        guard case let .ready(lifetimeId, sessionKey) = phase, reconnectSupported else {
            webView?.reload()
            return
        }
        let command: [String: Any] = [
            "type": "reconnect",
            "lifetimeId": lifetimeId,
            "sessionKey": sessionKey
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: command),
              let json = String(data: data, encoding: .utf8) else { return }
        lastCommandJSON = json
        webView?.evaluateJavaScript("window.\(Self.commandEntryName)(\(json))")
    }

    // MARK: Page lifetime (host rule 2)

    /// A new main-frame page committed: wait for that page's `ready` before showing the native composer.
    func pageStarted() {
        interruptUnresolved()
        phase = .waiting
        hostModeDeclined = false
        hostComposerActive = false
        resetPageState()
    }

    /// The page failed to load or its web content process ended.
    func pageEnded() {
        interruptUnresolved()
        phase = .waiting
        hostModeDeclined = false
        hostComposerActive = false
        resetPageState()
    }

    /// Keeps outstanding sends available for a user retry after the next ready.
    private func interruptUnresolved() {
        for index in earlier.indices where earlier[index].status == .accepted {
            earlier[index].status = .interrupted
            earlier[index].attempted = true
        }
        if var current = outgoing, current.status == .sending || current.status == .accepted {
            current.status = .interrupted
            current.attempted = true
            outgoing = current
        }
        surfaceEarlierProblem()
    }

    private func resetPageState() {
        unavailableReason = nil
        overlayOpen = false
        reconnectSupported = false
        fileAttachmentsEnabled = false
        reportedConnection = nil
        attachmentCapabilities = nil
        clearReconnectStall()
        pendingRestore = nil
    }

    /// The composer put `request` in the draft.
    func restoreTaken(_ request: RestoreRequest) {
        if pendingRestore?.id == request.id { pendingRestore = nil }
    }

    /// Starts timing a `reconnecting` report, or clears the stall when Chat reports anything else.
    /// Chat sends `connection` only when its state changes, so the timer runs from the first report.
    private func trackReconnectStall() {
        guard reportedConnection == .reconnecting else {
            clearReconnectStall()
            return
        }
        guard stallTask == nil, !reconnectStalled else { return }
        let delay = stalledReconnectDelay
        stallTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: delay)
            } catch {
                return
            }
            guard let self, !Task.isCancelled else { return }
            self.stallTask = nil
            guard self.reportedConnection == .reconnecting else { return }
            self.reconnectStalled = true
            self.recoveryStateObserver?()
        }
    }

    private func clearReconnectStall() {
        stallTask?.cancel()
        stallTask = nil
        reconnectStalled = false
    }

    // MARK: Sending

    /// True when `outgoing` holds this exact text and these attachments.
    static func isSameMessage(_ outgoing: Outgoing, content: String, attachments: [Attachment]) -> Bool {
        outgoing.content == content && outgoing.attachments.count == attachments.count
            && zip(outgoing.attachments, attachments).allSatisfy { $0.sameContent(as: $1) }
    }

    /// Returned words go ahead of anything typed since, so nothing is lost; words already in the
    /// draft are not added twice.
    static func draft(_ draft: String, restoring content: String) -> String {
        if content.isEmpty || draft.contains(content) { return draft }
        if draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return content }
        return content + "\n\n" + draft
    }

    /// Puts a failed-turn prompt into the draft for editing. The complete manifest goes ahead of
    /// items already in the draft, in order. Returns true when it could not be fully restored.
    static func apply(_ request: RestoreRequest, draft: inout String, attachments: inout [Attachment],
                      accepts: ([Attachment]) -> Bool) -> Bool {
        draft = Self.draft(draft, restoring: request.content)
        guard !request.attachmentsUnavailable, !request.attachments.isEmpty else {
            return request.attachmentsUnavailable
        }

        let manifest = request.attachments
        let alreadyRestored = attachments.count >= manifest.count
            && zip(attachments.prefix(manifest.count), manifest).allSatisfy { $0.sameContent(as: $1) }
        guard !alreadyRestored else { return false }
        guard accepts(manifest + attachments) else { return true }
        attachments = manifest + attachments
        return false
    }

    /// Whether Chat's current ready lifetime can accept this complete ordered manifest.
    func acceptsAttachments(_ attachments: [Attachment]) -> Bool {
        attachmentValidationFailure(for: attachments) == nil
    }

    private func attachmentValidationFailure(for attachments: [Attachment]) -> String? {
        guard !attachments.isEmpty else { return nil }
        guard let attachmentCapabilities else { return "attachment-unavailable" }
        return attachmentCapabilities.validationFailure(for: attachments,
                                                        fileAttachmentsEnabled: fileAttachmentsEnabled)
    }

    private static func supportsFileAttachments(_ value: Any?) -> Bool {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else { return false }
        return number.doubleValue == 1
    }

    /// Sends `text` and any attachments as a user action. The same text and attachments after a
    /// failed, uncertain, or interrupted result is a retry of that message; any edit is a new message.
    func send(_ text: String, attachments: [Attachment] = []) {
        guard case let .ready(lifetimeId, sessionKey) = phase, !isSending,
              !attachments.isEmpty || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        // Preserve the legacy photo-only no-op when Chat does not advertise its attachment limits.
        // A non-photo item is a new capability request and must fail visibly instead of dropping.
        if attachmentCapabilities == nil, !attachments.isEmpty,
           attachments.allSatisfy({ $0.mimeType == "image/jpeg" || $0.mimeType == "image/png" }) {
            return
        }
        let localFailure = attachmentValidationFailure(for: attachments)
        var retry = false
        var correlationId = "c_" + UUID().uuidString.lowercased()
        if let previous = outgoing, Self.isSameMessage(previous, content: text, attachments: attachments) {
            switch previous.status {
            case .failed, .uncertain, .interrupted:
                // A rejected, never-attempted local manifest is a new submission state. Give it a
                // fresh correlation so SwiftUI observes the failure and returns the draft intact.
                if localFailure == nil || previous.attempted {
                    correlationId = previous.correlationId
                    retry = previous.attempted
                }
            default: break
            }
        }
        if let previous = outgoing, previous.status == .accepted { earlier.append(previous) }
        outgoing = Outgoing(correlationId: correlationId, sessionKey: sessionKey, content: text,
                            attachments: attachments, lifetimeId: lifetimeId,
                            attempt: nil, status: localFailure.map(Status.failed) ?? .sending, attempted: retry)
        if let localFailure {
            if let outgoing { outgoingObserver?(outgoing) }
            return
        }
        var command: [String: Any] = [
            "type": "send",
            "lifetimeId": lifetimeId,
            "sessionKey": sessionKey,
            "correlationId": correlationId,
            "content": text
        ]
        if !attachments.isEmpty {
            command["attachments"] = attachments.map {
                ["filename": $0.filename, "mimeType": $0.mimeType, "data": $0.data.base64EncodedString()]
            }
        }
        if retry { command["retry"] = true }
        guard let data = try? JSONSerialization.data(withJSONObject: command),
              let json = String(data: data, encoding: .utf8) else { return }
        lastCommandJSON = json
        let script = "window.\(Self.commandEntryName)(\(json))"
        webView?.evaluateJavaScript(script) { [weak self] _, error in
            guard error != nil else { return }
            Task { @MainActor in self?.commandFailed(correlationId) }
        }
    }

    private func commandFailed(_ correlationId: String) {
        guard var current = outgoing, current.correlationId == correlationId,
              current.status == .sending, current.attempt == nil else { return }
        current.status = .failed("unreachable")
        outgoing = current
        outgoingObserver?(current)
    }

    /// An earlier message that failed or may not have sent becomes the current one, so its words
    /// come back for a retry. It waits while the latest message is still sending or itself unsent.
    private func surfaceEarlierProblem() {
        if let current = outgoing {
            switch current.status {
            case .sending, .failed, .uncertain, .interrupted: return
            case .accepted, .delivered: break
            }
        }
        guard let index = earlier.firstIndex(where: { $0.status != .accepted }) else { return }
        let problem = earlier.remove(at: index)
        if let current = outgoing, current.status == .accepted { earlier.append(current) }
        outgoing = problem
    }

    // MARK: Events from Chat

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, origin(of: message.frameInfo.securityOrigin) == allowedOrigin,
              let body = message.body as? String, let data = body.data(using: .utf8),
              let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = event["event"] as? String else { return }
        handle(type: type, event: event)
    }

    func handle(type: String, event: [String: Any]) {
        let lifetimeId = event["lifetimeId"] as? String
        switch type {
        case "ready":
            guard (event["version"] as? Int) == 1, let lifetimeId,
                  let sessionKey = event["sessionKey"] as? String else { return }
            // A repeated `ready` for the same lifetime is followed by the same `connection` state,
            // so a reconnect already being timed keeps its start.
            if currentLifetimeId != lifetimeId { clearReconnectStall() }
            reportedConnection = nil
            phase = .ready(lifetimeId: lifetimeId, sessionKey: sessionKey)
            hostModeDeclined = false
            agentName = event["agentDisplayName"] as? String ?? agentName
            gatewayOrigin = event["gatewayOrigin"] as? String ?? gatewayOrigin
            unavailableReason = nil
            let capabilities = event["capabilities"] as? [String: Any]
            reconnectSupported = capabilities?["reconnect"] as? Bool ?? false
            attachmentCapabilities = AttachmentCapabilities(capabilities?["attachments"])
            fileAttachmentsEnabled = Self.supportsFileAttachments(capabilities?["fileAttachments"])
            hostComposerActive = true
            recoveryStateObserver?()
        case "unavailable":
            if let lifetimeId, case let .ready(current, _) = phase, current == lifetimeId {
                unavailableReason = event["reason"] as? String
                phase = .unavailable(lifetimeId: lifetimeId)
                fileAttachmentsEnabled = false
                recoveryStateObserver?()
            }
        case "lifetime-ended":
            if hostComposerActive, let lifetimeId {
                unavailableReason = "lifetime-ended"
                phase = .unavailable(lifetimeId: lifetimeId)
                reconnectSupported = false
                fileAttachmentsEnabled = false
                reportedConnection = nil
                clearReconnectStall()
                recoveryStateObserver?()
            }
        case "restore-requested":
            // Only for the conversation this composer sends to now; an older lifetime's tap is dropped.
            guard (event["version"] as? Int) == 1, case let .ready(current, sessionKey) = phase,
                  lifetimeId == current, event["sessionKey"] as? String == sessionKey,
                  let messageId = event["messageId"] as? String,
                  let content = event["content"] as? String else { return }
            let rawItems = event["attachments"]
            let parsedItems = rawItems as? [[String: Any]]
            let items = parsedItems ?? []
            let manifest = items.compactMap { item -> Attachment? in
                guard let filename = item["filename"] as? String, let mimeType = item["mimeType"] as? String,
                      let base64 = item["data"] as? String, let data = Data(base64Encoded: base64),
                      data.base64EncodedString() == base64,
                      !filename.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      !data.isEmpty,
                      AttachmentCapabilities.isValidMIMEType(mimeType) else { return nil }
                return Attachment(filename: filename, mimeType: mimeType, data: data)
            }
            let explicitlyUnavailable = event["attachmentsUnavailable"] as? Bool == true
            let malformedContainer = rawItems != nil && parsedItems == nil
            let invalidManifest = malformedContainer || manifest.count != items.count
                || (!items.isEmpty && attachmentValidationFailure(for: manifest) != nil)
            let attachmentsUnavailable = explicitlyUnavailable || invalidManifest
            pendingRestore = RestoreRequest(
                messageId: messageId, content: content,
                attachments: attachmentsUnavailable ? [] : manifest,
                attachmentsUnavailable: attachmentsUnavailable)
            // Chat holds a canonical row for this prompt, so a copy Tuner still keeps for retry was
            // delivered. Retiring it makes the next Send a new message instead of a retry of the failed prompt.
            if let sent = event["correlationId"] as? String {
                earlier.removeAll { $0.correlationId == sent }
                if var current = outgoing, current.correlationId == sent, current.status != .delivered {
                    current.status = .delivered
                    outgoing = current
                }
            }
        case "declined":
            phase = .waiting
            hostModeDeclined = true
            hostComposerActive = false
            resetPageState()
            recoveryStateObserver?()
        case "connection":
            guard (event["version"] as? Int) == 1, let lifetimeId,
                  lifetimeId == currentLifetimeId else { return }
            switch event["state"] as? String {
            case "connected": reportedConnection = .connected
            case "reconnecting": reportedConnection = .reconnecting
            case "disconnected": reportedConnection = .disconnected
            default: break
            }
            if reportedConnection != nil {
                trackReconnectStall()
                recoveryStateObserver?()
            }
        case "overlay":
            guard (event["version"] as? Int) == 1, let lifetimeId,
                  lifetimeId == currentLifetimeId, let open = event["open"] as? Bool else { return }
            overlayOpen = open
        case "rejected":
            guard var current = matching(event), current.attempt == nil, current.status == .sending else { return }
            let reason = event["reason"] as? String ?? "rejected"
            current.status = reason == "already-delivered" || reason == "local-command" ? .delivered : .failed(reason)
            outgoing = current
            outgoingObserver?(current)
        case "accepted", "delivered", "failed", "uncertain":
            if let index = earlier.firstIndex(where: { matches($0, event) }) {
                var message = earlier[index]
                Self.apply(type: type, event: event, to: &message)
                if message.status == .delivered { earlier.remove(at: index) } else { earlier[index] = message }
                outgoingObserver?(message)
                surfaceEarlierProblem()
                return
            }
            guard var current = matching(event) else { return }
            Self.apply(type: type, event: event, to: &current)
            outgoing = current
            outgoingObserver?(current)
            surfaceEarlierProblem()
        default:
            break
        }
    }

    private static func apply(type: String, event: [String: Any], to current: inout Outgoing) {
        let attempt = event["attempt"] as? Int
        if let attempt, let seen = current.attempt, attempt < seen { return }
        current.attempt = attempt ?? current.attempt
        current.attempted = true
        let reason = event["reason"] as? String ?? type
        switch type {
        case "accepted": if current.status == .sending { current.status = .accepted }
        case "delivered": current.status = .delivered
        case "failed": current.status = .failed(reason)
        default: current.status = .uncertain(reason)
        }
    }

    private func matches(_ message: Outgoing, _ event: [String: Any]) -> Bool {
        event["correlationId"] as? String == message.correlationId
            && event["lifetimeId"] as? String == message.lifetimeId
    }

    private func matching(_ event: [String: Any]) -> Outgoing? {
        guard let current = outgoing, matches(current, event) else { return nil }
        return current
    }

    private var currentLifetimeId: String? {
        switch phase {
        case .waiting: nil
        case let .ready(lifetimeId, _): lifetimeId
        case let .unavailable(lifetimeId): unavailableReason == "lifetime-ended" ? nil : lifetimeId
        }
    }

    private func origin(of origin: WKSecurityOrigin) -> String {
        var parts = URLComponents()
        parts.scheme = origin.protocol
        parts.host = origin.host
        parts.port = origin.port == 0 ? nil : origin.port
        return parts.url?.absoluteString ?? ""
    }

    private static func jsonString(_ value: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [value]),
              let array = String(data: data, encoding: .utf8) else { return "\"\"" }
        return String(array.dropFirst().dropLast())
    }
}
