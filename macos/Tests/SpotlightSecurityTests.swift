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
