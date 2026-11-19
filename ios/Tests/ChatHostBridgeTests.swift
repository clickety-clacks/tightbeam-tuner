import ImageIO
import JavaScriptCore
import UIKit
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

    func testRecoveryObserverTracksUnavailableConnectionAndRestoredReadyState() {
        let bridge = readyBridge()
        var updates = 0
        bridge.recoveryStateObserver = { updates += 1 }

        bridge.handle(type: "unavailable", event: [
            "event": "unavailable", "lifetimeId": lifetime, "reason": "disconnected"
        ])
        XCTAssertTrue(bridge.phaseIsUnavailable)
        XCTAssertEqual(updates, 1)

        reportReady(bridge, lifetimeId: lifetime)
        XCTAssertFalse(bridge.phaseIsUnavailable)
        XCTAssertEqual(updates, 2)

        bridge.handle(type: "connection", event: [
            "event": "connection", "version": 1, "lifetimeId": lifetime, "state": "disconnected"
        ])
        XCTAssertEqual(bridge.connection, .disconnected)
        XCTAssertEqual(updates, 3)
    }

    private func reportConnection(_ bridge: ChatHostBridge, _ state: String, lifetimeId: String? = nil) {
        bridge.handle(type: "connection", event: [
            "event": "connection", "version": 1, "lifetimeId": lifetimeId ?? lifetime, "state": state
        ])
    }

    private func stallBridge() -> ChatHostBridge {
        let bridge = ChatHostBridge(chatURL: URL(string: "https://chat.example:9443/")!,
                                    stalledReconnectDelay: .milliseconds(50))
        bridge.handle(type: "ready", event: [
            "event": "ready", "version": 1, "lifetimeId": lifetime, "sessionKey": "agent:test",
            "capabilities": ["text": true, "reconnect": true]
        ])
        return bridge
    }

    /// Waits past the test bridge's stall delay for its timer to run.
    private func waitPastStallDelay() async throws {
        try await Task.sleep(for: .milliseconds(200))
    }

    func testStalledReconnectDelayMatchesOlderChatsDisconnectedTiming() {
        // Chat turns yellow 1 s into an outage and older Chat turns red at 10 s.
        XCTAssertEqual(ChatHostBridge.defaultStalledReconnectDelay, .seconds(9))
    }

    func testSustainedReconnectingOffersConnectAndRecoveryAfterStallDelay() async throws {
        let bridge = stallBridge()
        var updates = 0
        bridge.recoveryStateObserver = { updates += 1 }

        reportConnection(bridge, "reconnecting")
        XCTAssertEqual(updates, 1)
        XCTAssertFalse(bridge.offersConnect)
        XCTAssertTrue(bridge.isReconnectInProgress)
        XCTAssertEqual(bridge.recoveryConnection, .reconnecting)

        try await waitPastStallDelay()
        XCTAssertEqual(updates, 2, "the stall wakes Tuner's recovery")
        XCTAssertTrue(bridge.reconnectStalled)
        XCTAssertTrue(bridge.offersConnect)
        XCTAssertFalse(bridge.isReconnectInProgress)
        XCTAssertEqual(bridge.recoveryConnection, .disconnected)
        // The dot and its label keep following Chat's own state.
        XCTAssertEqual(bridge.connection, .reconnecting)
        XCTAssertEqual(bridge.connection.label, "Reconnecting; conversation may be out of date")
        XCTAssertEqual(ChatRecoveryPolicy.action(
            isReady: bridge.isReady, connection: bridge.recoveryConnection,
            canReconnectInPlace: bridge.canReconnectInPlace, reconnectIsPending: false,
            chatReconnectIsPending: bridge.isReconnectInProgress, isUnavailable: bridge.phaseIsUnavailable
        ), .reconnect)

        // Connect while stalled is the protocol's in-place reconnect.
        bridge.reconnect()
        XCTAssertEqual(try command(bridge)["type"] as? String, "reconnect")

        reportConnection(bridge, "connected")
        XCTAssertFalse(bridge.reconnectStalled)
        XCTAssertFalse(bridge.offersConnect)
        XCTAssertEqual(bridge.recoveryConnection, .connected)
    }

    func testEarlyDisconnectedKeepsTodaysConnectAndDoesNotStall() async throws {
        let bridge = stallBridge()
        var updates = 0
        bridge.recoveryStateObserver = { updates += 1 }

        reportConnection(bridge, "reconnecting")
        reportConnection(bridge, "disconnected")
        XCTAssertTrue(bridge.offersConnect)
        XCTAssertEqual(bridge.connection.label, "Disconnected")
        XCTAssertEqual(bridge.recoveryConnection, .disconnected)

        try await waitPastStallDelay()
        XCTAssertEqual(updates, 2, "no extra recovery wake after Chat already reported disconnected")
        XCTAssertFalse(bridge.reconnectStalled)
        XCTAssertEqual(bridge.connection, .disconnected)
    }

    func testStallTimingRestartsWhenChatLeavesReconnecting() async throws {
        let bridge = stallBridge()
        reportConnection(bridge, "reconnecting")
        try await waitPastStallDelay()
        XCTAssertTrue(bridge.offersConnect)

        // Older Chat: Tuner's reconnect turns red, then yellow again while Chat retries.
        reportConnection(bridge, "disconnected")
        reportConnection(bridge, "reconnecting")
        XCTAssertFalse(bridge.reconnectStalled)
        XCTAssertFalse(bridge.offersConnect)
        try await waitPastStallDelay()
        XCTAssertTrue(bridge.offersConnect)
    }

    func testReconnectingBrieflyNeverOffersConnect() async throws {
        let bridge = stallBridge()
        reportConnection(bridge, "reconnecting")
        reportConnection(bridge, "connected")
        try await waitPastStallDelay()
        XCTAssertFalse(bridge.reconnectStalled)
        XCTAssertFalse(bridge.offersConnect)
    }

    func testStallClearsOnPageStartAndNewLifetimeButSurvivesRepeatedReady() async throws {
        let bridge = stallBridge()
        reportConnection(bridge, "reconnecting")
        try await waitPastStallDelay()
        XCTAssertTrue(bridge.reconnectStalled)

        // Chat repeats ready for the same lifetime, then the same connection state.
        reportReady(bridge, lifetimeId: lifetime)
        reportConnection(bridge, "reconnecting")
        XCTAssertTrue(bridge.reconnectStalled)

        reportReady(bridge, lifetimeId: "l_next")
        XCTAssertFalse(bridge.reconnectStalled)
        reportConnection(bridge, "reconnecting", lifetimeId: "l_next")
        try await waitPastStallDelay()
        XCTAssertTrue(bridge.reconnectStalled)

        bridge.pageStarted()
        XCTAssertFalse(bridge.reconnectStalled)
        XCTAssertFalse(bridge.offersConnect)
        try await waitPastStallDelay()
        XCTAssertFalse(bridge.reconnectStalled)
    }

    func testUnsupportedAndUnauthorizedStillOfferConnect() {
        let bridge = readyBridge()
        bridge.handle(type: "unavailable", event: [
            "event": "unavailable", "lifetimeId": lifetime, "reason": "unauthorized"
        ])
        XCTAssertTrue(bridge.offersConnect)
    }

    func testHostModeDeclineIsReportedAndRemainsOnChatComposer() {
        let bridge = ChatHostBridge(chatURL: URL(string: "https://chat.example:9443/")!)
        var updates = 0
        bridge.recoveryStateObserver = { updates += 1 }

        bridge.handle(type: "declined", event: ["event": "declined"])

        XCTAssertTrue(bridge.hostModeDeclined)
        XCTAssertFalse(bridge.hostComposerActive)
        XCTAssertEqual(updates, 1)
    }

    func testRecoveryBackoffDoublesToCapAndResets() {
        var backoff = ChatRecoveryBackoff()
        XCTAssertEqual((0..<8).map { _ in backoff.nextDelay() }, [1, 2, 4, 8, 16, 32, 64, 120])
        backoff.reset()
        XCTAssertEqual(backoff.nextDelay(), 1)
    }

    func testRecoveryRetryScheduleWaitsBeyondGatewayTimeoutAndGrowsAcrossAttempts() {
        var backoff = ChatRecoveryBackoff()
        XCTAssertGreaterThanOrEqual(ChatRecoveryPolicy.resumeHealthCheckDelay, 20)
        XCTAssertEqual((0..<5).map { _ in backoff.nextDelay(minimum: ChatRecoveryPolicy.resumeHealthCheckDelay) },
                       [20, 40, 80, 120, 120])
        backoff.reset()
        XCTAssertEqual(backoff.nextDelay(minimum: ChatRecoveryPolicy.resumeHealthCheckDelay), 20)
    }

    func testRecoveryPolicyDoesNotInterruptProgressOrPendingReconnect() {
        XCTAssertEqual(ChatRecoveryPolicy.action(
            isReady: true, connection: .connected, canReconnectInPlace: true, reconnectIsPending: false
        ), .wait)
        XCTAssertEqual(ChatRecoveryPolicy.action(
            isReady: true, connection: .reconnecting, canReconnectInPlace: true, reconnectIsPending: false
        ), .wait)
        XCTAssertEqual(ChatRecoveryPolicy.action(
            isReady: true, connection: .disconnected, canReconnectInPlace: true, reconnectIsPending: true
        ), .wait)
        XCTAssertEqual(ChatRecoveryPolicy.action(
            isReady: false, connection: .reconnecting, canReconnectInPlace: false,
            reconnectIsPending: false, chatReconnectIsPending: true, isUnavailable: true
        ), .wait)
    }

    func testRecoveryPolicyReloadsOrReconnectsOnlyForUnhealthyStates() {
        XCTAssertEqual(ChatRecoveryPolicy.action(
            isReady: false, connection: .connecting, canReconnectInPlace: false, reconnectIsPending: false
        ), .reload)
        XCTAssertEqual(ChatRecoveryPolicy.action(
            isReady: true, connection: .connecting, canReconnectInPlace: true, reconnectIsPending: false
        ), .wait)
        XCTAssertEqual(ChatRecoveryPolicy.action(
            isReady: false, connection: .disconnected, canReconnectInPlace: false, reconnectIsPending: false
        ), .reload)
        XCTAssertEqual(ChatRecoveryPolicy.action(
            isReady: true, connection: .disconnected, canReconnectInPlace: true, reconnectIsPending: false
        ), .reconnect)
        XCTAssertEqual(ChatRecoveryPolicy.action(
            isReady: true, connection: .disconnected, canReconnectInPlace: false, reconnectIsPending: false
        ), .reload)
        XCTAssertEqual(ChatRecoveryPolicy.action(
            isReady: false, connection: .unauthorized, canReconnectInPlace: false, reconnectIsPending: false
        ), .wait)
        XCTAssertEqual(ChatRecoveryPolicy.action(
            isReady: false, connection: .reconnecting, canReconnectInPlace: false,
            reconnectIsPending: false, isUnavailable: true
        ), .reload)
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

    // MARK: Attachments

    private let photo = ChatHostBridge.Attachment(filename: "photo-1.jpg", mimeType: "image/jpeg",
                                                  data: Data([0xFF, 0xD8, 0xFF, 0xE0, 1, 2, 3]))

    func testAttachmentsNeedChatToAdvertiseThem() {
        let bridge = readyBridge(capabilities: ["text": true, "reconnect": true])
        XCTAssertNil(bridge.attachmentCapabilities)
        bridge.send("", attachments: [photo])
        XCTAssertNil(bridge.outgoing)
        XCTAssertNil(bridge.lastCommandJSON)
        bridge.send("caption", attachments: [photo])
        XCTAssertNil(bridge.outgoing, "a photo is never dropped by sending its caption alone")
    }

    func testReadyAdvertisesAttachmentLimits() throws {
        let bridge = readyBridge(capabilities: ["text": true, "attachments": [
            "mediaTypes": ["image/jpeg", "image/png"], "maxAttachments": 4, "maxAttachmentBytes": 1000
        ]])
        let capabilities = try XCTUnwrap(bridge.attachmentCapabilities)
        XCTAssertEqual(capabilities.maxAttachments, 4)
        XCTAssertEqual(capabilities.maxAttachmentBytes, 1000)
        XCTAssertTrue(capabilities.acceptsPhotos)
        XCTAssertTrue(capabilities.accepts("image/png"))
        XCTAssertFalse(capabilities.accepts("image/heic"))
        XCTAssertTrue(try XCTUnwrap(ChatHostBridge.AttachmentCapabilities([String: Any]())).accepts("image/jpeg"))
        XCTAssertFalse(try XCTUnwrap(ChatHostBridge.AttachmentCapabilities(["mediaTypes": ["application/pdf"]])).acceptsPhotos)
        XCTAssertTrue(try XCTUnwrap(ChatHostBridge.AttachmentCapabilities([String: Any]())).acceptsPhotos)

        bridge.pageStarted()
        XCTAssertNil(bridge.attachmentCapabilities)
    }

    func testPhotoOnlySendCarriesBase64Bytes() throws {
        let bridge = readyBridge(capabilities: ["text": true, "attachments": [String: Any]()])
        bridge.send("", attachments: [photo])
        XCTAssertEqual(bridge.outgoing?.status, .sending)
        XCTAssertEqual(bridge.outgoing?.attachments, [photo])
        let command = try command(bridge)
        XCTAssertEqual(command["content"] as? String, "")
        let attachments = try XCTUnwrap(command["attachments"] as? [[String: Any]])
        XCTAssertEqual(attachments.count, 1)
        XCTAssertEqual(attachments[0]["filename"] as? String, "photo-1.jpg")
        XCTAssertEqual(attachments[0]["mimeType"] as? String, "image/jpeg")
        XCTAssertEqual((attachments[0]["data"] as? String).flatMap { Data(base64Encoded: $0) }, photo.data)
        XCTAssertNil(command["retry"])

        report(bridge, "accepted", bridge.outgoing!.correlationId)
        XCTAssertEqual(bridge.outgoing?.status, .accepted)
        report(bridge, "delivered", bridge.outgoing!.correlationId)
        XCTAssertEqual(bridge.outgoing?.status, .delivered)
    }

    func testTextOnlySendHasNoAttachmentsField() throws {
        let bridge = readyBridge(capabilities: ["attachments": [String: Any]()])
        bridge.send("hello")
        XCTAssertNil(try command(bridge)["attachments"])
    }

    func testRetryResendsTheSamePhotosWithTheSameCorrelation() throws {
        let bridge = readyBridge(capabilities: ["attachments": [String: Any]()])
        bridge.send("look", attachments: [photo])
        let correlationId = bridge.outgoing!.correlationId
        bridge.handle(type: "failed", event: ["event": "failed", "lifetimeId": lifetime, "correlationId": correlationId,
                                               "attempt": 1, "reason": "upload-failed", "attachmentIndex": 0])
        XCTAssertEqual(bridge.outgoing?.status, .failed("upload-failed"))

        // The same photo, re-added as a new draft item, is still the same message.
        let readded = ChatHostBridge.Attachment(filename: photo.filename, mimeType: photo.mimeType, data: photo.data)
        bridge.send("look", attachments: [readded])
        XCTAssertEqual(bridge.outgoing?.correlationId, correlationId)
        let command = try command(bridge)
        XCTAssertEqual(command["retry"] as? Bool, true)
        XCTAssertEqual((command["attachments"] as? [[String: Any]])?.count, 1)
    }

    func testChangedPhotosAreANewMessage() {
        let bridge = readyBridge(capabilities: ["attachments": [String: Any]()])
        bridge.send("look", attachments: [photo])
        let correlationId = bridge.outgoing!.correlationId
        report(bridge, "failed", correlationId, reason: "refused")
        let other = ChatHostBridge.Attachment(filename: "photo-2.png", mimeType: "image/png", data: Data([0x89, 0x50]))
        bridge.send("look", attachments: [photo, other])
        XCTAssertNotEqual(bridge.outgoing?.correlationId, correlationId)
        report(bridge, "failed", bridge.outgoing!.correlationId, reason: "refused")
        let second = bridge.outgoing!.correlationId
        bridge.send("look")
        XCTAssertNotEqual(bridge.outgoing?.correlationId, second, "dropping the photos makes a new message")
    }

    func testInvalidAttachmentsRejectionFailsTheSend() {
        let bridge = readyBridge(capabilities: ["attachments": [String: Any]()])
        bridge.send("", attachments: [photo])
        bridge.handle(type: "rejected", event: ["event": "rejected", "lifetimeId": lifetime,
                                                 "correlationId": bridge.outgoing!.correlationId,
                                                 "reason": "invalid-attachments"])
        XCTAssertEqual(bridge.outgoing?.status, .failed("invalid-attachments"))
    }

    func testPhotoEncodingKeepsJPEGAndPNGAndConvertsOtherFormats() throws {
        let jpeg = try XCTUnwrap(PhotoAttachment.encoded(photo.data, name: "photo"))
        XCTAssertEqual(jpeg.mimeType, "image/jpeg")
        XCTAssertEqual(jpeg.data, photo.data)
        XCTAssertTrue(jpeg.filename.hasPrefix("photo-") && jpeg.filename.hasSuffix(".jpg"))

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 6), format: format).image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 8, height: 6))
        }
        let pngData = try XCTUnwrap(image.pngData())
        let png = try XCTUnwrap(PhotoAttachment.encoded(pngData, name: "pasted-image"))
        XCTAssertEqual(png.mimeType, "image/png")
        XCTAssertEqual(png.data, pngData)

        let tiff = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(tiff, "public.tiff" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(image.cgImage), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let converted = try XCTUnwrap(PhotoAttachment.encoded(tiff as Data, name: "photo"))
        XCTAssertEqual(converted.mimeType, "image/jpeg")
        XCTAssertTrue(converted.data.starts(with: [0xFF, 0xD8, 0xFF]))
        XCTAssertEqual(UIImage(data: converted.data)?.size, CGSize(width: 8, height: 6))

        XCTAssertNil(PhotoAttachment.encoded(Data("not an image".utf8), name: "photo"))
    }

    func testPhotoDraftsSurviveARelaunch() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "photo-drafts-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let other = ChatHostBridge.Attachment(filename: "pasted-image-2.png", mimeType: "image/png", data: Data([0x89, 0x50, 0x4E]))
        PhotoDraftStore(root: root).save([photo, other], for: "agent:one")

        let relaunched = PhotoDraftStore(root: root)
        XCTAssertEqual(relaunched.load("agent:one"), [photo, other])
        XCTAssertEqual(relaunched.load("agent:two"), [])

        relaunched.save([other], for: "agent:one")
        XCTAssertEqual(PhotoDraftStore(root: root).load("agent:one"), [other])

        relaunched.save([], for: "agent:one")
        XCTAssertEqual(PhotoDraftStore(root: root).load("agent:one"), [])
    }

    // MARK: Failed-turn restore (Chat's optional restore-requested event)

    private func restoreEvent(lifetimeId: String? = nil, sessionKey: String = "agent:test", messageId: String = "m_failed",
                              correlationId: String? = nil, content: String = "summarize the logs",
                              extra: [String: Any] = [:]) -> [String: Any] {
        var event: [String: Any] = ["event": "restore-requested", "version": 1, "lifetimeId": lifetimeId ?? lifetime,
                                    "sessionKey": sessionKey, "messageId": messageId, "content": content]
        if let correlationId { event["correlationId"] = correlationId }
        return event.merging(extra) { $1 }
    }

    /// Runs the injected script in a bare JavaScript context, as the Chat page would see it.
    func testDeclarationOptsIntoRestoreRequestedVersionOne() throws {
        let bridge = ChatHostBridge(chatURL: URL(string: "https://chat.example:9443/")!)
        let context = try XCTUnwrap(JSContext())
        context.evaluateScript("""
            var posted = [];
            var window = { location: { origin: 'https://chat.example:9443' },
              webkit: { messageHandlers: { tunerChatHost: { postMessage: (m) => posted.push(m) } } } };
            """)
        context.evaluateScript(bridge.declarationScript.source)
        let declaration = "window.__TIGHTBEAM_CHAT_HOST__"
        XCTAssertEqual(context.evaluateScript("JSON.stringify(\(declaration).versions)")?.toString(), "[1]")
        XCTAssertEqual(context.evaluateScript("JSON.stringify(\(declaration).events)")?.toString(),
                       #"{"restore-requested":[1]}"#)
        XCTAssertTrue(context.evaluateScript("typeof \(declaration).onEvent === 'function'")?.toBool() ?? false)

        let elsewhere = try XCTUnwrap(JSContext())
        elsewhere.evaluateScript("""
            var window = { location: { origin: 'https://other.example' },
              webkit: { messageHandlers: { tunerChatHost: { postMessage: () => {} } } } };
            """)
        elsewhere.evaluateScript(bridge.declarationScript.source)
        XCTAssertTrue(elsewhere.evaluateScript("window.__TIGHTBEAM_CHAT_HOST__ === undefined")?.toBool() ?? false)
    }

    func testRestoreForTheCurrentReadyLifetimeWaitsForTheComposerAndSendsNothing() {
        let bridge = readyBridge()
        bridge.handle(type: "restore-requested", event: restoreEvent(correlationId: "c_from-another-device"))
        let request = bridge.pendingRestore
        XCTAssertEqual(request?.messageId, "m_failed")
        XCTAssertEqual(request?.content, "summarize the logs")
        XCTAssertEqual(request?.attachments, [])
        XCTAssertEqual(request?.attachmentsUnavailable, false)
        XCTAssertNil(bridge.lastCommandJSON, "a restore never sends by itself")
        XCTAssertNil(bridge.outgoing)

        bridge.restoreTaken(request!)
        XCTAssertNil(bridge.pendingRestore)
    }

    func testRestoreIsIgnoredUnlessItMatchesTheCurrentReadyLifetime() {
        let waiting = ChatHostBridge(chatURL: URL(string: "https://chat.example:9443/")!)
        waiting.handle(type: "restore-requested", event: restoreEvent())
        XCTAssertNil(waiting.pendingRestore, "no ready lifetime yet")

        let bridge = readyBridge()
        bridge.handle(type: "restore-requested", event: restoreEvent(lifetimeId: "l_old"))
        bridge.handle(type: "restore-requested", event: restoreEvent(sessionKey: "agent:other"))
        bridge.handle(type: "restore-requested", event: restoreEvent(extra: ["version": 2]))
        bridge.handle(type: "restore-requested", event: restoreEvent(extra: ["content": NSNull()]))
        XCTAssertNil(bridge.pendingRestore)

        bridge.handle(type: "unavailable", event: ["event": "unavailable", "version": 1, "lifetimeId": lifetime,
                                                    "reason": "unauthorized"])
        bridge.handle(type: "restore-requested", event: restoreEvent())
        XCTAssertNil(bridge.pendingRestore, "the lifetime is not ready")

        bridge.handle(type: "lifetime-ended", event: ["event": "lifetime-ended", "version": 1, "lifetimeId": lifetime,
                                                       "reason": "target-changed"])
        reportReady(bridge, lifetimeId: "l_next")
        bridge.handle(type: "restore-requested", event: restoreEvent())
        XCTAssertNil(bridge.pendingRestore, "a tap from the ended lifetime")
        bridge.handle(type: "restore-requested", event: restoreEvent(lifetimeId: "l_next"))
        XCTAssertNotNil(bridge.pendingRestore)
        XCTAssertNil(bridge.lastCommandJSON)
    }

    func testRestoredPromptGoesOutOnlyOnSendAsANewCorrelationWithoutRetry() throws {
        let bridge = readyBridge()
        bridge.send("summarize the logs")
        let original = bridge.outgoing!.correlationId
        report(bridge, "accepted", original)
        report(bridge, "delivered", original)
        let sentBefore = bridge.lastCommandJSON

        // The agent's turn then failed; the person taps Edit and resend in Chat.
        bridge.handle(type: "restore-requested", event: restoreEvent(correlationId: original))
        var draft = ""
        var photos: [ChatHostBridge.Attachment] = []
        let lost = ChatHostBridge.apply(try XCTUnwrap(bridge.pendingRestore), draft: &draft, attachments: &photos) { _ in true }
        XCTAssertFalse(lost)
        XCTAssertEqual(draft, "summarize the logs")
        reportReady(bridge, lifetimeId: lifetime)
        XCTAssertEqual(bridge.lastCommandJSON, sentBefore, "nothing is sent until the person taps Send")

        bridge.send(draft + ", briefly")
        let resend = try command(bridge)
        let correlationId = try XCTUnwrap(resend["correlationId"] as? String)
        XCTAssertNotEqual(correlationId, original)
        XCTAssertTrue(correlationId.hasPrefix("c_"))
        XCTAssertNotNil(UUID(uuidString: String(correlationId.dropFirst(2))))
        XCTAssertNil(resend["retry"])
        XCTAssertEqual(resend["content"] as? String, "summarize the logs, briefly")

        // Unedited, it is still a new message rather than a retry of the failed prompt.
        report(bridge, "accepted", correlationId)
        report(bridge, "delivered", correlationId)
        bridge.send("summarize the logs")
        let unedited = try command(bridge)
        XCTAssertNotEqual(unedited["correlationId"] as? String, original)
        XCTAssertNil(unedited["retry"])
    }

    func testRestoreKeepsTypedTextAndARepeatedTapAddsNothing() throws {
        let bridge = readyBridge(capabilities: ["attachments": [String: Any]()])
        let data = photo.data.base64EncodedString()
        bridge.handle(type: "restore-requested", event: restoreEvent(extra: [
            "attachments": [["filename": "photo.jpg", "mimeType": "image/jpeg", "data": data]]
        ]))
        let first = try XCTUnwrap(bridge.pendingRestore)
        XCTAssertEqual(first.attachments.map(\.data), [photo.data])
        XCTAssertFalse(first.attachmentsUnavailable)

        var draft = "and also check disk usage"
        var photos: [ChatHostBridge.Attachment] = []
        _ = ChatHostBridge.apply(first, draft: &draft, attachments: &photos) { _ in true }
        XCTAssertEqual(draft, "summarize the logs\n\nand also check disk usage")
        XCTAssertEqual(photos.count, 1)

        bridge.handle(type: "restore-requested", event: restoreEvent(extra: [
            "attachments": [["filename": "photo.jpg", "mimeType": "image/jpeg", "data": data]]
        ]))
        let second = try XCTUnwrap(bridge.pendingRestore)
        XCTAssertNotEqual(second.id, first.id, "each tap is its own request")
        _ = ChatHostBridge.apply(second, draft: &draft, attachments: &photos) { _ in true }
        XCTAssertEqual(draft, "summarize the logs\n\nand also check disk usage")
        XCTAssertEqual(photos.count, 1)

        bridge.send(draft, attachments: photos)
        let resend = try command(bridge)
        XCTAssertNil(resend["retry"])
        let sent = try XCTUnwrap(resend["attachments"] as? [[String: Any]])
        XCTAssertEqual(sent.first?["data"] as? String, data)
    }

    func testUnavailablePhotosRestoreTheTextAndAreReported() throws {
        let bridge = readyBridge(capabilities: ["attachments": [String: Any]()])
        bridge.handle(type: "restore-requested", event: restoreEvent(extra: ["attachmentsUnavailable": true]))
        let request = try XCTUnwrap(bridge.pendingRestore)
        XCTAssertTrue(request.attachmentsUnavailable)
        var draft = ""
        var photos: [ChatHostBridge.Attachment] = []
        XCTAssertTrue(ChatHostBridge.apply(request, draft: &draft, attachments: &photos) { _ in true })
        XCTAssertEqual(draft, "summarize the logs")
        XCTAssertEqual(photos, [])

        // Photo bytes that cannot be decoded, or a type this lifetime does not take, are reported the same way.
        bridge.handle(type: "restore-requested", event: restoreEvent(extra: [
            "attachments": [["filename": "photo.jpg", "mimeType": "image/jpeg", "data": "not base64!"]]
        ]))
        XCTAssertEqual(bridge.pendingRestore?.attachmentsUnavailable, true)
        bridge.handle(type: "restore-requested", event: restoreEvent(content: "", extra: [
            "attachments": [["filename": "photo.jpg", "mimeType": "image/jpeg", "data": photo.data.base64EncodedString()]]
        ]))
        draft = ""
        XCTAssertTrue(ChatHostBridge.apply(try XCTUnwrap(bridge.pendingRestore), draft: &draft, attachments: &photos) { _ in false })
        XCTAssertEqual(photos, [])
        XCTAssertEqual(draft, "")
    }

    func testRestoreLeavesARefusedSendAndItsRetryAlone() throws {
        let bridge = readyBridge()
        bridge.send("refused words")
        let refused = bridge.outgoing!.correlationId
        report(bridge, "failed", refused, reason: "refused")
        bridge.handle(type: "restore-requested", event: restoreEvent())
        XCTAssertEqual(bridge.outgoing?.status, .failed("refused"))
        XCTAssertEqual(bridge.outgoing?.content, "refused words")

        bridge.send("refused words")
        let retry = try command(bridge)
        XCTAssertEqual(retry["correlationId"] as? String, refused)
        XCTAssertEqual(retry["retry"] as? Bool, true)
    }

    func testANewPageDropsAnUntakenRestore() {
        let bridge = readyBridge()
        bridge.handle(type: "restore-requested", event: restoreEvent())
        XCTAssertNotNil(bridge.pendingRestore)
        bridge.pageStarted()
        XCTAssertNil(bridge.pendingRestore)
    }
}
