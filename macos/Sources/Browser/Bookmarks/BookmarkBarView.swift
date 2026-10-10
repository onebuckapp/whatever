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

/// The bookmarks strip that lives between the toolbar and the tab bar.
///
/// Entries are laid out leading-to-trailing by hand in a scroll view, the
/// tab strip's arrangement at a smaller scale: trackpad gestures and mouse
/// wheels scroll the strip, and a fade marks each edge hiding entries. No
/// overflow menu — everything stays reachable by scrolling. The strip never
/// carries a required width: everything below is manual frames, so a bar
/// full of long titles clips instead of pushing the window wider.
@MainActor
final class BookmarkBarView: NSView {
    static let height: CGFloat = 28

    /// A link was activated (left click).
    var onActivate: ((BookmarkNode) -> Void)?
    /// A folder was activated; the menu should pop from the anchor view.
    var onFolderClick: ((BookmarkNode, NSView) -> Void)?
    /// Middle click on a link.
    var onMiddleClick: ((BookmarkNode) -> Void)?
    /// Right-click menu; nil node means the bar background.
    var contextMenuProvider: ((BookmarkNode?) -> NSMenu?)?
    /// A completed drag: (id, parentID, beforeID).
    var onMove: ((String, String?, String?) -> Void)?
    /// Tabs dropped on the bar, with where they landed. The receiver saves
    /// each tab's page as a bookmark, in drag order.
    var onDropTab: (([BrowserTab], BookmarkDropDestination) -> Void)?

    /// The store drags resolve against. Set by the controller.
    var store: BookmarkStore?

    private static let sideInset: CGFloat = 4
    private static let itemSpacing: CGFloat = 2
    private static let itemHeight: CGFloat = 22

    /// Feather width of each edge fade, in points. Same as the tab strip.
    private static let fadeFeather: CGFloat = 24

    private let scrollView = NSScrollView()
    private let content = BookmarkBarContentView()
    private var items: [BookmarkBarItemView] = []
    private let insertionMarker = TabInsertionMarkerView()

    /// Masks the clip view's content: transparent where more entries hide
    /// off that edge, opaque elsewhere. Rebuilt by `refreshFades` whenever
    /// the scroll position, content width, or bar width changes.
    private let fadeMask = CAGradientLayer()
    private var boundsObserver: NSObjectProtocol?

    private var leftFadeVisible = false
    private var rightFadeVisible = false

    /// The fade state, for tests: whether the left / right edge currently
    /// shows its fade.
    var fadesVisibleForTesting: (left: Bool, right: Bool) {
        (leftFadeVisible, rightFadeVisible)
    }

    /// Scroll offset, for tests.
    var scrollOriginXForTesting: CGFloat {
        scrollView.contentView.bounds.origin.x
    }

    /// Scrolls the strip so `offset` becomes the visible origin. For tests.
    func scrollToForTesting(_ offset: CGFloat) {
        let maxX = max(0, contentWidth - scrollView.contentView.bounds.width)
        scrollView.contentView.scroll(to: NSPoint(
            x: TabBarContainerView.snappedOffset(offset, max: maxX), y: 0))
        // A headless test host may not deliver the bounds notification, so
        // refresh directly; in the app the observer covers this too.
        refreshFades()
    }

    /// Scrolls the strip by `dx`, clamped to the content. For tests.
    func scrollHorizontallyForTesting(_ dx: CGFloat) {
        scrollContent(by: dx)
    }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        setUpSubviews()
        registerForDraggedTypes([BookmarkDragPayload.type, TabDragPayload.type])
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
        // Manual layout only, like the tab strip: frames come from `layout`,
        // so an autoresizing mask would snapshot each laid-out width back as
        // a required demand and the bar would push the window wider.
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        // No scroller bars at all: `NSScrollView` reserves layout height for
        // a horizontal scroller whenever one can appear, and still scrolls a
        // wider document view with both scrollers off. Same arrangement as
        // the tab strip.
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = false
        scrollView.documentView = content
        addSubview(scrollView)

        content.translatesAutoresizingMaskIntoConstraints = false
        // Precise horizontal gestures scroll natively through the scroll
        // view; everything else is mapped onto the strip, exactly like the
        // tab strip's document view.
        content.scrollWheelHandler = { [weak self] event in
            self?.handleScrollWheel(event)
        }
        // A drag hovering near either visible edge scrolls hidden entries
        // into reach for the drop.
        content.autoScroll = { [weak self] contentX in
            self?.autoScroll(contentX) ?? 0
        }

