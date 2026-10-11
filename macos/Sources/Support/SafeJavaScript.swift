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

import WebKit

extension WKWebView {
    /// Async `evaluateJavaScript` that tolerates a nil result.
    ///
    /// The system async overlay force-unwraps the completion's result, so a
    /// script answering `null`/`undefined` — or WebKit reporting `(nil, nil)`
    /// for a call interrupted by a navigation — traps the process instead of
    /// returning. This wrapper hands back the raw `Any?` and reports real
    /// errors by throwing, which is the completion API's actual contract.
    func evaluateJavaScriptSafely(_ script: String) async throws -> Any? {
        try await withCheckedThrowingContinuation { continuation in
            evaluateJavaScript(script) { result, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: result)
                }
            }
        }
    }
}
