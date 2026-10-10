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
import WebKit

/// What the site-information card shows for one tab: connection state and
/// the captured certificate. A snapshot, because popup structs must stay
/// `Sendable` and cannot hold the tab. The site's stored data rides a
/// loader object instead (see below), so counts stream in without
/// re-presenting the card.
struct SiteInfoSnapshot: Equatable, Sendable {
    /// Lowercased page host, or nil for pages without one.
    var host: String?
    /// Whether the page arrived over HTTPS. Only then is there a
    /// certificate to show.
    var isSecureConnection: Bool
    var certificate: SiteCertificateInfo?
}

/// Enumerates a site's stored cookies and data in the background and
/// publishes the counts, then removes them on request.
///
/// A `@MainActor` class, so — unlike the presenter — it can travel inside
/// the `Sendable` popup structs down to the card, which observes it. The
/// store walk can take seconds on a large profile: the card paints
/// instantly with a loader, and these publishes swap the counts in with
/// no dismiss/re-present cycle (re-hosting the tree tears it down through
/// `onDismiss`, which reads as the popup closing itself).
@MainActor
final class SiteInfoDataLoader: ObservableObject {
    @Published private(set) var isLoading = true
    @Published private(set) var cookies = 0
    @Published private(set) var other = 0

    private weak var tab: BrowserTab?
    private let host: String?
    private var records: [WKWebsiteDataRecord] = []
    /// Clear went out, possibly before the fetch landed. The fetch
    /// completion removes rather than publishes in that case.
    private var cleared = false

    init(tab: BrowserTab, host: String?) {
        self.tab = tab
        self.host = host
    }

    /// Starts the store walk. Publishes zeroes, not a hang, when there is
    /// no host to enumerate.
    func load() {
        guard let tab, let host, !host.isEmpty else {
            isLoading = false
            return
        }
        let store = tab.websiteDataStore
        store.fetchDataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes()) { [weak self] records in
            Task { @MainActor [weak self] in
                self?.finish(records.filter { Self.belongsToHost($0, host: host) })
            }
        }
    }

    /// Zeroes the counts and removes the fetched records. Safe before the
    /// fetch lands: the late records are removed on arrival instead.
    func clear() {
        cleared = true
        cookies = 0
        other = 0
        isLoading = false
        guard !records.isEmpty, let tab else {
            records = []
            return
        }
        let doomed = records
        records = []
        let store = tab.websiteDataStore
        Task {
            await store.removeData(
                ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
                for: doomed
            )
        }
    }

    private func finish(_ records: [WKWebsiteDataRecord]) {
        if cleared {
            if !records.isEmpty, let tab {
                let store = tab.websiteDataStore
                Task {
                    await store.removeData(
                        ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
                        for: records
                    )
                }
            }
            return
        }
        self.records = records
        var cookies = 0
        var other = 0
        for record in records {
            if record.dataTypes.contains(WKWebsiteDataTypeCookies) {
                cookies += 1
            }
            if !record.dataTypes.isSubset(of: [WKWebsiteDataTypeCookies]) {
                other += 1
            }
        }
        self.cookies = cookies
        self.other = other
        isLoading = false
    }

    /// Whether a data record belongs to `host`: its own name or a
    /// subdomain's. A nil host owns nothing.
    static func belongsToHost(_ record: WKWebsiteDataRecord, host: String?) -> Bool {
        guard let host, !host.isEmpty else { return false }
        let name = record.displayName.lowercased()
        return name == host || name.hasSuffix("." + host)
    }
}

/// Per-site card: connection state, certificate details, the site's
/// cookies and data with a way to clear them, and a way into Settings.
///
/// Presented by Mijick/Popups like the content-blocker card: a small
/// centered card over a transparent backdrop, tap-outside to dismiss.
/// Shielded like every other card while up.
struct SiteInfoPopup: CenterPopup {
    let stackID: PopupStackID
    let popupID: String
    let snapshot: SiteInfoSnapshot
    let loader: SiteInfoDataLoader

    func configurePopup(config: CenterPopupConfig) -> CenterPopupConfig {
        config
            .backgroundColor(.clear)
            .cornerRadius(20)
            .overlayColor(.clear)
            .tapOutsideToDismissPopup(true)
    }

    func onDismiss() {
        Task { @MainActor in
            SiteInfoPopupCoordinator.shared.popupDidDismiss(id: popupID)
        }
    }

