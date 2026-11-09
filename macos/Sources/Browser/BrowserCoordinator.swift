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
import WebKit

/// What it takes to reopen a closed tab. Reopening loads the URL into a
/// fresh tab, so the closed tab's `WKWebView` is released on close
/// instead of staying alive on the reopen stack. Back/forward history,
/// scroll position, and page state do not survive a close/reopen cycle.
struct ClosedTab {
    let url: URL?
    let privacyMode: BrowserPrivacyMode
}

/// Creates, tracks and closes browser windows. Each window owns its
/// tabs; a tab moves between windows by being detached from one and
/// inserted into another, never recreated. Closing a window closes its
/// tabs and records them for "Reopen Closed Tab".
@MainActor
final class BrowserCoordinator: NSObject, ObservableObject {
    static let shared = BrowserCoordinator()

    let history: HistoryRecording = StoreHistoryRecorder()

    private(set) var windows: [BrowserWindowController] = []
    /// Pushes the live half of the web settings onto every open page of one
    /// profile.
    ///
    /// Only the `WKWebView` properties can be changed this way; the rest are read
    /// when a view is built, so those take effect on the next page. Called from
    /// the profile's settings `onChange` (see `ProfileManager`) rather than
    /// from each control, so a change made anywhere lands the same way.
    func applyLiveWebSettings(for profileID: String) {
        let settings = ProfileManager.shared.context(forID: profileID).settings.settings.web
        for window in windows where window.profileID == profileID {
            for tab in window.tabs {
                // Skips tabs with no view: they read the configuration half when
                // they are built, and there is nothing to push live settings onto.
                guard let webView = tab.webView else { continue }
                settings.apply(toWebView: webView)
            }
        }
    }

    /// Pushes the window background onto every open page of one profile.
    ///
    /// Only the page-transparency part needs pushing: the background layer
    /// itself reads the store directly, one subscription per window.
    func applyLiveBackgroundSettings(for profileID: String) {
        let background = ProfileManager.shared.context(forID: profileID).settings.settings.appearance.background
        // Inert unless there is a background to reveal. A transparent page over
        // the plain window colour is a different appearance, not this feature.
        let enabled = background.isActive && background.showThroughPages
        for window in windows where window.profileID == profileID {
            for tab in window.tabs {
                guard let webView = tab.webView else { continue }
                PageTransparency.apply(enabled: enabled, to: webView)
            }
        }
    }

    /// Pushes the search link guard onto every open page of one profile.
    ///
    /// The script list rebuilds from current settings and the visible
    /// documents patch live, so the toggle answers at once instead of on the
    /// next navigation. Called from the profile's settings `onChange`.
    func applyLiveSearchLinkGuard(for profileID: String) {
        let enabled = ProfileManager.shared.context(forID: profileID).settings.settings.search.cleanResultLinks
        for window in windows where window.profileID == profileID {
            for tab in window.tabs {
                guard let webView = tab.webView else { continue }
                SearchLinkGuard.apply(enabled: enabled, to: webView)
            }
        }
    }

    /// Pushes the compiled content-blocker lists onto every open page of one
    /// profile.
    ///
    /// Each tab is synced with the exception list for the page it shows, and
    /// only tabs whose blocking actually moved reload: an exception added for
    /// one site must not throw away form state in twenty others. Called from
    /// the profile's settings `onChange`, which also fires for the compile
    /// bookkeeping `refreshIfNeeded` records — at launch there are no pages
    /// yet, and later that bookkeeping always accompanies a real change.
    func applyLiveContentBlocker(for profileID: String) {
        let manager = ProfileManager.shared
        let store = manager.context(forID: profileID).blocker
        var liveIDs = Set<UUID>()
        for window in windows where window.profileID == profileID {
            for tab in window.tabs {
                guard let webView = tab.webView else { continue }
                liveIDs.insert(tab.id)
                let attached = store.applyException(
                    for: webView.url,
                    to: webView.configuration.userContentController
                )
                if store.noteApplied(tab: tab.id, attached: attached) {
                    webView.reload()
                }
            }
        }
        store.forgetTabs(notIn: liveIDs)
    }
    /// Suppresses session writes while a session is being rebuilt.
    ///
    /// Restoring runs the same `addTab` and `selectTab` paths as any other
    /// change, so without this the first window would schedule a write of a
    /// half-restored session over the one being read.
    private var isRestoringSession = false

