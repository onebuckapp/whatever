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

import CryptoKit
import Foundation
import Testing
@testable import Whatever

/// Site-certificate helpers: fingerprint formatting and date display. Pure
/// values — no certificates are minted here; the parsing itself is proven
/// live against real handshakes.
@MainActor
struct SiteCertificateTests {
    @Test("fingerprints print as colon-separated uppercase hex")
    func fingerprintHex() {
        let digest = SHA256.hash(data: Data("abc".utf8))
        #expect(SiteCertificateInfo.fingerprintHex(digest)
            == "BA:78:16:BF:8F:01:CF:EA:41:41:40:DE:5D:AE:22:23:B0:03:61:A3:96:17:7A:9C:B4:10:FF:61:F2:00:15:AD")
    }

    @Test("dates print locale-independently")
    func displayDate() {
        var components = DateComponents()
        components.year = 2027
        components.month = 3
        components.day = 4
        components.hour = 12
        let calendar = Calendar(identifier: .gregorian)
        guard let date = calendar.date(from: components) else {
            Issue.record("fixture date did not build")
            return
        }
        #expect(SiteCertificateInfo.displayDate(date) == "2027-03-04")
    }
}
