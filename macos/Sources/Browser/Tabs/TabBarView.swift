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

protocol TabBarViewDelegate: AnyObject {
    func tabBar(_ tabBar: TabBarView, didSelect tab: BrowserTab)
    func tabBar(_ tabBar: TabBarView, didClose tab: BrowserTab)
    func tabBar(_ tabBar: TabBarView, menuFor tab: BrowserTab) -> NSMenu?
    /// The tab's mute button was pressed.
    func tabBar(_ tabBar: TabBarView, didToggleMuteFor tab: BrowserTab)
    /// A tab was dropped on this bar at the given insertion index.
    func tabBar(_ tabBar: TabBarView, didDropTab tab: BrowserTab, at index: Int)
    /// The merged group cell was pressed: show the split.
    func tabBarDidSelectGroup(_ tabBar: TabBarView)
    /// The merged group cell's close button was pressed: close both members.
    func tabBarDidCloseGroup(_ tabBar: TabBarView)
    /// Context menu for the merged group cell.
    func tabBarGroupMenu(_ tabBar: TabBarView) -> NSMenu?
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

    /// Given a strip-local rect, scrolls it into the visible area. Set by
    /// the container, which owns the scroll view; mirrors `autoScroll`.
    var scrollIntoView: ((NSRect) -> Void)?

    /// Receives wheel and gesture events the strip does not scroll natively
    /// (mouse wheels, vertical gestures). Set by the container, which maps
    /// them onto the strip.
    var scrollWheelHandler: ((NSEvent) -> Void)?

    /// Window that owns this bar; drops are routed back through the
    /// coordinator using it as the destination.
    weak var owner: BrowserWindowController?

