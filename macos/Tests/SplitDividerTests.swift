import Foundation
import Testing
@testable import Whatever

/// Proves the split divider cannot squeeze a pane out of existence.
///
/// The clamp is pure inputs by design, so this runs without views: the
/// drag path (min/max coordinates), the programmatic path
/// (`constrainSplitPosition`), and restores all share
/// `clampedDividerPosition`. Instantiating the controller headless stalls
/// the suite in this environment, so the live `NSSplitView` behavior stays
/// a manual check.
struct SplitDividerTests {
    private let width: CGFloat = 1300
    private var minimum: CGFloat { BrowserSplitViewController.minimumPaneWidth }

    private func clamp(_ proposed: CGFloat) -> CGFloat {
        BrowserSplitViewController.clampedDividerPosition(
            proposed,
            dividerIndex: 0,
            paneCount: 2,
            totalWidth: width
        )
    }

    @Test("positions inside the range pass through")
    func insidePassesThrough() {
        #expect(clamp(650) == 650)
        #expect(clamp(minimum) == minimum)
        #expect(clamp(width - minimum) == width - minimum)
    }

    @Test("a divider run past either end stops at the pane minimum")
    func endsClamp() {
        #expect(clamp(-500) == minimum)
        #expect(clamp(0) == minimum)
        #expect(clamp(width + 500) == width - minimum)
    }

    @Test("a window narrower than two minimums holds the leading side")
    func narrowWindowHolds() {
        let clamped = BrowserSplitViewController.clampedDividerPosition(
            10,
            dividerIndex: 0,
            paneCount: 2,
            totalWidth: 400
        )
        #expect(clamped == minimum)
    }
}
