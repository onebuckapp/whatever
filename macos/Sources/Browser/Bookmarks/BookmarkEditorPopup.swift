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
import MijickPopups
import SwiftUI

/// The bookmark editor card: one form for new links, new folders, and
/// edits, presented by Mijick/Popups like the content-blocker card.
///
/// The card owns the fields; saving travels through the coordinator to the
/// presenter (popup structs must stay `Sendable`, so they cannot hold the
/// presenter directly), which applies the submission to `BookmarkStore`.
struct BookmarkEditorPopup: CenterPopup {
    let stackID: PopupStackID
    let popupID: String
    let mode: BookmarkEditorMode
    let kind: BookmarkNode.Kind
    let initialTitle: String
    let initialURL: String
    let initialParentID: String?
    let folders: [BookmarkTree.FolderChoice]

    func configurePopup(config: CenterPopupConfig) -> CenterPopupConfig {
        config
            .backgroundColor(.clear)
            .cornerRadius(20)
            .overlayColor(.clear)
            .tapOutsideToDismissPopup(true)
    }

    func onDismiss() {
        Task { @MainActor in
            BookmarkEditorCoordinator.shared.popupDidDismiss(id: popupID)
        }
    }

    var body: some View {
        BookmarkEditorCard(
            kind: kind,
            initialTitle: initialTitle,
            initialURL: initialURL,
            initialParentID: initialParentID,
            folders: folders,
            onCancel: {
                Task { @MainActor in
                    BookmarkEditorCoordinator.shared.cancelTapped(id: popupID)
                }
            },
            onSave: { title, url, parentID in
                Task { @MainActor in
                    BookmarkEditorCoordinator.shared.saveTapped(
                        id: popupID,
                        title: title,
                        url: url,
                        parentID: parentID
                    )
                }
            },
            onDelete: mode.editedNodeID.map { _ in
                {
                    Task { @MainActor in
                        BookmarkEditorCoordinator.shared.deleteTapped(id: popupID)
                    }
                }
            }
        )
        .frame(width: 360)
        .background(Color(nsColor: .windowBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .shadow(color: .black.opacity(0.34), radius: 18, x: 0, y: 10)
        .shadow(color: .black.opacity(0.58), radius: 25, x: 0, y: 30)
        // Mijick masks the popup to its measured bounds, so the shadows
        // need transparent room; the padding is symmetric, so the card
        // stays centered.
        .padding(.vertical, 88)
        // Consume taps on the card itself so a click on empty card space
        // cannot reach the tap-outside layer.
        .onTapGesture {}
        .onExitCommand {
            Task { @MainActor in
                BookmarkEditorCoordinator.shared.cancelTapped(id: popupID)
            }
        }
    }
}

/// The form itself: title, address for links, a folder picker, and the
/// action row. An ordinary view so it can own `@State`; the popup struct
/// above stays `Sendable` with lets only.
private struct BookmarkEditorCard: View {
    let kind: BookmarkNode.Kind
    let folders: [BookmarkTree.FolderChoice]
    let onCancel: () -> Void
    let onSave: (String, String, String?) -> Void
    let onDelete: (() -> Void)?

    @State private var title: String
    @State private var url: String
    @State private var parentID: String?
    @State private var confirmingDelete = false
    @FocusState private var titleFocused: Bool

    init(
        kind: BookmarkNode.Kind,
        initialTitle: String,
        initialURL: String,
        initialParentID: String?,
        folders: [BookmarkTree.FolderChoice],
        onCancel: @escaping () -> Void,
        onSave: @escaping (String, String, String?) -> Void,
        onDelete: (() -> Void)?
    ) {
        self.kind = kind
        self.folders = folders
        self.onCancel = onCancel
        self.onSave = onSave
        self.onDelete = onDelete
        _title = State(initialValue: initialTitle)
        _url = State(initialValue: initialURL)
        _parentID = State(initialValue: initialParentID)
    }

    private var isFolder: Bool { kind == .folder }

    private var headerTitle: String {
        if isFolder {
            return onDelete == nil ? "New Folder" : "Edit Folder"
        }
        return onDelete == nil ? "New Bookmark" : "Edit Bookmark"
    }

    private var canSave: Bool {
        BookmarkEditor.isValid(title: title, url: url, kind: kind)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: isFolder ? "folder" : "bookmark")
                    .font(.system(size: 22))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 28)
                Text(headerTitle)
                    .font(.system(size: 13, weight: .semibold))
            }
            Divider()
            TextField("Title", text: $title)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12))
                .controlSize(.large)
                .focused($titleFocused)
            if !isFolder {
                TextField("Address", text: $url)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
                    .controlSize(.large)
            }
            Picker("Folder", selection: $parentID) {
                Text("Bookmarks Bar").tag(String?.none)
                ForEach(folders) { choice in
                    Text(folderLabel(choice)).tag(Optional(choice.node.id))
                }
            }
            .font(.system(size: 12))
            .controlSize(.large)
            .disabled(folders.isEmpty)
            Divider()
            HStack {
                if let onDelete {
                    Button("Delete", role: .destructive) {
                        confirmingDelete = true
                    }
                    .controlSize(.small)
                }
                Spacer()
                Button("Cancel", action: onCancel)
                    .controlSize(.small)
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    onSave(title, url, parentID)
                }
                .controlSize(.small)
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave)
            }
        }
        .padding(16)
        // The caret starts in the title, for a new item and a rename alike:
        // typed-first, so the name does not need a click. Delayed because
        // the card is presented asynchronously and a focus set before the
        // window has taken key is silently dropped.
        .task {
            try? await Task.sleep(for: .milliseconds(80))
            titleFocused = true
            try? await Task.sleep(for: .milliseconds(200))
            if !titleFocused {
                titleFocused = true
            }
        }
        .alert(
            "Delete \u{201C}\(alertTitle)\u{201D}?",
            isPresented: $confirmingDelete
        ) {
            Button("Delete", role: .destructive) {
                onDelete?()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Are you sure? This cannot be reverted.")
        }
    }

    private var alertTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        return isFolder ? "this folder" : "this bookmark"
    }

    private func folderLabel(_ choice: BookmarkTree.FolderChoice) -> String {
        String(repeating: "    ", count: choice.depth) + choice.node.displayTitle
    }
}