    private(set) var tabs: [BrowserTab] = []
    private var selectedTabID: UUID?
    /// Set when the selection changes and cleared once `layout` has scrolled
    /// it into view. Selection repaints happen on every `setTabs`, but only
    /// a changed selection may move the scroll position — otherwise a
    /// background title update would yank the strip out from under the user.
    private var pendingScrollToSelection = false
    /// The sticky split pair, in pane order. The bar renders it as one
    /// merged cell only while the pair sits adjacent; anything else draws
    /// two lone cells.
    private var splitPair: (leading: UUID, trailing: UUID)?
    /// The merged cell for the pair above, or nil when there is none.
    private var groupCell: TabGroupCellView?
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
        // Manual layout only: `TabBarContainerView.layout` sets this view's
        // frame from `preferredWidth`, so an autoresizing mask would bake
        // each laid-out width back as a required constraint. Those snapshots
        // ratchet: a transiently wide strip (long titles, many tabs) sticks
        // as a demand, and the window — which has no fixed width of its own
        // — grows to satisfy it and can never shrink back.
        translatesAutoresizingMaskIntoConstraints = false
        registerForDraggedTypes([TabDragPayload.type])
    }

    override func scrollWheel(with event: NSEvent) {
        // A trackpad horizontal gesture scrolls natively — smooth, with
        // momentum and rubber-banding — through the scroll view. Everything
        // else reaches the container's mapping: a mouse wheel only speaks
        // vertical, which a horizontal-only scroll view would swallow.
        if event.hasPreciseScrollingDeltas && event.scrollingDeltaX != 0 {
            super.scrollWheel(with: event)
            return
        }
        if let scrollWheelHandler {
            scrollWheelHandler(event)
        } else {
            super.scrollWheel(with: event)
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Content

    func setTabs(
        _ tabs: [BrowserTab],
        selectedTabID: UUID?,
        splitPair: (leading: UUID, trailing: UUID)? = nil
    ) {
        self.tabs = tabs
        if self.selectedTabID != selectedTabID {
            pendingScrollToSelection = true
        }
        self.selectedTabID = selectedTabID
        self.splitPair = splitPair

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

        // One merged cell for an adjacent pair, lone cells otherwise. The
        // members' own cells leave the hierarchy while grouped and come
        // back on dissolve.
        if let joined = joinedPairState() {
            let cell: TabGroupCellView
            if let existing = groupCell {
                cell = existing
            } else {
                cell = makeGroupCell(leading: joined.leading, trailing: joined.trailing)
                groupCell = cell
            }
            cell.configure(leading: joined.leading, trailing: joined.trailing)
            if cell.superview == nil {
                addSubview(cell)
            }
            itemViews[joined.leading.id]?.removeFromSuperview()
            itemViews[joined.trailing.id]?.removeFromSuperview()
            for tab in tabs where tab.id != joined.leading.id && tab.id != joined.trailing.id {
                if let item = itemViews[tab.id], item.superview == nil {
                    addSubview(item)
                }
            }
            cell.setSelected(
                selectedTabID == joined.leading.id || selectedTabID == joined.trailing.id)
        } else {
            groupCell?.removeFromSuperview()
            groupCell = nil
            for tab in tabs {
                if let item = itemViews[tab.id], item.superview == nil {
                    addSubview(item)
                }
            }
        }

        hideInsertionMarker()
        needsLayout = true
        superview?.needsLayout = true
    }

    /// The sticky pair with its tabs, only when it sits adjacent in pane
    /// order and can render as one cell. The window pulls the pair together
    /// on formation, so anything else means the order changed underneath
    /// and the cells fall back to lone.
    private func joinedPairState() -> (leading: BrowserTab, trailing: BrowserTab)? {
        guard let pair = splitPair,
              let leadingIndex = tabs.firstIndex(where: { $0.id == pair.leading }),
              tabs.indices.contains(leadingIndex + 1),
              tabs[leadingIndex + 1].id == pair.trailing,
              let leading = tabs.first(where: { $0.id == pair.leading }),
              let trailing = tabs.first(where: { $0.id == pair.trailing })
        else { return nil }
        return (leading, trailing)
    }

    /// Tabs as drawn: the grouped trailing member takes no cell of its own.
    private func visualTabs() -> [BrowserTab] {
        guard let joined = joinedPairState() else { return tabs }
        return tabs.filter { $0.id != joined.trailing.id }
    }

    /// The view drawn for a visual tab: the merged cell at the pair's slot,
    /// the lone cell everywhere else.
    private func viewForVisualTab(_ tab: BrowserTab) -> NSView? {
        if let joined = joinedPairState(), tab.id == joined.leading.id {
            return groupCell
        }
        return itemViews[tab.id]
    }

    /// Width of a visual tab: both members' shares for the merged cell.
    private func visualWidth(for tab: BrowserTab) -> CGFloat {
        if let joined = joinedPairState(), tab.id == joined.leading.id,
           let trailing = tabs.first(where: { $0.id == joined.trailing.id }) {
            return width(for: tab) + width(for: trailing)
        }
        return width(for: tab)
    }

    /// Width the strip wants; the container scrolls when this exceeds
    /// the visible width. The new-tab button is pinned by the container
    /// now, so it no longer reserves space here.
    var preferredWidth: CGFloat {
        var total: CGFloat = 0
        for tab in visualTabs() {
            total += visualWidth(for: tab) + 4
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
        for tab in visualTabs() {
            guard let view = viewForVisualTab(tab) else { continue }
            view.frame = NSRect(x: x, y: 4, width: visualWidth(for: tab), height: tabHeight)
            x += view.frame.width + 4
        }
        if insertionIndex != nil {
            layoutInsertionMarker()
        }
        if pendingScrollToSelection {
            pendingScrollToSelection = false
            scrollSelectedIntoView()
        }
        // Cells moved; the cursor did not. Re-resolve hover from where it
        // is, or stale hovers accumulate on every scrolled-past cell.
        refreshHoverForCurrentMouse()
    }

    /// Scrolls the selected cell into the visible area, if it is not there.
    /// Runs from `layout` so the frames are current; the container performs
    /// the scroll.
    private func scrollSelectedIntoView() {
        guard let id = selectedTabID,
              let tab = tabs.first(where: { $0.id == id }),
              let view = viewForVisualTab(tab)
        else { return }
        scrollIntoView?(view.frame)
    }

    /// Re-resolves which cell the cursor is over from a strip-local point.
    /// Scrolling, resizing, and tab changes all move cells under a
    /// stationary cursor without entered/exited events, so `layout` calls
    /// the cursor-based variant below on every pass; this point-based one
    /// is the testable core. Nil clears every hover.
    func refreshHover(at point: NSPoint?) {
        for tab in visualTabs() {
            guard let view = viewForVisualTab(tab) else { continue }
            let hovered = point.map { view.frame.contains($0) } ?? false
            if let cell = view as? TabBarItemView {
                cell.setHovered(hovered)
            } else if let group = view as? TabGroupCellView {
                group.setHovered(hovered)
            }
        }
    }

    /// Re-resolves hover from the live cursor position. A no-window strip
    /// (tests, teardown) clears instead of guessing.
    private func refreshHoverForCurrentMouse() {
        guard let window, window.isKeyWindow else {
            refreshHover(at: nil)
            return
        }
        refreshHover(at: convert(window.mouseLocationOutsideOfEventStream, from: nil))
    }

    /// IDs of the cells currently hovered, in display order. For tests —
    /// at most one, which is the point of the refresh.
    var hoveredTabIDsForTesting: [UUID] {
        visualTabs().filter {
            guard let view = viewForVisualTab($0) else { return false }
            if let cell = view as? TabBarItemView {
                return cell.isHoveredForTesting
            }
            return (view as? TabGroupCellView)?.isHoveredForTesting == true
        }.map(\.id)
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
    /// Index in `tabs` where the dragged tab should land, given
    /// the pointer position. Clamped so pinned tabs stay leading and
    /// normal tabs cannot move into the pinned region.
    ///
    /// Computed over the visual cells: a grouped trailing member takes no
    /// cell, and a dragged group excludes both members. The visual position
    /// maps back to a model index — the hidden trailing member sits
    /// immediately after its leading tab, so "before the next visual tab"
    /// already means "after the group".
    func insertionIndex(forDragged dragged: BrowserTab, at point: NSPoint) -> Int {
        let hidden: Set<UUID> = {
            guard let joined = joinedPairState(),
                  dragged.id == joined.leading.id || dragged.id == joined.trailing.id
            else { return [dragged.id] }
            return [joined.leading.id, joined.trailing.id]
        }()
        let orderedModel = tabs.filter { !hidden.contains($0.id) }
        let visual = visualTabs().filter { !hidden.contains($0.id) }
        var position = visual.count
        for (offset, tab) in visual.enumerated() {
            guard let view = viewForVisualTab(tab) else { continue }
            if point.x < view.frame.midX {
                position = offset
                break
            }
        }
        let index: Int
        if position >= visual.count {
            index = orderedModel.count
        } else {
            index = orderedModel.firstIndex(where: { $0.id == visual[position].id })
                ?? orderedModel.count
        }

        let pinnedCount = tabs.filter(\.presentation.isPinned).count
        if dragged.presentation.isPinned {
            return min(index, pinnedCount)
        }
        return max(index, pinnedCount)
    }

    private func layoutInsertionMarker() {
        guard let index = insertionIndex else { return }
        let x: CGFloat
        if index >= tabs.count {
            if let last = visualTabs().last, let view = viewForVisualTab(last) {
                x = view.frame.maxX + 2
            } else {
                x = 6 + 2
            }
        } else if index == 0 {
            x = 4
        } else {
            // The model tab just before the insertion point; a hidden
            // trailing member has no cell, so step back to the group cell,
            // whose far edge is the group's far edge.
            var step = index - 1
            while step >= 0 && isHiddenGroupMember(tabs[step].id) {
                step -= 1
            }
            let edge: CGFloat
            if step >= 0, let view = viewForVisualTab(tabs[step]) {
                edge = view.frame.maxX
            } else {
                edge = 6
            }
            x = edge + 2
        }
        insertionMarker.frame = NSRect(
            x: x,
            y: 4,
            width: 2,
            height: max(0, bounds.height - 4)
        )
    }

    /// Whether this tab is the grouped trailing member, which takes no
    /// cell of its own.
    private func isHiddenGroupMember(_ id: UUID) -> Bool {
        guard let joined = joinedPairState() else { return false }
        return id == joined.trailing.id
    }

    private func hideInsertionMarker() {
        insertionIndex = nil
        insertionMarker.isHidden = true
    }

    private func autoScroll(for point: NSPoint) {
        _ = autoScroll?(point.x)
    }

    // MARK: - Private

    private func makeGroupCell(leading: BrowserTab, trailing: BrowserTab) -> TabGroupCellView {
        let cell = TabGroupCellView(leading: leading, trailing: trailing)
        cell.onPress = { [weak self] in
            guard let self else { return }
            self.delegate?.tabBarDidSelectGroup(self)
        }
        cell.onClose = { [weak self] in
            guard let self else { return }
            self.delegate?.tabBarDidCloseGroup(self)
        }
        cell.contextMenuProvider = { [weak self] in
            guard let self else { return nil }
            return self.delegate?.tabBarGroupMenu(self)
        }
        cell.onDragEnded = { [weak self] screenPoint in
            guard let self else { return }
            self.dragEndedGroup(atScreenPoint: screenPoint)
        }
        return cell
    }

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

    /// A group-cell drag that ended outside every window carries the whole
    /// group into a new window, still grouped.
    private func dragEndedGroup(atScreenPoint point: NSPoint) {
        guard let joined = joinedPairState(),
              let owner
        else { return }
        let overWindow = BrowserCoordinator.shared.windows.contains {
            $0.window?.frame.contains(point) == true
        }
        guard !overWindow else { return }
        BrowserCoordinator.shared.detachGroup(
            [joined.leading, joined.trailing],
            from: owner,
            atScreenPoint: point
        )
    }
}

// MARK: - NSDraggingDestination

extension TabBarView {
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        draggingUpdated(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        let dragged = TabDragPayload.tabs(from: sender)
        guard let first = dragged.first else { return [] }
        let point = convert(sender.draggingLocation, from: nil)
        let index = insertionIndex(forDragged: first, at: point)

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
        !TabDragPayload.tabs(from: sender).isEmpty
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        defer { hideInsertionMarker() }
        let dragged = TabDragPayload.tabs(from: sender)
        guard !dragged.isEmpty else { return false }
        let index = insertionIndex ?? insertionIndex(forDragged: dragged[0], at: .zero)
        // A drop on this bar is either a same-window reorder or a move
        // in from another window; a pair travels as one unit either way.
        // Both are the coordinator's job.
        if let owner {
            if dragged.count == 2 {
                BrowserCoordinator.shared.moveTabs(dragged, to: index, in: owner)
            } else if let tab = dragged.first {
                BrowserCoordinator.shared.moveTab(tab, to: index, in: owner)
            }
            return true
        }
        return false
    }
}

/// Window chrome around the strip: horizontal scrolling with no visible
/// bar, a fade at each hidden edge, and the new-tab button pinned at the
/// visible trailing edge so it never scrolls away with the tabs.
final class TabBarContainerView: NSView {
    let strip = TabBarView()
    private let scrollView = NSScrollView()
    /// Pinned at the trailing edge, outside the scroll view: the strip
    /// scrolls underneath nothing, and the right fade ends at its gutter.
    private let newTabButton = BrowserToolbarButton()
    var newTabAction: (() -> Void)?

    /// Gutter reserved for the pinned button: its width plus breathing room
    /// on each side.
    private static let newTabReserve = BrowserToolbarButton.outerWidth + 8

    /// Feather width of each edge fade, in points.
    private static let fadeFeather: CGFloat = 24

    /// Masks the clip view's content: transparent where more tabs hide off
    /// that edge, opaque elsewhere. Rebuilt by `refreshFades` whenever the
    /// scroll position, strip width, or container width changes.
    private let fadeMask = CAGradientLayer()
    private var boundsObserver: NSObjectProtocol?

    /// The fade state, for tests: whether the left / right edge currently
    /// shows its fade.
    var fadesVisibleForTesting: (left: Bool, right: Bool) {
        (leftFadeVisible, rightFadeVisible)
    }

    private var leftFadeVisible = false
    private var rightFadeVisible = false

    /// Scroll offset and button frame, for tests.
    var scrollOriginXForTesting: CGFloat {
        scrollView.contentView.bounds.origin.x
    }

    var newTabButtonFrameForTesting: NSRect {
        newTabButton.frame
    }

    /// Scrolls the strip so `offset` becomes the visible origin. For tests.
    func scrollToForTesting(_ offset: CGFloat) {
        let maxX = max(0, strip.preferredWidth - scrollView.contentView.bounds.width)
        scrollView.contentView.scroll(to: NSPoint(x: min(max(offset, 0), maxX), y: 0))
        // A headless test host may not deliver the bounds notification, so
        // refresh directly; in the app the observer covers this too.
        refreshFades()
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: 36)
    }

    init(newTabAction: @escaping () -> Void) {
        super.init(frame: .zero)
        // Auto Layout positions this container; autoresizing masks would
        // fight the height constraint the window chrome installs.
        translatesAutoresizingMaskIntoConstraints = false
        self.newTabAction = newTabAction
        setUpSubviews()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        if let boundsObserver {
            NotificationCenter.default.removeObserver(boundsObserver)
        }
    }

    private func setUpSubviews() {
        // Manual layout only, like the strip: `layout` assigns the frame from
        // the container bounds, so a mask would snapshot it back as a demand.
        // Same ratchet as the strip's — see its init.
        scrollView.translatesAutoresizingMaskIntoConstraints = false
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

        // Same glyph treatment as the top bar buttons: the default cut
        // renders ~16pt tall, and 13.5 lands ~18 with a medium weight.
        newTabButton.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "New Tab")?
            .withSymbolConfiguration(.init(pointSize: 13.5, weight: .medium))
        newTabButton.toolTip = "New Tab"
        newTabButton.target = self
        newTabButton.action = #selector(newTabTapped)
        addSubview(newTabButton)

        // The mask lives on the scroll view, whose bounds never move: only
        // the clip view's bounds origin changes as the strip scrolls. The
        // fades therefore sit at the visible edges, not at the strip's ends
        // — the same arrangement as the crawl ticker's container mask.
        scrollView.wantsLayer = true
        scrollView.layer?.mask = fadeMask
        fadeMask.startPoint = CGPoint(x: 0, y: 0.5)
        fadeMask.endPoint = CGPoint(x: 1, y: 0.5)

        // Refresh the fades whenever the strip scrolls: drags, wheel,
        // trackpad, and the programmatic scrolls below all move the clip
        // view's bounds origin.
        scrollView.contentView.postsBoundsChangedNotifications = true
        boundsObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: scrollView.contentView,
            queue: .main
        ) { [weak self] _ in
            self?.refreshFades()
        }

        // Scrolls a strip-local rect into the visible area with a small
        // margin, clamped to the strip. The strip asks for this when the
        // selection changes; the y origin stays put, this bar scrolls
        // horizontally only.
        strip.scrollIntoView = { [weak self] rect in
            guard let self else { return }
            let clip = self.scrollView.contentView
            let visibleWidth = clip.bounds.width
            guard visibleWidth > 0 else { return }
            let margin: CGFloat = 8
            var originX = clip.bounds.origin.x
            if rect.minX < originX + margin {
                originX = rect.minX - margin
            } else if rect.maxX > originX + visibleWidth - margin {
                originX = rect.maxX - visibleWidth + margin
            } else {
                return
            }
            let maxX = max(0, self.strip.preferredWidth - visibleWidth)
            originX = min(max(originX, 0), maxX)
            guard originX != clip.bounds.origin.x else { return }
            clip.scroll(to: NSPoint(x: originX, y: 0))
            self.strip.needsLayout = true
        }

        // Maps wheel and gesture events onto the strip. Precise horizontal
        // gestures scroll natively through the scroll view (see the strip's
        // `scrollWheel`); this covers the rest, which reaches here either
        // through the strip's handler or directly over the pinned button.
        strip.scrollWheelHandler = { [weak self] event in
            self?.handleScrollWheel(event)
        }

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

    override func scrollWheel(with event: NSEvent) {
        // Events landing on the container itself — the pinned button and
        // the gutter. Same mapping as the strip's.
        handleScrollWheel(event)
    }

    /// Maps wheel deltas onto a horizontal strip offset. A device speaking
    /// horizontal is trusted as-is; anything vertical rotates a quarter
    /// turn, so wheel-down moves toward the trailing tabs exactly like
    /// shift+wheel anywhere else. Static so the sign convention is testable
    /// without synthesizing NSEvents.
    static func stripDelta(dx: CGFloat, dy: CGFloat, precise: Bool) -> CGFloat {
        if dx != 0 {
            return dx
        }
        // A mouse notch reports ±1: scaled to a useful step, about half a
        // minimum-width tab. Precise gestures already speak in points.
        return -dy * (precise ? 1 : 40)
    }

    private func handleScrollWheel(_ event: NSEvent) {
        scrollStrip(by: Self.stripDelta(
            dx: event.scrollingDeltaX,
            dy: event.scrollingDeltaY,
            precise: event.hasPreciseScrollingDeltas
        ))
    }

    /// Scrolls the strip by `dx`, clamped to the strip. No-op when every
    /// tab fits.
    private func scrollStrip(by dx: CGFloat) {
        let clip = scrollView.contentView
        let maxX = max(0, strip.preferredWidth - clip.bounds.width)
        guard maxX > 0, dx != 0 else { return }
        let next = min(max(clip.bounds.origin.x + dx, 0), maxX)
        guard next != clip.bounds.origin.x else { return }
        clip.scroll(to: NSPoint(x: next, y: 0))
        strip.needsLayout = true
        refreshFades()
    }

    /// Scrolls the strip by `dx`, clamped to the strip. For tests.
    func scrollHorizontallyForTesting(_ dx: CGFloat) {
        scrollStrip(by: dx)
    }

    override func layout() {
        super.layout()
        // The scroll view stops at the pinned button's gutter; the button
        // sits in the gutter, vertically centered on the strip.
        let reserve = Self.newTabReserve
        scrollView.frame = NSRect(
            x: 0,
            y: 0,
            width: max(0, bounds.width - reserve),
            height: bounds.height
        )
        newTabButton.frame = NSRect(
            x: bounds.width - reserve + (reserve - BrowserToolbarButton.outerWidth) / 2,
            y: 4 + (max(0, bounds.height - 4) - BrowserToolbarButton.outerHeight) / 2,
            width: BrowserToolbarButton.outerWidth,
            height: BrowserToolbarButton.outerHeight
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
        refreshFades()
    }

    /// Recomputes which edge fades show. Each side appears only while tabs
    /// hide off that side; a fully visible strip stays crisp on both ends.
    /// The mask's feather is a share of the *visible* width, so it keeps its
    /// size as the window resizes rather than stretching with the strip.
    private func refreshFades() {
        let clip = scrollView.contentView
        let visibleWidth = clip.bounds.width
        guard visibleWidth > 0 else { return }
        let originX = clip.bounds.origin.x
        let hidden = strip.preferredWidth - visibleWidth
        leftFadeVisible = originX > 0.5 && hidden > 0.5
        rightFadeVisible = hidden > 0.5 && originX < hidden - 0.5
        fadeMask.contentsScale = window?.backingScaleFactor ?? 2
        // The scroll view's own bounds: origin zero, always. The mask is
        // positioned in that space, so it never drifts with the scroll.
        fadeMask.frame = CGRect(origin: .zero, size: scrollView.bounds.size)
        let clear = NSColor.white.withAlphaComponent(0).cgColor
        let solid = NSColor.white.cgColor
        let feather = min(Self.fadeFeather / visibleWidth, 0.45)
        fadeMask.colors = [
            leftFadeVisible ? clear : solid,
            solid,
            solid,
            rightFadeVisible ? clear : solid,
        ]
        fadeMask.locations = [0, feather, 1 - feather, 1] as [NSNumber]
    }
}
