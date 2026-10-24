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
}
