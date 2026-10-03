import SwiftUI

/// SwiftUI entry point for the grain overlay. Hit-testing is disabled
/// at both levels: the SwiftUI wrapper opts out, and the underlying
/// `NoiseOverlayView` returns nil from `hitTest(_:)`, so even direct
/// AppKit event dispatch passes through.
struct NoiseOverlay: View {
    var configuration: NoiseOverlayConfiguration

    init(_ configuration: NoiseOverlayConfiguration = .init()) {
        self.configuration = configuration
    }

    var body: some View {
        NoiseOverlayRepresentable(configuration: configuration)
            .allowsHitTesting(false)
    }
}

/// Thin bridge over the single AppKit implementation, so the texture
/// cache and tiling behavior stay identical between AppKit and SwiftUI.
struct NoiseOverlayRepresentable: NSViewRepresentable {
    var configuration: NoiseOverlayConfiguration

    func makeNSView(context: Context) -> NoiseOverlayView {
        NoiseOverlayView(configuration: configuration)
    }

    func updateNSView(_ nsView: NoiseOverlayView, context: Context) {
        nsView.configuration = configuration
    }
}

extension View {
    /// Layers subtle grain above this view without affecting layout or
    /// interaction. A disabled configuration adds no view at all.
    ///
    ///     ContentView()
    ///         .noiseOverlay(.subtle)
    func noiseOverlay(_ configuration: NoiseOverlayConfiguration = .init()) -> some View {
        overlay {
            if configuration.isEnabled {
                NoiseOverlay(configuration)
            }
        }
    }
}

/// SwiftUI callers pass colors as `NSColor(Color.blue)`; `NSColor`
/// bridges `SwiftUI.Color` on macOS 11+.
