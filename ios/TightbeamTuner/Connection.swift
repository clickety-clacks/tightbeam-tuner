import Foundation

struct Connection: Codable, Equatable, Sendable {
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
        static let roster = "rosterSnapshot.v1"
    }

    private struct RosterSnapshot: Codable {
        let schemaVersion: Int
        let connection: Connection
        let agents: [Agent]
    }

    private static let rosterSnapshotSchemaVersion = 1
    typealias RosterFetcher = @Sendable (Connection) async throws -> Data

    var connection: Connection
    var agents: [Agent] = []
    var selectedID: String?
    var recentIDs: [String]
    var error: String?
    var isLoading = false
    var isRosterStale = false
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let rosterFetcher: RosterFetcher
    @ObservationIgnored private var hasRosterSnapshot = false
    @ObservationIgnored private var rosterRevision: UInt64 = 0
    @ObservationIgnored private var refreshInProgress = false
    @ObservationIgnored private var refreshRequested = false

    init(
        defaults: UserDefaults = .standard,
        rosterFetcher: @escaping RosterFetcher = { connection in
            try await SSHRoster.fetch(connection: connection)
        }
    ) {
        self.defaults = defaults
        self.rosterFetcher = rosterFetcher
        connection = defaults.data(forKey: Keys.connection)
            .flatMap { try? JSONDecoder().decode(Connection.self, from: $0) } ?? Connection()
        recentIDs = defaults.stringArray(forKey: Keys.recent) ?? []

        if connection.isComplete,
           let data = defaults.data(forKey: Keys.roster),
           let snapshot = try? JSONDecoder().decode(RosterSnapshot.self, from: data),
           snapshot.schemaVersion == Self.rosterSnapshotSchemaVersion,
           snapshot.connection == connection {
            agents = snapshot.agents.filter(Self.isVisibleRosterAgent)
            hasRosterSnapshot = true
            isRosterStale = true
        }
    }

    var selectedAgent: Agent? { agents.first { $0.id == selectedID } }
    /// Recent agents that are still active, newest first.
    var recentAgents: [Agent] {
        recentIDs.compactMap { id in agents.first { $0.id == id } }
    }

    /// Kept beyond the visible limit, so raising the limit in Settings brings older ones back.
    static let storedRecents = 50

    func save(_ value: Connection) {
        rosterRevision &+= 1
        if refreshInProgress { refreshRequested = true }
        connection = value
        defaults.set(try? JSONEncoder().encode(value), forKey: Keys.connection)
        defaults.removeObject(forKey: Keys.roster)
        hasRosterSnapshot = false
        selectedID = nil
        agents = []
        error = nil
        isRosterStale = false
    }

    func select(_ agent: Agent) {
        selectedID = agent.id
        recentIDs.removeAll { $0 == agent.id }
        recentIDs.insert(agent.id, at: 0)
        recentIDs = Array(recentIDs.prefix(Self.storedRecents))
        defaults.set(recentIDs, forKey: Keys.recent)
    }

    func removeRecent(_ sessionKey: String) {
        recentIDs.removeAll { $0 == sessionKey }
        defaults.set(recentIDs, forKey: Keys.recent)
    }

    func applyRosterEvent(_ frame: RepliedFrame) {
        switch frame {
        case .sessionSpawned(let agent), .sessionUpdated(let agent), .sessionHarnessChanged(let agent):
            rosterRevision &+= 1
            if refreshInProgress { refreshRequested = true }
            if Self.isVisibleRosterAgent(agent) {
                if let index = agents.firstIndex(where: { $0.id == agent.id }) {
                    agents[index] = agent
                } else {
                    agents.append(agent)
                }
            } else {
                removeAgent(agent.id)
            }
            persistRosterSnapshotIfAvailable()
        case .retired(let sessionKey):
            rosterRevision &+= 1
            if refreshInProgress { refreshRequested = true }
            removeAgent(sessionKey)
            persistRosterSnapshotIfAvailable()
        default:
            break
        }
    }

    private func removeAgent(_ sessionKey: String) {
        agents.removeAll { $0.id == sessionKey }
        if selectedID == sessionKey { selectedID = nil }
    }

    private static func isVisibleRosterAgent(_ agent: Agent) -> Bool {
        agent.state == "active" && !agent.id.isEmpty && !agent.name.isEmpty
    }

    private func persistRosterSnapshotIfAvailable() {
        guard hasRosterSnapshot else { return }
        let snapshot = RosterSnapshot(
            schemaVersion: Self.rosterSnapshotSchemaVersion,
            connection: connection,
            agents: agents
        )
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        defaults.set(data, forKey: Keys.roster)
    }

    func refresh() async {
        guard connection.isComplete else { return }
        guard !refreshInProgress else {
            refreshRequested = true
            return
        }
        refreshInProgress = true
        isLoading = true
        repeat {
            refreshRequested = false
            guard connection.isComplete else { break }
            let requestedConnection = connection
            let requestedRevision = rosterRevision
            do {
                let data = try await rosterFetcher(requestedConnection)
                guard !Task.isCancelled else { break }
                guard requestedRevision == rosterRevision else {
                    refreshRequested = true
                    continue
                }
                let roster = try JSONDecoder().decode(Roster.self, from: data)
                agents = roster.sessions.filter(Self.isVisibleRosterAgent)
                if let selectedID, !agents.contains(where: { $0.id == selectedID }) { self.selectedID = nil }
                error = nil
                isRosterStale = false
                hasRosterSnapshot = true
                persistRosterSnapshotIfAvailable()
            } catch {
                guard !Task.isCancelled else { break }
                guard requestedRevision == rosterRevision else {
                    refreshRequested = true
                    continue
                }
                self.error = error.localizedDescription
                isRosterStale = hasRosterSnapshot
            }
        } while refreshRequested && !Task.isCancelled
        refreshInProgress = false
        isLoading = false
    }
}
