import Foundation
import Observation

struct RepliedMessage: Decodable, Sendable, Equatable {
    let seq: Int
    let sessionKey, role: String
    let clientMessageId: String?
    let turnIncludesHuman: Bool
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        seq = try values.decode(Int.self, forKey: .seq)
        sessionKey = try values.decode(String.self, forKey: .sessionKey)
        role = try values.decode(String.self, forKey: .role)
        clientMessageId = try values.decodeIfPresent(String.self, forKey: .clientMessageId)
        turnIncludesHuman = try values.decodeIfPresent(Bool.self, forKey: .turnIncludesHuman) ?? false
    }
    private enum CodingKeys: String, CodingKey { case seq, sessionKey, role, clientMessageId, turnIncludesHuman }
}

struct RepliedReadMarker: Decodable, Sendable, Equatable {
    let userId, scopeKey: String
    let marker: Int?
    let updatedAt: Int
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        userId = try values.decode(String.self, forKey: .userId)
        scopeKey = try values.decode(String.self, forKey: .scopeKey)
        marker = (try? values.decode(Int.self, forKey: .marker))
            ?? (try? values.decode(String.self, forKey: .marker)).flatMap(Int.init)
        updatedAt = try values.decode(Int.self, forKey: .updatedAt)
    }
    private enum CodingKeys: String, CodingKey { case userId, scopeKey, marker, updatedAt }
}

struct RepliedMessagesPage: Decodable, Sendable {
    struct Page: Decodable, Sendable {
        let oldestCursor: String?
        let hasMoreBefore: Bool?
    }
    let items: [RepliedMessage]
    let page: Page?
}
struct RepliedMarkersPage: Decodable, Sendable {
    struct Page: Decodable, Sendable { let hasMoreAfter: Bool; let newestCursor: String? }
    let items: [RepliedReadMarker]
    let page: Page
}

enum RepliedFrame: Sendable, Equatable {
    case subscriptionReady, message(RepliedMessage), readMarker(RepliedReadMarker)
    case sessionSpawned(Agent), sessionUpdated(Agent), sessionHarnessChanged(Agent)
    case retired(String), serverError, ignored

    var changesRoster: Bool {
        switch self {
        case .sessionSpawned, .sessionUpdated, .sessionHarnessChanged, .retired: return true
        default: return false
        }
    }

    static func decode(_ data: Data) -> Self {
        let decoder = JSONDecoder()
        guard let header = try? decoder.decode(FrameHeader.self, from: data) else { return .ignored }
        switch header.type {
        case "subscription_ready":
            return header.subscriptionId == "replied" ? .subscriptionReady : .ignored
        case "error": return .serverError
        case "change":
            switch header.changeClass {
            case "message.created":
                guard let body = try? decoder.decode(Envelope<RepliedMessage>.self, from: data) else { return .ignored }
                return .message(body.payload)
            case "read_marker.updated":
                guard let body = try? decoder.decode(Envelope<RepliedReadMarker>.self, from: data) else { return .ignored }
                return .readMarker(body.payload)
            case "session.spawned":
                guard let body = try? decoder.decode(Envelope<Agent>.self, from: data) else { return .ignored }
                return .sessionSpawned(body.payload)
            case "session.updated":
                guard let body = try? decoder.decode(Envelope<Agent>.self, from: data) else { return .ignored }
                return .sessionUpdated(body.payload)
            case "session.harness_changed":
                guard let body = try? decoder.decode(Envelope<Agent>.self, from: data) else { return .ignored }
                return .sessionHarnessChanged(body.payload)
            case "session.retired":
                guard let key = header.refs?.sessionKey else { return .ignored }
                return .retired(key)
            default: return .ignored
            }
        default: return .ignored
        }
    }
}

private struct Envelope<T: Decodable>: Decodable { let payload: T }
private struct FrameHeader: Decodable {
    struct Refs: Decodable { let sessionKey: String? }
    let type: String
    let subscriptionId, changeClass: String?
    let refs: Refs?
    private enum CodingKeys: String, CodingKey {
        case type, subscriptionId, refs
        case changeClass = "class"
    }
}

