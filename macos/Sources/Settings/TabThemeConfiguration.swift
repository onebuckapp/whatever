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
import QuartzCore

/// Per-state tab chrome: what fills the cell behind its content, and what
/// colour its text and glyphs take.
///
/// The background reuses `BackgroundMediaConfiguration`, so tabs accept the
/// same solid colours, images, and videos as the window background — stored
/// the same way, with no migration step. The settings UI offers none, solid,
/// image, and video; the cell renderer additionally honours a hand-set
/// gradient rather than dropping it.
///
/// `foreground` is nil for the system look (label/secondary, exactly as
/// before this existed) and a stored colour otherwise.
struct TabThemeConfiguration: Codable, Equatable {
    var background = BackgroundMediaConfiguration()
    var foreground: BackgroundColor?
}

/// How tab cells sit in the strip: attached to the page like Safari's
/// tabs, or floating as pills with breathing room above the page.
///
/// A pill is always fully rounded; the Corner Radius slider applies to
/// the attached shape only.
enum TabShape: String, Codable, Equatable, CaseIterable, Identifiable {
    case attached
    case pills

    /// For `SettingsPickerRow`, which wants each option to be a stable item.
    var id: String { rawValue }

    var title: String {
        switch self {
        case .attached: "Attached"
        case .pills: "Pills"
        }
    }

    /// Whether the cell's bottom corners round. Attached cells keep them
    /// square so they read as joined to the page; pills round everything.
    var roundsBottomCorners: Bool {
        self == .pills
    }

    /// Corner mask for the cell's fill layers. Pills name all four corners:
    /// an empty mask rounds nothing at all, which once painted every pill's
    /// fill square over its rounded outline. Static so the rule is testable
    /// without laying out cells.
    var layerRounding: CACornerMask {
        if roundsBottomCorners {
            [.layerMinXMinYCorner, .layerMaxXMinYCorner, .layerMinXMaxYCorner, .layerMaxXMaxYCorner]
        } else {
            [.layerMinXMaxYCorner, .layerMaxXMaxYCorner]
        }
    }

    /// Corner mask for the page container. Attached pages meet the tab bar
    /// squarely at the top; pills round the top to the same radius as the
    /// bottom, so the floating page reads as one rounded card.
    var pageRounding: CACornerMask {
        if roundsBottomCorners {
            [.layerMinXMinYCorner, .layerMaxXMinYCorner, .layerMinXMaxYCorner, .layerMaxXMaxYCorner]
        } else {
            [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        }
    }

    /// Roundness drawn and clipped at `height` under `setting`.
    ///
    /// Pills ignore the slider and take the full stadium radius instead.
    /// Attached caps the setting at half the height wherever it is used,
    /// so no setting can invert the arcs. Static so the rule is testable
    /// without laying out cells.
    func cornerRadius(setting: CGFloat, height: CGFloat) -> CGFloat {
        switch self {
        case .pills:
            return max(0, height / 2)
        case .attached:
            guard height > 0 else { return max(setting, 0) }
            return min(max(setting, 0), height / 2)
        }
    }
}
