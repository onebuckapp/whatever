import AppKit
import Combine
import WebKit

/// One browser window. A window owns an ordered list of tabs (a tab
/// always belongs to exactly one window) plus, separately, a content
/// layout that decides what the page area shows:
/// `.single` renders one tab, `.split` renders two tabs side by side.
/// Splitting therefore changes presentation only: the tabs stay in the
/// window's collection and in the tab bar.
/// Where ⌘W actually lands.
///
/// SwiftUI builds `File > Close` from the scene and it owns ⌘W. The app's own
/// `Close Tab` item is in the menu but has had its key equivalent stripped,
/// because SwiftUI resolves a duplicate ⌘W in favour of the earlier menu, and
/// File comes before Tab. So ⌘W could only ever reach `performClose:`, and that
/// closed the whole window no matter how many tabs were open.
///
/// The menu item is not ours to retarget, so the tab semantics have to live
/// wherever the key equivalent ends up: here.
final class BrowserWindow: NSWindow {
    /// How far the three window buttons move from AppKit's own placement.
    ///
    /// Derived from the strip, not historical. While the top strip was an
    /// `NSToolbar`, AppKit put them at container (19, 18) and that fit because the
    /// container included the toolbar's height. Without one the container is 28pt
    /// tall, so replaying +12 up parks their tops 6pt above the window and every
    /// resize clips them. The strip is 52pt with a 32pt bar centred in it, so the
    /// bar's centre is 26pt below the window top; 16pt buttons centred on it start
    /// 12pt left of and 12pt below AppKit's spot — container (19, -6), fully
    /// inside the window and clear of its rounded top corners.
    private static let windowButtonOffset = NSSize(width: 12, height: -12)

    /// The frames the buttons were left in the last time they were nudged.
    ///
    /// Compared against their current frames on every pass, so finding them
    /// already where they were put is a no-op. That comparison is the whole
    /// trick: AppKit re-lays these three out itself on every resize, and the
    /// frames it chooses replace whatever was there. Adding the offset
    /// unconditionally would stack it on every pass and walk the buttons across
    /// the strip; replaying frames captured for a taller window after a shrink
    /// is what used to put them off the top. Reading them fresh each time keeps
    /// the nudge glued to wherever AppKit currently has them.
    private var lastNudgedButtonFrames: [NSRect]?
    /// Resize notifications, held so they can be removed.
    private var positioningObservers: [NSObjectProtocol] = []
    /// The buttons currently watched for AppKit moving them.
    ///
    /// The show path cannot win a race it cannot see: the buttons are created and
    /// placed lazily across the first display passes, after every deferred nudge
    /// has already run and found nothing. Watching their frames instead reacts to
    /// the placement itself, whenever it lands — creation, resize layouts,
    /// fullscreen transitions — and re-nudges from there.
    private var trackedButtons: [NSButton] = []
    private var buttonFrameObservations: [NSKeyValueObservation] = []
    /// Set while moving the buttons, so the frame changes that move causes do not
    /// re-enter the positioner and stack the offset on every pass.
    private var isNudgingButtons = false
    /// Watches the title: selecting a tab retitles the window and page loads
    /// retitle it again, and AppKit re-lays the three buttons on each change.
    /// Without this the buttons sit at AppKit's own spot from the new tab
    /// until something else (usually refocusing the window) triggers a pass.
    private var titleObservation: NSKeyValueObservation?

    override init(contentRect contentRect: NSRect, styleMask style: NSWindow.StyleMask, backing backingStoreType: NSWindow.BackingStoreType, defer flag: Bool) {
        super.init(contentRect: contentRect, styleMask: style, backing: backingStoreType, defer: flag)
        observePositioning()
    }

    deinit {
        for observer in positioningObservers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    /// Fired after AppKit has laid the window out for its new size, which a
    /// `setFrame` override cannot see: the buttons are repositioned during the
    /// display pass that follows the frame change, not inside it.
    private func observePositioning() {
        let center = NotificationCenter.default
        for name in [NSWindow.didResizeNotification, NSWindow.didEndLiveResizeNotification] {
            positioningObservers.append(
                center.addObserver(forName: name, object: self, queue: .main) { [weak self] _ in
                    self?.positionWindowButtonsOnceOnScreen()
                }
            )
        }
        // Fired once the window is visible and key, strictly after the show calls
        // below — and after the first display pass that creates the buttons, which
        // those calls race and lose. This is what finally places them on launch,
        // where no resize ever comes to retrigger the layout.
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didBecomeMainNotification] {
            positioningObservers.append(
                center.addObserver(forName: name, object: self, queue: .main) { [weak self] _ in
                    self?.positionWindowButtonsOnceOnScreen()
                }
            )
        }
        // Retitling re-lays the buttons too — selecting a tab, and every page
        // title arriving after it — so the title is watched the same way.
        // Held, not fire-and-forget: the observation dies with the token.
        titleObservation = observe(\.title, options: [.new]) { [weak self] _, _ in
            self?.positionWindowButtonsOnceOnScreen()
        }
    }