struct RepliedSubscriptionState: Sendable {
    private(set) var hasReceivedReady = false

    mutating func subscriptionReadyNeedsCatchUp() -> Bool {
        let needsCatchUp = hasReceivedReady
        hasReceivedReady = true
        return needsCatchUp
    }

    mutating func reset() {
        hasReceivedReady = false
    }
}

enum RepliesRowIndicator: Equatable {
    case waiting
    case reply
}

struct RepliedState: Sendable {
    private(set) var latestReplyBySession: [String: Int] = [:]
    private(set) var readMarkerBySession: [String: RepliedReadMarker] = [:]
    private(set) var localReadMarkerBySession: [String: Int]
    private(set) var retiredSessionKeys: Set<String> = []
    private struct PendingPrompt: Sendable {
        let sessionKey: String
        var promptSequence: Int?
    }
    private var pendingPromptsByID: [String: PendingPrompt] = [:]
    private var observedPromptSequencesBySession: [String: [String: Int]] = [:]
    private var observedPromptOrderBySession: [String: [String]] = [:]
    private var completedPromptIDsBySession: [String: Set<String>] = [:]
    private var completedPromptOrderBySession: [String: [String]] = [:]
    private var latestAssistantSequenceBySession: [String: Int] = [:]
    private var latestShownReplySequenceBySession: [String: Int] = [:]
    private(set) var pendingOrderBySession: [String: Int] = [:]
    private var nextPendingOrder = 0
    private static let retainedPromptPositionsPerSession = 128

    init(localReadMarkerBySession: [String: Int] = [:]) {
        self.localReadMarkerBySession = localReadMarkerBySession
    }
    mutating func markOpened(_ key: String) -> Int? {
        guard let reply = latestReplyBySession[key] else { return nil }
        let marker = max(reply, localReadMarkerBySession[key] ?? Int.min)
        localReadMarkerBySession[key] = marker
        return marker
    }
    mutating func apply(_ message: RepliedMessage) {
        _ = apply(message, shownSessionKey: nil, regularWidthShownChat: false)
    }
    mutating func apply(
        _ message: RepliedMessage,
        shownSessionKey: String?,
        regularWidthShownChat: Bool = false
    ) -> Bool {
        var readMarkerChanged = false
        if message.role == "user", let correlationID = message.clientMessageId {
            let promptSequence = rememberPromptPosition(
                sessionKey: message.sessionKey,
                correlationID: correlationID,
                sequence: message.seq
            )
            let latestAssistantSequence = latestAssistantSequenceBySession[message.sessionKey, default: Int.min]
            let alreadyCompleted = latestAssistantSequence > promptSequence
            if var prompt = pendingPromptsByID[correlationID], prompt.sessionKey == message.sessionKey {
                if prompt.promptSequence == nil { prompt.promptSequence = promptSequence }
                pendingPromptsByID[correlationID] = prompt
                if alreadyCompleted {
                    rememberCompletedPrompt(sessionKey: message.sessionKey, correlationID: correlationID)
                    removePendingPrompt(correlationID, sessionKey: message.sessionKey)
                    if !regularWidthShownChat,
                       latestShownReplySequenceBySession[message.sessionKey, default: Int.min] > promptSequence {
                        readMarkerChanged = advanceLocalReadMarkerIfSafe(message.sessionKey)
                    }
                }
            } else if alreadyCompleted {
                rememberCompletedPrompt(sessionKey: message.sessionKey, correlationID: correlationID)
            }
        }

        var completedPendingPrompt = false
        if message.role == "assistant" {
            latestAssistantSequenceBySession[message.sessionKey] = max(
                latestAssistantSequenceBySession[message.sessionKey] ?? Int.min,
                message.seq
            )
            let completedPrompts = pendingPromptsByID.compactMap { correlationID, prompt -> String? in
                guard prompt.sessionKey == message.sessionKey,
                      let promptSequence = prompt.promptSequence,
                      message.seq > promptSequence else { return nil }
                return correlationID
            }
            completedPendingPrompt = !completedPrompts.isEmpty
            for correlationID in completedPrompts {
                rememberCompletedPrompt(sessionKey: message.sessionKey, correlationID: correlationID)
                removePendingPrompt(correlationID, sessionKey: message.sessionKey)
            }
        }

        guard message.role == "assistant", message.turnIncludesHuman else { return readMarkerChanged }
        latestReplyBySession[message.sessionKey] = max(latestReplyBySession[message.sessionKey] ?? Int.min, message.seq)
        guard message.sessionKey == shownSessionKey else { return readMarkerChanged }
        latestShownReplySequenceBySession[message.sessionKey] = max(
            latestShownReplySequenceBySession[message.sessionKey] ?? Int.min,
            message.seq
        )
        guard !(regularWidthShownChat && completedPendingPrompt) else { return readMarkerChanged }
        return advanceLocalReadMarkerIfSafe(message.sessionKey) || readMarkerChanged
    }

