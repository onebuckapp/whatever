import Foundation

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