/// Root view hosted in the window content.
///
/// Fills the window so the card centres over the whole window and
/// tap-outside covers the page, matching how the settings modal behaves.
struct BookmarkEditorRootView: View {
    let stackID: PopupStackID
    let popupID: String
    let mode: BookmarkEditorMode
    let kind: BookmarkNode.Kind
    let initialTitle: String
    let initialURL: String
    let initialParentID: String?
    let folders: [BookmarkTree.FolderChoice]

    var body: some View {
        Color.clear
            .registerPopups(id: stackID) { config in
                config.center { popup in
                    popup
                        .backgroundColor(.clear)
                        .cornerRadius(20)
                        .overlayColor(.clear)
                        .tapOutsideToDismissPopup(true)
                }
            }
            .task {
                await BookmarkEditorPopup(
                    stackID: stackID,
                    popupID: popupID,
                    mode: mode,
                    kind: kind,
                    initialTitle: initialTitle,
                    initialURL: initialURL,
                    initialParentID: initialParentID,
                    folders: folders
                )
                .present(popupStackID: stackID)
            }
    }
}

/// Routes Mijick and card callbacks back to the presenter that owns the
/// hosting view. Popup structs must stay `Sendable`, so they cannot hold the
/// presenter directly.
@MainActor
final class BookmarkEditorCoordinator {
    static let shared = BookmarkEditorCoordinator()

    struct Handlers {
        var onSave: (String, String, String?) -> Void
        var onDelete: () -> Void
        var onCancel: () -> Void
        var onDismiss: () -> Void
    }

    private var handlers: [String: Handlers] = [:]

    func register(id: String, handlers: Handlers) {
        self.handlers[id] = handlers
    }

    func popupDidDismiss(id: String) {
        handlers.removeValue(forKey: id)?.onDismiss()
    }

    func saveTapped(id: String, title: String, url: String, parentID: String?) {
        handlers[id]?.onSave(title, url, parentID)
    }

    func deleteTapped(id: String) {
        handlers[id]?.onDelete()
    }

    /// Cancel and Escape dismiss through the presenter, not Mijick directly:
    /// the presenter's teardown is the one path that closes the popup, drops
    /// the host, and releases the window's modal shield together.
    func cancelTapped(id: String) {
        handlers[id]?.onCancel()
    }
}

/// Bridges the window to Mijick/Popups for the bookmark editor.
///
/// One presenter per window, owned by the content controller next to the
/// settings presenter. Saving and deleting are applied to the shared
/// `BookmarkStore` here, then the card dismisses through the one teardown
/// path. The backdrop drag guard is copied from the settings modal because
/// this card also holds text fields: a selection drag that ends outside the
/// card must not count as a click on the backdrop.
@MainActor
final class BookmarkEditorPresenter {
    /// How far the pointer may move between press and release while the
    /// release still counts as the click that dismisses the card.
    private static let backdropClickSlop: CGFloat = 6

    private weak var container: NSView?
    private var hostingView: NSHostingView<BookmarkEditorRootView>?
    private var stackID: PopupStackID?
    private var escapeMonitor: Any?
    private var backdropDragMonitor: Any?
    private var backdropPressPoint: NSPoint?
    private var onDidDismiss: (() -> Void)?

    init(container: NSView, onDidDismiss: (() -> Void)? = nil) {
        self.container = container
        self.onDidDismiss = onDidDismiss
    }

    var isPresented: Bool {
        hostingView?.superview != nil
    }

