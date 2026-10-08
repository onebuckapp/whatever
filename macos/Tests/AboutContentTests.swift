import AppKit
import Testing
@testable import Whatever

/// About panel credits: tagline, copyright line, and both links.
struct AboutContentTests {
    @Test("credits carry the tagline, copyright, and makers lines")
    func text() {
        let text = AboutContent.credits().string
        #expect(text.contains("Browsing the dead internet"))
        #expect(text.contains("(c) 2026 George Lemon | GPLv3 License"))
        #expect(text.contains("Made by Humans from OpenPeeps for OneBuck.app"))
    }

    @Test("credits link both names")
    func links() {
        let credits = AboutContent.credits()
        let text = credits.string as NSString
        for (name, url) in [
            ("OpenPeeps", AboutContent.openPeepsURL),
            ("OneBuck.app", AboutContent.oneBuckURL),
        ] {
            let range = text.range(of: name)
            #expect(range.location != NSNotFound)
            var found: URL?
            credits.enumerateAttribute(.link, in: range) { value, _, _ in
                found = value as? URL ?? (value as? String).flatMap(URL.init(string:))
            }
            #expect(found == url)
        }
    }
}
