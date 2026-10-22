import AppKit
import Foundation

// Pure AppKit menu-bar app (LSUIElement). Never import SwiftUI here (adds ~30 MB RSS, RECON §6).

#if DEBUG
// Debug entry points (--eject, --screens, --debug-hooks): compiled into debug builds only, and even there only with
// EJECTABLE_DEBUG=1, so a stray argument can never drive an eject. Release builds do not contain them at all.
let debugFlags: Set<String> = ["--eject", "--screens", "--debug-hooks", "--real"]
if CommandLine.arguments.dropFirst().contains(where: debugFlags.contains) {
    guard ProcessInfo.processInfo.environment["EJECTABLE_DEBUG"] == "1" else {
        FileHandle.standardError.write(Data("Ejectable: debug entry points disabled (set EJECTABLE_DEBUG=1 to use them)\n".utf8))
        exit(64)
    }
}
#endif

// Login-item check for the installed copy (`EJECTABLE_DEBUG=1 ~/Applications/Ejectable.app/…/Ejectable
// --login-item-roundtrip`): registers and unregisters Ejectable's own login item, nothing else.
if CommandLine.arguments.dropFirst().contains("--login-item-roundtrip") {
    guard ProcessInfo.processInfo.environment["EJECTABLE_DEBUG"] == "1" else {
        FileHandle.standardError.write(Data("Ejectable: --login-item-roundtrip needs EJECTABLE_DEBUG=1\n".utf8))
        exit(64)
    }
    exit(LoginItem.roundTrip())
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