    private mutating func rememberPromptPosition(sessionKey: String, correlationID: String, sequence: Int) -> Int {
        var positions = observedPromptSequencesBySession[sessionKey, default: [:]]
        let existingSequence = positions[correlationID]
        let position = min(existingSequence ?? sequence, sequence)
        positions[correlationID] = position

        var order = observedPromptOrderBySession[sessionKey, default: []]
        if existingSequence == nil {
            order.append(correlationID)
            while order.count > Self.retainedPromptPositionsPerSession {
                positions.removeValue(forKey: order.removeFirst())
            }
        }
        observedPromptSequencesBySession[sessionKey] = positions
        observedPromptOrderBySession[sessionKey] = order
        return position
    }

    private mutating func removePendingPrompt(_ correlationID: String, sessionKey: String) {
        guard pendingPromptsByID[correlationID]?.sessionKey == sessionKey else { return }
        pendingPromptsByID.removeValue(forKey: correlationID)
        if !pendingPromptsByID.values.contains(where: { $0.sessionKey == sessionKey }) {
            pendingOrderBySession.removeValue(forKey: sessionKey)
        }
    }

    private mutating func rememberCompletedPrompt(sessionKey: String, correlationID: String) {
        var completed = completedPromptIDsBySession[sessionKey, default: []]
        guard completed.insert(correlationID).inserted else { return }

        var order = completedPromptOrderBySession[sessionKey, default: []]
        order.append(correlationID)
        while order.count > Self.retainedPromptPositionsPerSession {
            completed.remove(order.removeFirst())
        }
        completedPromptIDsBySession[sessionKey] = completed
        completedPromptOrderBySession[sessionKey] = order
    }

    private mutating func advanceLocalReadMarkerIfSafe(_ sessionKey: String) -> Bool {
        guard let shownReply = latestShownReplySequenceBySession[sessionKey] else { return false }
        let hasEarlierPendingPrompt = pendingPromptsByID.values.contains { prompt in
            guard prompt.sessionKey == sessionKey else { return false }
            guard let promptSequence = prompt.promptSequence else { return true }
            return shownReply <= promptSequence
        }
        guard !hasEarlierPendingPrompt else { return false }

        let previousMarker = localReadMarkerBySession[sessionKey] ?? Int.min
        guard shownReply > previousMarker else { return false }
        localReadMarkerBySession[sessionKey] = shownReply
        return true
    }
    mutating func apply(_ marker: RepliedReadMarker, userID: String) {
        let suffix = ":session-read-position"
        guard marker.userId == userID, marker.scopeKey.hasSuffix(suffix) else { return }
        let key = String(marker.scopeKey.dropLast(suffix.count))
        if let current = readMarkerBySession[key], current.updatedAt > marker.updatedAt { return }
        readMarkerBySession[key] = marker
    }
    mutating func apply(_ frame: RepliedFrame, userID: String) {
        _ = apply(frame, userID: userID, shownSessionKey: nil, regularWidthShownChat: false)
    }
    mutating func apply(
        _ frame: RepliedFrame,
        userID: String,
        shownSessionKey: String?,
        regularWidthShownChat: Bool = false
    ) -> Bool {
        switch frame {
        case .message(let message):
            return apply(message, shownSessionKey: shownSessionKey,
                         regularWidthShownChat: regularWidthShownChat)
        case .readMarker(let marker): apply(marker, userID: userID)
        case .sessionSpawned(let agent), .sessionUpdated(let agent), .sessionHarnessChanged(let agent):
            retiredSessionKeys.remove(agent.id)
        case .retired(let key):
            retiredSessionKeys.insert(key)
        default: break
        }
        return false
    }