    /// Applied from `setFrame` rather than once at launch, because AppKit re-lays
    /// these three out on resizes and undoes the nudge.
    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        super.setFrame(frameRect, display: flag)
        positionStandardWindowButtons()
    }

    /// The buttons are created and placed by AppKit while the window first shows,
    /// so ordering front is the earliest moment they exist to be nudged. Both
    /// entry points are covered because `showWindow` and direct
    /// `makeKeyAndOrderFront` do not necessarily route through each other, and
    /// doubling up is harmless: a pass that finds them already placed is a no-op.
    override func orderFront(_ sender: Any?) {
        super.orderFront(sender)
        positionWindowButtonsOnceOnScreen()
    }

    override func makeKeyAndOrderFront(_ sender: Any?) {
        super.makeKeyAndOrderFront(sender)
        positionWindowButtonsOnceOnScreen()
    }

    /// Applied again once the window is on screen, and after every resize.
    ///
    /// Runs twice — now and on the next turn of the runloop — because AppKit
    /// positions the buttons during the display pass that follows a frame change,
    /// not inside it. The deferred pass is what catches that layout; the
    /// immediate one covers programmatic changes whose layout already settled.
    ///
    /// This used to retry three more times at 0.1s, 0.5s and 1.5s. Those retries
    /// were standing in for the ability to see AppKit's placement, which the frame
    /// observation below now provides directly, and they were the visible half of
    /// the problem: a placement that landed after the last retry was corrected
    /// hundreds of milliseconds late, so activating the window showed the buttons
    /// at AppKit's own position and then, visibly, snapping to the nudged one.
    func positionWindowButtonsOnceOnScreen() {
        positionStandardWindowButtons()
        DispatchQueue.main.async { [weak self] in
            self?.positionStandardWindowButtons()
        }
    }

    private func positionStandardWindowButtons() {
        // Nothing to do in fullscreen: AppKit hides and moves these itself, and
        // nudging them there is what left them off the window on the way back out.
        // The last-nudged frames are deliberately left alone, so the first pass
        // after leaving fullscreen sees AppKit's post-exit placement as new and
        // nudges from there.
        guard !styleMask.contains(.fullScreen) else { return }
        let buttons = [
            standardWindowButton(.closeButton),
            standardWindowButton(.miniaturizeButton),
            standardWindowButton(.zoomButton),
        ].compactMap { $0 }
        guard !buttons.isEmpty else { return }
        trackButtons(buttons)

        // Already where they were put: AppKit has not moved them since.
        let current = buttons.map(\.frame)
        if let last = lastNudgedButtonFrames, last == current { return }

        // Without this, Core Animation treats the move as an implicit transition
        // and slides the buttons from wherever AppKit put them to the nudged
        // position, which reads as the buttons wandering across the strip. The
        // correction has to be a single step or it is the same artefact the retry
        // timers used to cause, just slower.
        isNudgingButtons = true
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for button in buttons {
            button.setFrameOrigin(
                NSPoint(
                    x: button.frame.origin.x + Self.windowButtonOffset.width,
                    y: button.frame.origin.y + Self.windowButtonOffset.height
                )
            )
        }
        CATransaction.commit()
        isNudgingButtons = false
        lastNudgedButtonFrames = buttons.map(\.frame)
    }

    /// Watches the buttons' frames, re-observing when AppKit swaps the instances.
    ///
    /// A change the positioner did not make is AppKit placing them, so it comes
    /// straight back here for a nudge. A change it did make is skipped by the
    /// flag, without which every nudge would re-enter and walk the buttons away.
    private func trackButtons(_ buttons: [NSButton]) {
        let wanted = Set(buttons.map(ObjectIdentifier.init))
        guard wanted != Set(trackedButtons.map(ObjectIdentifier.init)) else { return }
        buttonFrameObservations.removeAll()
        trackedButtons = buttons
        for button in buttons {
            buttonFrameObservations.append(
                button.observe(\.frame, options: [.new]) { [weak self] _, _ in
                    guard let self, !self.isNudgingButtons else { return }
                    self.positionStandardWindowButtons()
                }
            )
        }
    }

    /// ⌘W closes the current tab, and only closes the window once there is no tab
    /// left to close.
    ///
    /// Two different things arrive here and they do not mean the same thing. The
    /// red close button sends itself as the sender; `File > Close`, which is what
    /// owns ⌘W, sends nothing. In a browser ⌘W is a tab close and the button is
    /// not, so the sender is what tells them apart.
    ///
    /// Falling through to `super` once a single tab is left is also what stops
    /// this recursing: closing that last tab brings the window back here by way of
    /// `removeTab`'s empty-tabs branch, and with nothing left to close it goes
    /// straight through.
    ///
    /// The button is told apart rather than retargeted on purpose. Assigning a new
    /// action to `standardWindowButton(.closeButton)` before the window is shown
    /// corrupts the close path badly enough that lldb faults in the middle of the
    /// next close, and there is no earlier moment than that to do it in.
    override func performClose(_ sender: Any?) {
        guard !(sender is NSButton),
              let controller = BrowserCoordinator.shared.controller(for: self),
              controller.tabs.count > 1,
              let tab = controller.selectedTab
        else {
            super.performClose(sender)
            return
        }
        controller.closeTab(tab)
    }
}

final class BrowserWindowController: NSWindowController {
    enum ContentLayout: Equatable {
        case single(tabID: UUID)
        case split(leadingTabID: UUID, trailingTabID: UUID, ratio: CGFloat)
    }

    private(set) var tabs: [BrowserTab] = []
    private(set) var selectedTabID: UUID?
    private(set) var layout: ContentLayout
    /// The sticky split group: the pair (and ratio) that renders joined in
    /// the tab bar and side by side in the page area.
    ///
    /// `layout` is only the current view — selecting a tab outside the group
    /// shows that tab alone but keeps this, so opening a new tab hides the
    /// split without destroying it and reselecting a member brings it back.
    /// Only closing or displacing a member dissolves it.
    private(set) var splitGroup: ContentLayout?

    private let activeModel = ActivePaneModel()
    private var toolbarController: BrowserToolbarController!
    private let contentController: BrowserWindowContentViewController
    private let dropPreview = SplitDropPreviewView()

    private var splitController: BrowserSplitViewController?
    private var singlePane: BrowserPaneController?
    private var paneCache: [UUID: BrowserPaneController] = [:]
    private var titleSubscription: AnyCancellable?
    private var progressCancellables = Set<AnyCancellable>()
    private var menuTargets: [UUID: TabMenuTarget] = [:]
    /// Held while a group menu is on screen: `NSMenuItem` targets are weak.
    private var groupMenuTarget: TabGroupMenuTarget?
    /// Observers for the frame notifications, held so they can be removed.
    private var frameObservers: [NSObjectProtocol] = []

    // MARK: - Init

    init(tab: BrowserTab) {
        self.layout = .single(tabID: tab.id)
        let content = BrowserWindowContentViewController()
        self.contentController = content
        let window = Self.makeWindow(content: content)
        super.init(window: window)
        configureChrome()
        adoptTabs([tab], selectedTabID: tab.id)
        selectTab(tab)
        refresh()

        // Must come after init: with a hidden transparent titlebar,
        // sizing the content before super.init is lost and the window
        // collapses to content fitting size on first show.
        window.setContentSize(NSSize(width: 1300, height: 840))
    }

