import AppKit
import EjectKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var coordinator: EjectCoordinator?
    private var menuController: StatusMenuController?
    #if DEBUG
    private var debug: DebugSupport?
    #endif

    func applicationDidFinishLaunching(_ notification: Notification) {
        Prefs.registerDefaults()
        // Process lifetime. DA notification session + kqueue, no NSWorkspace observers: no AppKit approver (S7).
        let monitor = VolumeMonitor.shared
        let coordinator = EjectCoordinator(monitor: monitor)
        let menuController = StatusMenuController(monitor: monitor, coordinator: coordinator)
        coordinator.onEjected = { [weak menuController] base, name, success in
            menuController?.showEjected(base, name: name, success: success)
        }
        self.coordinator = coordinator
        self.menuController = menuController

        #if DEBUG
        let options = DebugSupport.Options.parse(CommandLine.arguments)
        if !options.isEmpty {
            let debug = DebugSupport(options: options, coordinator: coordinator, menuController: menuController)
            coordinator.debug = debug
            self.debug = debug
        }
        #endif
        coordinator.setWatchingFinderEjects(UserDefaults.standard.bool(forKey: Prefs.watchFinderEjects))
        FileHandle.standardError.write(Data("READY pid=\(getpid())\n".utf8))
        #if DEBUG
        debug?.runEject()
        #endif
    }

    /// S9: quitting mid-flow abandons pending DiskArbitration results; log every open flow and its state first.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        coordinator?.logOpenFlowsAtQuit()
        return .terminateNow
    }
}
