import Foundation
import SwiftUI

/// Whatever's persisted settings, as one document.
///
/// The store holds a single JSON object (see `core/nim-core/storage/schema.nim`
/// and `WhateverSettingsProtocol`), so a schema change is one version check
/// rather than a sweep over per-key migrations. A document written by an older
/// build is missing the groups that build came later, and each group decodes
/// through `decodeIfPresent` so an absent one falls back to its defaults instead
/// of taking the document down with it.
///
/// That fallback is written out rather than left to the synthesized decoder,
/// which does not do it: `decode(_:forKey:)` throws `keyNotFound` for a missing
/// key even where the property has a default value, so adding a group the
/// obvious way silently loses every setting a user had, and the failure is
/// invisible because `load` falls back to defaults anyway.
struct AppSettings: Codable, Equatable {
    var general = GeneralSettings()
    var appearance = AppearanceSettings()
    var web = WebSettings()
    var search = SearchSettings()

    enum CodingKeys: String, CodingKey {
        case general, appearance, web, search
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        general = try container.decodeIfPresent(GeneralSettings.self, forKey: .general)
            ?? GeneralSettings()
        appearance = try container.decodeIfPresent(AppearanceSettings.self, forKey: .appearance)
            ?? AppearanceSettings()
        web = try container.decodeIfPresent(WebSettings.self, forKey: .web) ?? WebSettings()
        search = try container.decodeIfPresent(SearchSettings.self, forKey: .search)
            ?? SearchSettings()
    }

    /// Startup and history defaults.
    struct GeneralSettings: Codable, Equatable {
        /// Restore the previous session's windows and tabs on launch.
        var restoreSession = true
        /// Record visited pages in history. Private tabs never do, whatever
        /// this says.
        var recordsHistory = true
        /// Re-visit of the same URL inside this window updates the existing
        /// history row instead of adding a near-duplicate. Seconds.
        var historyCollapseWindow: Double = 10
    }

    /// The grain overlay's tunables, moved here from their old UserDefaults
    /// home. `NoiseOverlayConfiguration` stays the in-memory shape the view
    /// uses; this is its stored mirror.
    struct AppearanceSettings: Codable, Equatable {
        var noise = StoredNoise()
        var background = BackgroundMediaConfiguration()

        enum CodingKeys: String, CodingKey {
            case noise, background
        }

        init() {}

        /// Tolerant for the same reason as `AppSettings`: `background` was added
        /// after `noise`, so every document written before it lacks the key.
        ///
        /// Only the outer level is written this way. These documents are always
        /// written whole by `update`, so a group is either present and complete
        /// or absent, and a hand-edited document with a half-filled group is not a
        /// case worth carrying a decoder for.
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            noise = try container.decodeIfPresent(StoredNoise.self, forKey: .noise) ?? StoredNoise()
            background = try container.decodeIfPresent(BackgroundMediaConfiguration.self, forKey: .background)
                ?? BackgroundMediaConfiguration()
        }

