import Foundation
import Testing
@testable import Whatever

/// The `w://settings` address-bar command: recognized or not.
struct SettingsAddressTests {
    private func url(_ string: String) -> URL {
        URL(string: string)!
    }

    @Test("the settings address is recognized")
    func settings() {
        #expect(BrowserWindowController.isSettingsAddress(url("w://settings")))
    }

    @Test("a trailing slash still counts")
    func trailingSlash() {
        #expect(BrowserWindowController.isSettingsAddress(url("w://settings/")))
    }

    @Test("the retired scheme alias counts too")
    func retiredScheme() {
        #expect(BrowserWindowController.isSettingsAddress(url("whtvr://settings")))
    }

    @Test("other w addresses are plain navigations")
    func otherWAddresses() {
        #expect(!BrowserWindowController.isSettingsAddress(url("w://about")))
        #expect(!BrowserWindowController.isSettingsAddress(url("w://homepage/whatever_logo.svg")))
    }

    @Test("web addresses are not settings")
    func web() {
        #expect(!BrowserWindowController.isSettingsAddress(url("https://example.com/settings")))
        #expect(!BrowserWindowController.isSettingsAddress(url("https://settings.example.com")))
    }
}
