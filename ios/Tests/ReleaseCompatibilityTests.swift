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
        let diagnostic: String?
    }

    private struct UpgradeReply: Decodable {
        let ok: Bool
        let savedConnectionLoaded: Bool
        let rosterIdentityPreserved: Bool
    }

    private struct RuntimeContext: Decodable {
        let releaseId: Int
    }

    private struct ReplySeed: Decodable {
        let userId: String
        let mainSessionKey: String
        let replySessionKey: String
        let parentSessionKey: String
        let assistantSequence: Int
        let initialReadMarker: Int
    }

    private struct ReplyChange: Decodable {
        let ok: Bool
        let correlatedReply: Bool
        let previousSequence: Int
        let assistantSequence: Int
        let previousMarker: Int
        let marker: Int
    }

    private struct CatchUpChange: Decodable {
        let ok: Bool
        let correlatedReply: Bool
        let previousSequence: Int
        let assistantSequence: Int
        let previousMarker: Int
        let marker: Int
        let changedSessionMatched: Bool
        let gatewayRestarted: Bool
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
            guard selected.ok else {
                XCTFail(selected.diagnostic ?? "The test fixture must start the digest-pinned published runtime.")
                return
            }
            let runtime = try await fixtureGet(
                fixtureBase + "/runtime-context",
                token: token,
                as: RuntimeContext.self
            )
            XCTAssertEqual(runtime.releaseId, release.id)

            let seed = try await fixturePost(
                fixtureBase + "/seed-replies",
                token: token,
                body: ["releaseId": release.id],
                as: ReplySeed.self
            )
            let user = seed.userId
            XCTAssertFalse(user.isEmpty)
            XCTAssertFalse(seed.replySessionKey.isEmpty)
            XCTAssertFalse(seed.parentSessionKey.isEmpty)
            XCTAssertGreaterThan(seed.assistantSequence, 0)

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

            let storeSuite = "TunerCompatibilityStore-\(release.id)"
            let repliesSuite = "TunerCompatibilityReplies-\(release.id)-\(phase)"
            guard let storeDefaults = UserDefaults(suiteName: storeSuite),
                  let repliesDefaults = UserDefaults(suiteName: repliesSuite) else {
                XCTFail("The isolated compatibility defaults suite is unavailable.")
                return
            }
            if phase == "baseline" {
                storeDefaults.removePersistentDomain(forName: storeSuite)
            }
            repliesDefaults.removePersistentDomain(forName: repliesSuite)
            let store = TunerStore(defaults: storeDefaults)
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
            let replySessionKey = seed.replySessionKey
            let replyAgent = store.agents.first { $0.id == replySessionKey }
            let rosterPassed = store.error == nil
                && replyAgent?.parent == seed.parentSessionKey
                && seed.parentSessionKey == seed.mainSessionKey
                && store.agents.contains { $0.id == seed.parentSessionKey }
            if let replyAgent { store.select(replyAgent) }

            let sequences = await RepliedAPI.fetchSequences(gateway: gateway, user: user)
            let sequenceEndpointAbsent: Bool
            if sequences == nil {
                sequenceEndpointAbsent = await self.sequenceEndpointReturnsNotFound(gateway: gateway, user: user)
            } else {
                sequenceEndpointAbsent = false
            }
            let markersData = try? await self.fixtureGetData(
                RepliedAPI.markersURL(gateway: gateway, user: user, after: nil)
            )
            let markers = markersData.flatMap { try? JSONDecoder().decode(RepliedMarkersPage.self, from: $0) }
            let messages = await RepliedAPI.fetchMessages(gateway: gateway, sessionKey: replySessionKey, limit: 500)
            let expectedLatestReply = messages?
                .filter { $0.sessionKey == replySessionKey && $0.role == "assistant" && $0.turnIncludesHuman }
                .map(\.seq).max()
            let sequenceSummaryValid: Bool
            if sequenceEndpointAbsent {
                sequenceSummaryValid = true
            } else {
                sequenceSummaryValid = self.sequenceSummaryMatches(
                    sequences, messages: messages, sessionKey: replySessionKey
                )
            }

            let feed = RepliedFeed(defaults: repliesDefaults)
            feed.activateConnection(connection)
            await feed.loadSnapshot(
                gateway: gateway,
                user: user,
                sessionKeys: store.agents.map(\.id),
                limit: 500,
                recentSessionKeys: store.recentAgents.map(\.id),
                mode: .initial
            )
            let initialClientStateMatched = expectedLatestReply != nil
                && feed.state.latestReplyBySession[replySessionKey] == expectedLatestReply
                && sequenceSummaryValid
            let initialReadMarker = markers?.items.first {
                $0.userId == user && $0.scopeKey == replySessionKey + ":session-read-position"
            }
            let readMarkerClientStateMatched = initialReadMarker != nil
                && feed.state.readMarkerBySession[replySessionKey] == initialReadMarker
                && initialReadMarker?.marker == seed.initialReadMarker
            let initialSyncPassed = messages?.isEmpty == false
                && expectedLatestReply != nil
                && initialClientStateMatched
            let readMarkerSyncPassed = markers != nil && readMarkerClientStateMatched

            var reconnectRefreshCompleted = false
            let task = Task {
                await feed.run(
                    connection: connection,
                    sessionKeys: { store.agents.map(\.id) },
                    recentSessionKeys: { store.recentAgents.map(\.id) },
                    onRosterEvent: { frame in
                        store.applyRosterEvent(frame)
                    },
                    onReconnect: {
                        await store.refresh()
                        reconnectRefreshCompleted = true
                    }
                )
            }

            let initialSubscriptionReady = await self.waitUntil(timeout: 30) {
                feed.subscriptionReadyCount >= 1 && feed.snapshotCompletedCount >= 1
            }
            XCTAssertTrue(initialSubscriptionReady)
            let initialSnapshotCount = feed.snapshotCompletedCount
            let liveChange = try await fixturePost(
                fixtureBase + "/post-reply",
                token: token,
                body: [
                    "releaseId": release.id,
                    "sessionKey": replySessionKey,
                    "stage": "live",
                ],
                as: ReplyChange.self
            )
            XCTAssertTrue(liveChange.ok)
            XCTAssertTrue(liveChange.correlatedReply)
            XCTAssertEqual(liveChange.previousSequence, seed.assistantSequence)
            XCTAssertEqual(liveChange.previousMarker, seed.initialReadMarker)
            XCTAssertGreaterThan(liveChange.assistantSequence, liveChange.previousSequence)
            XCTAssertGreaterThan(liveChange.marker, liveChange.previousMarker)
            let liveEventObserved = await self.waitUntil(timeout: 90) {
                feed.state.latestReplyBySession[replySessionKey] == liveChange.assistantSequence
                    && feed.state.readMarkerBySession[replySessionKey]?.marker == liveChange.marker
                    && feed.messageCreatedSequenceBySession[replySessionKey] == liveChange.assistantSequence
                    && feed.readMarkerEventBySession[replySessionKey] == liveChange.marker
            }
            let liveStateMatched = liveEventObserved
                && feed.state.latestReplyBySession[replySessionKey] == liveChange.assistantSequence
                && feed.state.readMarkerBySession[replySessionKey]?.marker == liveChange.marker
                && feed.snapshotCompletedCount == initialSnapshotCount
            let priorReadyCount = feed.subscriptionReadyCount
            let priorSnapshotCount = feed.snapshotCompletedCount
            let catchup = try await self.fixturePost(
                fixtureBase + "/catch-up",
                token: token,
                body: [
                    "releaseId": release.id,
                    "sessionKey": replySessionKey,
                ],
                as: CatchUpChange.self
            )
            XCTAssertTrue(catchup.ok)
            XCTAssertTrue(catchup.correlatedReply)
            XCTAssertTrue(catchup.changedSessionMatched)
            XCTAssertTrue(catchup.gatewayRestarted)
            XCTAssertEqual(catchup.previousSequence, liveChange.assistantSequence)
            XCTAssertEqual(catchup.previousMarker, liveChange.marker)
            XCTAssertGreaterThan(catchup.assistantSequence, catchup.previousSequence)
            XCTAssertGreaterThan(catchup.marker, catchup.previousMarker)
            let reconnectCompleted = await self.waitUntil(timeout: 90) {
                feed.subscriptionReadyCount > priorReadyCount
                    && feed.snapshotCompletedCount > priorSnapshotCount
                    && reconnectRefreshCompleted
                    && feed.state.latestReplyBySession[replySessionKey] == catchup.assistantSequence
                    && feed.state.readMarkerBySession[replySessionKey]?.marker == catchup.marker
            }
            let catchupStateMatched = reconnectCompleted
                && feed.state.latestReplyBySession[replySessionKey] == catchup.assistantSequence
                && feed.state.readMarkerBySession[replySessionKey]?.marker == catchup.marker
            task.cancel()
            try? await Task.sleep(for: .milliseconds(150))

            let checks: [String: Any] = [
                "roster": [
                    "status": rosterPassed ? "passed" : "failed",
                    "implementation": "production-client",
                    "observed": [
                        "sessionIdentity": replyAgent == nil ? "missing" : "matched",
                        "parentRelation": replyAgent?.parent == seed.parentSessionKey && store.agents.contains { $0.id == seed.parentSessionKey }
                            ? "matched" : "mismatched",
                        "sessionCount": store.agents.count,
                    ],
                ],
                "initial_message_sync": [
                    "status": initialSyncPassed ? "passed" : "failed",
                    "implementation": "production-client",
                    "observed": [
                        "sequenceSummaryRoute": sequenceEndpointAbsent ? "not-supported" : "available",
                        "sequenceSummaryDecoded": sequences != nil,
                        "sequenceSummaryValid": sequenceSummaryValid,
                        "messagePageDecoded": messages != nil,
                        "clientStateMatched": initialClientStateMatched,
                        "turnIncludesHuman": expectedLatestReply != nil,
                        "sessionCount": store.agents.count,
                        "messageCount": messages?.count ?? 0,
                        "latestReplySequence": expectedLatestReply as Any? ?? NSNull(),
                    ],
                ],
                "read_marker_sync": [
                    "status": readMarkerSyncPassed ? "passed" : "failed",
                    "implementation": "production-client",
                    "observed": [
                        "pageDecoded": markers != nil,
                        "clientStateMatched": readMarkerClientStateMatched,
                        "markerCount": markers?.items.count ?? 0,
                        "replySessionMarkerPresent": initialReadMarker != nil,
                    ],
                ],
                "catch_up": [
                    "status": catchupStateMatched ? "passed" : "failed",
                    "implementation": "production-client",
                    "observed": [
                        "gatewayRestarted": catchup.gatewayRestarted,
                        "reconnected": reconnectRefreshCompleted,
                        "subscriptionReadyCount": feed.subscriptionReadyCount,
                        "snapshotCompletedCount": feed.snapshotCompletedCount,
                        "snapshotReadCompleted": reconnectCompleted,
                        "clientStateMatched": catchupStateMatched,
                        "changeEventClass": "message.created",
                        "correlatedReply": catchup.correlatedReply,
                        "changedSessionMatched": catchup.changedSessionMatched,
                        "previousSequence": catchup.previousSequence,
                        "changedSequence": catchup.assistantSequence,
                        "previousMarker": catchup.previousMarker,
                        "changedMarker": catchup.marker,
                    ],
                ],
                "live_subscription": [
                    "status": liveChange.ok && liveChange.correlatedReply && liveStateMatched
                        ? "passed" : "failed",
                    "implementation": "production-client",
                    "observed": [
                        "eventClass": liveEventObserved ? "message.created" : "not-observed",
                        "observedByClient": liveEventObserved,
                        "sessionIdentity": liveStateMatched ? "matched" : "missing",
                        "stateMatched": liveStateMatched,
                        "correlatedReply": liveChange.correlatedReply,
                        "previousReplySequence": liveChange.previousSequence,
                        "replySequence": liveChange.assistantSequence,
                        "previousMarker": liveChange.previousMarker,
                        "marker": liveChange.marker,
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
        return latestMessage > 0 && latestSummary >= latestMessage
    }

    private func sequenceEndpointReturnsNotFound(gateway: String, user: String) async -> Bool {
        guard let url = RepliedAPI.sequencesURL(gateway: gateway, user: user),
              let (_, response) = try? await URLSession.shared.data(from: url),
              let http = response as? HTTPURLResponse else { return false }
        return http.statusCode == 404
    }

}
