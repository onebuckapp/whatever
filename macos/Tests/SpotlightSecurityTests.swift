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

import Testing
@testable import Whatever

/// Address-bar lock semantics: only a positively insecure connection reads
/// as unsecured. Everything else shows the lock.
struct SpotlightSecurityTests {
    @Test("only plain http is unsecure")
    func onlyHttpIsUnsecure() {
        #expect(SpotlightField.isSecureScheme("http") == false)
        #expect(SpotlightField.isSecureScheme("HTTP") == false)
    }

    @Test("https, files, and empty states show the lock")
    func everythingElseIsSecure() {
        #expect(SpotlightField.isSecureScheme("https"))
        #expect(SpotlightField.isSecureScheme("HTTPS"))
        #expect(SpotlightField.isSecureScheme("file"))
        #expect(SpotlightField.isSecureScheme(nil))
        #expect(SpotlightField.isSecureScheme(""))
    }
}