    mutating func acceptPrompt(sessionKey: String, correlationID: String) {
        guard !retiredSessionKeys.contains(sessionKey),
              pendingPromptsByID[correlationID] == nil,
              !completedPromptIDsBySession[sessionKey, default: []].contains(correlationID) else { return }
        let promptSequence = observedPromptSequencesBySession[sessionKey]?[correlationID]
        if let promptSequence,
           let latestAssistant = latestAssistantSequenceBySession[sessionKey],
           latestAssistant > promptSequence { return }
        if !pendingPromptsByID.values.contains(where: { $0.sessionKey == sessionKey }) {
            nextPendingOrder += 1
            pendingOrderBySession[sessionKey] = nextPendingOrder
        }
        pendingPromptsByID[correlationID] = PendingPrompt(
            sessionKey: sessionKey,
            promptSequence: promptSequence
        )
    }

    mutating func failPrompt(sessionKey: String, correlationID: String) {
        guard pendingPromptsByID[correlationID]?.sessionKey == sessionKey else { return }
        removePendingPrompt(correlationID, sessionKey: sessionKey)
    }

    func isWaitingForReply(_ sessionKey: String) -> Bool {
        pendingPromptsByID.values.contains(where: { $0.sessionKey == sessionKey })
    }

    func pendingPromptIDs(for sessionKey: String) -> Set<String> {
        Set(pendingPromptsByID.compactMap { correlationID, prompt in
            prompt.sessionKey == sessionKey ? correlationID : nil
        })
    }

    func rowIndicator(for sessionKey: String) -> RepliesRowIndicator? {
        guard !retiredSessionKeys.contains(sessionKey) else { return nil }
        if isWaitingForReply(sessionKey) { return .waiting }
        guard let reply = latestReplyBySession[sessionKey] else { return nil }
        let marker = max(readMarkerBySession[sessionKey]?.marker ?? Int.min,
                         localReadMarkerBySession[sessionKey] ?? Int.min)
        return reply > marker ? .reply : nil
    }

    func agents(from roster: [Agent]) -> [Agent] {
        roster.compactMap { agent -> (Agent, RepliesRowIndicator, Int, Int)? in
            guard let indicator = rowIndicator(for: agent.id) else { return nil }
            return (agent, indicator, pendingOrderBySession[agent.id] ?? Int.min,
                    latestReplyBySession[agent.id] ?? Int.min)
        }
        .sorted {
            if $0.1 != $1.1 { return $0.1 == .waiting }
            let leftOrder = $0.1 == .waiting ? $0.2 : $0.3
            let rightOrder = $1.1 == .waiting ? $1.2 : $1.3
            return leftOrder == rightOrder ? $0.0.id < $1.0.id : leftOrder > rightOrder
        }
        .map { $0.0 }
    }

    func agentsInMainSection(from roster: [Agent]) -> [Agent] {
        roster.filter { !isWaitingForReply($0.id) }
    }
}

struct RepliedTaskKey: Equatable {
    let gateway, user: String
    let sessionKeys: [String]
}

struct RepliedShownChat {
    private static let regularWidthPrefix = "\u{001F}regular-width:"
    private static let inactiveRegularWidthPrefix = "\u{001F}regular-width-inactive:"
    private static let escapedSessionKeyPrefix = "\u{001F}session-key:"

    let selectedSessionKey: String?
    let compactWidth: Bool
    let compactDetailSelected: Bool
    let sceneIsActive: Bool

