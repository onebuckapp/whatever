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

/// Identifies a bookmark context-menu command. Strings are stored on the
/// menu items so items stay independent of the menu's target lifetime.
enum BookmarkMenuAction: String {
    case newFolder
    case newBookmark
    case open
    case openInNewTab
    case copyURL
    case edit
    case delete
    case openAllInNewTabs
    case openBookmarksSettings
}

/// One menu item's command, boxed for `representedObject` so a single
/// retained target serves every menu.
struct BookmarkMenuPayload {
    let action: BookmarkMenuAction
    /// The item the command applies to; nil for bar-background commands.
    let nodeID: String?
    /// The folder new items should be created in; nil for the root level.
    let parentID: String?
}

/// Retained by the bar controller so `NSMenuItem`'s weak target stays alive
/// while a menu is on screen.
@MainActor
final class BookmarkMenuTarget: NSObject {
    var onCommand: ((BookmarkMenuPayload) -> Void)?

    /// Named to avoid `NSObject.perform(_:)`, for the same reason as the tab
    /// menu target: a method literally called `perform` collides with the
    /// inherited selector-based API.
    @objc func handleMenuItem(_ sender: NSMenuItem) {
        guard let payload = sender.representedObject as? BookmarkMenuPayload else { return }
        onCommand?(payload)
    }
}

/// Builds the bookmark menus: bar background, one link, one folder, and the
/// folder contents used by both the folder dropdown and the overflow
/// chevron.
@MainActor
enum BookmarkContextMenu {
    static func barMenu(target: BookmarkMenuTarget) -> NSMenu {
        let menu = NSMenu()
        add("New Folder\u{2026}", .newFolder, parentID: nil, nodeID: nil, to: menu, target: target)
        add("New Bookmark\u{2026}", .newBookmark, parentID: nil, nodeID: nil, to: menu, target: target)
        menu.addItem(.separator())
        add("Open Bookmarks Settings", .openBookmarksSettings, parentID: nil, nodeID: nil, to: menu, target: target)
        return menu
    }

    static func linkMenu(node: BookmarkNode, target: BookmarkMenuTarget) -> NSMenu {
        let menu = NSMenu()
        add("Open", .open, parentID: nil, nodeID: node.id, to: menu, target: target)
        add("Open in New Tab", .openInNewTab, parentID: nil, nodeID: node.id, to: menu, target: target)
        add("Copy Link", .copyURL, parentID: nil, nodeID: node.id, to: menu, target: target)
        menu.addItem(.separator())
        add("Edit\u{2026}", .edit, parentID: nil, nodeID: node.id, to: menu, target: target)
        add("Delete", .delete, parentID: nil, nodeID: node.id, to: menu, target: target)
        return menu
    }

    static func folderMenu(node: BookmarkNode, target: BookmarkMenuTarget) -> NSMenu {
        let menu = NSMenu()
        add("Open All in New Tabs", .openAllInNewTabs, parentID: nil, nodeID: node.id, to: menu, target: target)
        menu.addItem(.separator())
        add("New Folder\u{2026}", .newFolder, parentID: node.id, nodeID: nil, to: menu, target: target)
        add("New Bookmark\u{2026}", .newBookmark, parentID: node.id, nodeID: nil, to: menu, target: target)
        menu.addItem(.separator())
        add("Rename\u{2026}", .edit, parentID: nil, nodeID: node.id, to: menu, target: target)
        add("Delete", .delete, parentID: nil, nodeID: node.id, to: menu, target: target)
        return menu
    }

    /// A folder's children as a menu: links open on click, folders become
    /// submenus, recursively. Also the overflow chevron's menu when
    /// `parentID` is nil.
    static func itemsMenu(
        parentID: String?,
        emptyTitle: String,
        store: BookmarkStore,
        target: BookmarkMenuTarget
    ) -> NSMenu {
        let menu = NSMenu()
        let children = store.children(of: parentID)
        if children.isEmpty {
            let empty = NSMenuItem(title: emptyTitle, action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
            return menu
        }
        for child in children {
            if child.isFolder {
                let item = NSMenuItem(title: child.displayTitle, action: nil, keyEquivalent: "")
                item.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
                item.submenu = itemsMenu(
                    parentID: child.id,
                    emptyTitle: emptyTitle,
                    store: store,
                    target: target
                )
                menu.addItem(item)
            } else {
                let item = NSMenuItem(
                    title: child.displayTitle,
                    action: #selector(BookmarkMenuTarget.handleMenuItem(_:)),
                    keyEquivalent: ""
                )
                item.target = target
                item.representedObject = BookmarkMenuPayload(
                    action: .open,
                    nodeID: child.id,
                    parentID: nil
                )
                menu.addItem(item)
            }
        }
        return menu
    }

    static func add(
        _ title: String,
        _ action: BookmarkMenuAction,
        parentID: String?,
        nodeID: String?,
        to menu: NSMenu,
        target: BookmarkMenuTarget
    ) {
        let item = NSMenuItem(
            title: title,
            action: #selector(BookmarkMenuTarget.handleMenuItem(_:)),
            keyEquivalent: ""
        )
        item.target = target
        item.representedObject = BookmarkMenuPayload(
            action: action,
            nodeID: nodeID,
            parentID: parentID
        )
        menu.addItem(item)
    }
}
