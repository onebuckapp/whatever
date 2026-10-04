import AppKit
import Combine

/// Native window toolbar: back / forward / reload on the leading side,
/// the address field in the middle, and bookmarks / downloads / settings on the
/// trailing side. It follows the window's active tab, so switching tabs updates
/// the navigation state and the address text.
@MainActor
final class BrowserToolbarController: NSObject {
    private static let navigationID = NSToolbarItem.Identifier("whatever.navigation")
    private static let backID = NSToolbarItem.Identifier("whatever.navigation.back")
    private static let forwardID = NSToolbarItem.Identifier("whatever.navigation.forward")
    private static let reloadID = NSToolbarItem.Identifier("whatever.navigation.reload")
    private static let addressID = NSToolbarItem.Identifier("whatever.address")
    private static let settingsID = NSToolbarItem.Identifier("whatever.settings")
    private static let downloadsID = NSToolbarItem.Identifier("whatever.downloads")
    private static let bookmarksID = NSToolbarItem.Identifier("whatever.bookmarks")
    /// macOS only exposes the space identifiers as raw constants.
    private static let flexibleSpaceID = NSToolbarItem.Identifier(
        rawValue: "NSToolbarFlexibleSpaceItem"
    )

    let windowToolbar: NSToolbar
    /// A plain `NSToolbarItem` holding a compact `NSSearchField`:
    /// `NSSearchToolbarItem` would force the prominent 40pt style,
    /// which is much taller than the rest of the toolbar.
    private let addressItem = NSToolbarItem(
        itemIdentifier: BrowserToolbarController.addressID
    )
    private let addressContainer = NSView()
    private let addressField = AddressSearchField()
    private let settingsButton = NSButton()
    private let downloadsButton = NSButton()
    private let bookmarksButton = NSButton()
    private let backButton = NSButton()
    private let forwardButton = NSButton()
    private let reloadButton = NSButton()

    private weak var controller: BrowserWindowController?
    private var cancellables = Set<AnyCancellable>()
    private var tab: BrowserTab?
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
        self.windowToolbar = NSToolbar(identifier: "whatever.toolbar")
        super.init()

        windowToolbar.delegate = self
        windowToolbar.displayMode = .iconOnly
        windowToolbar.allowsUserCustomization = false
        configureButtons()
        configureAddressField()
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
            return
        }

        backButton.isEnabled = state.canGoBack
        forwardButton.isEnabled = state.canGoForward
        reloadButton.isEnabled = true
        reloadButton.image = NSImage(
            systemSymbolName: state.isLoading ? "xmark" : "arrow.clockwise",
            accessibilityDescription: state.isLoading ? "Stop" : "Reload"
        )
        reloadButton.toolTip = state.isLoading ? "Stop" : "Reload"

        if !isEditingAddress {
            // Falls back to the tab's own address so a tab whose view has not
            // been built yet still shows where it is going rather than a blank
            // field.
            addressField.stringValue = (state.url ?? tab?.displayURL)?.absoluteString ?? ""
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

    private func configure(_ button: NSButton, symbol: String, help: String, action: Selector?) {
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: help)
        button.bezelStyle = .texturedRounded
        button.toolTip = help
        button.setButtonType(.momentaryChange)
        button.target = action == nil ? nil : self
        button.action = action
    }

    private func configureAddressField() {
        let field = addressField
        field.controlSize = .regular
        field.sendsSearchStringImmediately = false
        field.focusRingType = .default
        field.placeholderString = "Search or enter address"
        field.delegate = self
        field.sendsWholeSearchString = false
        field.sendsSearchStringImmediately = false
        // A wide, rounded field: the toolbar item keeps its fixed width and
        // the flexible spaces on both sides keep it centred.
        field.cell?.usesSingleLineMode = true
        field.cell?.truncatesLastVisibleLine = true
        field.font = .systemFont(ofSize: 13)
        field.translatesAutoresizingMaskIntoConstraints = false

        // The stock search cell draws its rounded bezel at its intrinsic
        // height, so the field lives in a fixed-height transparent wrapper
        // that centers it vertically instead of stretching the field itself
        // (stretching breaks the bezel shape and text alignment).
        addressContainer.translatesAutoresizingMaskIntoConstraints = false
        addressContainer.addSubview(field)
        NSLayoutConstraint.activate([
            field.centerYAnchor.constraint(equalTo: addressContainer.centerYAnchor),
            field.leadingAnchor.constraint(equalTo: addressContainer.leadingAnchor),
            field.trailingAnchor.constraint(equalTo: addressContainer.trailingAnchor),
            field.widthAnchor.constraint(equalToConstant: Self.addressFieldWidth),
            addressContainer.heightAnchor.constraint(equalToConstant: Self.addressFieldHeight),
            addressContainer.widthAnchor.constraint(equalToConstant: Self.addressFieldWidth),
        ])

        addressItem.view = addressContainer
        addressItem.label = "Address"
        addressItem.isBordered = true
    }

    private static let addressFieldHeight: CGFloat = 28
    private static let addressFieldWidth: CGFloat = 460
}

