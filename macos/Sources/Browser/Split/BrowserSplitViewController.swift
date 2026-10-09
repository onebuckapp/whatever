// Whatever Browser – Made by Humans from OpenPeeps
//
//     Copyright (C) 2026 George Lemon <georgelemon@protonmail.com>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program.  If not, see <https://www.gnu.org/licenses/>.

import AppKit
import Combine

/// Two panes side by side. Panes are retained by their window so the
/// existing web views are reparented rather than recreated, and the
/// divider position is stored as a ratio so it survives window resizes.
final class BrowserSplitViewController: NSSplitViewController {
    static let minimumPaneWidth: CGFloat = 260
    static let minimumRatio: CGFloat = 0.2
    static let maximumRatio: CGFloat = 0.8
    static let defaultRatio: CGFloat = 0.5

    private(set) var paneControllers: [BrowserPaneController] = []
    private var backgroundSubscription: AnyCancellable?

    /// Reports the divider position as a 0...1 fraction whenever it
    /// changes, so the window can restore it later.
    var onRatioChange: ((CGFloat) -> Void)?
    /// Set while rebuilding to avoid persisting a transient position.
    var isRestoringRatio = false

    override func viewDidLoad() {
        super.viewDidLoad()

        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.delegate = self
        applySplitBackgroundTransparency()
        // The split view is created and thrown away as the layout changes, so it
        // reads the setting itself rather than being told.
        backgroundSubscription = SettingsStore.shared.$settings
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.applySplitBackgroundTransparency()
            }
    }

    /// Lets the window background show between the panes.
    ///
    /// `NSSplitView` has no `drawsBackground` at all: not declared, and not
    /// present on the class at runtime on macOS 14.8, which is why the obvious
    /// `setValue(_:forKey:)` route is not an option — KVC raises
    /// `NSUnknownKeyException` for an unknown key and takes the process with it.
    /// That was a real crash here before this was checked.
    ///
    /// Its background is painted by its layer, so clearing that is the way
    /// through. Whether that is enough to reveal the window background in the
    /// gutter is a question for the eye rather than the API; if it turns out not
    /// to be, the honest outcome is that the gutter keeps AppKit's own colour
    /// while everything around the split still shows the background.
    ///
    /// Only applied while a background is configured: with none, the split is
    /// left exactly as AppKit drew it.
    private func applySplitBackgroundTransparency() {
        guard SettingsStore.shared.settings.appearance.background.isActive else {
            splitView.layer?.backgroundColor = nil
            return
        }
        splitView.wantsLayer = true
        splitView.layer?.backgroundColor = .clear
    }

    // MARK: - Panes

    func addPane(_ pane: BrowserPaneController) {
        let item = NSSplitViewItem(viewController: pane)
        item.canCollapse = false
        item.minimumThickness = Self.minimumPaneWidth
        // Finite on purpose: `.greatestFiniteMagnitude` exceeds AppKit's
        // constraint-constant limits, logs, gets substituted, and lays out
        // garbage. No window is ever this wide, so this is still no limit.
        item.maximumThickness = 10_000
        // NSSplitView positions arranged subviews with frames. A pane arriving
        // from single-tab duty still carries `translates == false` from
        // `showChild`, which flips the split into constraint-based layout and
        // trips its internal assertions on the next resize. Hand frame control
        // back here; leaving the split (direct hosting or parking) sets the
        // flag the other way again.
        pane.view.translatesAutoresizingMaskIntoConstraints = true
        addSplitViewItem(item)
        paneControllers.append(pane)
    }

    func removePane(_ pane: BrowserPaneController) {
        guard let index = paneControllers.firstIndex(where: { $0 === pane }) else {
            return
        }
        if splitViewItems.indices.contains(index) {
            removeSplitViewItem(splitViewItems[index])
        }
        paneControllers.remove(at: index)
    }

    /// Current leading pane width as a fraction of the split width.
    var ratio: CGFloat {
        let total = splitView.bounds.width
        guard total > 0,
              let leading = splitView.arrangedSubviews.first
        else {
            return Self.defaultRatio
        }
        return leading.frame.width / total
    }

    /// Moves the divider to a stored fraction, clamped so neither pane
    /// becomes unusably narrow.
    func setRatio(_ ratio: CGFloat) {
        let total = splitView.bounds.width
        guard total > 0 else { return }
        let clamped = min(
            max(ratio, Self.minimumRatio),
            Self.maximumRatio
        )
        isRestoringRatio = true
        splitView.setPosition((total * clamped).rounded(), ofDividerAt: 0)
        isRestoringRatio = false
    }

    /// Splits vertically by resizing both items to the same width.
    func resetToEqualWidths() {
        setRatio(Self.defaultRatio)
    }

    /// Clamps a divider position so neither side drops below the pane
    /// minimum. Pure inputs by design, so the programmatic and restore paths
    /// share one contract that runs without views. The live-drag path is
    /// deliberately NOT clamped here: `constrainMinCoordinate` and
    /// `constrainMaxCoordinate` are autolayout-incompatible delegate methods
    /// (alongside `resizeSubviewsWithOldSize` and `shouldAdjustSizeOfSubview`),
    /// and implementing any of them trips the split view's internal
    /// assertions because this split view is itself pinned by Auto Layout.
    /// Drags are clamped by the items' `minimumThickness` instead, which
    /// AppKit turns into layout constraints — the compatible mechanism.
    static func clampedDividerPosition(
        _ proposed: CGFloat,
        dividerIndex: Int,
        paneCount: Int,
        totalWidth: CGFloat
    ) -> CGFloat {
        let lowerBound = CGFloat(dividerIndex + 1) * minimumPaneWidth
        let upperBound = totalWidth
            - CGFloat(paneCount - dividerIndex - 1) * minimumPaneWidth
        // A window narrower than two minimums has no feasible position;
        // hold the leading side rather than letting the divider run away.
        return min(max(proposed, lowerBound), max(lowerBound, upperBound))
    }
}

extension BrowserSplitViewController {
    override func splitView(
        _ splitView: NSSplitView,
        constrainSplitPosition proposedPosition: CGFloat,
        ofSubviewAt dividerIndex: Int
    ) -> CGFloat {
        Self.clampedDividerPosition(
            proposedPosition,
            dividerIndex: dividerIndex,
            paneCount: splitView.arrangedSubviews.count,
            totalWidth: splitView.bounds.width
        )
    }

    /// The divider hit area is deliberately wider than the hairline so
    /// grabbing it does not require pixel precision.
    func splitView(
        _ splitView: NSSplitView,
        adjustableDividerThicknessForThickness thickness: CGFloat
    ) -> CGFloat {
        max(thickness, 10)
    }

    override func splitViewDidResizeSubviews(_ notification: Notification) {
        guard !isRestoringRatio, splitViewItems.count > 1 else { return }
        onRatioChange?(ratio)
    }
}