        /// Codable mirror of `NoiseOverlayConfiguration`. `NSColor` is not
        /// `Codable`, so the tint round-trips through its sRGB components.
        struct StoredNoise: Codable, Equatable {
            var isEnabled = true
            var opacity = 0.12
            var intensity = 0.40
            var contrast = 1.6
            var grainScale = 1.0
            var colorMode = GrainColorMode.monochrome
            var tintRed: Double?
            var tintGreen: Double?
            var tintBlue: Double?
            var tintOpacity = 0.0
            var seed: UInt64 = 0
        }
    }

    /// Browser engine preferences.
    ///
    /// The split mirrors what WebKit allows. `WKWebViewConfiguration` values are
    /// read once when a web view is built, so changing one only takes effect on
    /// the next page; `WKWebView` values are applied to open views immediately.
    /// `needsReload` in the UI is driven by which group was touched.
    struct WebSettings: Codable, Equatable {
        // MARK: Config-time: applied when a web view is built

        /// `WKWebpagePreferences.allowsContentJavaScript`.
        var allowsJavaScript = true
        /// `WKWebViewConfiguration.upgradeKnownHostsToHTTPS`.
        var upgradeKnownHostsToHTTPS = false
        /// `WKWebViewConfiguration.mediaTypesRequiringUserActionForPlayback`:
        /// which media needs a click before it plays.
        var mediaTypesRequiringUserAction: [String] = ["all"]
        /// `WKWebViewConfiguration.limitsNavigationsToAppBoundDomains`. Left
        /// off: the `whtvr://` homepage handler is part of this app, and
        /// app-bound navigation is strict about what that covers.
        var limitsNavigationsToAppBoundDomains = false
        /// `WKWebViewConfiguration.suppressesIncrementalRendering`.
        var suppressesIncrementalRendering = false

        // MARK: Live: applied to open views

        /// `WKWebView.pageZoom`, 0.25...5.
        var pageZoom: Double = 1.0
        /// `WKPreferences.minimumFontSize`, in points.
        var minimumFontSize: Double = 0
        /// `WKPreferences.javaScriptCanOpenWindowsAutomatically`.
        var javaScriptCanOpenWindowsAutomatically = false
        /// `WKPreferences.fraudulentWebsiteWarningEnabled`.
        var fraudulentWebsiteWarningEnabled = true
        /// `WKPreferences.siteSpecificQuirksModeEnabled`.
        var siteSpecificQuirksModeEnabled = false
        /// `WKPreferences.elementFullscreenEnabled`.
        var elementFullscreenEnabled = true
        /// `WKPreferences.tabFocusesLinks`.
        var tabFocusesLinks = false
        /// `WKWebView.customUserAgent`. nil means WebKit's default.
        var customUserAgent: String?
        /// `WKWebView.allowsLinkPreview`.
        var allowsLinkPreview = true
        /// `WKWebView.allowsBackForwardNavigationGestures`.
        var allowsBackForwardNavigationGestures = true
        /// `WKWebView.allowsMagnification`.
        var allowsMagnification = true
        /// `WKWebViewConfiguration.applicationNameForUserAgent`, sent as
        /// `Whatever/<version>` so sites see the real app.
        var applicationNameForUserAgent = "Whatever"
    }

    /// Which engine the address field sends a search to, and any the user added.
    ///
    /// Both the selection and the added engines live in this document rather than
    /// in the core, because the core stores the settings document as opaque bytes
    /// and knows nothing about what is in it.
    struct SearchSettings: Codable, Equatable {
        /// Id of the engine searches go to: a `PredefinedSearchEngine` raw value,
        /// or a custom engine's `id`.
        ///
        /// Held as a string rather than one of the two types because it has to
        /// name both, and because a document written by a build that knew an
        /// engine this one does not still has to decode. `engine()` resolves it
        /// and falls back rather than failing.
        var defaultEngine = PredefinedSearchEngine.duckDuckGo.rawValue

        /// Engines the user added, in the order they were added.
        var customEngines: [CustomSearchEngine] = []
    }

    /// Identifiers of the `WebSettings` properties WebKit only reads when a
    /// `WKWebView` is built.
    ///
    /// `WKWebView` copies its configuration at init and hands back a copy from
    /// `configuration`, so nothing reachable through it — including
    /// `configuration.preferences` — can be changed on a live view. Everything
    /// here needs a new page before it takes full effect; the rest of the
    /// properties live on `WKWebView` itself and apply immediately.
    ///
    /// Kept as names rather than a `Set` of values so it stays correct as fields
    /// are added, and so the settings UI can tell the user which change needs a
    /// reload.
    static let configTimeWebKeys: Set<String> = [
        "allowsJavaScript",
        "upgradeKnownHostsToHTTPS",
        "mediaTypesRequiringUserAction",
        "limitsNavigationsToAppBoundDomains",
        "suppressesIncrementalRendering",
        "minimumFontSize",
        "javaScriptCanOpenWindowsAutomatically",
        "fraudulentWebsiteWarningEnabled",
        "siteSpecificQuirksModeEnabled",
        "elementFullscreenEnabled",
        "tabFocusesLinks",
        "applicationNameForUserAgent",
    ]
}

