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

import Foundation
import Network
import Testing
import WebKit
@testable import Whatever

/// Tracker entries must leave the tab's back/forward list however they got
/// in — appended by a fresh commit or landed on without appending (Back
/// onto a redirector, a restored entry, a re-committed bounce). The latter
/// dedups in `noteCommitted` and used to skip the Nim check entirely, so a
/// Google `/url` hop survived forever and Back bounced off it in a loop.
@MainActor
struct BrowserTabTrackerTests {
    private static let serp = URL(string: "https://www.google.com/search?q=reteta")!
    private static let tracker = URL(
        string: "https://www.google.com/url?opi=89978449&q=https://www.la-doi-pasi.ro/reteta/reteta-simpla-de-pine-de-casa.html&sa=U&ved=2ahUKEwiIhdfIorKXAxUsAtsEHeMuO4cQFnoECAcQAg&usg=AOvVaw3NHicRD7y6Bf5B1Zm2lKJ3"
    )!
    private static let destination = URL(string: "https://www.la-doi-pasi.ro/reteta/reteta-simpla-de-pine-de-casa.html")!

    private final class StubHistory: HistoryRecording {
        func record(url: URL, title: String?) {}
    }

    private func makeTab(answering record: Bool) -> BrowserTab {
        let tab = BrowserTab(history: StubHistory(), initialURL: Self.serp)
        tab.historyShouldRecord = { _ in record }
        return tab
    }

