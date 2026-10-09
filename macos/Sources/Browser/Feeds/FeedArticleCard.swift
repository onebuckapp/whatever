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

import AppKit
import SwiftUI

/// One small reader card: thumbnail, site identity, title, and description.
struct FeedArticleCard: View {
    let article: FeedArticleSummary
    let favicon: NSImage?
    let thumbnail: NSImage?
    let onOpen: () -> Void
    let onToggleRead: () -> Void
    let onToggleSaved: () -> Void
    let onCopyLink: () -> Void

    var body: some View {
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: 8) {
                thumbnailView
                HStack(spacing: 6) {
                    siteIcon
                    Text(article.displaySite)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text(FeedTimestamp.text(for: article.publishedAt))
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                    if !article.isRead {
                        Circle()
                            .fill(Color.accentColor)
                            .frame(width: 7, height: 7)
                            .accessibilityLabel("Unread")
                    }
                }
                Text(article.displayTitle)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                if !article.summary.isEmpty {
                    Text(article.summary)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .multilineTextAlignment(.leading)
                }
                HStack {
                    Button(action: onToggleRead) {
                        Label(
                            article.isRead ? "Mark unread" : "Mark read",
                            systemImage: article.isRead ? "envelope.open" : "envelope"
                        )
                    }
                    Button(action: onToggleSaved) {
                        Label(
                            article.isSaved ? "Saved" : "Save",
                            systemImage: article.isSaved ? "bookmark.fill" : "bookmark"
                        )
                    }
                    Spacer(minLength: 4)
                    Button(action: onCopyLink) {
                        Label("Copy link", systemImage: "link")
                            .labelStyle(.iconOnly)
                    }
                    .help("Copy article link")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color(nsColor: .separatorColor).opacity(0.6), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(article.displayTitle). \(article.displaySite)")
        .accessibilityHint("Opens the article reader view.")
        .contextMenu {
            Button(article.isRead ? "Mark as unread" : "Mark as read", action: onToggleRead)
            Button(article.isSaved ? "Remove saved mark" : "Save article", action: onToggleSaved)
            Button("Copy link", action: onCopyLink)
        }
    }

    @ViewBuilder
    private var thumbnailView: some View {
        if let thumbnail {
            Image(nsImage: thumbnail)
                .resizable()
                .aspectRatio(16 / 9, contentMode: .fill)
                .frame(maxWidth: .infinity)
                .frame(height: 120)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .accessibilityHidden(true)
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color(nsColor: .windowBackgroundColor))
                if let favicon {
                    Image(nsImage: favicon)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 34, height: 34)
                        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                } else {
                    Text(String(article.displaySite.prefix(1)).uppercased())
                        .font(.system(size: 26, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(height: 120)
            .accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private var siteIcon: some View {
        if let favicon {
            Image(nsImage: favicon)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 16, height: 16)
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                .accessibilityHidden(true)
        } else {
            Image(systemName: "globe")
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
                .frame(width: 16, height: 16)
                .accessibilityHidden(true)
        }
    }
}
