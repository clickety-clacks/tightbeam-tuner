import Foundation

struct Roster: Decodable {
    let sessions: [Agent]
}

struct Agent: Decodable, Identifiable, Hashable {
    let id: String
    let name: String
    let state: String
    let parent: String?
    let archetype: String?

    enum CodingKeys: String, CodingKey {
        case id = "sessionKey"
        case name = "displayName"
        case state
        case currentParent
        case topologyParent
        case archetype
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        state = try values.decode(String.self, forKey: .state)
        parent = try values.decodeIfPresent(String.self, forKey: .currentParent)
            ?? values.decodeIfPresent(String.self, forKey: .topologyParent)
        archetype = try values.decodeIfPresent(String.self, forKey: .archetype)
    }
}
