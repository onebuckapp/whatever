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

/// The password manager card: a settings-shaped modal with a website sidebar
/// and a credential detail pane, presented by Mijick/Popups.
///
/// The card owns no secrets beyond what `PasswordStore` publishes: the core
/// holds the session key, and closing the card locks the vault (see the
/// content controller's teardown). Fields commit debounced, like settings —
/// there are no Save buttons.
struct PasswordManagerPopup: CenterPopup {
    let stackID: PopupStackID
    let popupID: String

    func configurePopup(config: CenterPopupConfig) -> CenterPopupConfig {
        config
            .backgroundColor(.clear)
            .cornerRadius(20)
            .overlayColor(.clear)
            .tapOutsideToDismissPopup(true)
    }

    func onDismiss() {
        Task { @MainActor in
            PasswordManagerCoordinator.shared.popupDidDismiss(id: popupID)
        }
    }

    var body: some View {
        PasswordManagerCard()
            .frame(width: 720, height: 520)
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
                Task {
                    await PopupStack.dismissPopup(popupID, popupStackID: stackID)
                }
            }
    }
}

/// The card itself: locked forms or the sidebar + detail, driven by the
/// shared store. An ordinary view so it can own selection and drafts; the
/// popup struct above stays `Sendable` with lets only.
private struct PasswordManagerCard: View {
    @ObservedObject private var store = PasswordStore.shared
    @State private var selectedID: String?
    @State private var query = ""
    @State private var editingHint = false
    @State private var hintDraft = ""
    @FocusState private var searchFocused: Bool

    private static let sidebarWidth: CGFloat = 220
    private static let rowInset: CGFloat = 10
    private static let listInset: CGFloat = 8

