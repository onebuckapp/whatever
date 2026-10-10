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
    /// Camera/mic indicator for the selected tab. Hidden unless the
    /// page asked for or holds a capture; opens the capture popup.
    private let webrtcButton = BrowserToolbarButton()
    /// The drawn spotlight and the dropdown under it. The old `AddressSearchField`
    /// is gone: see `SpotlightField` for why a stock search field could not do this.
    private let spotlight = SpotlightField()
    private let spotlightController = SpotlightController()
    private let settingsButton = BrowserToolbarButton()
    private let downloadsButton = BrowserToolbarButton()
    private let bookmarksButton = BrowserToolbarButton()
    private let passwordButton = BrowserToolbarButton()
    private let adblockButton = BrowserToolbarButton()
    private let backButton = BrowserToolbarButton()
    private let forwardButton = BrowserToolbarButton()
    private let reloadButton = BrowserToolbarButton()
    private let bookmarkButton = BrowserToolbarButton()
    /// Shown first in the leading cluster of incognito windows only: a small
    /// marker so a private window is distinguishable from a regular one.
    /// A label has no padding of its own, so it sits in a pill with insets.
    private static func makeIncognitoBadge() -> NSView {
        let label = NSTextField(labelWithString: "Incognito")
        label.font = .systemFont(ofSize: 11, weight: .medium)
        label.textColor = .secondaryLabelColor
        label.alignment = .center
        let pill = NSView()
        pill.wantsLayer = true
        pill.layer?.backgroundColor = NSColor.quaternaryLabelColor.cgColor
        pill.layer?.cornerRadius = 8
        pill.toolTip = "This window is incognito: its tabs are not saved to history."
        pill.addSubview(label)
        label.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: pill.leadingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: pill.trailingAnchor, constant: -8),
            label.topAnchor.constraint(equalTo: pill.topAnchor, constant: 3),
            label.bottomAnchor.constraint(equalTo: pill.bottomAnchor, constant: -3),
        ])
        return pill
    }

    private weak var controller: BrowserWindowController?
    private var cancellables = Set<AnyCancellable>()
    /// Chrome-level subscriptions that must survive tab switches. `cancellables`
    /// resets on every `setTab`, so anything not about the tab lives here.
    private var chromeCancellables = Set<AnyCancellable>()
    /// Style-owned constraints, kept to retarget rather than rebuild when the
    /// address bar settings change.
    private var addressContainerMaxWidth: NSLayoutConstraint?
    private var addressContainerPreferredWidth: NSLayoutConstraint?
    private var addressContainerHeight: NSLayoutConstraint!
    private var spotlightHeight: NSLayoutConstraint!
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
    /// Opens the password manager card for this window.
    var onPasswords: (() -> Void)?
    /// Opens the per-site content-blocker card for the current tab.
    var onAdBlock: (() -> Void)?
    /// Opens the bookmark editor for the current page: add when the page is
    /// not saved yet, edit when it is.
    var onBookmark: ((BookmarkEditorMode) -> Void)?
    /// Opens the capture popup for the selected tab's pending or live
    /// camera and microphone requests.
    var onMediaCapture: (() -> Void)?
    /// Offers the selected tab's advertised feeds. Empty when hidden.
    var onFeed: (([FeedCandidate]) -> Void)?

    init(controller: BrowserWindowController) {
        self.controller = controller
        // Built before `super.init()` because the strip is a `let`. The buttons and
        // the field are already initialized by their own declarations, so the strip
        // can be handed them here; their targets, images and delegate need `self`
        // and are set just after.
        let toolbar = BrowserToolbarView(
            leading: controller.isIncognito
                ? [Self.makeIncognitoBadge(), backButton, forwardButton, reloadButton, bookmarkButton]
                : [backButton, forwardButton, reloadButton, bookmarkButton],
            center: centerStack,
            trailing: [adblockButton, passwordButton, bookmarksButton, downloadsButton, settingsButton]
        )
        self.toolbarView = toolbar
        super.init()

        configureButtons()
        configureCenterStack()
        configureAddressField()
        configureSpotlight()
        // Address chrome follows settings for the life of the window, not the
        // tab: subscribing here rather than in `setTab` keeps it alive across
        // tab switches.
        SettingsStore.shared.$settings
            .map(\.addressBar)
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.applyAddressBarStyle() }
            .store(in: &chromeCancellables)
        applyAddressBarStyle()
        // The star follows the bookmarks themselves, not the tab: a save
        // from any window (or the bar's own menus) flips it everywhere.
        BookmarkStore.shared.$nodes
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.syncBookmarkButton() }
            .store(in: &chromeCancellables)
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
        // Capture grants and pending requests light the toolbar button
        // until the page goes away; the popup answers the pending ones.
        tab.tabController.$captureState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.syncMediaCaptureButton() }
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
            syncBookmarkButton()
            syncMediaCaptureButton()
            return
        }

        backButton.isEnabled = state.canGoBack
        forwardButton.isEnabled = state.canGoForward
        reloadButton.isEnabled = true
        // The stop glyph stays a system X: it means stop, not reload, and no
        // bundled X was cut for it. The reload glyph is the bundled Tabler
        // arrow, re-set here because this row re-sets the image on every
        // state change rather than reusing the setup path.
        if state.isLoading {
            reloadButton.image = NSImage(
                systemSymbolName: "xmark",
                accessibilityDescription: "Stop"
            )?.withSymbolConfiguration(.init(pointSize: 13.5, weight: .medium))
        } else {
            let image = BrowserToolbarButton.bundledGlyphImage(named: "TablerReload", inkRatio: 0.75)
            image?.accessibilityDescription = "Reload"
            reloadButton.image = image
        }
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
        syncBookmarkButton()
        syncMediaCaptureButton()
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
        // One ratio for both states so toggling blocker state never moves
        // the glyph: it boxes both at 17pt, where the check paints ~14.5pt
        // of ink and the cross ~15pt — both inside the system glyphs'
        // 12–15pt band.
        let image = BrowserToolbarButton.bundledGlyphImage(
            named: isBlocking ? "ShieldCheck" : "ShieldX",
            inkRatio: 0.85
        )
        image?.accessibilityDescription = isBlocking
            ? "Content blocker active on this site"
            : "Content blocker paused on this site"
        adblockButton.image = image
        adblockButton.toolTip = isBlocking
            ? "Content Blocker — active on this site"
            : "Content Blocker — paused on this site"
    }

    /// The star: filled while the current page is bookmarked, hollow when
    /// not, disabled where there is no user-facing address to save. Both
    /// states share one ratio so toggling saved state never moves the glyph.
    private func syncBookmarkButton() {
        let url = tab?.displayURL
        let saved = url.map { !$0.isAddresslessPage && BookmarkStore.shared.isBookmarked($0) } ?? false
        let help = saved ? "Edit Bookmark" : "Add Bookmark"
        bookmarkButton.isEnabled = url.map { !$0.isAddresslessPage } ?? false
        let image = BrowserToolbarButton.bundledGlyphImage(
            named: saved ? "TablerStarFilled" : "TablerStar",
            inkRatio: 0.875
        )
        image?.accessibilityDescription = help
        bookmarkButton.image = image
        bookmarkButton.toolTip = help
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

    @objc private func togglePasswords() {
        onPasswords?()
    }

    @objc private func openAdBlock() {
        onAdBlock?()
    }

    @objc private func openMediaCapture() {
        guard tab?.tabController.captureState.hasActivity == true else { return }
        onMediaCapture?()
    }

    @objc private func openFeed() {
        guard SettingsStore.shared.settings.feeds.isEnabled else { return }
        let candidates = tab?.tabController.feedCandidates ?? []
        guard !candidates.isEmpty else { return }
        onFeed?(candidates)
    }

    /// The star's action: edit the existing bookmark when the page is
    /// already saved, offer to add it otherwise. Prefilled from the page so
    /// the common case is one press plus Save.
    @objc private func toggleBookmark() {
        guard let url = tab?.displayURL, !url.isAddresslessPage else { return }
        onBookmark?(
            BookmarkEditor.starMode(
                for: url,
                title: tab?.tabController.title ?? "",
                in: BookmarkStore.shared
            )
        )
    }

    // MARK: - Setup

    private func configureButtons() {
        configureBundled(
            backButton,
            asset: "TablerChevronLeft",
            inkRatio: 0.725,
            help: "Back",
            action: #selector(goBack)
        )
        configureBundled(
            forwardButton,
            asset: "TablerChevronRight",
            inkRatio: 0.725,
            help: "Forward",
            action: #selector(goForward)
        )
        configureBundled(
            reloadButton,
            asset: "TablerReload",
            inkRatio: 0.75,
            help: "Reload",
            action: #selector(toggleReload)
        )
        configure(bookmarkButton, symbol: "star", help: "Add Bookmark", action: #selector(toggleBookmark))
        syncBookmarkButton()
        configureFeedButton()

        configurePasswordButton()
        configureAdBlockButton()
        configureWebRTCButton()
        configureBundled(
            bookmarksButton,
            asset: "TablerBookmark",
            inkRatio: 0.833,
            help: "Bookmarks",
            action: #selector(openBookmarks)
        )
        configureBundled(
            downloadsButton,
            asset: "TablerDownloads",
            inkRatio: 0.75,
            help: "Downloads",
            action: #selector(openDownloads)
        )
        configureBundled(
            settingsButton,
            asset: "TablerSettings",
            inkRatio: 0.833,
            help: "Settings",
            action: #selector(openSettings)
        )
    }

    private func configureCenterStack() {
        // The address container keeps its own preferred size; the stack only
        // holds the feed button directly after it. Hiding the button removes
        // its arranged space too, so the field does not keep a gap where the
        // control would have been.
        centerStack.orientation = .horizontal
        centerStack.alignment = .centerY
        centerStack.spacing = 6
        // Fill, not gravity: in stretch mode the stack itself is pinned across
        // the strip, and the container must grow into it rather than sit at
        // its leading edge at preferred width. The feed button's fixed size
        // keeps it put while the container takes the extra space.
        centerStack.distribution = .fill
        centerStack.addArrangedSubview(addressContainer)
        // Capture controls sit between the field and the feed button, and
        // only while the page holds or wants a capture; hiding the button
        // removes its arranged space too, like the feed button.
        centerStack.addArrangedSubview(webrtcButton)
        centerStack.addArrangedSubview(feedButton)
    }

    /// Shows the capture button exactly while the selected tab's page asked
    /// for or holds a capture. A pending request names itself; a live grant
    /// does.
    private func syncMediaCaptureButton() {
        let state = tab?.tabController.captureState ?? MediaCaptureState()
        webrtcButton.isHidden = !state.hasActivity
        if !state.requests.isEmpty {
            webrtcButton.toolTip = "Camera or microphone requested — open capture controls"
        } else {
            webrtcButton.toolTip = "Camera or microphone in use — open capture controls"
        }
    }

    /// Bundled Tabler vectors rather than a system glyph, so the control can
    /// show a check (blocking) or a cross (paused) inside the shield. Like
    /// the feed button: template images sized like the neighboring glyphs,
    /// with `syncAdBlockButton` owning the state from here on.
    /// Bundled Tabler vector rather than a system glyph, like the feed and
    /// shield buttons: a template image sized like the neighboring glyphs.
    /// `syncPasswordButton` does not exist because the button carries no
    /// state — the vault's lock state lives inside the manager card.
    private func configurePasswordButton() {
        let image = BrowserToolbarButton.bundledGlyphImage(
            named: "TablerAsterisk",
            inkRatio: 0.833
        )
        image?.accessibilityDescription = "Password Manager"
        passwordButton.image = image
        passwordButton.toolTip = "Password Manager"
        passwordButton.target = self
        passwordButton.action = #selector(togglePasswords)
    }

    private func configureAdBlockButton() {
        adblockButton.target = self
        adblockButton.action = #selector(openAdBlock)
        syncAdBlockButton()
    }

    /// Bundled access-point vector rather than a system glyph, so the
    /// control reads as broadcast rather than any one device. Boxed to
    /// match the system glyphs' width rather than their height: the arcs
    /// span nearly the whole grid, so height-matching would make it far
    /// wider than its neighbors. Hidden until a capture request or
    /// grant lights it; `syncMediaCaptureButton` owns this from here on.
    private func configureWebRTCButton() {
        let image = BrowserToolbarButton.bundledGlyphImage(named: "AccessPoint", inkRatio: 0.69)
        image?.accessibilityDescription = "Capture controls"
        webrtcButton.image = image
        webrtcButton.toolTip = "Capture controls"
        webrtcButton.target = self
        webrtcButton.action = #selector(openMediaCapture)
        webrtcButton.isHidden = true
    }

    private func configureFeedButton() {        // Bundled vector rather than a system glyph, so the control always
        // shows the project’s RSS mark. It is a template image, matching the
        // toolbar’s label color, and is boxed by ink like the other bundled
        // glyphs rather than at its 18pt box.
        let image = BrowserToolbarButton.bundledGlyphImage(named: "RSS", inkRatio: 0.75)
        image?.accessibilityDescription = "Available feeds"
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
        // larger, filling more of the frame. The medium weight keeps the
        // stroke sharp rather than hairline at that size.
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: help)?
            .withSymbolConfiguration(.init(pointSize: 13.5, weight: .medium))
        button.image = image
        button.toolTip = help
        button.target = action == nil ? nil : self
        button.action = action
    }

    /// Same as `configure` for bundled Tabler vectors: boxed by ink through
    /// the shared factory so the glyph paints at the system glyphs' size.
    private func configureBundled(
        _ button: BrowserToolbarButton,
        asset: String,
        inkRatio: CGFloat,
        help: String,
        action: Selector?
    ) {
        let image = BrowserToolbarButton.bundledGlyphImage(named: asset, inkRatio: inkRatio)
        image?.accessibilityDescription = help
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
        // Both width constraints come off in stretch mode, where the pins to
        // the clusters own the width: the stack's fill fights even the
        // lower-priority preferred width instead of yielding to it, and the
        // ambiguity parks the field at preferred size off-centre. Both are
        // kept so toggling the mode never rebuilds constraints.
        let maxWidth = addressContainer.widthAnchor.constraint(
            lessThanOrEqualToConstant: Self.addressFieldWidth
        )
        addressContainerMaxWidth = maxWidth
        addressContainerPreferredWidth = preferredWidth
        addressContainerHeight = addressContainer.heightAnchor.constraint(
            equalToConstant: Self.addressFieldHeight
        )
        spotlightHeight = spotlight.heightAnchor.constraint(equalToConstant: Self.addressFieldHeight)
        NSLayoutConstraint.activate([
            spotlight.leadingAnchor.constraint(equalTo: addressContainer.leadingAnchor),
            spotlight.trailingAnchor.constraint(equalTo: addressContainer.trailingAnchor),
            spotlight.centerYAnchor.constraint(equalTo: addressContainer.centerYAnchor),
            // Both the container and the spotlight: the container is what the strip
            // centres and sizes, and with only the spotlight pinned the container
            // collapses to zero height and the drawn chrome disappears with it.
            addressContainerHeight,
            spotlightHeight,
            preferredWidth,
            maxWidth,
        ])
    }

    /// Applies the address bar chrome settings: stretch mode, corner radius,
    /// and field height. Height lands on both the container and the field so
    /// the drawn chrome keeps its size.
    private func applyAddressBarStyle() {
        let style = SettingsStore.shared.settings.addressBar
        toolbarView.setFullWidth(style.fillsWidth)
        addressContainerMaxWidth?.isActive = !style.fillsWidth
        addressContainerPreferredWidth?.isActive = !style.fillsWidth
        SpotlightField.cornerRadius = style.cornerRadius
        let height = CGFloat(style.fieldHeight)
        addressContainerHeight.constant = height
        spotlightHeight.constant = height
        spotlight.needsDisplay = true
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
