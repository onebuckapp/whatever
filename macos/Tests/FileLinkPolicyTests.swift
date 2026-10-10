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

/// The file browser opens from the address bar only: a clicked `file://`
/// link may load a file in the tab, but never a directory in the viewer —
/// any page, local or remote, could otherwise link at the filesystem.
/// Pure statics over real temporary paths.
struct FileLinkPolicyTests {
    private func sandbox() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("FileLinkPolicy-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test("directories are classified, files are not")
    func classifiesDirectories() throws {
        let root = try sandbox()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("page.html")
        FileManager.default.createFile(atPath: file.path, contents: Data())
        #expect(BrowserWindowController.isFileDirectory(URL(fileURLWithPath: root.path)) == true)
        #expect(BrowserWindowController.isFileDirectory(URL(fileURLWithPath: file.path)) == false)
        #expect(BrowserWindowController.isFileDirectory(URL(string: "https://example.com/")!) == false)
    }

    @Test("clicked directory links are refused, file links load")
    func contentLinks() throws {
        let root = try sandbox()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("page.html")
        FileManager.default.createFile(atPath: file.path, contents: Data())
        // The reported flaw: a page linking at a directory opened the
        // native viewer. Now the link is refused.
        #expect(BrowserWindowController.allowsContentFileLink(URL(fileURLWithPath: root.path)) == false)
        #expect(BrowserWindowController.allowsContentFileLink(URL(fileURLWithPath: file.path)) == true)
        // Non-file schemes never reach the file path; the rule says no.
        #expect(BrowserWindowController.allowsContentFileLink(URL(string: "https://example.com/")!) == false)
    }
}