    var body: some View {
        Group {
            switch store.lockState {
            case .unset:
                PasswordSetupView()
            case .locked:
                PasswordUnlockView()
            case .unlocked:
                manager
            case .unknown:
                ProgressView().controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task {
            if store.lockState == .unknown {
                await store.refreshStatus()
            }
        }
    }

    private var filteredSites: [VaultSite] {
        let sites = store.vault.sites.sorted {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return sites }
        return sites.filter { VaultSearch.matches($0, query: trimmed) }
    }

    private var selectedSite: VaultSite? {
        let sites = filteredSites
        if let id = selectedID, let site = sites.first(where: { $0.id == id }) {
            return site
        }
        return sites.first
    }

    private var manager: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            detail
        }
        .onAppear {
            // The caret starts in the search field: type-to-filter with no
            // click needed. Delayed because the manager branch appears on a
            // lock-state flip, and a focus set mid-transition is dropped.
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(80))
                searchFocused = true
                try? await Task.sleep(for: .milliseconds(200))
                if !searchFocused {
                    searchFocused = true
                }
            }
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Passwords")
                .font(.system(size: 13, weight: .semibold))
                .padding(.horizontal, Self.rowInset)
                .padding(.top, 14)
                .padding(.bottom, 4)
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .focused($searchFocused)
                if !query.isEmpty {
                    Button {
                        query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, Self.rowInset)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .padding(.horizontal, Self.listInset)
            .padding(.bottom, 4)
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(filteredSites) { site in
                        siteRow(site)
                    }
                }
            }
            Spacer(minLength: 0)
            HStack(spacing: 4) {
                Button {
                    let site = store.createSite(name: "", url: "")
                    selectedID = site.id
                } label: {
                    Label("New Site", systemImage: "plus")
                        .font(.system(size: 12))
                }
                .buttonStyle(.plain)
                .padding(.horizontal, Self.rowInset)
                .padding(.vertical, 6)
                Spacer(minLength: 0)
                Button {
                    Task { @MainActor in
                        await store.lock()
                    }
                } label: {
                    Image(systemName: "lock")
                        .font(.system(size: 12))
                }
                .buttonStyle(.plain)
                .help("Lock the vault")
                .padding(.trailing, Self.rowInset)
            }
            HStack(spacing: 4) {
                Text(store.vaultHint.map { "Hint: \($0)" } ?? "No hint set")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
                Button {
                    hintDraft = store.vaultHint ?? ""
                    editingHint = true
                } label: {
                    Image(systemName: "pencil")
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .help("Change the vault hint")
                .padding(.trailing, Self.rowInset)
            }
            .padding(.leading, Self.rowInset)
        }
        .padding(.horizontal, Self.listInset)
        .frame(width: Self.sidebarWidth)
        .padding(.bottom, 10)
        .background(Color(nsColor: .underPageBackgroundColor))
        .alert("Vault hint", isPresented: $editingHint) {
            TextField("Hint (optional)", text: $hintDraft)
            Button("Save") {
                Task { @MainActor in
                    if await store.setHint(hintDraft.trimmingCharacters(in: .whitespacesAndNewlines)) {
                        editingHint = false
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Shown after several wrong passwords. Never the password itself.")
        }
    }

    private func siteRow(_ site: VaultSite) -> some View {
        let isSelected = site.id == selectedSite?.id
        return Button {
            selectedID = site.id
        } label: {
            HStack(spacing: 8) {
                PasswordSiteIcon(base64: site.favicon, size: 16)
                VStack(alignment: .leading, spacing: 1) {
                    Text(site.displayName)
                        .font(.system(size: 12))
                        .lineLimit(1)
                    if !site.host.isEmpty {
                        Text(site.host)
                            .font(.system(size: 10))
                            .foregroundStyle(isSelected ? Color.white.opacity(0.8) : Color.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                Spacer(minLength: 0)
            }
            .foregroundStyle(isSelected ? Color.white : Color.primary)
            .padding(.horizontal, Self.rowInset)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isSelected ? Color.accentColor : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var detail: some View {
        if let site = selectedSite, store.site(site.id) != nil {
            PasswordSiteDetail(siteID: site.id)
                .id(site.id)
        } else {
            SettingsPlaceholder(
                symbol: "key",
                title: "No site selected",
                message: "Pick a website on the left, or add one."
            )
        }
    }
}

/// A stored favicon or the globe fallback, in the tab strip's style.
private struct PasswordSiteIcon: View {
    let base64: String?
    let size: CGFloat

    var body: some View {
        Group {
            if let base64, let image = FeedImage.make(from: base64) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                    .accessibilityHidden(true)
            } else {
                Image(systemName: "globe")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(width: size, height: size)
    }
}

/// First-run form: choose the master password. A forgotten master password
/// loses the vault — there is no recovery, so it says so plainly.
private struct PasswordSetupView: View {
    @ObservedObject private var store = PasswordStore.shared
    @State private var password = ""
    @State private var confirm = ""
    @State private var hint = ""
    @State private var failure: String?

    /// Tab order through the form, buttons included: without explicit focus
    /// bindings SwiftUI leaves Tab dead inside the hosted card.
    private enum Field: Hashable {
        case password, confirm, hint, create
    }

    @FocusState private var focusedField: Field?
    @State private var tabMonitor: Any?

    private var canCreate: Bool {
        password.count >= 8 && password == confirm
    }

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "key.fill")
                .font(.system(size: 28))
                .foregroundStyle(Color.accentColor)
            Text("Create a master password")
                .font(.system(size: 14, weight: .semibold))
            Text("It opens your vault. There is no recovery: forgetting it loses every saved password.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
            SecureField("Master password (8+ characters)", text: $password)
                .textFieldStyle(.roundedBorder)
                .controlSize(.large)
                .frame(maxWidth: 300)
                .focused($focusedField, equals: .password)
            SecureField("Confirm master password", text: $confirm)
                .textFieldStyle(.roundedBorder)
                .controlSize(.large)
                .frame(maxWidth: 300)
                .focused($focusedField, equals: .confirm)
            TextField("Hint (optional)", text: $hint)
                .textFieldStyle(.roundedBorder)
                .controlSize(.large)
                .frame(maxWidth: 300)
                .focused($focusedField, equals: .hint)
            if let failure {
                Text(failure)
                    .font(.system(size: 12))
                    .foregroundStyle(.red)
            }
            Button("Create Vault") {
                Task { @MainActor in
                    failure = nil
                    if await store.setup(
                        master: password,
                        hint: hint.trimmingCharacters(in: .whitespacesAndNewlines)
                    ) {
                        password = ""
                        confirm = ""
                        hint = ""
                    } else {
                        failure = store.lastError ?? "The vault could not be created."
                    }
                }
            }
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .focused($focusedField, equals: .create)
            .disabled(!canCreate)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // The caret starts in the password field: typed-first, no click
        // needed. Delayed because the card presents asynchronously and a
        // focus set before the window has taken key is silently dropped.
        .task {
            try? await Task.sleep(for: .milliseconds(80))
            focusedField = .password
            try? await Task.sleep(for: .milliseconds(200))
            if focusedField == nil {
                focusedField = .password
            }
        }
        .onAppear {
            // Tab and Shift+Tab cycle the form explicitly. The fields'
            // AppKit editor eats Tab before SwiftUI's focus engine sees it,
            // so bindings alone leave Tab dead: this monitor runs first
            // (same mechanism as the presenter's Escape monitor) and
            // swallows only Tabs pressed while this form holds focus, so
            // Tab anywhere else in the window is untouched.
            guard tabMonitor == nil else { return }
            let focus = $focusedField
            tabMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                guard event.keyCode == 48 else { return event }
                let mods = event.modifierFlags.intersection([.shift, .control, .option, .command])
                guard mods == [] || mods == [.shift] else { return event }
                return MainActor.assumeIsolated { () -> NSEvent? in
                    guard focus.wrappedValue != nil else { return event }
                    let forward = !mods.contains(.shift)
                    focus.wrappedValue = forward ? nextSetupField(after: focus.wrappedValue) : previousSetupField(before: focus.wrappedValue)
                    return nil
                }
            }
        }
        .onDisappear {
            if let monitor = tabMonitor {
                NSEvent.removeMonitor(monitor)
                tabMonitor = nil
            }
        }
    }

    private func nextSetupField(after field: Field?) -> Field? {
        switch field {
        case .password: .confirm
        case .confirm: .hint
        case .hint: .create
        case .create: .password
        case nil: .password
        }
    }

    private func previousSetupField(before field: Field?) -> Field? {
        switch field {
        case .password: .create
        case .confirm: .password
        case .hint: .confirm
        case .create: .hint
        case nil: .password
        }
    }
}

/// Unlock form: one field, with "wrong password" answered plainly.
private struct PasswordUnlockView: View {
    @ObservedObject private var store = PasswordStore.shared
    @State private var password = ""
    @State private var wrongPassword = false
    @State private var failure: String?
    /// Consecutive wrong passwords this sitting. Past three, a kept hint is
    /// shown — the count lives here, not in the store, so it resets when the
    /// card closes.
    @State private var attempts = 0

    /// Tab order through the form, buttons included.
    private enum Field: Hashable {
        case password, unlock
    }

    @FocusState private var focusedField: Field?
    @State private var tabMonitor: Any?

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "lock.fill")
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
            Text("Unlock Passwords")
                .font(.system(size: 14, weight: .semibold))
            SecureField("Master password", text: $password)
                .textFieldStyle(.roundedBorder)
                .controlSize(.large)
                .frame(maxWidth: 300)
                .focused($focusedField, equals: .password)
            if wrongPassword {
                Text("Wrong master password, try again.")
                    .font(.system(size: 12))
                    .foregroundStyle(.red)
            } else if let failure {
                Text(failure)
                    .font(.system(size: 12))
                    .foregroundStyle(.red)
            }
            if attempts > 3, let hint = store.vaultHint {
                Text("Hint: \(hint)")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 340)
            }
            Button("Unlock") {
                Task { @MainActor in
                    await attempt()
                }
            }
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .focused($focusedField, equals: .unlock)
            .disabled(password.isEmpty)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // The caret starts in the password field. Delayed because the card
        // presents asynchronously and an early focus is silently dropped.
        .task {
            try? await Task.sleep(for: .milliseconds(80))
            focusedField = .password
            try? await Task.sleep(for: .milliseconds(200))
            if focusedField == nil {
                focusedField = .password
            }
        }
        .onAppear {
            // Explicit Tab cycling, like the setup form: the fields' AppKit
            // editor eats Tab before SwiftUI's focus engine sees it. Only
            // Tabs pressed while this form holds focus are swallowed.
            guard tabMonitor == nil else { return }
            let focus = $focusedField
            tabMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                guard event.keyCode == 48 else { return event }
                let mods = event.modifierFlags.intersection([.shift, .control, .option, .command])
                guard mods == [] || mods == [.shift] else { return event }
                return MainActor.assumeIsolated { () -> NSEvent? in
                    guard focus.wrappedValue != nil else { return event }
                    let forward = !mods.contains(.shift)
                    focus.wrappedValue = forward ? nextUnlockField(after: focus.wrappedValue) : previousUnlockField(before: focus.wrappedValue)
                    return nil
                }
            }
        }
        .onDisappear {
            if let monitor = tabMonitor {
                NSEvent.removeMonitor(monitor)
                tabMonitor = nil
            }
        }
    }

    private func nextUnlockField(after field: Field?) -> Field? {
        switch field {
        case .password: .unlock
        case .unlock: .password
        case nil: .password
        }
    }

    private func previousUnlockField(before field: Field?) -> Field? {
        switch field {
        case .password: .unlock
        case .unlock: .password
        case nil: .password
        }
    }

    private func attempt() async {
        wrongPassword = false
        failure = nil
        switch await store.unlock(master: password) {
        case .unlocked:
            password = ""
            attempts = 0
        case .wrongPassword:
            wrongPassword = true
            attempts += 1
            if attempts > 3 {
                await store.refreshHint()
            }
        case .failed(let message):
            failure = message
        }
    }
}

/// One site's editor: header fields plus its credential pairs.
private struct PasswordSiteDetail: View {
    @ObservedObject private var store = PasswordStore.shared
    let siteID: String
    let wordlist: [String] = PasswordGenerator.loadWordlist()

    /// Tab order through the detail, inputs only: name, URL, then each
    /// pair's username and password. Same story as the lock forms — the
    /// fields' AppKit editor eats Tab before SwiftUI's focus engine sees
    /// it — so the detail cycles one shared focus state explicitly.
    enum DetailField: Hashable {
        case name, url
        case username(String), password(String)
    }

    @FocusState private var focusedField: DetailField?
    @State private var tabMonitor: Any?

    @State private var name = ""
    @State private var url = ""
    @State private var saveTask: Task<Void, Never>?
    @State private var confirmingDelete = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                Divider()
                ForEach(site?.credentials ?? []) { credential in
                    PasswordCredentialRow(
                        siteID: siteID,
                        credentialID: credential.id,
                        wordlist: wordlist,
                        focus: $focusedField
                    )
                }
                Button {
                    _ = store.addCredential(to: siteID, username: "", password: "")
                } label: {
                    Label("Add another credential", systemImage: "plus")
                        .font(.system(size: 12))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 18)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear(perform: loadDrafts)
        .onChange(of: siteID) { loadDrafts() }
        .task(id: siteID) {
            await fetchFaviconIfMissing()
        }
        .alert("Delete \u{201C}\(site?.displayName ?? "this site")\u{201D}?", isPresented: $confirmingDelete) {
            Button("Delete", role: .destructive) {
                store.deleteSite(siteID)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The site and every credential in it will be removed. This cannot be reverted.")
        }
        .onAppear {
            // Explicit Tab cycling for the whole detail: one monitor, one
            // shared focus state, so Tab walks name → URL → each pair's
            // username → password and wraps around. Only Tabs pressed while
            // the detail holds focus are swallowed.
            guard tabMonitor == nil else { return }
            let focus = $focusedField
            tabMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [siteID] event in
                guard event.keyCode == 48 else { return event }
                let mods = event.modifierFlags.intersection([.shift, .control, .option, .command])
                guard mods == [] || mods == [.shift] else { return event }
                return MainActor.assumeIsolated { () -> NSEvent? in
                    let advanced = PasswordSiteDetail.advanceTab(
                        focus,
                        forward: !mods.contains(.shift),
                        siteID: siteID,
                        sites: PasswordStore.shared.vault.sites
                    )
                    return advanced ? nil : event
                }
            }
        }
        .onDisappear {
            if let monitor = tabMonitor {
                NSEvent.removeMonitor(monitor)
                tabMonitor = nil
            }
        }
    }

    /// The detail's Tab order: name, URL, then each pair's username and
    /// password in row order. Static and pure so the monitor always walks
    /// the current rows, even as pairs are added or removed.
    static func tabOrder(siteID: String, sites: [VaultSite]) -> [DetailField] {
        guard let site = sites.first(where: { $0.id == siteID }) else { return [.name, .url] }
        var order: [DetailField] = [.name, .url]
        for credential in site.credentials {
            order.append(.username(credential.id))
            order.append(.password(credential.id))
        }
        return order
    }

    /// Advances the shared focus one stop, wrapping around. Returns whether
    /// a stop was taken; false leaves the event to AppKit.
    static func advanceTab(
        _ focus: FocusState<DetailField?>.Binding,
        forward: Bool,
        siteID: String,
        sites: [VaultSite]
    ) -> Bool {
        guard focus.wrappedValue != nil else { return false }
        let order = tabOrder(siteID: siteID, sites: sites)
        guard !order.isEmpty else { return false }
        let index: Int
        if let current = focus.wrappedValue, let found = order.firstIndex(of: current) {
            index = found
        } else {
            index = forward ? order.count - 1 : 0
        }
        let step = forward ? 1 : -1
        focus.wrappedValue = order[(index + step + order.count) % order.count]
        return true
    }

    private var site: VaultSite? { store.site(siteID) }

    private var header: some View {
        HStack(alignment: .top, spacing: 10) {
            PasswordSiteIcon(base64: site?.favicon, size: 20)
            VStack(alignment: .leading, spacing: 8) {
                TextField("Site name", text: $name)
                    .font(.system(size: 13, weight: .semibold))
                    .textFieldStyle(.plain)
                    .focused($focusedField, equals: .name)
                    .onChange(of: name) { scheduleSave() }
                TextField("https://…", text: $url)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .textFieldStyle(.plain)
                    .focused($focusedField, equals: .url)
                    .onChange(of: url) { scheduleSave() }
            }
            Spacer(minLength: 8)
            Button {
                confirmingDelete = true
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .help("Delete this site and every credential in it")
        }
    }

    private func loadDrafts() {
        saveTask?.cancel()
        name = site?.name ?? ""
        url = site?.url ?? ""
    }

    /// One best-effort icon fetch per site: only when the site has an
    /// address but no icon yet, so an edited site never refetches.
    private func fetchFaviconIfMissing() async {
        guard let site, site.favicon == nil, let pageURL = URL(string: site.url) else { return }
        if let base64 = await SiteFaviconFetcher.fetchBase64(for: pageURL) {
            store.setSiteFavicon(siteID, base64: base64)
        }
    }

    /// Commits header edits debounced, like settings: typing never pays a
    /// seal + write per keystroke.
    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            store.updateSite(siteID, name: name, url: url)
        }
    }
}

