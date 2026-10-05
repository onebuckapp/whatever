import AppKit
import Combine
import WebKit

/// Owns one pane's find-in-page bar and the search pipeline behind it.
///
/// One controller per pane, created lazily on the first Cmd+F: each tab keeps
/// its own query and highlights while its pane sits in the cache. The bar
/// reports keystrokes, steps and option flips upward; everything else —
/// debounce, the extract → match → apply round trip, the count label, and
/// re-searching after the page settles — lives here.
///
/// The pipeline never trusts a late answer: `generation` invalidates every
/// in-flight step when a new one starts, and each stage re-checks that the
/// tab still shows the web view it started from, so a slow extraction for a
/// page the tab already left cannot paint that page's highlights.
@MainActor
final class FindController {
    /// Matches the core's cap: what is sent is also what can come back.
    private static let matchLimit = 2000
    /// Keystrokes settle this long before a search runs.
    private static let debounceNanos: UInt64 = 150_000_000

    private let tab: BrowserTab
    private weak var container: NSView?
    private weak var pageContainer: NSView?
    private var pageBottomConstraint: NSLayoutConstraint?
    private var openConstraint: NSLayoutConstraint?
    private var bar: FindBarView?
    private var cancellables = Set<AnyCancellable>()
    private var pendingSearch: Task<Void, Never>?

    /// Invalidated whenever a new search, step or close starts.
    private var generation = 0
    /// The page the live highlights were computed for. Anything else means
    /// the highlights are dead, even if the spans are still in the DOM.
    private var searchedURL: URL?
    /// Whether the page currently holds highlights this controller placed.
    private var highlightsLive = false
    private var lastTotal = 0
    private var lastHasMore = false

    var isOpen: Bool {
        bar?.superview != nil
    }

    /// - Parameters:
    ///   - container: the pane root view the bar is installed into.
    ///   - pageContainer: the page holder the bar sits below.
    ///   - pageBottomConstraint: the active constraint pinning the page
    ///     holder to the pane bottom, deactivated while the bar is open.
    init(tab: BrowserTab, container: NSView, pageContainer: NSView, pageBottomConstraint: NSLayoutConstraint) {
        self.tab = tab
        self.container = container
        self.pageContainer = pageContainer
        self.pageBottomConstraint = pageBottomConstraint
        Publishers.CombineLatest(tab.tabController.$url, tab.tabController.$isLoading)
            .sink { [weak self] url, loading in
                self?.pageDidSettle(url: url, loading: loading)
            }
            .store(in: &cancellables)
    }

    deinit {
        pendingSearch?.cancel()
    }

    // MARK: - Bar visibility

