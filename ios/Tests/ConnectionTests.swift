import XCTest
@testable import TightbeamTuner

final class ConnectionTests: XCTestCase {
    func testDeviceKeyIsStableAndAcceptedAsSSHKey() throws {
        let first = try SSHKeyStore.publicKeyLine()
        XCTAssertEqual(first, try SSHKeyStore.publicKeyLine())
        XCTAssertTrue(SSHRoster.validHostKey(first))
        XCTAssertFalse(SSHRoster.validHostKey("ssh-ed25519 invalid"))
    }

    private static let rosterJSON = Data(#"{"sessions":[{"sessionKey":"agent:one s_1","displayName":"One","state":"active","archetype":"coder","model":"model-a","effort":"high"}]}"#.utf8)
    private static let shellWarning = Data(".zshenv:.:19: no such file or directory: ~/.cargo/env\n".utf8)

    func testRosterLoadsWhenCommandExitsZeroWithStderrWarnings() throws {
        let result = SSHRoster.CommandResult(exitCode: nil, stdout: Self.rosterJSON, stderr: Self.shellWarning)
        let data = try SSHRoster.rosterData(from: result)
        let roster = try JSONDecoder().decode(Roster.self, from: data)
        XCTAssertEqual(roster.sessions.map(\.name), ["One"])
        XCTAssertEqual(roster.sessions.first?.rowDescription, "coder • model-a high")

        let explicitZero = SSHRoster.CommandResult(exitCode: 0, stdout: Self.rosterJSON, stderr: Self.shellWarning)
        XCTAssertEqual(try SSHRoster.rosterData(from: explicitZero), Self.rosterJSON)
        let quiet = SSHRoster.CommandResult(exitCode: nil, stdout: Self.rosterJSON, stderr: Data())
        XCTAssertEqual(try SSHRoster.rosterData(from: quiet), Self.rosterJSON)
    }

    func testRosterCommandNonZeroExitIsAnErrorCarryingStderr() {
        let result = SSHRoster.CommandResult(exitCode: 2, stdout: Self.rosterJSON,
                                             stderr: Self.shellWarning + Data("unknown user\n".utf8))
        XCTAssertThrowsError(try SSHRoster.rosterData(from: result)) { error in
            guard case .failed(2, let stderr) = error as? RosterCommandError else {
                return XCTFail("unexpected error \(error)")
            }
            XCTAssertTrue(stderr.hasSuffix("unknown user\n"))
            let shown = error.localizedDescription
            XCTAssertTrue(shown.hasPrefix("The roster command exited with status 2."))
            XCTAssertTrue(shown.contains("unknown user"))
        }
    }

    func testRosterCommandUnparseableStdoutIsAnErrorCarryingStderr() {
        for stdout in [Data(), Data("not json".utf8), Data(#"{"other":[]}"#.utf8)] {
            let result = SSHRoster.CommandResult(exitCode: 0, stdout: stdout, stderr: Self.shellWarning)
            XCTAssertThrowsError(try SSHRoster.rosterData(from: result)) { error in
                XCTAssertEqual(error as? RosterCommandError,
                               .unreadableOutput(stderr: String(decoding: Self.shellWarning, as: UTF8.self)))
                XCTAssertTrue(error.localizedDescription.contains("~/.cargo/env"))
            }
        }
        let silent = SSHRoster.CommandResult(exitCode: nil, stdout: Data("oops".utf8), stderr: Data())
        XCTAssertThrowsError(try SSHRoster.rosterData(from: silent)) { error in
            XCTAssertEqual(error.localizedDescription, "The roster command did not return an agent list.")
        }
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

        store.applyRosterEvent(try rosterEvent(#"""
        {"type":"change","class":"session.spawned","payload":{"sessionKey":"agent:new","displayName":"New","state":"active","archetype":"Coder","harness":"codex","model":"gpt-6","thinkingLevel":"high"}}
        """#))
        XCTAssertEqual(store.agents.map(\.id), ["agent:existing", "agent:retire", "agent:new"])
        let spawned = try XCTUnwrap(store.agents.first { $0.id == "agent:new" })
        XCTAssertEqual(spawned.effort, "high")
        XCTAssertEqual(spawned.rowDescription, "Coder • gpt-6 high")

        store.applyRosterEvent(try rosterEvent(#"""
        {"type":"change","class":"session.updated","payload":{"sessionKey":"agent:new","displayName":"Renamed","state":"active","archetype":"Reviewer","harness":"codex","model":"gpt-6.1","thinkingLevel":"medium"}}
        """#))
        let renamed = try XCTUnwrap(store.agents.first { $0.id == "agent:new" })
        XCTAssertEqual(renamed.name, "Renamed")
        XCTAssertEqual(renamed.archetype, "Reviewer")
        XCTAssertEqual(renamed.model, "gpt-6.1")
        XCTAssertEqual(renamed.effort, "medium")
        XCTAssertEqual(renamed.rowDescription, "Reviewer • gpt-6.1 medium")

        store.applyRosterEvent(try rosterEvent(#"""
        {"type":"change","class":"session.harness_changed","payload":{"sessionKey":"agent:new","displayName":"Renamed","state":"active","archetype":"Reviewer","harness":"claude","model":"gpt-6.1","thinkingLevel":"low"}}
        """#))
        let harnessChanged = try XCTUnwrap(store.agents.first { $0.id == "agent:new" })
        XCTAssertEqual(harnessChanged.harness, "claude")
        XCTAssertEqual(harnessChanged.effort, "low")
        XCTAssertEqual(harnessChanged.rowDescription, "Reviewer • gpt-6.1 low")

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
