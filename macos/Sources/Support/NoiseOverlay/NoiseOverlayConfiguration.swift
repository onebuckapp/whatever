import AppKit
import Combine

/// Whether the grain carries hue or stays neutral gray.
enum GrainColorMode: String, Codable, CaseIterable, Identifiable {
    case monochrome
    case color

    var id: String { title }

    var title: String {
        switch self {
        case .monochrome: "Monochrome"
        case .color: "Color"
        }
    }
}

/// Tunables for `NoiseOverlayView` / SwiftUI `NoiseOverlay`.
///
/// Opacity rides on the view's `alphaValue` (free: no redraw), while
/// seed, intensity, contrast, and color are baked into the cached tile
/// and regenerate it event-driven on change — the same split as the
/// reference ScreenGrain implementation.
struct NoiseOverlayConfiguration: Equatable {
    /// Master switch. A disabled overlay hides its view entirely, so it
    /// costs no compositing.
    var isEnabled: Bool = true

    /// Overall alpha of the grain layer, 0...1. Free to change.
    var opacity: CGFloat = 0.12

    /// Coverage baked into the tile's per-texel alphas, 0...1.
    /// Regenerates the cached tile when changed.
    var intensity: CGFloat = 0.75

    /// Hardness of the specks, 1...8. 1 keeps the reference's soft
    /// distribution; higher values push weak texels toward fully
    /// transparent and strong ones toward opaque, so the grain reads as
    /// black-and-white dust rather than gray haze. Regenerates the tile.
    var contrast: CGFloat = 1.6

    /// Grain size multiplier. 1 renders the 512px source at its 2x size
    /// (256pt, one texel per device pixel on Retina); larger values
    /// make chunkier grains by drawing the same tile over more points.
    /// Clamped to 1...8: below 1 would upscale the source and read as
    /// blur.
    var grainScale: CGFloat = 1

    /// Monochrome stays neutral on any content; color shows faint
    /// channel-independent hue. Regenerates the cached tile.
    var colorMode: GrainColorMode = .monochrome

    /// Optional uniform color wash drawn over the grain.
    var tint: NSColor? = nil

    /// Alpha of the tint wash, 0...1.
    var tintOpacity: CGFloat = 0

    /// Selects the deterministic tile. Different seeds give unrelated
    /// grain. Regenerates the cached tile when changed.
    var seed: UInt64 = 0

    /// Barely-there grain suitable for shipping.
    static let subtle = NoiseOverlayConfiguration()

    /// Fully off.
    static let disabled = NoiseOverlayConfiguration(isEnabled: false)

    static func == (lhs: NoiseOverlayConfiguration, rhs: NoiseOverlayConfiguration) -> Bool {
        lhs.isEnabled == rhs.isEnabled
            && lhs.opacity == rhs.opacity
            && lhs.intensity == rhs.intensity
            && lhs.contrast == rhs.contrast
            && lhs.grainScale == rhs.grainScale
            && lhs.colorMode == rhs.colorMode
            && lhs.tintOpacity == rhs.tintOpacity
            && lhs.seed == rhs.seed
            && Self.sameTint(lhs.tint, rhs.tint)
    }

    /// Values arriving from sliders can be slightly out of range or
    /// non-finite; clamping here keeps a bad drag from reaching the
    /// generator or the context.
    var sanitized: NoiseOverlayConfiguration {
        var result = self
        result.opacity = Self.clamp(opacity, 0...1, fallback: 0.12)
        result.intensity = Self.clamp(intensity, 0...1, fallback: 0.75)
        result.contrast = Self.clamp(contrast, 1...8, fallback: 1.6)
        result.grainScale = Self.clamp(grainScale, 1...8, fallback: 1)
        result.tintOpacity = Self.clamp(tintOpacity, 0...1, fallback: 0)
        return result
    }

    private static func clamp(_ value: CGFloat, _ range: ClosedRange<CGFloat>, fallback: CGFloat) -> CGFloat {
        guard value.isFinite else { return fallback }
        return min(max(value, range.lowerBound), range.upperBound)
    }

    private static func sameTint(_ lhs: NSColor?, _ rhs: NSColor?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil):
            return true
        case let (lhs?, rhs?):
            return lhs.isEqual(rhs)
        case _:
            return false
        }
    }
}

