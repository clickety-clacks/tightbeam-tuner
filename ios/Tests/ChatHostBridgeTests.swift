import XCTest
import WebKit
@testable import TightbeamTuner

@MainActor
final class ChatHostBridgeTests: XCTestCase {
    private let lifetime = "l_test"

    private func readyBridge(capabilities: [String: Any]? = nil) -> ChatHostBridge {
        let bridge = ChatHostBridge(chatURL: URL(string: "https://chat.example:9443/")!)
        var event: [String: Any] = [
            "event": "ready", "version": 1, "lifetimeId": lifetime, "sessionKey": "agent:test"
        ]
        if let capabilities { event["capabilities"] = capabilities }
        bridge.handle(type: "ready", event: event)
        return bridge
    }

    private func report(_ bridge: ChatHostBridge, _ type: String, _ correlationId: String, reason: String? = nil) {
        var event: [String: Any] = ["event": type, "lifetimeId": lifetime, "correlationId": correlationId, "attempt": 1]
        if let reason { event["reason"] = reason }
        bridge.handle(type: type, event: event)
    }

    private func reportReady(_ bridge: ChatHostBridge, lifetimeId: String) {
        bridge.handle(type: "ready", event: [
            "event": "ready", "version": 1, "lifetimeId": lifetimeId, "sessionKey": "agent:test"
        ])
    }

