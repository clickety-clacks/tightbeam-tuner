import Foundation
import Observation

struct RepliedMessage: Decodable, Sendable, Equatable {
    let seq: Int
    let sessionKey, role: String
    let turnIncludesHuman: Bool
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        seq = try values.decode(Int.self, forKey: .seq)
        sessionKey = try values.decode(String.self, forKey: .sessionKey)
        role = try values.decode(String.self, forKey: .role)
        turnIncludesHuman = try values.decodeIfPresent(Bool.self, forKey: .turnIncludesHuman) ?? false
    }
    private enum CodingKeys: String, CodingKey { case seq, sessionKey, role, turnIncludesHuman }
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

struct RepliedMessagesPage: Decodable, Sendable { let items: [RepliedMessage] }
struct RepliedMarkersPage: Decodable, Sendable {
    struct Page: Decodable, Sendable { let hasMoreAfter: Bool; let newestCursor: String? }
    let items: [RepliedReadMarker]
    let page: Page
}

enum RepliedFrame: Sendable, Equatable {
    case subscriptionReady, message(RepliedMessage), readMarker(RepliedReadMarker), retired(String), serverError, ignored
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

struct RepliedState: Sendable {
    private(set) var latestReplyBySession: [String: Int] = [:]
    private(set) var readMarkerBySession: [String: RepliedReadMarker] = [:]
    private(set) var localReadMarkerBySession: [String: Int]
    private(set) var retiredSessionKeys: Set<String> = []
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
        _ = apply(message, shownSessionKey: nil)
    }
    mutating func apply(_ message: RepliedMessage, shownSessionKey: String?) -> Bool {
        guard message.role == "assistant", message.turnIncludesHuman else { return false }
        latestReplyBySession[message.sessionKey] = max(latestReplyBySession[message.sessionKey] ?? Int.min, message.seq)
        guard message.sessionKey == shownSessionKey else { return false }
        let previousMarker = localReadMarkerBySession[message.sessionKey] ?? Int.min
        let clearedMarker = max(previousMarker, message.seq)
        guard clearedMarker != previousMarker else { return false }
        localReadMarkerBySession[message.sessionKey] = clearedMarker
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
        _ = apply(frame, userID: userID, shownSessionKey: nil)
    }
    mutating func apply(_ frame: RepliedFrame, userID: String, shownSessionKey: String?) -> Bool {
        switch frame {
        case .message(let message): return apply(message, shownSessionKey: shownSessionKey)
        case .readMarker(let marker): apply(marker, userID: userID)
        case .retired(let key): retiredSessionKeys.insert(key)
        default: break
        }
        return false
    }
    func agents(from roster: [Agent]) -> [Agent] {
        roster.compactMap { agent -> (Agent, Int)? in
            guard !retiredSessionKeys.contains(agent.id), let reply = latestReplyBySession[agent.id] else { return nil }
            let marker = max(readMarkerBySession[agent.id]?.marker ?? Int.min,
                             localReadMarkerBySession[agent.id] ?? Int.min)
            if reply <= marker { return nil }
            return (agent, reply)
        }
        .sorted { $0.1 == $1.1 ? $0.0.id < $1.0.id : $0.1 > $1.1 }
        .map { $0.0 }
    }
}

struct RepliedTaskKey: Equatable {
    let gateway, user: String
    let sessionKeys: [String]
}

struct RepliedShownChat {
    let selectedSessionKey: String?
    let compactWidth: Bool
    let compactDetailSelected: Bool
    let sceneIsActive: Bool

    var sessionKeyOnScreen: String? {
        guard sceneIsActive, let selectedSessionKey,
              !compactWidth || compactDetailSelected else { return nil }
        return selectedSessionKey
    }
}

@MainActor @Observable final class RepliedFeed {
    private(set) var state = RepliedState()
    private(set) var shownSessionKey: String?
    private static let localReadMarkersKey = "repliedLocalReadMarkers"
    private let defaults: UserDefaults
    private var stateGateway: String?
    private var stateUser: String?

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
        shownSessionKey = key
    }

    func apply(_ frame: RepliedFrame, userID: String) {
        if state.apply(frame, userID: userID, shownSessionKey: shownSessionKey) {
            persistLocalReadMarkers()
        }
    }

    private func persistLocalReadMarkers() {
        defaults.set(state.localReadMarkerBySession, forKey: Self.localReadMarkersKey)
    }

    func run(gateway: String, user: String, sessionKeys: [String]) async {
        if stateGateway != gateway || stateUser != user {
            state = RepliedState(localReadMarkerBySession: Self.localReadMarkers(from: defaults))
            stateGateway = gateway
            stateUser = user
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
                    try await socket.send(.string(#"{"type":"subscribe","protocolVersion":2,"subscriptionId":"replied","filters":{"classes":["message.created","read_marker.updated","session.retired"]}}"#))
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
                            let limit = firstLoad ? nil : 100
                            firstLoad = false
                            snapshotTask = Task { await self.loadSnapshot(gateway: gateway, user: user, sessionKeys: sessionKeys, limit: limit) }
                        case .serverError: break receiveLoop
                        default: apply(frame, userID: user)
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
        fetchMessages: @escaping @Sendable (String, String, Int?) async -> [RepliedMessage]? = RepliedAPI.fetchMessages
    ) async {
        let markers = await fetchMarkers(gateway, user)
        guard !Task.isCancelled else { return }
        for marker in markers { state.apply(marker, userID: user) }
        guard !markers.isEmpty else { return }
        await withTaskGroup(of: (String, [RepliedMessage]?).self) { group in
            var next = min(6, sessionKeys.count)
            for key in sessionKeys.prefix(6) {
                group.addTask { (key, await fetchMessages(gateway, key, limit)) }
            }
            while let (key, messages) = await group.next() {
                guard !Task.isCancelled else { group.cancelAll(); return }
                if let messages {
                    for message in messages where message.sessionKey == key {
                        apply(.message(message), userID: user)
                    }
                }
                if next < sessionKeys.count {
                    let key = sessionKeys[next]
                    next += 1
                    group.addTask { (key, await fetchMessages(gateway, key, limit)) }
                }
            }
        }
    }
}

enum RepliedAPI {
    static func percentEncodedPathSegment(_ value: String) -> String {
        let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? ""
    }
    static func messagesURL(gateway: String, sessionKey: String, limit: Int?) -> URL? {
        guard let base = URL(string: gateway), var url = URLComponents(url: base, resolvingAgainstBaseURL: false) else { return nil }
        url.percentEncodedPath = "/api/sessions/\(percentEncodedPathSegment(sessionKey))/messages"
        url.queryItems = [URLQueryItem(name: "tail", value: "true")]
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
