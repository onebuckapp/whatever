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

/// Owns the bookmarks bar's view and its place in the window.
///
/// The bar is always parented between the toolbar and the tab bar; showing
/// and hiding is a height collapse (28 or 0) plus `isHidden`, so the tab
/// bar and the page area follow through the existing constraint chain with
/// no re-pinning. When enabled it shows even with no bookmarks, because its
/// own context menu is the way to create the first one.
///
/// Menus are built per right-click and dispatched through one retained
/// target; the payload on each item carries the command and the node it
/// applies to.
@MainActor
final class BookmarkBarController {
    let view: BookmarkBarView

    /// Test seam: when non-nil, decides visibility instead of the settings
    /// toggle, so layout tests never touch the shared settings document.
    var forceEnabledForTesting: Bool? {
        didSet { refresh() }
    }

    /// Opens a link. `true` means a new tab.
    var onOpen: ((URL, Bool) -> Void)?
    /// Opens the editor card (new bookmark/folder, rename, edit).
    var onPresentEditor: ((BookmarkEditorMode) -> Void)?
    /// Opens the settings modal on the Bookmarks pane.
    var onOpenSettings: (() -> Void)?

    private let store: BookmarkStore
    private let menuTarget = BookmarkMenuTarget()
    private var heightConstraint: NSLayoutConstraint?
    private var cancellables = Set<AnyCancellable>()
    private var lastRoots: [BookmarkNode]?

    /// `store` defaults to the shared store; injected in tests so the bar
    /// can be driven without XPC.
    init(container: NSView, store: BookmarkStore = .shared) {
        self.store = store
        view = BookmarkBarView()
        view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(view)
        heightConstraint = view.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            heightConstraint!,
        ])

        view.onActivate = { [weak self] node in
            self?.open(node, newTab: false)
        }
        view.onFolderClick = { [weak self] node, anchor in
            self?.presentFolderMenu(node, from: anchor)
        }
        view.onMiddleClick = { [weak self] node in
            self?.open(node, newTab: true)
        }
        view.contextMenuProvider = { [weak self] node in
            self?.menu(for: node)
        }
        view.overflowMenuProvider = { [weak self] in
            self?.overflowMenu()
        }
        // Drags resolve against the same store the bar renders; the move
        // itself goes through the store's guarded `move`.
        view.store = store
        view.onMove = { [weak self] id, parentID, beforeID in
            self?.store.move(id, to: parentID, before: beforeID)
        }

        SettingsStore.shared.$settings
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &cancellables)
        store.$nodes
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &cancellables)
        refresh()
    }

    /// Whether the bar is currently occupying its slot.
    var isVisible: Bool { !view.isHidden }

    private func refresh() {
        let enabled = forceEnabledForTesting ?? SettingsStore.shared.settings.bookmarks.showBar
        heightConstraint?.constant = enabled ? BookmarkBarView.height : 0
        view.isHidden = !enabled

        let roots = store.roots
        if lastRoots != roots {
            lastRoots = roots
            view.update(nodes: roots)
        }
        // The feature is on but nothing is cached yet: read the store. The
        // in-flight guard in the store keeps setting drags from piling up
        // round trips; failures simply leave the bar empty.
        if enabled, !store.isLoaded {
            Task { await store.load() }
        }
    }

    // MARK: - Actions

    private func open(_ node: BookmarkNode, newTab: Bool) {
        guard node.kind == .link,
              let urlString = node.url,
              let url = URL(string: urlString)
        else {
            return
        }
        onOpen?(url, newTab)
    }

    private func handle(_ payload: BookmarkMenuPayload) {
        switch payload.action {
        case .newFolder:
            onPresentEditor?(.newFolder(parentID: payload.parentID))
        case .newBookmark:
            onPresentEditor?(.newLink(prefillTitle: "", prefillURL: "", parentID: payload.parentID))
        case .open:
            if let node = payload.nodeID.flatMap(store.node) {
                open(node, newTab: false)
            }
        case .openInNewTab:
            if let node = payload.nodeID.flatMap(store.node) {
                open(node, newTab: true)
            }
        case .copyURL:
            if let node = payload.nodeID.flatMap(store.node), let urlString = node.url {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(urlString, forType: .string)
            }
        case .edit:
            if let id = payload.nodeID {
                onPresentEditor?(.edit(id: id))
            }
        case .delete:
            requestDelete(payload.nodeID)
        case .openAllInNewTabs:
            openAll(in: payload.nodeID)
        case .openBookmarksSettings:
            onOpenSettings?()
        }
    }

    /// Deletes a link at once; a non-empty folder asks first, because one
    /// context-menu click should not silently take a whole subtree.
    private func requestDelete(_ id: String?) {
        guard let id, let node = store.node(id) else { return }
        let doomed = BookmarkTree.descendantIDs(of: id, in: store.nodes)
        guard node.isFolder, !doomed.isEmpty else {
            store.delete(id)
            return
        }
        let alert = NSAlert()
        alert.messageText = "Delete \u{201C}\(node.displayTitle)\u{201D}?"
        alert.informativeText = doomed.count == 1
            ? "The folder and the item inside it will be removed."
            : "The folder and the \(doomed.count) items inside it will be removed."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        if let window = view.window {
            alert.beginSheetModal(for: window) { [weak self] response in
                guard response == .alertFirstButtonReturn else { return }
                self?.store.delete(id)
            }
        } else {
            store.delete(id)
        }
    }

    /// Every link in a folder's subtree, in tree order, each in its own tab.
    private func openAll(in id: String?) {
        guard let id, let folder = store.node(id), folder.isFolder else { return }
        var urls: [URL] = []
        func collect(_ parentID: String) {
            for child in store.children(of: parentID) {
                if child.isFolder {
                    collect(child.id)
                } else if let urlString = child.url, let url = URL(string: urlString) {
                    urls.append(url)
                }
            }
        }
        collect(id)
        for url in urls {
            onOpen?(url, true)
        }
    }

    // MARK: - Menus

    private func prepareTarget() {
        menuTarget.onCommand = { [weak self] payload in
            self?.handle(payload)
        }
    }

    private func menu(for node: BookmarkNode?) -> NSMenu {
        prepareTarget()
        guard let node else {
            return BookmarkContextMenu.barMenu(target: menuTarget)
        }
        if node.isFolder {
            return BookmarkContextMenu.folderMenu(node: node, target: menuTarget)
        }
        return BookmarkContextMenu.linkMenu(node: node, target: menuTarget)
    }

    private func presentFolderMenu(_ node: BookmarkNode, from anchor: NSView) {
        guard node.isFolder else { return }
        prepareTarget()
        let menu = BookmarkContextMenu.itemsMenu(
            parentID: node.id,
            emptyTitle: "Empty",
            store: store,
            target: menuTarget
        )
        menu.popUp(
            positioning: nil,
            at: NSPoint(x: 0, y: anchor.bounds.minY - 4),
            in: anchor
        )
    }

    private func overflowMenu() -> NSMenu {
        prepareTarget()
        let menu = BookmarkContextMenu.itemsMenu(
            parentID: nil,
            emptyTitle: "No Bookmarks",
            store: store,
            target: menuTarget
        )
        menu.addItem(.separator())
        BookmarkContextMenu.add(
            "Edit Bookmarks\u{2026}",
            .openBookmarksSettings,
            parentID: nil,
            nodeID: nil,
            to: menu,
            target: menuTarget
        )
        return menu
    }
}
