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

import SwiftUI

/// The inline generator: mode, options, preview, regenerate, use.
///
/// Shared by the manager's credential rows and the suggest popover, so both
/// offer the same characters and EFF diceware options. `confirmTitle` names
/// the accepting button for its host: "Use" inside the manager, "Fill" in
/// the page popover.
struct PasswordGeneratorPanel: View {
    enum Mode: String, CaseIterable, Identifiable {
        case characters
        case words

        var id: String { rawValue }
        var title: String {
            switch self {
            case .characters: tr("Characters", ctx: "Passwords")
            case .words: tr("Words", ctx: "Passwords")
            }
        }
    }

    let wordlist: [String]
    let onUse: (String) -> Void
    var confirmTitle: String = tr("Use", ctx: "Passwords")

    @State private var mode: Mode = .characters
    @State private var length = 20.0
    @State private var lowercase = true
    @State private var uppercase = true
    @State private var digits = true
    @State private var symbols = true
    @State private var wordCount = 4.0
    @State private var separator = "-"
    @State private var capitalize = false
    @State private var appendNumber = true
    @State private var preview = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker(tr("Mode", ctx: "Passwords"), selection: $mode) {
                ForEach(Mode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .onChange(of: mode) { regenerate() }
            if mode == .characters {
                HStack {
                    Text(tr("Length: {n}", ctx: "Passwords", args: ["n": "\(Int(length))"]))
                        .font(.system(size: 12))
                    Slider(value: $length, in: 8 ... 64, step: 1)
                        .onChange(of: length) { regenerate() }
                }
                toggles(
                    (tr("Lowercase", ctx: "Passwords"), $lowercase),
                    (tr("Uppercase", ctx: "Passwords"), $uppercase),
                    (tr("Digits", ctx: "Passwords"), $digits),
                    (tr("Symbols", ctx: "Passwords"), $symbols)
                )
            } else {
                HStack {
                    Text(tr("Words: {n}", ctx: "Passwords", args: ["n": "\(Int(wordCount))"]))
                        .font(.system(size: 12))
                    Slider(value: $wordCount, in: 3 ... 8, step: 1)
                        .onChange(of: wordCount) { regenerate() }
                }
                HStack {
                    Picker(tr("Separator", ctx: "Passwords"), selection: $separator) {
                        ForEach(PasswordGenerator.separatorChoices, id: \.self) { choice in
                            Text(separatorTitle(choice)).tag(choice)
                        }
                    }
                    .frame(maxWidth: 150)
                    .onChange(of: separator) { regenerate() }
                    Toggle(tr("Capitalize", ctx: "Passwords"), isOn: $capitalize)
                        .onChange(of: capitalize) { regenerate() }
                    Toggle(tr("Number", ctx: "Passwords"), isOn: $appendNumber)
                        .onChange(of: appendNumber) { regenerate() }
                }
                .font(.system(size: 12))
            }
            Text(preview.isEmpty ? "—" : preview)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color(nsColor: .textBackgroundColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                )
            HStack {
                Spacer()
                Button(tr("Regenerate", ctx: "Passwords")) { regenerate() }
                    .controlSize(.small)
                Button(confirmTitle) { onUse(preview) }
                    .controlSize(.small)
                    .keyboardShortcut(.defaultAction)
                    .disabled(preview.isEmpty)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .onAppear(perform: regenerate)
    }

    private func toggles(_ pairs: (String, Binding<Bool>)...) -> some View {
        HStack {
            ForEach(0 ..< pairs.count, id: \.self) { index in
                Toggle(pairs[index].0, isOn: pairs[index].1)
                    .onChange(of: pairs[index].1.wrappedValue) { regenerate() }
            }
        }
        .font(.system(size: 12))
    }

    private func separatorTitle(_ separator: String) -> String {
        switch separator {
        case "-": tr("Hyphen (-)", ctx: "Passwords")
        case "_": tr("Underscore (_)", ctx: "Passwords")
        case ".": tr("Dot (.)", ctx: "Passwords")
        case " ": "Space"
        case "": "None"
        default: separator
        }
    }

    private func regenerate() {
        var rng = SystemRandomNumberGenerator()
        switch mode {
        case .characters:
            preview = PasswordGenerator.characters(
                .init(
                    length: Int(length),
                    lowercase: lowercase,
                    uppercase: uppercase,
                    digits: digits,
                    symbols: symbols
                ),
                using: &rng
            )
        case .words:
            preview = PasswordGenerator.words(
                .init(
                    count: Int(wordCount),
                    separator: separator,
                    capitalize: capitalize,
                    appendNumber: appendNumber
                ),
                wordlist: wordlist,
                using: &rng
            )
        }
    }
}
