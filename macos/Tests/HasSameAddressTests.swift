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
