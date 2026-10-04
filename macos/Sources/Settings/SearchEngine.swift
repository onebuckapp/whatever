import Foundation

/// The engines offered out of the box.
///
/// A plain list rather than a stored one: these are the choices that do not need
/// explaining, and a fresh install has to offer something before the user has
/// configured anything. `rawValue` is what lands in the settings document, so
/// renaming a case silently retires it. That is deliberate and harmless here,
/// because `AppSettings.SearchSettings.engine()` falls back to DuckDuckGo for an id
/// it cannot resolve rather than leaving the address field with nowhere to send a
/// search.
enum PredefinedSearchEngine: String, CaseIterable, Identifiable {
    // DuckDuckGo leads because it is the default, not because it sorts first.
    case duckDuckGo
    case bing
    case brave
    case ecosia
    case google
    case mojeek
    case startpage
    case wikipedia
    case yandex

    var id: String { rawValue }

    var title: String {
        switch self {
        case .duckDuckGo: "DuckDuckGo"
        case .bing: "Bing"
        case .brave: "Brave"
        case .ecosia: "Ecosia"
        case .google: "Google"
        case .mojeek: "Mojeek"
        case .startpage: "Startpage"
        case .wikipedia: "Wikipedia"
        case .yandex: "Yandex"
        }
    }

    /// The search page, without the query.
    var address: String {
        switch self {
        case .duckDuckGo: "https://duckduckgo.com/"
        case .bing: "https://www.bing.com/search"
        case .brave: "https://search.brave.com/search"
        case .ecosia: "https://www.ecosia.org/search"
        case .google: "https://www.google.com/search"
        case .mojeek: "https://www.mojeek.com/search"
        case .startpage: "https://www.startpage.com/sp/search"
        case .wikipedia: "https://en.wikipedia.org/w/index.php"
        case .yandex: "https://yandex.com/search/"
        }
    }

    /// Query item the search text goes in.
    ///
    /// Not `q` everywhere: Yandex takes `text`, Startpage takes `query`, and
    /// Wikipedia's index takes `search`. Getting these right is the whole reason
    /// this is per-engine rather than one constant.
    var queryItem: String {
        switch self {
        case .yandex: "text"
        case .startpage: "query"
        case .wikipedia: "search"
        default: "q"
        }
    }

    var resolved: ResolvedSearchEngine {
        ResolvedSearchEngine(title: title, address: address, queryItem: queryItem)
    }

    /// Whether the engine records what is searched for.
    ///
    /// Shown next to the name so the choice is informed rather than a surprise.
    var isPrivate: Bool {
        switch self {
        case .duckDuckGo, .brave, .ecosia, .mojeek, .startpage, .wikipedia: true
        case .bing, .google, .yandex: false
        }
    }
}

/// An engine the user added.
///
/// Stored as strings rather than a `URL` because the address is allowed to contain
/// a `%s` placeholder, which is not a valid percent-escape and so cannot survive a
/// round trip through `URL`.
struct CustomSearchEngine: Codable, Equatable, Identifiable {
    var id: UUID = UUID()
    var name: String = ""
    /// The search page. Either a plain address, in which case the query is added
    /// as `queryItem`, or one containing `%s`, which the query replaces.
    var address: String = ""
    var queryItem: String = "q"

    var resolved: ResolvedSearchEngine {
        ResolvedSearchEngine(title: name, address: address, queryItem: queryItem)
    }
}

/// An engine in the one shape the address field needs, however it was defined.
struct ResolvedSearchEngine: Equatable {
    var title: String
    var address: String
    var queryItem: String

    /// The search URL for `query`.
    ///
    /// Two styles are supported because real engines use both: a `queryItem` added
    /// to an address, and an address carrying a `%s` for the query. The second is
    /// what an engine that puts the query in the path needs, and it cannot be
    /// expressed with `URLComponents`.
    func searchURL(for query: String) -> URL? {
        if address.contains("%s") {
            let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
            return URL(string: address.replacingOccurrences(of: "%s", with: encoded))
        }
        guard let base = URL(string: address) else { return nil }
        var components = URLComponents(url: base, resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: queryItem, value: query)]
        return components?.url
    }
}

extension AppSettings.SearchSettings {
    /// The engine searches actually go to.
    ///
    /// Falls back to DuckDuckGo when `defaultEngine` names something that is not
    /// there, which is reachable: a custom engine can be deleted while selected,
    /// and a document can come from a build that knew an engine this one does not.
    /// Resolving to a fallback beats leaving the address field unable to search.
    func engine() -> ResolvedSearchEngine {
        if let custom = customEngines.first(where: { $0.id.uuidString == defaultEngine }) {
            return custom.resolved
        }
        if let predefined = PredefinedSearchEngine(rawValue: defaultEngine) {
            return predefined.resolved
        }
        return PredefinedSearchEngine.duckDuckGo.resolved
    }

    /// The custom engine with `id`, if there is one.
    func customEngine(id: String) -> CustomSearchEngine? {
        customEngines.first { $0.id.uuidString == id }
    }

    /// Whether `id` names the selected engine, for the radio column.
    func isSelected(_ id: String) -> Bool {
        defaultEngine == id
    }
}

/// Checks a custom engine before it is saved.
///
/// Returns the reason it cannot be saved, or nil when it is fine. Used by the add
/// form so the button can be disabled and the row can say why, rather than
/// accepting an engine that would silently fail every search.
enum CustomEngineValidator {
    static func problem(
        name: String,
        address: String,
        queryItem: String
    ) -> String? {
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Give the engine a name."
        }
        let trimmedAddress = address.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedAddress.isEmpty {
            return "Enter the search address."
        }
        let lowercased = trimmedAddress.lowercased()
        guard lowercased.hasPrefix("http://") || lowercased.hasPrefix("https://") else {
            return "The address must start with http:// or https://"
        }

        // A template address is checked by substituting a stand-in for the query,
        // since that is the string that actually has to parse.
        if trimmedAddress.contains("%s") {
            let probe = trimmedAddress.replacingOccurrences(of: "%s", with: "test")
            guard URL(string: probe) != nil else {
                return "That address is not valid."
            }
            return nil
        }

        if queryItem.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Enter the query parameter, usually q."
        }
        guard URL(string: trimmedAddress) != nil else {
            return "That address is not valid."
        }
        return nil
    }
}