/// Reads and writes `AppSettings` through the store service.
///
/// Every call is asynchronous: the document lives in another process, and the
/// main thread must not wait on it. Writes are debounced so dragging a slider
/// does not produce one store round trip per frame.
@MainActor
final class SettingsStore: ObservableObject {
    static let shared = SettingsStore()

    /// Current settings. Starts as the built-in defaults and is replaced once
    /// the store answers, so the UI is never blocked on the first read.
    @Published private(set) var settings = AppSettings()

    /// Whether the store has answered yet. The settings UI shows a loading
    /// state until this is true rather than briefly presenting defaults as if
    /// they were the user's choices.
    @Published private(set) var isLoaded = false

    /// Last read or write failure, for diagnostics and the settings UI.
    @Published private(set) var lastError: String?

    /// Whether a change has not reached the store yet.
    ///
    /// The quit path uses this to decide whether it needs to delay termination
    /// at all, so an unchanged quit is not made to wait on a round trip.
    var hasPendingWrite: Bool { saveTask != nil }

    /// Called after every change with the top-level keys whose values differ.
    ///
    /// `BrowserCoordinator` subscribes once at launch to push live web settings
    /// onto open pages. Keeping it here rather than in each control means a
    /// programmatic change is applied exactly like one made in the UI.
    var onChange: ((Set<String>) -> Void)?

    /// UserDefaults key the grain settings lived under before the move to the
    /// store. Read once on the first launch after the migration and then left
    /// alone, so it stays usable as a rollback.
    private static let legacyNoiseKey = "whatever.noiseOverlay"

    private var saveTask: Task<Void, Never>?
    /// How long to wait after a change before writing. Long enough to coalesce a
    /// slider drag, short enough that a crash loses nothing meaningful.
    private static let saveDebounce: Duration = .milliseconds(400)

    private init() {}

    // MARK: - Loading

    /// Loads settings from the store, migrating the legacy UserDefaults
    /// document on a store that has none.
    ///
    /// Safe to call more than once: the second call is ignored once loaded.
    func load() async {
        guard !isLoaded else { return }
        do {
            let data = try await StoreClient.shared.settings()
            let stored = try JSONDecoder().decode(AppSettings.self, from: data)
            if stored == AppSettings() {
                // An empty object is what a fresh install reads back, so the
                // legacy document is the only thing that can carry real choices
                // forward.
                if let migrated = migrateLegacyDefaults() {
                    settings = migrated
                    await saveNow()
                }
            } else {
                settings = stored
            }
            isLoaded = true
        } catch {
            lastError = error.localizedDescription
            // A store that cannot be reached must not stop the browser from
            // opening, so the defaults stand and the UI can report the failure.
            if let migrated = migrateLegacyDefaults() {
                settings = migrated
            }
            isLoaded = true
        }
    }

    /// Reads the pre-store grain document, if there is one.
    ///
    /// Returns nil when there is nothing to migrate, which is the case for any
    /// install that never used the overlay.
    private func migrateLegacyDefaults() -> AppSettings? {
        guard let data = UserDefaults.standard.data(forKey: Self.legacyNoiseKey),
              let legacy = try? JSONDecoder().decode(LegacyNoise.self, from: data)
        else {
            return nil
        }
        var result = AppSettings()
        result.appearance.noise = legacy.settings
        return result
    }

    // MARK: - Writing

    /// Applies a change and schedules a write.
    func update(_ mutate: (inout AppSettings) -> Void) {
        var next = settings
        mutate(&next)
        guard next != settings else { return }
        let previous = settings
        settings = next
        scheduleSave()
        onChange?(Self.changedKeys(from: previous, to: next))
    }

    /// Which top-level sections differ between two documents.
    ///
    /// Section-level rather than field-level, because the only subscriber cares
    /// whether the web section moved at all.
    private static func changedKeys(from old: AppSettings, to new: AppSettings) -> Set<String> {
        var keys: Set<String> = []
        if old.general != new.general { keys.insert("general") }
        if old.appearance != new.appearance { keys.insert("appearance") }
        if old.web != new.web { keys.insert("web") }
        if old.search != new.search { keys.insert("search") }
        return keys
    }

