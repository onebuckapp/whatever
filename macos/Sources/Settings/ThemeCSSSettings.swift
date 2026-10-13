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

import Combine
import SwiftUI

/// The Custom CSS group in Appearance: a read-only managed preview, the
/// hand-written user block with highlighting and policy underlines, and
/// Apply/Revert. Lives inside Appearance alongside the other groups and
/// emits groups rather than a pane.
///
/// The two-way contract, in one place: controls regenerate the managed
/// block (previewed, never edited); Apply parses the user block, maps what
/// has a control counterpart back into settings, and stores the whole block
/// as `customCSS` in the same update. What remains applies as a CSS-only
/// override through the cascade and still repaints live.
struct ThemeCSSSettingsGroups: View {
    @ObservedObject private var store = SettingsStore.shared
    @ObservedObject private var engine = ThemeEngine.shared

    /// Draft of the user block. Seeded once on appear: the card keeps panes
    /// mounted, so a blind reseed would clobber typing on every return.
    @State private var draft = ""
    @State private var seeded = false
    @State private var diagnostics: [ThemeCSSDiagnostic] = []
    @State private var status: String?
    @State private var applying = false
    @State private var checking = false
    @State private var helpText: String?
    private static let maxBytes = 200_000

    @State private var generation = 0
    @State private var checkWork: DispatchWorkItem?
    @State private var cancellables = Set<AnyCancellable>()

    private var customCSS: String {
        store.settings.appearance.customCSS
    }

    private var isDirty: Bool {
        draft != customCSS
    }

    private var errorCount: Int {
        diagnostics.filter { $0.severity == "error" }.count
    }

    private var warningCount: Int {
        diagnostics.filter { $0.severity == "warning" }.count
    }

    var body: some View {
        SettingsGroup(
            title: tr("Custom CSS", ctx: "Settings.Appearance"),
            footnote: tr(
                "A stylesheet for the browser chrome, GTK-style. Rules that match a control update it; the rest applies as an override and still repaints live.",
                ctx: "Settings.Appearance")
        ) {
            managedPreview
            ThemeCSSTextView(text: $draft, diagnostics: diagnostics)
                .frame(minHeight: 180)
                .onChange(of: draft) { scheduleCheck() }
            statusRow
            helpDisclosure
        }
        .onAppear {
            if !seeded {
                seeded = true
                draft = customCSS
                scheduleCheck()
            }
            if helpText == nil {
                Task { @MainActor in helpText = await Self.loadHelp() }
            }
        }
    }

    // MARK: - Managed preview

