import Foundation
import XCTest
@testable import TightbeamTuner

@MainActor
final class ReleaseCompatibilityTests: XCTestCase {
    private struct ReleaseReference: Decodable {
        let id: Int
    }

    private struct FixtureReply: Decodable {
        let ok: Bool
    }

    private struct UpgradeReply: Decodable {
        let ok: Bool
        let savedConnectionLoaded: Bool
        let rosterIdentityPreserved: Bool
    }

    private struct RuntimeContext: Decodable {
        let releaseId: Int
    }

    func testProductionRosterAndRepliesPathsAgainstPublishedRuntime() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let phase = environment["TUNER_COMPAT_PHASE"],
              let fixtureBase = environment["TUNER_COMPAT_FIXTURE_URL"],
              let token = environment["TUNER_COMPAT_FIXTURE_TOKEN"],
              let gateway = environment["TUNER_COMPAT_GATEWAY_URL"],
              let sshPort = Int(environment["TUNER_COMPAT_SSH_PORT"] ?? ""),
              let sshHostKey = environment["TUNER_COMPAT_SSH_HOST_KEY"],
              let sshUser = environment["TUNER_COMPAT_SSH_USER"],
              let user = environment["TUNER_COMPAT_USER"],
              let cli = environment["TUNER_COMPAT_CLI"],
              let releaseData = environment["TUNER_COMPAT_RELEASES_JSON"]?.data(using: .utf8),
              let sourceData = environment["TUNER_COMPAT_PHASE_SOURCE_JSON"]?.data(using: .utf8),
              let simulatorType = environment["TUNER_COMPAT_SIMULATOR_TYPE"],
              let simulatorRuntime = environment["TUNER_COMPAT_SIMULATOR_RUNTIME"] else {
            throw XCTSkip("Only the isolated published-runtime matrix supplies this test configuration.")
        }
        guard phase == "baseline" || phase == "candidate" else {
            XCTFail("The compatibility phase is invalid.")
            return
        }

        let releases = try JSONDecoder().decode([ReleaseReference].self, from: releaseData)
        let phaseSource = try JSONSerialization.jsonObject(with: sourceData)
        let candidateValue = try jsonObject(environment["TUNER_COMPAT_CANDIDATE_JSON"])
        let runId = try XCTUnwrap(environment["TUNER_COMPAT_RUN_ID"])
        let attempt = Int(environment["TUNER_COMPAT_ATTEMPT"] ?? "1") ?? 1

