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

/// A non-interactive film-grain overlay: the AppKit equivalent of
/// `z-index: 999; pointer-events: none`.
///
/// Event transparency is structural, not a flag: `hitTest(_:)` always
/// returns nil, so clicks, drags, scrolls, hover tracking, gestures,
/// and keyboard focus behave exactly as if the overlay were absent.
/// The view never becomes first responder and is excluded from
/// accessibility.
///
/// Rendering is cheap by construction:
/// - the tile comes from `NoiseTextureCache` (generated once per input
///   set, 1 MB at 512px), never per frame;
/// - opacity rides on the view's `alphaValue`, so strength tweaks skip
///   redrawing entirely;
/// - the view is layer-backed, so the tiled result is composited by the
///   GPU and redrawn only when the configuration, bounds, appearance,
///   or backing scale changes;
/// - a disabled or fully transparent overlay hides itself and skips
///   compositing entirely.
///
/// Texel alphas are mean-zero sparse specks, so the grain stays neutral
/// on both light and dark content: black specks read on light
/// backgrounds, white specks on dark ones, with no gray veil.
final class NoiseOverlayView: NSView {
    /// Layer order within the parent, mirroring the CSS `z-index: 999`.
    /// `moveToFront()` additionally keeps the view last among siblings
    /// for parents that add subviews after installation.
    static let zPosition: CGFloat = 999

    var configuration: NoiseOverlayConfiguration {
        didSet {
            if oldValue != configuration {
                applyConfiguration()
            }
        }
    }

    init(configuration: NoiseOverlayConfiguration = .init(), frame: NSRect = .zero) {
        self.configuration = configuration
        super.init(frame: frame)
        wantsLayer = true
        layer?.zPosition = Self.zPosition
        // Redraw (at the current backing scale) whenever geometry or
        // the display changes. The default policy would stretch the
        // existing bitmap on resize, turning 1px grain into blurry or
        // chunky blocks.
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        setAccessibilityElement(false)
        applyConfiguration()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Event transparency

    /// The whole contract: this view (and its empty subtree) never
    /// claims the mouse, so events fall through to the views below.
    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override var acceptsFirstResponder: Bool {
        false
    }

    override var mouseDownCanMoveWindow: Bool {
        false
    }

    override var isOpaque: Bool {
        false
    }

    // MARK: - Placement

    /// Pins an overlay over `parent`'s full bounds. Constraints keep it
    /// covering the area through resizes and layout changes; because it
    /// is a sibling (not ancestor) of scrolling content, scrolling does
    /// not move the grain.
    ///
    /// There is exactly one overlay per parent: a second layer would
    /// double the grain over everything it covered, so an existing one
    /// is returned with the configuration applied instead.
    @discardableResult
    static func install(
        in parent: NSView,
        configuration: NoiseOverlayConfiguration = .init()
    ) -> NoiseOverlayView {
        if let existing = parent.subviews.compactMap({ $0 as? NoiseOverlayView }).first {
            existing.configuration = configuration
            existing.moveToFront()
            return existing
        }
        let overlay = NoiseOverlayView(configuration: configuration)
        overlay.translatesAutoresizingMaskIntoConstraints = false
        parent.addSubview(overlay, positioned: .above, relativeTo: nil)
        NSLayoutConstraint.activate([
            overlay.topAnchor.constraint(equalTo: parent.topAnchor),
            overlay.leadingAnchor.constraint(equalTo: parent.leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: parent.trailingAnchor),
            overlay.bottomAnchor.constraint(equalTo: parent.bottomAnchor),
        ])
        return overlay
    }

    /// Reorders the overlay above subsequently added siblings (page
    /// views, drop previews, progress bars). Call after swapping child
    /// controllers; harmless otherwise.
    func moveToFront() {
        superview?.addSubview(self, positioned: .above, relativeTo: nil)
    }

    // MARK: - Redraw triggers

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Backing scale comes from the window; re-tile crisply on moves
        // between Retina and non-Retina displays.
        needsDisplay = true
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        needsDisplay = true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    // MARK: - Drawing

    private func applyConfiguration() {
        isHidden = !configuration.isEnabled || configuration.opacity <= 0.001
        // Layer opacity: changing strength never redraws, the window
        // server just composites the cached bitmap differently.
        alphaValue = min(max(configuration.opacity, 0), 1)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard configuration.isEnabled else { return }
        guard let context = NSGraphicsContext.current?.cgContext else { return }

        // The cached tile at its native size. The span is derived from
        // the screen's backing scale so one texel always maps to
        // exactly one device pixel — points and pixels are not the
        // same unit, and any resampling would blur the grain.
        let tile = NoiseTextureCache.image(
            seed: configuration.seed,
            intensity: configuration.intensity,
            contrast: configuration.contrast,
            colorMode: configuration.colorMode
        )
        let texSide = CGFloat(tile.width)
        guard texSide > 0, tile.height > 0 else { return }
        // The 512px tile is a 2x source: `tileSidePoints` gives 256pt on
        // Retina (one texel per device pixel, like a 2x web image) and
        // the source size on 1x screens, so the tile is never upscaled.
        let grain = min(max(configuration.grainScale, 1), 8)
        let backed = convertToBacking(CGSize(width: 1, height: 1))
        let backing = max(backed.width, backed.height)
        let tileSide = NoiseTextureCache.tileSidePoints(texSide: texSide, backingScale: backing)
            * grain
        guard tileSide > 0 else { return }

        // Sampling only: `grainScale` above 1 covers more points with
        // the same tile, which is a downscale and gets filtered.
        context.saveGState()
        context.setShouldAntialias(false)
        context.interpolationQuality = grain > 1 ? .medium : .none

        // Grid-aligned manual tiling: the phase is stable across draws
        // and only dirty tiles repaint.
        let startX = floor(dirtyRect.minX / tileSide) * tileSide
        let startY = floor(dirtyRect.minY / tileSide) * tileSide
        var y = startY
        while y < dirtyRect.maxY {
            var x = startX
            while x < dirtyRect.maxX {
                context.draw(tile, in: CGRect(x: x, y: y, width: tileSide, height: tileSide))
                x += tileSide
            }
            y += tileSide
        }
        context.restoreGState()

        if let tint = configuration.tint, configuration.tintOpacity > 0 {
            tint.withAlphaComponent(min(max(configuration.tintOpacity, 0), 1)).setFill()
            dirtyRect.fill(using: .sourceOver)
        }
    }
}
