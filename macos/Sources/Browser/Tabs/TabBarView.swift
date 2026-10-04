import AppKit

protocol TabBarViewDelegate: AnyObject {
    func tabBar(_ tabBar: TabBarView, didSelect tab: BrowserTab)
    func tabBar(_ tabBar: TabBarView, didClose tab: BrowserTab)
    func tabBar(_ tabBar: TabBarView, menuFor tab: BrowserTab) -> NSMenu?
    /// The tab's mute button was pressed.
    func tabBar(_ tabBar: TabBarView, didToggleMuteFor tab: BrowserTab)
    /// A tab was dropped on this bar at the given insertion index.
    func tabBar(_ tabBar: TabBarView, didDropTab tab: BrowserTab, at index: Int)
}

/// Thin accent line drawn between tabs while a drag hovers the bar.
final class TabInsertionMarkerView: NSView {
    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        layer?.cornerRadius = 1
        isHidden = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

/// Horizontally scrollable strip of tab cells, laid out by hand so tab
/// widths and pinning behave like Safari's bar. Reordering uses a real
/// AppKit drag: this view is the drop target, `TabBarItemView` is the
/// dragging source.
final class TabBarView: NSView {
    weak var delegate: TabBarViewDelegate?

    /// Given a pointer x in the strip, scrolls the strip when the
    /// pointer is near a visible edge. Returns the applied scroll offset.
    var autoScroll: ((CGFloat) -> CGFloat)?

    /// Window that owns this bar; drops are routed back through the
    /// coordinator using it as the destination.
    weak var owner: BrowserWindowController?

    private(set) var tabs: [BrowserTab] = []
    private var selectedTabID: UUID?
    private var itemViews: [UUID: TabBarItemView] = [:]
    private let insertionMarker = TabInsertionMarkerView()

    /// Tabs in display order. The window keeps `tabs` sorted with
    /// pinned tabs leading, so this is the same as `tabs` and the drop
    /// indices computed here map straight onto model indices.
    private var laidOutTabs: [BrowserTab] {
        tabs
    }

    private var insertionIndex: Int?

    override var isFlipped: Bool { true }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: 36)
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([TabDragPayload.type])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Content

    func setTabs(_ tabs: [BrowserTab], selectedTabID: UUID?) {
        self.tabs = tabs
        self.selectedTabID = selectedTabID

        for tab in tabs where itemViews[tab.id] == nil {
            let item = makeItem(for: tab)
            itemViews[tab.id] = item
            addSubview(item)
        }
        let live = Set(tabs.map(\.id))
        for (id, item) in itemViews where !live.contains(id) {
            item.removeFromSuperview()
            itemViews.removeValue(forKey: id)
        }

        for tab in tabs {
            itemViews[tab.id]?.setSelected(tab.id == selectedTabID)
        }
        hideInsertionMarker()
        needsLayout = true
        superview?.needsLayout = true
    }

    /// Width the strip wants; the container scrolls when this exceeds
    /// the visible width.
    var preferredWidth: CGFloat {
        var total: CGFloat = 0
        for tab in laidOutTabs {
            total += width(for: tab) + 4
        }
        return max(0, total + 12)
    }

    // MARK: - Layout

    override func layout() {
        super.layout()
        // Cells run flush to the bar's bottom edge so they stick to the
        // page below; only the top keeps an inset.
        let tabHeight = max(0, bounds.height - 4)
        var x: CGFloat = 6
        for tab in laidOutTabs {
            guard let item = itemViews[tab.id] else { continue }
            item.frame = NSRect(x: x, y: 4, width: width(for: tab), height: tabHeight)
            x += item.frame.width + 4
        }
        if insertionIndex != nil {
            layoutInsertionMarker()
        }
    }

    private func width(for tab: BrowserTab) -> CGFloat {
        if tab.presentation.isPinned {
            return TabBarItemView.pinnedWidth
        }
        let normalCount = max(1, tabs.filter { !$0.presentation.isPinned }.count)
        let pinnedWidth = CGFloat(tabs.filter(\.presentation.isPinned).count)
            * (TabBarItemView.pinnedWidth + 4)
        let available = max(
            bounds.width - pinnedWidth - 12 - CGFloat(normalCount) * 4,
            TabBarItemView.minimumWidth * CGFloat(normalCount)
        )
        let ideal = available / CGFloat(normalCount)
        return min(
            max(ideal, TabBarItemView.minimumWidth),
            TabBarItemView.maximumWidth
        )
    }