/// A toolbar-like icon button for the credential rows: a fixed small frame
/// with a hover-only fill, so the eye/copy/generate trio reads as a button
/// list rather than three floating glyphs. Smaller than the toolbar's
/// buttons, same faint fill language.
private struct PasswordIconButton<Label: View>: View {
    let help: String
    let action: () -> Void
    let label: () -> Label

    @State private var hovering = false

    init(help: String, action: @escaping () -> Void, @ViewBuilder label: @escaping () -> Label) {
        self.help = help
        self.action = action
        self.label = label
    }

    var body: some View {
        Button(action: action) {
            label()
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 26, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color(nsColor: .labelColor).opacity(hovering ? 0.06 : 0))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { hovering = $0 }
    }
}

/// One credential pair: username and password fields with reveal, copy,
/// generate, strength, and delete.
private struct PasswordCredentialRow: View {
    @ObservedObject private var store = PasswordStore.shared
    let siteID: String
    let credentialID: String
    let wordlist: [String]
    /// The detail's shared focus state: Tab cycles it from the detail's
    /// monitor, so the row only binds its fields to it.
    let focus: FocusState<PasswordSiteDetail.DetailField?>.Binding

    @State private var username = ""
    @State private var password = ""
    @State private var revealed = false
    @State private var showGenerator = false
    @State private var strength: PasswordStrength?
    @State private var saveTask: Task<Void, Never>?
    @State private var confirmingDeleteCredential = false

