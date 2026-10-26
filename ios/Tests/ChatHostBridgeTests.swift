import XCTest
@testable import TightbeamTuner

@MainActor
final class ChatHostBridgeTests: XCTestCase {
    private let lifetime = "l_test"

    private func readyBridge() -> ChatHostBridge {
        let bridge = ChatHostBridge(chatURL: URL(string: "https://chat.example:9443/")!)
        bridge.handle(type: "ready", event: [
            "event": "ready", "version": 1, "lifetimeId": lifetime, "sessionKey": "agent:test"
        ])
        return bridge
    }

    private func report(_ bridge: ChatHostBridge, _ type: String, _ correlationId: String, reason: String? = nil) {
        var event: [String: Any] = ["event": type, "lifetimeId": lifetime, "correlationId": correlationId, "attempt": 1]
        if let reason { event["reason"] = reason }
        bridge.handle(type: type, event: event)
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
        report(bridge, "failed", first, reason: "timeout")
        XCTAssertEqual(bridge.outgoing?.content, "second")

        report(bridge, "accepted", second)
        XCTAssertEqual(bridge.outgoing?.content, "first")
        XCTAssertEqual(bridge.outgoing?.status, .failed("timeout"))
        XCTAssertEqual(bridge.earlier.map(\.correlationId), [second])

        // Retrying the same words keeps the earlier message's identity.
        bridge.send("first")
        XCTAssertEqual(bridge.outgoing?.correlationId, first)
    }

    func testPageEndLeavesEveryAcceptedMessageUncertain() {
        let bridge = readyBridge()
        bridge.send("first")
        report(bridge, "accepted", bridge.outgoing!.correlationId)
        bridge.send("second")
        report(bridge, "accepted", bridge.outgoing!.correlationId)
        bridge.pageEnded()
        XCTAssertEqual(bridge.outgoing?.status, .uncertain("accepted-unreconciled"))
        XCTAssertEqual(bridge.earlier.map(\.status), [.uncertain("accepted-unreconciled")])
    }
}