    /// The resolve runs off-thread through the store; poll rather than
    /// sleep a fixed span.
    private func waitFor(
        _ description: String,
        timeout: Duration = .seconds(5),
        _ condition: () -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            if ContinuousClock.now >= deadline {
                Issue.record("timed out waiting for \(description)")
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test("an appended tracker still drops")
    func appendedTrackerDrops() async throws {
        let tab = makeTab(answering: false)
        tab.noteCommitted(url: Self.tracker)
        try await waitFor("the appended tracker to drop") {
            tab.historySnapshot().urls == [Self.serp]
        }
        #expect(tab.historySnapshot().urls == [Self.serp])
        #expect(tab.currentURL == Self.serp)
    }

    @Test("landing on a tracker without appending still drops it")
    func dedupedTrackerDrops() async throws {
        // Seed [serp, tracker] with the check answering record, as a fresh
        // commit does; the entry is current, so the next commit dedups.
        // Answers are FIFO so the test is order-proof: whichever task runs
        // first gets record, and only the dedup-triggered re-ask gets drop.
        // Without the re-ask on dedup, the second answer is never consumed
        // and the entry survives.
        let tab = BrowserTab(history: StubHistory(), initialURL: Self.serp)
        var answers = [true, false]
        tab.historyShouldRecord = { _ in answers.isEmpty ? true : answers.removeFirst() }
        tab.noteCommitted(url: Self.tracker)
        #expect(tab.historySnapshot().urls == [Self.serp, Self.tracker])
        // Back onto the redirector (or a restored entry waking up): the
        // commit dedups, but the re-asked check must still drop it.
        tab.noteCommitted(url: Self.tracker)
        try await waitFor("the deduped tracker to drop") {
            tab.historySnapshot().urls == [Self.serp]
        }
        #expect(tab.historySnapshot().urls == [Self.serp])
        #expect(tab.currentURL == Self.serp)
    }

    // MARK: - Post/Redirect/Get

    private static let orderForm = URL(string: "https://shop.example/order")!
    private static let orderSubmit = URL(string: "https://shop.example/submit")!
    private static let orderThanks = URL(string: "https://shop.example/thanks")!
    private static let orderLanding = URL(string: "https://shop.example/catalog")!

    @Test("a POST submit never records, and back skips the form")
    func postRedirectSkipsForm() {
        // Order form --POST--> 303 thanks: neither the submission nor the
        // form owns history, so Back from thanks has nowhere to go.
        let tab = BrowserTab(history: StubHistory(), initialURL: Self.orderForm)
        tab.historyShouldRecord = { _ in true }
        tab.notePOSTRequest(url: Self.orderSubmit)
        tab.noteCommitted(url: Self.orderSubmit)
        #expect(tab.historySnapshot().urls == [Self.orderForm])
        tab.noteCommitted(url: Self.orderThanks)
        #expect(tab.historySnapshot().urls == [Self.orderThanks])
        #expect(tab.currentURL == Self.orderThanks)
    }

    @Test("a POST that renders keeps its form")
    func postRenderKeepsForm() {
        // No redirect answer: the submission rendered instead, so the arm
        // dies with the finish and a later landing keeps the form behind it.
        let tab = BrowserTab(history: StubHistory(), initialURL: Self.orderForm)
        tab.historyShouldRecord = { _ in true }
        tab.notePOSTRequest(url: Self.orderSubmit)
        tab.noteCommitted(url: Self.orderSubmit)
        tab.noteLoadFinished(url: Self.orderSubmit)
        tab.noteCommitted(url: Self.orderLanding)
        #expect(tab.historySnapshot().urls == [Self.orderForm, Self.orderLanding])
        #expect(tab.currentURL == Self.orderLanding)
    }

    @Test("taking over voids a pending form-skip")
    func takeoverVoidsFormSkip() {
        // Armed by a skipped POST, then the user backs out: the voided arm
        // must not drop the form under a later landing.
        let tab = BrowserTab(history: StubHistory(), initialURL: Self.orderForm)
        tab.historyShouldRecord = { _ in true }
        tab.notePOSTRequest(url: Self.orderSubmit)
        tab.noteCommitted(url: Self.orderSubmit)
        tab.goBack()
        tab.noteCommitted(url: Self.orderThanks)
        #expect(tab.historySnapshot().urls == [Self.orderForm, Self.orderThanks])
        #expect(tab.currentURL == Self.orderThanks)
    }

    @Test("reloading a plain page changes nothing")
    func plainReloadKeeps() async throws {
        let tab = makeTab(answering: true)
        tab.noteCommitted(url: Self.destination)
        tab.noteCommitted(url: Self.destination)
        try await Task.sleep(for: .milliseconds(100))
        #expect(tab.historySnapshot().urls == [Self.serp, Self.destination])
        #expect(tab.currentURL == Self.destination)
    }

    @Test("lagged redirect callbacks clear every hop")
    func laggedCallbacksClearHops() {
        // Production order on instant chains: each commit observation
        // lands, then the previous hop's redirect callback arrives. Each
        // callback drops the oldest unfinished hop; the landing re-appends
        // on finish.
        let a = URL(string: "https://hop.example/a")!
        let b = URL(string: "https://hop.example/b")!
        let c = URL(string: "https://hop.example/c")!
        let d = URL(string: "https://shop.example/")!
        let tab = makeTab(answering: true)
        tab.noteCommitted(url: a)
        tab.noteCommitted(url: b)
        tab.noteServerRedirect()
        #expect(tab.historySnapshot().urls == [Self.serp, b])
        tab.noteCommitted(url: c)
        tab.noteServerRedirect()
        #expect(tab.historySnapshot().urls == [Self.serp, c])
        tab.noteCommitted(url: d)
        tab.noteServerRedirect()
        tab.noteCommitted(url: d)
        tab.noteLoadFinished(url: d)
        #expect(tab.historySnapshot().urls == [Self.serp, d])
        #expect(tab.currentURL == d)
    }

    @Test("redirect callbacks keep finished pages")
    func redirectKeepsFinished() {
        // Finished pages leave the unfinished tracker on finish, so a
        // stray redirect report (a subframe hop, say) finds nothing to
        // drop and changes nothing.
        let tab = makeTab(answering: true)
        tab.noteCommitted(url: Self.destination)
        tab.noteLoadFinished(url: Self.destination)
        tab.noteServerRedirect()
        tab.noteServerRedirect()
        #expect(tab.historySnapshot().urls == [Self.serp, Self.destination])
        #expect(tab.currentURL == Self.destination)
    }

    @Test("a replace landing folds the superseded chain into one entry")
    func replaceLandingFoldsChain() {
        // Mirrors didFinish order: the landing reconciles first, then the
        // fold converts it into its predecessor's place while the sweep
        // drops the still-unfinished intermediaries.
        let a = URL(string: "https://hop.example/a")!
        let b = URL(string: "https://hop.example/b")!
        let landing = URL(string: "https://shop.example/")!
        let tab = makeTab(answering: true)
        tab.noteCommitted(url: a)
        tab.noteCommitted(url: b)
        tab.noteCommitted(url: landing)
        tab.foldReplaceLanding(url: landing)
        tab.noteLoadFinished(url: landing)
        #expect(tab.historySnapshot().urls == [Self.serp, landing])
        #expect(tab.currentURL == landing)
    }

    @Test("a restored tracker drops without any navigation")
    func restoredTrackerDrops() async throws {
        // A stored loop state resurrected by session restore re-validates
        // on the spot instead of waiting for a commit to touch it.
        let tab = BrowserTab(
            history: StubHistory(),
            restored: BrowserTab.RestoredState(
                urls: [Self.serp, Self.tracker],
                index: 1,
                title: nil,
                isPinned: false
            ),
            historyShouldRecord: { !$0.contains("/url?") }
        )
        try await waitFor("the restored tracker to drop") {
            tab.historySnapshot().urls == [Self.serp]
        }
        #expect(tab.historySnapshot().urls == [Self.serp])
        #expect(tab.currentURL == Self.serp)
    }

    // MARK: - Live WebKit round trips

    private func waitForURL(_ view: WKWebView, _ want: URL) async throws {
        try await waitFor("page \(want.absoluteString)", timeout: .seconds(20)) {
            view.url?.hasSameAddress(as: want) == true
        }
    }

    @Test("google-style 302 hop keeps serp and destination, back returns")
    func scriptedClickRoundTrip() async throws {
        // Same-tab scripted click into a `/url`-style 302, through real
        // WebKit: provisional KVO, server-redirect callback, commit, async
        // check. The hop must never own history; Back must reach the SERP.
        let server = try RedirectProbeServer()
        try await server.start()
        defer { server.stop() }
        let serp = server.url("/serp")
        let target = server.url("/target")
        let hop = server.url("/url?opi=89978449&q=\(target.absoluteString)")

        let tab = BrowserTab(history: StubHistory(), initialURL: serp)
        tab.historyShouldRecord = { !$0.contains("/url?") }
        let view = tab.ensureWebView()
        try await waitForURL(view, serp)
        _ = try? await view.evaluateJavaScriptSafely("window.location='\(hop.absoluteString)'")
        try await waitForURL(view, target)
        try await waitFor("history to settle on serp and destination") {
            tab.historySnapshot().urls == [serp, target]
        }
        #expect(tab.historySnapshot().urls == [serp, target])
        tab.goBack()
        try await waitFor("back to land on the serp") {
            tab.currentURL.hasSameAddress(as: serp)
        }
        #expect(tab.currentURL.hasSameAddress(as: serp))
    }

    @Test("a tab opened on a redirector settles on the destination alone")
    func newTabOnRedirectorSettles() async throws {
        // A result opened in a new tab starts life on the hop itself: the
        // destination still records once, the hop still drops, and Back has
        // nowhere to go (the SERP lives in the other tab).
        let server = try RedirectProbeServer()
        try await server.start()
        defer { server.stop() }
        let target = server.url("/target")
        let hop = server.url("/url?opi=89978449&q=\(target.absoluteString)")

        let tab = BrowserTab(history: StubHistory(), initialURL: hop)
        tab.historyShouldRecord = { !$0.contains("/url?") }
        let view = tab.ensureWebView()
        try await waitForURL(view, target)
        try await waitFor("history to settle on the destination") {
            tab.historySnapshot().urls == [target]
        }
        #expect(tab.historySnapshot().urls == [target])
        #expect(tab.currentURL.hasSameAddress(as: target))
    }

    @Test("server chain drops every hop")
    func serverChainDropsHops() async throws {
        // SERP > 302 > 302 > 302 > landing through real WebKit: no hop
        // commits, so none may own history; Back returns to the SERP.
        let server = try RedirectProbeServer()
        try await server.start()
        defer { server.stop() }
        let serp = server.url("/serp")
        let landing = server.url("/chain-d")

        let tab = BrowserTab(history: StubHistory(), initialURL: serp)
        tab.historyShouldRecord = { _ in true }
        let view = tab.ensureWebView()
        try await waitForURL(view, serp)
        tab.navigate(to: server.url("/chain-a"))
        try await waitForURL(view, landing)
        try await waitFor("history to settle on serp and landing") {
            tab.historySnapshot().urls == [serp, landing]
        }
        #expect(tab.historySnapshot().urls == [serp, landing])
        tab.goBack()
        try await waitFor("back to land on the serp") {
            tab.currentURL.hasSameAddress(as: serp)
        }
        #expect(tab.currentURL.hasSameAddress(as: serp))
    }

    @Test("client chain folds every replace")
    func clientChainFoldsReplaces() async throws {
        // SERP > JS-replace > JS-replace > JS-replace > landing through real
        // WebKit, with no markers for the tracker check: the replace
        // commits fold into one entry and Back returns to the SERP.
        let server = try RedirectProbeServer()
        try await server.start()
        defer { server.stop() }
        let serp = server.url("/serp")
        let landing = server.url("/cj-d")

        let tab = BrowserTab(history: StubHistory(), initialURL: serp)
        tab.historyShouldRecord = { _ in true }
        let view = tab.ensureWebView()
        try await waitForURL(view, serp)
        tab.navigate(to: server.url("/cj-a"))
        try await waitForURL(view, landing)
        try await waitFor("history to settle on serp and landing") {
            tab.historySnapshot().urls == [serp, landing]
        }
        #expect(tab.historySnapshot().urls == [serp, landing])
        tab.goBack()
        try await waitFor("back to land on the serp") {
            tab.currentURL.hasSameAddress(as: serp)
        }
        #expect(tab.currentURL.hasSameAddress(as: serp))
    }

    @Test("form POST lands thanks with no form behind it")
    func formPostSkipsForm() async throws {
        // Order form --POST--> 303 thanks through real WebKit: neither the
        // submission nor the form owns history, so Back has nowhere to go.
        let server = try RedirectProbeServer()
        try await server.start()
        defer { server.stop() }
        let form = server.url("/form")
        let thanks = server.url("/thanks")

        let tab = BrowserTab(history: StubHistory(), initialURL: form)
        tab.historyShouldRecord = { _ in true }
        let view = tab.ensureWebView()
        try await waitForURL(view, form)
        // The URL commits before the document parses: wait for the form
        // element itself or submit() is a silent no-op on a null.
        for _ in 0 ..< 100 {
            let hasForm = try? await view.evaluateJavaScriptSafely("!!document.querySelector('form')")
            if (hasForm as? Bool) == true { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        _ = try? await view.evaluateJavaScriptSafely("document.querySelector('form').submit()")
        try await waitForURL(view, thanks)
        try await waitFor("history to settle on thanks alone") {
            tab.historySnapshot().urls == [thanks]
        }
        #expect(tab.historySnapshot().urls == [thanks])
        #expect(tab.currentURL.hasSameAddress(as: thanks))
    }
}

/// Self-contained localhost redirector for back-navigation integration
/// tests: no scripts, no network, ephemeral port. Serves a fake SERP, a
/// Google-style 302 `/url` (raw nested destination, like `?q=https://…`),
/// and landing pages over plain HTTP/1.0.
final class RedirectProbeServer: Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "whatever.redirect-probe")

    init() throws {
        listener = try NWListener(using: .tcp, on: .init(integerLiteral: 0))
    }

    var port: UInt16 { listener.port?.rawValue ?? 0 }

    func url(_ path: String) -> URL {
        URL(string: "http://127.0.0.1:\(port)\(path)")!
    }

    func start() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    continuation.resume()
                case .failed(let error):
                    continuation.resume(throwing: error)
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.serve(connection)
            }
            listener.start(queue: queue)
        }
    }

    func stop() {
        listener.cancel()
    }

    private func serve(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, _, _ in
            guard let self, let data, !data.isEmpty else {
                connection.cancel()
                return
            }
            let request = String(data: data, encoding: .utf8) ?? ""
            connection.send(content: self.response(for: request), completion: .contentProcessed { _ in
                connection.cancel()
            })
        }
    }

    private func response(for request: String) -> Data {
        let parts = request.split(separator: "\r\n").first?.split(separator: " ") ?? []
        let method = parts.first.map(String.init) ?? "GET"
        let target = parts.dropFirst().first.map(String.init) ?? "/"
        if target == "/serp" {
            return page(title: "Fake Results", body: "<h1>Fake Results</h1>")
        }
        if target.hasPrefix("/url?") {
            let query = target.split(separator: "?", maxSplits: 1).last ?? ""
            for pair in query.split(separator: "&") where pair.hasPrefix("q=") {
                return redirect(to: String(pair.dropFirst(2)))
            }
            return status(400)
        }
        if target.hasPrefix("/target") {
            return page(title: "Landing", body: "<h1>Landing</h1>")
        }
        if target == "/chain-a" {
            return redirect(to: absolute("/chain-b"))
        }
        if target == "/chain-b" {
            return redirect(to: absolute("/chain-c"))
        }
        if target == "/chain-c" {
            return redirect(to: absolute("/chain-d"))
        }
        if target == "/chain-d" {
            return page(title: "Chain landing", body: "<h1>Chain landing</h1>")
        }
        if target == "/cj-a" {
            return replacePage(to: "/cj-b")
        }
        if target == "/cj-b" {
            return replacePage(to: "/cj-c")
        }
        if target == "/cj-c" {
            return replacePage(to: "/cj-d")
        }
        if target == "/cj-d" {
            return page(title: "Client landing", body: "<h1>Client landing</h1>")
        }
        if target == "/form" {
            return page(
                title: "Order",
                body: "<h1>Order</h1>"
                    + "<form method=\"POST\" action=\"/submit\">"
                    + "<input type=\"text\" name=\"item\" value=\"bread\">"
                    + "<button type=\"submit\">Place order</button>"
                    + "</form>"
            )
        }
        if method == "POST", target == "/submit" {
            // Post/Redirect/Get with the proper code: 303 turns the
            // follow-up into a GET, so the POST itself is never a page.
            return seeOther(to: absolute("/thanks"))
        }
        if target == "/thanks" {
            return page(title: "Thanks", body: "<h1>Thank you</h1>")
        }
        return status(404)
    }

    private func absolute(_ path: String) -> String {
        "http://127.0.0.1:\(port)\(path)"
    }

    private func page(title: String, body: String) -> Data {
        let html = "<!doctype html><html><head><title>\(title)</title></head><body>\(body)</body></html>"
        return Data("HTTP/1.0 200 OK\r\nContent-Type: text/html\r\nContent-Length: \(html.utf8.count)\r\nConnection: close\r\n\r\n\(html)".utf8)
    }

    private func redirect(to location: String) -> Data {
        Data("HTTP/1.0 302 Found\r\nLocation: \(location)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8)
    }

    /// A 200 page that immediately replaces itself with the next hop: the
    /// client-side chain shape (`location.replace`), with no markers for
    /// the tracker check to find.
    private func replacePage(to path: String) -> Data {
        page(
            title: "Redirecting",
            body: "<script>window.location.replace('\(path)')</script>Redirecting…"
        )
    }

    private func seeOther(to location: String) -> Data {
        Data("HTTP/1.0 303 See Other\r\nLocation: \(location)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8)
    }

    private func status(_ code: Int) -> Data {
        Data("HTTP/1.0 \(code) \r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8)
    }
}