    /// ContentView's existing String? callback carries this selection token only to RepliedFeed.
    /// The prefix preserves regular-width state across the existing String? seam without changing ContentView.
    var sessionKeyOnScreen: String? {
        guard let selectedSessionKey,
              !compactWidth || (compactDetailSelected && sceneIsActive) else { return nil }
        if compactWidth {
            if selectedSessionKey.hasPrefix(Self.regularWidthPrefix)
                || selectedSessionKey.hasPrefix(Self.inactiveRegularWidthPrefix)
                || selectedSessionKey.hasPrefix(Self.escapedSessionKeyPrefix) {
                return Self.escapedSessionKeyPrefix + selectedSessionKey
            }
            return selectedSessionKey
        }
        let prefix = sceneIsActive ? Self.regularWidthPrefix : Self.inactiveRegularWidthPrefix
        return prefix + selectedSessionKey
    }

    static func decodeSessionKey(_ value: String?) -> (sessionKey: String?, regularWidth: Bool, visible: Bool) {
        guard let value else { return (nil, false, false) }
        if value.hasPrefix(escapedSessionKeyPrefix) {
            return (String(value.dropFirst(escapedSessionKeyPrefix.count)), false, true)
        }
        if value.hasPrefix(inactiveRegularWidthPrefix) {
            return (String(value.dropFirst(inactiveRegularWidthPrefix.count)), true, false)
        }
        if value.hasPrefix(regularWidthPrefix) {
            return (String(value.dropFirst(regularWidthPrefix.count)), true, true)
        }
        return (value, false, true)
    }
}

