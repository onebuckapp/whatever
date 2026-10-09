import AppKit
import Foundation
import Testing
import WebKit
@testable import Whatever

/// The link-hover status bubble: script shape and bubble transitions.
///
/// The script runs in pages, so these pin what can be pinned without one:
/// what it listens for, that it reports only changes, and that it installs
/// early on every frame. The bubble itself is a plain view driven through
/// `show`/`hide`, so its transitions are pinned directly on the main actor.
struct LinkHoverTests {
    @Test("script listens for hover enter, leave, and window exit")
    func listensForHover() {
        let source = LinkHover.source
        #expect(source.contains("mouseover"))
        #expect(source.contains("mouseout"))
        #expect(source.contains("mouseleave"))
        #expect(source.contains(#"closest("a[href]")"#))
    }

    @Test("script reports only changes through the message handler")
    func reportsChangesOnly() {
        let source = LinkHover.source
        #expect(source.contains(LinkHover.handlerName))
        #expect(source.contains("postMessage"))
        #expect(source.contains("current"))
    }

    @Test("script is idempotent and needs the message bridge")
    func installsOnceWithBridge() {
        let source = LinkHover.source
        #expect(source.contains("__whateverLinkHover"))
        #expect(source.contains("messageHandlers"))
    }

    @Test("script installs at document start on every frame")
    @MainActor
    func installsEarlyEverywhere() {
        let script = LinkHover.script
        #expect(script.injectionTime == .atDocumentStart)
        #expect(script.isForMainFrameOnly == false)
    }

    @Test("bubble shows the address and hides again")
    @MainActor
    func bubbleShowsAndHides() {
        let bubble = LinkHoverBubble()
        #expect(bubble.isShowing == false)
        bubble.show(URL(string: "https://example.com/some/long/path")!, onPage: URL(string: "https://example.com/")!)
        #expect(bubble.isShowing == true)
        #expect(bubble.displayedAddress == "https://example.com/some/long/path")
        bubble.hide()
        #expect(bubble.isShowing == false)
    }

    @Test("bubble retargets while up without restarting")
    @MainActor
    func bubbleRetargetsWhileUp() {
        let bubble = LinkHoverBubble()
        bubble.show(URL(string: "https://a.example")!, onPage: nil)
        bubble.show(URL(string: "https://b.example/other")!, onPage: nil)
        #expect(bubble.isShowing == true)
        #expect(bubble.displayedAddress == "https://b.example/other ↗")
    }

    @Test("external links gain the arrow, internal ones do not")
    func externalArrow() {
        let page = URL(string: "https://example.com/article")!
        #expect(LinkHoverBubble.displayText(
            link: URL(string: "https://example.com/other")!, onPage: page)
            == "https://example.com/other")
        #expect(LinkHoverBubble.displayText(
            link: URL(string: "https://elsewhere.com/x")!, onPage: page)
            == "https://elsewhere.com/x ↗")
    }

    @Test("www counts as the same site, case ignored, hostless leaves")
    func externalEdgeCases() {
        #expect(LinkHoverBubble.isExternal(
            link: URL(string: "https://www.example.com/x")!,
            onPage: URL(string: "https://example.com/")!) == false)
        #expect(LinkHoverBubble.isExternal(
            link: URL(string: "https://EXAMPLE.com/x")!,
            onPage: URL(string: "https://example.com/")!) == false)
        #expect(LinkHoverBubble.isExternal(
            link: URL(string: "https://sub.example.com/x")!,
            onPage: URL(string: "https://example.com/")!) == true)
        #expect(LinkHoverBubble.isExternal(
            link: URL(string: "mailto:a@example.com")!,
            onPage: URL(string: "https://example.com/")!) == true)
        #expect(LinkHoverBubble.isExternal(
            link: URL(string: "https://example.com/x")!,
            onPage: nil) == true)
    }

    @Test("hiding a hidden bubble is a no-op")
    @MainActor
    func hideIdempotent() {
        let bubble = LinkHoverBubble()
        bubble.hide()
        #expect(bubble.isShowing == false)
    }
}
