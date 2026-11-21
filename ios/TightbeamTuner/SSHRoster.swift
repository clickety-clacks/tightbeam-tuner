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
        let result: CommandResult
        do {
            result = try await run(command, on: client)
            try await client.close()
        } catch {
            try? await client.close()
            throw error
        }
        return try rosterData(from: result)
    }

    /// What one SSH command produced. A nil exit code means the server closed the channel
    /// without reporting a non-zero status.
    struct CommandResult: Equatable, Sendable {
        var exitCode: Int?
        var stdout: Data
        var stderr: Data
    }

    static let maxStdoutBytes = 8 * 1024 * 1024
    static let maxStderrBytes = 64 * 1024

    /// Decides from the command's own result, not from whether it wrote to stderr. A login
    /// shell can print warnings on every command; when the command exits 0 and stdout is an
    /// agent list, those warnings are not a failure.
    static func rosterData(from result: CommandResult) throws -> Data {
        let stderr = String(decoding: result.stderr, as: UTF8.self)
        if let exitCode = result.exitCode, exitCode != 0 {
            throw RosterCommandError.failed(exitCode: exitCode, stderr: stderr)
        }
        guard (try? JSONDecoder().decode(Roster.self, from: result.stdout)) != nil else {
            throw RosterCommandError.unreadableOutput(stderr: stderr)
        }
        return result.stdout
    }

    /// Collects stdout and stderr separately. Citadel's `executeCommand(_:maxResponseSize:)`
    /// fails the whole command on any stderr byte, so it is not used here.
    private static func run(_ command: String, on client: SSHClient) async throws -> CommandResult {
        var result = CommandResult(exitCode: nil, stdout: Data(), stderr: Data())
        do {
            for try await chunk in try await client.executeCommandStream(command) {
                switch chunk {
                case .stdout(let buffer):
                    guard result.stdout.count + buffer.readableBytes <= maxStdoutBytes else {
                        throw CitadelError.commandOutputTooLarge
                    }
                    result.stdout.append(contentsOf: buffer.readableBytesView)
                case .stderr(let buffer):
                    // Keep the end: a command's own error usually follows any shell warnings.
                    result.stderr.append(contentsOf: buffer.readableBytesView)
                    if result.stderr.count > maxStderrBytes {
                        result.stderr = Data(result.stderr.suffix(maxStderrBytes))
                    }
                }
            }
        } catch let failure as SSHClient.CommandFailed {
            result.exitCode = failure.exitCode
        }
        return result
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

enum RosterCommandError: LocalizedError, Equatable {
    case failed(exitCode: Int, stderr: String)
    case unreadableOutput(stderr: String)

    /// Bounded so a long shell trace stays readable in the agent list.
    static let maxShownStderrCharacters = 2000

    var stderr: String {
        switch self {
        case .failed(_, let stderr), .unreadableOutput(let stderr): stderr
        }
    }

    var errorDescription: String? {
        let summary = switch self {
        case .failed(let exitCode, _): "The roster command exited with status \(exitCode)."
        case .unreadableOutput: "The roster command did not return an agent list."
        }
        let shown = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !shown.isEmpty else { return summary }
        let bounded = shown.count > Self.maxShownStderrCharacters
            ? "…" + shown.suffix(Self.maxShownStderrCharacters) : shown
        return summary + "\n" + bounded
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