    var body: some View {
        SiteInfoPopupCard(
            snapshot: snapshot,
            loader: loader,
            onManage: {
                Task { @MainActor in
                    SiteInfoPopupCoordinator.shared.manageTapped(id: popupID)
                }
            }
        )
        .frame(width: 300)
        .background(Color(nsColor: .windowBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .shadow(color: .black.opacity(0.34), radius: 18, x: 0, y: 10)
        .shadow(color: .black.opacity(0.58), radius: 25, x: 0, y: 30)
        // Mijick masks the popup to its measured bounds, so the shadows
        // need transparent room; the padding is symmetric, so the card
        // stays centered.
        .padding(.vertical, 88)
        // Consume taps on the card itself, as every sibling card does, so a
        // click on empty card space cannot reach the tap-outside layer.
        // Deliberately a no-op rather than a dismissal like the QR card's:
        // this card holds live controls, and clicking them must not close it.
        .onTapGesture {}
        .onExitCommand {
            Task {
                await PopupStack.dismissPopup(popupID, popupStackID: stackID)
            }
        }
    }
}

/// The card itself: an ordinary view, observing the loader for the counts
/// and the snapshot for everything else. The popup struct above stays
/// `Sendable` with lets only — the loader's `@MainActor` isolation is
/// what makes holding it legal.
private struct SiteInfoPopupCard: View {
    let snapshot: SiteInfoSnapshot
    @ObservedObject var loader: SiteInfoDataLoader
    let onManage: () -> Void

    init(
        snapshot: SiteInfoSnapshot,
        loader: SiteInfoDataLoader,
        onManage: @escaping () -> Void
    ) {
        self.snapshot = snapshot
        self.loader = loader
        self.onManage = onManage
    }

    private var hasData: Bool {
        loader.cookies > 0 || loader.other > 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            Divider()
            certificateSection
            Divider()
            dataSection
            Divider()
            Button(action: onManage) {
                HStack {
                    Text("Site settings")
                        .font(.system(size: 12))
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(16)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: snapshot.isSecureConnection ? "lock.fill" : "lock.slash")
                .font(.system(size: 22))
                .foregroundStyle(snapshot.isSecureConnection ? Color.accentColor : Color.secondary)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(snapshot.host ?? "This page")
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(connectionLine)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var connectionLine: String {
        guard snapshot.host != nil else {
            return "Open a website to inspect it here."
        }
        return snapshot.isSecureConnection
            ? "Connection is secure."
            : "Connection is not secure."
    }

    @ViewBuilder
    private var certificateSection: some View {
        if !snapshot.isSecureConnection || snapshot.host == nil {
            Text("This page is not loaded over HTTPS, so there is no certificate to show.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } else if let certificate = snapshot.certificate {
            VStack(alignment: .leading, spacing: 4) {
                Text("Certificate")
                    .font(.system(size: 12, weight: .medium))
                detailRow("Issued to", certificate.subject ?? "Unknown")
                detailRow("Issued by", certificate.issuer ?? "Unknown")
                if let validUntil = certificate.validUntil {
                    detailRow("Expires", SiteCertificateInfo.displayDate(validUntil))
                }
                if let fingerprint = certificate.sha256Fingerprint {
                    detailRow("Fingerprint", fingerprint)
                }
            }
        } else {
            Text("Certificate details are not available for this visit.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func detailRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 76, alignment: .leading)
            Text(value)
                .font(.system(size: 11, design: .monospaced))
                .lineLimit(2)
                .truncationMode(.middle)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var dataSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Cookies and site data")
                .font(.system(size: 12, weight: .medium))
            if loader.isLoading {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Loading site data.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            } else {
                HStack(alignment: .firstTextBaseline) {
                    Text(dataLine)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    Button("Clear") {
                        loader.clear()
                    }
                    .controlSize(.small)
                    .disabled(!hasData)
                }
            }
        }
    }

    private var dataLine: String {
        switch (loader.cookies, loader.other) {
        case (0, 0):
            "No stored data for this site."
        case let (cookies, other):
            "\(count(cookies, singular: "cookie")) · \(count(other, singular: "item"))"
        }
    }

    private func count(_ n: Int, singular: String) -> String {
        n == 1 ? "1 \(singular)" : "\(n) \(singular)s"
    }
}

/// Root view hosted in the window content.
///
/// Fills the window so the card centres over the whole window and
/// tap-outside covers the page, matching how the settings modal behaves.
struct SiteInfoPopupRootView: View {
    let stackID: PopupStackID
    let popupID: String
    let snapshot: SiteInfoSnapshot
    let loader: SiteInfoDataLoader

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
                await SiteInfoPopup(stackID: stackID, popupID: popupID, snapshot: snapshot, loader: loader)
                    .present(popupStackID: stackID)
            }
    }
}

/// Routes Mijick's callbacks back to the presenter that owns the hosting
/// view. Popup structs must stay `Sendable`, so they cannot hold the
/// presenter directly; the manage tap travels the same road as dismissal.
@MainActor
final class SiteInfoPopupCoordinator {
    static let shared = SiteInfoPopupCoordinator()

    private var dismissHandlers: [String: () -> Void] = [:]
    private var manageHandlers: [String: () -> Void] = [:]

    func register(
        id: String,
        onDismiss: @escaping () -> Void,
        onManage: @escaping () -> Void
    ) {
        dismissHandlers[id] = onDismiss
        manageHandlers[id] = onManage
    }

    func popupDidDismiss(id: String) {
        dismissHandlers.removeValue(forKey: id)?()
        manageHandlers.removeValue(forKey: id)
    }

    func manageTapped(id: String) {
        manageHandlers.removeValue(forKey: id)?()
    }
}

/// Bridges the window to Mijick/Popups for the per-site card.
///
/// One presenter per window, owned by the content controller next to the
/// content-blocker presenter. The card paints on open; the loader streams
/// the counts in through publishes, so nothing is ever re-presented.
@MainActor
final class SiteInfoPopupPresenter {
    private weak var container: NSView?
    private weak var tab: BrowserTab?
    private var hostingView: NSHostingView<SiteInfoPopupRootView>?
    private var stackID: PopupStackID?
    private var escapeMonitor: Any?
    private var onDidDismiss: (() -> Void)?
    private var onManage: (() -> Void)?

    init(
        container: NSView,
        tab: BrowserTab,
        onDidDismiss: (() -> Void)? = nil,
        onManage: (() -> Void)? = nil
    ) {
        self.container = container
        self.tab = tab
        self.onDidDismiss = onDidDismiss
        self.onManage = onManage
    }

    var isPresented: Bool {
        hostingView?.superview != nil
    }

    /// Opens the card for `tab`'s page. Paints immediately; the loader
    /// streams the counts in through publishes, so the store walk never
    /// holds the card back and nothing is ever re-presented.
    func present() {
        guard let container, container.window != nil, let tab, !isPresented else { return }
        resetForReuse()
        let loader = SiteInfoDataLoader(tab: tab, host: tab.displayURL.host?.lowercased())
        loader.load()
        install(container: container, tab: tab, loader: loader)
    }

    private func install(container: NSView, tab: BrowserTab, loader: SiteInfoDataLoader) {
        let snapshot = SiteInfoSnapshot(
            host: tab.displayURL.host?.lowercased(),
            isSecureConnection: tab.displayURL.scheme?.lowercased() == "https",
            certificate: tab.tabController.siteCertificate
        )
        let stackID = PopupStackID(rawValue: "site-info-\(UUID().uuidString)")
        let popupID = "site-info-\(UUID().uuidString)"
        let root = SiteInfoPopupRootView(stackID: stackID, popupID: popupID, snapshot: snapshot, loader: loader)
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
                Task { @MainActor [weak self] in
                    self?.dismiss()
                }
                return nil
            }
            return event
        }
        SiteInfoPopupCoordinator.shared.register(
            id: popupID,
            onDismiss: { [weak self] in self?.tearDown() },
            onManage: { [weak self] in self?.manage() }
        )
    }

    func dismiss() {
        if let stackID {
            Task {
                await PopupStack.dismissAllPopups(popupStackID: stackID)
            }
        }
        tearDown()
    }

    /// Trades the card for the full settings: dismiss first, then let the
    /// owner open settings, so the two never stack.
    ///
    /// The handler is captured before the dismiss, not after: teardown nils
    /// every handler, so reading it afterwards always finds nothing and the
    /// settings tap silently does nothing.
    func manage() {
        let manage = onManage
        onManage = nil
        dismiss()
        manage?()
    }

    /// Single teardown path, whether dismissal came from Escape, from
    /// Mijick's tap-outside layer, or from the owner.
    private func tearDown() {
        resetForReuse()
        let notify = onDidDismiss
        onDidDismiss = nil
        onManage = nil
        notify?()
    }

    /// Drops the host without notifying the owner, so a re-present cannot clear
    /// the owner's reference to this presenter mid-present.
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
        hostingView?.removeFromSuperview()
        hostingView = nil
        stackID = nil
    }

    deinit {
        if let escapeMonitor {
            NSEvent.removeMonitor(escapeMonitor)
        }
    }
}
