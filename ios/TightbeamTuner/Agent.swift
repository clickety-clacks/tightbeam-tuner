import Foundation

struct Roster: Decodable {
    let sessions: [Agent]
}

struct Agent: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let state: String
    let parent: String?
    let archetype: String?
    let harness: String?
    let model: String?

    enum CodingKeys: String, CodingKey {
        case id = "sessionKey"
        case name = "displayName"
        case state
        case currentParent
        case topologyParent
        case archetype
        case harness
        case model
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        state = try values.decode(String.self, forKey: .state)
        parent = try values.decodeIfPresent(String.self, forKey: .currentParent)
            ?? values.decodeIfPresent(String.self, forKey: .topologyParent)
        archetype = try values.decodeIfPresent(String.self, forKey: .archetype)
        harness = try? values.decodeIfPresent(String.self, forKey: .harness)
        model = try? values.decodeIfPresent(String.self, forKey: .model)
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(name, forKey: .name)
        try values.encode(state, forKey: .state)
        try values.encodeIfPresent(parent, forKey: .currentParent)
        try values.encodeIfPresent(archetype, forKey: .archetype)
        try values.encodeIfPresent(harness, forKey: .harness)
        try values.encodeIfPresent(model, forKey: .model)
    }
}
