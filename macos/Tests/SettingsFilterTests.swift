import Foundation
import Testing
@testable import Whatever

/// Filter matching behind the Appearance pane's search field: every query
/// word must land in the section's title or keywords, and emptiness matches
/// everything so the pane opens unfiltered.
struct SettingsFilterTests {
    @Test("empty query matches everything")
    func emptyMatchesAll() {
        #expect(SettingsFilter.matches(query: "", haystack: "Grain"))
        #expect(SettingsFilter.matches(query: "   ", haystack: "Anything"))
    }

    @Test("matching ignores case")
    func caseInsensitive() {
        #expect(SettingsFilter.matches(query: "grain", haystack: "Grain texture film"))
        #expect(SettingsFilter.matches(query: "GRAIN", haystack: "Grain texture film"))
        #expect(!SettingsFilter.matches(query: "video", haystack: "Grain texture film"))
    }

    @Test("every word must match somewhere")
    func allWordsRequired() {
        #expect(SettingsFilter.matches(query: "current tab", haystack: "Inactive Tabs Current Tab"))
        #expect(!SettingsFilter.matches(query: "current window", haystack: "Inactive Tabs Current Tab"))
    }

    @Test("the Grain example keeps only its section")
    func grainExample() {
        #expect(SettingsFilter.matches(query: "Grain", haystack: "Grain grain texture film noise pattern"))
        #expect(!SettingsFilter.matches(query: "Grain", haystack: "Look look color colour opacity"))
        #expect(!SettingsFilter.matches(query: "Grain", haystack: "Window Background background wallpaper"))
    }
}
