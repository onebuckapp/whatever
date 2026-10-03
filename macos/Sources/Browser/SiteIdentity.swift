import Foundation

/// Decides whether two addresses belong to the same website, which is what
/// decides whether a navigation can stay in the page that is already loaded.
///
/// A link within one site is the common case on the web and there is nothing to
/// gain from tearing the page down for it: the new address goes into the same
/// `WKWebView`, so it keeps the same `WKProcessPool`, the same WebContent
/// process, warm caches and a continuous view. Only crossing to a different
/// site replaces the page, which is what keeps unrelated sites isolated from
/// each other's processes.
///
/// ## Why this is not eTLD+1
///
/// The registrable domain would need the public suffix list, which Foundation
/// does not expose, so this uses the conservative rule instead: two addresses are
/// the same site when one host is equal to the other or is a proper subdomain of
/// it. That gets the cases a linear browsing flow actually hits — `example.com`
/// to `www.example.com`, `google.com` to `accounts.google.com` — while never
/// grouping unrelated sites together, which is the direction that would actually
/// cost isolation.
///
/// The gap is sibling subdomains: `mail.example.com` to `docs.example.com` are
/// the same registrable domain but read as different sites here, so that
/// navigation still replaces the page. It fails safe, in that the outcome is the
/// old behaviour rather than a cross-site leak.
enum SiteIdentity {
    /// Whether `next` can be loaded in the view already showing `current`.
    ///
    /// False whenever the answer would be a guess: a missing host, an address
    /// that is not web content, or a scheme change that is not an ordinary
    /// http/https upgrade.
    static func isSameSite(_ current: URL, _ next: URL) -> Bool {
        guard let currentHost = normalizedHost(current),
              let nextHost = normalizedHost(next),
              sharesSchemeFamily(current, next)
        else {
            return false
        }
        if currentHost == nextHost { return true }
        // The dot is what stops `notexample.com` from counting as a subdomain of
        // `example.com`.
        return currentHost.hasSuffix(".\(nextHost)") || nextHost.hasSuffix(".\(currentHost)")
    }

    /// Lowercased host with a trailing root dot removed, or nil when there is
    /// nothing to compare.
    ///
    /// `about:blank` and other hostless addresses return nil so they always take
    /// the replace-the-page path.
    private static func normalizedHost(_ url: URL) -> String? {
        guard let scheme = url.scheme?.lowercased(), scheme != "about" else { return nil }
        guard var host = url.host(percentEncoded: false)?.lowercased(), !host.isEmpty else {
            return nil
        }
        // `example.com.` and `example.com` are the same host.
        if host.hasSuffix(".") { host.removeLast() }
        return host
    }

    /// Whether the two schemes may share a page.
    ///
    /// Ordinary http/https pairs are treated as one scheme so that a site
    /// upgrading itself from http to https stays in the same page. Anything else
    /// has to match exactly, so a custom scheme cannot be mistaken for a web host
    /// that happens to share its name.
    private static func sharesSchemeFamily(_ current: URL, _ next: URL) -> Bool {
        let currentScheme = current.scheme?.lowercased() ?? ""
        let nextScheme = next.scheme?.lowercased() ?? ""
        let webSchemes: Set<String> = ["http", "https"]
        return webSchemes.contains(currentScheme) && webSchemes.contains(nextScheme)
            ? true
            : currentScheme == nextScheme
    }
}