@MainActor @Observable final class RepliedFeed {
    private(set) var state = RepliedState()
    private(set) var shownSessionKey: String?
    private static let localReadMarkersKey = "repliedLocalReadMarkers"
    private let defaults: UserDefaults
    private var stateGateway: String?
    private var stateUser: String?
    private var subscriptionState = RepliedSubscriptionState()
    private var shownChatIsRegularWidth = false
    private var regularWidthSelectedSessionKey: String?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        state = RepliedState(localReadMarkerBySession: Self.localReadMarkers(from: defaults))
    }

    private static func localReadMarkers(from defaults: UserDefaults) -> [String: Int] {
        defaults.dictionary(forKey: localReadMarkersKey)?.compactMapValues { $0 as? Int } ?? [:]
    }

    func markOpened(_ key: String) {
        guard state.markOpened(key) != nil else { return }
        persistLocalReadMarkers()
    }

    func updateShownSessionKey(_ key: String?) {
        let selection = RepliedShownChat.decodeSessionKey(key)
        if let previousSessionKey = regularWidthSelectedSessionKey,
           previousSessionKey != selection.sessionKey {
            markOpened(previousSessionKey)
        }
        shownSessionKey = selection.visible ? selection.sessionKey : nil
        shownChatIsRegularWidth = selection.regularWidth && selection.sessionKey != nil
        regularWidthSelectedSessionKey = shownChatIsRegularWidth ? selection.sessionKey : nil
    }

    func apply(_ frame: RepliedFrame, userID: String) {
        apply(frame, userID: userID, shownSessionKey: shownSessionKey)
    }

    private func apply(_ frame: RepliedFrame, userID: String, shownSessionKey: String?) {
        if state.apply(frame, userID: userID, shownSessionKey: shownSessionKey,
                       regularWidthShownChat: shownChatIsRegularWidth) {
            persistLocalReadMarkers()
        }
    }

    func observePromptStatus(_ status: ChatHostBridge.Status, sessionKey: String, correlationID: String) {
        switch status {
        case .accepted, .delivered:
            state.acceptPrompt(sessionKey: sessionKey, correlationID: correlationID)
        case .failed(_):
            state.failPrompt(sessionKey: sessionKey, correlationID: correlationID)
        case .sending, .uncertain, .interrupted:
            break
        }
    }

    private func persistLocalReadMarkers() {
        defaults.set(state.localReadMarkerBySession, forKey: Self.localReadMarkersKey)
    }

    func run(
        gateway: String,
        user: String,
        sessionKeys: [String],
        onRosterEvent: @escaping @MainActor (RepliedFrame) -> Void,
        onReconnect: @escaping @MainActor () async -> Void
    ) async {
        if stateGateway != gateway || stateUser != user {
            state = RepliedState(localReadMarkerBySession: Self.localReadMarkers(from: defaults))
            stateGateway = gateway
            stateUser = user
            subscriptionState.reset()
        }
        guard let url = RepliedAPI.webSocketURL(gateway: gateway) else { return }
        var retry: UInt64 = 1
        var firstLoad = true
        while !Task.isCancelled {
            let socket = URLSession.shared.webSocketTask(with: url)
            socket.resume()
            var snapshotTask: Task<Void, Never>?
            var ready = false
            await withTaskCancellationHandler {
                do {
                    try await socket.send(.string(RepliedAPI.subscriptionFrame))
                    receiveLoop: while !Task.isCancelled {
                        let message = try await socket.receive()
                        guard !Task.isCancelled else { break }
                        guard case .string(let text) = message else { continue }
                        let frame = RepliedFrame.decode(Data(text.utf8))
                        switch frame {
                        case .subscriptionReady:
                            guard !ready else { continue }
                            ready = true
                            retry = 1
                            if subscriptionState.subscriptionReadyNeedsCatchUp() { await onReconnect() }
                            let limit = firstLoad ? nil : 100
                            firstLoad = false
                            snapshotTask = Task { await self.loadSnapshot(gateway: gateway, user: user, sessionKeys: sessionKeys, limit: limit) }
                        case .serverError: break receiveLoop
                        default:
                            apply(frame, userID: user)
                            if frame.changesRoster { onRosterEvent(frame) }
                        }
                    }
                } catch { }
            } onCancel: { socket.cancel(with: .goingAway, reason: nil) }
            snapshotTask?.cancel()
            socket.cancel(with: .goingAway, reason: nil)
            guard !Task.isCancelled else { return }
            do { try await Task.sleep(nanoseconds: retry * 1_000_000_000) } catch { return }
            retry = min(retry * 2, 30)
        }
    }

    func loadSnapshot(
        gateway: String,
        user: String,
        sessionKeys: [String],
        limit: Int?,
        fetchMarkers: @escaping @Sendable (String, String) async -> [RepliedReadMarker] = RepliedAPI.fetchMarkers,
        fetchMessages: @escaping @Sendable (String, String, Int?) async -> [RepliedMessage]? = RepliedAPI.fetchMessages,
        fetchPendingMessages: @escaping @Sendable (String, String, Set<String>) async -> [RepliedMessage]? = RepliedAPI.fetchPendingMessages
    ) async {
        let markers = await fetchMarkers(gateway, user)
        guard !Task.isCancelled else { return }
        for marker in markers { state.apply(marker, userID: user) }
        let keysToFetch = markers.isEmpty
            ? sessionKeys.filter { state.isWaitingForReply($0) }
            : sessionKeys
        guard !keysToFetch.isEmpty else { return }
        let requests = keysToFetch.map { key -> (String, Set<String>, Int?) in
            let promptIDs = state.pendingPromptIDs(for: key)
            return (key, promptIDs, promptIDs.isEmpty ? (limit ?? 500) : nil)
        }
        await withTaskGroup(of: (String, [RepliedMessage]?).self) { group in
            var next = min(6, requests.count)
            for request in requests.prefix(6) {
                group.addTask {
                    if request.1.isEmpty {
                        return (request.0, await fetchMessages(gateway, request.0, request.2))
                    }
                    return (request.0, await fetchPendingMessages(gateway, request.0, request.1))
                }
            }
            while let (key, messages) = await group.next() {
                guard !Task.isCancelled else { group.cancelAll(); return }
                if let messages {
                    for message in messages where message.sessionKey == key {
                        apply(.message(message), userID: user)
                    }
                }
                if next < requests.count {
                    let request = requests[next]
                    next += 1
                    group.addTask {
                        if request.1.isEmpty {
                            return (request.0, await fetchMessages(gateway, request.0, request.2))
                        }
                        return (request.0, await fetchPendingMessages(gateway, request.0, request.1))
                    }
                }
            }
        }
    }
}

enum RepliedAPI {
    static let subscriptionFrame = #"{"type":"subscribe","protocolVersion":2,"subscriptionId":"replied","filters":{"classes":["message.created","read_marker.updated","session.spawned","session.updated","session.harness_changed","session.retired"]}}"#

