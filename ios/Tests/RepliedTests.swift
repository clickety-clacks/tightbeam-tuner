import Foundation
import XCTest
@testable import TightbeamTuner

final class RepliedTests: XCTestCase {
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
            {"userId":"reader","scopeKey":"session:agent:alpha","marker":10,"updatedAt":1,"rowVersion":"a"},
            {"userId":"reader","scopeKey":"session:agent:beta","marker":"10","updatedAt":2,"rowVersion":"b"},
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

        let read = try change(#"{"type":"change","class":"read_marker.updated","payload":{"userId":"reader","scopeKey":"session:agent:alpha","marker":20,"updatedAt":10}}"#)
        state.apply(read, userID: "reader")
        XCTAssertTrue(state.agents(from: roster).isEmpty)

        let olderRead = try change(#"{"type":"change","class":"read_marker.updated","payload":{"userId":"reader","scopeKey":"session:agent:alpha","marker":"1","updatedAt":9}}"#)
        state.apply(olderRead, userID: "reader")
        XCTAssertTrue(state.agents(from: roster).isEmpty)

        let cleared = try change(#"{"type":"change","class":"read_marker.updated","payload":{"userId":"reader","scopeKey":"session:agent:alpha","marker":null,"updatedAt":11}}"#)
        state.apply(cleared, userID: "reader")
        XCTAssertEqual(state.agents(from: roster).map(\.id), ["agent:alpha"])

        let readAgain = try change(#"{"type":"change","class":"read_marker.updated","payload":{"userId":"reader","scopeKey":"session:agent:alpha","marker":20,"updatedAt":12}}"#)
        state.apply(readAgain, userID: "reader")
        XCTAssertTrue(state.agents(from: roster).isEmpty)

        let newerReply = try change(#"{"type":"change","class":"message.created","payload":{"seq":21,"sessionKey":"agent:alpha","role":"assistant","turnIncludesHuman":true},"refs":{"sessionKey":"agent:alpha"}}"#)
        state.apply(newerReply, userID: "reader")
        XCTAssertEqual(state.agents(from: roster).map(\.id), ["agent:alpha"])
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
}