/// Shared, observable grain settings for the whole app.
///
/// One store backs every window's overlay, so a change made in the settings
/// popup updates all open windows at once.
///
/// Persistence moved from `UserDefaults` to the `WhateverStore` service during
/// the store's introduction. This type is now a view onto
/// `AppSettings.appearance.noise`: it holds the in-memory configuration the
/// overlay reads, translates to and from the stored mirror, and mirrors every
/// change into `SettingsStore`, which does the debounced write.
@MainActor
final class NoiseOverlaySettings: ObservableObject {
    static let shared = NoiseOverlaySettings()

    /// Bumped on every write; views observe the object itself.
    @Published private(set) var configuration: NoiseOverlayConfiguration

    private let settings: SettingsStore

    init(settings: SettingsStore = .shared) {
        self.settings = settings
        configuration = Self.configuration(from: settings.settings.appearance.noise)

        // The store may answer after this object exists, carrying the user's
        // saved values or a migrated legacy document.
        Task { @MainActor [weak self] in
            guard let self else { return }
            await settings.load()
            configuration = Self.configuration(from: settings.settings.appearance.noise)
        }
    }

    // MARK: - Mutation

    func update(_ mutate: (inout NoiseOverlayConfiguration) -> Void) {
        var next = configuration
        mutate(&next)
        next = next.sanitized
        guard next != configuration else { return }
        configuration = next
        persist()
    }

    /// Fresh deterministic grain with the same look.
    func rerollSeed() {
        update { $0.seed = UInt64.random(in: 0...UInt64.max) }
    }

    func reset() {
        configuration = NoiseOverlayConfiguration()
        persist()
    }

    /// Applies stored values without writing them back, for the load path.
    func adopt(_ configuration: NoiseOverlayConfiguration) {
        self.configuration = configuration
    }

    private func persist() {
        settings.update { $0.appearance.noise = Self.stored(from: configuration) }
    }

    // MARK: - Translation

    /// Stored mirror of a configuration.
    ///
    /// `NSColor` is not `Codable`, so the tint round-trips through its sRGB
    /// components. A tint in another color space is dropped rather than
    /// converted, since the only tint the UI offers is picked in sRGB.
    static func stored(
        from configuration: NoiseOverlayConfiguration
    ) -> AppSettings.AppearanceSettings.StoredNoise {
        var result = AppSettings.AppearanceSettings.StoredNoise()
        result.isEnabled = configuration.isEnabled
        result.opacity = Double(configuration.opacity)
        result.intensity = Double(configuration.intensity)
        result.contrast = Double(configuration.contrast)
        result.grainScale = Double(configuration.grainScale)
        result.colorMode = configuration.colorMode
        result.tintOpacity = Double(configuration.tintOpacity)
        result.seed = configuration.seed
        if let tint = configuration.tint?.usingColorSpace(.sRGB) {
            result.tintRed = Double(tint.redComponent)
            result.tintGreen = Double(tint.greenComponent)
            result.tintBlue = Double(tint.blueComponent)
        }
        return result
    }

    /// In-memory configuration for a stored mirror.
    ///
    /// Sanitized on the way in: a hand-edited or corrupted document must not be
    /// able to push a non-finite value into the texture generator.
    static func configuration(
        from stored: AppSettings.AppearanceSettings.StoredNoise
    ) -> NoiseOverlayConfiguration {
        var result = NoiseOverlayConfiguration()
        result.isEnabled = stored.isEnabled
        result.opacity = CGFloat(stored.opacity)
        result.intensity = CGFloat(stored.intensity)
        result.contrast = CGFloat(stored.contrast)
        result.grainScale = CGFloat(stored.grainScale)
        result.colorMode = stored.colorMode
        result.tintOpacity = CGFloat(stored.tintOpacity)
        result.seed = stored.seed
        if let tintRed = stored.tintRed,
           let tintGreen = stored.tintGreen,
           let tintBlue = stored.tintBlue
        {
            result.tint = NSColor(
                srgbRed: CGFloat(tintRed),
                green: CGFloat(tintGreen),
                blue: CGFloat(tintBlue),
                alpha: 1
            )
        }
        return result.sanitized
    }
}
