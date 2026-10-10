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
import Combine
import Foundation

/// Software-update state for the General settings pane.
///
/// Checks GitHub's public releases API on demand and, when a newer release
/// exists, downloads its disk image for a manual update. Nothing here is
/// automatic: no background checks, no silent installs. The system is not
/// involved beyond opening Finder on the finished download.
@MainActor
final class AppUpdateSettings: ObservableObject {
    /// What the update row shows.
    enum Status: Equatable {
        /// Nothing checked yet this sitting.
        case idle
        /// The releases API is being asked.
        case checking
        /// Installed version is current.
        case upToDate
        /// A newer release with a compatible disk image.
        case available(version: String)
        /// A newer release exists but ships no disk image for this Mac.
        case noCompatibleDownload(version: String)
        /// The check failed (offline, rate-limited, unparsable).
        case failed(message: String)
        /// The disk image is downloading.
        case downloading(version: String)
        /// The disk image sits in Downloads, revealed on request.
        case downloaded(version: String, fileURL: URL)
    }

    @Published private(set) var status: Status = .idle

    /// The installed version, from the bundle. Injected for tests.
    private let currentVersion: String
    /// Machine architecture picked from at compile time. Injected for tests.
    private let architecture: ProcessorArchitecture
    private let session: URLSession
    /// Latest release already fetched this sitting, so repeated presses do
    /// not burn the unauthenticated rate limit (60 requests an hour).
    private var cachedRelease: GitHubRelease?

    /// GitHub's latest-release endpoint for this project. `/latest` skips
    /// drafts and prereleases, so only a published stable release answers.
    private static let latestReleaseURL = URL(
        string: "https://api.github.com/repos/onebuckapp/whatever/releases/latest"
    )!

    init(
        session: URLSession = .shared,
        currentVersion: String? = nil,
        architecture: ProcessorArchitecture? = nil
    ) {
        self.session = session
        self.currentVersion = currentVersion
            ?? Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
            ?? "0.0.0"
        #if arch(arm64)
        self.architecture = architecture ?? .arm64
        #elseif arch(x86_64)
        self.architecture = architecture ?? .x86_64
        #else
        self.architecture = architecture ?? .unknown
        #endif
    }

    /// Title line for the update row under `status`.
    var title: String {
        switch status {
        case .idle:
            "Software update"
        case .checking:
            "Checking for updates"
        case .upToDate:
            "Whatever is up to date"
        case .available:
            "Update available"
        case .noCompatibleDownload:
            "Update available"
        case .failed:
            "Could not check for updates"
        case .downloading:
            "Downloading update"
        case .downloaded:
            "Update downloaded"
        }
    }

    /// Detail line under the title.
    var subtitle: String {
        switch status {
        case .idle:
            "Whatever \(currentVersion) is installed."
        case .checking:
            "Asking GitHub for the latest release."
        case .upToDate:
            "Whatever \(currentVersion) is the latest release."
        case .available(let version):
            "Whatever \(version) is available — you have \(currentVersion)."
        case .noCompatibleDownload(let version):
            "Whatever \(version) is available, but it ships no disk image for this Mac."
        case .failed(let message):
            message
        case .downloading(let version):
            "Downloading Whatever \(version)."
        case .downloaded(let version, let fileURL):
            "Whatever \(version) is in \(fileURL.lastPathComponent) — open it to update."
        }
    }

    /// Asks GitHub for the latest release and reports whether it is newer.
    /// Safe to press repeatedly: an in-flight check is ignored, and a
    /// release already fetched this sitting is reused.
    func checkForUpdates() async {
        if case .checking = status { return }
        if case .downloading = status { return }
        status = .checking
        do {
            let release: GitHubRelease
            if let cachedRelease {
                release = cachedRelease
            } else {
                release = try await fetchLatestRelease()
                cachedRelease = release
            }
            let latest = release.version
            guard Self.isNewer(latest: latest, than: currentVersion) else {
                status = .upToDate
                return
            }
            guard Self.downloadAsset(from: release.assets, architecture: architecture) != nil else {
                status = .noCompatibleDownload(version: latest)
                return
            }
            status = .available(version: latest)
        } catch {
            status = .failed(message: (error as? AppUpdateError)?.message
                ?? "The check failed. Check your connection and try again.")
        }
    }

    /// Downloads the cached release's disk image into Downloads and reports
    /// it. Only from `.available`: the asset was picked during the check.
    func downloadUpdate() async {
        guard case .available(let version) = status,
              let release = cachedRelease,
              let asset = Self.downloadAsset(from: release.assets, architecture: architecture)
        else {
            return
        }
        status = .downloading(version: version)
        do {
            let (temporaryURL, _) = try await session.download(from: asset.browserDownloadURL)
            let destination = try moveToDownloads(temporaryURL, filename: asset.name)
            status = .downloaded(version: version, fileURL: destination)
        } catch {
            status = .failed(message: "The download failed. Check your connection and try again.")
        }
    }

    /// Reveals the downloaded disk image in Finder.
    func revealDownload() {
        guard case .downloaded(_, let fileURL) = status else { return }
        NSWorkspace.shared.activateFileViewerSelecting([fileURL])
    }

    // MARK: - Network

