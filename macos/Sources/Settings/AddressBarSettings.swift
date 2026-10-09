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

/// Address bar chrome: width behaviour, corner roundness, and field height.
///
/// The field stretches full width by default; everything else matches the
/// historical bar (10pt corners, 32pt tall).
struct AddressBarSettings: Codable, Equatable {
    /// Stretches the field across the space between the button clusters
    /// instead of centring a fixed width. Auto Layout re-resolves on every
    /// resize, so this is inherently responsive. On by default: the strip's
    /// empty middle is field, not margin.
    var fillsWidth = true
    /// Corner radius in points. Clamped to half the field height at draw
    /// time, so the maximum reads as a pill.
    var cornerRadius: Double = 10
    /// Field height in points.
    var fieldHeight: Double = 32

    /// Slider bounds for roundness. The top equals half the default height:
    /// at defaults, sliding all the way right makes a full pill.
    static let cornerRadiusRange = 0.0...16.0
    static let fieldHeightRange = 28.0...40.0

    /// What `cornerRadius` draws as in a field of `height`: capped at half
    /// the height, so no setting can invert the arcs.
    static func clampedRadius(_ radius: Double, forHeight height: Double) -> Double {
        min(max(radius, 0), max(height, 0) / 2)
    }
}

/// The address bar's settings rows. Lives inside Appearance with the other
/// chrome groups; every control writes straight through the store, so the
/// strip behind the card follows live.
struct AddressBarSettingsGroups: View {
    @ObservedObject private var store = SettingsStore.shared

    var body: some View {
        SettingsGroup(
            title: "Address Bar",
            footnote: "Size and shape of the field. Follows live as it changes."
        ) {
            SettingsToggleRow(
                title: "Fill Available Width",
                subtitle: "Stretches between the buttons instead of a centred field.",
                isOn: store.binding(\.addressBar.fillsWidth)
            )
            SettingsSliderRow(
                title: "Corner Radius",
                value: store.binding(\.addressBar.cornerRadius),
                range: AddressBarSettings.cornerRadiusRange,
                step: 0.5,
                format: { String(format: "%.1f pt", $0) }
            )
            SettingsSliderRow(
                title: "Field Height",
                value: store.binding(\.addressBar.fieldHeight),
                range: AddressBarSettings.fieldHeightRange,
                step: 1,
                format: { String(format: "%.0f pt", $0) }
            )
        }
    }
}
