import AppKit

/// Two panes side by side. Panes are retained by their window so the
/// existing web views are reparented rather than recreated, and the
/// divider position is stored as a ratio so it survives window resizes.
final class BrowserSplitViewController: NSSplitViewController {
    static let minimumPaneWidth: CGFloat = 260
    static let minimumRatio: CGFloat = 0.2
    static let maximumRatio: CGFloat = 0.8
    static let defaultRatio: CGFloat = 0.5

    private(set) var paneControllers: [BrowserPaneController] = []

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
}

extension BrowserSplitViewController {
    override func splitView(
        _ splitView: NSSplitView,
        constrainSplitPosition proposedPosition: CGFloat,
        ofSubviewAt dividerIndex: Int
    ) -> CGFloat {
        let minimum = Self.minimumPaneWidth
        let lowerBound = CGFloat(dividerIndex + 1) * minimum
        let upperBound = splitView.bounds.width
            - CGFloat(splitView.arrangedSubviews.count - dividerIndex - 1) * minimum
        return min(max(proposedPosition, lowerBound), max(lowerBound, upperBound))
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