    // MARK: - Insertion index

    /// Index in `laidOutTabs` where the dragged tab should land, given
    /// the pointer position. Clamped so pinned tabs stay leading and
    /// normal tabs cannot move into the pinned region.
    func insertionIndex(forDragged dragged: BrowserTab, at point: NSPoint) -> Int {
        let ordered = laidOutTabs.filter { $0.id != dragged.id }
        var index = ordered.count
        for (offset, tab) in ordered.enumerated() {
            guard let item = itemViews[tab.id] else { continue }
            if point.x < item.frame.midX {
                index = offset
                break
            }
        }

        let pinnedCount = tabs.filter(\.presentation.isPinned).count
        if dragged.presentation.isPinned {
            return min(index, pinnedCount)
        }
        return max(index, pinnedCount)
    }

    private func layoutInsertionMarker() {
        guard let index = insertionIndex else { return }
        let ordered = laidOutTabs
        let x: CGFloat
        if index >= ordered.count {
            x = (itemViews[ordered.last?.id ?? UUID()]?.frame.maxX ?? 6) + 2
        } else if index == 0 {
            x = 4
        } else {
            x = (itemViews[ordered[index - 1].id]?.frame.maxX ?? 6) + 2
        }
        insertionMarker.frame = NSRect(
            x: x,
            y: 4,
            width: 2,
            height: max(0, bounds.height - 4)
        )
    }

    private func hideInsertionMarker() {
        insertionIndex = nil
        insertionMarker.isHidden = true
    }

    private func autoScroll(for point: NSPoint) {
        _ = autoScroll?(point.x)
    }

    // MARK: - Private

    private func makeItem(for tab: BrowserTab) -> TabBarItemView {
        let item = TabBarItemView(tab: tab)
        item.onPress = { [weak self] in
            guard let self else { return }
            self.delegate?.tabBar(self, didSelect: tab)
        }
        item.onClose = { [weak self] in
            guard let self else { return }
            self.delegate?.tabBar(self, didClose: tab)
        }
        item.onToggleMute = { [weak self] in
            guard let self else { return }
            self.delegate?.tabBar(self, didToggleMuteFor: tab)
        }
        item.contextMenuProvider = { [weak self] in
            guard let self else { return nil }
            return self.delegate?.tabBar(self, menuFor: tab)
        }
        item.onDragEnded = { [weak self] screenPoint in
            guard let self else { return }
            self.dragEnded(tab, atScreenPoint: screenPoint)
        }
        addSubview(item)
        return item
    }

    /// A drag that ended outside the tab bar either split the page
    /// area or left the application entirely. Only the latter moves
    /// the tab into its own window.
    private func dragEnded(_ tab: BrowserTab, atScreenPoint point: NSPoint) {
        let overWindow = BrowserCoordinator.shared.windows.contains {
            $0.window?.frame.contains(point) == true
        }
        guard !overWindow else { return }
        BrowserCoordinator.shared.dragEndedOutsideApp(tab, atScreenPoint: point)
    }
}

// MARK: - NSDraggingDestination

extension TabBarView {
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        draggingUpdated(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard let tab = TabDragPayload.tab(from: sender) else { return [] }
        let point = convert(sender.draggingLocation, from: nil)
        let index = insertionIndex(forDragged: tab, at: point)

        if insertionIndex != index {
            insertionIndex = index
            insertionMarker.isHidden = false
            addSubview(insertionMarker)
            layoutInsertionMarker()
        }
        autoScroll(for: point)
        return .move
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        hideInsertionMarker()
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        hideInsertionMarker()
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        TabDragPayload.tab(from: sender) != nil
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        defer { hideInsertionMarker() }
        guard let tab = TabDragPayload.tab(from: sender) else { return false }
        let index = insertionIndex ?? insertionIndex(forDragged: tab, at: .zero)
        // A drop on this bar is either a same-window reorder or a move
        // in from another window; both are the coordinator's job.
        if let owner {
            BrowserCoordinator.shared.moveTab(tab, to: index, in: owner)
            return true
        }
        return false
    }
}

