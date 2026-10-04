import AppKit
import Combine

/// The window's top strip: back / forward / reload on the leading side,
/// the address field in the middle, and bookmarks / downloads / settings on the
/// trailing side. It follows the window's active tab, so switching tabs updates
/// the navigation state and the address text.
///
/// Owns the views; `BrowserToolbarView` owns the layout. It was an `NSToolbar`
/// until the strip became hand-rolled, and the button and field code below is
/// unchanged from when it was.
@MainActor
final class BrowserToolbarController: NSObject {
    /// Installed into the window's content view by `BrowserWindowController`.
    let toolbarView: BrowserToolbarView
    private let addressContainer = NSView()
    /// The drawn spotlight and the dropdown under it. The old `AddressSearchField`
    /// is gone: see `SpotlightField` for why a stock search field could not do this.
    private let spotlight = SpotlightField()
    private let spotlightController = SpotlightController()
    private let settingsButton = BrowserToolbarButton()
    private let downloadsButton = BrowserToolbarButton()
    private let bookmarksButton = BrowserToolbarButton()
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

    init(controller: BrowserWindowController) {
        self.controller = controller
        // Built before `super.init()` because the strip is a `let`. The buttons and
        // the field are already initialized by their own declarations, so the strip
        // can be handed them here; their targets, images and delegate need `self`
        // and are set just after.
        let toolbar = BrowserToolbarView(
            leading: [backButton, forwardButton, reloadButton],
            center: addressContainer,
            trailing: [bookmarksButton, downloadsButton, settingsButton]
        )
        self.toolbarView = toolbar
        super.init()

        configureButtons()
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

        syncControls()
    }

    private func syncControls() {
        guard let state = tab?.tabController else {
            backButton.isEnabled = false
            forwardButton.isEnabled = false
            reloadButton.isEnabled = false
            addressField.stringValue = ""
            spotlight.updateClearButton()
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

        if !isEditingAddress {
            // Falls back to the tab's own address so a tab whose view has not
            // been built yet still shows where it is going rather than a blank
            // field. Sets the same way `syncControls` does for every other control,
            // so switching tabs updates the address text.
            addressField.stringValue = (state.url ?? tab?.displayURL)?.absoluteString ?? ""
            // The text was set directly rather than typed, so the × would still
            // reflect the previous tab without this.
            spotlight.updateClearButton()
            // The dropdown's results were a function of the previous tab's field.
            spotlightController.fieldDidEndEditing()
        }
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

    // MARK: - Setup

    private func configureButtons() {
        configure(backButton, symbol: "chevron.left", help: "Back", action: #selector(goBack))
        configure(forwardButton, symbol: "chevron.right", help: "Forward", action: #selector(goForward))
        configure(reloadButton, symbol: "arrow.clockwise", help: "Reload", action: #selector(toggleReload))

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