    /// Rebuilds a window from a stored session.
    ///
    /// The tabs come back without web views, so a window that had a dozen tabs
    /// open builds pages only for the ones its layout actually shows. Everything
    /// else waits until it is selected.
    init(restoring record: SessionSnapshot.WindowSnapshot, history: HistoryRecording) {
        // A tab whose stored address will not parse cannot be rebuilt, so it is
        // dropped rather than restored to the homepage and quietly disagreeing
        // with the document.
        let rebuilt = record.tabs.compactMap { tabRecord -> BrowserTab? in
            guard let urls = tabRecord.restoredURLs, !urls.isEmpty else { return nil }
            return BrowserTab(
                id: tabRecord.id,
                privacyMode: .regular,
                history: history,
                restored: .init(
                    urls: urls,
                    index: min(tabRecord.restoredIndex, urls.count - 1),
                    title: tabRecord.title,
                    isPinned: tabRecord.isPinned,
                    isMuted: tabRecord.isMuted ?? false
                )
            )
        }
        // A record whose every tab failed to rebuild still opens a usable window
        // rather than a blank one.
        let restoredTabs = rebuilt.isEmpty
            ? [BrowserTab(history: history)]
            : rebuilt
        let rebuiltIDs = Set(restoredTabs.map(\.id))

        // The layout is normalized against the tabs that actually came back, so
        // it can never name a pane that has nothing to show.
        let layout: ContentLayout
        switch record.layout {
        case .single(let id):
            layout = .single(tabID: rebuiltIDs.contains(id) ? id : (restoredTabs.first?.id ?? UUID()))
        case .split(let leading, let trailing, let ratio):
            let canRestoreBoth = rebuiltIDs.contains(leading)
                && rebuiltIDs.contains(trailing)
                && leading != trailing
            layout = canRestoreBoth
                ? .split(
                    leadingTabID: leading,
                    trailingTabID: trailing,
                    ratio: CGFloat(ratio)
                )
                : .single(tabID: restoredTabs.first?.id ?? UUID())
        }
        self.layout = layout
        // The sticky group comes back with the window, so a split hidden
        // behind another tab at quit still renders joined and reselects
        // into view. An old document without one falls back to the shown
        // layout, which names a valid pair exactly when it is a split.
        var restoredGroup: ContentLayout?
        if let saved = record.splitGroup,
           case .split(let leading, let trailing, let ratio) = saved,
           rebuiltIDs.contains(leading), rebuiltIDs.contains(trailing),
           leading != trailing {
            restoredGroup = .split(
                leadingTabID: leading,
                trailingTabID: trailing,
                ratio: CGFloat(ratio)
            )
        } else if case .split = layout {
            restoredGroup = layout
        }
        self.splitGroup = restoredGroup

        let content = BrowserWindowContentViewController()
        self.contentController = content
        let window = Self.makeWindow(content: content)
        super.init(window: window)
        configureChrome()
        adoptTabs(restoredTabs, selectedTabID: nil)

        // `selectTab` collapses a split when the selection is not one of its
        // panes, so the selection is settled before it runs. A stored selection
        // that cannot belong to the stored split must not collapse it; the split
        // is the more distinctive state and is still worth restoring.
        let layoutIDs = layout.tabIDs.filter { rebuiltIDs.contains($0) }
        let storedSelection = record.selectedTabID.flatMap { rebuiltIDs.contains($0) ? $0 : nil }
        let selection = storedSelection.flatMap { candidate in
            layoutIDs.contains(candidate) ? candidate : nil
        } ?? layoutIDs.first ?? storedSelection ?? restoredTabs.first?.id

        if let selection, let tab = restoredTabs.first(where: { $0.id == selection }) {
            selectTab(tab)
        } else {
            refresh()
        }

        if record.frame.isUsable {
            window.setFrame(record.frame.rect, display: true)
        }
    }

    convenience init(
        initialURL: URL? = nil,
        privacyMode: BrowserPrivacyMode = .regular,
        history: HistoryRecording
    ) {
        self.init(tab: BrowserTab(privacyMode: privacyMode, history: history, initialURL: initialURL))
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Init plumbing

    private static func makeWindow(content: BrowserWindowContentViewController) -> NSWindow {
        let window = BrowserWindow(contentViewController: content)
        // `fullSizeContentView` puts the content view across the whole window
        // rather than starting below the titlebar, which combined with the
        // transparent titlebar below is what lets the page background run up
        // behind the toolbar strip. Nothing else reserves that strip: it used to
        // come from the native toolbar's safe-area inset, and `BrowserToolbarView`
        // now contributes it explicitly, so the tab bar stays exactly where it
        // was.
        window.styleMask = [
            .titled, .closable, .miniaturizable, .resizable, .fullSizeContentView,
        ]
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        return window
    }

    /// Everything that does not depend on which tabs exist: the toolbar strip, the
    /// tab bar's wiring, and the drop handlers.
    private func configureChrome() {
        // The toolbar controller needs this controller, so it can only
        // be built after super.init.
        let toolbarController = BrowserToolbarController(controller: self)
        self.toolbarController = toolbarController
        contentController.installToolbar(toolbarController.toolbarView)
        // Now the content view exists, so the spotlight's dropdown has somewhere to
        // live: the content view, not the strip, so it can cover the tab bar and
        // the page.
        toolbarController.attachSpotlightDropdown(to: contentController.view)

        contentController.installDropPreview(dropPreview)
        contentController.setNewTabAction { [weak self] in
            guard let self else { return }
            BrowserCoordinator.shared.newTab(in: self)
        }
        contentController.tabBar.strip.delegate = self
        contentController.tabBar.strip.owner = self
        contentController.onDropZoneChanged = { [weak self] zone in
            guard let self else { return }
            if let zone {
                self.dropPreview.present(zone: zone, animated: true)
            } else {
                self.dropPreview.dismiss()
            }
        }
        contentController.onTabDropped = { [weak self] tab, zone in
            self?.handleSplitDrop(of: tab, zone: zone)
        }
        contentController.onTabGroupDropped = { [weak self] pair in
            guard let self else { return }
            BrowserCoordinator.shared.moveTabs(pair, to: self.tabs.count, in: self)
        }
        toolbarController.onAddressSubmitted = { [weak self] url in
            self?.openAddress(url)
        }
        toolbarController.onSettings = { [weak self] in
            self?.presentSettings()
        }
        // The trailing buttons are shortcuts into the settings modal rather than
        // separate surfaces, so there is one place for those panes to live.
        // Downloads is the exception: the button opens the history popup over
        // the current pane, and only the settings sidebar leads to download
        // settings.
        toolbarController.onDownloads = { [weak self] in
            guard let self, let tab = self.selectedTab else {
                SystemBeep.play()
                return
            }
            self.pane(for: tab).presentDownloads()
        }
        toolbarController.onBookmarks = { [weak self] in
            self?.presentSettings(section: .bookmarks)
        }
        toolbarController.onAdBlock = { [weak self] in
            self?.presentAdBlockPopup()
        }
        toolbarController.onFeed = { [weak self] candidates in
            self?.presentFeedReader(candidates: candidates)
        }
        contentController.onOpenFeedArticle = { [weak self] url, newTab in
            self?.openFeedArticle(url, inNewTab: newTab)
        }
        // A modal card takes the mouse away from the pages for its duration.
        contentController.onShieldChanged = { [weak self] shielded in
            self?.setPagesInteractive(!shielded)
        }

        // Where a window sits is part of the session, so moving or resizing one
        // schedules a write. The store's debounce collapses a whole drag into a
        // single save.
        if let window {
            for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification] {
                frameObservers.append(
                    NotificationCenter.default.addObserver(
                        forName: name, object: window, queue: .main
                    ) { [weak self] _ in
                        MainActor.assumeIsolated { self?.sessionDidChange() }
                    }
                )
            }
        }
    }

