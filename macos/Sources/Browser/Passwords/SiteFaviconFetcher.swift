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
import Foundation

/// Site icons for the password manager.
///
/// Fetches `https://<host>/favicon.ico` directly — no third party, in line
/// with everything else — and processes it through the feed pipeline (64px
/// PNG, base64), so the vault stores the same compact bytes the feeds store.
/// Best-effort by design: a site without a reachable icon keeps the globe,
/// and a host that failed once is not retried for the life of the process.
enum SiteFaviconFetcher {
    private static var failedHosts = Set<String>()

    /// Processed PNG bytes as base64, or nil when there is nothing fetchable.
    /// Never throws: failures read as "no icon".
    static func fetchBase64(for url: URL) async -> String? {
        guard let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              let host = url.host?.lowercased(),
              !failedHosts.contains(host)
        else {
            return nil
        }
        guard let iconURL = URL(string: "/favicon.ico", relativeTo: url) else {
            return nil
        }
        do {
            var request = URLRequest(url: iconURL)
            request.timeoutInterval = 10
            request.setValue(
                "image/avif,image/webp,image/png,image/*,*/*;q=0.8",
                forHTTPHeaderField: "Accept"
            )
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200 ..< 300).contains(http.statusCode),
                  !data.isEmpty,
                  let image = NSImage(data: data)
            else {
                failedHosts.insert(host)
                return nil
            }
            let processed = try await FeedFetcher.shared.processFaviconImage(image, remoteURL: iconURL)
            return processed.base64
        } catch {
            failedHosts.insert(host)
            return nil
        }
    }
}
