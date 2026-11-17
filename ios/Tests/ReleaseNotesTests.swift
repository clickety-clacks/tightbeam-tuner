import XCTest
@testable import TightbeamTuner

final class ReleaseNotesTests: XCTestCase {
    func testCompatibilityStatementComesFromTheCurrentReleaseNoteItem() {
        let statement = "Tightbeam CLI 0.0.0 and Chat v0.0.0 (test fixture)."
        let current = ReleaseNote(version: "1.0", build: 987654, date: "January 1, 2027", items: [
            .init(symbol: "info.circle", title: "Compatibility", detail: statement),
            .init(symbol: "exclamationmark.triangle", title: "Breaking changes", detail: "Test fixture."),
        ])
        let withoutCompatibility = ReleaseNote(version: "1.0", build: 987653, date: "December 31, 2026", items: [
            .init(symbol: "text.bubble", title: "Other", detail: "No compatibility entry."),
        ])
        let lowercaseCompatibility = ReleaseNote(version: "1.0", build: 987652, date: "December 30, 2026", items: [
            .init(symbol: "info.circle", title: "compatibility", detail: statement),
        ])

        XCTAssertEqual(ReleaseNotes.compatibilityStatement(in: current), statement)
        XCTAssertEqual(ReleaseNotes.compatibilityStatement(in: lowercaseCompatibility), statement)
        XCTAssertNil(ReleaseNotes.compatibilityStatement(in: withoutCompatibility))
        XCTAssertNil(ReleaseNotes.compatibilityStatement(in: nil))
    }

    func testBoundCurrentBuildNoteParticipatesInFirstLaunchSelection() {
        let current = ReleaseNote(version: "1.0", build: 987654, date: "November 11, 2026", items: [
            .init(symbol: "text.bubble", title: "Current release", detail: "Current details.")
        ])
        let notes = ReleaseNotes.notes(including: current)

        let unseen = ReleaseNotes.unseenNotes(
            in: notes,
            currentBuild: 987654,
            lastSeenBuild: 900000,
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

    func testShippedBuild76NoteRemainsInHistory() throws {
        let shipped = try XCTUnwrap(ReleaseNotes.history.first(where: { $0.build == 76 }))

        XCTAssertEqual(shipped.date, "November 17, 2026")
        XCTAssertEqual(
            shipped.items.map { ($0.title, $0.detail) }.map { "\($0.0)|\($0.1)" },
            [
                "Compatibility|Compatible with: Tightbeam 0.1.16 (build 4283) and Chat v0.1.100. Not yet verified with Chat v0.1.101.",
                "Breaking changes|None.",
            ]
        )
    }

    func testFirstLaunchAfterUpdateShowsTheExactCurrentBuildNote() {
        let latest = ReleaseNote(version: "1.0", build: 900001, date: "", items: [
            .init(symbol: "text.bubble", title: "Current build", detail: "Current details.")
        ])
        let prior = ReleaseNote(version: "1.0", build: 900000, date: "", items: [
            .init(symbol: "keyboard", title: "Prior build", detail: "Prior details.")
        ])

        let unseen = ReleaseNotes.unseenNotes(
            in: [latest, prior],
            currentBuild: 900001,
            lastSeenBuild: nil,
            firstInstall: false
        )

        XCTAssertEqual(unseen.map(\.build), [900001])
        XCTAssertEqual(unseen.first?.items.map(\.title), ["Current build"])
        XCTAssertEqual(unseen.first?.items.map(\.detail), ["Current details."])
    }

    func testSavedReadMarkerShowsOnlyNotesNewerThanTheLastSeenBuild() {
        let latest = ReleaseNote(version: "1.0", build: 900001, date: "", items: [
            .init(symbol: "text.bubble", title: "Current build", detail: "Current details.")
        ])
        let prior = ReleaseNote(version: "1.0", build: 900000, date: "", items: [
            .init(symbol: "keyboard", title: "Prior build", detail: "Prior details.")
        ])

        let unseen = ReleaseNotes.unseenNotes(
            in: [latest, prior],
            currentBuild: 900001,
            lastSeenBuild: 900000,
            firstInstall: false
        )

        XCTAssertEqual(unseen.map(\.build), [900001])
    }

    func testFreshInstallStillStartsWithoutReleaseNotes() {
        let latest = ReleaseNote(version: "1.0", build: 900001, date: "", items: [
            .init(symbol: "text.bubble", title: "Current build", detail: "Current details.")
        ])

        let unseen = ReleaseNotes.unseenNotes(
            in: [latest],
            currentBuild: 900001,
            lastSeenBuild: nil,
            firstInstall: true
        )

        XCTAssertTrue(unseen.isEmpty)
    }
}