    var body: some View {
        SettingsCard {
            VStack(alignment: .leading, spacing: 8) {
                labeledField("Username") {
                    HStack(spacing: 2) {
                        TextField("name@example.com", text: $username)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12))
                            .focused(focus, equals: .username(credentialID))
                            .onChange(of: username) { scheduleSave() }
                        PasswordIconButton(help: "Copy username", action: { copy(username) }) {
                            Image(systemName: "doc.on.doc")
                        }
                    }
                }
                labeledField("Password") {
                    HStack(spacing: 2) {
                        Group {
                            if revealed {
                                TextField("Password", text: $password)
                                    .focused(focus, equals: .password(credentialID))
                            } else {
                                SecureField("Password", text: $password)
                                    .focused(focus, equals: .password(credentialID))
                            }
                        }
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12))
                        .onChange(of: password) { scheduleSave() }
                        PasswordIconButton(
                            help: revealed ? "Hide password" : "Show password",
                            action: { revealed.toggle() }
                        ) {
                            Image(nsImage: revealImage)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(width: 14, height: 14)
                        }
                        PasswordIconButton(help: "Copy password", action: { copy(password) }) {
                            Image(systemName: "doc.on.doc")
                        }
                        PasswordIconButton(help: "Generate a password", action: { showGenerator.toggle() }) {
                            Image(nsImage: generateImage)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(width: 14, height: 14)
                        }
                    }
                }
                if showGenerator {
                    PasswordGeneratorPanel(wordlist: wordlist) { generated in
                        password = generated
                        scheduleSave()
                    }
                }
                HStack {
                    strengthMeter
                    Spacer(minLength: 8)
                    Button {
                        confirmingDeleteCredential = true
                    } label: {
                        Label("Delete credential", systemImage: "trash")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.borderless)
                    .help("Delete this credential")
                }
            }
        }
        .alert("Delete this credential?", isPresented: $confirmingDeleteCredential) {
            Button("Delete", role: .destructive) {
                store.deleteCredential(siteID: siteID, credentialID)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Are you sure? This cannot be reverted.")
        }
        .onAppear(perform: loadDrafts)
        .onChange(of: credentialID) { loadDrafts() }
        .task(id: password) {
            // Debounced by relaunch: every keystroke restarts the wait, so
            // the meter only scores settled text.
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            strength = password.isEmpty ? nil : await store.strength(of: password)
        }
    }

    private var revealImage: NSImage {
        let image = NSImage(named: revealed ? "EyeOff" : "Eye")
        image?.isTemplate = true
        return image ?? NSImage()
    }

    private var generateImage: NSImage {
        let image = NSImage(named: "CircleAsterisk")
        image?.isTemplate = true
        return image ?? NSImage()
    }

    @ViewBuilder
    private var strengthMeter: some View {
        if let strength {
            Text(strength.level.rawValue.capitalized)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(strengthColor(strength.level))
        }
    }

    private func strengthColor(_ level: PasswordStrength.Level) -> Color {
        switch level {
        case .weak: .red
        case .medium: .orange
        case .strong: .green
        }
    }

    private func labeledField<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            content()
        }
    }

    private func loadDrafts() {
        saveTask?.cancel()
        guard let credential = store.site(siteID)?.credentials.first(where: { $0.id == credentialID })
        else { return }
        username = credential.username
        password = credential.password
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            store.updateCredential(siteID: siteID, credentialID, username: username, password: password)
        }
    }

    private func copy(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }
}

