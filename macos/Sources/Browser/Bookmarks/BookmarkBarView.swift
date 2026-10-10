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
/// Entries are laid out leading-to-trailing in a clipped container; when
/// they no longer fit, a chevron appears at the trailing edge and the
/// overflow is reachable through its menu. The strip never carries a
/// required width: the stack has no trailing pin and low compression
/// resistance, so a bar full of long titles clips instead of pushing the
/// window wider.
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
    /// The overflow chevron's menu.
    var overflowMenuProvider: (() -> NSMenu?)?
    /// A completed drag: (id, parentID, beforeID).
    var onMove: ((String, String?, String?) -> Void)?
    /// Tabs dropped on the bar, with where they landed. The receiver saves
    /// each tab's page as a bookmark, in drag order.
    var onDropTab: (([BrowserTab], BookmarkDropDestination) -> Void)?

    /// The store drags resolve against. Set by the controller.
    var store: BookmarkStore?

    private static let sideInset: CGFloat = 4
    private static let overflowReserve: CGFloat = 34

    private let itemsContainer = NSView()
    private let stack = NSStackView()
    private let overflowButton = BrowserToolbarButton()
    private let insertionMarker = TabInsertionMarkerView()
    private var itemsTrailing: NSLayoutConstraint!
    private var nodes: [BookmarkNode] = []

    init() {
        super.init(frame: .zero)
        wantsLayer = true

        itemsContainer.wantsLayer = true
        itemsContainer.layer?.masksToBounds = true
        itemsContainer.translatesAutoresizingMaskIntoConstraints = false

        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false

        overflowButton.image = NSImage(
            systemSymbolName: "chevron.right.2",
            accessibilityDescription: "More bookmarks"
        )?.withSymbolConfiguration(.init(pointSize: 10, weight: .semibold))
        overflowButton.toolTip = "More bookmarks"
        overflowButton.target = self
        overflowButton.action = #selector(showOverflow)
        overflowButton.isHidden = true

        addSubview(itemsContainer)
        itemsContainer.addSubview(stack)
        addSubview(overflowButton)
        addSubview(insertionMarker)

        registerForDraggedTypes([BookmarkDragPayload.type, TabDragPayload.type])

        itemsTrailing = itemsContainer.trailingAnchor.constraint(
            equalTo: trailingAnchor,
            constant: -Self.sideInset
        )
        NSLayoutConstraint.activate([
            itemsContainer.leadingAnchor.constraint(
                equalTo: leadingAnchor,
                constant: Self.sideInset
            ),
            itemsContainer.topAnchor.constraint(equalTo: topAnchor),
            itemsContainer.bottomAnchor.constraint(equalTo: bottomAnchor),
            itemsTrailing,

            stack.leadingAnchor.constraint(equalTo: itemsContainer.leadingAnchor),
            stack.topAnchor.constraint(equalTo: itemsContainer.topAnchor),
            stack.bottomAnchor.constraint(equalTo: itemsContainer.bottomAnchor),

            overflowButton.trailingAnchor.constraint(
                equalTo: trailingAnchor,
                constant: -Self.sideInset
            ),
            overflowButton.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Rebuilds the strip's buttons for `nodes`.
    func update(nodes: [BookmarkNode]) {
        self.nodes = nodes
        for view in stack.arrangedSubviews {
            stack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        for node in nodes {
            stack.addArrangedSubview(makeItem(node))
        }
        clearDropIndicators()
        needsLayout = true
        needsDisplay = true
    }

    /// Test seams.
    var itemTitlesForTesting: [String] {
        stack.arrangedSubviews.compactMap { ($0 as? BookmarkBarItemView)?.node.displayTitle }
    }

    var isOverflowVisibleForTesting: Bool { !overflowButton.isHidden }

    var itemsWidthForTesting: CGFloat { stack.fittingSize.width }

    override func layout() {
        super.layout()
        updateOverflow()
    }

    /// Shows the chevron exactly when the entries outgrow the strip.
    ///
    /// The available width is computed from the current reserve state, not
    /// from the container's laid-out frame, so one pass is self-consistent
    /// and the visibility cannot oscillate between passes.
    private func updateOverflow() {
        let reserved = overflowButton.isHidden ? 0 : Self.overflowReserve
        let available = bounds.width - Self.sideInset * 2 - reserved
        let needsOverflow = !nodes.isEmpty
            && bounds.width > 0
            && stack.fittingSize.width > available + 0.5
        if needsOverflow == overflowButton.isHidden {
            overflowButton.isHidden = !needsOverflow
        }
        let desiredTrailing = -(Self.sideInset + (needsOverflow ? Self.overflowReserve : 0))
        if itemsTrailing.constant != desiredTrailing {
            itemsTrailing.constant = desiredTrailing
        }
    }

    @objc private func showOverflow() {
        guard let menu = overflowMenuProvider?() else { return }
        menu.popUp(
            positioning: nil,
            at: NSPoint(x: 0, y: overflowButton.bounds.minY - 4),
            in: overflowButton
        )
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
        for case let item as BookmarkBarItemView in stack.arrangedSubviews {
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
        for case let item as BookmarkBarItemView in stack.arrangedSubviews {
            item.isDropTarget = item.node.id == id
        }
    }

    private func layoutInsertionMarker(beforeID: String?) {
        let x: CGFloat
        if let beforeID,
           let item = stack.arrangedSubviews
               .compactMap({ $0 as? BookmarkBarItemView })
               .first(where: { $0.node.id == beforeID })
        {
            x = convert(item.bounds, from: item).minX - 2
        } else if let last = stack.arrangedSubviews.last {
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
        for case let item as BookmarkBarItemView in stack.arrangedSubviews
        where item.node.id == id {
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
