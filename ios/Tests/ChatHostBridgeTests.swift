import ImageIO
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
}
