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