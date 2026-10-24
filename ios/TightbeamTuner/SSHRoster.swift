import Citadel
import Crypto
import Foundation
import NIOSSH
import Security

enum SSHRoster {
    static func validHostKey(_ line: String) -> Bool {
        (try? trustedKey(line)) != nil
    }

    static func fetch(connection: Connection) async throws -> Data {
        let privateKey = try SSHKeyStore.loadOrCreate()
        let hostKey = try trustedKey(connection.sshHostKey)
        let settings = SSHClientSettings(
            host: connection.sshHost.trimmingCharacters(in: .whitespaces),
            port: connection.sshPort,
            authenticationMethod: {
                .ed25519(username: connection.sshUser, privateKey: privateKey)
            },
            hostKeyValidator: .trustedKeys([hostKey])
        )
        let client = try await SSHClient.connect(to: settings)
        let command = [connection.tightbeamPath, "list", "--as-user", connection.tightbeamUser]
            .map(shellQuote).joined(separator: " ")
        do {
            let output = try await client.executeCommand(command, maxResponseSize: 8 * 1024 * 1024)
            let data = Data(output.readableBytesView)
            try await client.close()
            return data
        } catch {
            try? await client.close()
            throw error
        }
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }

    private static func trustedKey(_ line: String) throws -> NIOSSHPublicKey {
        let parts = line.split(whereSeparator: \.isWhitespace)
        guard parts.count >= 2, parts[0] == "ssh-ed25519" else { throw SSHSetupError.invalidHostKey }
        return try NIOSSHPublicKey(openSSHPublicKey: line)
    }
}

private enum SSHSetupError: LocalizedError {
    case invalidHostKey
    var errorDescription: String? { "Enter the SSH server's ssh-ed25519 public host key." }
}

enum SSHKeyStore {
    private static let service = "co.clicketyclacks.tightbeam-tuner.ssh"
    private static let account = "roster-key"

    static func loadOrCreate() throws -> Curve25519.Signing.PrivateKey {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecSuccess, let data = result as? Data {
            return try Curve25519.Signing.PrivateKey(rawRepresentation: data)
        }
        guard status == errSecItemNotFound else { throw SSHKeyError.keychain(status) }
        let key = Curve25519.Signing.PrivateKey()
        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: key.rawRepresentation,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let addStatus = SecItemAdd(attributes as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw SSHKeyError.keychain(addStatus) }
        return key
    }

    static func publicKeyLine() throws -> String {
        let raw = try loadOrCreate().publicKey.rawRepresentation
        func field(_ data: Data) -> Data {
            var result = Data()
            let count = UInt32(data.count)
            result.append(contentsOf: [(count >> 24), (count >> 16), (count >> 8), count].map { UInt8($0 & 0xff) })
            result.append(data)
            return result
        }
        return "ssh-ed25519 " + (field(Data("ssh-ed25519".utf8)) + field(raw)).base64EncodedString()
    }
}

private enum SSHKeyError: LocalizedError {
    case keychain(OSStatus)
    var errorDescription: String? { "Could not store the SSH key in the device Keychain." }
}
