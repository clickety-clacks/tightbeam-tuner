import XCTest
@testable import TightbeamTuner

final class RosterCacheTests: XCTestCase {
    @MainActor
    func testMatchingCacheAppearsBeforeRefreshAndIsReplacedOnSuccess() async throws {
        let connection = completeConnection()
        let (defaults, suiteName) = try makeDefaults(connection: connection)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let cached = roster("agent:cached", "Cached", parent: "agent:parent")
        let seed = TunerStore(defaults: defaults, rosterFetcher: { _ in cached })
        await seed.refresh()

        let refreshed = roster("agent:fresh", "Fresh", model: "gpt-6.1")
        let fetcher = GatedRosterFetcher(nextResponse: refreshed)
        let store = TunerStore(defaults: defaults, rosterFetcher: { connection in
            try await fetcher.fetch(connection)
        })

        XCTAssertEqual(store.agents.map(\.id), ["agent:cached"])
        XCTAssertEqual(store.agents.first?.parent, "agent:parent")
        XCTAssertTrue(store.isRosterStale)

        let refresh = Task { await store.refresh() }
        await fetcher.waitForFirstCall()
        XCTAssertTrue(store.isLoading)
        XCTAssertEqual(store.agents.map(\.id), ["agent:cached"])
        await fetcher.completeFirst(with: refreshed)
        await refresh.value

        XCTAssertEqual(store.agents.map(\.id), ["agent:fresh"])
        XCTAssertEqual(store.agents.first?.model, "gpt-6.1")
        XCTAssertFalse(store.isRosterStale)
        XCTAssertNil(store.error)
        XCTAssertFalse(store.isLoading)
    }

    @MainActor
    func testLiveRosterEventIsPersistedAtSnapshotBoundary() async throws {
        let connection = completeConnection()
        let (defaults, suiteName) = try makeDefaults(connection: connection)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let cached = roster("agent:cached", "Cached")
        let seed = TunerStore(defaults: defaults, rosterFetcher: { _ in cached })
        await seed.refresh()

        let store = TunerStore(defaults: defaults, rosterFetcher: { _ in cached })
        let eventUpdate = try JSONDecoder().decode(
            Roster.self,
            from: roster("agent:cached", "Updated from live event")
        ).sessions[0]
        store.applyRosterEvent(.sessionUpdated(eventUpdate))

        let beforeSnapshot = TunerStore(defaults: defaults, rosterFetcher: { _ in cached })
        XCTAssertEqual(beforeSnapshot.agents.first?.name, "Cached")

        store.persistRosterSnapshotIfAvailable()
        let afterSnapshot = TunerStore(defaults: defaults, rosterFetcher: { _ in cached })
        XCTAssertEqual(afterSnapshot.agents.first?.name, "Updated from live event")
        XCTAssertTrue(afterSnapshot.isRosterStale)
    }

    @MainActor
    func testNoMatchingCacheKeepsEmptyInitialStateAndFailureBehavior() async throws {
        let (defaults, suiteName) = try makeDefaults(connection: completeConnection())
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = TunerStore(defaults: defaults, rosterFetcher: { _ in
            throw NSError(domain: "RosterCacheTests", code: 1)
        })

        XCTAssertTrue(store.agents.isEmpty)
        XCTAssertFalse(store.isRosterStale)
        await store.refresh()

        XCTAssertTrue(store.agents.isEmpty)
        XCTAssertFalse(store.isRosterStale)
        XCTAssertNotNil(store.error)
        XCTAssertFalse(store.isLoading)
    }

