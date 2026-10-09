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

/// One download history row, as the store reports it.
///
/// `isMissing` is computed by the owning store at load time from the
/// filesystem, never persisted: the disk is the authority, and a stored flag
/// would lie after external deletes. Unknown states fail the row rather than
/// guessing, so a future core can add states without old app builds
/// misrendering them.
struct DownloadItem: Identifiable, Equatable {
    enum State: String {
        case inProgress = "in-progress"
        case done
        case failed
        case cancelled
    }

    let id: String
    let sourceURL: String
    let filename: String
    let destinationPath: String
    let bytesExpected: Int64
    let bytesReceived: Int64
    let state: State
    let errorText: String
    let startedAt: Date
    let finishedAt: Date
    var isMissing = false

    /// 0...1 while bytes are known, nil for indeterminate or terminal rows.
    var fraction: Double? {
        guard state == .inProgress, bytesExpected > 0 else { return nil }
        return min(1, Double(bytesReceived) / Double(bytesExpected))
    }

    static func decodeList(_ data: Data) -> [DownloadItem] {
        (try? JSONDecoder().decode([Failable].self, from: data))?.compactMap(\.value) ?? []
    }

    private struct Failable: Decodable {
        let value: DownloadItem?
        init(from decoder: Decoder) throws {
            value = try? DownloadItem(from: decoder)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case sourceURL
        case filename
        case destinationPath
        case bytesExpected
        case bytesReceived
        case state
        case errorText
        case startedAt
        case finishedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard let state = State(rawValue: (try? container.decode(String.self, forKey: .state)) ?? "") else {
            throw DecodingError.dataCorruptedError(
                forKey: .state, in: container,
                debugDescription: "Unknown download state"
            )
        }
        self.state = state
        id = (try? container.decode(String.self, forKey: .id)) ?? ""
        sourceURL = (try? container.decode(String.self, forKey: .sourceURL)) ?? ""
        filename = (try? container.decode(String.self, forKey: .filename)) ?? ""
        destinationPath = (try? container.decode(String.self, forKey: .destinationPath)) ?? ""
        bytesExpected = (try? container.decode(Int64.self, forKey: .bytesExpected)) ?? -1
        bytesReceived = (try? container.decode(Int64.self, forKey: .bytesReceived)) ?? 0
        errorText = (try? container.decode(String.self, forKey: .errorText)) ?? ""
        let started = (try? container.decode(Int64.self, forKey: .startedAt)) ?? 0
        let finished = (try? container.decode(Int64.self, forKey: .finishedAt)) ?? 0
        startedAt = Date(timeIntervalSince1970: TimeInterval(started))
        finishedAt = Date(timeIntervalSince1970: TimeInterval(finished))
        guard !id.isEmpty else {
            throw DecodingError.dataCorruptedError(
                forKey: .id, in: container,
                debugDescription: "Download without an id"
            )
        }
    }
}
