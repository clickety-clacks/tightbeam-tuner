import XCTest
@testable import TightbeamTuner

final class ReleaseNotesTests: XCTestCase {
    func testBoundCurrentBuildNoteParticipatesInFirstLaunchSelection() {
        let current = ReleaseNote(version: "1.0", build: 987654, date: "November 11, 2026", items: [
            .init(symbol: "text.bubble", title: "Current release", detail: "Current details.")
        ])
        let notes = ReleaseNotes.notes(including: current)

        let unseen = ReleaseNotes.unseenNotes(
            in: notes,
            currentBuild: 987654,
            lastSeenBuild: 52,
            firstInstall: false
        )

        XCTAssertEqual(unseen.map(\.build), [987654])
        XCTAssertEqual(unseen.first?.items.map(\.title), ["Current release"])
        XCTAssertEqual(unseen.first?.items.map(\.detail), ["Current details."])
    }

    func testCanonicalNoteAppearsOnFirstLaunchAfterAnUpgrade() throws {
        let latest = try XCTUnwrap(ReleaseNotes.all.first)

        let unseen = ReleaseNotes.unseenNotes(
            in: ReleaseNotes.all,
            currentBuild: latest.build,
            lastSeenBuild: nil,
            firstInstall: false
        )

        XCTAssertEqual(unseen.map(\.build), [latest.build])
        XCTAssertEqual(unseen.first?.items.map(\.title), latest.items.map(\.title))
        XCTAssertEqual(unseen.first?.items.map(\.detail), latest.items.map(\.detail))
    }

    func testFirstLaunchAfterUpdateShowsTheExactCurrentBuildNote() {
        let latest = ReleaseNote(version: "1.0", build: 53, date: "", items: [
            .init(symbol: "text.bubble", title: "Current build", detail: "Current details.")
        ])
        let prior = ReleaseNote(version: "1.0", build: 52, date: "", items: [
            .init(symbol: "keyboard", title: "Prior build", detail: "Prior details.")
        ])

        let unseen = ReleaseNotes.unseenNotes(
            in: [latest, prior],
            currentBuild: 53,
            lastSeenBuild: nil,
            firstInstall: false
        )

        XCTAssertEqual(unseen.map(\.build), [53])
        XCTAssertEqual(unseen.first?.items.map(\.title), ["Current build"])
        XCTAssertEqual(unseen.first?.items.map(\.detail), ["Current details."])
    }

    func testSavedReadMarkerShowsOnlyNotesNewerThanTheLastSeenBuild() {
        let latest = ReleaseNote(version: "1.0", build: 53, date: "", items: [
            .init(symbol: "text.bubble", title: "Current build", detail: "Current details.")
        ])
        let prior = ReleaseNote(version: "1.0", build: 52, date: "", items: [
            .init(symbol: "keyboard", title: "Prior build", detail: "Prior details.")
        ])

        let unseen = ReleaseNotes.unseenNotes(
            in: [latest, prior],
            currentBuild: 53,
            lastSeenBuild: 52,
            firstInstall: false
        )

        XCTAssertEqual(unseen.map(\.build), [53])
    }

    func testFreshInstallStillStartsWithoutReleaseNotes() {
        let latest = ReleaseNote(version: "1.0", build: 53, date: "", items: [
            .init(symbol: "text.bubble", title: "Current build", detail: "Current details.")
        ])

        let unseen = ReleaseNotes.unseenNotes(
            in: [latest],
            currentBuild: 53,
            lastSeenBuild: nil,
            firstInstall: true
        )

        XCTAssertTrue(unseen.isEmpty)
    }
}