/// Window chrome around the strip: horizontal scrolling on the left and
/// a fixed new-tab button on the trailing edge.
final class TabBarContainerView: NSView {
    let strip = TabBarView()
    private let scrollView = NSScrollView()
    private let newTabButton: NSButton = {
        let button = NSButton(frame: .zero)
        button.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "New Tab")
        button.imagePosition = .imageOnly
        return button
    }()
    var newTabAction: (() -> Void)?

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: 36)
    }

    init(newTabAction: @escaping () -> Void) {
        self.newTabAction = newTabAction
        super.init(frame: .zero)
        // Auto Layout positions this container; autoresizing masks would
        // fight the height constraint the window chrome installs.
        translatesAutoresizingMaskIntoConstraints = false
        setUpSubviews()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setUpSubviews() {
        // No scroller bars at all, and this is load-bearing rather than
        // cosmetic. `NSScrollView` reserves about 15pt of layout height for a
        // horizontal scroller whenever one can appear, and shrinks its document
        // view to match. The document view here is the tab strip, so that fed
        // straight into the tab height: measured, a window narrow enough for the
        // tabs to overflow collapsed them from 32pt to 17pt, and flickered
        // between the two as the scroller came and went with the strip's width.
        //
        // `scrollerStyle = .overlay` is the obvious fix and does not work: this
        // scroll view reports the style back as legacy regardless of when it is
        // set. Scrolling does not need a bar. `NSScrollView` still scrolls a
        // document view wider than its clip view with `hasHorizontalScroller` off,
        // the bar was set to autohide anyway, and `autoScroll` already drives
        // `contentView.scroll(to:)` directly during a tab drag.
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = false
        scrollView.documentView = strip
        addSubview(scrollView)

        newTabButton.target = self
        newTabButton.action = #selector(newTabTapped)
        newTabButton.isBordered = false
        newTabButton.bezelStyle = .shadowlessSquare
        newTabButton.contentTintColor = .secondaryLabelColor
        newTabButton.toolTip = "New Tab"
        addSubview(newTabButton)

        // Scroll the strip when a drag hovers near either visible edge.
        strip.autoScroll = { [weak self] stripX in
            guard let self else { return 0 }
            let visible = self.scrollView.contentView
            let edge: CGFloat = 24
            var delta: CGFloat = 0
            if stripX < visible.bounds.minX + edge {
                delta = -12
            } else if stripX > visible.bounds.maxX - edge {
                delta = 12
            }
            guard delta != 0, self.scrollView.documentView != nil else { return 0 }
            let maxX = max(0, self.strip.preferredWidth - visible.bounds.width)
            let next = min(
                max(visible.bounds.origin.x + delta, 0),
                maxX
            )
            guard next != visible.bounds.origin.x else { return 0 }
            visible.scroll(to: NSPoint(x: next, y: 0))
            self.strip.needsLayout = true
            return next - visible.bounds.origin.x
        }
    }

    @objc private func newTabTapped() {
        newTabAction?()
    }

    override func layout() {
        super.layout()
        let buttonSize: CGFloat = 30
        scrollView.frame = NSRect(
            x: 0,
            y: 0,
            width: max(0, bounds.width - buttonSize),
            height: bounds.height
        )
        newTabButton.frame = NSRect(
            x: bounds.maxX - buttonSize + 2,
            y: (bounds.height - 20) / 2,
            width: 20,
            height: 20
        )
        // The strip's height comes from the container, which the window pins to
        // `tabBarHeight`, rather than being read back from the clip view. Reading
        // it back let the scroll view decide the height, which is the coupling
        // that made the tabs change height as the window was resized.
        strip.frame = NSRect(
            x: 0,
            y: 0,
            width: max(strip.preferredWidth, scrollView.contentSize.width),
            height: bounds.height
        )
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }
}