        for release in releases {
            let selected = try await fixturePost(
                fixtureBase + "/select-runtime",
                token: token,
                body: ["releaseId": release.id]
            )
            XCTAssertTrue(selected.ok, "The test fixture must start the digest-pinned published runtime.")
            let runtime = try await fixtureGet(
                fixtureBase + "/runtime-context",
                token: token,
                as: RuntimeContext.self
            )
            XCTAssertEqual(runtime.releaseId, release.id)

            let connection = Connection(
                chatServer: "https://chat.invalid",
                gateway: gateway,
                sshHost: "127.0.0.1",
                sshPort: sshPort,
                sshUser: sshUser,
                sshHostKey: sshHostKey,
                tightbeamPath: cli,
                tightbeamUser: user
            )
            let key = try SSHKeyStore.publicKeyLine()
            let authorized = try await fixturePost(
                fixtureBase + "/authorized-key",
                token: token,
                body: ["publicKey": key]
            )
            XCTAssertTrue(authorized.ok)

            let defaults = UserDefaults.standard
            if phase == "baseline" {
                // Isolate each published-runtime comparison while preserving
                // the baseline state for the candidate's upgrade check.
                defaults.removeObject(forKey: "repliedStateSnapshot.v1")
                defaults.removeObject(forKey: "repliedLocalReadMarkers")
            }
            let store = TunerStore(defaults: defaults)
            var savedConnectionLoaded = true
            var rosterIdentityPreserved = true
            if phase == "baseline" {
                store.save(connection)
                let recorded = try await fixturePost(
                    fixtureBase + "/record-baseline-state",
                    token: token,
                    body: [
                        "releaseId": release.id,
                        "publicKey": key,
                        "connection": try connectionObject(connection),
                    ]
                )
                XCTAssertTrue(recorded.ok)
            } else {
                let upgrade = try await fixturePost(
                    fixtureBase + "/verify-upgrade-state",
                    token: token,
                    body: [
                        "releaseId": release.id,
                        "publicKey": key,
                        "connection": try connectionObject(connection),
                    ],
                    as: UpgradeReply.self
                )
                savedConnectionLoaded = upgrade.savedConnectionLoaded && store.connection == connection
                rosterIdentityPreserved = upgrade.rosterIdentityPreserved
                if !savedConnectionLoaded {
                    // Keep the other production-client comparisons measurable after recording the break.
                    store.save(connection)
                }
            }

            await store.refresh()
            let mainID = "agent:\(user):main"
            let main = store.agents.first { $0.id == mainID }
            let rosterPassed = store.error == nil && main != nil && main?.parent == nil
            if let main { store.select(main) }

            let sequences = await RepliedAPI.fetchSequences(gateway: gateway, user: user)
            let markersData = try? await fixtureGetData(RepliedAPI.markersURL(gateway: gateway, user: user, after: nil))
            let markers = markersData.flatMap { try? JSONDecoder().decode(RepliedMarkersPage.self, from: $0) }
            let messages = await RepliedAPI.fetchMessages(gateway: gateway, sessionKey: mainID, limit: 500)

            let feed = RepliedFeed(defaults: defaults)
            feed.activateConnection(connection)
            await feed.loadSnapshot(
                gateway: gateway,
                user: user,
                sessionKeys: store.agents.map(\.id),
                limit: 500,
                recentSessionKeys: store.recentAgents.map(\.id),
                mode: .initial
            )
            let expectedLatestReply = messages?
                .filter { $0.sessionKey == mainID && $0.role == "assistant" && $0.turnIncludesHuman }
                .map(\.seq).max()
            let initialClientStateMatched = feed.state.latestReplyBySession[mainID] == expectedLatestReply
                && sequenceSummaryMatches(sequences, messages: messages, sessionKey: mainID)
            let readMarkerClientStateMatched = readMarkersApplied(markers, state: feed.state, user: user)
            let initialSyncPassed = sequences != nil && messages != nil && initialClientStateMatched
            let readMarkerSyncPassed = markers != nil && readMarkerClientStateMatched

            var liveEventObserved = false
            var liveSessionIdentityMatched = false
            var liveParentRelationMatched = false
            var reconnectCompleted = false
            let newUser = "test" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
            let task = Task {
                await feed.run(
                    connection: connection,
                    sessionKeys: { store.agents.map(\.id) },
                    recentSessionKeys: { store.recentAgents.map(\.id) },
                    onRosterEvent: { frame in
                        store.applyRosterEvent(frame)
                        if case .sessionSpawned(let agent) = frame,
                           agent.id == "agent:\(newUser):main" {
                            liveEventObserved = true
                            liveSessionIdentityMatched = store.agents.contains { $0.id == agent.id }
                            liveParentRelationMatched = agent.parent == nil
                        }
                    },
                    onReconnect: {
                        let reconnectSequences = await RepliedAPI.fetchSequences(gateway: gateway, user: user)
                        let reconnectMarkersData = try? await fixtureGetData(
                            RepliedAPI.markersURL(gateway: gateway, user: user, after: nil)
                        )
                        let reconnectMarkers = reconnectMarkersData.flatMap {
                            try? JSONDecoder().decode(RepliedMarkersPage.self, from: $0)
                        }
                        let reconnectMessages = await RepliedAPI.fetchMessages(
                            gateway: gateway, sessionKey: mainID, limit: 100
                        )
                        await feed.loadSnapshot(
                            gateway: gateway,
                            user: user,
                            sessionKeys: store.agents.map(\.id),
                            limit: 100,
                            recentSessionKeys: store.recentAgents.map(\.id),
                            mode: .reconnect
                        )
                        let reconnectExpectedLatestReply = reconnectMessages?
                            .filter { $0.sessionKey == mainID && $0.role == "assistant" && $0.turnIncludesHuman }
                            .map(\.seq).max()
                        let reconnectClientStateMatched =
                            feed.state.latestReplyBySession[mainID] == reconnectExpectedLatestReply
                            && sequenceSummaryMatches(
                                reconnectSequences, messages: reconnectMessages, sessionKey: mainID
                            )
                            && readMarkersApplied(reconnectMarkers, state: feed.state, user: user)
                        reconnectCompleted = reconnectSequences != nil
                            && reconnectMarkers != nil
                            && reconnectMessages != nil
                            && reconnectClientStateMatched
                    }
                )
            }

            try await Task.sleep(for: .milliseconds(750))
            let seeded = try await fixturePost(
                fixtureBase + "/add-user",
                token: token,
                body: ["user": newUser]
            )
            let liveObserved = await waitUntil(timeout: 20) { liveEventObserved }
            let restart = try await fixturePost(
                fixtureBase + "/restart-gateway",
                token: token,
                body: [:]
            )
            let reconnected = await waitUntil(timeout: 30) { reconnectCompleted }
            task.cancel()
            try? await Task.sleep(for: .milliseconds(150))

            let checks: [String: Any] = [
                "roster": [
                    "status": rosterPassed ? "passed" : "failed",
                    "implementation": "production-client",
                    "observed": [
                        "sessionIdentity": main == nil ? "missing" : "matched",
                        "parentRelation": main?.parent == nil && main != nil ? "matched" : "mismatched",
                        "sessionCount": store.agents.count,
                    ],
                ],
                "initial_message_sync": [
                    "status": initialSyncPassed ? "passed" : "failed",
                    "implementation": "production-client",
                    "observed": [
                        "sequenceSummaryDecoded": sequences != nil,
                        "messagePageDecoded": messages != nil,
                        "clientStateMatched": initialClientStateMatched,
                        "sessionCount": store.agents.count,
                        "messageCount": messages?.count ?? 0,
                    ],
                ],
                "read_marker_sync": [
                    "status": readMarkerSyncPassed ? "passed" : "failed",
                    "implementation": "production-client",
                    "observed": [
                        "pageDecoded": markers != nil,
                        "clientStateMatched": readMarkerClientStateMatched,
                        "markerCount": markers?.items.count ?? 0,
                    ],
                ],
                "catch_up": [
                    "status": reconnected && restart.ok ? "passed" : "failed",
                    "implementation": "production-client",
                    "observed": [
                        "gatewayRestarted": restart.ok,
                        "reconnected": reconnected,
                        "snapshotReadCompleted": reconnectCompleted,
                        "clientStateMatched": reconnectCompleted,
                    ],
                ],
                "live_subscription": [
                    "status": seeded.ok && liveObserved && liveSessionIdentityMatched && liveParentRelationMatched
                        ? "passed" : "failed",
                    "implementation": "production-client",
                    "observed": [
                        "eventClass": liveObserved ? "session.spawned" : "not-observed",
                        "observedByClient": liveObserved,
                        "sessionIdentity": liveSessionIdentityMatched ? "matched" : "missing",
                        "parentRelation": liveParentRelationMatched ? "matched" : "mismatched",
                    ],
                ],
            ]
            var phaseResult: [String: Any] = [
                "releaseId": release.id,
                "phase": phase,
                "phaseSource": phaseSource,
                "candidate": candidateValue,
                "runId": runId,
                "attempt": attempt,
                "simulator": ["deviceType": simulatorType, "runtime": simulatorRuntime],
                "checks": checks,
            ]
            if phase == "candidate" {
                phaseResult["upgradeContinuity"] = [
                    "status": "completed",
                    "savedConnectionLoaded": savedConnectionLoaded,
                    "rosterIdentityPreserved": rosterIdentityPreserved,
                ]
            }
            let recorded = try await fixturePost(
                fixtureBase + "/phase-result",
                token: token,
                body: phaseResult
            )
            XCTAssertTrue(recorded.ok, "The test fixture must retain each observed phase result.")
        }
    }

    private func fixturePost(_ urlString: String, token: String, body: [String: Any]) async throws -> FixtureReply {
        try await fixturePost(urlString, token: token, body: body, as: FixtureReply.self)
    }

    private func fixturePost<T: Decodable>(
        _ urlString: String,
        token: String,
        body: [String: Any],
        as type: T.Type
    ) async throws -> T {
        let url = try XCTUnwrap(URL(string: urlString))
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(token, forHTTPHeaderField: "X-Test-Fixture-Token")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        let http = try XCTUnwrap(response as? HTTPURLResponse)
        XCTAssertTrue((200..<300).contains(http.statusCode))
        return try JSONDecoder().decode(type, from: data)
    }

    private func fixtureGet<T: Decodable>(
        _ urlString: String,
        token: String,
        as type: T.Type
    ) async throws -> T {
        let url = try XCTUnwrap(URL(string: urlString))
        var request = URLRequest(url: url)
        request.setValue(token, forHTTPHeaderField: "X-Test-Fixture-Token")
        let (data, response) = try await URLSession.shared.data(for: request)
        let http = try XCTUnwrap(response as? HTTPURLResponse)
        XCTAssertTrue((200..<300).contains(http.statusCode))
        return try JSONDecoder().decode(type, from: data)
    }

    private func fixtureGetData(_ url: URL?) async throws -> Data {
        let url = try XCTUnwrap(url)
        var request = URLRequest(url: url)
        let (data, response) = try await URLSession.shared.data(for: request)
        let http = try XCTUnwrap(response as? HTTPURLResponse)
        XCTAssertTrue((200..<300).contains(http.statusCode))
        return data
    }

    private func connectionObject(_ connection: Connection) throws -> [String: Any] {
        let data = try JSONEncoder().encode(connection)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func jsonObject(_ string: String?) throws -> [String: Any] {
        let data = try XCTUnwrap(string?.data(using: .utf8))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func waitUntil(
        timeout: TimeInterval,
        condition: @escaping @MainActor () -> Bool
    ) async -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while ProcessInfo.processInfo.systemUptime < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(200))
        }
        return condition()
    }

    private func sequenceSummaryMatches(
        _ sequences: [RepliedSessionMessageSequence]?,
        messages: [RepliedMessage]?,
        sessionKey: String
    ) -> Bool {
        guard let sequences, let messages else { return false }
        let latestMessage = messages.filter { $0.sessionKey == sessionKey }.map(\.seq).max() ?? 0
        let latestSummary = sequences.first(where: { $0.sessionKey == sessionKey })?.latestMessageSeq ?? 0
        return latestSummary >= latestMessage
    }

    private func readMarkersApplied(
        _ page: RepliedMarkersPage?,
        state: RepliedState,
        user: String
    ) -> Bool {
        guard let page else { return false }
        let suffix = ":session-read-position"
        for marker in page.items where marker.userId == user && marker.scopeKey.hasSuffix(suffix) {
            let sessionKey = String(marker.scopeKey.dropLast(suffix.count))
            guard state.readMarkerBySession[sessionKey] == marker else { return false }
        }
        return true
    }
}