/// The inline generator: mode, options, preview, regenerate, use.
private struct PasswordGeneratorPanel: View {
    enum Mode: String, CaseIterable, Identifiable {
        case characters
        case words

        var id: String { rawValue }
        var title: String { rawValue.capitalized }
    }

    let wordlist: [String]
    let onUse: (String) -> Void

    @State private var mode: Mode = .characters
    @State private var length = 20.0
    @State private var lowercase = true
    @State private var uppercase = true
    @State private var digits = true
    @State private var symbols = true
    @State private var wordCount = 4.0
    @State private var separator = "-"
    @State private var capitalize = false
    @State private var appendNumber = true
    @State private var preview = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Mode", selection: $mode) {
                ForEach(Mode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .onChange(of: mode) { regenerate() }
            if mode == .characters {
                HStack {
                    Text("Length: \(Int(length))")
                        .font(.system(size: 12))
                    Slider(value: $length, in: 8 ... 64, step: 1)
                        .onChange(of: length) { regenerate() }
                }
                toggles(
                    ("Lowercase", $lowercase),
                    ("Uppercase", $uppercase),
                    ("Digits", $digits),
                    ("Symbols", $symbols)
                )
            } else {
                HStack {
                    Text("Words: \(Int(wordCount))")
                        .font(.system(size: 12))
                    Slider(value: $wordCount, in: 3 ... 8, step: 1)
                        .onChange(of: wordCount) { regenerate() }
                }
                HStack {
                    Picker("Separator", selection: $separator) {
                        ForEach(PasswordGenerator.separatorChoices, id: \.self) { choice in
                            Text(separatorTitle(choice)).tag(choice)
                        }
                    }
                    .frame(maxWidth: 150)
                    .onChange(of: separator) { regenerate() }
                    Toggle("Capitalize", isOn: $capitalize)
                        .onChange(of: capitalize) { regenerate() }
                    Toggle("Number", isOn: $appendNumber)
                        .onChange(of: appendNumber) { regenerate() }
                }
                .font(.system(size: 12))
            }
            Text(preview.isEmpty ? "—" : preview)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color(nsColor: .textBackgroundColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                )
            HStack {
                Spacer()
                Button("Regenerate") { regenerate() }
                    .controlSize(.small)
                Button("Use") { onUse(preview) }
                    .controlSize(.small)
                    .keyboardShortcut(.defaultAction)
                    .disabled(preview.isEmpty)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .onAppear(perform: regenerate)
    }

    private func toggles(_ pairs: (String, Binding<Bool>)...) -> some View {
        HStack {
            ForEach(0 ..< pairs.count, id: \.self) { index in
                Toggle(pairs[index].0, isOn: pairs[index].1)
                    .onChange(of: pairs[index].1.wrappedValue) { regenerate() }
            }
        }
        .font(.system(size: 12))
    }

    private func separatorTitle(_ separator: String) -> String {
        switch separator {
        case "-": "Hyphen (-)"
        case "_": "Underscore (_)"
        case ".": "Dot (.)"
        case " ": "Space"
        case "": "None"
        default: separator
        }
    }

    private func regenerate() {
        var rng = SystemRandomNumberGenerator()
        switch mode {
        case .characters:
            preview = PasswordGenerator.characters(
                .init(
                    length: Int(length),
                    lowercase: lowercase,
                    uppercase: uppercase,
                    digits: digits,
                    symbols: symbols
                ),
                using: &rng
            )
        case .words:
            preview = PasswordGenerator.words(
                .init(
                    count: Int(wordCount),
                    separator: separator,
                    capitalize: capitalize,
                    appendNumber: appendNumber
                ),
                wordlist: wordlist,
                using: &rng
            )
        }
    }
}

/// Root view hosted in the window content.
///
/// Fills the window so the card centres over the whole window and
/// tap-outside covers the page, matching how the settings modal behaves.
struct PasswordManagerRootView: View {
    let stackID: PopupStackID
    let popupID: String

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
                await PasswordManagerPopup(stackID: stackID, popupID: popupID)
                    .present(popupStackID: stackID)
            }
    }
}

