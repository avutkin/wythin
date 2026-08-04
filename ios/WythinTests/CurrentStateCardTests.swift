import XCTest
import SwiftUI
@testable import Wythin

/// `BalanceTrackMath` is the pure geometry and formatting behind the
/// nervous-system balance card's track: where the marker sits for a given
/// balance value, how the PNS/SNS numbers are formatted, and which colours
/// the gradient uses at each end. Everything else on `BalanceTrack` is
/// SwiftUI layout that needs a host to render, so this is the part that can
/// actually be pinned.
final class BalanceTrackMathTests: XCTestCase {

    // MARK: markerOffset

    func testMarkerOffsetAtZeroSitsAtTheLeftEdge() {
        XCTAssertEqual(BalanceTrackMath.markerOffset(sns: 0, trackWidth: 200), 0, accuracy: 0.001)
    }

    func testMarkerOffsetAtOneSitsAtTheUsableRightEdge() {
        let width: CGFloat = 200
        let expected = width - BalanceTrackMath.markerWidth
        XCTAssertEqual(BalanceTrackMath.markerOffset(sns: 1, trackWidth: width), expected, accuracy: 0.001)
    }

    func testMarkerOffsetAtHalfSitsHalfwayAcrossTheUsableWidth() {
        let width: CGFloat = 200
        let usable = width - BalanceTrackMath.markerWidth
        XCTAssertEqual(BalanceTrackMath.markerOffset(sns: 0.5, trackWidth: width), usable / 2, accuracy: 0.001)
    }

    func testMarkerOffsetClampsBelowZero() {
        // sns is 0-1 by construction (AutonomicIndices.sns = 1 - pns), but the
        // track shouldn't put the marker off-screen if that ever slips.
        XCTAssertEqual(BalanceTrackMath.markerOffset(sns: -0.4, trackWidth: 200), 0, accuracy: 0.001)
    }

    func testMarkerOffsetClampsAboveOne() {
        let width: CGFloat = 200
        let expected = width - BalanceTrackMath.markerWidth
        XCTAssertEqual(BalanceTrackMath.markerOffset(sns: 1.6, trackWidth: width), expected, accuracy: 0.001)
    }

    func testMarkerOffsetNeverGoesNegativeOnAnUndersizedTrack() {
        // Width narrower than the reserved marker width: usable clamps to 0
        // rather than going negative and pushing the marker off the left edge.
        XCTAssertEqual(BalanceTrackMath.markerOffset(sns: 1, trackWidth: 10), 0, accuracy: 0.001)
    }

    // MARK: format

    func testFormatKeepsTwoDecimalPlaces() {
        XCTAssertEqual(BalanceTrackMath.format(0.6234), "0.62")
        XCTAssertEqual(BalanceTrackMath.format(0), "0.00")
        XCTAssertEqual(BalanceTrackMath.format(1), "1.00")
    }

    // MARK: gradientColors

    func testGradientColorsRunGreenToRedWhenPlaceable() {
        XCTAssertEqual(BalanceTrackMath.gradientColors(placeable: true), [Theme.accent, Theme.warn])
    }

    func testGradientColorsAreFlatAndDimWhenNotPlaceable() {
        let colors = BalanceTrackMath.gradientColors(placeable: false)
        XCTAssertEqual(colors, [Theme.dim.opacity(0.18), Theme.dim.opacity(0.18)])
    }

    func testGradientEndpointsAreThemeColorsNotInventedHexValues() {
        // The spec is explicit: reuse Theme.accent / Theme.warn, don't invent
        // new hex values for the gradient.
        let colors = BalanceTrackMath.gradientColors(placeable: true)
        XCTAssertEqual(colors.first, Theme.accent)
        XCTAssertEqual(colors.last,  Theme.warn)
    }
}
