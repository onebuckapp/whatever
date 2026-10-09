import Foundation
import Testing
@testable import Whatever

/// The omnibox search row: first result, live text, engine destination.
struct SpotlightSearchRowTests {
    private var engine: ResolvedSearchEngine {
        PredefinedSearchEngine.duckDuckGo.resolved
    }

    @Test("row names the typed text")
    func namesQuery() {
        let row = HistoryFuzzyEntry.searchRow(query: "cats", engine: engine)
        #expect(row?.title == "Search for \"cats\"")
        #expect(row?.isSearchRow == true)
    }

    @Test("row keeps a stable identity while typing")
    func stableID() {
        let first = HistoryFuzzyEntry.searchRow(query: "ca", engine: engine)
        let second = HistoryFuzzyEntry.searchRow(query: "cats", engine: engine)
        #expect(first?.id == HistoryFuzzyEntry.searchRowID)
        #expect(second?.id == HistoryFuzzyEntry.searchRowID)
    }

    @Test("row navigates through the address parser")
    func parserDestination() {
        let search = HistoryFuzzyEntry.searchRow(query: "cats", engine: engine)
        #expect(search?.url.contains("cats") == true)
        #expect(search?.host == engine.title)
        // URL-looking text still goes direct, exactly as Enter would.
        let direct = HistoryFuzzyEntry.searchRow(query: "example.com", engine: engine)
        #expect(direct?.url == "https://example.com")
    }

    @Test("blank query builds no row")
    func blankIsNil() {
        #expect(HistoryFuzzyEntry.searchRow(query: "", engine: engine) == nil)
        #expect(HistoryFuzzyEntry.searchRow(query: "   ", engine: engine) == nil)
    }

    @Test("row renders plainly: no visits, no highlights")
    func plainRow() {
        let row = HistoryFuzzyEntry.searchRow(query: "cats", engine: engine)
        #expect(row?.visitCount == 0)
        #expect(row?.titleHighlight.isEmpty == true)
        #expect(row?.urlHighlight.isEmpty == true)
    }
}
