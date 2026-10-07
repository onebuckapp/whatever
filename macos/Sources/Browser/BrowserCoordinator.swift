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
    /// Pushes the live half of the web settings onto every open page.
    ///
    /// Only the `WKWebView` properties can be changed this way; the rest are read
    /// when a view is built, so those take effect on the next page. Called from
    /// `SettingsStore.onChange` rather than from each control, so a change made
    /// anywhere lands the same way.
    func applyLiveWebSettings() {
        let settings = SettingsStore.shared.settings.web
        for window in windows {
            for tab in window.tabs {
                // Skips tabs with no view: they read the configuration half when
                // they are built, and there is nothing to push live settings onto.
                guard let webView = tab.webView else { continue }
                settings.apply(toWebView: webView)
            }
        }
    }

    /// Pushes the window background onto every open page.
    ///
    /// Only the page-transparency part needs pushing: the background layer
    /// itself reads the store directly, one subscription per window.
    func applyLiveBackgroundSettings() {
        let background = SettingsStore.shared.settings.appearance.background
        // Inert unless there is a background to reveal. A transparent page over
        // the plain window colour is a different appearance, not this feature.
        let enabled = background.isActive && background.showThroughPages
        for window in windows {
            for tab in window.tabs {
                guard let webView = tab.webView else { continue }
                PageTransparency.apply(enabled: enabled, to: webView)
            }
        }
    }

    /// Pushes the compiled content-blocker lists onto every open page.
    ///
    /// Each tab is synced with the exception list for the page it shows, and
    /// only tabs whose blocking actually moved reload: an exception added for
    /// one site must not throw away form state in twenty others. Called from
    /// `SettingsStore.onChange`, which also fires for the compile
    /// bookkeeping `refreshIfNeeded` records — at launch there are no pages
    /// yet, and later that bookkeeping always accompanies a real change.
    func applyLiveContentBlocker() {
        let store = ContentBlockerStore.shared
        var liveIDs = Set<UUID>()
        for window in windows {
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
    }

    // MARK: - Session

    /// Builds the document that describes every open window.
    ///
    /// Private tabs are left out here rather than marked in the document: a
    /// private tab is not the user's to reopen later, so it should not survive
    /// in a file either. The address is the tab's own rather than its loaded
    /// page's, so a tab that never got a view still records where it was.
    func sessionSnapshot() -> SessionSnapshot {
        let records = windows.compactMap { controller -> SessionSnapshot.WindowSnapshot? in
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
            return SessionSnapshot.WindowSnapshot(
                frame: .init(window.frame),
                tabs: tabs,
                selectedTabID: controller.selectedTabID.flatMap { kept.contains($0) ? $0 : nil },
                layout: layout
            )
        }
        return SessionSnapshot(windows: records)
    }

    /// Reopens a stored session.
    ///
    /// Returns how many windows came back, so the caller can open a fresh one
    /// when there was nothing to restore.
    @discardableResult
    func restore(from snapshot: SessionSnapshot?) -> Int {
        guard let snapshot, snapshot.isRestorable else { return 0 }
        isRestoringSession = true
        defer { isRestoringSession = false }
        var restored = 0
        for record in snapshot.windows where !record.tabs.isEmpty {
            let controller = BrowserWindowController(restoring: record, history: history)
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
    /// forgets to call this.
    func sessionDidChange() {
        guard !isRestoringSession else { return }
        let snapshot = sessionSnapshot()
        Task { await SessionStore.shared.scheduleSave(snapshot) }
    }

    /// Writes the session immediately, for the quit and window-close paths.
    func saveSessionNow() async {
        await SessionStore.shared.saveNow(sessionSnapshot())
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
    func newWindow(url: URL? = nil) -> BrowserWindowController {
        let controller = BrowserWindowController(
            initialURL: url,
            history: history
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

    /// Moves a tab into a brand new window, keeping its web view.
    @discardableResult
    func newWindow(
        containing tab: BrowserTab,
        atScreenPoint point: NSPoint? = nil,
        focusesAddressBar: Bool = false
    ) -> BrowserWindowController {
        let controller = BrowserWindowController(tab: tab)
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
    /// `focusesAddressBar` defaults to true because every path here is somebody
    /// asking for a new tab and then wanting to type in it. The one caller that is
    /// not is `BrowserPaneController`'s `createWebViewWith`, which is WebKit
    /// driving a `window.open` rather than a person, and passes false: focus
    /// belongs to the page that opened the popup, and the popup's navigation is
    /// about to need it.
    @discardableResult
    func newTab(
        url: URL? = nil,
        privacyMode: BrowserPrivacyMode = .regular,
        in controller: BrowserWindowController? = nil,
        focusesAddressBar: Bool = true
    ) -> BrowserTab? {
        let target = controller ?? keyController
        let tab = BrowserTab(privacyMode: privacyMode, history: history, initialURL: url)
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
        let tab = BrowserTab(privacyMode: closed.privacyMode, history: history, initialURL: closed.url)
        let controller = keyController
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

    // MARK: - Private

    private func windowWillClose(_ window: NSWindow) {
        guard let controller = windows.first(where: { $0.window === window }) else { return }
        // The window's tabs go on the reopen stack in close order.
        recentlyClosed.append(contentsOf: controller.tabs.reversed().map {
            ClosedTab(url: $0.displayURL, privacyMode: $0.privacyMode)
        })
        trimRecentlyClosed()
        controller.tearDown()
        windows.removeAll { $0 === controller }
        // After the removal, so the snapshot describes what is still open. The
        // frame is captured while the window still exists.
        sessionDidChange()
    }

    private func trimRecentlyClosed() {
        if recentlyClosed.count > maxRecentlyClosed {
            recentlyClosed.removeFirst(recentlyClosed.count - maxRecentlyClosed)
        }
    }
}
