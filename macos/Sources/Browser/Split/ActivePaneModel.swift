import Combine
import Foundation

/// Shared per-window split state: which tab is active (drives the
/// single shared toolbar, the window title and the pane highlight) and
/// whether that highlight is shown (split mode only).
final class ActivePaneModel: ObservableObject {
    @Published var activeTabID: UUID?
    @Published var showsIndicator = false
}
