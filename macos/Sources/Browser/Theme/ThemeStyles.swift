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
import QuartzCore

/// One node of the chrome style tree sent to `bc_theme_resolve`: the fixed
/// chrome structure with live states. Keys are region-stable (`"tabs"`,
/// `"tab:<uuid>"`, `"addressbar"`, …) so the resolved map applies back to
/// the view that described itself.
struct ThemeNode: Encodable {
    var key: String
    var element: String
    var id: String = ""
    var classes: [String] = []
    var states: [String] = []
    var children: [ThemeNode] = []

    /// `{key: {property: canonical-value}}` decoded from a resolve document.
    static func styles(from data: Data) -> [String: [String: String]] {
        guard let document = try? JSONDecoder().decode(ResolveDocument.self, from: data) else {
            return [:]
        }
        return document.styles
    }

    /// The `{nodes: [...]}` document for a resolve call.
    static func document(_ nodes: [ThemeNode]) -> String? {
        guard let data = try? JSONEncoder().encode(NodesDocument(nodes: nodes)) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    private struct NodesDocument: Encodable {
        var nodes: [ThemeNode]
    }

    private struct ResolveDocument: Decodable {
        var styles: [String: [String: String]]
    }
}

/// A parsed `linear-gradient()`: direction in degrees clockwise from
/// pointing up — the same convention as the structured gradient's `angle`,
/// so one maps onto the other without conversion — plus opaque-or-not stops.
struct ThemeGradient {
    var angle: Double
    var colors: [NSColor]
}

/// Typed reads over one node's resolved `{property: value}` map. Canonical
/// values come from the core (`#rrggbb[aa]`, `Npx`, `0..1`), so parsing here
/// is strict: anything unexpected reads as nil and the structured theme
/// stands, which keeps a core/Swift version skew from painting garbage.
enum ThemeStyleValue {
    /// `#rrggbb` or `#rrggbbaa` to an sRGB color.
    static func color(_ props: [String: String], _ name: String) -> NSColor? {
        guard let raw = props[name], raw.hasPrefix("#") else { return nil }
        let hex = String(raw.dropFirst())
        guard hex.count == 6 || hex.count == 8,
              let value = UInt64(hex, radix: 16)
        else { return nil }
        let divisor = 255.0
        if hex.count == 6 {
            return NSColor(
                srgbRed: CGFloat(Double((value >> 16) & 0xFF) / divisor),
                green: CGFloat(Double((value >> 8) & 0xFF) / divisor),
                blue: CGFloat(Double(value & 0xFF) / divisor),
                alpha: 1
            )
        }
        return NSColor(
            srgbRed: CGFloat(Double((value >> 24) & 0xFF) / divisor),
            green: CGFloat(Double((value >> 16) & 0xFF) / divisor),
            blue: CGFloat(Double((value >> 8) & 0xFF) / divisor),
            alpha: CGFloat(Double(value & 0xFF) / divisor)
        )
    }

    /// `Npx` to points. Unitless and other units never arrive (the core only
    /// emits `px`), so anything else is nil rather than guessed.
    static func length(_ props: [String: String], _ name: String) -> CGFloat? {
        guard let raw = props[name], raw.hasSuffix("px") else { return nil }
        guard let value = Double(raw.dropLast(2)) else { return nil }
        return CGFloat(value)
    }

    /// `0..1` number to a clamped double.
    static func opacity(_ props: [String: String], _ name: String) -> Double? {
        guard let raw = props[name], let value = Double(raw) else { return nil }
        return min(max(value, 0), 1)
    }

    /// Unitless point size: the core emits font sizes as `Npx`.
    static func fontSize(_ props: [String: String]) -> CGFloat? {
        length(props, "font-size")
    }

    /// `linear-gradient(<dir>, <color>, …)` with bare color stops, matching
    /// exactly what the core canonicalizes. Directions: `to <side>{1,2}`
    /// (corners interpolate to 45/135/225/315) or `Ndeg`.
    static func gradient(_ props: [String: String]) -> ThemeGradient? {
        guard let raw = props["background-image"] else { return nil }
        let prefix = "linear-gradient("
        guard raw.hasPrefix(prefix), raw.hasSuffix(")") else { return nil }
        let inner = String(raw.dropFirst(prefix.count).dropLast())
        let args = splitTopLevel(inner)
        guard args.count >= 3 else { return nil }
        let angle: Double?
        let first = args[0].trimmingCharacters(in: .whitespaces).lowercased()
        if first.hasPrefix("to ") {
            angle = angleForDirection(String(first.dropFirst(3)))
        } else if first.hasSuffix("deg"), let degrees = Double(first.dropLast(3)) {
            angle = degrees
        } else {
            return nil
        }
        guard let resolved = angle else { return nil }
        var colors: [NSColor] = []
        for stop in args.dropFirst() {
            guard let color = parseHexColor(stop.trimmingCharacters(in: .whitespaces)) else {
                return nil
            }
            colors.append(color)
        }
        guard colors.count >= 2 else { return nil }
        return ThemeGradient(angle: resolved, colors: colors)
    }

    private static func angleForDirection(_ text: String) -> Double? {
        let words = text.split(separator: " ").map(String.init)
        guard words.count >= 1, words.count <= 2 else { return nil }
        let has = { (side: String) in words.contains(side) }
        switch (has("top"), has("bottom"), has("left"), has("right")) {
        case (true, false, false, false): return 0
        case (false, false, false, true): return 90
        case (false, true, false, false): return 180
        case (false, false, true, false): return 270
        case (true, false, false, true): return 45
        case (false, true, false, true): return 135
        case (false, true, true, false): return 225
        case (true, false, true, false): return 315
        default: return nil
        }
    }

    private static func parseHexColor(_ text: String) -> NSColor? {
        color(["v": text], "v")
    }

    /// A `CAGradientLayer` for a resolved theme gradient. Stops space out
    /// evenly (CSS bare stops carry no positions); the angle math matches
    /// the structured gradient's, degrees clockwise from pointing up.
    static func makeGradientLayer(_ gradient: ThemeGradient) -> CAGradientLayer {
        let layer = CAGradientLayer()
        layer.colors = gradient.colors.map { $0.cgColor }
        let radians = CGFloat(gradient.angle) * .pi / 180
        let dx = sin(radians) / 2
        let dy = cos(radians) / 2
        layer.startPoint = CGPoint(x: 0.5 - dx, y: 0.5 + dy)
        layer.endPoint = CGPoint(x: 0.5 + dx, y: 0.5 - dy)
        return layer
    }

    /// Splits on top-level commas, respecting nested parens.
    private static func splitTopLevel(_ text: String) -> [String] {
        var parts: [String] = []
        var depth = 0
        var current = ""
        for char in text {
            if char == "(" { depth += 1 }
            if char == ")" { depth = max(0, depth - 1) }
            if char == ",", depth == 0 {
                parts.append(current)
                current = ""
            } else {
                current.append(char)
            }
        }
        parts.append(current)
        return parts
    }
}