    static func percentEncodedPathSegment(_ value: String) -> String {
        let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? ""
    }
    static func messagesURL(gateway: String, sessionKey: String, limit: Int?, before: String? = nil) -> URL? {
        guard let base = URL(string: gateway), var url = URLComponents(url: base, resolvingAgainstBaseURL: false) else { return nil }
        url.percentEncodedPath = "/api/sessions/\(percentEncodedPathSegment(sessionKey))/messages"
        url.queryItems = before.map { [URLQueryItem(name: "before", value: $0)] }
            ?? [URLQueryItem(name: "tail", value: "true")]
        if let limit { url.queryItems?.append(URLQueryItem(name: "limit", value: String(limit))) }
        return url.url
    }
    static func markersURL(gateway: String, user: String, after: String?) -> URL? {
        guard let base = URL(string: gateway), var url = URLComponents(url: base, resolvingAgainstBaseURL: false) else { return nil }
        url.path = "/api/read-markers"
        url.queryItems = [URLQueryItem(name: "asUser", value: user), URLQueryItem(name: "limit", value: "500")]
        if let after { url.queryItems?.append(URLQueryItem(name: "after", value: after)) }
        return url.url
    }
    static func webSocketURL(gateway: String) -> URL? {
        guard let base = URL(string: gateway), var url = URLComponents(url: base, resolvingAgainstBaseURL: false),
              url.scheme == "http" || url.scheme == "https" else { return nil }
        url.scheme = url.scheme == "https" ? "wss" : "ws"
        url.path = "/ws/changes"
        url.queryItems = [URLQueryItem(name: "protocolVersion", value: "2")]
        return url.url
    }

    static func fetchMessages(gateway: String, sessionKey: String, limit: Int?) async -> [RepliedMessage]? {
        guard let url = messagesURL(gateway: gateway, sessionKey: sessionKey, limit: limit),
              let data = await get(url),
              let page = try? JSONDecoder().decode(RepliedMessagesPage.self, from: data) else { return nil }
        return page.items
    }

    static func fetchPendingMessages(
        gateway: String,
        sessionKey: String,
        promptIDs: Set<String>
    ) async -> [RepliedMessage]? {
        guard !promptIDs.isEmpty else { return [] }
        var unmatchedPromptIDs = promptIDs
        var messages: [RepliedMessage] = []
        var before: String?
        var visitedCursors: Set<String> = []

        while true {
            guard let url = messagesURL(gateway: gateway, sessionKey: sessionKey, limit: 500, before: before),
                  let data = await get(url),
                  let page = try? JSONDecoder().decode(RepliedMessagesPage.self, from: data) else { return nil }
            messages.append(contentsOf: page.items)
            for message in page.items where message.role == "user" {
                if let clientMessageId = message.clientMessageId {
                    unmatchedPromptIDs.remove(clientMessageId)
                }
            }

            guard !unmatchedPromptIDs.isEmpty,
                  page.page?.hasMoreBefore == true,
                  let oldestCursor = page.page?.oldestCursor else {
                return messages.sorted { $0.seq < $1.seq }
            }
            guard visitedCursors.insert(oldestCursor).inserted else {
                return messages.sorted { $0.seq < $1.seq }
            }
            before = oldestCursor
        }
    }
    static func fetchMarkers(gateway: String, user: String) async -> [RepliedReadMarker] {
        var markers: [RepliedReadMarker] = []
        var after: String?
        while let url = markersURL(gateway: gateway, user: user, after: after),
              let data = await get(url),
              let page = try? JSONDecoder().decode(RepliedMarkersPage.self, from: data) {
            markers.append(contentsOf: page.items)
            guard page.page.hasMoreAfter, let cursor = page.page.newestCursor else { break }
            after = cursor
        }
        return markers
    }

    private static func get(_ url: URL) async -> Data? {
        guard let result = try? await URLSession.shared.data(from: url),
              let response = result.1 as? HTTPURLResponse,
              (200..<300).contains(response.statusCode) else { return nil }
        return result.0
    }
}
