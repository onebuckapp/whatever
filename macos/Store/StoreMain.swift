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

/// Entry point of the `WhateverStore` XPC service.
///
/// The bundle's `CFBundlePackageType` is `XPC!`, so launchd starts this
/// executable in response to the app's first `NSXPCConnection` and terminates it
/// once the app has been idle.
///
/// Deliberately no `NSApplication`: an XPC service is not an app, and
/// instantiating one pulls AppKit's app lifecycle into a process that has no
/// Dock presence, which aborts before the listener is ever resumed.
///
/// `dispatchMain()` rather than `RunLoop.main.run()` because the service's
/// Info.plist declares `RunLoopType = dispatch_main`. The two have to agree, so
/// the plist is the place to look when one of them misbehaves.
@main
enum StoreMain {
    static func main() {
        StoreService.main()
        dispatchMain()
    }
}