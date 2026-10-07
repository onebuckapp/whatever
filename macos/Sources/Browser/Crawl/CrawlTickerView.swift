import AppKit
import SwiftUI

/// The scrolling headline strip inside the crawl bar.
///
/// A thin `NSViewRepresentable` over `CrawlTickerNSView`: the strip bitmap is
/// rasterized once per content change and scrolled as a GPU texture, so the
/// SwiftUI side holds no animation state and re-evaluates only when inputs
/// change. The public contract (inputs, `haltLoop`, test hooks) is unchanged,
/// so the bar controller drives it exactly as before.
struct CrawlTickerView: NSViewRepresentable {
    var headlines: [CrawlHeadline]
    var speed: Double
    var direction: AppSettings.CrawlDirection
    var fontSize: Double
    var backgroundOpacity: Double
    /// Mark shown between headlines, 1–2 characters. Normalized at render.
    var separator: String = CrawlContent.defaultSeparator
    /// Favicons keyed by feed URL. Items with a cached icon show it instead
    /// of the site name; items without one fall back to `site: title` text
    /// so no headline ever renders as a bare gap.
    var favicons: [String: NSImage] = [:]
    var onOpen: ((URL) -> Void)?
    /// Starts the scroll animation once measured. Tests set this to false so
    /// snapshots are deterministic snapshots of the loop start.
    var animateLoop = true
    /// Cancels the in-flight loop without starting a new one. The owner sets
    /// this before detaching the bar so no repeat-forever animation is live
    /// while the hosting view leaves the hierarchy.
    var haltLoop = false
    /// Test hook fired when a loop actually launches, with the sweep span
    /// and the one-way duration. Nil in production.
    var onLoopStart: ((CGFloat, TimeInterval) -> Void)?

    /// Follows Dynamic Type: a base of 1 scaled by the system text size, so
    /// the settings point size grows in accessibility sizes like the rest of
    /// the system. The scaled size feeds the rasterizer, so larger text
    /// re-renders crisply instead of scaling a bitmap up.
    @ScaledMetric(relativeTo: .body) private var typeScale = 1.0

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> CrawlTickerNSView {
        let view = CrawlTickerNSView()
        context.coordinator.view = view
        sync(view, context: context)
        return view
    }

    func updateNSView(_ view: CrawlTickerNSView, context: Context) {
        sync(view, context: context)
    }

    private func inputs() -> CrawlTickerInputs {
        CrawlTickerInputs(
            headlines: headlines,
            speed: speed,
            direction: direction,
            fontSize: fontSize * typeScale,
            backgroundOpacity: backgroundOpacity,
            favicons: favicons,
            separator: separator
        )
    }

    private func sync(_ view: CrawlTickerNSView, context: Context) {
        view.onOpen = onOpen
        view.animateLoop = animateLoop
        view.onLoopStart = onLoopStart
        view.update(with: inputs())
        if haltLoop != view.isHalted {
            view.setHalted(haltLoop)
        }
        // Returning to the foreground restarts from the leading edge, which
        // also recovers the loop if it ever missed its start.
        let phase = context.environment.scenePhase
        if phase == .active, context.coordinator.lastPhase != .active, !haltLoop {
            view.startLoop(fromStart: true)
        }
        context.coordinator.lastPhase = phase
    }

    final class Coordinator {
        weak var view: CrawlTickerNSView?
        var lastPhase: ScenePhase = .active
    }
}