    private func command(_ bridge: ChatHostBridge, file: StaticString = #filePath, line: UInt = #line) throws -> [String: Any] {
        let json = try XCTUnwrap(bridge.lastCommandJSON, file: file, line: line)
        let data = try XCTUnwrap(json.data(using: .utf8), file: file, line: line)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any], file: file, line: line)
    }

    @MainActor private final class RecordingWebView: WKWebView {
        var reloadCount = 0

        override func reload() -> WKNavigation? {
            reloadCount += 1
            return nil
        }
    }

    func testSendIsFreeOnceAccepted() {
        let bridge = readyBridge()
        bridge.send("first")
        XCTAssertTrue(bridge.isSending)
        report(bridge, "accepted", bridge.outgoing!.correlationId)
        XCTAssertFalse(bridge.isSending)
        XCTAssertEqual(bridge.outgoing?.status, .accepted)
    }

    func testEachMessageKeepsItsOwnOutcome() {
        let bridge = readyBridge()
        bridge.send("first")
        let first = bridge.outgoing!.correlationId
        report(bridge, "accepted", first)
        bridge.send("second")
        let second = bridge.outgoing!.correlationId
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(bridge.earlier.map(\.correlationId), [first])

        report(bridge, "delivered", first)
        XCTAssertTrue(bridge.earlier.isEmpty)
        XCTAssertEqual(bridge.outgoing?.content, "second")
    }

    func testEarlierFailureComesBackForRetry() {
        let bridge = readyBridge()
        bridge.send("first")
        let first = bridge.outgoing!.correlationId
        report(bridge, "accepted", first)
        bridge.send("second")
        let second = bridge.outgoing!.correlationId

        // The latest is still sending: the earlier failure waits.
        report(bridge, "failed", first, reason: "refused")
        XCTAssertEqual(bridge.outgoing?.content, "second")

        report(bridge, "accepted", second)
        XCTAssertEqual(bridge.outgoing?.content, "first")
        XCTAssertEqual(bridge.outgoing?.status, .failed("refused"))
        XCTAssertEqual(bridge.earlier.map(\.correlationId), [second])

        // Retrying the same words keeps the earlier message's identity.
        bridge.send("first")
        XCTAssertEqual(bridge.outgoing?.correlationId, first)
    }

    func testPageEndInterruptsOutstandingMessagesWithoutOutcome() {
        let bridge = readyBridge()
        bridge.send("first")
        report(bridge, "accepted", bridge.outgoing!.correlationId)
        bridge.send("second")
        report(bridge, "accepted", bridge.outgoing!.correlationId)
        bridge.pageEnded()
        XCTAssertEqual(bridge.outgoing?.status, .interrupted)
        XCTAssertTrue(bridge.outgoing?.attempted == true)
        XCTAssertEqual(bridge.earlier.map(\.status), [.interrupted])
        XCTAssertEqual(bridge.earlier.map(\.attempted), [true])
        XCTAssertFalse(bridge.isSending)
    }

    func testPageEndAllowsUserRetryWithSameCorrelationAfterReady() throws {
        let bridge = readyBridge()
        bridge.send("hello")
        let correlationId = bridge.outgoing!.correlationId
        bridge.pageEnded()
        XCTAssertEqual(bridge.outgoing?.status, .interrupted)
        XCTAssertTrue(bridge.outgoing?.attempted == true)
        XCTAssertFalse(bridge.isSending)

        reportReady(bridge, lifetimeId: "l_next")
        XCTAssertFalse(bridge.isSending)
        bridge.send("hello")
        XCTAssertEqual(bridge.outgoing?.correlationId, correlationId)
        XCTAssertEqual(bridge.outgoing?.lifetimeId, "l_next")
        let command = try command(bridge)
        XCTAssertEqual(command["correlationId"] as? String, correlationId)
        XCTAssertEqual(command["retry"] as? Bool, true)
    }

    func testRetryAfterPageEndSetsRetryWhenChatStartedAnAttempt() throws {
        let bridge = readyBridge()
        bridge.send("hello")
        let correlationId = bridge.outgoing!.correlationId
        report(bridge, "accepted", correlationId)
        bridge.pageEnded()
        XCTAssertEqual(bridge.outgoing?.status, .interrupted)

        reportReady(bridge, lifetimeId: "l_next")
        bridge.send("hello")
        XCTAssertEqual(bridge.outgoing?.correlationId, correlationId)
        let command = try command(bridge)
        XCTAssertEqual(command["correlationId"] as? String, correlationId)
        XCTAssertEqual(command["retry"] as? Bool, true)
    }

    func testLifetimeEndedDoesNotInterruptOutstandingSend() {
        let bridge = readyBridge()
        bridge.send("hello")
        bridge.handle(type: "lifetime-ended", event: [
            "event": "lifetime-ended", "lifetimeId": lifetime
        ])
        XCTAssertEqual(bridge.outgoing?.status, .sending)
        XCTAssertFalse(bridge.isReady)
    }

    func testConnectionEventsDriveDotAndResetOnPageStart() {
        let bridge = readyBridge()
        XCTAssertEqual(bridge.connection, .connected)

        bridge.handle(type: "connection", event: [
            "event": "connection", "version": 1, "lifetimeId": lifetime, "state": "reconnecting"
        ])
        XCTAssertEqual(bridge.connection, .reconnecting)
        bridge.handle(type: "connection", event: [
            "event": "connection", "version": 1, "lifetimeId": lifetime, "state": "disconnected"
        ])
        XCTAssertEqual(bridge.connection, .disconnected)
        bridge.send("while disconnected")
        XCTAssertEqual(bridge.outgoing?.status, .sending)

        bridge.pageStarted()
        XCTAssertEqual(bridge.connection, .connecting)
        reportReady(bridge, lifetimeId: lifetime)
        XCTAssertEqual(bridge.connection, .connected)
    }

    func testNotReadyRejectionDoesNotChangePhaseOrConnection() throws {
        let bridge = readyBridge()
        bridge.handle(type: "connection", event: [
            "event": "connection", "version": 1, "lifetimeId": lifetime, "state": "reconnecting"
        ])
        bridge.send("hello")
        report(bridge, "rejected", bridge.outgoing!.correlationId, reason: "not-ready")
        XCTAssertEqual(bridge.phase, .ready(lifetimeId: lifetime, sessionKey: "agent:test"))
        XCTAssertEqual(bridge.connection, .reconnecting)
        XCTAssertTrue(bridge.isReady)
        XCTAssertEqual(bridge.outgoing?.status, .failed("not-ready"))

        let correlationId = bridge.outgoing!.correlationId
        bridge.send("hello")
        XCTAssertEqual(bridge.outgoing?.correlationId, correlationId)
        XCTAssertNil(try command(bridge)["retry"])
    }

    func testLocalCommandDoesNotReturnWordsAsFailed() {
        let bridge = readyBridge()
        bridge.send("/settings")
        report(bridge, "rejected", bridge.outgoing!.correlationId, reason: "local-command")
        XCTAssertEqual(bridge.outgoing?.status, .delivered)
        XCTAssertFalse(bridge.isSending)
    }

    func testOverlayEventsTrackDialogState() {
        let bridge = readyBridge()
        bridge.handle(type: "overlay", event: [
            "event": "overlay", "version": 1, "lifetimeId": lifetime, "open": true
        ])
        XCTAssertTrue(bridge.overlayOpen)
        bridge.handle(type: "overlay", event: [
            "event": "overlay", "version": 1, "lifetimeId": lifetime, "open": false
        ])
        XCTAssertFalse(bridge.overlayOpen)
    }

    func testReconnectCommandUsesLatestReadyWhenAdvertised() throws {
        let bridge = readyBridge(capabilities: ["text": true, "reconnect": true])
        let webView = RecordingWebView(frame: .zero, configuration: WKWebViewConfiguration())
        bridge.webView = webView

        bridge.reconnect()

        let command = try command(bridge)
        XCTAssertEqual(Set(command.keys), Set(["type", "lifetimeId", "sessionKey"]))
        XCTAssertEqual(command["type"] as? String, "reconnect")
        XCTAssertEqual(command["lifetimeId"] as? String, lifetime)
        XCTAssertEqual(command["sessionKey"] as? String, "agent:test")
        XCTAssertEqual(webView.reloadCount, 0)
    }

    func testReconnectReloadsWhenOlderChatDoesNotAdvertiseIt() {
        let bridge = readyBridge(capabilities: ["text": true])
        let webView = RecordingWebView(frame: .zero, configuration: WKWebViewConfiguration())
        bridge.webView = webView

        bridge.reconnect()

        XCTAssertEqual(webView.reloadCount, 1)
        XCTAssertNil(bridge.lastCommandJSON)
    }
}