/// Routes Mijick's dismissal callback back to the presenter that owns the
/// hosting view. Popup structs must stay `Sendable`, so they cannot hold the
/// presenter directly.
@MainActor
final class PasswordManagerCoordinator {
    static let shared = PasswordManagerCoordinator()

    private var dismissHandlers: [String: () -> Void] = [:]

    func register(id: String, handler: @escaping () -> Void) {
        dismissHandlers[id] = handler
    }

    func popupDidDismiss(id: String) {
        dismissHandlers.removeValue(forKey: id)?()
    }
}

/// Bridges the window to Mijick/Popups for the password manager.
///
/// One presenter per window, owned by the content controller next to the
/// settings presenter. The window owns the modal's lifetime, so tab switches
/// do not dismiss it; Escape, tap-outside, and the toolbar button do. The
/// backdrop drag guard is copied from the settings modal because this card
/// also holds text fields: a selection drag that ends outside the card must
/// not count as a click on the backdrop.
@MainActor
final class PasswordManagerPresenter {
    /// How far the pointer may move between press and release while the
    /// release still counts as the click that dismisses the card.
    private static let backdropClickSlop: CGFloat = 6

    private weak var container: NSView?
    private var hostingView: NSHostingView<PasswordManagerRootView>?
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

    /// Opens the manager, or does nothing if it is already open.
    func present() {
        guard let container, container.window != nil, !isPresented else { return }
        resetForReuse()

        let stackID = PopupStackID(rawValue: "passwords-\(UUID().uuidString)")
        let popupID = "passwords"
        let root = PasswordManagerRootView(stackID: stackID, popupID: popupID)
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
        PasswordManagerCoordinator.shared.register(id: popupID) { [weak self] in
            self?.tearDown()
        }
    }

    func dismiss() {
        if let stackID {
            Task {
                await PopupStack.dismissAllPopups(popupStackID: stackID)
            }
        }
        tearDown()
    }

    /// Single teardown path, whether dismissal came from Escape, from
    /// Mijick's tap-outside layer, or from the owner.
    private func tearDown() {
        resetForReuse()
        let notify = onDidDismiss
        onDidDismiss = nil
        notify?()
    }

    /// Holds back the release that ends a drag which began on the backdrop.
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
    /// Same 720x520 card as settings, so the same box: the frame plus 88pt
    /// of shadow room above and below, expanded slightly.
    private func pressIsOnBackdrop(_ event: NSEvent) -> Bool {
        guard let container else { return false }
        let point = container.convert(event.locationInWindow, from: nil)
        let bounds = container.bounds
        let box = NSRect(
            x: (bounds.width - 736) / 2,
            y: (bounds.height - 712) / 2,
            width: 736,
            height: 712
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
