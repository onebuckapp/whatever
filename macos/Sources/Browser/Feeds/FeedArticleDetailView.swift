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

/// Native article detail: persisted title, site identity, hero image, and text.
struct FeedArticleDetailView: View {
    let article: FeedArticleSummary
    let detail: FeedArticleDetail?
    let favicon: NSImage?
    let thumbnail: NSImage?
    let isLoading: Bool
    let onOpenInCurrentTab: () -> Void
    let onOpenInNewTab: () -> Void
    let onClose: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 6) {
                    if let favicon {
                        Image(nsImage: favicon)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 18, height: 18)
                            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                            .accessibilityHidden(true)
                    }
                    Text(article.displaySite)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    Text(FeedTimestamp.text(for: article.publishedAt))
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                }
                Text(article.displayTitle)
                    .font(.system(size: 20, weight: .bold))
                    .multilineTextAlignment(.leading)
                if !article.authors.isEmpty {
                    Text(article.authors.joined(separator: ", "))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                if let thumbnail {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .accessibilityHidden(true)
                }
                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                } else if let body = bodyText, !body.isEmpty {
                    Text(body)
                        .font(.system(size: 13))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Text("Only the summary is available for this article.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Button("Open article", action: onOpenInCurrentTab)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    Button("Open in new tab", action: onOpenInNewTab)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    Spacer(minLength: 8)
                    Button("Back to articles", action: onClose)
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                }
                .padding(.top, 4)
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var bodyText: String? {
        guard let detail else { return article.summary.isEmpty ? nil : article.summary }
        let content = detail.content.isEmpty ? article.summary : detail.content
        return content.isEmpty ? nil : content
    }
}