    private(set) var recentlyClosed: [ClosedTab] = []
    private let maxRecentlyClosed = 25
    private var closeObserver: NSObjectProtocol?
    /// Held for the app's life; removal is teardown that never comes.
    private var tabCycleMonitor: Any?

    private override init() {
        super.init()
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let window = notification.object as? NSWindow else { return }
            // The observer is registered on the main queue.
            MainActor.assumeIsolated {
                self?.windowWillClose(window)
            }
        }
        // Ctrl+Tab walks tabs forward, Ctrl+Shift+Tab and Cmd+Shift+Tab
        // walk back. A local monitor, because one menu item holds one key
        // equivalent and these need three across two items. It runs before
        // the responder chain, so the spotlight's own Tab walking (dropdown
        // open) and the password cards' form cycling never see these, and
        // plain Tab is untouched. Confined to browser windows, so panels
        // and sheets keep their keys.
        tabCycleMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 48,
                  let offset = Self.tabCycleDirection(modifiers: event.modifierFlags)
            else {
                return event
            }
            return MainActor.assumeIsolated { () -> NSEvent? in
                guard let self,
                      let window = event.window,
                      self.windows.contains(where: { $0.window === window })
                else {
                    return event
                }
                if offset > 0 {
                    self.selectNextTab()
                } else {
                    self.selectPreviousTab()
                }
                return nil
            }
        }
    }

    /// Tab-cycle direction for a Tab keypress's modifiers: +1 forward, -1
    /// back, nil when the press is not tab cycling at all. Static so the
    /// mapping is testable without synthesizing key events.
    static func tabCycleDirection(modifiers: NSEvent.ModifierFlags) -> Int? {
        let mods = modifiers.intersection([.control, .shift, .command, .option])
        if mods == [.control] {
            return 1
        }
        if mods == [.control, .shift] || mods == [.command, .shift] {
            return -1
        }
        return nil
    }

    // MARK: - Session

    /// Builds the document that describes every open window on one profile.
    ///
    /// Private tabs are left out here rather than marked in the document: a
    /// private tab is not the user's to reopen later, so it should not survive
    /// in a file either. The address is the tab's own rather than its loaded
    /// page's, so a tab that never got a view still records where it was.
    ///
    /// One document per profile: each profile's store holds only its own
    /// windows, so restoring one profile never resurrects another's.
    func sessionSnapshot(for profileID: String) -> SessionSnapshot {
        let records = windows.filter({ $0.profileID == profileID }).compactMap { controller -> SessionSnapshot.WindowSnapshot? in
            guard let window = controller.window else { return nil }
            let tabs = controller.tabs.compactMap { tab -> SessionSnapshot.TabSnapshot? in
                guard tab.privacyMode != .privateBrowsing else { return nil }
                let slice = tab.historySnapshot()
                return SessionSnapshot.TabSnapshot(
                    id: tab.id,
                    url: tab.currentURL.absoluteString,
                    title: tab.tabController.title,
                    isPinned: tab.presentation.isPinned,
                    history: slice.urls.map(\.absoluteString),
                    historyIndex: slice.index,
                    isMuted: tab.tabController.isMuted
                )
            }
            guard !tabs.isEmpty else { return nil }
            // The layout can name a private tab that the filter above just
            // dropped, so it is rebuilt from what survived.
            let kept = Set(tabs.map(\.id))
            let layout: SessionSnapshot.WindowSnapshot.Layout
            switch controller.layout {
            case .single(let tabID):
                layout = .single(kept.contains(tabID) ? tabID : (tabs.first?.id ?? UUID()))
            case .split(let leading, let trailing, let ratio):
                let canRestoreBoth = kept.contains(leading)
                    && kept.contains(trailing)
                    && leading != trailing
                layout = canRestoreBoth
                    ? .split(leading: leading, trailing: trailing, ratio: Double(ratio))
                    : .single(kept.contains(leading) ? leading : (tabs.first?.id ?? UUID()))
            }
            // The sticky group rides along so a hidden split comes back as a
            // group, not just as two tabs.
            var splitGroup: SessionSnapshot.WindowSnapshot.Layout?
            if let group = controller.splitGroup,
               case .split(let leading, let trailing, let ratio) = group,
               kept.contains(leading), kept.contains(trailing),
               leading != trailing {
                splitGroup = .split(
                    leading: leading, trailing: trailing, ratio: Double(ratio))
            }
            return SessionSnapshot.WindowSnapshot(
                frame: .init(window.frame),
                tabs: tabs,
                selectedTabID: controller.selectedTabID.flatMap { kept.contains($0) ? $0 : nil },
                layout: layout,
                splitGroup: splitGroup,
                profileID: controller.profileID
            )
        }
        return SessionSnapshot(windows: records)
    }

    /// Reopens one profile's stored session.
    ///
    /// Returns how many windows came back, so the caller can open a fresh one
    /// when there was nothing to restore. Records without a profile id are
    /// pre-profiles documents and restore into the default profile; a record
    /// naming another profile never appears here because each profile loads
    /// only its own document.
    @discardableResult
    func restore(from snapshot: SessionSnapshot?, profileID: String) -> Int {
        guard let snapshot, snapshot.isRestorable else { return 0 }
        isRestoringSession = true
        defer { isRestoringSession = false }
        let context = ProfileManager.shared.context(forID: profileID)
        var restored = 0
        for record in snapshot.windows where !record.tabs.isEmpty {
            let controller = BrowserWindowController(
                restoring: record,
                profileID: profileID,
                history: context.history,
                dataStore: context.dataStore
            )
            windows.append(controller)
            controller.showWindow(nil)
            controller.window?.makeKeyAndOrderFront(nil)
            restored += 1
        }
        return restored
    }

    /// Schedules a session write.
    ///
    /// The single entry point for every change worth recording, so a new kind of
    /// mutation cannot quietly skip persistence by being added somewhere that
    /// forgets to call this. Writes one document per profile with windows
    /// open; a profile with none is handled where its last window closes.
    func sessionDidChange() {
        guard !isRestoringSession else { return }
        let manager = ProfileManager.shared
        let ids = Set(windows.map(\.profileID))
        Task {
            for id in ids {
                await SessionStore.shared.scheduleSave(
                    sessionSnapshot(for: id),
                    using: manager.client(for: id)
                )
            }
        }
    }

    /// Writes the session immediately, for the quit and window-close paths.
    func saveSessionNow() async {
        let manager = ProfileManager.shared
        for id in Set(windows.map(\.profileID)) {
            await SessionStore.shared.saveNow(
                sessionSnapshot(for: id),
                using: manager.client(for: id)
            )
        }
    }

    /// Whether a session write has not reached the store yet.
    ///
    /// The quit path reads this to decide whether it needs to delay termination
    /// at all, so a quit with nothing pending does not wait on a round trip.
    func hasPendingSessionWrite() async -> Bool {
        await SessionStore.shared.hasPendingWrite
    }

    // MARK: - Windows

    @discardableResult
    func newWindow(
        url: URL? = nil,
        privacyMode: BrowserPrivacyMode = .regular,
        profileID: String? = nil
    ) -> BrowserWindowController {
        // A new window opens into the key window's profile, so a Work user
        // pressing ⌘N stays in Work; with no windows open it is the default
        // profile. An explicit id always wins (restore, profile switching).
        let manager = ProfileManager.shared
        let resolvedID = profileID ?? keyController?.profileID ?? manager.defaultProfile.id
        let context = manager.context(forID: resolvedID)
        let controller = BrowserWindowController(
            initialURL: url,
            privacyMode: privacyMode,
            profileID: resolvedID,
            history: context.history,
            dataStore: context.dataStore
        )
        windows.append(controller)
        controller.showWindow(nil)
        controller.window?.center()
        controller.window?.makeKeyAndOrderFront(nil)
        // Only the keyboard shortcut calls this today, and it always wants the
        // caret. Gated on `url` so a future caller that opens a window to navigate
        // somewhere does not also steal focus away from the destination.
        if url == nil {
            controller.focusAddressBar()
        }
        return controller
    }

    /// Opens a window whose tabs are all private: nothing opened in it reaches
    /// history or the session document. The window carries the incognito flag,
    /// so tabs it creates later stay private too.
    @discardableResult
    func newPrivateWindow() -> BrowserWindowController {
        newWindow(privacyMode: .privateBrowsing)
    }

    /// Moves a tab into a brand new window, keeping its web view.
    @discardableResult
    func newWindow(
        containing tab: BrowserTab,
        atScreenPoint point: NSPoint? = nil,
        focusesAddressBar: Bool = false
    ) -> BrowserWindowController {
        // The fresh window inherits the tab's profile, so the tab's jar and
        // recorder stay valid without any migration.
        let context = ProfileManager.shared.context(forID: tab.profileID)
        let controller = BrowserWindowController(
            tab: tab,
            history: context.history,
            dataStore: context.dataStore
        )
        windows.append(controller)
        controller.showWindow(nil)
        if let window = controller.window {
            if let point {
                window.setFrameOrigin(NSPoint(x: point.x - 60, y: point.y - 30))
            } else {
                window.center()
            }
            window.makeKeyAndOrderFront(nil)
        }
        // After the window is key, not before: `BrowserWindowController.init(tab:)`
        // selects the tab while the content view is not yet in a shown window, so
        // there is nothing for `makeFirstResponder` to find.
        if focusesAddressBar {
            controller.focusAddressBar()
        }
        return controller
    }

    var keyController: BrowserWindowController? {
        controller(for: NSApp.keyWindow) ?? windows.first { $0.window?.isKeyWindow == true }
    }

    /// Windows on one profile, in opening order.
    func windows(for profileID: String) -> [BrowserWindowController] {
        windows.filter { $0.profileID == profileID }
    }

    /// Focuses the profile's window, opening one when it has none. The
    /// switcher answers here rather than re-profiling a window: tabs never
    /// change profile, so switching means going to (or opening) a window
    /// that already belongs to the profile.
    func focusOrOpenWindow(for profileID: String) {
        if let existing = windows(for: profileID).first {
            existing.window?.makeKeyAndOrderFront(nil)
        } else {
            newWindow(profileID: profileID)
        }
    }

    /// Closes every window on a profile, for the delete flow. Closing
    /// drives the usual teardown (session snapshot, emptied-profile save),
    /// so by the time this returns the profile has no windows left.
    func closeWindows(for profileID: String) {
        for controller in windows(for: profileID) {
            controller.close()
        }
    }

    /// Deletes a profile and its windows: closes the windows, drops any
    /// session write they scheduled, removes the profile, and opens a
    /// default window when nothing is left. The scheduled-write drop
    /// matters: a debounced save firing after the delete would resolve a
    /// fallback profile and write the removed windows there.
    func deleteProfileAndCloseWindows(_ id: String) async throws {
        closeWindows(for: id)
        await SessionStore.shared.discardPending()
        try await ProfileManager.shared.deleteProfile(id: id)
        if windows.isEmpty {
            newWindow()
        }
    }

    // MARK: - Profile flows

    /// Prompts for a name and opens a window in a new profile. Sheets onto
    /// the key window when there is one; app-modal otherwise.
    func promptNewProfile() {
        promptForProfileName(
            title: tr("New Profile", ctx: "Profiles"),
            initial: "",
            confirm: tr("Create", ctx: "Profiles")
        ) { name in
            Task { @MainActor in
                do {
                    let profile = try await ProfileManager.shared.createProfile(name: name)
                    self.focusOrOpenWindow(for: profile.id)
                } catch {
                    self.presentStoreError(error)
                }
            }
        }
    }

    /// Renames the key window's profile.
    func promptRenameProfile() {
        guard let controller = keyController,
              let profile = ProfileManager.shared.profile(withID: controller.profileID)
        else { return }
        promptForProfileName(
            title: tr("Rename Profile", ctx: "Profiles"),
            initial: profile.name,
            confirm: tr("Rename", ctx: "Profiles")
        ) { name in
            Task { @MainActor in
                do {
                    try await ProfileManager.shared.renameProfile(id: profile.id, name: name)
                } catch {
                    self.presentStoreError(error)
                }
            }
        }
    }

    /// Confirms and deletes the key window's profile with its windows.
    /// Refuses the last profile, like the core does.
    func confirmDeleteProfile() {
        guard let controller = keyController,
              let profile = ProfileManager.shared.profile(withID: controller.profileID)
        else { return }
        let alert = NSAlert()
        alert.messageText = tr("Delete Profile “{name}”?", ctx: "Profiles", args: ["name": profile.name])
        alert.informativeText = tr(
            "This removes its history, bookmarks, passwords, and everything else stored in this profile. This cannot be undone.",
            ctx: "Profiles"
        )
        alert.addButton(withTitle: tr("Delete", ctx: "Profiles"))
        alert.addButton(withTitle: tr("Cancel", ctx: "Profiles"))
        let delete = { [weak self] in
            Task { @MainActor in
                do {
                    try await self?.deleteProfileAndCloseWindows(profile.id)
                } catch {
                    self?.presentStoreError(error)
                }
            }
        }
        if let window = controller.window {
            alert.beginSheetModal(for: window) { response in
                guard response == .alertFirstButtonReturn else { return }
                delete()
            }
        } else if alert.runModal() == .alertFirstButtonReturn {
            delete()
        }
    }

    /// One text-field prompt for the profile flows above.
    private func promptForProfileName(
        title: String,
        initial: String,
        confirm: String,
        onConfirm: @escaping (String) -> Void
    ) {
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 22))
        field.stringValue = initial
        field.placeholderString = tr("Name", ctx: "Profiles")
        let alert = NSAlert()
        alert.messageText = title
        alert.accessoryView = field
        alert.addButton(withTitle: confirm)
        alert.addButton(withTitle: tr("Cancel", ctx: "Profiles"))
        // Focus the field: a prompt that makes the user click into it first
        // is a prompt half broken.
        alert.window.initialFirstResponder = field
        let commit = {
            let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return }
            onConfirm(name)
        }
        if let window = keyController?.window {
            alert.beginSheetModal(for: window) { response in
                guard response == .alertFirstButtonReturn else { return }
                commit()
            }
        } else if alert.runModal() == .alertFirstButtonReturn {
            commit()
        }
    }

    /// Reports a store failure from the flows above. Rare — the core
    /// validates input, and the last-profile refusal arrives here — but a
    /// silent no-op would leave the user wondering why nothing happened.
    private func presentStoreError(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = error.localizedDescription
        alert.addButton(withTitle: tr("OK", ctx: "Profiles"))
        if let window = keyController?.window {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }

    func controller(for window: NSWindow?) -> BrowserWindowController? {
        guard let window else { return nil }
        return windows.first { $0.window === window }
    }

    func close(_ controller: BrowserWindowController) {
        controller.close()
    }

    // MARK: - Tabs

    /// Adds a tab to `controller`, or to the key window's controller,
    /// falling back to a new window.
    ///
    /// A nil `privacyMode` inherits the target window: an incognito window
    /// mints private tabs, a regular window regular ones. Callers that must
    /// keep a specific mode — a popup owned by a private tab, a reopened
    /// closed tab — pass it explicitly and it always wins. With no target
    /// window the fallback builds a fresh window around the tab, which is
    /// regular unless the caller said otherwise.
    ///
    /// `focusesAddressBar` defaults to true because every path here is somebody
    /// asking for a new tab and then wanting to type in it. The one caller that is
    /// not is `BrowserPaneController`'s `createWebViewWith`, which is WebKit
    /// driving a `window.open` rather than a person, and passes false: focus
    /// belongs to the page that opened the popup, and the popup's navigation is
    /// about to need it.
    @discardableResult
    func newTab(
        url: URL? = nil,
        privacyMode: BrowserPrivacyMode? = nil,
        in controller: BrowserWindowController? = nil,
        focusesAddressBar: Bool = true
    ) -> BrowserTab? {
        let target = controller ?? keyController
        let manager = ProfileManager.shared
        let resolvedID = target?.profileID ?? manager.defaultProfile.id
        let context = manager.context(forID: resolvedID)
        let tab = BrowserTab(
            privacyMode: Self.resolvedPrivacyMode(explicit: privacyMode, in: target),
            profileID: resolvedID,
            history: context.history,
            dataStore: context.dataStore,
            initialURL: url
        )
        if let target {
            target.addTab(tab)
            // After `addTab`, which selects the tab. See `focusAddressBar`.
            if focusesAddressBar {
                target.focusAddressBar()
            }
        } else {
            newWindow(containing: tab, focusesAddressBar: focusesAddressBar)
        }
        return tab
    }

    /// The privacy mode for a tab nobody pinned down: an explicit mode always
    /// wins, otherwise the target window's default (private in an incognito
    /// window), otherwise regular. Static and window-free so the rule itself
    /// is testable without building a window.
    static func resolvedPrivacyMode(
        explicit: BrowserPrivacyMode?,
        in controller: BrowserWindowController?
    ) -> BrowserPrivacyMode {
        explicit ?? controller?.defaultPrivacyMode ?? .regular
    }

    func recordClosedTab(_ tab: BrowserTab) {
        // Snapshot, don't retain: reopening rebuilds the tab from its
        // URL, so the closed tab and its web view deallocate now.
        // `displayURL` rather than the loaded page's URL, so reopening a tab that
        // was never realized lands on the address it was sitting at.
        recentlyClosed.append(ClosedTab(url: tab.displayURL, privacyMode: tab.privacyMode))
        trimRecentlyClosed()
    }

    func reopenClosedTab() {
        guard let closed = recentlyClosed.popLast() else {
            SystemBeep.play()
            return
        }
        // A reopened tab is a fresh load into the key window's profile: its
        // URL carries over, its cookies do not.
        let controller = keyController
        let manager = ProfileManager.shared
        let resolvedID = controller?.profileID ?? manager.defaultProfile.id
        let context = manager.context(forID: resolvedID)
        let tab = BrowserTab(
            privacyMode: closed.privacyMode,
            profileID: resolvedID,
            history: context.history,
            dataStore: context.dataStore,
            initialURL: closed.url
        )
        if let controller {
            controller.addTab(tab)
            controller.selectTab(tab)
            // Someone reopened this to go somewhere, so put the caret where they
            // will type. The URL is selected, so typing replaces it.
            controller.focusAddressBar()
        } else {
            newWindow(containing: tab, focusesAddressBar: true)
        }
    }

    func selectNextTab() {
        guard let controller = keyController else { return }
        controller.selectTab(atOffset: 1)
    }

    func selectPreviousTab() {
        guard let controller = keyController else { return }
        controller.selectTab(atOffset: -1)
    }

    func selectTab(at index: Int) {
        guard let controller = keyController,
              controller.tabs.indices.contains(index)
        else {
            return
        }
        controller.selectTab(controller.tabs[index])
    }

    /// Finds a live tab across every window, including tabs whose window
    /// is mid-drag. Used to resolve a drag payload.
    func tab(withIDString string: String) -> BrowserTab? {
        guard let id = UUID(uuidString: string) else { return nil }
        for controller in windows {
            if let tab = controller.tabs.first(where: { $0.id == id }) {
                return tab
            }
        }
        return nil
    }

    /// Called by a drag that ended outside every browser window. The tab
    /// becomes a new window at that point.
    func dragEndedOutsideApp(_ tab: BrowserTab, atScreenPoint point: NSPoint) {
        guard let source = windows.first(where: {
            $0.tabs.contains { $0.id == tab.id }
        }) else {
            return
        }
        detach(tab: tab, from: source, atScreenPoint: point)
    }

    /// Moves a tab to an index in `destination`: a reorder when the tab is
    /// already there, a move from another window otherwise. The source
    /// window closes itself if a move empties it.
    func moveTab(
        _ tab: BrowserTab,
        to index: Int,
        in destination: BrowserWindowController
    ) {
        let source = windows.first {
            $0.tabs.contains { $0.id == tab.id }
        }
        guard let source else { return }
        if source !== destination {
            if source.profileID != destination.profileID {
                // Tabs never change profile: a cross-profile move becomes a
                // detach into a fresh window that inherits the tab's own.
                source.detachTab(tab)
                newWindow(containing: tab)
                return
            }
            source.detachTab(tab)
            destination.addTab(tab, at: index)
        } else {
            destination.moveTab(tab, to: index)
        }
    }

    /// Moves a tab to a new window, removing it from `source`, which closes
    /// itself if that leaves it empty. A screen point positions the new window
    /// under the drop; without one it is centred.
    func detach(
        tab: BrowserTab,
        from source: BrowserWindowController,
        atScreenPoint point: NSPoint? = nil
    ) {
        guard source.tabs.contains(where: { $0.id == tab.id }) else { return }
        // Keep the tab's session alive: nothing about the tab is torn
        // down, only its membership of `source` changes.
        source.detachTab(tab)
        newWindow(containing: tab, atScreenPoint: point)
    }

    /// Moves a whole split group to an index in `destination`: a reorder
    /// when the group is already there, a move from another window
    /// otherwise. A cross-window move re-forms the group on arrival, so the
    /// pair stays a pair; the source window closes itself if a move empties
    /// it. The pair travels in pane order.
    func moveTabs(
        _ pair: [BrowserTab],
        to index: Int,
        in destination: BrowserWindowController
    ) {
        guard pair.count == 2 else { return }
        let source = windows.first {
            $0.tabs.contains { $0.id == pair[0].id }
        }
        guard let source else { return }
        if source !== destination {
            if source.profileID != destination.profileID {
                // As with single tabs: the pair keeps its profile in a
                // fresh window rather than mixing into another's.
                detachGroup(pair, from: source, atScreenPoint: nil)
                return
            }
            source.detachTab(pair[0])
            source.detachTab(pair[1])
            destination.addTab(pair[0], at: index, select: false)
            destination.addTab(pair[1], at: index + 1, select: false)
            // Both tabs are already home; this only restores the sticky
            // view state, with the leading tab showing.
            _ = destination.createSplit(
                currentTab: pair[1], droppedTab: pair[0], zone: .leading)
        } else {
            source.moveTabPair(pair, to: index)
        }
    }

    /// Moves a whole split group to a new window, keeping its web views
    /// and re-forming the group there.
    func detachGroup(
        _ pair: [BrowserTab],
        from source: BrowserWindowController,
        atScreenPoint point: NSPoint? = nil
    ) {
        guard pair.count == 2,
              source.tabs.contains(where: { $0.id == pair[0].id }),
              source.tabs.contains(where: { $0.id == pair[1].id })
        else { return }
        source.detachTab(pair[0])
        source.detachTab(pair[1])
        let fresh = newWindow(containing: pair[0], atScreenPoint: point)
        fresh.addTab(pair[1], select: false)
        _ = fresh.createSplit(
            currentTab: pair[1], droppedTab: pair[0], zone: .leading)
    }

    // MARK: - Private

    private func windowWillClose(_ window: NSWindow) {
        guard let controller = windows.first(where: { $0.window === window }) else { return }
        // The window's tabs go on the reopen stack in close order.
        recentlyClosed.append(contentsOf: controller.tabs.reversed().map {
            ClosedTab(url: $0.displayURL, privacyMode: $0.privacyMode)
        })
        trimRecentlyClosed()
        let closedProfile = controller.profileID
        controller.tearDown()
        windows.removeAll { $0 === controller }
        // After the removal, so the snapshot describes what is still open. The
        // frame is captured while the window still exists.
        sessionDidChange()
        // A profile that just lost its last window would otherwise keep its
        // stale document: the partition above only writes profiles that
        // still have windows, so the emptied one is cleared explicitly.
        if !windows.contains(where: { $0.profileID == closedProfile }) {
            let client = ProfileManager.shared.client(for: closedProfile)
            Task {
                await SessionStore.shared.scheduleSave(.empty, using: client)
            }
        }
    }

    private func trimRecentlyClosed() {
        if recentlyClosed.count > maxRecentlyClosed {
            recentlyClosed.removeFirst(recentlyClosed.count - maxRecentlyClosed)
        }
    }
}
