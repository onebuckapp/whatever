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
