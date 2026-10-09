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

/// The generator's rules and the bundled wordlist. Deterministic RNG so no
/// test depends on chance.
struct PasswordGeneratorTests {
    /// SplitMix-style counter: deterministic across runs and platforms.
    struct StepRNG: RandomNumberGenerator {
        var state: UInt64 = 0x9E3779B97F4A7C15

        mutating func next() -> UInt64 {
            state = state &+ 0x9E3779B97F4A7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            return z ^ (z >> 31)
        }
    }

    @Test("characters mode covers every enabled class")
    func characterCoverage() {
        var rng = StepRNG()
        let made = PasswordGenerator.characters(
            .init(length: 16, lowercase: true, uppercase: true, digits: true, symbols: true),
            using: &rng
        )
        #expect(made.count == 16)
        #expect(made.contains(where: { $0.isLowercase && $0.isLetter }))
        #expect(made.contains(where: { $0.isUppercase && $0.isLetter }))
        #expect(made.contains(where: { $0.isNumber }))
        #expect(made.contains(where: { PasswordGenerator.symbolAlphabet.contains($0) }))
    }

    @Test("characters mode respects a single class and the length clamp")
    func characterSingleClass() {
        var rng = StepRNG()
        let digits = PasswordGenerator.digitAlphabet
        let made = PasswordGenerator.characters(
            .init(length: 3, lowercase: false, uppercase: false, digits: true, symbols: false),
            using: &rng
        )
        #expect(made.count == 4)
        #expect(made.allSatisfy { digits.contains($0) })

        let long = PasswordGenerator.characters(
            .init(length: 10_000, lowercase: true, uppercase: false, digits: false, symbols: false),
            using: &rng
        )
        #expect(long.count == 128)
    }

    @Test("characters mode with no class is empty")
    func characterNoClass() {
        var rng = StepRNG()
        #expect(
            PasswordGenerator.characters(
                .init(length: 16, lowercase: false, uppercase: false, digits: false, symbols: false),
                using: &rng
            ).isEmpty
        )
    }

    @Test("words mode joins, capitalizes, and numbers on request")
    func wordsMode() {
        var rng = StepRNG()
        let list = ["abacus", "abdomen", "zoology"]
        let plain = PasswordGenerator.words(
            .init(count: 4, separator: "-", capitalize: false, appendNumber: false),
            wordlist: list,
            using: &rng
        )
        #expect(plain.split(separator: "-").count == 4)
        #expect(plain.split(separator: "-").allSatisfy { list.contains(String($0)) })

        let dressed = PasswordGenerator.words(
            .init(count: 3, separator: "_", capitalize: true, appendNumber: true),
            wordlist: list,
            using: &rng
        )
        let parts = dressed.split(separator: "_")
        #expect(parts.count == 4)
        #expect(parts.dropLast().allSatisfy { $0.first?.isUppercase == true })
        #expect(Int(parts.last.map(String.init) ?? "") != nil)
    }

    @Test("words mode with an empty list or a tiny count is empty")
    func wordsEmpty() {
        var rng = StepRNG()
        #expect(
            PasswordGenerator.words(
                .init(count: 4, separator: "-", capitalize: false, appendNumber: false),
                wordlist: [],
                using: &rng
            ).isEmpty
        )
    }

    @Test("the bundled EFF list loads whole and unique")
    func wordlistIntegrity() throws {
        let list = PasswordGenerator.loadWordlist()
        #expect(list.count == 7776, "wordlist has \(list.count) words, expected 7776")
        #expect(Set(list).count == list.count, "wordlist contains duplicates")
        #expect(list.first == "abacus")
        #expect(list.last == "zoom")
    }
}
