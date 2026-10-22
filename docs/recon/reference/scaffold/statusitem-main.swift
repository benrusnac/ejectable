import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var item: NSStatusItem!
    func applicationDidFinishLaunching(_ n: Notification) {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "externaldrive", accessibilityDescription: "Drives")
        let m = NSMenu()
        m.addItem(withTitle: "Hello", action: nil, keyEquivalent: "")
        m.addItem(.separator())
        m.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = m
        FileHandle.standardError.write(Data("READY pid=\(getpid()) policy=\(NSApp.activationPolicy().rawValue)\n".utf8))
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
