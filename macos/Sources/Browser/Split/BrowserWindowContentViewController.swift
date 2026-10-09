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

/// Window content: the toolbar strip and custom tab bar at the top, and the
/// page area below, which shows either one tab's page or a split view of two
/// tabs. Navigation and the address field live in `BrowserToolbarView`.
final class BrowserWindowContentViewController: NSViewController {
    static let tabBarHeight: CGFloat = 36

    private var onNewTab: (() -> Void)?
    private var dropPreview: NSView?
    private var toolbarView: NSView?
    private let progressBar = NSView()
    private var noiseOverlay: NoiseOverlayView?
    private var backgroundMedia: BackgroundMediaView?
    private var backgroundSubscription: AnyCancellable?
    private var settingsSubscription: AnyCancellable?
    private var noiseSettingsPresenter: NoiseOverlaySettingsPresenter?
    private var settingsPresenter: SettingsModalPresenter?
    private var adBlockPresenter: AdBlockPopupPresenter?
    private var feedReaderPresenter: FeedReaderPresenter?
    /// Internal for layout tests, which drive visibility through the
    /// controller's testing seams.
    var crawlBarController: CrawlBarController?
    private var shield: ModalEventShieldView?

    /// Set by the window controller. `onDropZoneChanged` receives nil
    /// when the pointer leaves the page area so the preview can be
    /// dismissed.
    var onDropZoneChanged: ((SplitDropZone?) -> Void)?
    var onTabDropped: ((BrowserTab, SplitDropZone) -> Void)?
    /// A whole split group dropped on the page area: both tabs move over
    /// and re-form there. The zone is advisory only — two tabs cannot fill
    /// one pane, so the pair lands as its own split.
    var onTabGroupDropped: (([BrowserTab]) -> Void)?
    /// Reports the shield going in (`true`) or coming out (`false`).
    ///
    /// The window controller uses it to take its pages out of mouse interaction for
    /// the duration. The shield is what intercepts presses; this is what stops the
    /// pages noticing the pointer at all, and both are needed for the page to be
    /// genuinely inert while a card is up.
    var onShieldChanged: ((Bool) -> Void)?
    /// Opens a feed article from the reader. `true` means a new tab; false
    /// means the selected tab.
    var onOpenFeedArticle: ((URL, Bool) -> Void)?

    let tabBar = TabBarContainerView(newTabAction: {})
    /// Constraints pinning each child to the page area, one set per child.
    ///
    /// Per child rather than one set for whichever is current, because children are
    /// kept in the hierarchy and parked off-screen instead of removed. See
    /// `showChild`.
    ///
    /// They must be deactivated when the child is replaced: constraints retain the
    /// views they pin, so abandoned ones keep discarded pages (and their processes)
    /// alive.
    private var childConstraints: [ObjectIdentifier: [NSLayoutConstraint]] = [:]
    /// The bottom-edge constraint of each set above, tracked separately so the
    /// crawl bar can re-pin it without matching heuristics.
    private var childBottomConstraints: [ObjectIdentifier: NSLayoutConstraint] = [:]