    /// Replaces everything with the built-in defaults.
    func reset() {
        settings = AppSettings()
        scheduleSave()
    }

    /// A two-way binding onto one field, for SwiftUI controls.
    ///
    /// Every write goes through `update`, so a control cannot get the store's
    /// change detection or its debounced persistence by accident.
    func binding<Value>(_ keyPath: WritableKeyPath<AppSettings, Value>) -> Binding<Value> {
        Binding(
            get: { [self] in settings[keyPath: keyPath] },
            set: { [self] newValue in
                update { document in
                    document[keyPath: keyPath] = newValue
                }
            }
        )
    }

    /// Writes the legacy UserDefaults document back out.
    ///
    /// Only for the "revert to the pre-store behaviour" escape hatch; the
    /// browser reads settings from the store.
    func exportLegacyNoiseDocument() -> Data? {
        try? JSONEncoder().encode(LegacyNoise(settings: settings.appearance.noise))
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: Self.saveDebounce)
            guard !Task.isCancelled else { return }
            await self?.saveNow()
        }
    }

    /// Writes immediately, bypassing the debounce. Used after a migration at
    /// launch and on quit, where there may be no later chance to write.
    ///
    /// Bounded by `saveTimeout`, because this runs on the quit path: a store
    /// service that has gone away must not leave the app unable to quit.
    func saveNow() async {
        saveTask?.cancel()
        saveTask = nil
        let snapshot = settings
        let result = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                do {
                    let data = try JSONEncoder().encode(snapshot)
                    try await StoreClient.shared.setSettings(data)
                    return true
                } catch {
                    return false
                }
            }
            group.addTask {
                try? await Task.sleep(for: Self.saveTimeout)
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
        lastError = result ? nil : "Settings could not be saved."
    }

    /// How long a single write may take before it is abandoned. Long enough for
    /// a cold service launch on a slow disk, short enough not to hang a quit.
    private static let saveTimeout: Duration = .seconds(3)
}

/// The shape UserDefaults held before settings moved to the store.
///
/// Encoded field-for-field as the old `StoredConfiguration` so an existing
/// document decodes without conversion. Retired: the store is the home for
/// settings now, and this only exists to carry old values across.
private struct LegacyNoise: Codable {
    var isEnabled: Bool
    var opacity: Double
    var intensity: Double
    var contrast: Double
    var grainScale: Double
    var colorMode: GrainColorMode
    var tintRed: Double?
    var tintGreen: Double?
    var tintBlue: Double?
    var tintOpacity: Double
    var seed: UInt64

    init(
        isEnabled: Bool,
        opacity: Double,
        intensity: Double,
        contrast: Double,
        grainScale: Double,
        colorMode: GrainColorMode,
        tintRed: Double?,
        tintGreen: Double?,
        tintBlue: Double?,
        tintOpacity: Double,
        seed: UInt64
    ) {
        self.isEnabled = isEnabled
        self.opacity = opacity
        self.intensity = intensity
        self.contrast = contrast
        self.grainScale = grainScale
        self.colorMode = colorMode
        self.tintRed = tintRed
        self.tintGreen = tintGreen
        self.tintBlue = tintBlue
        self.tintOpacity = tintOpacity
        self.seed = seed
    }

    init(settings: AppSettings.AppearanceSettings.StoredNoise) {
        isEnabled = settings.isEnabled
        opacity = settings.opacity
        intensity = settings.intensity
        contrast = settings.contrast
        grainScale = settings.grainScale
        colorMode = settings.colorMode
        tintRed = settings.tintRed
        tintGreen = settings.tintGreen
        tintBlue = settings.tintBlue
        tintOpacity = settings.tintOpacity
        seed = settings.seed
    }

    var settings: AppSettings.AppearanceSettings.StoredNoise {
        AppSettings.AppearanceSettings.StoredNoise(
            isEnabled: isEnabled,
            opacity: opacity,
            intensity: intensity,
            contrast: contrast,
            grainScale: grainScale,
            colorMode: colorMode,
            tintRed: tintRed,
            tintGreen: tintGreen,
            tintBlue: tintBlue,
            tintOpacity: tintOpacity,
            seed: seed
        )
    }
}