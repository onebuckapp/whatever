import Foundation
import Testing
import WebKit
@testable import Whatever

/// The search link guard: coverage data, script shape, and defaults.
///
/// The script itself runs in pages, so these tests pin what can be pinned
/// without a live engine result page: which hosts it arms on, that it only
/// intercepts link presses, that it never blocks navigation, and that it
/// installs at document start on all frames. Real proof is the manual QA
/// matrix: each guarded engine times left, middle, and right press, plus
/// Back afterwards.
struct SearchLinkGuardTests {
    @Test("guard is opt-in: off on a fresh document")
    func defaultsOff() {
        #expect(AppSettings.SearchSettings().cleanResultLinks == false)
    }

    @Test("coverage spans the agreed engines")
    func coversAgreedEngines() {
        let patterns = SearchLinkGuard.guardedHostPatterns.joined(separator: "\n")
        #expect(patterns.contains("google"))
        #expect(patterns.contains("bing"))
        #expect(patterns.contains("duckduckgo"))
        #expect(patterns.contains("yahoo"))
        #expect(patterns.contains("brave"))
        #expect(patterns.contains("startpage"))
        #expect(patterns.contains("ecosia"))
    }

    @Test("google pattern spans country domains but not lookalikes")
    func googlePatternSpansRegions() {
        let pattern = SearchLinkGuard.guardedHostPatterns.first { $0.contains("google") }!
        let regex = try! NSRegularExpression(pattern: pattern)
        func matches(_ host: String) -> Bool {
            let range = NSRange(host.startIndex..., in: host)
            return regex.firstMatch(in: host, range: range) != nil
        }
        #expect(matches("www.google.com"))
        #expect(matches("www.google.co.uk"))
        #expect(matches("google.de"))
        #expect(!matches("notgoogle.com"))
        #expect(!matches("google.com.evil.example"))
    }

    @Test("script intercepts only link presses, without blocking navigation")
    func interceptsOnlyLinkPresses() {
        let source = SearchLinkGuard.source
        #expect(source.contains("mousedown"))
        #expect(source.contains(#"closest("a")"#))
        #expect(source.contains("stopImmediatePropagation"))
        #expect(!source.contains("preventDefault"))
    }

    @Test("script is idempotent under re-injection")
    func reinstallsIdempotently() {
        #expect(SearchLinkGuard.source.contains("__whateverLinkGuard"))
    }

    @Test("script installs at document start on every frame")
    @MainActor
    func installsEarlyEverywhere() {
        let script = SearchLinkGuard.script
        #expect(script.injectionTime == .atDocumentStart)
        #expect(script.isForMainFrameOnly == false)
    }
}
