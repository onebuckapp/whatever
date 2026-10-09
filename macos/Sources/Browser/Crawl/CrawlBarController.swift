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

/// Owns the crawl bar's hosted view and its place in the window.
///
/// The bar is added to the window content only while it has something to
/// show; removing it (rather than hiding it) stops the `TimelineView`
/// animation entirely, so a disabled or empty crawl consumes nothing. The
/// owning content controller is told through `onVisibilityChanged` whenever
/// the bar enters or leaves, so it can re-pin the page area above the bar.
///
/// Mirrors `FindController`'s hide-not-remove idea, taken one step further:
/// the find bar stays parented while hidden because it is cheap when idle,
/// but a timeline animation is never cheap when idle.
@MainActor
final class CrawlBarController {
    let store = CrawlStore()

    /// Fires when the bar enters or leaves the window. The owner re-pins the
    /// page area and fixes sibling order in response.
    var onVisibilityChanged: (() -> Void)?
    /// Test seam: when non-nil, decides visibility instead of the settings
    /// toggle, so layout tests never touch the shared settings document.
    var forceEnabledForTesting: Bool? {
        didSet { refresh() }
    }
    /// Opens a tapped headline. Wired to the window's article opener.
    var onOpenArticle: ((URL) -> Void)?

    /// Whether the bar is currently parented in the window.
    var isVisible: Bool { tickerView?.superview != nil }
    /// The bar view, for sibling ordering. Nil until first shown.
    var barView: NSView? { tickerView }
    /// Height the bar currently occupies, including its bottom margin.
    var occupiedHeight: CGFloat {
        guard isVisible else { return 0 }
        return barHeight + Self.bottomMargin
    }

    private weak var container: NSView?
    /// The ticker, hosted directly rather than through SwiftUI.
    ///
    /// This used to be an `NSHostingView<CrawlTickerView>` and that hosting
    /// is the window-resize bug: SwiftUI's internal platform-host wrapper
    /// keeps a *required* frame width (`NSAutoresizingMaskLayoutConstraint`
    /// on `PlatformViewHost<PlatformViewRepresentableAdaptor<CrawlTickerView>>`),
    /// and AppKit grows the window to satisfy it. The ticker is plain AppKit
    /// already, so hosting it directly leaves only our own pins in charge of
    /// width and the failure mode cannot exist.
    private var tickerView: CrawlTickerNSView?
    private var heightConstraint: NSLayoutConstraint?
    /// Edge pins for the bar, re-activated on every add: AppKit drops a
    /// removed view's constraints from its old superview, so re-adding
    /// without re-activating would parent a constraint-less zero-size view.
    private var barConstraints: [NSLayoutConstraint] = []
    private var barHeight: CGFloat = 28
    private var cancellables = Set<AnyCancellable>()
    /// Last visibility reported to the owner. Compared against actual
    /// visibility on every refresh so the callback fires exactly on change,
    /// including the first show, where `install()` parents the view before
    /// any explicit add below could notice the transition.
    private var lastReportedVisible = false
    /// Signature of the last pushed root view. Pushes only happen on change:
    /// every slider tick emits settings, and rebuilding the hosted hierarchy
    /// per tick would restart layout and animation work for identical input.
    /// A struct rather than a tuple: tuples lose `==` past six elements.
    private struct PushSignature: Equatable {
        var headlines: [CrawlHeadline]
        var speed: Double
        var direction: AppSettings.CrawlDirection
        var fontSize: Double
        var opacity: Double
        var separator: String
        var faviconKeys: Set<String>
    }

    private var lastPush: PushSignature?
    /// Foreground-return observer; see `init`.
    private var foregroundObserver: Any?

    private static let sideMargin: CGFloat = 6
    private static let bottomMargin: CGFloat = 6

