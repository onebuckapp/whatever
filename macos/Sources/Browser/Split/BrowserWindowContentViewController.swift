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
    private var shield: ModalEventShieldView?

    /// Set by the window controller. `onDropZoneChanged` receives nil
    /// when the pointer leaves the page area so the preview can be
    /// dismissed.
    var onDropZoneChanged: ((SplitDropZone?) -> Void)?
    var onTabDropped: ((BrowserTab, SplitDropZone) -> Void)?
    /// Reports the shield going in (`true`) or coming out (`false`).
    ///
    /// The window controller uses it to take its pages out of mouse interaction for
    /// the duration. The shield is what intercepts presses; this is what stops the
    /// pages noticing the pointer at all, and both are needed for the page to be
    /// genuinely inert while a card is up.
    var onShieldChanged: ((Bool) -> Void)?

    let tabBar = TabBarContainerView(newTabAction: {})
    /// Constraints pinning the current child. They must be deactivated
    /// when the child is replaced: constraints retain the views they
    /// pin, so abandoned ones keep discarded pages (and their
    /// processes) alive.
    /// Constraints pinning each child to the page area, one set per child.
    ///
    /// Per child rather than one set for whichever is current, because children are
    /// kept in the hierarchy and hidden instead of removed. See `showChild`.
    private var childConstraints: [ObjectIdentifier: [NSLayoutConstraint]] = [:]

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
        installShield { [weak self] in
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
    /// way out. The two dialogs are mutually exclusive because both claim the
    /// shield.
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
        installShield(dismissOnPress: false) { [weak self] in
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
        removeShield()
        noiseOverlay?.moveToFront()
    }

    private func dismissNoiseSettings() {
        // The presenter's teardown calls back into `clearNoiseSettings`.
        noiseSettingsPresenter?.dismiss()
        clearNoiseSettings()
    }

    private func clearNoiseSettings() {
        noiseSettingsPresenter = nil
        removeShield()
        noiseOverlay?.moveToFront()
    }

    /// Covers the page so nothing under a card can be clicked, and tells the
    /// window that its pages have to go inert with it.
    ///
    /// Both halves matter and neither is sufficient alone: the shield is a plain
    /// view that consumes presses, but a `WKWebView` underneath keeps tracking the
    /// pointer for hover whether or not anything is intercepting clicks.
    private func installShield(onClick: @escaping () -> Void) {
        installShield(dismissOnPress: true, onClick: onClick)
    }

    /// Covers the page so nothing under a card can be clicked, and tells the
    /// window that its pages have to go inert with it.
    ///
    /// Both halves matter and neither is sufficient alone: the shield is a plain
    /// view that consumes presses, but a `WKWebView` underneath keeps tracking the
    /// pointer for hover whether or not anything is intercepting clicks.
    private func installShield(dismissOnPress: Bool, onClick: @escaping () -> Void) {
        shield?.removeFromSuperview()
        // Below the toolbar, so navigation and the address bar keep working while
        // a card is up. The native toolbar used to sit outside the content view
        // entirely and was left interactive by default; now it is in here, so the
        // ordering has to be asked for.
        let installed = ModalEventShieldView.install(in: view, below: toolbarView, onClick: onClick)
        installed.dismissOnPress = dismissOnPress
        shield = installed
        onShieldChanged?(true)
    }

    /// Takes the shield back out and hands the mouse back to the pages. Guarded so
    /// the teardown paths can all call it without having to know whether they are
    /// the first one out.
    private func removeShield() {
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
    var pageAreaRect: NSRect {
        let top = tabBar.frame.maxY
        return NSRect(
            x: 0,
            y: top,
            width: view.bounds.width,
            height: max(0, view.bounds.height - top)
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
    }

    /// Shows one child and hides the rest, without taking anything out of the
    /// window.
    ///
    /// This used to remove every child and add the new one, which is what made a
    /// tab switch feel slow. `WKWebView` tears down its layer tree when its view
    /// leaves the window and has to build and render it again on the way back in,
    /// so the page you just asked for arrived as a blank frame first. A child that
    /// is already parented here is now only unhidden, and WebKit never loses the
    /// window.
    ///
    /// The model's part of a switch was never the problem: measured in the running
    /// app, `selectTab` costs 1 to 3ms for pages that already exist and under 6ms
    /// for one whose web view has not been built yet.
    func showChild(_ controller: NSViewController) {
        releaseOrphanedChildren()
        let key = ObjectIdentifier(controller)

        if controller.view.superview !== view {
            // Arriving from somewhere else, which in practice means a pane coming
            // back out of a split. Hand it over and pin it to the page area again.
            addChild(controller)
            controller.view.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(controller.view)
            forgetConstraints(for: controller)
            childConstraints[key] = [
                // Anchored to the tab bar rather than to the view's top plus the
                // bar's height, because the bar no longer sits at the top of the
                // view now that the window is full-size.
                controller.view.topAnchor.constraint(equalTo: tabBar.bottomAnchor),
                controller.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                controller.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                controller.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            ]
        }

        for child in children {
            let isCurrent = child === controller
            child.view.isHidden = !isCurrent
            let constraints = childConstraints[ObjectIdentifier(child)] ?? []
            if isCurrent {
                NSLayoutConstraint.activate(constraints)
            } else {
                NSLayoutConstraint.deactivate(constraints)
            }
        }

        // No reordering of the children themselves: only one is visible at a time, so
        // their order against each other cannot show. Bringing one to the front
        // would mean taking it out of the window and adding it back, which is the
        // very thing this is here to avoid.
        view.addSubview(progressBar)

        // The child was just added, so it sits above the preview unless
        // it is pushed back. The grain stays above everything.
        if let dropPreview {
            view.subviews = view.subviews.filter { $0 !== dropPreview } + [dropPreview]
        }
        noiseOverlay?.moveToFront()
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
        guard TabDragPayload.tab(from: sender) != nil,
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
        TabDragPayload.tab(from: sender) != nil && dropZone(for: sender) != nil
    }

    func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        defer { onDropZoneChanged?(nil) }
        guard let tab = TabDragPayload.tab(from: sender),
              let zone = dropZone(for: sender)
        else {
            return false
        }
        onTabDropped?(tab, zone)
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
