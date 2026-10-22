import AppKit
import EjectKit
import ServiceManagement

/// "Launch at Login" through `SMAppService.mainApp` (RECON §6). Works only from a real .app bundle with a bundle id
/// (`./build.sh install` puts it in ~/Applications); otherwise the menu item is disabled and the reason logged.
/// After `register()`, `.requiresApproval` is normal until the user allows it in System Settings › Login Items.
@MainActor
enum LoginItem {
    enum State: Equatable {
        case unavailable(String)
        case off
        case on
        case needsApproval
    }

    /// Not a bundle: `swift run`, or the bare executable outside its .app.
    static var unavailableReason: String? {
        let b = Bundle.main
        guard b.bundleURL.pathExtension == "app", b.bundleIdentifier != nil else {
            return "Ejectable isn\u{2019}t running from its .app bundle (run ./build.sh install)."
        }
        return nil
    }

    static var state: State {
        if let why = unavailableReason { return .unavailable(why) }
        return switch SMAppService.mainApp.status {
        case .enabled: .on
        case .requiresApproval: .needsApproval
        case .notRegistered, .notFound: .off
        @unknown default: .off
        }
    }

    static func statusName(_ s: SMAppService.Status) -> String {
        switch s {
        case .notRegistered: "notRegistered"
        case .enabled: "enabled"
        case .requiresApproval: "requiresApproval"
        case .notFound: "notFound"
        @unknown default: "unknown(\(s.rawValue))"
        }
    }

    /// Register / unregister. Returns an error message for the user, nil on success.
    static func set(_ on: Bool) -> String? {
        if let why = unavailableReason {
            ActionLog.shared.record("login-item", "unavailable: \(why)")
            return why
        }
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            ActionLog.shared.record("login-item", "\(on ? "register" : "unregister") -> \(statusName(SMAppService.mainApp.status))")
            return nil
        } catch {
            ActionLog.shared.record("login-item", "\(on ? "register" : "unregister") failed: \(error.localizedDescription)")
            return error.localizedDescription
        }
    }

    static func openLoginItemsSettings() {
        ActionLog.shared.record("login-item", "open Login Items settings")
        SMAppService.openSystemSettingsLoginItems()
    }

    /// Debug entry point (`EJECTABLE_DEBUG=1 Ejectable --login-item-roundtrip`): status, register, status, unregister,
    /// status. Leaves it unregistered. Returns the process exit code.
    static func roundTrip() -> Int32 {
        func say(_ s: String) { FileHandle.standardOutput.write(Data((s + "\n").utf8)) }
        say("bundle: \(Bundle.main.bundleURL.path) id=\(Bundle.main.bundleIdentifier ?? "-")")
        if let why = unavailableReason { say("unavailable: \(why)"); return 1 }
        let service = SMAppService.mainApp
        say("status before:           \(statusName(service.status))")
        var code: Int32 = 0
        do { try service.register(); say("register(): ok") } catch { say("register() failed: \(error)"); code = 1 }
        say("status after register:   \(statusName(service.status))")
        do { try service.unregister(); say("unregister(): ok") } catch { say("unregister() failed: \(error)"); code = 1 }
        say("status after unregister: \(statusName(service.status))")
        ActionLog.shared.record("login-item", "debug round trip -> \(statusName(service.status))")
        return code
    }
}