// MARK: - NSToolbarDelegate

extension BrowserToolbarController: NSToolbarDelegate {
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        // Flexible space on both sides keeps the wide address field centred, with
        // the trailing buttons pinned to the right edge. Identifiers run left to
        // right, so this trailing group reads bookmarks, downloads, settings, or
        // settings, downloads, bookmarks from the right.
        [
            Self.navigationID,
            Self.flexibleSpaceID,
            Self.addressID,
            Self.flexibleSpaceID,
            Self.bookmarksID,
            Self.downloadsID,
            Self.settingsID,
        ]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar) + [NSToolbarItem.Identifier.space]
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        switch itemIdentifier {
        case Self.navigationID:
            return makeNavigationGroup()
        case Self.settingsID:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.view = settingsButton
            item.label = "Settings"
            item.toolTip = "Settings"
            return item
        case Self.downloadsID:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.view = downloadsButton
            item.label = "Downloads"
            item.toolTip = "Downloads"
            return item
        case Self.bookmarksID:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.view = bookmarksButton
            item.label = "Bookmarks"
            item.toolTip = "Bookmarks"
            return item
        case Self.addressID:
            return addressItem
        case Self.flexibleSpaceID:
            return Self.makeFlexibleSpace(identifier: itemIdentifier)
        default:
            return nil
        }
    }

    /// `NSToolbarSpaceItem` backs the space identifiers but is not
    /// declared in the macOS SDK, so it is resolved by name.
    private static func makeFlexibleSpace(identifier: NSToolbarItem.Identifier) -> NSToolbarItem? {
        guard let spaceClass = NSClassFromString("NSToolbarSpaceItem") as? NSObject.Type
        else {
            return nil
        }
        let space = spaceClass.init()
        setItemIdentifier(identifier, on: space)
        return space as? NSToolbarItem
    }

    private static func setItemIdentifier(
        _ identifier: NSToolbarItem.Identifier,
        on object: NSObject
    ) {
        let selector = NSSelectorFromString("setItemIdentifier:")
        guard object.responds(to: selector),
              type(of: object).instancesRespond(to: selector)
        else {
            return
        }
        _ = object.perform(selector, with: identifier)
    }

    /// The three navigation buttons share one movable group so they
    /// cannot be separated.
    private func makeNavigationGroup() -> NSToolbarItemGroup {
        let items = [
            makeButtonItem(Self.backID, button: backButton, label: "Back"),
            makeButtonItem(Self.forwardID, button: forwardButton, label: "Forward"),
            makeButtonItem(Self.reloadID, button: reloadButton, label: "Reload"),
        ]
        let group = NSToolbarItemGroup(itemIdentifier: Self.navigationID)
        group.subitems = items
        group.controlRepresentation = .automatic
        group.label = "Navigation"
        return group
    }

    private func makeButtonItem(
        _ identifier: NSToolbarItem.Identifier,
        button: NSButton,
        label: String
    ) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.view = button
        item.label = label
        item.toolTip = button.toolTip
        return item
    }
}

// MARK: - Address field

extension BrowserToolbarController: NSSearchFieldDelegate {
    func controlTextDidBeginEditing(_ obj: Notification) {
        isEditingAddress = true
        // Deferred one runloop so the focusing click's caret placement has
        // finished; otherwise the click would override the selection.
        DispatchQueue.main.async { [weak self] in
            self?.addressField.currentEditor()?.selectAll(nil)
        }
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        // End editing fires on blur as well as on Enter, so it must never
        // submit: blurring the field would otherwise reload the page.
        // Submission happens only on Enter via doCommandBy below.
        isEditingAddress = false
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            submitAddress()
            return true
        }
        return false
    }

    private func submitAddress() {
        let text = addressField.stringValue
        // Read the engine here rather than in the parser, so the parser stays a
        // pure function of its input and the store is touched once per search.
        let engine = SettingsStore.shared.settings.search.engine()
        guard let url = AddressParser.url(from: text, searchEngine: engine) else { return }
        onAddressSubmitted?(url)
    }
}
