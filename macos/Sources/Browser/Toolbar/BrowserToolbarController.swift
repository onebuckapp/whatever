import AppKit
import Combine

/// The window's top strip: back / forward / reload on the leading side,
/// the address field in the middle, and content blocker / bookmarks /
/// downloads / settings on the trailing side. It follows the window's
/// active tab, so switching tabs updates the navigation state and the
/// address text.
///
/// Owns the views; `BrowserToolbarView` owns the layout. It was an `NSToolbar`
/// until the strip became hand-rolled, and the button and field code below is
/// unchanged from when it was.
@MainActor
final class BrowserToolbarController: NSObject {
    /// Installed into the window's content view by `BrowserWindowController`.
    let toolbarView: BrowserToolbarView
    private let addressContainer = NSView()
    private let centerStack = NSStackView()
    private let feedButton = BrowserToolbarButton()
    /// The drawn spotlight and the dropdown under it. The old `AddressSearchField`
    /// is gone: see `SpotlightField` for why a stock search field could not do this.
    private let spotlight = SpotlightField()
    private let spotlightController = SpotlightController()
    private let settingsButton = BrowserToolbarButton()
    private let downloadsButton = BrowserToolbarButton()
    private let bookmarksButton = BrowserToolbarButton()
    private let adblockButton = BrowserToolbarButton()
    private let backButton = BrowserToolbarButton()
    private let forwardButton = BrowserToolbarButton()
    private let reloadButton = BrowserToolbarButton()

    private weak var controller: BrowserWindowController?
    private var cancellables = Set<AnyCancellable>()
    private var tab: BrowserTab?
    /// Reported by `SpotlightField`, which has no `isEditing` of its own to ask
    /// unlike the `NSTextField` it replaced. Set while editing so `syncControls`
    /// does not overwrite what is being typed.
    private var isEditingAddress = false

    var onAddressSubmitted: ((URL) -> Void)?
    /// Opens the settings modal.
    var onSettings: (() -> Void)?
    /// Opens the settings modal on the Downloads section.
    var onDownloads: (() -> Void)?
    /// Opens the settings modal on the Bookmarks section.
    var onBookmarks: (() -> Void)?
    /// Opens the per-site content-blocker card for the current tab.
    var onAdBlock: (() -> Void)?
    /// Offers the selected tab's advertised feeds. Empty when hidden.
    var onFeed: (([FeedCandidate]) -> Void)?

    init(controller: BrowserWindowController) {
        self.controller = controller
        // Built before `super.init()` because the strip is a `let`. The buttons and
        // the field are already initialized by their own declarations, so the strip
        // can be handed them here; their targets, images and delegate need `self`
        // and are set just after.
        let toolbar = BrowserToolbarView(
            leading: [backButton, forwardButton, reloadButton],
            center: centerStack,
            trailing: [adblockButton, bookmarksButton, downloadsButton, settingsButton]
        )
        self.toolbarView = toolbar
        super.init()

        configureButtons()
        configureCenterStack()
        configureAddressField()
        configureSpotlight()
        // Wired here rather than in the spotlight's own init because it needs `self`.
        spotlight.onEditingChanged = { [weak self] isEditing in
            self?.isEditingAddress = isEditing
        }
    }

    /// The spotlight's own input, so `syncControls` can reach it without going
    /// through the drawn chrome.
    private var addressField: NSTextField { spotlight.textField }

    /// Hooked up after `super.init` because it needs `onAddressSubmitted`.
    private func configureSpotlight() {
        // A chosen row navigates the current tab, exactly as submitting the field
        // would: the dropdown completes the address, it does not bypass it.
        spotlightController.onNavigate = { [weak self] url in
            self?.onAddressSubmitted?(url)
        }
    }

    // MARK: - Focus

    /// Puts the caret in the address field with its contents selected.
    ///
    /// The selection and the retry both live in `SpotlightField`: it defers a
    /// `selectAll` by one runloop turn so the focusing click's caret placement does
    /// not override it, and it retries once because `makeFirstResponder` fails
    /// outright in a window that was just ordered front rather than deferring
    /// itself.
    @discardableResult
    func focusAddressField() -> Bool {
        // The selection and the one-runloop retry both live in the spotlight now,
        // which is also where the field's window comes from.
        spotlight.focusInput()
    }