    private var managedPreview: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(tr("Managed — regenerated from the controls above", ctx: "Settings.Appearance"))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            ScrollView {
                Text(engine.managedCSS.isEmpty
                    ? tr("Nothing yet — still generating.", ctx: "Settings.Appearance")
                    : engine.managedCSS)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(height: 110)
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color(nsColor: .separatorColor), lineWidth: 1))
        }
    }

    // MARK: - Status and actions

    private var statusRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Button(tr("Apply", ctx: "Settings.Appearance")) { apply() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(!isDirty || applying || errorCount > 0)
                Button(tr("Revert", ctx: "Settings.Appearance")) {
                    draft = customCSS
                    status = nil
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(!isDirty || applying)
                if checking || applying {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            if let status {
                Text(status)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } else if errorCount > 0 || warningCount > 0 {
                Text(summaryText(errors: errorCount, warnings: warningCount))
                    .font(.system(size: 11))
                    .foregroundStyle(errorCount > 0 ? .red : .orange)
            } else if !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(tr("Clean — Apply stores it and updates matching controls.", ctx: "Settings.Appearance"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func summaryText(errors: Int, warnings: Int) -> String {
        if errors > 0, warnings > 0 {
            tr(
                "{errors} errors and {warnings} warnings — errors block Apply.",
                ctx: "Settings.Appearance",
                args: ["errors": String(errors), "warnings": String(warnings)])
        } else if errors > 0 {
            tr(
                "{errors} errors — they block Apply.",
                ctx: "Settings.Appearance",
                args: ["errors": String(errors)])
        } else {
            tr(
                "{warnings} warnings — Apply still works, flagged rules are skipped.",
                ctx: "Settings.Appearance",
                args: ["warnings": String(warnings)])
        }
    }

    // MARK: - Help

    private var helpDisclosure: some View {
        DisclosureGroup(
            tr("Supported selectors & properties", ctx: "Settings.Appearance")
        ) {
            Text(helpText ?? tr("Loading…", ctx: "Settings.Appearance"))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
        .font(.system(size: 11))
    }

    private static func loadHelp() async -> String {
        guard let data = await ThemeEngine.shared.spec(),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return "background-color, color, border-color, border-radius, border-width, font-size, opacity, background-image: linear-gradient(…)"
        }
        var lines: [String] = []
        if let elements = json["elements"] as? [String] {
            lines.append(elements.joined(separator: " "))
        }
        if let ids = json["ids"] as? [String] {
            lines.append(ids.map { "#\($0)" }.joined(separator: " "))
        }
        if let classes = json["classes"] as? [String] {
            // `.tab` alone plus the meaningful compounds: plain `.group`
            // never matches without its tab.
            lines.append(
                ([".tab", ".tab.group", ".tab.pill", ".tab.attached"] +
                    classes.filter { !["tab", "group", "pill", "attached"].contains($0) }
                        .map { ".\($0)" })
                    .joined(separator: " "))
        }
        if let pseudos = json["pseudos"] as? [String] {
            lines.append(pseudos.map { ":\($0)" }.joined(separator: " "))
        }
        lines.append("")
        if let props = json["properties"] as? [String: [String]] {
            for group in ["colors", "lengths", "numbers", "gradients"] {
                if let names = props[group] {
                    lines.append(names.joined(separator: " "))
                }
            }
        }
        lines.append("")
        lines.append("Example:")
        lines.append(".tab:active {")
        lines.append("  background-color: #2a2c31;")
        lines.append("  color: #ffffff;")
        lines.append("  border-radius: 8px;")
        lines.append("}")
        return lines.joined(separator: "\n")
    }

    // MARK: - Check and Apply

    private func scheduleCheck() {
        checkWork?.cancel()
        status = nil
        let work = DispatchWorkItem {
            checking = true
            generation += 1
            let current = generation
            let text = draft
            Task { @MainActor in
                var found: [ThemeCSSDiagnostic] = []
                do {
                    let data = try await StoreClient.shared.themeCheck(text)
                    if current == generation {
                        found = ThemeCSSDiagnostic.list(from: data)
                    }
                } catch {
                    if current == generation {
                        found = []
                    }
                }
                if current == generation {
                    diagnostics = found
                    checking = false
                }
            }
        }
        checkWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    private func apply() {
        guard draft.utf8.count <= Self.maxBytes else {
            status = tr(
                "Too large — keep stylesheets under 200 KB.",
                ctx: "Settings.Appearance")
            return
        }
        applying = true
        generation += 1
        let current = generation
        let text = draft
        Task { @MainActor in
            defer {
                if current == generation { applying = false }
            }
            do {
                let checkData = try await StoreClient.shared.themeCheck(text)
                guard current == generation else { return }
                let found = ThemeCSSDiagnostic.list(from: checkData)
                diagnostics = found
                let errors = found.filter { $0.severity == "error" }
                guard errors.isEmpty else {
                    status = summaryText(
                        errors: errors.count,
                        warnings: found.count - errors.count)
                    return
                }
                let declData = try await StoreClient.shared.themeDeclarations(text)
                guard current == generation else { return }
                let declarations = ThemeDeclaration.list(from: declData)
                var outcome = ThemeCSSSync.Outcome()
                SettingsStore.shared.update { settings in
                    settings.appearance.customCSS = text
                    outcome = ThemeCSSSync.mapInto(declarations, &settings)
                }
                await ThemeEngine.shared.refreshManaged()
                guard current == generation else { return }
                if outcome.cssOnly == 0 {
                    status = tr(
                        "Applied — {count} declarations update controls.",
                        ctx: "Settings.Appearance",
                        args: ["count": String(outcome.updated)])
                } else if outcome.updated == 0 {
                    status = tr(
                        "Stored — everything applies as a CSS override, no controls changed.",
                        ctx: "Settings.Appearance")
                } else {
                    status = tr(
                        "Applied — {updated} update controls, {cssOnly} stay CSS-only overrides.",
                        ctx: "Settings.Appearance",
                        args: [
                            "updated": String(outcome.updated),
                            "cssOnly": String(outcome.cssOnly),
                        ])
                }
            } catch {
                guard current == generation else { return }
                status = tr(
                    "The theme service did not answer — try again.",
                    ctx: "Settings.Appearance")
            }
        }
    }
}
