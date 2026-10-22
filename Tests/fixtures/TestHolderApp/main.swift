import AppKit

// DUTestHolder: tiny GUI app for the Terminator tests (built by Tests/fixtures/make-test-app.sh).
// LSUIElement, so it never shows in the Dock. Arguments:
//   --hold <path>   keep <path> open read-only, so the app holds a fixture volume (kind .app in the scan)
//   --refuse <n>    answer the first n quit requests with .terminateCancel (like an unsaved-changes prompt)
//   --log <path>    append events: "ready <pid> fd=<fd>", "shouldTerminate cancel", "shouldTerminate now"
@MainActor
final class TestHolderDelegate: NSObject, NSApplicationDelegate {
    var refuse = 0
    var logPath: String?
    var fd: Int32 = -1

    func applicationDidFinishLaunching(_ notification: Notification) {
        let args = CommandLine.arguments
        func value(_ flag: String) -> String? {
            guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
            return args[i + 1]
        }
        logPath = value("--log")
        refuse = value("--refuse").flatMap { Int($0) } ?? 0
        if let path = value("--hold") { fd = open(path, O_RDONLY) }
        log("ready \(getpid()) fd=\(fd)")
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if refuse > 0 {
            refuse -= 1
            log("shouldTerminate cancel")
            return .terminateCancel
        }
        log("shouldTerminate now")
        return .terminateNow
    }

    func log(_ line: String) {
        guard let logPath else { return }
        let fd = open(logPath, O_WRONLY | O_APPEND | O_CREAT, 0o644)
        guard fd >= 0 else { return }
        _ = (line + "\n").withCString { write(fd, $0, strlen($0)) }
        close(fd)
    }
}

let app = NSApplication.shared
let delegate = TestHolderDelegate()
app.delegate = delegate
// DUTestExtension.app (LSBackgroundOnly) keeps LaunchServices' policy .prohibited, like an app extension.
if Bundle.main.object(forInfoDictionaryKey: "LSBackgroundOnly") as? Bool != true {
    app.setActivationPolicy(.accessory)
}
app.run()
