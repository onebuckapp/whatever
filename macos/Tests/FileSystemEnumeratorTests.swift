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

/// The directory walker behind the file browser popup, driven directly:
/// no popup, no XPC, no WebKit. Fixtures live under a fresh temp directory
/// per test, so the real filesystem's state never leaks in.
struct FileSystemEnumeratorTests {
    private func fixture() throws -> String {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("whatever-fs-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root.path
    }

    private func write(_ name: String, in root: String, contents: String = "x") throws {
        try contents.write(
            to: URL(fileURLWithPath: root).appendingPathComponent(name),
            atomically: true,
            encoding: .utf8
        )
    }

    private func collect(
        _ directory: String,
        entryCap: Int = 20000,
        batchSize: Int = 200
    ) async throws -> (entries: [FileSystemEnumerator.RawEntry], batches: Int, skipped: Int, capped: Bool) {
        var entries: [FileSystemEnumerator.RawEntry] = []
        var batches = 0
        var skipped = 0
        var capped = false
        for try await batch in FileSystemEnumerator.children(of: directory, entryCap: entryCap, batchSize: batchSize) {
            batches += 1
            entries.append(contentsOf: batch.entries)
            skipped = batch.skipped
            capped = batch.capped || capped
        }
        return (entries, batches, skipped, capped)
    }

    @Test("lists children with metadata")
    func listsChildren() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(atPath: root) }
        try FileManager.default.createDirectory(atPath: root + "/docs", withIntermediateDirectories: true)
        try write("b.txt", in: root, contents: "bee")
        try write("a.txt", in: root, contents: "ay")
        try write(".hidden", in: root, contents: "shh")

        let listed = try await collect(root)
        let byName = Dictionary(uniqueKeysWithValues: listed.entries.map { ($0.name, $0) })
        #expect(listed.entries.count == 4)
        #expect(byName["docs"]?.isDir == true)
        #expect(byName["a.txt"]?.isDir == false)
        #expect(byName["a.txt"]?.size == 2)
        // Parent compared by name: enumeration reports canonical paths
        // (`/private/var/…`) while the fixture was built through the
        // symlinked form (`/var/…`), so prefix comparison never holds.
        let parentName = URL(fileURLWithPath: root).lastPathComponent
        for entry in listed.entries {
            #expect(entry.path.hasSuffix("/" + entry.name))
            #expect(URL(fileURLWithPath: entry.path).deletingLastPathComponent().lastPathComponent == parentName)
        }
        #expect(byName["a.txt"]?.hidden == false)
        #expect(byName[".hidden"]?.hidden == true)
        #expect(listed.skipped == 0)
        #expect(listed.capped == false)
    }

    @Test("a broken symlink is listed, not fatal")
    func brokenSymlinkListed() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(atPath: root) }
        try write("real.txt", in: root)
        try FileManager.default.createSymbolicLink(
            atPath: root + "/alias.txt",
            withDestinationPath: root + "/real.txt"
        )
        try FileManager.default.createSymbolicLink(
            atPath: root + "/broken.txt",
            withDestinationPath: root + "/nope-missing"
        )

        let listed = try await collect(root)
        #expect(listed.entries.count == 3)
        #expect(listed.entries.contains(where: { $0.name == "broken.txt" }))
    }

    @Test("cyclic symlinks terminate the walk")
    func cyclicSymlinksTerminate() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(atPath: root) }
        try FileManager.default.createDirectory(atPath: root + "/a", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: root + "/b", withIntermediateDirectories: true)
        // a points into b and b back into a: a descending walk would loop.
        try FileManager.default.createSymbolicLink(atPath: root + "/a/link", withDestinationPath: root + "/b")
        try FileManager.default.createSymbolicLink(atPath: root + "/b/link", withDestinationPath: root + "/a")

        let listed = try await collect(root)
        #expect(listed.entries.count == 2)
    }

    @Test("a missing directory throws unreadable")
    func missingDirectoryThrows() async throws {
        await #expect(throws: FileSystemEnumerator.UnreadableDirectory.self) {
            for try await _ in FileSystemEnumerator.children(of: "/whatever-missing-dir-xyz") {
            }
        }
    }

    @Test("a denied directory throws unreadable")
    func deniedDirectoryThrows() async throws {
        let root = try fixture()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root + "/locked")
            try? FileManager.default.removeItem(atPath: root)
        }
        try FileManager.default.createDirectory(atPath: root + "/locked", withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: root + "/locked")

        await #expect(throws: FileSystemEnumerator.UnreadableDirectory.self) {
            for try await _ in FileSystemEnumerator.children(of: root + "/locked") {
            }
        }
    }

    @Test("the cap stops the walk and says so")
    func capStopsWalk() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(atPath: root) }
        for i in 0..<8 {
            try write("f\(i).txt", in: root)
        }

        let listed = try await collect(root, entryCap: 5, batchSize: 2)
        #expect(listed.entries.count == 5)
        #expect(listed.capped == true)
        #expect(listed.batches >= 2)
    }

    @Test("batches stream progressively")
    func batchesStream() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(atPath: root) }
        for i in 0..<450 {
            try write("f\(i).txt", in: root)
        }

        let listed = try await collect(root, batchSize: 200)
        #expect(listed.entries.count == 450)
        #expect(listed.batches == 3)
    }
}

/// The store's display contract — locale-aware dirs-first sorting and the
/// hidden filter — over a real (small) directory. The walk itself is covered
/// above; this pins what the list shows.
struct FileBrowserStoreTests {
    @Test("sorts directories first and filters hidden files")
    @MainActor
    func sortsAndFilters() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("whatever-fs-store-\(UUID().uuidString)", isDirectory: true).path
        defer { try? FileManager.default.removeItem(atPath: root) }
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: root + "/b", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: root + "/a", withIntermediateDirectories: true)
        try "z".write(to: URL(fileURLWithPath: root + "/z.txt"), atomically: true, encoding: .utf8)
        try "h".write(to: URL(fileURLWithPath: root + "/.hidden"), atomically: true, encoding: .utf8)

        let store = FileBrowserStore(directory: root)
        store.load()
        for _ in 0..<500 {
            if !store.isLoading {
                break
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(store.errorMessage == nil)
        #expect(store.entries.map(\.name) == ["a", "b", "z.txt"])
        store.showHidden = true
        #expect(store.entries.map(\.name) == ["a", "b", ".hidden", "z.txt"])
    }
}