        // The mask lives on the scroll view, whose bounds never move: only
        // the clip view's bounds origin changes, so the fades sit at the
        // visible edges, not at the content's ends.
        scrollView.wantsLayer = true
        scrollView.layer?.mask = fadeMask
        fadeMask.startPoint = CGPoint(x: 0, y: 0.5)
        fadeMask.endPoint = CGPoint(x: 1, y: 0.5)

        scrollView.contentView.postsBoundsChangedNotifications = true
        boundsObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: scrollView.contentView,
            queue: .main
        ) { [weak self] _ in
            self?.refreshFades()
        }
    }

    /// Rebuilds the strip's buttons for `nodes`.
    func update(nodes: [BookmarkNode]) {
        for item in items {
            item.removeFromSuperview()
        }
        items = nodes.map(makeItem)
        for item in items {
            content.addSubview(item)
        }
        clearDropIndicators()
        needsLayout = true
        needsDisplay = true
    }

    /// Test seams.
    var itemTitlesForTesting: [String] {
        items.map(\.node.displayTitle)
    }

    /// The laid-out content width: entries plus spacing plus both insets.
    var itemsWidthForTesting: CGFloat { contentWidth }

    override func layout() {
        super.layout()
        scrollView.frame = bounds
        layoutItems()
        let clip = scrollView.contentView
        let overflowing = contentWidth - clip.bounds.width > 0.5
        if !overflowing, clip.bounds.origin.x != 0 {
            // The window widened past the overflow: re-zero a scroll offset
            // nothing clamps anymore, or the strip sits shifted with blank
            // chrome at its leading edge. Same as the tab strip.
            clip.scroll(to: NSPoint(x: 0, y: 0))
        }
        scrollView.reflectScrolledClipView(clip)
        refreshFades()
    }

    /// The content's full width, for the document frame and scroll limits.
    private var contentWidth: CGFloat {
        var total = Self.sideInset
        for (index, item) in items.enumerated() {
            if index > 0 {
                total += Self.itemSpacing
            }
            total += item.intrinsicContentSize.width
        }
        return total + Self.sideInset
    }

    private func layoutItems() {
        let clipWidth = scrollView.contentSize.width
        content.frame = NSRect(
            x: 0,
            y: 0,
            width: max(contentWidth, clipWidth),
            height: bounds.height
        )
        let itemY = (bounds.height - Self.itemHeight) / 2
        var x = Self.sideInset
        for (index, item) in items.enumerated() {
            if index > 0 {
                x += Self.itemSpacing
            }
            let width = item.intrinsicContentSize.width
            item.frame = NSRect(x: x, y: itemY, width: width, height: Self.itemHeight)
            x += width
        }
    }

    // MARK: - Scrolling

    /// Maps wheel deltas onto a horizontal strip offset. Shared with the tab
    /// strip's convention: a device speaking horizontal is trusted as-is,
    /// anything vertical rotates a quarter turn.
    private func handleScrollWheel(_ event: NSEvent) {
        scrollContent(by: TabBarContainerView.stripDelta(
            dx: event.scrollingDeltaX,
            dy: event.scrollingDeltaY,
            precise: event.hasPreciseScrollingDeltas
        ))
    }

    /// Scrolls the strip by `dx`, clamped to the content. No-op when every
    /// entry fits.
    private func scrollContent(by dx: CGFloat) {
        let clip = scrollView.contentView
        let maxX = max(0, contentWidth - clip.bounds.width)
        guard maxX > 0, dx != 0 else { return }
        let next = TabBarContainerView.snappedOffset(clip.bounds.origin.x + dx, max: maxX)
        guard next != clip.bounds.origin.x else { return }
        clip.scroll(to: NSPoint(x: next, y: 0))
        refreshFades()
    }

    /// Scrolls the strip when a drag hovers near either visible edge, so a
    /// hidden entry can be reached for the drop. Same shape as the tab
    /// strip's auto-scroll.
    private func autoScroll(_ contentX: CGFloat) -> CGFloat {
        let visible = scrollView.contentView
        let edge: CGFloat = 24
        var delta: CGFloat = 0
        if contentX < visible.bounds.minX + edge {
            delta = -12
        } else if contentX > visible.bounds.maxX - edge {
            delta = 12
        }
        guard delta != 0, scrollView.documentView != nil else { return 0 }
        let maxX = max(0, contentWidth - visible.bounds.width)
        let next = TabBarContainerView.snappedOffset(visible.bounds.origin.x + delta, max: maxX)
        guard next != visible.bounds.origin.x else { return 0 }
        visible.scroll(to: NSPoint(x: next, y: 0))
        return next - visible.bounds.origin.x
    }

    /// Recomputes which edge fades show. Each side appears only while
    /// entries hide off that side; a fully visible strip stays crisp on
    /// both ends. Same arrangement as the tab strip.
    private func refreshFades() {
        let clip = scrollView.contentView
        let visibleWidth = clip.bounds.width
        guard visibleWidth > 0 else { return }
        let originX = clip.bounds.origin.x
        let hidden = contentWidth - visibleWidth
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

    // MARK: - Drag and drop

    /// Resolves a drag to a destination: the middle of a folder files into
    /// it, an edge reorders before or after the hovered item, and the
    /// background appends at the end of the root level. Nil refuses the drop
    /// (a node onto itself, or a folder into its own subtree). A nil
    /// `draggedID` is a tab drag: a brand-new bookmark that cannot cycle,
    /// so only the hit testing applies.
    private func dropDestination(at point: NSPoint, draggedID: String?) -> BookmarkDropDestination? {
        guard let store else { return nil }
        guard let hit = hitItem(at: point) else {
            // Background: append at the end.
            if let draggedID,
               BookmarkTree.invalidMove(id: draggedID, to: nil, in: store.nodes)
            {
                return nil
            }
            return .reorder(parentID: nil, beforeID: nil)
        }
        let hitNode = hit.node
        // Dropping a bookmark onto itself is not a move.
        guard hitNode.id != draggedID else { return nil }
        let frame = convert(hit.bounds, from: hit)
        let middle = frame.insetBy(dx: frame.width * 0.25, dy: 0).contains(point)
        if hitNode.isFolder, middle {
            if let draggedID,
               BookmarkTree.invalidMove(id: draggedID, to: hitNode.id, in: store.nodes)
            {
                return nil
            }
            return .intoFolder(hitNode.id)
        }
        if let draggedID,
           BookmarkTree.invalidMove(id: draggedID, to: nil, in: store.nodes)
        {
            return nil
        }
        let beforeID: String?
        if point.x < frame.midX {
            beforeID = hitNode.id
        } else {
            beforeID = nextRootID(after: hitNode)
        }
        return .reorder(parentID: nil, beforeID: beforeID)
    }

    private func hitItem(at point: NSPoint) -> BookmarkBarItemView? {
        for item in items {
            if convert(item.bounds, from: item).contains(point) {
                return item
            }
        }
        return nil
    }

    private func nextRootID(after node: BookmarkNode) -> String? {
        guard let store else { return nil }
        let roots = store.roots
        guard let index = roots.firstIndex(where: { $0.id == node.id }) else { return nil }
        let next = roots.index(after: index)
        return next < roots.endIndex ? roots[next].id : nil
    }

    private func showIndicator(for destination: BookmarkDropDestination) {
        switch destination {
        case .intoFolder(let id):
            insertionMarker.isHidden = true
            setDropTarget(id)
        case .reorder(_, let beforeID):
            setDropTarget(nil)
            layoutInsertionMarker(beforeID: beforeID)
        }
    }

    private func setDropTarget(_ id: String?) {
        for item in items {
            item.isDropTarget = item.node.id == id
        }
    }

    private func layoutInsertionMarker(beforeID: String?) {
        let x: CGFloat
        if let beforeID,
           let item = items.first(where: { $0.node.id == beforeID })
        {
            x = convert(item.bounds, from: item).minX - 2
        } else if let last = items.last {
            x = convert(last.bounds, from: last).maxX + 2
        } else {
            x = Self.sideInset + 2
        }
        insertionMarker.frame = NSRect(
            x: x,
            y: 4,
            width: 2,
            height: max(0, bounds.height - 8)
        )
        insertionMarker.isHidden = false
        // Keep it above the clipped items on every show.
        addSubview(insertionMarker, positioned: .above, relativeTo: nil)
    }

    private func clearDropIndicators() {
        insertionMarker.isHidden = true
        setDropTarget(nil)
    }

    /// What is being dragged over the bar: a bookmark by id, or tabs whose
    /// pages want saving. Addressless tabs (homepage, blank pages) carry no
    /// URL worth saving and are filtered out, so a drag of only those is no
    /// drag at all.
    private enum DropPayload {
        case bookmark(String)
        case tabs([BrowserTab])
    }

    private func payload(from sender: NSDraggingInfo) -> DropPayload? {
        guard let store else { return nil }
        if let node = BookmarkDragPayload.node(from: sender, in: store) {
            return .bookmark(node.id)
        }
        let tabs = TabDragPayload.tabs(from: sender).filter { !$0.displayURL.isAddresslessPage }
        guard !tabs.isEmpty else { return nil }
        return .tabs(tabs)
    }

    private func destination(for payload: DropPayload, at point: NSPoint) -> BookmarkDropDestination? {
        switch payload {
        case .bookmark(let id):
            return dropDestination(at: point, draggedID: id)
        case .tabs:
            return dropDestination(at: point, draggedID: nil)
        }
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        draggingUpdated(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard let payload = payload(from: sender) else {
            clearDropIndicators()
            return []
        }
        let point = convert(sender.draggingLocation, from: nil)
        // A drag hovering near either visible edge scrolls hidden entries
        // into reach. Runs before hit testing so the indicator lands on
        // the post-scroll geometry.
        _ = content.autoScroll?(content.convert(point, from: self).x)
        guard let destination = destination(for: payload, at: point) else {
            clearDropIndicators()
            return []
        }
        showIndicator(for: destination)
        return .move
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        clearDropIndicators()
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        clearDropIndicators()
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let payload = payload(from: sender) else {
            return false
        }
        let point = convert(sender.draggingLocation, from: nil)
        return destination(for: payload, at: point) != nil
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        defer { clearDropIndicators() }
        guard let payload = payload(from: sender) else {
            return false
        }
        let point = convert(sender.draggingLocation, from: nil)
        guard let destination = destination(for: payload, at: point) else {
            return false
        }
        switch (payload, destination) {
        case (.bookmark(let id), .intoFolder(let parentID)):
            onMove?(id, parentID, nil)
        case (.bookmark(let id), .reorder(let parentID, let beforeID)):
            onMove?(id, parentID, beforeID)
        case (.tabs(let tabs), _):
            onDropTab?(tabs, destination)
        }
        return true
    }

    /// Test seams.
    func dropDestinationForTesting(at point: NSPoint, draggedID: String?) -> BookmarkDropDestination? {
        dropDestination(at: point, draggedID: draggedID)
    }

    func itemFrameForTesting(_ id: String) -> NSRect? {
        for item in items where item.node.id == id {
            return convert(item.bounds, from: item)
        }
        return nil
    }

    /// Right-click on the strip itself (items handle their own).
    override func rightMouseDown(with event: NSEvent) {
        guard let menu = contextMenuProvider?(nil) else {
            super.rightMouseDown(with: event)
            return
        }
        menu.popUp(
            positioning: nil,
            at: convert(event.locationInWindow, from: nil),
            in: self
        )
    }

    private func makeItem(_ node: BookmarkNode) -> BookmarkBarItemView {
        let item = BookmarkBarItemView(node: node)
        item.onActivate = { [weak self, weak item] in
            guard let self, let item else { return }
            if node.isFolder {
                self.onFolderClick?(node, item)
            } else {
                self.onActivate?(node)
            }
        }
        item.onMiddleClick = { [weak self] in
            guard !node.isFolder else { return }
            self?.onMiddleClick?(node)
        }
        item.contextMenuProvider = { [weak self] in
            self?.contextMenuProvider?(node)
        }
        return item
    }

    /// A hairline along the bottom edge, matching the rest of the chrome's
    /// separator treatment.
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        NSColor.separatorColor.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

/// The scroll view's document: lays out nothing itself (the bar assigns
/// every item frame in `layoutItems`), but intercepts wheel events first —
/// exactly like the tab strip — so a precise horizontal gesture scrolls
/// natively while everything else is mapped onto the strip.
final class BookmarkBarContentView: NSView {
    /// Maps wheel and gesture events the strip does not scroll natively.
    /// Set by the bar.
    var scrollWheelHandler: ((NSEvent) -> Void)?
    /// Scrolls the strip when a drag hovers near a visible edge. Set by
    /// the bar; mirrors the tab strip's `autoScroll`.
    var autoScroll: ((CGFloat) -> CGFloat)?

    override func scrollWheel(with event: NSEvent) {
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
}