    deinit {
        for observer in frameObservers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    /// Takes ownership of `tabs` in order, without selecting or refreshing: the
    /// caller decides what the page area ends up showing.
    private func adoptTabs(_ tabs: [BrowserTab], selectedTabID: UUID?) {
        self.tabs = tabs
        self.selectedTabID = selectedTabID
        for tab in tabs {
            tab.onWebViewReplaced = { [weak self, weak tab] in
                guard let tab else { return }
                self?.webViewReplaced(for: tab)
            }
        }
    }

    /// Records that this window's share of the session changed.
    private func sessionDidChange() {
        BrowserCoordinator.shared.sessionDidChange()
    }

    /// Hands the mouse to every open page, or takes it away from all of them.
    ///
    /// Called for the lifetime of a modal card. Only realized pages need anything
    /// doing: a tab with no view is already unable to see the pointer, and picks
    /// up the right state when it builds one.
    private func setPagesInteractive(_ interactive: Bool) {
        for tab in tabs {
            tab.setAcceptsMouseInput(interactive)
        }
    }

    // MARK: - Tabs

    var selectedTab: BrowserTab? {
        tabs.first { $0.id == selectedTabID } ?? tabs.first
    }

    /// Tabs the page area is currently showing.
    var displayedTabs: [BrowserTab] {
        switch layout {
        case .single(let tabID):
            return tabs.filter { $0.id == tabID }
        case .split(let leading, let trailing, _):
            return [leading, trailing].compactMap { id in tabs.first { $0.id == id } }
        }
    }

    var isSplit: Bool {
        if case .split = layout {
            return true
        }
        return false
    }

    func addTab(_ tab: BrowserTab, at index: Int? = nil, select: Bool = true) {
        guard !tabs.contains(where: { $0.id == tab.id }) else { return }
        tab.onWebViewReplaced = { [weak self, weak tab] in
            guard let tab else { return }
            self?.webViewReplaced(for: tab)
        }
        let target = min(max(0, index ?? tabs.count), tabs.count)
        tabs.insert(tab, at: target)
        if select {
            selectTab(tab)
        } else {
            refresh()
        }
        sessionDidChange()
    }

    func selectTab(_ tab: BrowserTab) {
        guard tabs.contains(where: { $0.id == tab.id }) else { return }

        dismissQRCode()
        dismissFileBrowser()
        dismissDownloads()

        selectedTabID = tab.id
        tab.markActive()
        activeModel.activeTabID = tab.id
        toolbarController.setTab(tab)
        bindProgress(to: tab)
        titleSubscription = tab.tabController.$title.sink { [weak self] title in
            self?.window?.title = title
        }
        window?.title = tab.tabController.title

        // The split is sticky: selecting a member restores its view, while
        // selecting anything else shows that tab alone but keeps the group,
        // so opening a new tab hides the split without destroying it.
        if let group = validSplitGroup(),
           case .split(let leading, let trailing, let ratio) = group,
           [leading, trailing].contains(tab.id) {
            layout = .split(leadingTabID: leading, trailingTabID: trailing, ratio: ratio)
        } else {
            if case .split = layout {
                splitGroup = layout
            }
            layout = .single(tabID: tab.id)
        }
        refresh()
        sessionDidChange()
    }

    /// The sticky group, only when both members are still tabs of this
    /// window. A group naming a closed tab must never drive the view.
    private func validSplitGroup() -> ContentLayout? {
        guard let group = splitGroup,
              case .split(let leading, let trailing, _) = group,
              tabs.contains(where: { $0.id == leading }),
              tabs.contains(where: { $0.id == trailing })
        else { return nil }
        return group
    }

    /// Drives the 2pt indicator under the toolbar from the active tab.
    private func bindProgress(to tab: BrowserTab) {
        progressCancellables.removeAll()
        tab.tabController.$estimatedProgress
            .combineLatest(tab.tabController.$isLoading)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] progress, isLoading in
                self?.contentController.updateProgress(progress, isLoading: isLoading)
            }
            .store(in: &progressCancellables)
    }

    func moveTab(_ tab: BrowserTab, to index: Int) {
        guard let from = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        tabs.remove(at: from)
        tabs.insert(tab, at: min(max(0, index), tabs.count))
        refresh()
        sessionDidChange()
    }

    /// Reorders a split group as one unit, keeping pane order. The sticky
    /// group names IDs rather than indices, so it survives the move untouched.
    func moveTabPair(_ pair: [BrowserTab], to index: Int) {
        guard pair.count == 2,
              tabs.contains(where: { $0.id == pair[0].id }),
              tabs.contains(where: { $0.id == pair[1].id })
        else { return }
        let ids = Set(pair.map(\.id))
        let remaining = tabs.filter { !ids.contains($0.id) }
        let target = min(max(0, index), remaining.count)
        tabs = Array(remaining[..<target]) + pair + Array(remaining[target...])
        refresh()
        sessionDidChange()
    }

    /// Dissolves the sticky group without closing anything: the pair stays
    /// as two adjacent tabs and the page shows the selection alone. This is
    /// what "Close Pane" means on a grouped cell — reverting, not closing.
    func dissolveGroup() {
        guard splitGroup != nil else { return }
        splitGroup = nil
        if case .split = layout, let tab = selectedTab {
            layout = .single(tabID: tab.id)
        }
        refresh()
        sessionDidChange()
    }

    /// Dissolves the group when it names `tab`, leaving everything else
    /// alone. Pinning a member un-groups it: a pinned cell has room for a
    /// favicon only, never for two titles.
    func dissolveGroupIfContains(_ tab: BrowserTab) {
        guard let group = validSplitGroup(),
              case .split(let leading, let trailing, _) = group,
              leading == tab.id || trailing == tab.id
        else { return }
        dissolveGroup()
    }

    /// Closes both members of the sticky group. What the group cell's single
    /// close button does.
    func closeGroup() {
        guard let group = validSplitGroup(),
              case .split(let leading, let trailing, _) = group,
              let first = tabs.first(where: { $0.id == leading }),
              let second = tabs.first(where: { $0.id == trailing })
        else { return }
        BrowserCoordinator.shared.recordClosedTab(first)
        BrowserCoordinator.shared.recordClosedTab(second)
        removeTab(first)
        // The first removal dissolved the group; the second is plain.
        if tabs.contains(where: { $0.id == second.id }) {
            removeTab(second)
        }
    }

    @discardableResult
    func duplicateTab(_ tab: BrowserTab) -> BrowserTab {
        // A blank page duplicates as a fresh homepage, not as about:blank.
        let url = tab.displayURL
        let copy = BrowserTab(
            privacyMode: tab.privacyMode,
            history: BrowserCoordinator.shared.history,
            initialURL: url.isAddresslessPage ? nil : url
        )
        let index = tabs.firstIndex(where: { $0.id == tab.id }).map { $0 + 1 }
        addTab(copy, at: index)
        return copy
    }

    /// Adds an already existing tab, e.g. one created for another
    /// window or reopened from history.
    @discardableResult
    func addExistingTab(_ tab: BrowserTab) -> BrowserTab {
        addTab(tab)
        return tab
    }

    /// Selects the tab `offset` positions along the tab bar.
    func selectTab(atOffset offset: Int) {
        guard !tabs.isEmpty, let selected = selectedTab,
              let index = tabs.firstIndex(where: { $0.id == selected.id })
        else {
            SystemBeep.play()
            return
        }
        selectTab(tabs[(index + offset + tabs.count) % tabs.count])
    }

    /// Releases window-owned state. Tabs survive so they can be reopened
    /// or adopted by another window.
    func tearDown() {
        for tab in tabs {
            if let pane = paneCache.removeValue(forKey: tab.id) {
                contentController.forgetChild(pane)
            }
            // The window is closing, so nothing will ever need these pages
            // again; dropping the views releases their processes.
            tab.discardWebView()
        }
        paneCache.removeAll()
        menuTargets.removeAll()
        progressCancellables.removeAll()
        titleSubscription = nil
    }

    /// Removes a tab without closing it, so another window can adopt
    /// it. An emptied window closes itself.
    func detachTab(_ tab: BrowserTab) {
        guard let index = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        tabs.remove(at: index)

        switch layout {
        case .split(let leading, let trailing, _):
            // A split needs two distinct tabs, so taking either displayed pane
            // leaves one and the split has to go. Pointing both panes at the
            // survivor instead would show the same tab twice and still report
            // `isSplit`, which is what this used to do. The ratio goes with it:
            // there is nothing left to divide.
            if leading == tab.id {
                layout = .single(tabID: trailing)
            } else if trailing == tab.id {
                layout = .single(tabID: leading)
            }
        case .single(let tabID) where tabID == tab.id:
            // `index` may now point past the end when the detached tab
            // was last; clamp like the selection below does.
            layout = tabs.isEmpty
                ? .single(tabID: tab.id)
                : .single(tabID: tabs[min(index, tabs.count - 1)].id)
        case .single:
            break
        }
        dissolveSplitGroup(naming: tab.id)

        if let pane = paneCache.removeValue(forKey: tab.id) {
            // Pane popups live at window level above the shield, so unlike
            // the page they do not go away with the pane on their own.
            pane.dismissQRCode()
            pane.dismissFileBrowser()
            pane.dismissDownloads()
            contentController.forgetChild(pane)
        }
        // The view moves with the tab, so it is only unparented here.
        tab.webView?.removeFromSuperview()
        menuTargets.removeValue(forKey: tab.id)

        if tabs.isEmpty {
            BrowserCoordinator.shared.close(self)
        } else {
            selectTab(tabs[min(index, tabs.count - 1)])
        }
        sessionDidChange()
    }

    /// Drops the sticky group when one of its members leaves the window. A
    /// group naming a gone tab must never drive the view back.
    private func dissolveSplitGroup(naming tabID: UUID) {
        guard case .split(let leading, let trailing, _) = splitGroup,
              leading == tabID || trailing == tabID
        else { return }
        splitGroup = nil
    }

    /// Removes a tab. The last tab closes the window; a removed tab
    /// leaves the split so it stops being displayed.
    func removeTab(_ tab: BrowserTab) {
        guard let index = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        tabs.remove(at: index)

        switch layout {
        case .single(let tabID) where tabID == tab.id:
            // `index` may now point past the end when the closed tab was
            // last; clamp like the selection below does.
            layout = tabs.isEmpty
                ? .single(tabID: tab.id)
                : .single(tabID: tabs[min(index, tabs.count - 1)].id)
        case .split(let leading, let trailing, _):
            // A split needs two distinct tabs, so taking either displayed pane
            // leaves one and the split has to go. Pointing both panes at the
            // survivor instead would show the same tab twice and still report
            // `isSplit`, which is what this used to do. The ratio goes with it:
            // there is nothing left to divide.
            if leading == tab.id {
                layout = .single(tabID: trailing)
            } else if trailing == tab.id {
                layout = .single(tabID: leading)
            }
        case .single:
            break
        }
        dissolveSplitGroup(naming: tab.id)

        if let pane = paneCache.removeValue(forKey: tab.id) {
            contentController.forgetChild(pane)
        }
        tab.webView?.removeFromSuperview()
        menuTargets.removeValue(forKey: tab.id)

        if tabs.isEmpty {
            BrowserCoordinator.shared.close(self)
            return
        }

        let next = selectedTabID.flatMap { id in tabs.first { $0.id == id } }
            ?? tabs[min(index, tabs.count - 1)]
        selectTab(next)
        sessionDidChange()
    }

    func closeTab(_ tab: BrowserTab) {
        BrowserCoordinator.shared.recordClosedTab(tab)
        removeTab(tab)
    }

    /// Closes the tab hosting `webView` because its page called `window.close()`.
    ///
    /// Deliberately not `closeTab`: that records the tab for reopening, and a
    /// popup taking itself back out is not a visit anyone asked to undo. It would
    /// also reopen as the homepage, since a popup has no address of its own until
    /// WebKit finishes navigating it.
    func closePopupTab(_ webView: WKWebView) {
        guard let tab = tabs.first(where: { $0.webView === webView }) else { return }
        removeTab(tab)
    }

    func closeOtherTabs(except tab: BrowserTab) {
        for other in tabs where other.id != tab.id {
            removeTab(other)
        }
    }

    func closeTabs(toTheRightOf tab: BrowserTab) {
        guard let index = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        for other in tabs[(index + 1)...] {
            removeTab(other)
        }
    }

    // MARK: - Split view

    /// Splits `currentTab` with `droppedTab` in the given direction.
    /// Transactional: the layout only changes when both tabs are known
    /// and the zone is a real half.
    @discardableResult
    func createSplit(
        currentTab: BrowserTab,
        droppedTab: BrowserTab,
        zone: SplitDropZone
    ) -> Bool {
        guard currentTab.id != droppedTab.id else { return false }
        guard tabs.contains(where: { $0.id == currentTab.id }),
              tabs.contains(where: { $0.id == droppedTab.id })
        else {
            return false
        }
        // A group cell has room for two titles, never for pinned cells: a
        // pinned tab cannot join a split.
        guard !currentTab.presentation.isPinned,
              !droppedTab.presentation.isPinned
        else {
            SystemBeep.play()
            return false
        }

        let ratio: CGFloat = BrowserSplitViewController.defaultRatio
        switch zone {
        case .leading:
            layout = .split(
                leadingTabID: droppedTab.id,
                trailingTabID: currentTab.id,
                ratio: ratio
            )
        case .trailing:
            layout = .split(
                leadingTabID: currentTab.id,
                trailingTabID: droppedTab.id,
                ratio: ratio
            )
        case .center:
            return false
        }
        if case .split(let leading, let trailing, _) = layout {
            placeAdjacent(leadingTabID: leading, trailingTabID: trailing)
            splitGroup = layout
        }

        rebuildSplitView()
        selectTab(droppedTab)
        sessionDidChange()
        return true
    }

    /// Drops a tab onto an existing split: it replaces the pane on that
    /// side, and the tab it displaced returns to being just a tab.
    func replacePane(with tab: BrowserTab, zone: SplitDropZone) {
        guard case .split(let leading, let trailing, let ratio) = layout else {
            if let current = selectedTab {
                createSplit(currentTab: current, droppedTab: tab, zone: zone)
            }
            return
        }
        guard !tab.presentation.isPinned else {
            SystemBeep.play()
            return
        }
        switch zone {
        case .leading:
            layout = .split(leadingTabID: tab.id, trailingTabID: trailing, ratio: ratio)
        case .trailing:
            layout = .split(leadingTabID: leading, trailingTabID: tab.id, ratio: ratio)
        case .center:
            return
        }
        if case .split(let leading, let trailing, _) = layout {
            placeAdjacent(leadingTabID: leading, trailingTabID: trailing)
            splitGroup = layout
        }
        rebuildSplitView()
        selectTab(tab)
        sessionDidChange()
    }

    /// Pulls the split pair together in the tab bar, in pane order, so the
    /// two cells render joined. The anchor is the earlier of the two tabs,
    /// so forming a group disturbs the order as little as possible.
    private func placeAdjacent(leadingTabID: UUID, trailingTabID: UUID) {
        guard let leading = tabs.first(where: { $0.id == leadingTabID }),
              let trailing = tabs.first(where: { $0.id == trailingTabID }),
              let leadingIndex = tabs.firstIndex(where: { $0.id == leadingTabID }),
              let trailingIndex = tabs.firstIndex(where: { $0.id == trailingTabID })
        else { return }
        guard trailingIndex != leadingIndex + 1 else { return }
        let anchor = min(leadingIndex, trailingIndex)
        let others = tabs.filter { $0.id != leadingTabID && $0.id != trailingTabID }
        tabs = Array(others[..<min(anchor, others.count)])
            + [leading, trailing]
            + Array(others[min(anchor, others.count)...])
    }

    /// Splits the selected tab with the next tab in the tab bar.
    func splitWithNextTab() {
        guard let tab = selectedTab,
              let index = tabs.firstIndex(where: { $0.id == tab.id }),
              tabs.indices.contains(index + 1)
        else {
            SystemBeep.play()
            return
        }
        if isSplit {
            replacePane(with: tabs[index + 1], zone: .trailing)
        } else {
            createSplit(currentTab: tab, droppedTab: tabs[index + 1], zone: .trailing)
        }
    }

    func splitWithPreviousTab() {
        guard let tab = selectedTab,
              let index = tabs.firstIndex(where: { $0.id == tab.id }),
              index > 0
        else {
            SystemBeep.play()
            return
        }
        if isSplit {
            replacePane(with: tabs[index - 1], zone: .leading)
        } else {
            createSplit(currentTab: tab, droppedTab: tabs[index - 1], zone: .leading)
        }
    }

    /// Removes the pane showing `tab` and collapses back to one pane.
    func closePane(_ tab: BrowserTab) {
        guard isSplit else {
            closeTab(tab)
            return
        }
        let remaining = displayedTabs.first { $0.id != tab.id }
        guard let remaining else {
            closeTab(tab)
            return
        }
        // Explicitly closed, not merely hidden: the group goes with it.
        splitGroup = nil
        layout = .single(tabID: remaining.id)
        rebuildContent()
        selectTab(remaining)
        sessionDidChange()
    }

    func collapseSplit() {
        guard isSplit, let tab = selectedTab ?? displayedTabs.first else { return }
        splitGroup = nil
        layout = .single(tabID: tab.id)
        rebuildContent()
        sessionDidChange()
    }

    func focusNextPane() {
        focusPane(step: 1)
    }

    func focusPreviousPane() {
        focusPane(step: -1)
    }

    /// Puts the caret in the address bar, which is what a new tab wants.
    ///
    /// Call this *after* the tab has been added and selected, never before.
    /// `selectTab` goes through `toolbarController.setTab`, which clears
    /// `isEditingAddress` and rewrites the field's text; focusing first would
    /// leave the field holding focus with that flag false, and the next
    /// `syncControls` would then overwrite whatever had been typed into it.
    func focusAddressBar() {
        toolbarController.focusAddressField()
    }

    private func focusPane(step: Int) {
        let visible = displayedTabs
        guard visible.count > 1, let tab = selectedTab,
              let index = visible.firstIndex(where: { $0.id == tab.id })
        else {
            SystemBeep.play()
            return
        }
        let next = visible[(index + step + visible.count) % visible.count]
        selectTab(next)
        // The pane is on screen by now, so this is already realized; asking the
        // tab for it directly keeps the call honest if that ever stops being true.
        window?.makeFirstResponder(next.ensureWebView())
    }

    // MARK: - Drop handling

    /// Commits a tab drop onto the page area: the tab stays in this
    /// window's tab bar and only its presentation changes.
    func handleSplitDrop(of tab: BrowserTab, zone: SplitDropZone) {
        guard zone != .center else {
            SystemBeep.play()
            return
        }
        if isSplit {
            replacePane(with: tab, zone: zone)
        } else if let current = selectedTab {
            createSplit(currentTab: current, droppedTab: tab, zone: zone)
        }
    }

    // MARK: - Refresh

    func refresh() {
        normalizeTabOrder()
        refreshTabBar()
        rebuildContent()
        let minimumWidth: CGFloat = isSplit ? 560 : 360
        window?.contentMinSize = NSSize(width: minimumWidth, height: 320)
    }

    func refreshTabBar() {
        // The bar joins the sticky pair whether it is on screen or hidden,
        // so the group reads as one unit until it is dissolved.
        var pair: (UUID, UUID)?
        if let group = validSplitGroup(),
           case .split(let leading, let trailing, _) = group {
            pair = (leading, trailing)
        }
        contentController.tabBar.strip.setTabs(
            tabs, selectedTabID: selectedTabID, splitPair: pair)
    }

    /// Pinned tabs always lead the bar. Keeping that invariant in the
    /// model means the tab bar's drop indices are model indices.
    private func normalizeTabOrder() {
        guard tabs.contains(where: \.presentation.isPinned) else { return }
        let ordered = tabs.filter(\.presentation.isPinned)
            + tabs.filter { !$0.presentation.isPinned }
        guard ordered != tabs else { return }
        tabs = ordered
    }

    func tabMenuTarget(for tab: BrowserTab) -> TabMenuTarget {
        if let existing = menuTargets[tab.id] {
            existing.rebind(tab: tab)
            return existing
        }
        let target = TabMenuTarget(controller: self, tab: tab)
        menuTargets[tab.id] = target
        return target
    }

    /// Holds a group menu's target for the menu's lifetime.
    func retainGroupMenuTarget(_ target: TabGroupMenuTarget) {
        groupMenuTarget = target
    }

    // MARK: - Content

    /// Rehosts the tab's replacement view after a navigation swapped it:
    /// the old pane is discarded and a new pane hosts the new view.
    private func webViewReplaced(for tab: BrowserTab) {
        guard tabs.contains(where: { $0.id == tab.id }) else { return }
        dismissQRCode()
        dismissFileBrowser()
        dismissDownloads()
        if let pane = paneCache.removeValue(forKey: tab.id) {
            contentController.forgetChild(pane)
        }
        rebuildContent()
    }

    private func pane(for tab: BrowserTab) -> BrowserPaneController {
        if let cached = paneCache[tab.id] {
            return cached
        }
        let pane = BrowserPaneController(tab: tab, activeModel: activeModel)
        paneCache[tab.id] = pane
        return pane
    }

    // MARK: - QR code

    /// Shows the QR card for `tab`'s page over that tab's pane.
    func presentQRCode(for tab: BrowserTab) {
        guard let url = tab.webView?.url, !url.isAddresslessPage else {
            SystemBeep.play()
            return
        }
        // A hidden tab has no pane in the current layout. Show it first so
        // the card has a visible page to cover.
        if !displayedTabs.contains(where: { $0.id == tab.id }) {
            selectTab(tab)
        }
        pane(for: tab).presentQRCode(text: url.absoluteString)
    }

    // MARK: - Local files

    /// Opens an address from the address bar. `w://settings` opens the
    /// Settings modal over the current page instead of navigating: it is a
    /// command, not a place, so the tab keeps its address and history
    /// untouched. `file://` directories open the
    /// native browser popup over the current page instead of navigating:
    /// WebKit's own directory listing is what this replaces, and a listing
    /// is browsed, not visited, so it takes no history entry. Everything
    /// else — including `file://` files, which WebKit renders — navigates
    /// the selected tab as before.
    func openAddress(_ url: URL) {
        if Self.isSettingsAddress(url) {
            presentSettings()
            return
        }
        if Self.isFileDirectory(url) {
            guard let tab = selectedTab else {
                SystemBeep.play()
                return
            }
            pane(for: tab).presentFileBrowser(url: url)
            return
        }
        selectedTab?.navigate(to: url)
    }

    /// Whether `url` is the settings address: scheme `w` (or its retired
    /// `whtvr` alias) with host `settings`. `URL` already lowercases both,
    /// so no case folding is needed here.
    static func isSettingsAddress(_ url: URL) -> Bool {
        guard ["w", "whtvr"].contains(url.scheme?.lowercased()) else { return false }
        return url.host?.lowercased() == "settings"
    }

    /// Whether `url` names a directory on this machine. Synchronous
    /// `FileManager` rather than a core round trip: the app is unsandboxed,
    /// and routing only needs the kind, not the contents.
    static func isFileDirectory(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "file" else { return false }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            return false
        }
        return isDirectory.boolValue
    }

    /// Opens a clicked `file://` link for the tab that owns the click:
    /// directories in that tab's popup, files through the tab so they render
    /// with history. Split from `openAddress`, where only the selection is
    /// known rather than the tab.
    func openFileLink(_ url: URL, for tab: BrowserTab) {
        if Self.isFileDirectory(url) {
            pane(for: tab).presentFileBrowser(url: url)
            return
        }
        tab.navigate(to: url)
    }

    /// Closes every open file browser, used when the layout or selection
    /// changes out from under one. Mirrors the QR dismissal: popups belong
    /// to the pane layout showing them.
    func dismissFileBrowser() {
        for pane in paneCache.values {
            pane.dismissFileBrowser()
        }
    }

    /// Closes every open downloads popup, on the same transitions: the card
    /// belongs to the pane layout showing it, not to the selection.
    func dismissDownloads() {
        for pane in paneCache.values {
            pane.dismissDownloads()
        }
    }

    /// Claims the window's modal shield for a pane popup (file browser,
    /// downloads, QR card). One shield serves the whole window by claim, so coexisting
    /// pane cards never steal each other's cover; a shield click dismisses
    /// the frontmost card.
    func claimPopupShield(id: String, onDismiss: @escaping () -> Void) {
        contentController.claimShield(id: id, dismissOnPress: true, onDismiss: onDismiss)
    }

    /// Releases a pane popup's shield claim. Unknown ids are no-ops.
    func releasePopupShield(id: String) {
        contentController.releaseShield(id: id)
    }

    // MARK: - Find in page

    /// Opens the selected tab's find bar. The selected tab is always
    /// displayed, so unlike the QR card this needs no select-first step.
    func showFindBar() {
        guard let tab = selectedTab else {
            SystemBeep.play()
            return
        }
        pane(for: tab).showFindBar()
    }

    /// Steps the selected tab's match forward, opening its bar first.
    func findNext() {
        guard let tab = selectedTab else {
            SystemBeep.play()
            return
        }
        pane(for: tab).findStep(1)
    }

    /// Steps the selected tab's match backward, opening its bar first.
    func findPrevious() {
        guard let tab = selectedTab else {
            SystemBeep.play()
            return
        }
        pane(for: tab).findStep(-1)
    }

    // MARK: - Reload

    /// Reloads the selected tab, or refreshes its file listing when that is
    /// what is open. A loading page stops instead, matching the toolbar
    /// button's toggle.
    func reloadPage() {
        guard let tab = selectedTab else {
            SystemBeep.play()
            return
        }
        let pane = pane(for: tab)
        if pane.refreshFileBrowser() {
            return
        }
        if pane.refreshDownloads() {
            return
        }
        if tab.tabController.isLoading {
            tab.tabController.stopLoading()
        } else {
            tab.tabController.reload()
        }
    }

    /// Reloads ignoring caches. A file listing has no cache to bypass, so it
    /// refreshes like a plain reload.
    func reloadPageFromOrigin() {
        guard let tab = selectedTab else {
            SystemBeep.play()
            return
        }
        let pane = pane(for: tab)
        if pane.refreshFileBrowser() {
            return
        }
        tab.tabController.reloadFromOrigin()
    }

    /// Opens the settings modal on this window.
    ///
    /// The single entry point behind all three of them — the toolbar gear, the
    /// page menu's Settings item, and the app menu's Settings command — so the
    /// modal is always owned by the window it is opened over.
    func presentSettings(section: SettingsSection = .general) {
        contentController.presentSettings(section: section)
    }

    /// Opens the per-site content-blocker card for the selected tab.
    ///
    /// Behind the toolbar shield button. Nothing to show without a selected
    /// tab, and the card itself handles pages without an exceptable host.
    func presentAdBlockPopup() {
        guard let tab = selectedTab else { return }
        contentController.presentAdBlockPopup(for: tab)
    }

    /// Opens the reader for the selected tab's advertised feeds.
    ///
    /// Behind the toolbar feed button, which is only visible when the page
    /// advertised at least one document. The reader itself decides whether the
    /// tab may subscribe or only browse what is already saved.
    func presentFeedReader(candidates: [FeedCandidate]) {
        guard let tab = selectedTab, !candidates.isEmpty else {
            SystemBeep.play()
            return
        }
        contentController.presentFeedReader(candidates: candidates, tab: tab)
    }

    /// Opens one reader article, either in place or in a new tab.
    ///
    /// The reader always closes first: opening in place would otherwise leave
    /// the card covering the page it just navigated to.
    func openFeedArticle(_ url: URL, inNewTab: Bool) {
        contentController.dismissFeedReader()
        if inNewTab {
            BrowserCoordinator.shared.newTab(url: url, in: self, focusesAddressBar: false)
        } else {
            selectedTab?.navigate(to: url)
        }
    }

    /// Closes every open QR card, used when the layout or selection changes
    /// out from under one.
    func dismissQRCode() {
        for pane in paneCache.values {
            pane.dismissQRCode()
        }
    }

    /// Rebuilds the page area for the current layout, reusing cached
    /// panes so web views are reparented instead of recreated.
    private func rebuildContent() {
        dismissQRCode()
        dismissFileBrowser()
        dismissDownloads()
        let visible = displayedTabs
        // Wakes slept tabs: a tab whose view was discarded rebuilds it here,
        // loading its address anew. Hidden tabs stay unrealized.
        for tab in visible {
            pane(for: tab).hostPage()
        }
        if visible.count <= 1 {
            splitController = nil
            singlePane = nil
            if let tab = visible.first {
                pane(for: tab).splitPosition = .single
                contentController.showChild(pane(for: tab))
            }
            activeModel.showsIndicator = false
            return
        }
        rebuildSplitView()
    }

    private func rebuildSplitView() {
        guard case .split(let leading, let trailing, let ratio) = layout else {
            rebuildContent()
            return
        }
        let visible = displayedTabs
        guard visible.count == 2 else {
            rebuildContent()
            return
        }

        let split: BrowserSplitViewController
        if let existing = splitController {
            split = existing
        } else {
            split = BrowserSplitViewController()
            splitController = split
            singlePane = nil
        }
        // Re-armed on every rebuild, not just creation: replacing a pane
        // changes the pair while the controller persists, and a closure
        // capturing the original pair would write the displaced tab back
        // into the layout on the next divider tick.
        split.onRatioChange = { [weak self] newRatio in
            guard let self, case .split = self.layout else { return }
            let clamped = min(
                max(newRatio, BrowserSplitViewController.minimumRatio),
                BrowserSplitViewController.maximumRatio
            )
            self.layout = .split(
                leadingTabID: leading,
                trailingTabID: trailing,
                ratio: clamped
            )
            // The sticky copy follows the view, so a hidden-then-restored
            // split comes back at the dragged ratio.
            self.splitGroup = self.layout
            self.sessionDidChange()
        }

        let wanted = visible.map { pane(for: $0) }
        for pane in split.paneControllers where !wanted.contains(where: { $0 === pane }) {
            split.removePane(pane)
        }
        for pane in wanted where !split.paneControllers.contains(where: { $0 === pane }) {
            split.addPane(pane)
        }
        // `wanted` follows `visible`, which is leading-then-trailing, so the
        // panes read as one grouped surface instead of two cards.
        wanted[0].splitPosition = .leading
        wanted[1].splitPosition = .trailing
        contentController.showChild(split)
        activeModel.showsIndicator = true
        // Ratio can only be applied once the view has a width.
        split.view.layoutSubtreeIfNeeded()
        split.setRatio(ratio)
    }
}

