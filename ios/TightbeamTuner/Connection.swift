import Foundation

struct Connection: Codable, Equatable {
    var chatServer = ""
    var gateway = ""
    var sshHost = ""
    var sshPort = 22
    var sshUser = ""
    var sshHostKey = ""
    var tightbeamPath = "tightbeam"
    var tightbeamUser = ""

    var isComplete: Bool {
        origin(chatServer) != nil && origin(gateway, allowHTTP: true) != nil
            && !sshHost.isEmpty && !sshHost.contains(where: \.isWhitespace)
            && (1...65535).contains(sshPort)
            && !sshUser.isEmpty && !sshUser.contains(where: \.isWhitespace)
            && !tightbeamPath.isEmpty && !tightbeamPath.contains(where: \.isNewline)
            && !tightbeamUser.isEmpty && !tightbeamUser.contains(where: \.isNewline)
            && SSHRoster.validHostKey(sshHostKey)
    }

    func origin(_ value: String, allowHTTP: Bool = false) -> URL? {
        guard let url = URL(string: value),
              url.scheme == "https" || (allowHTTP && url.scheme == "http"),
              url.host != nil, url.user == nil, url.password == nil,
              url.path.isEmpty || url.path == "/" else { return nil }
        guard url.query == nil, url.fragment == nil else { return nil }
        return url
    }

    func chatURL(for agent: Agent) -> URL? {
        guard let base = origin(chatServer),
              var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else { return nil }
        components.path = "/"
        components.queryItems = [
            URLQueryItem(name: "gateway", value: gateway),
            URLQueryItem(name: "session", value: agent.id)
        ]
        return components.url
    }
}

@MainActor
@Observable
final class TunerStore {
    private enum Keys {
        static let connection = "connection.v1"
        static let recent = "recentAgents.v1"
    }

    var connection: Connection
    var agents: [Agent] = []
    var selectedID: String?
    var recentIDs: [String]
    var error: String?
    var isLoading = false

    init() {
        let defaults = UserDefaults.standard
        connection = defaults.data(forKey: Keys.connection)
            .flatMap { try? JSONDecoder().decode(Connection.self, from: $0) } ?? Connection()
        recentIDs = defaults.stringArray(forKey: Keys.recent) ?? []
    }

    var selectedAgent: Agent? { agents.first { $0.id == selectedID } }
    /// Recent agents that are still active, newest first.
    var recentAgents: [Agent] {
        recentIDs.compactMap { id in agents.first { $0.id == id } }
    }

    /// Kept beyond the visible limit, so raising the limit in Settings brings older ones back.
    static let storedRecents = 50

    func save(_ value: Connection) {
        connection = value
        UserDefaults.standard.set(try? JSONEncoder().encode(value), forKey: Keys.connection)
        selectedID = nil
        agents = []
        error = nil
    }

    func select(_ agent: Agent) {
        selectedID = agent.id
        recentIDs.removeAll { $0 == agent.id }
        recentIDs.insert(agent.id, at: 0)
        recentIDs = Array(recentIDs.prefix(Self.storedRecents))
        UserDefaults.standard.set(recentIDs, forKey: Keys.recent)
    }

    func refresh() async {
        guard connection.isComplete else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let data = try await SSHRoster.fetch(connection: connection)
            let roster = try JSONDecoder().decode(Roster.self, from: data)
            agents = roster.sessions.filter { $0.state == "active" && !$0.id.isEmpty && !$0.name.isEmpty }
            if let selectedID, !agents.contains(where: { $0.id == selectedID }) { self.selectedID = nil }
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}
