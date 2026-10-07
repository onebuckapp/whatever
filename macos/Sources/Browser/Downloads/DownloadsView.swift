import AppKit
import SwiftUI

/// Download history card: every finished or in-flight download, newest first.
///
/// Files deleted from disk since render as dimmed Deleted rows rather than
/// vanishing: the row is history the user may still want to retry or forget
/// on purpose. Opening or revealing a row acts on the file; removing it only
/// forgets the history, never touches the disk.
struct DownloadsView: View {
    @ObservedObject var store: DownloadsStore

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(width: 620, height: 480)
        .background(Color(nsColor: .windowBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .shadow(color: .black.opacity(0.34), radius: 18, x: 0, y: 10)
        .shadow(color: .black.opacity(0.58), radius: 25, x: 0, y: 30)
        // Same symmetric padding as every card: Mijick masks the popup to
        // its measured bounds, so the shadows need transparent room.
        .padding(.vertical, 88)
        .onTapGesture {}
        .task {
            store.load()
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text("Downloads")
                .font(.system(size: 13, weight: .semibold))
            if store.isLoading {
                ProgressView()
                    .controlSize(.small)
            }
            Spacer(minLength: 0)
            Button {
                store.refresh()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Refresh")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var content: some View {
        if let failure = store.failure, store.items.isEmpty {
            VStack(spacing: 8) {
                Text(failure)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("Retry") {
                    store.refresh()
                }
                .controlSize(.small)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if store.items.isEmpty, !store.isLoading {
            Text("No downloads yet.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(store.items) { item in
                DownloadRow(item: item, store: store)
            }
            .listStyle(.plain)
        }
    }

    private var footer: some View {
        HStack {
            Text(footerText)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private var footerText: String {
        switch store.items.count {
        case 0: "Nothing downloaded"
        case 1: "1 item"
        default: "\(store.items.count) items"
        }
    }
}

private struct DownloadRow: View {
    let item: DownloadItem
    @ObservedObject var store: DownloadsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Text(item.filename)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                stateBadge
            }
            Text(detailText)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            if item.fraction != nil {
                ProgressView(value: item.fraction)
                    .progressViewStyle(.linear)
                    .controlSize(.small)
            }
        }
        .padding(.vertical, 4)
        .opacity(item.isMissing ? 0.55 : 1)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            openItem()
        }
        .contextMenu {
            Button("Open") { openItem() }
                .disabled(item.isMissing)
            Button("Reveal in Finder") { revealItem() }
                .disabled(item.isMissing)
            if item.state == .failed {
                Button("Retry") { store.retry(item) }
            }
            Divider()
            Button("Remove from List") {
                Task { await store.remove(item) }
            }
        }
    }

    /// A missing file overrides every other state: the operative fact is that
    /// there is nothing to open, whatever the download ended as.
    private var stateBadge: some View {
        let (text, color): (String, Color) = if item.isMissing {
            ("Deleted", .red)
        } else {
            switch item.state {
            case .inProgress: ("Downloading", .accentColor)
            case .done: ("Done", .secondary)
            case .failed: ("Failed", .red)
            case .cancelled: ("Cancelled", .secondary)
            }
        }
        return Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(color)
    }

    private var detailText: String {
        var parts: [String] = [DownloadFormatters.size(item)]
        parts.append(DownloadFormatters.date(item.startedAt))
        if item.state == .failed, !item.errorText.isEmpty {
            parts.append(item.errorText)
        }
        return parts.joined(separator: " • ")
    }

    private func openItem() {
        guard !item.isMissing else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: item.destinationPath))
    }

    private func revealItem() {
        guard !item.isMissing else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.destinationPath)])
    }
}

private enum DownloadFormatters {
    static let bytes: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()

    static let date: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    /// Known size, downloaded size while running, or date alone when neither
    /// is known — a row never shows a bare "0 bytes" for an indeterminate
    /// transfer.
    static func size(_ item: DownloadItem) -> String {
        if item.bytesExpected > 0, item.state == .inProgress {
            return "\(bytes.string(fromByteCount: item.bytesReceived)) of \(bytes.string(fromByteCount: item.bytesExpected))"
        }
        if item.bytesExpected > 0 {
            return bytes.string(fromByteCount: item.bytesExpected)
        }
        if item.bytesReceived > 0 {
            return bytes.string(fromByteCount: item.bytesReceived)
        }
        return "Unknown size"
    }

    static func date(_ date: Date) -> String {
        Self.date.string(from: date)
    }
}
