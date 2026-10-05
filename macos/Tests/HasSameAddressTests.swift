import Foundation
import Testing
@testable import Whatever

/// Address comparison behind the history reconcile: same page or not.
struct HasSameAddressTests {
    private func url(_ string: String) -> URL {
        URL(string: string)!
    }

    @Test("identical addresses match")
    func identical() {
        #expect(url("https://website.com/products").hasSameAddress(as: url("https://website.com/products")))
    }

    @Test("a bare host matches its trailing-slash form")
    func bareHostTrailingSlash() {
        #expect(url("https://website.com").hasSameAddress(as: url("https://website.com/")))
    }

    @Test("trailing slashes on paths do not matter")
    func pathTrailingSlash() {
        #expect(url("https://website.com/products").hasSameAddress(as: url("https://website.com/products/")))
    }

    @Test("different paths do not match")
    func differentPaths() {
        #expect(!url("https://website.com/products").hasSameAddress(as: url("https://website.com/products/tshirt")))
        #expect(!url("https://website.com").hasSameAddress(as: url("https://website.com/products")))
    }

    @Test("host comparison is case-insensitive")
    func hostCase() {
        #expect(url("https://WEBSITE.com/a").hasSameAddress(as: url("https://website.com/a")))
    }

    @Test("query, fragment, port, and scheme all participate")
    func components() {
        let base = url("https://website.com/a?x=1#s")
        #expect(!base.hasSameAddress(as: url("https://website.com/a?x=2#s")))
        #expect(!base.hasSameAddress(as: url("https://website.com/a?x=1#t")))
        #expect(!base.hasSameAddress(as: url("https://website.com:8443/a?x=1#s")))
        #expect(!base.hasSameAddress(as: url("http://website.com/a?x=1#s")))
        #expect(base.hasSameAddress(as: url("https://website.com/a?x=1#s")))
    }
}
