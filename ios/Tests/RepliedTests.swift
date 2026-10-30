import Foundation
import XCTest
@testable import TightbeamTuner

final class RepliedTests: XCTestCase {
    func testShownChatUsesCompactColumnAndKeepsRegularDetailVisible() {
        XCTAssertNil(RepliedShownChat(
            selectedSessionKey: "agent:alpha",
            compactWidth: true,
            compactDetailSelected: false,
            sceneIsActive: true
        ).sessionKeyOnScreen)
        XCTAssertEqual(RepliedShownChat(
            selectedSessionKey: "agent:alpha",
            compactWidth: true,
            compactDetailSelected: true,
            sceneIsActive: true
        ).sessionKeyOnScreen, "agent:alpha")
        XCTAssertEqual(RepliedShownChat(
            selectedSessionKey: "agent:alpha",
            compactWidth: false,
            compactDetailSelected: false,
            sceneIsActive: true
        ).sessionKeyOnScreen, "agent:alpha")
        XCTAssertNil(RepliedShownChat(
            selectedSessionKey: "agent:alpha",
            compactWidth: false,
            compactDetailSelected: true,
            sceneIsActive: false
        ).sessionKeyOnScreen)
    }

    func testPagesSelectUnreadRepliesAndSortNewestFirst() throws {
        let messages = try JSONDecoder().decode(RepliedMessagesPage.self, from: Data(#"""
        {
          "schemaVersion": 1,
          "resource": "transcript messages",
          "items": [
            {"seq":10,"sessionKey":"agent:alpha","role":"assistant","turnIncludesHuman":true},
            {"seq":11,"sessionKey":"agent:beta","role":"assistant","turnIncludesHuman":true},
            {"seq":12,"sessionKey":"agent:gamma","role":"assistant","turnIncludesHuman":false},
            {"seq":13,"sessionKey":"agent:delta","role":"user","turnIncludesHuman":true},
            {"seq":14,"sessionKey":"agent:epsilon","role":"assistant"},
            {"seq":15,"sessionKey":"agent:zeta","role":"assistant","turnIncludesHuman":true}
          ],
          "page": {}
        }
        """#.utf8))

        let markers = try JSONDecoder().decode(RepliedMarkersPage.self, from: Data(#"""
        {
          "items": [
            {"userId":"reader","scopeKey":"agent:alpha:session-read-position","marker":10,"updatedAt":1,"rowVersion":"a"},
            {"userId":"reader","scopeKey":"agent:beta:session-read-position","marker":"10","updatedAt":2,"rowVersion":"b"},
            {"userId":"reader","scopeKey":"device:agent:zeta","marker":99,"updatedAt":3,"rowVersion":"c"}
          ],
          "page": {"hasMoreAfter":true,"newestCursor":"cursor /+"}
        }
        """#.utf8))

        XCTAssertEqual(markers.items.map(\.marker), [10, 10, 99])
        XCTAssertTrue(markers.page.hasMoreAfter)
        XCTAssertEqual(markers.page.newestCursor, "cursor /+")

        var state = RepliedState()
        for message in messages.items { state.apply(message) }
        let sessionKeys = Set(["agent:alpha", "agent:beta", "agent:gamma", "agent:delta", "agent:epsilon", "agent:zeta"])
        for marker in markers.items { state.apply(marker, userID: "reader") }

        let roster = try makeAgents(Array(sessionKeys))
        XCTAssertEqual(state.agents(from: roster).map(\.id), ["agent:zeta", "agent:beta"])
    }

    func testReadMarkerFramesMergeByUpdatedAtAndClearBackToUnread() throws {
        let roster = try makeAgents(["agent:alpha"])
        var state = RepliedState()
        state.apply(try message(#"{"seq":20,"sessionKey":"agent:alpha","role":"assistant","turnIncludesHuman":true}"#))

        let oldFormatRead = try change(#"{"type":"change","class":"read_marker.updated","payload":{"userId":"reader","scopeKey":"session:agent:alpha","marker":20,"updatedAt":100}}"#)
        state.apply(oldFormatRead, userID: "reader")
        XCTAssertEqual(state.agents(from: roster).map(\.id), ["agent:alpha"])

        let read = try change(#"{"type":"change","class":"read_marker.updated","payload":{"userId":"reader","scopeKey":"agent:alpha:session-read-position","marker":20,"updatedAt":10}}"#)
        state.apply(read, userID: "reader")
        XCTAssertTrue(state.agents(from: roster).isEmpty)

        let olderRead = try change(#"{"type":"change","class":"read_marker.updated","payload":{"userId":"reader","scopeKey":"agent:alpha:session-read-position","marker":"1","updatedAt":9}}"#)
        state.apply(olderRead, userID: "reader")
        XCTAssertTrue(state.agents(from: roster).isEmpty)

        let cleared = try change(#"{"type":"change","class":"read_marker.updated","payload":{"userId":"reader","scopeKey":"agent:alpha:session-read-position","marker":null,"updatedAt":11}}"#)
        state.apply(cleared, userID: "reader")
        XCTAssertEqual(state.agents(from: roster).map(\.id), ["agent:alpha"])

        let readAgain = try change(#"{"type":"change","class":"read_marker.updated","payload":{"userId":"reader","scopeKey":"agent:alpha:session-read-position","marker":20,"updatedAt":12}}"#)
        state.apply(readAgain, userID: "reader")
        XCTAssertTrue(state.agents(from: roster).isEmpty)

        let newerReply = try change(#"{"type":"change","class":"message.created","payload":{"seq":21,"sessionKey":"agent:alpha","role":"assistant","turnIncludesHuman":true},"refs":{"sessionKey":"agent:alpha"}}"#)
        state.apply(newerReply, userID: "reader")
        XCTAssertEqual(state.agents(from: roster).map(\.id), ["agent:alpha"])
    }

    @MainActor func testEmptyMarkersSkipHistoryAndLiveReplyPopulatesList() async throws {
        let (defaults, suiteName) = try testDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let feed = RepliedFeed(defaults: defaults)
        let reads = FetchCounter()
        let roster = try makeAgents(["agent:alpha"])

        await feed.loadSnapshot(
            gateway: "https://gateway.example.test",
            user: "reader",
            sessionKeys: ["agent:alpha"],
            limit: nil,
            fetchMarkers: { _, _ in [] },
            fetchMessages: { _, _, _ in
                await reads.recordMessageFetch()
                return []
            }
        )

        let messageFetches = await reads.messageFetches
        XCTAssertEqual(messageFetches, 0)
        let initiallyVisible = feed.state.agents(from: roster).map(\.id)
        XCTAssertTrue(initiallyVisible.isEmpty)

        let reply = try change(#"{"type":"change","class":"message.created","payload":{"seq":4,"sessionKey":"agent:alpha","role":"assistant","turnIncludesHuman":true}}"#)
        feed.apply(reply, userID: "reader")
        let afterReply = feed.state.agents(from: roster).map(\.id)
        XCTAssertEqual(afterReply, ["agent:alpha"])
    }

    @MainActor func testNonEmptyMarkersStillReadMessageHistory() async throws {
        let (defaults, suiteName) = try testDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let feed = RepliedFeed(defaults: defaults)
        let reads = FetchCounter()
        let markers = try JSONDecoder().decode(RepliedMarkersPage.self, from: Data(#"{"items":[{"userId":"reader","scopeKey":"agent:alpha:session-read-position","marker":3,"updatedAt":1}],"page":{"hasMoreAfter":false}}"#.utf8)).items
        let history = [try message(#"{"seq":4,"sessionKey":"agent:alpha","role":"assistant","turnIncludesHuman":true}"#)]
        let roster = try makeAgents(["agent:alpha", "agent:beta"])

        await feed.loadSnapshot(
            gateway: "https://gateway.example.test",
            user: "reader",
            sessionKeys: ["agent:alpha", "agent:beta"],
            limit: 100,
            fetchMarkers: { _, _ in markers },
            fetchMessages: { _, key, _ in
                await reads.recordMessageFetch()
                return history.filter { $0.sessionKey == key }
            }
        )

        let messageFetches = await reads.messageFetches
        XCTAssertEqual(messageFetches, 2)
        let visible = feed.state.agents(from: roster).map(\.id)
        XCTAssertEqual(visible, ["agent:alpha"])
    }

    @MainActor func testOpeningHidesReplyUntilNewerReplyAndSurvivesRelaunch() async throws {
        let (defaults, suiteName) = try testDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let roster = try makeAgents(["agent:alpha"])
        let oldReply = try change(#"{"type":"change","class":"message.created","payload":{"seq":20,"sessionKey":"agent:alpha","role":"assistant","turnIncludesHuman":true}}"#)
        let newReply = try change(#"{"type":"change","class":"message.created","payload":{"seq":21,"sessionKey":"agent:alpha","role":"assistant","turnIncludesHuman":true}}"#)
        let feed = RepliedFeed(defaults: defaults)

        feed.markOpened("agent:alpha") // No reply is known yet.
        feed.apply(oldReply, userID: "reader")
        let beforeOpen = feed.state.agents(from: roster).map(\.id)
        XCTAssertEqual(beforeOpen, ["agent:alpha"])

        feed.markOpened("agent:alpha")
        let afterOpen = feed.state.agents(from: roster).map(\.id)
        XCTAssertTrue(afterOpen.isEmpty)

        let olderServerMarker = try change(#"{"type":"change","class":"read_marker.updated","payload":{"userId":"reader","scopeKey":"agent:alpha:session-read-position","marker":19,"updatedAt":1}}"#)
        feed.apply(olderServerMarker, userID: "reader")
        feed.apply(oldReply, userID: "reader")
        let afterDuplicate = feed.state.agents(from: roster).map(\.id)
        XCTAssertTrue(afterDuplicate.isEmpty)

        feed.apply(newReply, userID: "reader")
        let afterNewReply = feed.state.agents(from: roster).map(\.id)
        XCTAssertEqual(afterNewReply, ["agent:alpha"])

        feed.markOpened("agent:alpha")
        let relaunched = RepliedFeed(defaults: defaults)
        relaunched.apply(oldReply, userID: "reader")
        let afterRelaunch = relaunched.state.agents(from: roster).map(\.id)
        XCTAssertTrue(afterRelaunch.isEmpty)

        relaunched.markOpened("agent:alpha") // An older reply cannot lower the saved marker.
        relaunched.apply(newReply, userID: "reader")
        let afterOlderOpen = relaunched.state.agents(from: roster).map(\.id)
        XCTAssertTrue(afterOlderOpen.isEmpty)
    }

    @MainActor func testLiveReplyIsPerDeviceAndOnlySuppressedWhenItsChatIsShown() throws {
        let (shownDefaults, shownSuite) = try testDefaults()
        defer { shownDefaults.removePersistentDomain(forName: shownSuite) }
        let (otherDefaults, otherSuite) = try testDefaults()
        defer { otherDefaults.removePersistentDomain(forName: otherSuite) }
        let roster = try makeAgents(["agent:alpha"])
        let reply = try change(#"{"type":"change","class":"message.created","payload":{"seq":20,"sessionKey":"agent:alpha","role":"assistant","turnIncludesHuman":true}}"#)
        let shownDevice = RepliedFeed(defaults: shownDefaults)
        shownDevice.updateShownSessionKey("agent:alpha")
        shownDevice.apply(reply, userID: "reader")

        XCTAssertTrue(shownDevice.state.agents(from: roster).isEmpty)
        XCTAssertEqual(shownDevice.state.localReadMarkerBySession["agent:alpha"], 20)
        XCTAssertEqual(shownDefaults.dictionary(forKey: "repliedLocalReadMarkers")?["agent:alpha"] as? Int, 20)

        let otherDevice = RepliedFeed(defaults: otherDefaults)
        otherDevice.apply(reply, userID: "reader")
        XCTAssertEqual(otherDevice.state.agents(from: roster).map(\.id), ["agent:alpha"])

        shownDevice.updateShownSessionKey(nil)
        let laterReply = try change(#"{"type":"change","class":"message.created","payload":{"seq":21,"sessionKey":"agent:alpha","role":"assistant","turnIncludesHuman":true}}"#)
        shownDevice.apply(laterReply, userID: "reader")
        XCTAssertEqual(shownDevice.state.agents(from: roster).map(\.id), ["agent:alpha"])
    }

    @MainActor func testCatchUpUsesCurrentShownChatAndSavedSuppressionSurvivesRelaunch() async throws {
        let (defaults, suiteName) = try testDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let roster = try makeAgents(["agent:alpha"])
        let markers = try JSONDecoder().decode(RepliedMarkersPage.self, from: Data(#"{"items":[{"userId":"reader","scopeKey":"agent:alpha:session-read-position","marker":0,"updatedAt":1}],"page":{"hasMoreAfter":false}}"#.utf8)).items
        let reply = try message(#"{"seq":30,"sessionKey":"agent:alpha","role":"assistant","turnIncludesHuman":true}"#)
        let feed = RepliedFeed(defaults: defaults)

        await feed.loadSnapshot(
            gateway: "https://gateway.example.test",
            user: "reader",
            sessionKeys: ["agent:alpha"],
            limit: 100,
            fetchMarkers: { _, _ in markers },
            fetchMessages: { _, _, _ in
                await feed.updateShownSessionKey("agent:alpha")
                return [reply]
            }
        )

        XCTAssertTrue(feed.state.agents(from: roster).isEmpty)
        XCTAssertEqual(defaults.dictionary(forKey: "repliedLocalReadMarkers")?["agent:alpha"] as? Int, 30)

        let relaunched = RepliedFeed(defaults: defaults)
        relaunched.updateShownSessionKey(nil)
        await relaunched.loadSnapshot(
            gateway: "https://gateway.example.test",
            user: "reader",
            sessionKeys: ["agent:alpha"],
            limit: 100,
            fetchMarkers: { _, _ in markers },
            fetchMessages: { _, _, _ in [reply] }
        )
        XCTAssertTrue(relaunched.state.agents(from: roster).isEmpty)

        let laterReply = try change(#"{"type":"change","class":"message.created","payload":{"seq":31,"sessionKey":"agent:alpha","role":"assistant","turnIncludesHuman":true}}"#)
        relaunched.apply(laterReply, userID: "reader")
        XCTAssertEqual(relaunched.state.agents(from: roster).map(\.id), ["agent:alpha"])
    }

    func testRetiredAndOutOfRosterAgentsAreExcluded() throws {
        let roster = try makeAgents(["agent:active"])
        var state = RepliedState()
        state.apply(try message(#"{"seq":1,"sessionKey":"agent:active","role":"assistant","turnIncludesHuman":true}"#))
        state.apply(try message(#"{"seq":2,"sessionKey":"agent:retired","role":"assistant","turnIncludesHuman":true}"#))
        XCTAssertEqual(state.agents(from: roster).map(\.id), ["agent:active"])

        let retired = try change(#"{"type":"change","class":"session.retired","refs":{"sessionKey":"agent:active"},"payload":{"sessionKey":"agent:active","state":"retired"}}"#)
        state.apply(retired, userID: "reader")
        XCTAssertTrue(state.agents(from: roster).isEmpty)
    }

    func testFrameDecoderIgnoresUnknownFramesAndAcceptsSubscriptionReady() throws {
        XCTAssertEqual(RepliedFrame.decode(Data(#"{"type":"subscription_ready","subscriptionId":"replied"}"#.utf8)), .subscriptionReady)
        XCTAssertEqual(RepliedFrame.decode(Data(#"{"type":"heartbeat","seq":4}"#.utf8)), .ignored)
        XCTAssertEqual(RepliedFrame.decode(Data(#"{"type":"error","message":"retry"}"#.utf8)), .serverError)
        XCTAssertEqual(RepliedFrame.decode(Data(#"{"type":"change","class":"other.event","payload":{}}"#.utf8)), .ignored)
        let absentFlag = RepliedFrame.decode(Data(#"{"type":"change","class":"message.created","payload":{"seq":1,"sessionKey":"agent:a","role":"assistant"}}"#.utf8))
        guard case .message(let message) = absentFlag else {
            XCTFail("Expected a message frame")
            return
        }
        XCTAssertFalse(message.turnIncludesHuman)
    }

    func testSessionKeyIsPercentEncodedAsOnePathSegment() throws {
        XCTAssertEqual(RepliedAPI.percentEncodedPathSegment("agent:main:x s_1"), "agent%3Amain%3Ax%20s_1")
        let url = try XCTUnwrap(RepliedAPI.messagesURL(
            gateway: "https://gateway.example.test", sessionKey: "agent:main:x s_1", limit: nil
        ))
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.percentEncodedPath, "/api/sessions/agent%3Amain%3Ax%20s_1/messages")
        XCTAssertEqual(components.queryItems?.map(\.name), ["tail"])
    }

    private func change(_ json: String, file: StaticString = #filePath, line: UInt = #line) throws -> RepliedFrame {
        let frame = RepliedFrame.decode(Data(json.utf8))
        switch frame {
        case .message(_), .readMarker(_), .retired(_): return frame
        default:
            XCTFail("Expected a change frame", file: file, line: line)
            throw NSError(domain: "RepliedTests", code: 1)
        }
    }

    private func message(_ json: String) throws -> RepliedMessage {
        try JSONDecoder().decode(RepliedMessage.self, from: Data(json.utf8))
    }

    private func makeAgents(_ keys: [String]) throws -> [Agent] {
        let sessions: [[String: String]] = keys.map { [
            "sessionKey": $0,
            "displayName": $0,
            "state": "active"
        ] }
        let data = try JSONSerialization.data(withJSONObject: ["sessions": sessions])
        return try JSONDecoder().decode(Roster.self, from: data).sessions
    }

    private func testDefaults() throws -> (UserDefaults, String) {
        let suiteName = "RepliedTests.\(UUID().uuidString)"
        return (try XCTUnwrap(UserDefaults(suiteName: suiteName)), suiteName)
    }

    private actor FetchCounter {
        private(set) var messageFetches = 0
        func recordMessageFetch() { messageFetches += 1 }
    }
}
