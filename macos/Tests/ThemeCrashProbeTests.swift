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

import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Whatever

/// TEMPORARY crash probe: mounts the real settings group in a SwiftUI
/// hosting view and types garbage like the screenshot. Delete once the
/// typing crash is found.
struct ThemeCrashProbeTests {
    @MainActor
    private func textView(in root: NSView) -> NSTextView? {
        if let found = root as? NSTextView, found.isEditable {
            return found
        }
        for child in root.subviews {
            if let found = textView(in: child) {
                return found
            }
        }
        return nil
    }

    @Test("real settings group survives garbage typing")
    @MainActor
    func garbageTyping() async throws {
        let hosted = NSHostingView(rootView: ThemeCSSSettingsGroups())
        hosted.frame = NSRect(x: 0, y: 0, width: 500, height: 600)
        let window = NSWindow(
            contentRect: hosted.frame, styleMask: [.titled],
            backing: .buffered, defer: false)
        window.contentView = hosted
        // Let appear + seed + first check run against the live service.
        try await Task.sleep(for: .milliseconds(900))
        guard let view = textView(in: hosted) else {
            Issue.record("no editable text view mounted")
            return
        }
        let garbage = [
            "asdsadsadsa",
            "\n\n\n(((:::",
            String(repeating: ".x{color:red;}\n", count: 200),
            "/* unclosed comment here",
            "\"unclosed string { { {",
            String(repeating: "z", count: 50_000),
        ]
        for (n, chunk) in garbage.enumerated() {
            view.selectedRange = NSRange(
                location: (view.string as NSString).length, length: 0)
            view.insertText(chunk, replacementRange: view.selectedRange)
            // Outlive both debounces and the XPC round trip.
            try await Task.sleep(for: .milliseconds(800))
            view.layoutManager?.ensureLayout(for: view.textContainer!)
            view.displayIfNeeded()
            print("PROBE chunk \(n) ok len=\(view.string.count)")
        }
        print("PROBE done")
    }
}
