import XCTest
import SwiftUI
@testable import TightbeamTuner

final class ComposerSafeAreaTests: XCTestCase {
    func testFilterNearTopSelectsTopSafeAreaInset() {
        let detail = CGRect(x: 300, y: 80, width: 800, height: 900)
        let filter = CGRect(x: 40, y: 96, width: 240, height: 48)

        guard case .top = ChatComposerSafeAreaPlacement.edge(for: filter, in: detail) else {
            return XCTFail("A Filter at the top of the detail should use the top safe-area edge")
        }
    }

    func testFilterNearBottomSelectsBottomSafeAreaInsetForKeyboardDownAndUpFrames() {
        let keyboardDownDetail = CGRect(x: 300, y: 80, width: 800, height: 900)
        let keyboardDownFilter = CGRect(x: 40, y: 836, width: 240, height: 48)
        let keyboardUpDetail = CGRect(x: 300, y: 80, width: 800, height: 500)
        let keyboardUpFilter = CGRect(x: 40, y: 528, width: 240, height: 48)

        for (detail, filter) in [
            (keyboardDownDetail, keyboardDownFilter),
            (keyboardUpDetail, keyboardUpFilter),
        ] {
            guard case .bottom = ChatComposerSafeAreaPlacement.edge(for: filter, in: detail) else {
                return XCTFail("A lower Filter target should use the bottom safe-area edge")
            }
        }
    }

    func testMissingOrUnmeasuredFilterFallsBackToBottomEdge() {
        let detail = CGRect(x: 0, y: 100, width: 600, height: 700)

        guard case .bottom = ChatComposerSafeAreaPlacement.edge(for: nil, in: detail),
              case .bottom = ChatComposerSafeAreaPlacement.edge(for: .zero, in: detail),
              case .bottom = ChatComposerSafeAreaPlacement.edge(for: CGRect(x: 0, y: 0, width: 20, height: 20), in: .zero) else {
            return XCTFail("Missing layout measurements should safely default to the bottom edge")
        }
    }

    func testContentOnlyExtendsUnderTheSafeAreaOppositeTheComposer() {
        let portraitTopComposer = ChatComposerSafeAreaPlacement.contentExtensionEdges(
            isPortrait: true, composerActive: true, composerEdge: .top
        )
        let portraitBottomComposer = ChatComposerSafeAreaPlacement.contentExtensionEdges(
            isPortrait: true, composerActive: true, composerEdge: .bottom
        )
        let landscapeBottomComposer = ChatComposerSafeAreaPlacement.contentExtensionEdges(
            isPortrait: false, composerActive: true, composerEdge: .bottom
        )
        let landscapeTopComposer = ChatComposerSafeAreaPlacement.contentExtensionEdges(
            isPortrait: false, composerActive: true, composerEdge: .top
        )
        let inactiveLandscapeComposer = ChatComposerSafeAreaPlacement.contentExtensionEdges(
            isPortrait: false, composerActive: false, composerEdge: .bottom
        )
        let inactivePortraitComposer = ChatComposerSafeAreaPlacement.contentExtensionEdges(
            isPortrait: true, composerActive: false, composerEdge: .bottom
        )

        XCTAssertTrue(portraitTopComposer.contains(.bottom))
        XCTAssertFalse(portraitTopComposer.contains(.top))
        XCTAssertTrue(portraitBottomComposer.contains(.top))
        XCTAssertFalse(portraitBottomComposer.contains(.bottom))
        XCTAssertEqual(landscapeBottomComposer, [])
        XCTAssertEqual(landscapeTopComposer, [])
        XCTAssertTrue(inactiveLandscapeComposer.contains(.bottom))
        XCTAssertFalse(inactiveLandscapeComposer.contains(.top))
        XCTAssertTrue(inactivePortraitComposer.contains(.vertical))
    }

    func testCaptureFixtureSelectsFilterEdgeAndCanStartKeyboardUp() {
        let keyboardUp = WIb6SafeAreaCaptureFixtureConfiguration(arguments: [
            WIb6SafeAreaCaptureFixtureConfiguration.launchArgument,
            "--wib6-filter-edge=top",
            "--wib6-keyboard-up",
            "--wib6-scroll-to-last",
        ])
        let keyboardDown = WIb6SafeAreaCaptureFixtureConfiguration(arguments: [
            WIb6SafeAreaCaptureFixtureConfiguration.launchArgument,
            "--wib6-filter-edge=bottom",
        ])

        guard case .top = keyboardUp.edge else {
            return XCTFail("The fixture should select its requested top Filter edge")
        }
        XCTAssertTrue(keyboardUp.keyboardUp)
        XCTAssertTrue(keyboardUp.scrollToLast)
        XCTAssertNil(keyboardUp.failureMessage)
        guard case .bottom = keyboardDown.edge else {
            return XCTFail("The fixture should select its requested bottom Filter edge")
        }
        XCTAssertFalse(keyboardDown.keyboardUp)
        XCTAssertFalse(keyboardDown.scrollToLast)
        XCTAssertNil(keyboardDown.failureMessage)
    }
}
