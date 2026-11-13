import XCTest
import SwiftUI
@testable import TightbeamTuner

final class ComposerSafeAreaTests: XCTestCase {
    func testExactFilterBottomAlignmentAcrossIntermediatePositionsAndKeyboardRegions() {
        // Positions deliberately share the same half: edge classification alone cannot pass.
        for regionHeight in [CGFloat(900), 500] {
            for fraction in [CGFloat(0.15), 0.35, 0.65, 0.85] {
                let filterBottom = regionHeight * fraction
                let edge: VerticalEdge = fraction < 0.5 ? .top : .bottom
                let placement = ComposerInsetPlacement(
                    edge: edge, availableHeight: regionHeight,
                    targetBottom: filterBottom, composerHeight: 44
                )
                let insetOrigin = edge == .top ? 0 : regionHeight - placement.extent
                let composerBottom = insetOrigin + placement.composerTop + 44
                XCTAssertEqual(composerBottom, filterBottom, accuracy: 0.001)
                if edge == .top {
                    XCTAssertEqual(placement.extent, composerBottom, accuracy: 0.001)
                } else {
                    XCTAssertEqual(insetOrigin, composerBottom - 44, accuracy: 0.001)
                }
            }
        }
    }

    func testMultilineGrowthKeepsFilterBottomAndReservesWholeComposer() {
        for edge in [VerticalEdge.top, .bottom] {
            for height in [CGFloat(44), 88, 132] {
                let placement = ComposerInsetPlacement(
                    edge: edge, availableHeight: 600, targetBottom: 300, composerHeight: height
                )
                let origin = edge == .top ? 0 : 600 - placement.extent
                XCTAssertEqual(origin + placement.composerTop + height, 300)
                XCTAssertGreaterThanOrEqual(placement.extent, height)
            }
        }
    }

    func testSystemSafeRegionWinsOverStaleOffscreenFilterFrame() {
        let cases: [(CGFloat, CGFloat)] = [(-20, 44), (700, 400)]
        for edge in [VerticalEdge.top, .bottom] {
            for (target, expectedBottom) in cases {
                let placement = ComposerInsetPlacement(
                    edge: edge, availableHeight: 400, targetBottom: target, composerHeight: 44
                )
                let origin = edge == .top ? 0 : 400 - placement.extent
                XCTAssertEqual(origin + placement.composerTop + 44, expectedBottom)
            }
        }
    }

    func testNoTargetUsesOnlyMeasuredHeightWithoutAdditionalClearance() {
        for edge in [VerticalEdge.top, .bottom] {
            let placement = ComposerInsetPlacement(
                edge: edge, availableHeight: 600, targetBottom: nil, composerHeight: 61
            )
            XCTAssertEqual(placement.extent, 61)
            XCTAssertEqual(placement.composerTop, 0)
        }
    }

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

    func testCaptureFixtureUsesMeasuredIntermediateFilterTargets() {
        for edge in ["top", "bottom"] {
            let configuration = WIb6SafeAreaCaptureFixtureConfiguration(arguments: [
                WIb6SafeAreaCaptureFixtureConfiguration.launchArgument,
                "--wib6-filter-edge=\(edge)", "--wib6-intermediate-filter",
            ])
            XCTAssertNil(configuration.failureMessage)
            XCTAssertTrue(configuration.intermediateFilter)
            XCTAssertGreaterThan(configuration.spacersBeforeFilter, 0)
            XCTAssertGreaterThan(configuration.spacersAfterFilter, 0)
            XCTAssertEqual(configuration.spacersBeforeFilter + configuration.spacersAfterFilter, 3)
        }
    }

    func testCaptureFixtureUsesSelfContainedSyntheticChatPage() async {
        let fixture = WIb6SafeAreaCaptureFixtureConfiguration(arguments: [
            WIb6SafeAreaCaptureFixtureConfiguration.launchArgument,
            "--wib6-filter-edge=top",
            "--wib6-scroll-to-last",
        ])

        XCTAssertEqual(fixture.chatURL.scheme, "data")
        XCTAssertNil(fixture.chatURL.host)

        guard let encodedHTML = fixture.chatURL.absoluteString.split(separator: ",", maxSplits: 1).last,
              let pageData = Data(base64Encoded: String(encodedHTML)),
              let page = String(data: pageData, encoding: .utf8) else {
            return XCTFail("The fixture should embed its page without a server")
        }
        XCTAssertTrue(page.contains("First synthetic message"))
        XCTAssertTrue(page.contains("Last synthetic message"))
        let commandEntryName = await MainActor.run { ChatHostBridge.commandEntryName }
        let pageContainsCommandEntry = page.contains(commandEntryName)
        XCTAssertFalse(pageContainsCommandEntry)
    }
}
