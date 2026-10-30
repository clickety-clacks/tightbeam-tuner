import XCTest
@testable import TightbeamTuner

final class AgentSectionCountsTests: XCTestCase {
    func testCountsApplyTextAndArchetypeFiltersToListedAgentsAndTree() throws {
        let agents = try makeAgents()
        let root = try XCTUnwrap(agents.first { $0.id == "agent:root" })
        let matching = try XCTUnwrap(agents.first { $0.id == "agent:ios-coder" })
        let otherCoder = try XCTUnwrap(agents.first { $0.id == "agent:web-coder" })
        let otherArchetype = try XCTUnwrap(agents.first { $0.id == "agent:ios-mentor" })
        let filter = AgentListFilter(words: ["ios"], archetypes: ["coder"])

        let counts = AgentSectionCounts(
            replied: [root, matching, otherCoder, otherArchetype],
            recent: [root, matching, otherCoder],
            agents: agents,
            filter: filter
        )

        XCTAssertEqual(counts.replied, 1)
        XCTAssertEqual(counts.recent, 1)
        XCTAssertEqual(counts.agents, 1)
    }

    func testNoFilterCountsEveryAgentInTheTree() throws {
        let agents = try makeAgents()
        let filter = AgentListFilter(words: [], archetypes: [])
        let counts = AgentSectionCounts(replied: [], recent: [], agents: agents, filter: filter)

        XCTAssertEqual(counts.agents, agents.count)
    }

    private func makeAgents() throws -> [Agent] {
        let data = Data(#"""
        {
          "sessions": [
            {"sessionKey":"agent:root","displayName":"Team lead","state":"active","archetype":"orchestrator"},
            {"sessionKey":"agent:ios-coder","displayName":"iOS coder","state":"active","currentParent":"agent:root","archetype":"coder"},
            {"sessionKey":"agent:web-coder","displayName":"Web coder","state":"active","currentParent":"agent:root","archetype":"coder"},
            {"sessionKey":"agent:ios-mentor","displayName":"iOS mentor","state":"active","currentParent":"agent:root","archetype":"mentor"}
          ]
        }
        """#.utf8)
        return try JSONDecoder().decode(Roster.self, from: data).sessions
    }
}