    @MainActor
    func testSuccessfulEmptyRefreshReplacesAndPersistsEmptyRoster() async throws {
        let connection = completeConnection()
        let (defaults, suiteName) = try makeDefaults(connection: connection)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let oldRoster = roster("agent:old", "Old")
        let seed = TunerStore(defaults: defaults, rosterFetcher: { _ in oldRoster })
        await seed.refresh()

        let store = TunerStore(defaults: defaults, rosterFetcher: { _ in Data(#"{"sessions":[]}"#.utf8) })
        XCTAssertEqual(store.agents.map(\.id), ["agent:old"])
        await store.refresh()

        XCTAssertTrue(store.agents.isEmpty)
        XCTAssertFalse(store.isRosterStale)
        XCTAssertNil(store.error)

        let nextLaunch = TunerStore(defaults: defaults, rosterFetcher: { _ in Data(#"{"sessions":[]}"#.utf8) })
        XCTAssertTrue(nextLaunch.agents.isEmpty)
        XCTAssertTrue(nextLaunch.isRosterStale)
    }

    @MainActor
    func testFailedRefreshRetainsCachedRowsAndMarksThemPossiblyStale() async throws {
        let connection = completeConnection()
        let (defaults, suiteName) = try makeDefaults(connection: connection)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let cached = roster("agent:cached", "Cached")
        let seed = TunerStore(defaults: defaults, rosterFetcher: { _ in cached })
        await seed.refresh()

        let store = TunerStore(defaults: defaults, rosterFetcher: { _ in
            throw NSError(domain: "RosterCacheTests", code: 2)
        })
        await store.refresh()

        XCTAssertEqual(store.agents.map(\.id), ["agent:cached"])
        XCTAssertTrue(store.isRosterStale)
        XCTAssertNotNil(store.error)
        XCTAssertFalse(store.isLoading)
    }

    @MainActor
    func testDifferentConnectionDoesNotRestoreCachedRows() async throws {
        let originalConnection = completeConnection()
        let (defaults, suiteName) = try makeDefaults(connection: originalConnection)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let oldRoster = roster("agent:old", "Old")
        let seed = TunerStore(defaults: defaults, rosterFetcher: { _ in oldRoster })
        await seed.refresh()

        var otherConnection = originalConnection
        otherConnection.tightbeamUser = "another-user"
        defaults.set(try JSONEncoder().encode(otherConnection), forKey: "connection.v1")

        let store = TunerStore(defaults: defaults, rosterFetcher: { _ in Data(#"{"sessions":[]}"#.utf8) })
        XCTAssertTrue(store.agents.isEmpty)
        XCTAssertFalse(store.isRosterStale)
    }

    @MainActor
    func testSavingConnectionClearsCachedRowsEvenWhenSettingsMatch() async throws {
        let connection = completeConnection()
        let (defaults, suiteName) = try makeDefaults(connection: connection)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let oldRoster = roster("agent:old", "Old")
        let seed = TunerStore(defaults: defaults, rosterFetcher: { _ in oldRoster })
        await seed.refresh()

        let store = TunerStore(defaults: defaults, rosterFetcher: { _ in Data(#"{"sessions":[]}"#.utf8) })
        store.save(connection)

        XCTAssertTrue(store.agents.isEmpty)
        XCTAssertFalse(store.isRosterStale)
        let nextLaunch = TunerStore(defaults: defaults, rosterFetcher: { _ in Data(#"{"sessions":[]}"#.utf8) })
        XCTAssertTrue(nextLaunch.agents.isEmpty)
        XCTAssertFalse(nextLaunch.isRosterStale)
    }

    @MainActor
    func testLiveRosterEventDiscardsAnOlderRefreshResultAndRetries() async throws {
        let connection = completeConnection()
        let (defaults, suiteName) = try makeDefaults(connection: connection)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let outdatedResponse = roster("agent:old", "Old")
        let currentResponse = roster("agent:live", "Live", model: "gpt-6.1")
        let fetcher = GatedRosterFetcher(nextResponse: currentResponse)
        let store = TunerStore(defaults: defaults, rosterFetcher: { connection in
            try await fetcher.fetch(connection)
        })

        let refresh = Task { await store.refresh() }
        await fetcher.waitForFirstCall()
        let liveAgent = try JSONDecoder().decode(Roster.self, from: roster("agent:live", "Live")).sessions[0]
        store.applyRosterEvent(.sessionSpawned(liveAgent))
        await fetcher.completeFirst(with: outdatedResponse)
        await refresh.value

        let callCount = await fetcher.callCount
        XCTAssertEqual(callCount, 2)
        XCTAssertEqual(store.agents.map(\.id), ["agent:live"])
        XCTAssertEqual(store.agents.first?.model, "gpt-6.1")
        XCTAssertFalse(store.isLoading)
    }

    private func makeDefaults(connection: Connection) throws -> (UserDefaults, String) {
        let suiteName = "TunerRosterCacheTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.set(try JSONEncoder().encode(connection), forKey: "connection.v1")
        return (defaults, suiteName)
    }

    private func completeConnection() -> Connection {
        var connection = Connection()
        connection.chatServer = "https://chat.example.test"
        connection.gateway = "https://gateway.example.test"
        connection.sshHost = "roster.example.test"
        connection.sshPort = 22
        connection.sshUser = "tuner"
        connection.sshHostKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINdamAGCsQq31Uv+08lkBzoO4XLz2qYjJa8CGmj3B1Ea"
        connection.tightbeamPath = "/usr/local/bin/tightbeam"
        connection.tightbeamUser = "test-user"
        return connection
    }

    private func roster(_ id: String, _ name: String, parent: String? = nil, model: String? = nil) -> Data {
        let parentField = parent.map { #","currentParent":"\#($0)""# } ?? ""
        let modelField = model.map { #","model":"\#($0)""# } ?? ""
        return Data(#"{"sessions":[{"sessionKey":"\#(id)","displayName":"\#(name)","state":"active","archetype":"Coder","harness":"codex"\#(parentField)\#(modelField)}]}"#.utf8)
    }
}

private actor GatedRosterFetcher {
    private var firstResponseContinuation: CheckedContinuation<Data, Error>?
    private var firstCallWaiter: CheckedContinuation<Void, Never>?
    private(set) var callCount = 0
    private let nextResponse: Data

    init(nextResponse: Data) {
        self.nextResponse = nextResponse
    }

    func fetch(_ connection: Connection) async throws -> Data {
        callCount += 1
        guard callCount == 1 else { return nextResponse }
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            firstResponseContinuation = continuation
            firstCallWaiter?.resume()
            firstCallWaiter = nil
        }
    }

    func waitForFirstCall() async {
        guard firstResponseContinuation == nil else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            firstCallWaiter = continuation
        }
    }

    func completeFirst(with data: Data) {
        let continuation = firstResponseContinuation
        firstResponseContinuation = nil
        continuation?.resume(returning: data)
    }
}
