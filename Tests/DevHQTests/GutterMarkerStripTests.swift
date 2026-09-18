import AppKit
import XCTest
@testable import DevHQ

@MainActor
final class GutterMarkerStripTests: XCTestCase {
    /// The strip must match the gutter's origin and height so marker rects can
    /// reuse raw layout-manager `yPos` values, and must stay narrow enough to
    /// clear CodeEdit's 20pt leading inset where line numbers begin.
    func testStripFrameTracksGutterOriginAndHeight() {
        let gutter = NSView(frame: NSRect(x: 7, y: 13, width: 64, height: 420))

        let strip = gutterMarkerStripFrame(tracking: gutter)

        XCTAssertEqual(strip.minX, 7)
        XCTAssertEqual(strip.minY, 13)
        XCTAssertEqual(strip.height, 420)
        XCTAssertEqual(strip.width, gutterMarkerStripWidth)
        XCTAssertLessThanOrEqual(strip.width, 20)
    }

    /// The strip is installed as a sibling above the gutter, never as its
    /// subview: adding a subview to the layer-backed `GutterView` stops it
    /// drawing its line numbers.
    func testStripIsInstalledAsSiblingAboveGutter() {
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 400))
        let gutter = NSView(frame: NSRect(x: 0, y: 0, width: 64, height: 400))
        host.addSubview(gutter)
        let marker = NSView(frame: .zero)

        let observer = installGutterMarkerStrip(marker, tracking: gutter)
        defer {
            if let observer { NotificationCenter.default.removeObserver(observer) }
        }

        XCTAssertTrue(gutter.subviews.isEmpty)
        XCTAssertIdentical(marker.superview, host)
        XCTAssertEqual(marker.frame, gutterMarkerStripFrame(tracking: gutter))
        let gutterIndex = host.subviews.firstIndex(of: gutter)
        let markerIndex = host.subviews.firstIndex(of: marker)
        XCTAssertNotNil(gutterIndex)
        XCTAssertNotNil(markerIndex)
        XCTAssertGreaterThan(markerIndex ?? 0, gutterIndex ?? 0)
    }

    func testStripFollowsGutterFrameChanges() {
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 400))
        let gutter = NSView(frame: NSRect(x: 0, y: 0, width: 64, height: 400))
        host.addSubview(gutter)
        let marker = NSView(frame: .zero)
        let observer = installGutterMarkerStrip(marker, tracking: gutter)
        defer {
            if let observer { NotificationCenter.default.removeObserver(observer) }
        }

        gutter.frame = NSRect(x: 0, y: -120, width: 80, height: 900)

        XCTAssertEqual(marker.frame.minY, -120)
        XCTAssertEqual(marker.frame.height, 900)
        XCTAssertEqual(marker.frame.width, gutterMarkerStripWidth)
    }
}