extension BrowserWindowController.ContentLayout {
    /// The tabs a layout displays, in order.
    ///
    /// Mirrors `SessionSnapshot.WindowSnapshot.Layout.tabIDs`, which is what a
    /// session restore reads the layout back through.
    var tabIDs: [UUID] {
        switch self {
        case .single(let id):
            return [id]
        case .split(let leading, let trailing, _):
            return [leading, trailing]
        }
    }
}

// MARK: - TabBarViewDelegate

extension BrowserWindowController: TabBarViewDelegate {
    func tabBar(_ tabBar: TabBarView, didSelect tab: BrowserTab) {
        selectTab(tab)
    }

    func tabBar(_ tabBar: TabBarView, didClose tab: BrowserTab) {
        closeTab(tab)
    }

    func tabBar(_ tabBar: TabBarView, menuFor tab: BrowserTab) -> NSMenu? {
        BrowserTabContextMenu.menu(for: tab, controller: self)
    }

    func tabBar(_ tabBar: TabBarView, didDropTab tab: BrowserTab, at index: Int) {
        BrowserCoordinator.shared.moveTab(tab, to: index, in: self)
    }

    func tabBar(_ tabBar: TabBarView, didToggleMuteFor tab: BrowserTab) {
        tab.toggleMute()
    }

    /// The merged group cell was pressed: show the split, focused on the
    /// already-active pane when it is a member, so the address bar shows
    /// the page the user is looking at.
    func tabBarDidSelectGroup(_ tabBar: TabBarView) {
        guard let group = validSplitGroup(),
              case .split(let leading, let trailing, _) = group
        else { return }
        let active = [leading, trailing].first { $0 == activeModel.activeTabID }
            ?? leading
        if let tab = tabs.first(where: { $0.id == active }) {
            selectTab(tab)
        }
    }

    func tabBarDidCloseGroup(_ tabBar: TabBarView) {
        closeGroup()
    }

    func tabBarGroupMenu(_ tabBar: TabBarView) -> NSMenu? {
        BrowserTabGroupMenu.menu(controller: self)
    }

    /// Moves the sticky group into a fresh window, keeping it grouped.
    func moveGroupToNewWindow() {
        guard let group = validSplitGroup(),
              case .split(let leading, let trailing, _) = group,
              let first = tabs.first(where: { $0.id == leading }),
              let second = tabs.first(where: { $0.id == trailing })
        else {
            SystemBeep.play()
            return
        }
        BrowserCoordinator.shared.detachGroup([first, second], from: self)
    }
}