    /// Opens the card for `mode`, or does nothing if it is already open.
    func present(mode: BookmarkEditorMode) {
        guard let container, container.window != nil, !isPresented else { return }
        resetForReuse()

        let store = BookmarkStore.shared
        let kind = BookmarkEditor.kind(for: mode, in: store)
        let initial: (title: String, url: String, parent: String?)
        switch mode {
        case .newLink(let prefillTitle, let prefillURL, let parentID):
            initial = (prefillTitle, prefillURL, parentID)
        case .newFolder(let parentID):
            initial = ("", "", parentID)
        case .edit(let id):
            let node = store.node(id)
            initial = (node?.title ?? "", node?.url ?? "", node?.parentID)
        }
        let folders = store.folderChoices(excluding: mode.editedNodeID)
        // A parent that no longer exists (or is inside the edited subtree)
        // falls back to the root rather than pinning a stale picker tag.
        let parent = initial.parent.flatMap { candidate in
            folders.contains { $0.node.id == candidate } ? candidate : nil
        }

        let stackID = PopupStackID(rawValue: "bookmark-editor-\(UUID().uuidString)")
        let popupID = "bookmark-editor-\(UUID().uuidString)"
        let root = BookmarkEditorRootView(
            stackID: stackID,
            popupID: popupID,
            mode: mode,
            kind: kind,
            initialTitle: initial.title,
            initialURL: initial.url,
            initialParentID: parent,
            folders: folders
        )
        let hostingView = NSHostingView(rootView: root)
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(hostingView)
        NSLayoutConstraint.activate([
            hostingView.topAnchor.constraint(equalTo: container.topAnchor),
            hostingView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            hostingView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        self.hostingView = hostingView
        self.stackID = stackID
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            if event.keyCode == 53 {
                Task { @MainActor in
                    self.dismiss()
                }
                return nil
            }
            return event
        }
        backdropDragMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .leftMouseUp]
        ) { [weak self] event in
            guard let self else { return event }
            // Local monitors run on the main thread during event dispatch.
            return MainActor.assumeIsolated { self.filterBackdropDrag(event) }
        }
        BookmarkEditorCoordinator.shared.register(
            id: popupID,
            handlers: .init(
                onSave: { [weak self] title, url, parentID in
                    guard let self else { return }
                    BookmarkEditor.apply(
                        title: title,
                        url: url,
                        parentID: parentID,
                        mode: mode,
                        to: store
                    )
                    self.dismiss()
                },
                onDelete: { [weak self] in
                    guard let self else { return }
                    if let id = mode.editedNodeID {
                        store.delete(id)
                    }
                    self.dismiss()
                },
                onCancel: { [weak self] in
                    self?.dismiss()
                },
                onDismiss: { [weak self] in
                    self?.tearDown()
                }
            )
        )
    }

    func dismiss() {
        if let stackID {
            Task {
                await PopupStack.dismissAllPopups(popupStackID: stackID)
            }
        }
        tearDown()
    }

    /// Single teardown path, whether dismissal came from Save, Delete,
    /// Cancel, Escape, Mijick's tap-outside layer, or the owner.
    private func tearDown() {
        resetForReuse()
        let notify = onDidDismiss
        onDidDismiss = nil
        notify?()
    }

    /// Holds back the release that ends a drag which began on the backdrop.
    /// A clean click passes through and dismisses the card; a release far
    /// from a backdrop press is swallowed.
    private func filterBackdropDrag(_ event: NSEvent) -> NSEvent? {
        switch event.type {
        case .leftMouseDown:
            backdropPressPoint = pressIsOnBackdrop(event) ? NSEvent.mouseLocation : nil
            return event
        case .leftMouseUp:
            defer { backdropPressPoint = nil }
            guard let press = backdropPressPoint else { return event }
            let release = NSEvent.mouseLocation
            let moved = hypot(release.x - press.x, release.y - press.y)
            return moved > Self.backdropClickSlop ? nil : event
        default:
            return event
        }
    }

    /// Whether a press landed on the dimmed backdrop rather than the card.
    ///
    /// The card is 360 wide and roughly 440 tall including its shadow
    /// padding; the box is expanded a little so a press on the boundary
    /// keeps the click behavior instead of joining the drag guard.
    private func pressIsOnBackdrop(_ event: NSEvent) -> Bool {
        guard let container else { return false }
        let point = container.convert(event.locationInWindow, from: nil)
        let bounds = container.bounds
        let box = NSRect(
            x: (bounds.width - 376) / 2,
            y: (bounds.height - 470) / 2,
            width: 376,
            height: 470
        )
        return !box.contains(point)
    }

    /// Drops the host without notifying the owner, so a re-present cannot
    /// clear the owner's reference to this presenter mid-present.
    private func resetForReuse() {
        if let stackID {
            Task {
                await PopupStack.dismissAllPopups(popupStackID: stackID)
            }
        }
        if let escapeMonitor {
            NSEvent.removeMonitor(escapeMonitor)
            self.escapeMonitor = nil
        }
        if let backdropDragMonitor {
            NSEvent.removeMonitor(backdropDragMonitor)
            self.backdropDragMonitor = nil
        }
        backdropPressPoint = nil
        hostingView?.removeFromSuperview()
        hostingView = nil
        stackID = nil
    }

    deinit {
        if let escapeMonitor {
            NSEvent.removeMonitor(escapeMonitor)
        }
        if let backdropDragMonitor {
            NSEvent.removeMonitor(backdropDragMonitor)
        }
    }
}
