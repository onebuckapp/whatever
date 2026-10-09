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

/// Password generation for the manager: random characters or EFF diceware
/// words.
///
/// Pure and synchronous. Randomness comes from an injected generator so tests
/// can seed it; the UI passes the system one, which is CSPRNG-backed. The
/// wordlist is the bundled EFF large list (see `loadWordlist`).
enum PasswordGenerator {
    struct CharacterOptions: Equatable {
        /// Clamped to 4...128 on use.
        var length: Int
        var lowercase: Bool
        var uppercase: Bool
        var digits: Bool
        var symbols: Bool
    }

    struct WordOptions: Equatable {
        /// Clamped to 2...12 on use.
        var count: Int
        var separator: String
        var capitalize: Bool
        var appendNumber: Bool
    }

    static let lowercaseAlphabet = "abcdefghijklmnopqrstuvwxyz"
    static let uppercaseAlphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
    static let digitAlphabet = "0123456789"
    /// Symbols that survive shells, URLs, and JSON without escaping pain:
    /// no quotes, backslashes, backticks, or spaces.
    static let symbolAlphabet = "!@#$%^&*()-_=+[]{};:,.<>?/~|"
    /// Separator choices the UI offers for words mode.
    static let separatorChoices = ["-", "_", ".", " ", ""]

    /// Random characters from the enabled classes. Every enabled class
    /// appears at least once (when the length allows it); "" when no class
    /// is enabled.
    static func characters<RNG: RandomNumberGenerator>(
        _ options: CharacterOptions,
        using rng: inout RNG
    ) -> String {
        var classes: [String] = []
        if options.lowercase { classes.append(lowercaseAlphabet) }
        if options.uppercase { classes.append(uppercaseAlphabet) }
        if options.digits { classes.append(digitAlphabet) }
        if options.symbols { classes.append(symbolAlphabet) }
        guard !classes.isEmpty else { return "" }

        let length = min(max(options.length, 4), 128)
        let alphabet = classes.joined()
        // One guaranteed member per class first, so a short password cannot
        // silently miss a class the user asked for; the rest is uniform over
        // the joined alphabet, then everything is shuffled.
        var picked = classes.prefix(length).compactMap { $0.randomElement(using: &rng) }
        while picked.count < length, let next = alphabet.randomElement(using: &rng) {
            picked.append(next)
        }
        return String(picked.shuffled(using: &rng))
    }

    /// Diceware-style passphrase from the bundled EFF list. "" when the
    /// wordlist is empty or the count is below 2.
    static func words<RNG: RandomNumberGenerator>(
        _ options: WordOptions,
        wordlist: [String],
        using rng: inout RNG
    ) -> String {
        let count = min(max(options.count, 2), 12)
        guard !wordlist.isEmpty else { return "" }
        var picked: [String] = []
        for _ in 0 ..< count {
            guard var word = wordlist.randomElement(using: &rng) else { break }
            if options.capitalize {
                word = word.prefix(1).uppercased() + word.dropFirst()
            }
            picked.append(word)
        }
        var phrase = picked.joined(separator: options.separator)
        if options.appendNumber {
            phrase += options.separator + String(Int.random(in: 0 ... 99, using: &rng))
        }
        return phrase
    }

    /// The bundled EFF large wordlist, in file order. Empty when the
    /// resource is missing, which the UI treats as words mode unavailable.
    static func loadWordlist(bundle: Bundle = .main) -> [String] {
        guard let url = bundle.url(forResource: "eff-large", withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8)
        else {
            return []
        }
        return text.split(separator: "\n").compactMap { row in
            let parts = row.split(separator: "\t")
            guard parts.count == 2 else { return nil }
            return String(parts[1])
        }
    }
}
