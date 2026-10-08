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
        item.maximumThickness = .greatestFiniteMagnitude
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
    /// minimum. Pure inputs by design, so the drag, programmatic, and
    /// restore paths share one contract that runs without views.
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
    /// Lowest divider position the drag path may settle on.
    ///
    /// `constrainSplitPosition` below only governs programmatic moves
    /// (`setPosition`), while a live drag consults these min/max coordinates.
    /// Without them a fast drag can push the divider past the trailing
    /// pane's minimum and the pane collapses out from under its tab, which
    /// reads as the right-hand page disappearing mid-resize.
    override func splitView(
        _ splitView: NSSplitView,
        constrainMinCoordinate proposedMinimum: CGFloat,
        ofSubviewAt dividerIndex: Int
    ) -> CGFloat {
        Self.clampedDividerPosition(
            proposedMinimum,
            dividerIndex: dividerIndex,
            paneCount: splitView.arrangedSubviews.count,
            totalWidth: splitView.bounds.width
        )
    }

    /// Highest divider position the drag path may settle on. Mirror image
    /// of the minimum above.
    override func splitView(
        _ splitView: NSSplitView,
        constrainMaxCoordinate proposedMaximum: CGFloat,
        ofSubviewAt dividerIndex: Int
    ) -> CGFloat {
        Self.clampedDividerPosition(
            proposedMaximum,
            dividerIndex: dividerIndex,
            paneCount: splitView.arrangedSubviews.count,
            totalWidth: splitView.bounds.width
        )
    }

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
