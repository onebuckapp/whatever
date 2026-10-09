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
        bubble.show(URL(string: "https://example.com/some/long/path")!)
        #expect(bubble.isShowing == true)
        #expect(bubble.displayedAddress == "https://example.com/some/long/path")
        bubble.hide()
        #expect(bubble.isShowing == false)
    }

    @Test("bubble retargets while up without restarting")
    @MainActor
    func bubbleRetargetsWhileUp() {
        let bubble = LinkHoverBubble()
        bubble.show(URL(string: "https://a.example")!)
        bubble.show(URL(string: "https://b.example/other")!)
        #expect(bubble.isShowing == true)
        #expect(bubble.displayedAddress == "https://b.example/other")
    }

    @Test("hiding a hidden bubble is a no-op")
    @MainActor
    func hideIdempotent() {
        let bubble = LinkHoverBubble()
        bubble.hide()
        #expect(bubble.isShowing == false)
    }
}
