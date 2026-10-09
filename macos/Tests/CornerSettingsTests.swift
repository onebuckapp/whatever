import Foundation
import Testing
@testable import Whatever

/// Corner roundness settings: defaults, legacy documents, and round trip.
struct CornerSettingsTests {
    @Test("corners default to the historical chrome")
    func defaults() {
        let appearance = AppSettings.AppearanceSettings()
        #expect(appearance.tabCornerRadius == 8)
        #expect(appearance.crawlCornerRadius == 8)
        #expect(appearance.pageCornerRadius == 10)
        #expect(appearance.linkHoverOpacity == 0.75)
    }

    @Test("documents written before corners existed decode to defaults")
    func legacyDecodes() throws {
        let decoded = try JSONDecoder().decode(
            AppSettings.AppearanceSettings.self,
            from: Data("{}".utf8)
        )
        #expect(decoded.tabCornerRadius == 8)
        #expect(decoded.crawlCornerRadius == 8)
        #expect(decoded.pageCornerRadius == 10)
        #expect(decoded.linkHoverOpacity == 0.75)
    }

    @Test("chosen roundness round-trips")
    func roundTrip() throws {
        var appearance = AppSettings.AppearanceSettings()
        appearance.tabCornerRadius = 4
        appearance.crawlCornerRadius = 12
        appearance.pageCornerRadius = 0
        appearance.linkHoverOpacity = 0.5
        let decoded = try JSONDecoder().decode(
            AppSettings.AppearanceSettings.self,
            from: JSONEncoder().encode(appearance)
        )
        #expect(decoded == appearance)
    }
}
