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

/// The session document keeps splits: window layouts round-trip.
struct SessionSnapshotTests {
    private func tab(id: UUID = UUID(), url: String = "https://example.com") -> SessionSnapshot.TabSnapshot {
        SessionSnapshot.TabSnapshot(
            id: id,
            url: url,
            title: nil,
            isPinned: false,
            history: [url],
            historyIndex: 0
        )
    }

    @Test("a split layout survives encoding")
    func splitRoundTrip() throws {
        let leading = UUID()
        let trailing = UUID()
        let snapshot = SessionSnapshot(windows: [
            SessionSnapshot.WindowSnapshot(
                tabs: [tab(id: leading), tab(id: trailing)],
                selectedTabID: trailing,
                layout: .split(leading: leading, trailing: trailing, ratio: 0.4)
            ),
        ])
        let decoded = try JSONDecoder().decode(
            SessionSnapshot.self,
            from: JSONEncoder().encode(snapshot)
        )
        #expect(decoded == snapshot)
        #expect(decoded.isRestorable)
        guard case .split(let l, let t, let ratio) = decoded.windows[0].layout else {
            Issue.record("split layout did not decode back as split")
            return
        }
        #expect(l == leading)
        #expect(t == trailing)
        #expect(ratio == 0.4)
    }

    @Test("an empty snapshot is not restorable")
    func emptyNotRestorable() {
        #expect(!SessionSnapshot.empty.isRestorable)
        #expect(!SessionSnapshot(windows: []).isRestorable)
    }

    @Test("a hidden split group survives encoding")
    func splitGroupRoundTrip() throws {
        let leading = UUID()
        let trailing = UUID()
        let other = UUID()
        let snapshot = SessionSnapshot(windows: [
            SessionSnapshot.WindowSnapshot(
                tabs: [tab(id: leading), tab(id: trailing), tab(id: other)],
                selectedTabID: other,
                layout: .single(other),
                splitGroup: .split(leading: leading, trailing: trailing, ratio: 0.3)
            ),
        ])
        let decoded = try JSONDecoder().decode(
            SessionSnapshot.self,
            from: JSONEncoder().encode(snapshot)
        )
        #expect(decoded == snapshot)
        guard case .split(let l, let t, let ratio) = decoded.windows[0].splitGroup else {
            Issue.record("split group did not decode back as split")
            return
        }
        #expect(l == leading)
        #expect(t == trailing)
        #expect(ratio == 0.3)
    }

    @Test("documents without a group decode as no group")
    func missingGroupDecodesNil() throws {
        let data = """
            {"windows": [{
                "frame": {"x": 0, "y": 0, "width": 1300, "height": 840},
                "tabs": [],
                "selectedTabID": null,
                "layout": {"single": {"_0": "\(UUID().uuidString)"}}
            }]}
            """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(SessionSnapshot.self, from: data)
        #expect(decoded.windows[0].splitGroup == nil)
    }
}
