import Foundation
import Observation
import WebKit

/// Tuner's side of Chat's host composer seam (version 1).
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
        /// Chat hid its composer earlier in this page and is reconnecting.
        case unavailable(lifetimeId: String)
    }

    enum Status: Equatable {
        case sending
        case accepted
        case delivered
        case failed(String)
        case uncertain(String)
    }

    /// The message the user last sent. Kept until it is delivered or replaced, so it can be retried.
    struct Outgoing: Equatable {
        let correlationId: String
        let content: String
        var lifetimeId: String
        var attempt: Int?
        var status: Status
        /// Chat started at least one attempt for this message (any later send of it is a retry).
        var attempted = false
    }

    private(set) var phase: Phase = .waiting
    private(set) var outgoing: Outgoing?
    /// True once Chat has hidden its composer in this page load (it stays hidden until the next page).
    private(set) var hostComposerActive = false
    /// The agent's display name from Chat's latest `ready`.
    private(set) var agentName: String?
    /// The gateway from Chat's latest `ready`.
    private(set) var gatewayOrigin: String?
    /// Why Chat last reported the conversation unavailable (`connecting`, `reconnecting`, ...).
    private(set) var unavailableReason: String?

    /// Chat's connection state, as its own composer's status dot shows it.
    enum Connection {
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

    var connection: Connection {
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

    init(chatURL: URL) {
        var parts = URLComponents()
        parts.scheme = chatURL.scheme
        parts.host = chatURL.host
        parts.port = chatURL.port
        allowedOrigin = parts.url?.absoluteString ?? ""
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

    var isSending: Bool {
        outgoing?.status == .sending || outgoing?.status == .accepted
    }

    // MARK: Page lifetime (host rule 2)

    /// A new main-frame page committed: wait for that page's `ready` before showing the native composer.
    func pageStarted() {
        settleUnresolved(reason: "page-replaced")
        phase = .waiting
        hostComposerActive = false
    }

    /// The page failed to load or its web content process ended.
    func pageEnded() {
        settleUnresolved(reason: "page-ended")
        phase = .waiting
        hostComposerActive = false
    }

    // MARK: Sending

    /// Sends `text` as a user action. Unchanged text after a failed or uncertain result is a retry
    /// of the same message; edited text is a new message.
    func send(_ text: String) {
        guard case let .ready(lifetimeId, sessionKey) = phase,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !isSending else { return }
        var retry = false
        var correlationId = "c_" + UUID().uuidString.lowercased()
        if let previous = outgoing, previous.content == text {
            switch previous.status {
            case .failed, .uncertain:
                correlationId = previous.correlationId
                retry = previous.attempted
            default: break
            }
        }
        outgoing = Outgoing(correlationId: correlationId, content: text, lifetimeId: lifetimeId,
                            attempt: nil, status: .sending, attempted: retry)
        var command: [String: Any] = [
            "type": "send",
            "lifetimeId": lifetimeId,
            "sessionKey": sessionKey,
            "correlationId": correlationId,
            "content": text
        ]
        if retry { command["retry"] = true }
        guard let data = try? JSONSerialization.data(withJSONObject: command),
              let json = String(data: data, encoding: .utf8) else { return }
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
    }

    /// Marks every outstanding send as uncertain; that is its one outcome (host rule 2).
    private func settleUnresolved(reason: String) {
        guard var current = outgoing, current.status == .sending || current.status == .accepted else { return }
        current.status = .uncertain(current.status == .accepted ? "accepted-unreconciled" : reason)
        outgoing = current
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
            phase = .ready(lifetimeId: lifetimeId, sessionKey: sessionKey)
            agentName = event["agentDisplayName"] as? String ?? agentName
            gatewayOrigin = event["gatewayOrigin"] as? String ?? gatewayOrigin
            unavailableReason = nil
            hostComposerActive = true
        case "unavailable":
            if let lifetimeId, case let .ready(current, _) = phase, current == lifetimeId {
                unavailableReason = event["reason"] as? String
                phase = .unavailable(lifetimeId: lifetimeId)
            }
        case "lifetime-ended":
            if hostComposerActive, let lifetimeId {
                unavailableReason = "lifetime-ended"
                phase = .unavailable(lifetimeId: lifetimeId)
            }
        case "declined":
            phase = .waiting
            hostComposerActive = false
        case "rejected":
            guard var current = matching(event), current.attempt == nil, current.status == .sending else { return }
            let reason = event["reason"] as? String ?? "rejected"
            current.status = reason == "already-delivered" ? .delivered : .failed(reason)
            outgoing = current
        case "accepted", "delivered", "failed", "uncertain":
            guard var current = matching(event) else { return }
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
            outgoing = current
        default:
            break
        }
    }

    private func matching(_ event: [String: Any]) -> Outgoing? {
        guard let current = outgoing, event["correlationId"] as? String == current.correlationId,
              event["lifetimeId"] as? String == current.lifetimeId else { return nil }
        return current
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
