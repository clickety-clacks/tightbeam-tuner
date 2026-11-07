import XCTest
@testable import TightbeamTuner

final class ConnectionTests: XCTestCase {
    func testDeviceKeyIsStableAndAcceptedAsSSHKey() throws {
        let first = try SSHKeyStore.publicKeyLine()
        XCTAssertEqual(first, try SSHKeyStore.publicKeyLine())
        XCTAssertTrue(SSHRoster.validHostKey(first))
        XCTAssertFalse(SSHRoster.validHostKey("ssh-ed25519 invalid"))
    }

    func testChatURLPreservesOpaqueSessionKey() throws {
        let agent = try JSONDecoder().decode(Agent.self, from: Data(#"{"sessionKey":"agent:one s_1 2","displayName":"One","state":"active"}"#.utf8))
        var connection = Connection()
        connection.chatServer = "https://chat.example.test"
        connection.gateway = "https://gateway.example.test"
        let url = try XCTUnwrap(connection.chatURL(for: agent))
        let values = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(values.first { $0.name == "session" }?.value, agent.id)
        XCTAssertEqual(values.first { $0.name == "gateway" }?.value, connection.gateway)
    }

    func testHTTPGatewayFromChatIsAcceptedButChatRequiresHTTPS() throws {
        var connection = Connection()
        connection.chatServer = "https://chat.example.test"
        connection.gateway = "http://gateway.example.test:11373"
        connection.sshHost = "server.example.test"
        connection.sshUser = "user"
        connection.sshHostKey = try SSHKeyStore.publicKeyLine()
        connection.tightbeamUser = "user"
        XCTAssertTrue(connection.isComplete)

        connection.chatServer = "http://chat.example.test"
        XCTAssertFalse(connection.isComplete)
    }

    @MainActor
    func testRosterEventsUpdateSpawnedChangedAndRetiredRowsWithoutRefresh() throws {
        let suiteName = "TunerRosterEvents-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = TunerStore(defaults: defaults)
        store.agents = try JSONDecoder().decode(Roster.self, from: Data(#"{"sessions":[{"sessionKey":"agent:existing","displayName":"Existing","state":"active","archetype":"Coder","harness":"codex","model":"gpt-6"},{"sessionKey":"agent:retire","displayName":"Retire me","state":"active"}]}"#.utf8)).sessions
        store.selectedID = "agent:retire"

        store.applyRosterEvent(try rosterEvent(#"{"type":"change","class":"session.spawned","payload":{"sessionKey":"agent:new","displayName":"New","state":"active","archetype":"Coder","harness":"codex","model":"gpt-6"}}"#))
        XCTAssertEqual(store.agents.map(\.id), ["agent:existing", "agent:retire", "agent:new"])

        store.applyRosterEvent(try rosterEvent(#"{"type":"change","class":"session.updated","payload":{"sessionKey":"agent:new","displayName":"Renamed","state":"active","archetype":"Reviewer","harness":"codex","model":"gpt-6.1"}}"#))
        let renamed = try XCTUnwrap(store.agents.first { $0.id == "agent:new" })
        XCTAssertEqual(renamed.name, "Renamed")
        XCTAssertEqual(renamed.archetype, "Reviewer")
        XCTAssertEqual(renamed.model, "gpt-6.1")

        store.applyRosterEvent(try rosterEvent(#"{"type":"change","class":"session.harness_changed","payload":{"sessionKey":"agent:new","displayName":"Renamed","state":"active","archetype":"Reviewer","harness":"claude","model":"gpt-6.1"}}"#))
        XCTAssertEqual(store.agents.first { $0.id == "agent:new" }?.harness, "claude")

        store.applyRosterEvent(try rosterEvent(#"{"type":"change","class":"session.updated","payload":{"sessionKey":"agent:new","displayName":"Renamed","state":"paused","archetype":"Reviewer","harness":"claude","model":"gpt-6.1"}}"#))
        XCTAssertFalse(store.agents.contains { $0.id == "agent:new" })

        store.applyRosterEvent(try rosterEvent(#"{"type":"change","class":"session.retired","refs":{"sessionKey":"agent:retire"},"payload":{"sessionKey":"agent:retire","state":"retired"}}"#))
        XCTAssertNil(store.selectedID)
        XCTAssertFalse(store.agents.contains { $0.id == "agent:retire" })
        XCTAssertFalse(store.isLoading)
    }

    @MainActor
    func testRemovingRecentPersistsWithoutChangingSelection() throws {
        let suiteName = "TunerRecentTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(["alpha", "beta"], forKey: "recentAgents.v1")

        let store = TunerStore(defaults: defaults)
        store.selectedID = "alpha"
        store.removeRecent("alpha")

        XCTAssertEqual(store.recentIDs, ["beta"])
        XCTAssertEqual(store.selectedID, "alpha")
        XCTAssertEqual(TunerStore(defaults: defaults).recentIDs, ["beta"])
    }

    private func rosterEvent(_ json: String) throws -> RepliedFrame {
        let frame = RepliedFrame.decode(Data(json.utf8))
        guard frame.changesRoster else { throw NSError(domain: "ConnectionTests", code: 1) }
        return frame
    }
}
