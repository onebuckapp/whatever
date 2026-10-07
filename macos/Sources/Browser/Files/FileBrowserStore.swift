import AppKit
import Combine
import Foundation

/// One directory's listing state for the file browser popup.
///
/// Read-only by design: rows are enumerated, never mutated. Batches stream
/// in from a background walk and each one re-sorts and publishes, so the
/// first rows paint in milliseconds and the list settles as the walk
/// finishes. Every load supersedes the last two ways: the task is cancelled
/// to stop the walk, and the generation guards the publishes, so a slow
/// listing for a directory the user already left cannot publish over the
/// current one. Sorting is locale-aware and applied here.
@MainActor
final class FileBrowserStore: ObservableObject {
    @Published private(set) var entries: [FileSystemEnumerator.RawEntry] = []
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var total = 0
    @Published private(set) var hasMore = false
    @Published private(set) var skipped = 0
    @Published var showHidden = false {
        didSet {
            guard showHidden != oldValue else { return }
            applyFilter()
        }
    }

    private(set) var directory: String
    private var allEntries: [FileSystemEnumerator.RawEntry] = []
    private var loadTask: Task<Void, Never>?
    private var generation = 0

    /// A file was chosen: the presenter dismisses the popup and the pane
    /// navigates the tab to it, so WebKit renders it like any other page.
    var onOpenFile: ((URL) -> Void)?

    init(directory: String) {
        self.directory = directory
    }

    /// Path components for the breadcrumb trail, root first. The root
    /// component is `/` rather than an empty string, so it reads as one.
    var breadcrumbs: [String] {
        let parts = directory.split(separator: "/").map(String.init)
        return ["/"] + parts
    }

    /// Absolute path for the breadcrumb at `index`.
    func path(forBreadcrumb index: Int) -> String {
        let parts = directory.split(separator: "/").map(String.init)
        guard index > 0, index <= parts.count else { return "/" }
        return "/" + parts[0..<index].joined(separator: "/")
    }

    var canGoUp: Bool {
        directory != "/"
    }

    /// Selects `path` when it is one of this listing's directories, for the
    /// breadcrumb buttons. Anything else is ignored rather than loaded: the
    /// buttons only ever offer ancestors of the current directory.
    func navigate(to path: String) {
        guard path != directory,
              path == "/" || directory.hasPrefix(path + "/")
        else {
            return
        }
        directory = path
        load()
    }

    func goUp() {
        guard canGoUp else { return }
        navigate(to: (directory as NSString).deletingLastPathComponent)
    }

    func refresh() {
        load()
    }

    /// Opens an entry: directories browse deeper in place, files leave to
    /// the tab. Called from double-click, Enter, and the row button alike.
    func open(_ entry: FileSystemEnumerator.RawEntry) {
        if entry.isDir {
            directory = entry.path
            load()
        } else {
            onOpenFile?(URL(fileURLWithPath: entry.path))
        }
    }

    func load() {
        loadTask?.cancel()
        generation += 1
        let generation = generation
        let directory = directory
        allEntries = []
        entries = []
        total = 0
        hasMore = false
        skipped = 0
        isLoading = true
        errorMessage = nil
        loadTask = Task { [weak self] in
            do {
                for try await batch in FileSystemEnumerator.children(of: directory) {
                    guard let self, self.generation == generation else { return }
                    self.allEntries.append(contentsOf: batch.entries)
                    self.total = self.allEntries.count
                    self.skipped = batch.skipped
                    self.hasMore = batch.capped
                    self.applyFilter()
                    if batch.done {
                        break
                    }
                }
            } catch is CancellationError {
                // Superseded by a newer load, or the popup went away: stale
                // by definition, never an error card.
                return
            } catch {
                guard let self, self.generation == generation else { return }
                self.errorMessage = (error as NSError).localizedDescription
            }
            guard let self, self.generation == generation else { return }
            self.isLoading = false
        }
    }

    private func applyFilter() {
        let visible = showHidden ? allEntries : allEntries.filter { !$0.hidden }
        entries = visible.sorted {
            if $0.isDir != $1.isDir {
                return $0.isDir
            }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }
}