    func show() {
        guard let container, let pageContainer else { return }
        if bar == nil {
            let bar = FindBarView()
            bar.translatesAutoresizingMaskIntoConstraints = false
            bar.isHidden = true
            bar.onQueryChanged = { [weak self] _ in self?.queryDidChange() }
            bar.onNext = { [weak self] in self?.step(1) }
            bar.onPrevious = { [weak self] in self?.step(-1) }
            bar.onOptionsChanged = { [weak self] in self?.optionsDidChange() }
            bar.onClose = { [weak self] in self?.close() }
            container.addSubview(bar)
            NSLayoutConstraint.activate([
                bar.leadingAnchor.constraint(equalTo: pageContainer.leadingAnchor),
                bar.trailingAnchor.constraint(equalTo: pageContainer.trailingAnchor),
                bar.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -6),
            ])
            self.bar = bar
        }
        guard let bar, bar.superview != nil else { return }
        pageBottomConstraint?.isActive = false
        if openConstraint == nil {
            openConstraint = pageContainer.bottomAnchor.constraint(equalTo: bar.topAnchor, constant: -6)
        }
        openConstraint?.isActive = true
        bar.isHidden = false
        bar.focusQuery()
        // Reopening over a previous query re-seats the highlights: the page
        // may have changed while the bar was closed.
        if !bar.queryField.stringValue.isEmpty, !highlightsLive {
            Task { [weak self] in await self?.performSearch() }
        }
    }

    func close() {
        guard isOpen else { return }
        generation += 1
        pendingSearch?.cancel()
        pendingSearch = nil
        highlightsLive = false
        searchedURL = nil
        if let webView = tab.webView {
            Task { [weak webView] in
                try? await webView?.evaluateJavaScript("window.__whtvrFind && window.__whtvrFind.clear()")
            }
        }
        openConstraint?.isActive = false
        pageBottomConstraint?.isActive = true
        bar?.isHidden = true
        // Focus goes back to the page, not to whatever held it before: the
        // bar stole it when it opened, and Escape promises to give it back.
        if let webView = tab.webView {
            container?.window?.makeFirstResponder(webView)
        }
    }

    // MARK: - Search

    func step(_ delta: Int) {
        Task { [weak self] in await self?.performStep(delta) }
    }

    private func queryDidChange() {
        highlightsLive = false
        pendingSearch?.cancel()
        pendingSearch = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.debounceNanos)
            guard let self, !Task.isCancelled else { return }
            await self.performSearch()
            self.pendingSearch = nil
        }
    }

    private func optionsDidChange() {
        highlightsLive = false
        pendingSearch?.cancel()
        pendingSearch = nil
        Task { [weak self] in await self?.performSearch() }
    }

    private func performStep(_ delta: Int) async {
        guard let bar, !(bar.queryField.stringValue.isEmpty) else { return }
        // A step wins over a still-debouncing keystroke: the user already
        // committed to moving.
        pendingSearch?.cancel()
        pendingSearch = nil
        if highlightsLive, let webView = tab.webView {
            generation += 1
            let gen = generation
            let raw = try? await webView.evaluateJavaScript("window.__whtvrFind.step(\(delta))")
            guard gen == generation, webView === self.tab.webView else { return }
            guard let result = raw as? [String: Any], !(result["stale"] as? Bool ?? false) else {
                // The page mutated under the highlights; restart from the
                // first match rather than stepping through dead spans.
                await self.performSearch()
                return
            }
            updateCount(index: result["index"] as? Int, count: result["count"] as? Int)
            return
        }
        await performSearch()
        // Shift+Enter on a fresh search wraps to the last match, the way
        // stepping back from the first would.
        if delta < 0, highlightsLive {
            await performStep(delta)
        }
    }

    private func performSearch(initialIndex: Int = 0) async {
        generation += 1
        let gen = generation
        guard let bar, let webView = tab.webView else { return }
        let query = bar.queryField.stringValue
        guard !query.isEmpty else {
            clearInPage(webView)
            bar.setCount("")
            searchedURL = nil
            return
        }
        let highlightAll = bar.highlightAllBox.state == .on
        let matchCase = bar.matchCaseBox.state == .on
        let wholeWords = bar.wholeWordsBox.state == .on
        guard let rawExtract = try? await webView.evaluateJavaScript(
            "window.__whtvrFind && window.__whtvrFind.extractText()"
        ),
            gen == generation, webView === self.tab.webView,
            let extract = rawExtract as? [String: Any],
            let text = extract["text"] as? String
        else {
            // The bridge is not evaluated yet (a page still loading) or
            // the tab moved on; the settle observation re-runs this when
            // there is a document to search.
            return
        }
        searchedURL = webView.url
        guard let found = try? await BrowserCore.findMatches(
            text: text,
            query: query,
            matchCase: matchCase,
            wholeWords: wholeWords,
            limit: Self.matchLimit
        ),
            gen == generation, webView === self.tab.webView
        else {
            return
        }
        lastTotal = found.total
        lastHasMore = found.hasMore
        let payload = ApplyPayload(
            ranges: found.matches.map { [$0.start, $0.stop] },
            highlightAll: highlightAll,
            index: initialIndex
        )
        guard let payloadJSON = String(
            data: (try? JSONEncoder().encode(payload)) ?? Data(),
            encoding: .utf8
        ), !payloadJSON.isEmpty else {
            return
        }
        guard let rawApply = try? await webView.evaluateJavaScript(
            "window.__whtvrFind.applyMatches(\(payloadJSON))"
        ),
            gen == generation, webView === self.tab.webView,
            let applied = rawApply as? [String: Any],
            !(applied["stale"] as? Bool ?? false)
        else {
            // Mutated between extraction and application; one fresh pass,
            // not a loop — a continuously mutating page would never settle.
            if gen == generation, webView === self.tab.webView {
                searchedURL = nil
                await self.performSearchRetry(gen: gen)
            }
            return
        }
        highlightsLive = (applied["count"] as? Int ?? 0) > 0
        updateCount(index: applied["index"] as? Int, count: applied["count"] as? Int)
    }

    /// The single permitted retry for an extract→apply race. Not a loop:
    /// `performSearch` bumps `generation`, so a second collision lands here
    /// with a dead generation and stops.
    private func performSearchRetry(gen: Int) async {
        guard gen == generation else { return }
        generation += 1
        await performSearch()
    }

    private func clearInPage(_ webView: WKWebView) {
        highlightsLive = false
        Task { [weak webView] in
            try? await webView?.evaluateJavaScript("window.__whtvrFind && window.__whtvrFind.clear()")
        }
    }

    private func updateCount(index: Int?, count: Int?) {
        guard let bar else { return }
        guard let count, count > 0, let index, index >= 0 else {
            bar.setCount(queryIsEmpty ? "" : "No results")
            return
        }
        // The JS count is the wrapped (kept) matches; the core total can be
        // larger when the limit cut the list.
        let total = lastHasMore ? lastTotal : count
        bar.setCount("\(index + 1) of \(total)\(lastHasMore ? "+" : "")")
    }

    private var queryIsEmpty: Bool {
        bar?.queryField.stringValue.isEmpty ?? true
    }

    // MARK: - Page tracking

    /// Follows the tab's committed page. A URL change resets the highlights —
    /// same-document fragment moves included, since the spans belong to the
    /// previous state — and a settled page with an open bar and a query
    /// re-searches itself, so navigation never leaves dead highlights behind.
    private func pageDidSettle(url: URL?, loading: Bool) {
        if loading {
            // The document is being replaced; anything placed is gone with it.
            // The settle below re-searches once there is text to search.
            if searchedURL != nil {
                searchedURL = nil
                highlightsLive = false
            }
            return
        }
        guard url != searchedURL else { return }
        searchedURL = nil
        highlightsLive = false
        if isOpen, !(bar?.queryField.stringValue.isEmpty ?? true) {
            Task { [weak self] in await self?.performSearch() }
        } else {
            bar?.setCount("")
        }
    }
}

/// The argument to the bridge's `applyMatches`: the core's ranges in order,
/// whether to wrap them all, and which one selects first.
private struct ApplyPayload: Encodable {
    let ranges: [[Int]]
    let highlightAll: Bool
    let index: Int
}
