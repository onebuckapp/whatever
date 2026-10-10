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

/// Software-update rules: version comparison, disk-image picking, and the
/// release payload. Pure values throughout — no test touches GitHub.
@MainActor
struct AppUpdateSettingsTests {
    @Test("tags parse to numeric components")
    func versionComponents() {
        #expect(AppUpdateSettings.versionComponents("v0.3.0") == [0, 3, 0])
        #expect(AppUpdateSettings.versionComponents("0.2.2") == [0, 2, 2])
        #expect(AppUpdateSettings.versionComponents("V1.0") == [1, 0])
        #expect(AppUpdateSettings.versionComponents("  v0.3.0\n") == [0, 3, 0])
    }

    @Test("newer means strictly newer, numerically")
    func isNewer() {
        #expect(AppUpdateSettings.isNewer(latest: "0.3.0", than: "0.2.2") == true)
        #expect(AppUpdateSettings.isNewer(latest: "v0.3.0", than: "0.2.2") == true)
        #expect(AppUpdateSettings.isNewer(latest: "0.2.10", than: "0.2.2") == true)
        #expect(AppUpdateSettings.isNewer(latest: "0.2.2", than: "0.2.2") == false)
        #expect(AppUpdateSettings.isNewer(latest: "0.3", than: "0.3.0") == false)
        #expect(AppUpdateSettings.isNewer(latest: "0.2.1", than: "0.2.2") == false)
        #expect(AppUpdateSettings.isNewer(latest: "1.0.0", than: "0.9.9") == true)
    }

    private func asset(_ name: String) -> GitHubAsset {
        GitHubAsset(
            name: name,
            browserDownloadURL: URL(string: "https://example.com/\(name)")!
        )
    }

    @Test("the lone disk image wins without an architecture match")
    func loneImageWins() {
        let assets = [asset("Whatever-0.3.0.dmg"), asset("Whatever-0.3.0.zip")]
        #expect(AppUpdateSettings.downloadAsset(from: assets, architecture: .arm64)?.name
            == "Whatever-0.3.0.dmg")
    }

    @Test("multiple images pick the machine's architecture")
    func archMatchWins() {
        let assets = [
            asset("Whatever-0.3.0-x86_64.dmg"),
            asset("Whatever-0.3.0-arm64.dmg"),
        ]
        #expect(AppUpdateSettings.downloadAsset(from: assets, architecture: .arm64)?.name
            == "Whatever-0.3.0-arm64.dmg")
        #expect(AppUpdateSettings.downloadAsset(from: assets, architecture: .x86_64)?.name
            == "Whatever-0.3.0-x86_64.dmg")
    }

    @Test("release builds beat debug builds of the same architecture")
    func releaseBeatsDebug() {
        let assets = [
            asset("Whatever_0.3.0_macos-arm64-debug.dmg"),
            asset("Whatever_0.3.0_macos-arm64.dmg"),
        ]
        #expect(AppUpdateSettings.downloadAsset(from: assets, architecture: .arm64)?.name
            == "Whatever_0.3.0_macos-arm64.dmg")
    }

    @Test("no match and no lone image means no compatible download")
    func noMatchMeansNothing() {        let assets = [
            asset("Whatever-0.3.0-x86_64.dmg"),
            asset("Whatever-0.3.0-arm64.dmg"),
            asset("notes.txt"),
        ]
        #expect(AppUpdateSettings.downloadAsset(from: assets, architecture: .unknown) == nil)
        #expect(AppUpdateSettings.downloadAsset(from: [asset("notes.txt")], architecture: .arm64) == nil)
        #expect(AppUpdateSettings.downloadAsset(from: [], architecture: .arm64) == nil)
    }

    @Test("the release payload decodes to tag and assets")
    func releaseDecodes() throws {
        let json = """
        {
            "tag_name": "v0.3.0",
            "body": "Notes here.",
            "assets": [
                {"name": "Whatever-0.3.0-arm64.dmg", "browser_download_url": "https://example.com/a.dmg"},
                {"name": "Whatever-0.3.0.zip", "browser_download_url": "https://example.com/a.zip"}
            ],
            "extra_field": 42
        }
        """
        let release = try AppUpdateSettings.decoder.decode(GitHubRelease.self, from: Data(json.utf8))
        #expect(release.tagName == "v0.3.0")
        #expect(release.version == "0.3.0")
        #expect(release.assets.count == 2)
    }

    @Test("the idle row names the installed version")
    func idleRow() {
        let settings = AppUpdateSettings(currentVersion: "0.2.2")
        #expect(settings.title == "Software update")
        #expect(settings.subtitle == "Whatever 0.2.2 is installed.")
    }
}