    init() {
        super.init(nibName: nil, bundle: nil)
        tabBar.newTabAction = { [weak self] in self?.onNewTab?() }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setNewTabAction(_ action: @escaping () -> Void) {
        onNewTab = action
    }

    /// Installs the toolbar strip across the top of the window and moves the tab
    /// bar directly beneath it.
    ///
    /// The tab bar used to hang off `view.safeAreaLayoutGuide.topAnchor`, whose 52pt
    /// inset came from the native `NSToolbar`. With that gone the safe area is
    /// empty and the bar would jump to the top of the window, so the inset is now
    /// pinned explicitly as the strip's height. Same 52 points, same place.
    ///
    /// Added below everything else so the background media, the tab bar and the
    /// progress bar all keep drawing over it where they overlap.
    func installToolbar(_ toolbar: NSView) {
        guard isViewLoaded, toolbarView == nil else { return }
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(toolbar, positioned: .below, relativeTo: tabBar)
        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: view.topAnchor),
            toolbar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            toolbar.heightAnchor.constraint(equalToConstant: BrowserToolbarView.height),

            tabBar.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
        ])
        toolbarView = toolbar
    }

    /// Opens the grain settings card, or closes it when already open.
    /// Driven by the toolbar button next to the page menu.
    ///
    /// A modal shield goes in above the page for the duration: Mijick's
    /// own tap-outside layer is `.clear`, so without it a click over the
    /// page would reach the `WKWebView` underneath. The shield swallows
    /// the input and dismisses the card; the card itself stays above it
    /// and fully interactive. The toolbar strip is deliberately left
    /// above the shield, so navigation and window controls keep working.
    func toggleNoiseSettings() {
        guard isViewLoaded else { return }
        if noiseSettingsPresenter != nil {
            dismissNoiseSettings()
            return
        }
        // Shield first: the popup host is added afterwards, so it lands
        // on top and stays interactive while everything under the shield
        // (page, tab bar, drop preview) goes inert. It also catches
        // clicks in the areas Mijick's own backdrop does not cover.
        claimShield(id: "noise", dismissOnPress: true) { [weak self] in
            Task { @MainActor in
                self?.dismissNoiseSettings()
            }
        }
        let presenter = NoiseOverlaySettingsPresenter(container: view) { [weak self] in
            // Covers every dismissal route: Save, Escape, the toolbar
            // button, Mijick's tap-outside, and the shield.
            self?.clearNoiseSettings()
        }
        presenter.present()
        noiseSettingsPresenter = presenter
        // Both were just added, so they sit above the grain; the grain
        // still never consumes input.
        noiseOverlay?.moveToFront()
    }

    /// Opens the settings modal over this window.
    ///
    /// Same shape as the grain card: shield first so everything underneath goes
    /// inert, then the popup host on top of it, and one teardown path for every
    /// way out. Cards share the shield by claim, so settings can sit over a
    /// pane popup (or vice versa) without either losing its cover.
    func presentSettings(section: SettingsSection = .general) {
        guard isViewLoaded else { return }
        if settingsPresenter != nil {
            dismissSettings()
            return
        }
        dismissNoiseSettings()
        // Click semantics, not press semantics: a drag that starts on the
        // card is owned by the card's gesture, and its release can fall
        // through the host and the deafened page down to this shield. Firing
        // on that lone release would dismiss the card the user was dragging
        // inside of, so only a press and release both on the shield count.
        claimShield(id: "settings", dismissOnPress: false) { [weak self] in
            Task { @MainActor in
                self?.dismissSettings()
            }
        }
        let presenter = SettingsModalPresenter(container: view) { [weak self] in
            self?.clearSettings()
        }
        presenter.present(section: section)
        settingsPresenter = presenter
        noiseOverlay?.moveToFront()
    }

    func dismissSettings() {
        settingsPresenter?.dismiss()
        clearSettings()
    }

    private func clearSettings() {
        settingsPresenter = nil
        releaseShield(id: "settings")
        noiseOverlay?.moveToFront()
    }

    /// Opens the reader for the selected tab's advertised feeds, or closes it
    /// when already open.
    ///
    /// Shielded like every other card: the backdrop stays transparent, but a
    /// click over the page must reach the shield (dismissing the card), never
    /// the `WKWebView` underneath. Subscriptions and downloads still require
    /// a regular tab; private tabs get a read-only view of the
    /// already-persisted library plus the current page's transient candidates.
    func presentFeedReader(candidates: [FeedCandidate], tab: BrowserTab) {
        guard isViewLoaded else { return }
        if feedReaderPresenter != nil {
            dismissFeedReader()
            // Fall through and reopen: the candidates belong to this tab and
            // this press, not to whatever the previous card was showing.
        }
        let presenter = FeedReaderPresenter(container: view) { [weak self] in
            self?.feedReaderPresenter = nil
            self?.releaseShield(id: "feed-reader")
        }
        feedReaderPresenter = presenter
        // Shield first: the popup host is added afterwards, so it lands above
        // the shield and stays interactive while the page underneath goes
        // inert. A host under the shield still shows, but every click on the
        // card lands on the shield instead.
        claimShield(id: "feed-reader", dismissOnPress: true) { [weak self] in
            self?.dismissFeedReader()
        }
        presenter.present(
            candidates: candidates,
            pageURL: tab.displayURL,
            siteName: tab.tabController.title,
            webView: tab.webView,
            allowsPersistence: tab.privacyMode == .regular,
            onOpenArticle: { [weak self] url, newTab in
                self?.onOpenFeedArticle?(url, newTab)
            }
        )
        if !presenter.isPresented {
            // The card never opened (a detached window): don't hold cover
            // for it.
            feedReaderPresenter = nil
            releaseShield(id: "feed-reader")
        }
    }

    func dismissFeedReader() {
        feedReaderPresenter?.dismiss()
        feedReaderPresenter = nil
    }

    /// Opens the per-site content-blocker card for `tab`, or closes it when
    /// already open.
    ///
    /// Shielded like every other card: a click over the page must reach the
    /// shield (dismissing the card), never the `WKWebView` underneath. The
    /// host is the tab's http(s) host, or nil for pages without one, where
    /// the card shows itself as having nothing to except.
    func presentAdBlockPopup(for tab: BrowserTab) {
        guard isViewLoaded else { return }
        if adBlockPresenter != nil {
            dismissAdBlockPopup()
            return
        }
        let host: String? = {
            // `displayURL` already answers with the live page when there is a
            // view and the tab's own address when there is not, so there is no
            // second fallback to chain on here.
            let url = tab.displayURL
            guard let scheme = url.scheme?.lowercased(),
                  ["http", "https"].contains(scheme)
            else {
                return nil
            }
            return url.host?.lowercased()
        }()
        let presenter = AdBlockPopupPresenter(container: view) { [weak self] in
            self?.adBlockPresenter = nil
            self?.releaseShield(id: "adblock")
        } onManage: { [weak self] in
            self?.presentSettings(section: .contentBlocker)
        }
        adBlockPresenter = presenter
        // Shield first, for the same reason as the reader: the host lands
        // above it and stays interactive.
        claimShield(id: "adblock", dismissOnPress: true) { [weak self] in
            self?.dismissAdBlockPopup()
        }
        presenter.present(host: host)
        if !presenter.isPresented {
            // The card never opened (a detached window): don't hold cover
            // for it.
            adBlockPresenter = nil
            releaseShield(id: "adblock")
        }
    }

    func dismissAdBlockPopup() {
        adBlockPresenter?.dismiss()
        adBlockPresenter = nil
    }

    private func dismissNoiseSettings() {
        // The presenter's teardown calls back into `clearNoiseSettings`.
        noiseSettingsPresenter?.dismiss()
        clearNoiseSettings()
    }

    private func clearNoiseSettings() {
        noiseSettingsPresenter = nil
        releaseShield(id: "noise")
        noiseOverlay?.moveToFront()
    }

    /// Covers the page so nothing under a card can be clicked, and tells the
    /// window that its pages have to go inert with it.
    ///
    /// Both halves matter and neither is sufficient alone: the shield is a plain
    /// view that consumes presses, but a `WKWebView` underneath keeps tracking the
    /// pointer for hover whether or not anything is intercepting clicks.
    ///
    /// Claims stack frontmost-last: several cards can be up at once (a file
    /// popup in one split pane, downloads in another), and the single shield
    /// view serves them all. A click on the shield dismisses the frontmost
    /// card; the view and the inert callback only toggle on the empty
    /// transition, so coexisting cards never steal each other's cover.
    private struct ShieldClaim {
        let id: String
        var dismissOnPress: Bool
        var onDismiss: () -> Void
    }

    private var shieldClaims: [ShieldClaim] = []

    /// Claims the modal shield for a card. Re-claiming moves to the front.
    /// The `onDismiss` runs when a shield click reaches this claim while it
    /// is frontmost — it must dismiss the card, which releases the claim.
    /// Below the toolbar, so navigation and the address bar keep working while
    /// a card is up.
    func claimShield(id: String, dismissOnPress: Bool, onDismiss: @escaping () -> Void) {
        shieldClaims.removeAll { $0.id == id }
        shieldClaims.append(ShieldClaim(id: id, dismissOnPress: dismissOnPress, onDismiss: onDismiss))
        if shield == nil {
            let installed = ModalEventShieldView.install(in: view, below: toolbarView) { [weak self] in
                self?.dismissTopShieldClaim()
            }
            shield = installed
            onShieldChanged?(true)
        }
        refreshShieldTop()
    }

    /// Releases a card's claim. Unknown ids are no-ops, so every teardown
    /// path can call this without knowing whether it is the first one out.
    func releaseShield(id: String) {
        guard shieldClaims.contains(where: { $0.id == id }) else { return }
        shieldClaims.removeAll { $0.id == id }
        if shieldClaims.isEmpty {
            removeShieldView()
        } else {
            refreshShieldTop()
        }
    }

    /// The frontmost claim owns the press behavior: a card that dismisses on
    /// a bare press must not inherit another card's press-and-release rule.
    private func refreshShieldTop() {
        shield?.dismissOnPress = shieldClaims.last?.dismissOnPress ?? true
    }

    private func dismissTopShieldClaim() {
        guard let top = shieldClaims.popLast() else { return }
        if shieldClaims.isEmpty {
            removeShieldView()
        } else {
            refreshShieldTop()
        }
        top.onDismiss()
    }

    /// Takes the shield back out and hands the mouse back to the pages.
    /// Guarded so the teardown paths can all call it without having to know
    /// whether they are the first one out.
    private func removeShieldView() {
        guard shield != nil else { return }
        shield?.removeFromSuperview()
        shield = nil
        onShieldChanged?(false)
    }

    /// 2pt loading indicator overlaid on the top edge of the page. It
    /// stays in layout while idle so the page does not jump when a load
    /// starts.
    func updateProgress(_ progress: Double, isLoading: Bool) {
        let clamped = min(max(progress, 0.02), 1)
        progressBar.isHidden = false
        progressBar.layer?.backgroundColor = isLoading
            ? NSColor.controlAccentColor.cgColor
            : NSColor.clear.cgColor
        progressBar.frame.size.width = view.bounds.width * clamped
        progressBar.alphaValue = isLoading ? 1 : 0
    }

    /// Overlay shown above the page area while a tab is dragged over
    /// the window. It never takes part in layout constraints of the
    /// child controller and always stays on top of it.
    ///
    /// The flag is set here because the preview has to sit above the pane, and the
    /// only place the pane's position in the subview order is settled is
    /// `showChild`.
    func installDropPreview(_ preview: NSView) {
        guard dropPreview == nil else { return }
        dropPreview = preview
        preview.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(preview)

        NSLayoutConstraint.activate([
            preview.topAnchor.constraint(equalTo: tabBar.bottomAnchor),
            preview.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            preview.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            preview.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    /// Page area in the content view's coordinates, directly below the
    /// tab bar with no gap. The progress indicator overlays its top
    /// edge, so it takes no part in this rect.
    ///
    /// Measured from the tab bar's own frame rather than from the tab bar's
    /// height, because the bar is inset by the window's safe area now that the
    /// window is full-size.
    ///
    /// Shrinks from the bottom while the headline crawl is visible, so drop
    /// zones never claim the strip the ticker occupies.
    var pageAreaRect: NSRect {
        let top = tabBar.frame.maxY
        let bottom = crawlBarController?.occupiedHeight ?? 0
        return NSRect(
            x: 0,
            y: top,
            width: view.bounds.width,
            height: max(0, view.bounds.height - top - bottom)
        )
    }

    private static let progressHeight: CGFloat = 2

    override func loadView() {
        view = NSView()
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        // The content view itself is the drop target for the page area.
        // AppKit walks up from the WKWebView, which is not registered,
        // so drops over the page land here without needing an overlay
        // for hit-testing. The tab bar is registered too and sits
        // deeper, so drops on the bar never reach this.
        view.registerForDraggedTypes([TabDragPayload.type])

        progressBar.wantsLayer = true
        progressBar.layer?.backgroundColor = NSColor.clear.cgColor
        progressBar.alphaValue = 0
        progressBar.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(tabBar)
        view.addSubview(progressBar)

        NSLayoutConstraint.activate([
            // The top edge comes from `installToolbar`, which pins this to the
            // bottom of the toolbar strip. It used to come from the view's safe
            // area, whose inset the native toolbar supplied.
            tabBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tabBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tabBar.heightAnchor.constraint(equalToConstant: Self.tabBarHeight),

            progressBar.topAnchor.constraint(equalTo: tabBar.bottomAnchor),
            progressBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            progressBar.heightAnchor.constraint(equalToConstant: Self.progressHeight),
            progressBar.widthAnchor.constraint(
                lessThanOrEqualTo: view.widthAnchor
            ),
        ])

        // Subtle grain above the tab bar and page area. It is a sibling
        // of the content (never an ancestor), so scrolling does not move
        // it, and constraints keep it covering the window through
        // resizes. It never intercepts events; see `NoiseOverlayView`.
        // Settings are shared app-wide, so every window follows the
        // popup's changes live.
        let overlay = NoiseOverlayView.install(in: view)
        noiseOverlay = overlay
        settingsSubscription = NoiseOverlaySettings.shared.$configuration
            .receive(on: DispatchQueue.main)
            .sink { [weak overlay] configuration in
                overlay?.configuration = configuration
            }
        overlay.configuration = NoiseOverlaySettings.shared.configuration

        // The window background, at the very back. Installed before the grain so
        // the grain lands in front of it, and pinned to the bounds rather than
        // the safe area so it runs up behind the transparent toolbar.
        let background = BackgroundMediaView.install(in: view)
        backgroundMedia = background
        // Read straight off the settings store rather than through a mirror: the
        // stored shape is the in-memory shape here, so a second observable would
        // be pure overhead. `appearance` is already a published section, and
        // `changedKeys` already reports it.
        backgroundSubscription = SettingsStore.shared.$settings
            .receive(on: DispatchQueue.main)
            .sink { [weak background] settings in
                background?.configuration = settings.appearance.background
            }
        background.configuration = SettingsStore.shared.settings.appearance.background
        installCrawlBar()
    }

    /// Where a parked child's view is moved to, horizontally.
    ///
    /// Far enough that it cannot be seen through the window even if the window is
    /// partly transparent, and to the *left* rather than the right so a parked
    /// page cannot be reached by scrolling the content view either.
    private static let parkingOrigin = NSPoint(x: -10_000, y: 0)

    /// Shows one child and parks the rest, without taking anything out of the
    /// window.
    ///
    /// ## Why parking rather than hiding
    ///
    /// This used to remove every child and add the new one, then later to set
    /// `isHidden` on the ones that were not current. Both cost real time on the way
    /// back, and hiding costs it twice.
    ///
    /// Removing a child takes its `WKWebView` out of the window, which makes WebKit
    /// tear down the layer tree and rebuild it on the way in, so the page arrives as
    /// a blank frame first.
    ///
    /// Hiding is worse than that, and the difference is what made switching between
    /// a video tab and anything else feel broken. A hidden view is not merely
    /// unpainted: WebKit reports the page as hidden, so the page sees
    /// `document.hidden = true` and reacts the way every site reacts to a
    /// background tab. A YouTube player pauses. Returning to the tab then costs a
    /// full re-raster *and* a resume of the stream, which is where a one-to-two
    /// second wait on a player page came from.
    ///
    /// Parking avoids both. The view stays in the window, so its layers are kept,
    /// and it stays visible to the page, so media keeps playing behind the current
    /// tab and no resume is needed. Off-screen is also the honest fallback for
    /// anything the page has not accounted for: a page that still thinks it is
    /// foreground behaves the same whether it is behind another tab or beside it,
    /// which is exactly what a browser tab switch already does.
    ///
    /// The tradeoff, stated because it is a real one: media in a parked tab keeps
    /// playing with audio. That is what the switch is being optimised for, and
    /// pausing instead would put the resume cost straight back. A tab that wants to
    /// go quiet has its own mute control.
    ///
    /// The model's part of a switch was never the problem: measured in the running
    /// app, `selectTab` costs 1 to 3ms for pages that already exist and under 6ms
    /// for one whose web view has not been built yet.
    func showChild(_ controller: NSViewController) {
        releaseOrphanedChildren()
        let key = ObjectIdentifier(controller)
        var hierarchyChanged = false

        if controller.view.superview !== view {
            // Arriving from somewhere else, which in practice means a pane coming
            // back out of a split. Hand it over and pin it to the page area again.
            addChild(controller)
            controller.view.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(controller.view)
            forgetConstraints(for: controller)
            let bottom = pageBottomConstraint(for: controller.view)
            childBottomConstraints[key] = bottom
            childConstraints[key] = [
                // Anchored to the tab bar rather than to the view's top plus the
                // bar's height, because the bar no longer sits at the top of the
                // view now that the window is full-size.
                controller.view.topAnchor.constraint(equalTo: tabBar.bottomAnchor),
                controller.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                controller.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                bottom,
            ]
            hierarchyChanged = true
        }

        for child in children {
            let isCurrent = child === controller
            let constraints = childConstraints[ObjectIdentifier(child)] ?? []
            if isCurrent {
                unpin(constraints, of: child.view)
                NSLayoutConstraint.activate(constraints)
            } else {
                NSLayoutConstraint.deactivate(constraints)
                pin(constraints, to: child.view)
            }
        }

        // These three only matter when a pane has just been added above them,
        // which is the add above and nothing else: the drop preview is installed
        // once for the window's life and every later switch reuses panes that are
        // already parented. Running them on every switch reordered siblings above
        // the web view each time, which dirties layout for the whole content
        // hierarchy for no visible gain.
        if hierarchyChanged {
            view.addSubview(progressBar)
            if let dropPreview {
                view.subviews = view.subviews.filter { $0 !== dropPreview } + [dropPreview]
            }
            // The page may have arrived above the crawl bar; the grain keeps
            // its front-most seat behind nothing.
            crawlBarController?.bringToFront()
            noiseOverlay?.moveToFront()
        }
    }

    // MARK: - Headline crawl

    /// Installs the window-wide headline crawl bar along the bottom edge.
    ///
    /// One bar per window rather than one per pane: in a split both panes
    /// shrink above the same strip, and each pane's own find bar keeps its
    /// `bar.bottom == pane.bottom - 6` pin, which now resolves just above the
    /// ticker with no pane-side changes. Cmd+F therefore always opens above
    /// the crawl bar.
    private func installCrawlBar() {
        let controller = CrawlBarController(container: view) { [weak self] url in
            // Ticker taps always open a new tab: the strip is window-wide
            // ambient content, never the current page, so replacing the page
            // underneath would lose where the user was reading.
            self?.onOpenFeedArticle?(url, true)
        }
        controller.onVisibilityChanged = { [weak self] in
            self?.crawlVisibilityChanged()
        }
        crawlBarController = controller
        crawlVisibilityChanged()
    }

    /// Re-pins the page area and restores sibling order after the crawl bar
    /// enters, leaves, or is first installed.
    private func crawlVisibilityChanged() {
        updateCrawlBottomPins()
        crawlBarController?.bringToFront()
        noiseOverlay?.moveToFront()
    }

    /// The page area's bottom edge: the crawl bar's top while it is visible,
    /// the window bottom otherwise.
    private func pageBottomConstraint(for childView: NSView) -> NSLayoutConstraint {
        if let bar = crawlBarController?.barView, bar.superview === view {
            return childView.bottomAnchor.constraint(equalTo: bar.topAnchor)
        }
        return childView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
    }

    /// Re-pins every child's bottom edge after the crawl bar enters or leaves.
    ///
    /// Only the tracked bottom constraint of each set is replaced; top and
    /// sides are untouched. Parked children (manual frames, off-screen) keep
    /// an inactive replacement; the current child takes its replacement live
    /// in the same pass. A retired constraint is removed from the view when
    /// it is actually installed there; one that was never installed is owed
    /// nothing and is skipped.
    ///
    /// Activation deliberately does NOT consult `old.isActive`: removing the
    /// bar drops every constraint referencing it before this runs, so a
    /// retired pin routinely reads inactive even when it laid out the page a
    /// moment ago. Trusting that flag orphaned the page with no bottom pin
    /// at all — a zero-height web view until the next tab switch re-pinned
    /// it. Parked-ness comes from the view (`translatesAutoresizingMaskInto
    /// Constraints`), which hierarchy changes cannot forge.
    private func updateCrawlBottomPins() {
        for child in children {
            let key = ObjectIdentifier(child)
            guard var constraints = childConstraints[key],
                  let old = childBottomConstraints[key],
                  let index = constraints.firstIndex(of: old)
            else { continue }
            let replacement = pageBottomConstraint(for: child.view)
            let parked = child.view.translatesAutoresizingMaskIntoConstraints
            old.isActive = false
            if view.constraints.contains(old) {
                view.removeConstraint(old)
            }
            if !parked {
                replacement.isActive = true
            }
            constraints[index] = replacement
            childConstraints[key] = constraints
            childBottomConstraints[key] = replacement
        }
    }

    /// Takes a parked view out of Auto Layout's hands and moves it out of sight.
    ///
    /// Both halves matter. Auto Layout has to let go, or it will put the view back
    /// at its pinned position on the next pass; and the frame has to be captured
    /// at park time, because a parked view takes no part in layout and so never
    /// hears about a resize.
    private func pin(_ constraints: [NSLayoutConstraint], to view: NSView) {
        guard !constraints.isEmpty else { return }
        let size = view.bounds.size
        view.translatesAutoresizingMaskIntoConstraints = true
        view.frame = NSRect(
            origin: Self.parkingOrigin,
            size: size.width > 0 && size.height > 0 ? size : view.frame.size
        )
    }

    /// Hands a view back to Auto Layout, discarding the parked frame.
    ///
    /// The frame is cleared rather than kept: leaving a stale one behind is how a
    /// view ends up at its old position for one layout pass before its constraints
    /// win, which shows as a flash at the wrong size.
    private func unpin(_ constraints: [NSLayoutConstraint], of view: NSView) {
        guard !constraints.isEmpty else { return }
        view.translatesAutoresizingMaskIntoConstraints = false
        view.frame = .zero
    }

    /// Drops a child for good, for a pane whose tab is gone.
    ///
    /// Children are retained so their pages can stay in the window, which means
    /// closing a tab has to release one explicitly or it would be held for the rest
    /// of the window's life.
    func forgetChild(_ controller: NSViewController) {
        controller.view.removeFromSuperview()
        controller.removeFromParent()
        forgetConstraints(for: controller)
    }

    private func forgetConstraints(for controller: NSViewController) {
        guard let constraints = childConstraints.removeValue(forKey: ObjectIdentifier(controller))
        else { return }
        childBottomConstraints.removeValue(forKey: ObjectIdentifier(controller))
        NSLayoutConstraint.deactivate(constraints)
        // `NSLayoutConstraint.remove()` is not exposed to Swift, and dropping
        // our reference is not enough: a deactivated constraint stays installed on
        // the view and would keep the pane's web view alive.
        view.removeConstraints(constraints)
    }

    /// Releases children that are in no hierarchy at all.
    ///
    /// A pane that a split has let go of has lost its superview without being
    /// forgotten, and would otherwise sit here as a child for the rest of the
    /// window's life.
    private func releaseOrphanedChildren() {
        for child in children where child.view.superview == nil {
            child.removeFromParent()
            forgetConstraints(for: child)
        }
    }
}

// MARK: - NSDraggingDestination

/// A tab dropped on the page area splits the window instead of joining
/// the tab bar. This is the only drop target besides the tab bar, and
/// it answers on behalf of its owning window.
extension BrowserWindowContentViewController: NSDraggingDestination {
    func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        draggingUpdated(sender)
    }

    func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard !TabDragPayload.tabs(from: sender).isEmpty,
              let zone = dropZone(for: sender)
        else {
            return []
        }
        onDropZoneChanged?(zone)
        return .move
    }

    func draggingExited(_ sender: NSDraggingInfo?) {
        onDropZoneChanged?(nil)
    }

    func draggingEnded(_ sender: NSDraggingInfo) {
        onDropZoneChanged?(nil)
    }

    func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        !TabDragPayload.tabs(from: sender).isEmpty && dropZone(for: sender) != nil
    }

    func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        defer { onDropZoneChanged?(nil) }
        let dragged = TabDragPayload.tabs(from: sender)
        guard !dragged.isEmpty,
              dropZone(for: sender) != nil
        else {
            return false
        }
        if dragged.count == 2 {
            onTabGroupDropped?(dragged)
        } else if let tab = dragged.first, let zone = dropZone(for: sender) {
            onTabDropped?(tab, zone)
        } else {
            return false
        }
        return true
    }

    /// Drop zone under the drag, or nil when the pointer is outside the
    /// page area (for example over the toolbar).
    private func dropZone(for info: NSDraggingInfo) -> SplitDropZone? {
        let area = pageAreaRect
        guard area.width > 0, area.height > 0 else { return nil }
        let point = info.draggingLocation
        guard area.contains(point) else { return nil }
        return SplitDropZone.zone(for: point, in: area)
    }
}