    private func fetchLatestRelease() async throws -> GitHubRelease {
        var request = URLRequest(url: Self.latestReleaseURL)
        // GitHub rejects API calls without a user agent (403), and prefers
        // the versioned accept header over the default preview one.
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Whatever-macOS/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AppUpdateError.network
        }
        switch http.statusCode {
        case 200...299:
            break
        case 403, 429:
            throw AppUpdateError.rateLimited
        case 404:
            throw AppUpdateError.noReleases
        default:
            throw AppUpdateError.network
        }
        do {
            return try Self.decoder.decode(GitHubRelease.self, from: data)
        } catch {
            throw AppUpdateError.unparsable
        }
    }

    /// Plain decoder shared with tests: both payload types carry explicit
    /// keys, so no key strategy (see `GitHubRelease.CodingKeys`).
    static var decoder: JSONDecoder {
        JSONDecoder()
    }

    /// Moves a finished download into Downloads, uniquifying the name when
    /// an older disk image is still there.
    private func moveToDownloads(_ temporaryURL: URL, filename: String) throws -> URL {
        let downloads = try FileManager.default.url(
            for: .downloadsDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        var destination = downloads.appendingPathComponent(filename, isDirectory: false)
        var attempt = 1
        while FileManager.default.fileExists(atPath: destination.path) {
            attempt += 1
            let stem = (filename as NSString).deletingPathExtension
            let suffix = (filename as NSString).pathExtension
            destination = downloads.appendingPathComponent(
                "\(stem) \(attempt).\(suffix)",
                isDirectory: false
            )
        }
        try FileManager.default.moveItem(at: temporaryURL, to: destination)
        return destination
    }

    // MARK: - Pure rules

    /// Numeric version behind a release tag. Strips a leading `v` and
    /// compares number runs, so `v0.3.0` beats `0.2.2` and `0.3` ties
    /// `0.3.0`. Static so the rule is testable without touching GitHub.
    static func versionComponents(_ tag: String) -> [Int] {
        tag
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "^[vV]", with: "", options: .regularExpression)
            .split(separator: ".")
            .map { part in
                Int(part.prefix(while: \.isNumber)) ?? 0
            }
    }

    /// Whether `latest` is strictly newer than `current`.
    static func isNewer(latest: String, than current: String) -> Bool {
        let newParts = versionComponents(latest)
        let oldParts = versionComponents(current)
        for index in 0..<max(newParts.count, oldParts.count) {
            let fresh = index < newParts.count ? newParts[index] : 0
            let installed = index < oldParts.count ? oldParts[index] : 0
            if fresh != installed {
                return fresh > installed
            }
        }
        return false
    }

    /// The disk image for `architecture` among a release's assets. Prefers
    /// an explicit architecture match in the filename; falls back to the
    /// lone disk image when there is exactly one; anything else means no
    /// compatible download rather than the wrong architecture's image.
    /// Static so the picking is testable without touching GitHub.
    static func downloadAsset(
        from assets: [GitHubAsset],
        architecture: ProcessorArchitecture
    ) -> GitHubAsset? {
        let images = assets.filter { $0.name.lowercased().hasSuffix(".dmg") }
        if images.count == 1 {
            return images[0]
        }
        // No token, no guess: an empty token matches every filename, so an
        // unknown architecture reports no compatible download instead.
        guard !architecture.token.isEmpty else { return nil }
        let matches = images.filter { $0.name.lowercased().contains(architecture.token) }
        // Releases ship debug alongside release builds: prefer the build a
        // user would actually install.
        return matches.first { !$0.name.lowercased().contains("debug") } ?? matches.first
    }
}

/// Which instruction set a disk image must run on.
enum ProcessorArchitecture {
    case arm64
    case x86_64
    case unknown

    /// Filename token identifying a build for this architecture.
    var token: String {
        switch self {
        case .arm64: "arm64"
        case .x86_64: "x86_64"
        case .unknown: ""
        }
    }
}

/// A GitHub release as the `/latest` endpoint reports it. Only the fields
/// the checker reads: anything else the API adds is ignored.
struct GitHubRelease: Codable, Equatable {
    var tagName: String
    var assets: [GitHubAsset]

    // Explicit on both types, with a plain decoder: the snake_case strategy
    // converts JSON keys before matching them against these raw values, so
    // combining the two breaks every underscored key instead of fixing it.
    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case assets
    }

    /// The version the row names: the tag without its leading `v`.
    var version: String {
        let tag = tagName.trimmingCharacters(in: .whitespacesAndNewlines)
        if tag.hasPrefix("v") || tag.hasPrefix("V") {
            return String(tag.dropFirst())
        }
        return tag
    }
}

/// One release attachment: the filename to save and where to fetch it.
struct GitHubAsset: Codable, Equatable {
    var name: String
    var browserDownloadURL: URL

    enum CodingKeys: String, CodingKey {
        case name
        case browserDownloadURL = "browser_download_url"
    }
}

/// Why a check failed, in the row's own words.
enum AppUpdateError: Error {
    case network
    case rateLimited
    case noReleases
    case unparsable

    var message: String {
        switch self {
        case .network:
            "The check failed. Check your connection and try again."
        case .rateLimited:
            "GitHub is rate-limiting update checks. Try again in a little while."
        case .noReleases:
            "GitHub reports no releases yet. Try again later."
        case .unparsable:
            "GitHub answered unexpectedly. Try again later."
        }
    }
}