    /// Whether the dropdown is showing, so the keyboard handlers know whether the
    /// arrow keys belong to it or to the caret.
    func isSpotlightOpen() -> Bool {
        spotlightController.isOpen
    }

    /// Called once the window's content view exists. Separate from the constructor
    /// because the toolbar is built before that view is loaded.
    func attachSpotlightDropdown(to container: NSView) {
        spotlightController.attach(field: spotlight, container: container)
    }

    // MARK: - Tab binding

    func setTab(_ tab: BrowserTab?) {
        guard self.tab?.id != tab?.id else { return }
        self.tab = tab
        cancellables.removeAll()
        isEditingAddress = false

        guard let tab else {
            syncControls()
            return
        }

        tab.tabController.setFeedsEnabled(SettingsStore.shared.settings.feeds.isEnabled)
        SettingsStore.shared.$settings
            .map(\.feeds.isEnabled)
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isEnabled in
                self?.tab?.tabController.setFeedsEnabled(isEnabled)
                self?.syncFeedButton()
            }
            .store(in: &cancellables)
        tab.tabController.$canGoBack
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.syncControls() }
            .store(in: &cancellables)
        tab.tabController.$canGoForward
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.syncControls() }
            .store(in: &cancellables)
        tab.tabController.$isLoading
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.syncControls() }
            .store(in: &cancellables)
        tab.tabController.$url
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.syncControls() }
            .store(in: &cancellables)
        tab.tabController.$title
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.syncControls() }
            .store(in: &cancellables)
        tab.tabController.$feedCandidates
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.syncFeedButton() }
            .store(in: &cancellables)
        // Finished downloads badge the button until the popup is opened.
        DownloadsBadgeCenter.shared.$unseenCount
            .receive(on: DispatchQueue.main)
            .sink { [weak self] count in
                self?.downloadsButton.badgeCount = count
            }
            .store(in: &cancellables)
        // Exception edits land here too (the card writes settings), so the
        // shield tracks the toggle without waiting for a navigation.
        SettingsStore.shared.$settings
            .map(\.adblock.exceptions)
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.syncAdBlockButton() }
            .store(in: &cancellables)

        syncControls()
    }

    private func syncControls() {
        guard let state = tab?.tabController else {
            backButton.isEnabled = false
            forwardButton.isEnabled = false
            reloadButton.isEnabled = false
            addressField.stringValue = ""
            spotlight.updateClearButton()
            spotlight.isSecure = true
            syncFeedButton()
            syncAdBlockButton()
            return
        }

        backButton.isEnabled = state.canGoBack
        forwardButton.isEnabled = state.canGoForward
        reloadButton.isEnabled = true
        // Same 13.5pt medium cut as every other toolbar glyph (see `configure`):
        // this one is re-set on every state change, so it cannot reuse that path.
        reloadButton.image = NSImage(
            systemSymbolName: state.isLoading ? "xmark" : "arrow.clockwise",
            accessibilityDescription: state.isLoading ? "Stop" : "Reload"
        )?.withSymbolConfiguration(.init(pointSize: 13.5, weight: .medium))
        reloadButton.toolTip = state.isLoading ? "Stop" : "Reload"

        // The leading lock follows the live page (falling back to the tab's
        // own address like the field text), so it answers for what is shown.
        // While editing, the field shows the magnifier regardless.
        let pageURL = state.url ?? tab?.displayURL
        spotlight.isSecure = SpotlightField.isSecureScheme(pageURL?.scheme)

        if !isEditingAddress {
            // Falls back to the tab's own address so a tab whose view has not
            // been built yet still shows where it is going rather than a blank
            // field. Sets the same way `syncControls` does for every other control,
            // so switching tabs updates the address text.
            addressField.stringValue = pageURL?.absoluteString ?? ""
            // The text was set directly rather than typed, so the × would still
            // reflect the previous tab without this.
            spotlight.updateClearButton()
            // The dropdown's results were a function of the previous tab's field.
            spotlightController.fieldDidEndEditing()
        }
        syncFeedButton()
        syncAdBlockButton()
    }

    /// Shows the feed control exactly when the selected tab advertises feeds.
    ///
    /// The candidates are keyed to the page that produced them and cleared on
    /// navigation, so the button follows the page rather than lingering from
    /// the previous one.
    private func syncFeedButton() {        let isEnabled = SettingsStore.shared.settings.feeds.isEnabled
        let candidates = isEnabled ? tab?.tabController.feedCandidates ?? [] : []
        feedButton.isHidden = candidates.isEmpty
        feedButton.toolTip = candidates.count == 1
            ? "Available feed"
            : "\(candidates.count) available feeds"
    }

    /// Shows the shield matching the current site's blocker state: checked
    /// while blocking applies, crossed where the site (or its parent host)
    /// is excepted. Same effective-state rule as the blocker's card, so the
    /// two can never disagree about a subdomain.
    private func syncAdBlockButton() {
        let url = tab?.displayURL
        let host: String? = {
            guard let url,
                  let scheme = url.scheme?.lowercased(),
                  ["http", "https"].contains(scheme)
            else { return nil }
            return url.host?.lowercased()
        }()
        let isBlocking = host.map {
            !ContentBlockerStore.isExcepted(
                host: $0,
                in: SettingsStore.shared.settings.adblock.exceptions
            )
        } ?? false
        let image = NSImage(named: isBlocking ? "ShieldCheck" : "ShieldX")
        image?.accessibilityDescription = isBlocking
            ? "Content blocker active on this site"
            : "Content blocker paused on this site"
        image?.isTemplate = true
        image?.size = NSSize(width: 18, height: 18)
        adblockButton.image = image
        adblockButton.toolTip = isBlocking
            ? "Content Blocker — active on this site"
            : "Content Blocker — paused on this site"
    }

    // MARK: - Actions

    @objc private func goBack() {
        tab?.goBack()
    }

    @objc private func goForward() {
        tab?.goForward()
    }

    @objc private func toggleReload() {
        guard let state = tab?.tabController else { return }
        if state.isLoading {
            state.stopLoading()
        } else {
            state.reload()
        }
    }

    @objc private func openSettings() {
        onSettings?()
    }

    @objc private func openDownloads() {
        onDownloads?()
    }

    @objc private func openBookmarks() {
        onBookmarks?()
    }

    @objc private func openAdBlock() {
        onAdBlock?()
    }

    @objc private func openFeed() {
        guard SettingsStore.shared.settings.feeds.isEnabled else { return }
        let candidates = tab?.tabController.feedCandidates ?? []
        guard !candidates.isEmpty else { return }
        onFeed?(candidates)
    }

    // MARK: - Setup

    private func configureButtons() {
        configure(backButton, symbol: "chevron.left", help: "Back", action: #selector(goBack))
        configure(forwardButton, symbol: "chevron.right", help: "Forward", action: #selector(goForward))
        configure(reloadButton, symbol: "arrow.clockwise", help: "Reload", action: #selector(toggleReload))
        configureFeedButton()

        configure(settingsButton, symbol: "gearshape", help: "Settings", action: #selector(openSettings))
        // `arrow.down.to.line` is the plain download glyph: an arrow descending
        // onto a baseline, which reads as "fetching" without needing the tray
        // shape Safari uses or the circle the empty Downloads pane uses.
        configure(
            downloadsButton,
            symbol: "arrow.down.to.line",
            help: "Downloads",
            action: #selector(openDownloads)
        )
        configure(
            bookmarksButton,
            symbol: "bookmark",
            help: "Bookmarks",
            action: #selector(openBookmarks)
        )
        configureAdBlockButton()
    }

    private func configureCenterStack() {
        // The address container keeps its own preferred size; the stack only
        // holds the feed button directly after it. Hiding the button removes
        // its arranged space too, so the field does not keep a gap where the
        // control would have been.
        centerStack.orientation = .horizontal
        centerStack.alignment = .centerY
        centerStack.spacing = 6
        centerStack.addArrangedSubview(addressContainer)
        centerStack.addArrangedSubview(feedButton)
    }

    /// Bundled Tabler vectors rather than a system glyph, so the control can
    /// show a check (blocking) or a cross (paused) inside the shield. Like
    /// the feed button: template images sized like the neighboring glyphs,
    /// with `syncAdBlockButton` owning the state from here on.
    private func configureAdBlockButton() {
        adblockButton.target = self
        adblockButton.action = #selector(openAdBlock)
        syncAdBlockButton()
    }

    private func configureFeedButton() {        // Bundled vector rather than a system glyph, so the control always
        // shows the project’s RSS mark. It is a template image, matching the
        // toolbar’s label color, and is sized like the neighboring glyphs.
        let image = NSImage(named: "RSS")
        image?.accessibilityDescription = "Available feeds"
        image?.isTemplate = true
        image?.size = NSSize(width: 18, height: 18)
        feedButton.image = image
        feedButton.toolTip = "Available feeds"
        feedButton.target = self
        feedButton.action = #selector(openFeed)
        // Shown only for a page that advertises feeds; `syncFeedButton` owns
        // this from here on.
        feedButton.isHidden = true
    }

    private func configure(_ button: BrowserToolbarButton, symbol: String, help: String, action: Selector?) {
        // Measured, not guessed: the default cut renders ~16pt tall, and pointSize
        // scales it linearly (18 renders 24), so 13.5 lands ~18 — two points
        // larger, filling more of the 24pt frame. The medium weight keeps the
        // stroke sharp rather than hairline at that size.
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: help)?
            .withSymbolConfiguration(.init(pointSize: 13.5, weight: .medium))
        button.image = image
        button.toolTip = help
        button.target = action == nil ? nil : self
        button.action = action
    }

    private func configureAddressField() {
        // The spotlight draws its own chrome, so nothing is configured on the field
        // here beyond the padding the drawn version positions it with.
        addressContainer.translatesAutoresizingMaskIntoConstraints = false
        addressContainer.addSubview(spotlight)
        spotlight.translatesAutoresizingMaskIntoConstraints = false
        // The dropdown is added to the window's content view rather than to this
        // container, so it can cover the tab bar and the page. Resolved lazily
        // because the toolbar is built before the content controller's view is
        // loaded, so the call is made again from `installToolbar`.
        spotlightController.attach(field: spotlight)
        // Preferred width rather than a fixed one, so that on a window too narrow to
        // hold it the field gives way instead of the strip's leading and trailing
        // clusters breaking their constraints against each other.
        let preferredWidth = addressContainer.widthAnchor.constraint(
            equalToConstant: Self.addressFieldWidth
        )
        preferredWidth.priority = .defaultHigh
        NSLayoutConstraint.activate([
            spotlight.leadingAnchor.constraint(equalTo: addressContainer.leadingAnchor),
            spotlight.trailingAnchor.constraint(equalTo: addressContainer.trailingAnchor),
            spotlight.centerYAnchor.constraint(equalTo: addressContainer.centerYAnchor),
            // Both the container and the spotlight: the container is what the strip
            // centres and sizes, and with only the spotlight pinned the container
            // collapses to zero height and the drawn chrome disappears with it.
            addressContainer.heightAnchor.constraint(equalToConstant: Self.addressFieldHeight),
            spotlight.heightAnchor.constraint(equalToConstant: Self.addressFieldHeight),
            preferredWidth,
            addressContainer.widthAnchor.constraint(
                lessThanOrEqualToConstant: Self.addressFieldWidth
            ),
        ])
    }

    private static let addressFieldHeight: CGFloat = 32
    private static let addressFieldWidth: CGFloat = 460

    // MARK: - Spotlighting

    func moveSpotlightSelection(by offset: Int) {
        spotlightController.moveSelection(by: offset)
    }

    func dismissSpotlight() {
        spotlightController.fieldDidEndEditing()
    }
}

// MARK: - Spotlighting

/// The spotlight's input is a plain `NSTextField`, and `SpotlightField` owns the
/// caret handling that `NSSearchFieldDelegate` used to do here. What stays in this
/// controller is the one thing the tab binding needs: whether the field is being
/// edited, so `syncControls` does not overwrite what is being typed.