    init(container: NSView, onOpenArticle: ((URL) -> Void)? = nil) {
        self.container = container
        self.onOpenArticle = onOpenArticle
        store.startObserving()
        SettingsStore.shared.$settings
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &cancellables)
        store.$headlines
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &cancellables)
        // Favicon arrivals change the pushed signature through their keys,
        // so icons pop in without touching the loop inputs.
        store.$faviconImages
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &cancellables)
        // Returning to the foreground restarts the loop from the leading
        // edge, which also recovers the loop if it ever missed its start.
        // (The SwiftUI wrapper this replaced watched scene phase for the
        // same reason.)
        foregroundObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let ticker = self.tickerView, !ticker.isHalted else { return }
                ticker.startLoop(fromStart: true)
            }
        }
        refresh()
    }

    deinit {
        if let foregroundObserver {
            NotificationCenter.default.removeObserver(foregroundObserver)
        }
    }

    /// Moves the bar above the page without disturbing the grain overlay's
    /// front-most seat. Called after any sibling shuffle (tab switches,
    /// popup hosts) that may have covered it.
    func bringToFront() {
        guard let container, let tickerView, tickerView.superview === container else { return }
        container.addSubview(tickerView, positioned: .above, relativeTo: nil)
    }

    private func refresh() {
        let feeds = SettingsStore.shared.settings.feeds
        barHeight = min(max(feeds.crawlBarHeight, 18), 64)
        let enabled = forceEnabledForTesting ?? feeds.crawlEnabled
        let shouldShow = enabled && !store.headlines.isEmpty
        if shouldShow {
            if tickerView == nil {
                install(feeds: feeds)
            }
            heightConstraint?.constant = barHeight
            // Value inputs: push the latest headlines and settings into the
            // ticker, but only when something actually changed. The onOpen
            // closure is fresh every time by construction and is not part of
            // the comparison.
            let signature = PushSignature(
                headlines: store.headlines,
                speed: feeds.crawlSpeed,
                direction: feeds.crawlDirection,
                fontSize: feeds.crawlFontSize,
                opacity: feeds.crawlBackgroundOpacity,
                separator: feeds.crawlSeparator,
                faviconKeys: Set(store.faviconImages.keys)
            )
            if lastPush.map({ $0 != signature }) ?? true {
                lastPush = signature
                push(feeds: feeds)
            }
        } else {
            lastPush = nil
        }
        // Reconcile against where the view actually is: `install()` parents
        // it as a side effect, so testing `isVisible` after the fact is the
        // only transition check that cannot miss the first show.
        if shouldShow, !isVisible, let container, let tickerView {
            container.addSubview(tickerView)
            NSLayoutConstraint.activate(barConstraints)
            bringToFront()
        } else if !shouldShow, isVisible {
            freezeAndDetach()
        }
        let nowVisible = isVisible
        if nowVisible != lastReportedVisible {
            lastReportedVisible = nowVisible
            onVisibilityChanged?()
        }
        // The feature is on but nothing is cached yet: read the store. The
        // in-flight guard in the store keeps slider drags from piling up
        // round trips; failures simply leave us empty, which keeps us hidden.
        if enabled, store.headlines.isEmpty {
            Task { await store.load() }
        }
    }

    /// Hides the bar in two phases: first the strip's animation is cancelled
    /// explicitly, then — on the next runloop turn, after the freeze commits —
    /// the bar leaves the hierarchy. Tearing down a live repeat-forever
    /// animation together with its layers blanked sibling content until the
    /// next full re-layout; this ordering never does both at once. If the bar
    /// is wanted again before the deferred detach runs, the detach is skipped
    /// and the fresh show path un-halts and restarts the loop.
    private func freezeAndDetach() {
        guard let tickerView else { return }
        tickerView.setHalted(true)
        lastPush = nil
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let feeds = SettingsStore.shared.settings.feeds
            let enabled = self.forceEnabledForTesting ?? feeds.crawlEnabled
            guard !enabled || self.store.headlines.isEmpty else { return }
            self.tickerView?.removeFromSuperview()
            let nowVisible = self.isVisible
            if nowVisible != self.lastReportedVisible {
                self.lastReportedVisible = nowVisible
                self.onVisibilityChanged?()
            }
        }
    }
    /// The inputs the ticker renders from. `fontSize` carries the user's
    /// text-size scale, read at push time; the settings tick that changes
    /// the stored size also re-pushes.
    private func makeInputs(feeds: AppSettings.FeedSettings) -> CrawlTickerInputs {
        CrawlTickerInputs(
            headlines: store.headlines,
            speed: feeds.crawlSpeed,
            direction: feeds.crawlDirection,
            fontSize: feeds.crawlFontSize * Self.typeScale,
            backgroundOpacity: feeds.crawlBackgroundOpacity,
            favicons: store.faviconImages,
            separator: feeds.crawlSeparator
        )
    }

    /// Room for the user's text size, the way the SwiftUI wrapper's
    /// `@ScaledMetric` did before the ticker was hosted directly.
    /// `preferredFont(forTextStyle: .body)` tracks the accessibility text
    /// size; at the default it equals `systemFontSize`, so the scale is 1.
    private static var typeScale: CGFloat {
        CGFloat(NSFont.preferredFont(forTextStyle: .body).pointSize / max(1, NSFont.systemFontSize))
    }

    /// Pushes fresh inputs into the ticker and makes sure a halted ticker
    /// (hidden, then wanted again) resumes. The un-halt is guarded: an
    /// unconditional `setHalted(false)` would restart the loop on every
    /// push, including favicon arrivals that only change a few icons.
    private func push(feeds: AppSettings.FeedSettings) {
        guard let tickerView else { return }
        tickerView.onOpen = { [weak self] url in self?.openHeadline(url) }
        if tickerView.isHalted {
            tickerView.setHalted(false)
        }
        tickerView.update(with: makeInputs(feeds: feeds))
    }

    /// A ticker tap always reads the item: it leaves the unread-only bar at
    /// once, persists behind the navigation, and the opener takes it from
    /// there. An unknown URL (stale loop, rebuilt list) still navigates.
    private func openHeadline(_ url: URL) {
        if let headline = store.headlines.first(where: { $0.url == url.absoluteString }) {
            store.markReadAndDrop(headline)
        }
        onOpenArticle?(url)
    }

    private func install(feeds: AppSettings.FeedSettings) {
        let ticker = CrawlTickerNSView()
        // Layer-managed and drew-nothing-of-its-own, like its predecessor:
        // the pill comes from its own background layer, so the corners stay
        // transparent onto the page beneath.
        ticker.translatesAutoresizingMaskIntoConstraints = false
        ticker.onOpen = { [weak self] url in self?.openHeadline(url) }
        ticker.update(with: makeInputs(feeds: feeds))
        guard let container else { return }
        container.addSubview(ticker)
        heightConstraint = ticker.heightAnchor.constraint(equalToConstant: barHeight)
        barConstraints = [
            ticker.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: Self.sideMargin),
            ticker.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -Self.sideMargin),
            ticker.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -Self.bottomMargin),
            heightConstraint!,
        ]
        NSLayoutConstraint.activate(barConstraints)
        tickerView = ticker
    }
}
