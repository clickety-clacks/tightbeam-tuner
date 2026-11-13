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
        let regularSessionToken = RepliedShownChat(
            selectedSessionKey: "agent:alpha",
            compactWidth: false,
            compactDetailSelected: false,
            sceneIsActive: true
        ).sessionKeyOnScreen
        let regularSelection = RepliedShownChat.decodeSessionKey(regularSessionToken)
        XCTAssertEqual(regularSelection.sessionKey, "agent:alpha")
        XCTAssertTrue(regularSelection.regularWidth)
        XCTAssertTrue(regularSelection.visible)
        let inactiveRegularSessionToken = RepliedShownChat(
            selectedSessionKey: "agent:alpha",
            compactWidth: false,
            compactDetailSelected: true,
            sceneIsActive: false
        ).sessionKeyOnScreen
        let inactiveRegularSelection = RepliedShownChat.decodeSessionKey(inactiveRegularSessionToken)
        XCTAssertEqual(inactiveRegularSelection.sessionKey, "agent:alpha")
        XCTAssertTrue(inactiveRegularSelection.regularWidth)
        XCTAssertFalse(inactiveRegularSelection.visible)
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

    @MainActor func testAcceptedPromptMovesIntoRepliesWithWaitingIndicator() throws {
        let (defaults, suiteName) = try testDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let feed = RepliedFeed(defaults: defaults)
        let roster = try makeAgents(["agent:alpha"])
        let bridge = makeReplyBridge(sessionKey: "agent:alpha", feed: feed)

        XCTAssertEqual(feed.state.agentsInMainSection(from: roster).map(\.id), ["agent:alpha"])
        bridge.send("synthetic prompt")
        let outgoing = try XCTUnwrap(bridge.outgoing)
        XCTAssertTrue(feed.state.agents(from: roster).isEmpty)
        XCTAssertEqual(feed.state.agentsInMainSection(from: roster).map(\.id), ["agent:alpha"])

        bridge.handle(type: "accepted", event: [
            "lifetimeId": outgoing.lifetimeId,
            "correlationId": outgoing.correlationId
        ])

        XCTAssertEqual(feed.state.agents(from: roster).map(\.id), ["agent:alpha"])
        XCTAssertEqual(feed.state.rowIndicator(for: "agent:alpha"), .waiting)
        let mainSectionAgents = feed.state.agentsInMainSection(from: roster)
        XCTAssertTrue(mainSectionAgents.isEmpty, "A pending agent must leave Agents after acceptance")
        let counts = AgentSectionCounts(
            replied: feed.state.agents(from: roster),
            recent: [],
            agents: mainSectionAgents,
            filter: AgentListFilter(words: [], archetypes: [])
        )
        XCTAssertEqual(counts.agents, 0)
    }

    @MainActor func testRegularWidthShownReplyStaysUnreadUntilSelectingAnotherAgent() throws {
        let (defaults, suiteName) = try testDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(["agent:alpha": 2], forKey: "repliedLocalReadMarkers")
        let feed = RepliedFeed(defaults: defaults)
        let roster = try makeAgents(["agent:alpha", "agent:beta"])
        let shownAlpha = RepliedShownChat(
            selectedSessionKey: "agent:alpha",
            compactWidth: false,
            compactDetailSelected: false,
            sceneIsActive: true
        )
        feed.updateShownSessionKey(shownAlpha.sessionKeyOnScreen)

        let bridge = makeReplyBridge(sessionKey: "agent:alpha", feed: feed)
        bridge.send("synthetic prompt")
        let outgoing = try XCTUnwrap(bridge.outgoing)
        bridge.handle(type: "delivered", event: [
            "lifetimeId": outgoing.lifetimeId,
            "correlationId": outgoing.correlationId,
            "attempt": 1
        ])
        XCTAssertEqual(feed.state.rowIndicator(for: "agent:alpha"), .waiting)
        feed.apply(.message(try message(#"{"seq":3,"sessionKey":"agent:alpha","role":"user","clientMessageId":"\#(outgoing.correlationId)"}"#)), userID: "reader")
        feed.apply(.message(try message(#"{"seq":4,"sessionKey":"agent:alpha","role":"assistant","turnIncludesHuman":true}"#)), userID: "reader")

        XCTAssertFalse(feed.state.isWaitingForReply("agent:alpha"))
        XCTAssertEqual(feed.state.rowIndicator(for: "agent:alpha"), .reply)
        XCTAssertEqual(feed.state.localReadMarkerBySession["agent:alpha"], 2)
        XCTAssertEqual(feed.state.agents(from: roster).map(\.id), ["agent:alpha"])

        let shownBeta = RepliedShownChat(
            selectedSessionKey: "agent:beta",
            compactWidth: false,
            compactDetailSelected: false,
            sceneIsActive: true
        )
        feed.updateShownSessionKey(shownBeta.sessionKeyOnScreen)

        XCTAssertNil(feed.state.rowIndicator(for: "agent:alpha"))
        XCTAssertEqual(feed.state.localReadMarkerBySession["agent:alpha"], 4)
        XCTAssertEqual(defaults.dictionary(forKey: "repliedLocalReadMarkers")?["agent:alpha"] as? Int, 4)
    }

    @MainActor func testInactiveRegularSceneDoesNotReadReplyOrLoseSelection() throws {
        let (defaults, suiteName) = try testDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(["agent:alpha": 2], forKey: "repliedLocalReadMarkers")
        let feed = RepliedFeed(defaults: defaults)
        let shownAlpha = RepliedShownChat(
            selectedSessionKey: "agent:alpha",
            compactWidth: false,
            compactDetailSelected: false,
            sceneIsActive: true
        )
        feed.updateShownSessionKey(shownAlpha.sessionKeyOnScreen)

        let bridge = makeReplyBridge(sessionKey: "agent:alpha", feed: feed)
        bridge.send("synthetic prompt")
        let outgoing = try XCTUnwrap(bridge.outgoing)
        bridge.handle(type: "delivered", event: [
            "lifetimeId": outgoing.lifetimeId,
            "correlationId": outgoing.correlationId,
            "attempt": 1
        ])
        feed.apply(.message(try message(#"{"seq":3,"sessionKey":"agent:alpha","role":"user","clientMessageId":"\#(outgoing.correlationId)"}"#)), userID: "reader")

        let inactiveAlpha = RepliedShownChat(
            selectedSessionKey: "agent:alpha",
            compactWidth: false,
            compactDetailSelected: false,
            sceneIsActive: false
        )
        let inactiveSelection = RepliedShownChat.decodeSessionKey(inactiveAlpha.sessionKeyOnScreen)
        XCTAssertEqual(inactiveSelection.sessionKey, "agent:alpha")
        XCTAssertTrue(inactiveSelection.regularWidth)
        XCTAssertFalse(inactiveSelection.visible)
        feed.updateShownSessionKey(inactiveAlpha.sessionKeyOnScreen)
        feed.apply(.message(try message(#"{"seq":4,"sessionKey":"agent:alpha","role":"assistant","turnIncludesHuman":true}"#)), userID: "reader")

        XCTAssertEqual(feed.state.rowIndicator(for: "agent:alpha"), .reply)
        XCTAssertEqual(feed.state.localReadMarkerBySession["agent:alpha"], 2)

        feed.updateShownSessionKey(shownAlpha.sessionKeyOnScreen)
        XCTAssertEqual(feed.state.rowIndicator(for: "agent:alpha"), .reply)
        XCTAssertEqual(feed.state.localReadMarkerBySession["agent:alpha"], 2)

        feed.apply(.message(try message(#"{"seq":5,"sessionKey":"agent:alpha","role":"assistant","turnIncludesHuman":true}"#)), userID: "reader")
        XCTAssertEqual(feed.state.rowIndicator(for: "agent:alpha"), .reply)
        XCTAssertEqual(feed.state.localReadMarkerBySession["agent:alpha"], 2)

        feed.updateShownSessionKey(RepliedShownChat(
            selectedSessionKey: "agent:beta",
            compactWidth: false,
            compactDetailSelected: false,
            sceneIsActive: true
        ).sessionKeyOnScreen)
        XCTAssertNil(feed.state.rowIndicator(for: "agent:alpha"))
        XCTAssertEqual(feed.state.localReadMarkerBySession["agent:alpha"], 5)
    }

    @MainActor func testRegularShownPromptWithTwoAssistantMessagesStaysUnreadUntilExplicitRead() throws {
        let (defaults, suiteName) = try testDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(["agent:alpha": 2], forKey: "repliedLocalReadMarkers")
        let feed = RepliedFeed(defaults: defaults)
        feed.updateShownSessionKey(RepliedShownChat(
            selectedSessionKey: "agent:alpha",
            compactWidth: false,
            compactDetailSelected: false,
            sceneIsActive: true
        ).sessionKeyOnScreen)

        let bridge = makeReplyBridge(sessionKey: "agent:alpha", feed: feed)
        bridge.send("synthetic prompt")
        let outgoing = try XCTUnwrap(bridge.outgoing)
        bridge.handle(type: "delivered", event: [
            "lifetimeId": outgoing.lifetimeId,
            "correlationId": outgoing.correlationId,
            "attempt": 1
        ])
        feed.apply(.message(try message(#"{"seq":3,"sessionKey":"agent:alpha","role":"user","clientMessageId":"\#(outgoing.correlationId)"}"#)), userID: "reader")
        feed.apply(.message(try message(#"{"seq":4,"sessionKey":"agent:alpha","role":"assistant","turnIncludesHuman":true}"#)), userID: "reader")
        feed.apply(.message(try message(#"{"seq":5,"sessionKey":"agent:alpha","role":"assistant","turnIncludesHuman":true}"#)), userID: "reader")

        XCTAssertEqual(feed.state.rowIndicator(for: "agent:alpha"), .reply)
        XCTAssertEqual(feed.state.localReadMarkerBySession["agent:alpha"], 2)

        feed.markOpened("agent:alpha")
        XCTAssertNil(feed.state.rowIndicator(for: "agent:alpha"))
        XCTAssertEqual(feed.state.localReadMarkerBySession["agent:alpha"], 5)

        feed.apply(.message(try message(#"{"seq":6,"sessionKey":"agent:alpha","role":"assistant","turnIncludesHuman":true}"#)), userID: "reader")
        XCTAssertNil(feed.state.rowIndicator(for: "agent:alpha"))
        XCTAssertEqual(feed.state.localReadMarkerBySession["agent:alpha"], 6)
    }

    @MainActor func testRegularShownTwoAssistantMessagesStayInRepliesUntilLeaving() throws {
        let (defaults, suiteName) = try testDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(["agent:alpha": 2], forKey: "repliedLocalReadMarkers")
        let feed = RepliedFeed(defaults: defaults)
        feed.updateShownSessionKey(RepliedShownChat(
            selectedSessionKey: "agent:alpha",
            compactWidth: false,
            compactDetailSelected: false,
            sceneIsActive: true
        ).sessionKeyOnScreen)

        let bridge = makeReplyBridge(sessionKey: "agent:alpha", feed: feed)
        bridge.send("synthetic prompt")
        let outgoing = try XCTUnwrap(bridge.outgoing)
        bridge.handle(type: "delivered", event: [
            "lifetimeId": outgoing.lifetimeId,
            "correlationId": outgoing.correlationId,
            "attempt": 1
        ])
        feed.apply(.message(try message(#"{"seq":3,"sessionKey":"agent:alpha","role":"user","clientMessageId":"\#(outgoing.correlationId)"}"#)), userID: "reader")
        feed.apply(.message(try message(#"{"seq":4,"sessionKey":"agent:alpha","role":"assistant","turnIncludesHuman":true}"#)), userID: "reader")
        feed.apply(.message(try message(#"{"seq":5,"sessionKey":"agent:alpha","role":"assistant","turnIncludesHuman":true}"#)), userID: "reader")

        XCTAssertFalse(feed.state.isWaitingForReply("agent:alpha"))
        XCTAssertEqual(feed.state.rowIndicator(for: "agent:alpha"), .reply)
        XCTAssertEqual(feed.state.localReadMarkerBySession["agent:alpha"], 2)

        feed.updateShownSessionKey(RepliedShownChat(
            selectedSessionKey: "agent:beta",
            compactWidth: false,
            compactDetailSelected: false,
            sceneIsActive: true
        ).sessionKeyOnScreen)

        XCTAssertNil(feed.state.rowIndicator(for: "agent:alpha"))
        XCTAssertEqual(feed.state.localReadMarkerBySession["agent:alpha"], 5)
    }

    @MainActor func testRegularShownLatePromptEchoStartsHoldForFollowingAssistantMessage() throws {
        let (defaults, suiteName) = try testDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(["agent:alpha": 2], forKey: "repliedLocalReadMarkers")
        let feed = RepliedFeed(defaults: defaults)
        feed.updateShownSessionKey(RepliedShownChat(
            selectedSessionKey: "agent:alpha",
            compactWidth: false,
            compactDetailSelected: false,
            sceneIsActive: true
        ).sessionKeyOnScreen)

        let bridge = makeReplyBridge(sessionKey: "agent:alpha", feed: feed)
        bridge.send("synthetic prompt")
        let outgoing = try XCTUnwrap(bridge.outgoing)
        bridge.handle(type: "delivered", event: [
            "lifetimeId": outgoing.lifetimeId,
            "correlationId": outgoing.correlationId,
            "attempt": 1
        ])
        feed.apply(.message(try message(#"{"seq":4,"sessionKey":"agent:alpha","role":"assistant","turnIncludesHuman":true}"#)), userID: "reader")
        feed.apply(.message(try message(#"{"seq":3,"sessionKey":"agent:alpha","role":"user","clientMessageId":"\#(outgoing.correlationId)"}"#)), userID: "reader")

        XCTAssertEqual(feed.state.rowIndicator(for: "agent:alpha"), .reply)
        XCTAssertEqual(feed.state.localReadMarkerBySession["agent:alpha"], 2)

        feed.apply(.message(try message(#"{"seq":5,"sessionKey":"agent:alpha","role":"assistant","turnIncludesHuman":true}"#)), userID: "reader")
        XCTAssertEqual(feed.state.rowIndicator(for: "agent:alpha"), .reply)
        XCTAssertEqual(feed.state.localReadMarkerBySession["agent:alpha"], 2)
    }

    @MainActor func testRegularShownUnpromptedReplyKeepsExistingAutoReadBehavior() throws {
        let (defaults, suiteName) = try testDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let feed = RepliedFeed(defaults: defaults)
        let shownAlpha = RepliedShownChat(
            selectedSessionKey: "agent:alpha",
            compactWidth: false,
            compactDetailSelected: false,
            sceneIsActive: true
        )
        feed.updateShownSessionKey(shownAlpha.sessionKeyOnScreen)

        feed.apply(.message(try message(#"{"seq":4,"sessionKey":"agent:alpha","role":"assistant","turnIncludesHuman":true}"#)), userID: "reader")

        XCTAssertNil(feed.state.rowIndicator(for: "agent:alpha"))
        XCTAssertEqual(feed.state.localReadMarkerBySession["agent:alpha"], 4)
    }

    @MainActor func testCompactWidthShownReplyStillAutoReadsOnArrival() throws {
        let (defaults, suiteName) = try testDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(["agent:alpha": 2], forKey: "repliedLocalReadMarkers")
        let feed = RepliedFeed(defaults: defaults)
        let compactDetail = RepliedShownChat(
            selectedSessionKey: "agent:alpha",
            compactWidth: true,
            compactDetailSelected: true,
            sceneIsActive: true
        )
        feed.updateShownSessionKey(compactDetail.sessionKeyOnScreen)

        let bridge = makeReplyBridge(sessionKey: "agent:alpha", feed: feed)
        bridge.send("synthetic prompt")
        let outgoing = try XCTUnwrap(bridge.outgoing)
        bridge.handle(type: "accepted", event: [
            "lifetimeId": outgoing.lifetimeId,
            "correlationId": outgoing.correlationId,
            "attempt": 1
        ])
        feed.apply(.message(try message(#"{"seq":3,"sessionKey":"agent:alpha","role":"user","clientMessageId":"\#(outgoing.correlationId)"}"#)), userID: "reader")
        feed.apply(.message(try message(#"{"seq":4,"sessionKey":"agent:alpha","role":"assistant","turnIncludesHuman":true}"#)), userID: "reader")

        XCTAssertFalse(feed.state.isWaitingForReply("agent:alpha"))
        XCTAssertNil(feed.state.rowIndicator(for: "agent:alpha"))
        XCTAssertEqual(feed.state.localReadMarkerBySession["agent:alpha"], 4)
    }

    @MainActor func testRegularShownSubstrateNoticeKeepsExistingBehavior() throws {
        let (defaults, suiteName) = try testDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(["agent:alpha": 2], forKey: "repliedLocalReadMarkers")
        let feed = RepliedFeed(defaults: defaults)
        let shownAlpha = RepliedShownChat(
            selectedSessionKey: "agent:alpha",
            compactWidth: false,
            compactDetailSelected: false,
            sceneIsActive: true
        )
        feed.updateShownSessionKey(shownAlpha.sessionKeyOnScreen)

        let bridge = makeReplyBridge(sessionKey: "agent:alpha", feed: feed)
        bridge.send("synthetic prompt")
        let outgoing = try XCTUnwrap(bridge.outgoing)
        bridge.handle(type: "accepted", event: [
            "lifetimeId": outgoing.lifetimeId,
            "correlationId": outgoing.correlationId,
            "attempt": 1
        ])
        feed.apply(.message(try message(#"{"seq":3,"sessionKey":"agent:alpha","role":"user","clientMessageId":"\#(outgoing.correlationId)"}"#)), userID: "reader")
        feed.apply(.message(try message(#"{"seq":4,"sessionKey":"agent:alpha","role":"assistant","turnIncludesHuman":false}"#)), userID: "reader")

        XCTAssertFalse(feed.state.isWaitingForReply("agent:alpha"))
        XCTAssertNil(feed.state.rowIndicator(for: "agent:alpha"))
        XCTAssertEqual(feed.state.localReadMarkerBySession["agent:alpha"], 2)

        feed.apply(.message(try message(#"{"seq":5,"sessionKey":"agent:alpha","role":"assistant","turnIncludesHuman":true}"#)), userID: "reader")
        XCTAssertNil(feed.state.rowIndicator(for: "agent:alpha"))
        XCTAssertEqual(feed.state.localReadMarkerBySession["agent:alpha"], 5)
    }

    @MainActor func testDeliveredWithoutAcceptedMovesAgentIntoReplies() throws {
        let (defaults, suiteName) = try testDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let feed = RepliedFeed(defaults: defaults)
        let roster = try makeAgents(["agent:alpha"])
        let bridge = makeReplyBridge(sessionKey: "agent:alpha", feed: feed)
        bridge.send("synthetic prompt")
        let outgoing = try XCTUnwrap(bridge.outgoing)

        bridge.handle(type: "delivered", event: [
            "lifetimeId": outgoing.lifetimeId,
            "correlationId": outgoing.correlationId,
            "attempt": 1
        ])

        XCTAssertEqual(bridge.outgoing?.status, .delivered)
        XCTAssertEqual(feed.state.pendingPromptIDs(for: "agent:alpha"), [outgoing.correlationId])
        XCTAssertEqual(feed.state.rowIndicator(for: "agent:alpha"), .waiting)
        XCTAssertEqual(feed.state.agents(from: roster).map(\.id), ["agent:alpha"])
        XCTAssertTrue(feed.state.agentsInMainSection(from: roster).isEmpty)
    }

    @MainActor func testAlreadyDeliveredRejectionMovesAgentIntoReplies() throws {
        let (defaults, suiteName) = try testDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let feed = RepliedFeed(defaults: defaults)
        let roster = try makeAgents(["agent:alpha"])
        let bridge = makeReplyBridge(sessionKey: "agent:alpha", feed: feed)
        bridge.send("synthetic prompt")
        let outgoing = try XCTUnwrap(bridge.outgoing)

        bridge.handle(type: "rejected", event: [
            "lifetimeId": outgoing.lifetimeId,
            "correlationId": outgoing.correlationId,
            "reason": "already-delivered"
        ])

        XCTAssertEqual(bridge.outgoing?.status, .delivered)
        XCTAssertEqual(feed.state.rowIndicator(for: "agent:alpha"), .waiting)
        XCTAssertEqual(feed.state.pendingPromptIDs(for: "agent:alpha"), [outgoing.correlationId])
        XCTAssertTrue(feed.state.agentsInMainSection(from: roster).isEmpty)
    }

    @MainActor func testAcceptedAndDeliveredInEitherOrderKeepOnePendingRowAndItsOrder() throws {
        let (defaults, suiteName) = try testDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let feed = RepliedFeed(defaults: defaults)
        let roster = try makeAgents(["agent:alpha", "agent:beta"])
        let acceptedFirst = makeReplyBridge(sessionKey: "agent:alpha", feed: feed)
        acceptedFirst.send("first prompt")
        let first = try XCTUnwrap(acceptedFirst.outgoing)
        acceptedFirst.handle(type: "accepted", event: [
            "lifetimeId": first.lifetimeId,
            "correlationId": first.correlationId,
            "attempt": 1
        ])
        let firstOrder = try XCTUnwrap(feed.state.pendingOrderBySession["agent:alpha"])

        let deliveredFirst = makeReplyBridge(sessionKey: "agent:beta", feed: feed)
        deliveredFirst.send("second prompt")
        let second = try XCTUnwrap(deliveredFirst.outgoing)
        deliveredFirst.handle(type: "delivered", event: [
            "lifetimeId": second.lifetimeId,
            "correlationId": second.correlationId,
            "attempt": 1
        ])
        let secondOrder = try XCTUnwrap(feed.state.pendingOrderBySession["agent:beta"])
        let rowOrderBeforeDuplicateEvents = feed.state.agents(from: roster).map(\.id)

        acceptedFirst.handle(type: "delivered", event: [
            "lifetimeId": first.lifetimeId,
            "correlationId": first.correlationId,
            "attempt": 1
        ])
        deliveredFirst.handle(type: "accepted", event: [
            "lifetimeId": second.lifetimeId,
            "correlationId": second.correlationId,
            "attempt": 1
        ])

        XCTAssertEqual(feed.state.pendingPromptIDs(for: "agent:alpha"), [first.correlationId])
        XCTAssertEqual(feed.state.pendingPromptIDs(for: "agent:beta"), [second.correlationId])
        XCTAssertEqual(feed.state.pendingOrderBySession["agent:alpha"], firstOrder)
        XCTAssertEqual(feed.state.pendingOrderBySession["agent:beta"], secondOrder)
        XCTAssertEqual(feed.state.agents(from: roster).map(\.id), rowOrderBeforeDuplicateEvents)
        XCTAssertTrue(feed.state.agentsInMainSection(from: roster).isEmpty)
    }

    @MainActor func testLateDeliveryAfterReorderedReplyDoesNotResurrectPrompt() throws {
        let (defaults, suiteName) = try testDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let feed = RepliedFeed(defaults: defaults)
        let roster = try makeAgents(["agent:alpha"])
        let bridge = makeReplyBridge(sessionKey: "agent:alpha", feed: feed)
        bridge.send("synthetic prompt")
        let outgoing = try XCTUnwrap(bridge.outgoing)
        bridge.handle(type: "accepted", event: [
            "lifetimeId": outgoing.lifetimeId,
            "correlationId": outgoing.correlationId,
            "attempt": 1
        ])

        // The live assistant event can reach Tuner before the prompt echo on its feed.
        feed.apply(.message(try message(#"{"seq":11,"sessionKey":"agent:alpha","role":"assistant","turnIncludesHuman":true}"#)), userID: "reader")
        XCTAssertEqual(feed.state.rowIndicator(for: "agent:alpha"), .waiting)
        feed.apply(.message(try message(#"{"seq":10,"sessionKey":"agent:alpha","role":"user","clientMessageId":"\#(outgoing.correlationId)"}"#)), userID: "reader")
        XCTAssertEqual(feed.state.rowIndicator(for: "agent:alpha"), .reply)

        bridge.handle(type: "delivered", event: [
            "lifetimeId": outgoing.lifetimeId,
            "correlationId": outgoing.correlationId,
            "attempt": 1
        ])

        XCTAssertTrue(feed.state.pendingPromptIDs(for: "agent:alpha").isEmpty)
        XCTAssertEqual(feed.state.rowIndicator(for: "agent:alpha"), .reply)
        XCTAssertEqual(feed.state.agents(from: roster).map(\.id), ["agent:alpha"])
        XCTAssertEqual(feed.state.pendingOrderBySession["agent:alpha"], nil)
    }

    @MainActor func testFailureOtherRejectionAndUncertainDoNotCreateRepliesRows() throws {
        let (defaults, suiteName) = try testDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let feed = RepliedFeed(defaults: defaults)
        let roster = try makeAgents(["agent:rejected", "agent:failed", "agent:uncertain"])

        let rejectedBridge = makeReplyBridge(sessionKey: "agent:rejected", feed: feed)
        rejectedBridge.send("rejected prompt")
        let rejected = try XCTUnwrap(rejectedBridge.outgoing)
        rejectedBridge.handle(type: "rejected", event: [
            "lifetimeId": rejected.lifetimeId,
            "correlationId": rejected.correlationId,
            "reason": "offline"
        ])

        let failedBridge = makeReplyBridge(sessionKey: "agent:failed", feed: feed)
        failedBridge.send("failed prompt")
        let failed = try XCTUnwrap(failedBridge.outgoing)
        failedBridge.handle(type: "failed", event: [
            "lifetimeId": failed.lifetimeId,
            "correlationId": failed.correlationId,
            "attempt": 1,
            "reason": "refused"
        ])

        let uncertainBridge = makeReplyBridge(sessionKey: "agent:uncertain", feed: feed)
        uncertainBridge.send("uncertain prompt")
        let uncertain = try XCTUnwrap(uncertainBridge.outgoing)
        uncertainBridge.handle(type: "uncertain", event: [
            "lifetimeId": uncertain.lifetimeId,
            "correlationId": uncertain.correlationId,
            "attempt": 1,
            "reason": "ack-lost"
        ])

        XCTAssertEqual(rejectedBridge.outgoing?.status, .failed("offline"))
        XCTAssertEqual(failedBridge.outgoing?.status, .failed("refused"))
        XCTAssertEqual(uncertainBridge.outgoing?.status, .uncertain("ack-lost"))
        XCTAssertTrue(feed.state.agents(from: roster).isEmpty)
        XCTAssertEqual(feed.state.agentsInMainSection(from: roster).map(\.id), ["agent:rejected", "agent:failed", "agent:uncertain"])
        for sessionKey in ["agent:rejected", "agent:failed", "agent:uncertain"] {
            XCTAssertNil(feed.state.rowIndicator(for: sessionKey))
            XCTAssertFalse(feed.state.isWaitingForReply(sessionKey))
        }
    }

    @MainActor func testAssistantReplyRestoresRepliesArrow() throws {
        let (defaults, suiteName) = try testDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let feed = RepliedFeed(defaults: defaults)
        let roster = try makeAgents(["agent:alpha"])
        let bridge = makeReplyBridge(sessionKey: "agent:alpha", feed: feed)
        bridge.send("synthetic prompt")
        let outgoing = try XCTUnwrap(bridge.outgoing)
        bridge.handle(type: "accepted", event: [
            "lifetimeId": outgoing.lifetimeId,
            "correlationId": outgoing.correlationId
        ])
        XCTAssertTrue(feed.state.agentsInMainSection(from: roster).isEmpty)
        XCTAssertEqual(feed.state.rowIndicator(for: "agent:alpha"), .waiting)

        feed.apply(try change(#"{"type":"change","class":"message.created","payload":{"seq":3,"sessionKey":"agent:alpha","role":"user","clientMessageId":"\#(outgoing.correlationId)"}}"#), userID: "reader")
        feed.apply(try change(#"{"type":"change","class":"message.created","payload":{"seq":4,"sessionKey":"agent:alpha","role":"assistant","turnIncludesHuman":true}}"#), userID: "reader")

        XCTAssertEqual(feed.state.agents(from: roster).map(\.id), ["agent:alpha"])
        XCTAssertEqual(feed.state.rowIndicator(for: "agent:alpha"), .reply)
        XCTAssertEqual(feed.state.agentsInMainSection(from: roster).map(\.id), ["agent:alpha"])
    }

    @MainActor func testReplayedAssistantHistoryDoesNotEndPendingPrompt() async throws {
        let (defaults, suiteName) = try testDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let feed = RepliedFeed(defaults: defaults)
        let roster = try makeAgents(["agent:alpha"])
        let priorReply = try message(#"{"seq":10,"sessionKey":"agent:alpha","role":"assistant","turnIncludesHuman":true}"#)
        feed.apply(.message(priorReply), userID: "reader")

        let bridge = makeReplyBridge(sessionKey: "agent:alpha", feed: feed)
        bridge.send("synthetic prompt")
        let outgoing = try XCTUnwrap(bridge.outgoing)
        bridge.handle(type: "accepted", event: [
            "lifetimeId": outgoing.lifetimeId,
            "correlationId": outgoing.correlationId
        ])

        let prompt = try message(#"{"seq":11,"sessionKey":"agent:alpha","role":"user","clientMessageId":"\#(outgoing.correlationId)"}"#)

        let marker = try JSONDecoder().decode(
            RepliedReadMarker.self,
            from: Data(#"{"userId":"reader","scopeKey":"agent:alpha:session-read-position","marker":8,"updatedAt":1}"#.utf8)
        )
        let requestedPromptIDs = FetchPromptIDsRecorder()
        await feed.loadSnapshot(
            gateway: "https://gateway.example.test",
            user: "reader",
            sessionKeys: ["agent:alpha"],
            limit: 100,
            fetchMarkers: { _, _ in [marker] },
            fetchPendingMessages: { _, _, promptIDs in
                await requestedPromptIDs.record(promptIDs)
                return [priorReply, prompt]
            }
        )

        let recordedRequests = await requestedPromptIDs.values
        XCTAssertEqual(recordedRequests, [Set([outgoing.correlationId])])
        XCTAssertEqual(feed.state.rowIndicator(for: "agent:alpha"), .waiting)
        XCTAssertEqual(feed.state.agents(from: roster).map(\.id), ["agent:alpha"])

        feed.apply(try change(#"{"type":"change","class":"message.created","payload":{"seq":12,"sessionKey":"agent:alpha","role":"assistant","turnIncludesHuman":true}}"#), userID: "reader")

        XCTAssertEqual(feed.state.rowIndicator(for: "agent:alpha"), .reply)
    }

    @MainActor func testCatchUpBeforePromptEchoKeepsOlderReplyWaitingAndDoesNotAdvanceReadMarker() async throws {
        let (defaults, suiteName) = try testDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(["agent:alpha": 5], forKey: "repliedLocalReadMarkers")
        let feed = RepliedFeed(defaults: defaults)
        feed.updateShownSessionKey("agent:alpha")
        let roster = try makeAgents(["agent:alpha"])
        feed.apply(.message(try message(#"{"seq":5,"sessionKey":"agent:alpha","role":"user","clientMessageId":"c_previous"}"#)), userID: "reader")

        let bridge = makeReplyBridge(sessionKey: "agent:alpha", feed: feed)
        bridge.send("synthetic prompt")
        let outgoing = try XCTUnwrap(bridge.outgoing)
        bridge.handle(type: "accepted", event: [
            "lifetimeId": outgoing.lifetimeId,
            "correlationId": outgoing.correlationId
        ])

        let priorReply = try message(#"{"seq":10,"sessionKey":"agent:alpha","role":"assistant","turnIncludesHuman":true}"#)
        let prompt = try message(#"{"seq":11,"sessionKey":"agent:alpha","role":"user","clientMessageId":"\#(outgoing.correlationId)"}"#)
        let requestedPromptIDs = FetchPromptIDsRecorder()
        await feed.loadSnapshot(
            gateway: "https://gateway.example.test",
            user: "reader",
            sessionKeys: ["agent:alpha"],
            limit: 100,
            fetchMarkers: { _, _ in [] },
            fetchPendingMessages: { _, _, promptIDs in
                await requestedPromptIDs.record(promptIDs)
                return [priorReply, prompt]
            }
        )

        let recordedRequests = await requestedPromptIDs.values
        XCTAssertEqual(recordedRequests, [Set([outgoing.correlationId])])
        XCTAssertTrue(feed.state.isWaitingForReply("agent:alpha"))
        XCTAssertEqual(feed.state.rowIndicator(for: "agent:alpha"), .waiting)
        XCTAssertEqual(feed.state.localReadMarkerBySession["agent:alpha"], 5)
        XCTAssertEqual(feed.state.agents(from: roster).map(\.id), ["agent:alpha"])

        feed.apply(try change(#"{"type":"change","class":"message.created","payload":{"seq":12,"sessionKey":"agent:alpha","role":"assistant","turnIncludesHuman":true}}"#), userID: "reader")
        XCTAssertFalse(feed.state.isWaitingForReply("agent:alpha"))
        XCTAssertEqual(feed.state.localReadMarkerBySession["agent:alpha"], 12)
    }

    @MainActor func testCatchUpReplyEndsPromptWhenNoEarlierFeedPositionWasKnown() async throws {
        let (defaults, suiteName) = try testDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let feed = RepliedFeed(defaults: defaults)
        let roster = try makeAgents(["agent:alpha"])
        let bridge = makeReplyBridge(sessionKey: "agent:alpha", feed: feed)
        bridge.send("synthetic prompt")
        let outgoing = try XCTUnwrap(bridge.outgoing)
        XCTAssertEqual(feed.state.agentsInMainSection(from: roster).map(\.id), ["agent:alpha"])
        bridge.handle(type: "accepted", event: [
            "lifetimeId": outgoing.lifetimeId,
            "correlationId": outgoing.correlationId
        ])

        let prompt = try message(#"{"seq":20,"sessionKey":"agent:alpha","role":"user","clientMessageId":"\#(outgoing.correlationId)"}"#)
        let reply = try message(#"{"seq":21,"sessionKey":"agent:alpha","role":"assistant","turnIncludesHuman":true}"#)
        let requestedPromptIDs = FetchPromptIDsRecorder()
        await feed.loadSnapshot(
            gateway: "https://gateway.example.test",
            user: "reader",
            sessionKeys: ["agent:alpha"],
            limit: 100,
            fetchMarkers: { _, _ in [] },
            fetchPendingMessages: { _, _, promptIDs in
                await requestedPromptIDs.record(promptIDs)
                return [prompt, reply]
            }
        )

        let recordedRequests = await requestedPromptIDs.values
        guard let recordedPromptIDs = recordedRequests.first else {
            XCTFail("Expected a pending-prompt catch-up request")
            return
        }
        XCTAssertEqual(recordedRequests.count, 1)
        XCTAssertEqual(recordedPromptIDs, Set([outgoing.correlationId]))
        XCTAssertFalse(feed.state.isWaitingForReply("agent:alpha"))
        XCTAssertEqual(feed.state.rowIndicator(for: "agent:alpha"), .reply)
        XCTAssertEqual(feed.state.agents(from: roster).map(\.id), ["agent:alpha"])
    }

    @MainActor func testSendFailureDoesNotMoveAgentIntoReplies() throws {
        let (defaults, suiteName) = try testDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let feed = RepliedFeed(defaults: defaults)
        let roster = try makeAgents(["agent:alpha"])
        let bridge = makeReplyBridge(sessionKey: "agent:alpha", feed: feed)
        bridge.send("synthetic prompt")
        let outgoing = try XCTUnwrap(bridge.outgoing)
        XCTAssertEqual(feed.state.agentsInMainSection(from: roster).map(\.id), ["agent:alpha"])

        bridge.handle(type: "rejected", event: [
            "lifetimeId": outgoing.lifetimeId,
            "correlationId": outgoing.correlationId,
            "reason": "offline"
        ])

        XCTAssertEqual(bridge.outgoing?.status, .failed("offline"))
        XCTAssertTrue(feed.state.agents(from: roster).isEmpty)
        XCTAssertNil(feed.state.rowIndicator(for: "agent:alpha"))
        XCTAssertEqual(feed.state.agentsInMainSection(from: roster).map(\.id), ["agent:alpha"])
    }

    @MainActor func testFailureAfterAcceptanceClearsWaitingIndicator() throws {
        let (defaults, suiteName) = try testDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let feed = RepliedFeed(defaults: defaults)
        let roster = try makeAgents(["agent:alpha"])
        let bridge = makeReplyBridge(sessionKey: "agent:alpha", feed: feed)
        bridge.send("synthetic prompt")
        let outgoing = try XCTUnwrap(bridge.outgoing)
        bridge.handle(type: "accepted", event: [
            "lifetimeId": outgoing.lifetimeId,
            "correlationId": outgoing.correlationId
        ])
        XCTAssertEqual(feed.state.rowIndicator(for: "agent:alpha"), .waiting)

        bridge.handle(type: "failed", event: [
            "lifetimeId": outgoing.lifetimeId,
            "correlationId": outgoing.correlationId,
            "reason": "synthetic failure"
        ])

        XCTAssertTrue(feed.state.agents(from: roster).isEmpty)
        XCTAssertNil(feed.state.rowIndicator(for: "agent:alpha"))
        XCTAssertEqual(feed.state.agentsInMainSection(from: roster).map(\.id), ["agent:alpha"])
    }

    @MainActor func testLifetimeEndDoesNotClearWaitingIndicator() throws {
        let (defaults, suiteName) = try testDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let feed = RepliedFeed(defaults: defaults)
        let roster = try makeAgents(["agent:alpha"])
        let bridge = makeReplyBridge(sessionKey: "agent:alpha", feed: feed)
        bridge.send("synthetic prompt")
        let outgoing = try XCTUnwrap(bridge.outgoing)
        bridge.handle(type: "accepted", event: [
            "lifetimeId": outgoing.lifetimeId,
            "correlationId": outgoing.correlationId
        ])
        XCTAssertEqual(feed.state.rowIndicator(for: "agent:alpha"), .waiting)

        bridge.handle(type: "unavailable", event: [
            "lifetimeId": outgoing.lifetimeId,
            "reason": "lifetime-ended"
        ])
        XCTAssertEqual(feed.state.rowIndicator(for: "agent:alpha"), .waiting)

        bridge.handle(type: "lifetime-ended", event: ["lifetimeId": outgoing.lifetimeId])

        XCTAssertEqual(feed.state.agents(from: roster).map(\.id), ["agent:alpha"])
        XCTAssertEqual(feed.state.rowIndicator(for: "agent:alpha"), .waiting)
    }

    @MainActor func testPendingReplySurvivesRosterRemovalAndReturn() throws {
        let (defaults, suiteName) = try testDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let feed = RepliedFeed(defaults: defaults)
        let roster = try makeAgents(["agent:alpha"])
        let bridge = makeReplyBridge(sessionKey: "agent:alpha", feed: feed)
        bridge.send("synthetic prompt")
        let outgoing = try XCTUnwrap(bridge.outgoing)
        bridge.handle(type: "accepted", event: [
            "lifetimeId": outgoing.lifetimeId,
            "correlationId": outgoing.correlationId
        ])

        feed.apply(try change(#"{"type":"change","class":"session.retired","refs":{"sessionKey":"agent:alpha"},"payload":{"sessionKey":"agent:alpha","state":"retired"}}"#), userID: "reader")
        XCTAssertTrue(feed.state.agents(from: roster).isEmpty)

        feed.apply(try change(#"{"type":"change","class":"session.spawned","payload":{"sessionKey":"agent:alpha","displayName":"agent:alpha","state":"active"}}"#), userID: "reader")

        XCTAssertEqual(feed.state.agents(from: roster).map(\.id), ["agent:alpha"])
        XCTAssertEqual(feed.state.rowIndicator(for: "agent:alpha"), .waiting)
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

    func testRosterEventFramesDecodeFullSessionRows() throws {
        let spawned = try change(#"{"type":"change","class":"session.spawned","payload":{"sessionKey":"agent:new","displayName":"New agent","state":"active","archetype":"Coder","harness":"codex","model":"gpt-6"}}"#)
        guard case .sessionSpawned(let newAgent) = spawned else {
            XCTFail("Expected a spawned session")
            return
        }
        XCTAssertEqual(newAgent.id, "agent:new")
        XCTAssertEqual(newAgent.name, "New agent")

        let updated = try change(#"{"type":"change","class":"session.updated","payload":{"sessionKey":"agent:new","displayName":"Renamed agent","state":"active","archetype":"Coder","harness":"codex","model":"gpt-6.1"}}"#)
        guard case .sessionUpdated(let changedAgent) = updated else {
            XCTFail("Expected an updated session")
            return
        }
        XCTAssertEqual(changedAgent.name, "Renamed agent")
        XCTAssertEqual(changedAgent.model, "gpt-6.1")

        let harnessChanged = try change(#"{"type":"change","class":"session.harness_changed","payload":{"sessionKey":"agent:new","displayName":"Renamed agent","state":"active","archetype":"Coder","harness":"claude","model":"gpt-6.1"}}"#)
        guard case .sessionHarnessChanged(let changedHarness) = harnessChanged else {
            XCTFail("Expected a harness change")
            return
        }
        XCTAssertEqual(changedHarness.harness, "claude")
        XCTAssertTrue(harnessChanged.changesRoster)

        XCTAssertTrue(spawned.changesRoster)
        XCTAssertTrue(updated.changesRoster)
        let retired = try change(#"{"type":"change","class":"session.retired","refs":{"sessionKey":"agent:new"},"payload":{"sessionKey":"agent:new","state":"retired"}}"#)
        XCTAssertTrue(retired.changesRoster)
    }

    func testSubscriptionRequestsAllRosterLifecycleEvents() throws {
        let frame = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(RepliedAPI.subscriptionFrame.utf8)) as? [String: Any]
        )
        let filters = try XCTUnwrap(frame["filters"] as? [String: Any])
        XCTAssertEqual(
            try XCTUnwrap(filters["classes"] as? [String]),
            ["message.created", "read_marker.updated", "session.spawned", "session.updated", "session.harness_changed", "session.retired"]
        )
    }

    func testReconnectCatchUpRunsAfterAReadySubscriptionIsReestablished() {
        var state = RepliedSubscriptionState()
        XCTAssertFalse(state.subscriptionReadyNeedsCatchUp())
        XCTAssertTrue(state.subscriptionReadyNeedsCatchUp())
        state.reset()
        XCTAssertFalse(state.subscriptionReadyNeedsCatchUp())
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

    func testOlderMessagePagesUseTheOldestCursorInsteadOfTheTailAnchor() throws {
        let url = try XCTUnwrap(RepliedAPI.messagesURL(
            gateway: "https://gateway.example.test",
            sessionKey: "agent:alpha",
            limit: 500,
            before: "cursor /+"
        ))
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.queryItems?.map(\.name), ["before", "limit"])
        XCTAssertEqual(components.queryItems?.first?.value, "cursor /+")

        let page = try JSONDecoder().decode(RepliedMessagesPage.self, from: Data(#"""
        {"items": [], "page": {"oldestCursor": "older", "hasMoreBefore": true}}
        """#.utf8))
        XCTAssertEqual(page.page?.oldestCursor, "older")
        XCTAssertEqual(page.page?.hasMoreBefore, true)
    }

    private func change(_ json: String, file: StaticString = #filePath, line: UInt = #line) throws -> RepliedFrame {
        let frame = RepliedFrame.decode(Data(json.utf8))
        switch frame {
        case .message(_), .readMarker(_), .sessionSpawned(_), .sessionUpdated(_),
             .sessionHarnessChanged(_), .retired(_): return frame
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

    @MainActor private func makeReplyBridge(sessionKey: String, feed: RepliedFeed) -> ChatHostBridge {
        let bridge = ChatHostBridge(
            chatURL: URL(string: "https://chat.example.test/")!,
            outgoingObserver: { outgoing in
                feed.observePromptStatus(outgoing.status, sessionKey: outgoing.sessionKey,
                                        correlationID: outgoing.correlationId)
            }
        )
        bridge.handle(type: "ready", event: [
            "version": 1,
            "lifetimeId": "l_test",
            "sessionKey": sessionKey
        ])
        return bridge
    }

    private actor FetchCounter {
        private(set) var messageFetches = 0
        func recordMessageFetch() { messageFetches += 1 }
    }

    private actor FetchPromptIDsRecorder {
        private(set) var values: [Set<String>] = []
        func record(_ value: Set<String>) { values.append(value) }
    }
}
