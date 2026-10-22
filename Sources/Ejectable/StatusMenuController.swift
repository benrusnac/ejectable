import AppKit
import EjectKit

enum Prefs {
    static let watchFinderEjects = "watchFinderEjects"
    static let showNetworkShares = "showNetworkShares"

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [watchFinderEjects: true, showNetworkShares: true])
    }
}

/// The `externaldrive` status item and its menu, rebuilt on open (and on mount changes; no polling):
/// Drives (click = eject the whole disk) · Eject All · Network (click = disconnect) · toggles · Quit.
/// Built from `VolumeMonitor`'s cached snapshot only: no DiskArbitration / IOKit / statfs on the main thread.
@MainActor
final class StatusMenuController: NSObject, NSMenuDelegate {
    let statusItem: NSStatusItem
    let toast: EjectedToast
    private let menu = NSMenu()
    private let monitor: VolumeMonitor
    private let coordinator: EjectCoordinator

    init(monitor: VolumeMonitor, coordinator: EjectCoordinator) {
        self.monitor = monitor
        self.coordinator = coordinator
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.autosaveName = "Ejectable"
        if let button = statusItem.button {
            let image = NSImage(systemSymbolName: "externaldrive", accessibilityDescription: "Ejectable")
            image?.isTemplate = true
            button.image = image
            button.imagePosition = .imageOnly
            button.toolTip = "Ejectable"
        }
        if let why = LoginItem.unavailableReason { ActionLog.shared.record("login-item", "menu item disabled: \(why)") }
        toast = EjectedToast(statusItem: statusItem)
        super.init()
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu
        monitor.onChange = { [weak self] volumes in
            ActionLog.shared.record("ui", "volumes changed: \(volumes.map { $0.isNetwork ? "\($0.name) (network)" : $0.name })")
            self?.rebuild()
        }
        rebuild()
    }

    func menuNeedsUpdate(_ menu: NSMenu) { rebuild() }

    /// The menu (debug dump / menu screenshot).
    var currentMenu: NSMenu { menu }

    // MARK: - Build

    func rebuild() {
        menu.removeAllItems()
        let entries = monitor.entries
        let local = entries.filter { !$0.volume.isNetwork }
        let network = entries.map(\.volume).filter(\.isNetwork)

        menu.addItem(.sectionHeader(title: "Drives"))
        if local.isEmpty {
            let none = NSMenuItem(title: "No external drives", action: nil, keyEquivalent: "")
            none.isEnabled = false
            menu.addItem(none)
        }
        let drives = local.map(driveItem)
        drives.forEach(menu.addItem)
        let tip = "Ejectable \u{2014} \(local.count) \(local.count == 1 ? "drive" : "drives")"
        toast.idleToolTip = tip
        if statusItem.button?.title.isEmpty ?? true { statusItem.button?.toolTip = tip }
        let all = NSMenuItem(title: "Eject All", action: #selector(ejectAll(_:)), keyEquivalent: "")
        all.target = self
        all.isEnabled = drives.contains(where: \.isEnabled)          // RAID sets are listed but never ejected
        menu.addItem(all)

        if UserDefaults.standard.bool(forKey: Prefs.showNetworkShares), !network.isEmpty {
            menu.addItem(.separator())
            menu.addItem(.sectionHeader(title: "Network"))
            for v in network { menu.addItem(networkItem(v)) }
        }

        menu.addItem(.separator())
        menu.addItem(toggle("Watch Finder ejects", key: Prefs.watchFinderEjects))
        menu.addItem(toggle("Show network shares", key: Prefs.showNetworkShares))
        loginItems().forEach(menu.addItem)
        menu.addItem(.separator())
        let about = NSMenuItem(title: "About Ejectable", action: #selector(showAbout(_:)), keyEquivalent: "")
        about.target = self
        menu.addItem(about)
        let quit = NSMenuItem(title: "Quit Ejectable", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        menu.addItem(quit)
    }

    private func driveItem(_ entry: MonitoredVolume) -> NSMenuItem {
        let v = entry.volume
        let item = NSMenuItem(title: v.name, action: #selector(ejectDrive(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = v.path
        let icon = NSWorkspace.shared.icon(forFile: v.path)
        icon.size = NSSize(width: 16, height: 16)
        item.image = icon
        let disk = entry.disk                           // cached snapshot (VolumeMonitor's queue resolved it)
        let count = disk?.volumes.count ?? 1
        if disk?.isMultiMember == true {                // S5: listed, never offered
            item.action = nil
            item.isEnabled = false
            let title = NSMutableAttributedString(string: v.name, attributes: [.font: NSFont.menuFont(ofSize: 0)])
            title.append(NSAttributedString(string: " \u{2014} RAID set \u{2014} not supported yet", attributes: [
                .font: NSFont.menuFont(ofSize: 0), .foregroundColor: NSColor.secondaryLabelColor]))
            item.attributedTitle = title
            item.toolTip = "\(v.name) spans several disks (\(disk?.wholeAncestors.joined(separator: ", ") ?? "")). Eject it in Disk Utility."
        } else if count > 1 {                           // S8
            let title = NSMutableAttributedString(string: v.name, attributes: [.font: NSFont.menuFont(ofSize: 0)])
            title.append(NSAttributedString(string: " \u{2014} \(count) volumes", attributes: [
                .font: NSFont.menuFont(ofSize: 0), .foregroundColor: NSColor.secondaryLabelColor]))
            item.attributedTitle = title
            item.toolTip = "Ejects all \(count) volumes on this disk"
        } else {
            item.toolTip = "Eject \(v.name)"
        }
        return item
    }

    private func networkItem(_ v: VolumeInfo) -> NSMenuItem {
        let item = NSMenuItem(title: v.name, action: #selector(disconnectShare(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = v.path
        // SF symbol, not icon(forFile:): no I/O on a share that may be unresponsive.
        item.image = NSImage(systemSymbolName: "server.rack", accessibilityDescription: nil)
        if #available(macOS 14.4, *) { item.subtitle = "Disconnect" }
        item.toolTip = "Disconnect \(v.name)"
        return item
    }

    private func toggle(_ title: String, key: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(toggled(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = key
        item.state = UserDefaults.standard.bool(forKey: key) ? .on : .off
        return item
    }

    /// "Launch at Login" (SMAppService.mainApp) plus, while macOS waits for approval, a hint that opens Login Items.
    private func loginItems() -> [NSMenuItem] {
        let item = NSMenuItem(title: "Launch at Login", action: #selector(toggleLoginItem(_:)), keyEquivalent: "")
        item.target = self
        switch LoginItem.state {
        case .unavailable(let why):
            item.isEnabled = false
            item.toolTip = why
            return [item]
        case .off:
            item.state = .off
            return [item]
        case .on:
            item.state = .on
            return [item]
        case .needsApproval:
            item.state = .mixed
            let hint = NSMenuItem(title: "Approve in System Settings \u{203A} Login Items\u{2026}",
                                  action: #selector(openLoginItems(_:)), keyEquivalent: "")
            hint.target = self
            hint.indentationLevel = 1
            return [item, hint]
        }
    }

    static var versionString: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let short = info["CFBundleShortVersionString"] as? String ?? "dev"
        let build = info["CFBundleVersion"] as? String ?? "0"
        return "\(short) (\(build))"
    }

    static var logFolder: URL { ActionLog.shared.fileURL.deletingLastPathComponent() }

    // MARK: - Actions

    @objc private func toggleLoginItem(_ sender: NSMenuItem) {
        let turnOn = LoginItem.state == .off
        if let error = LoginItem.set(turnOn) {
            onMainRunLoop { self.coordinator.showError(title: "Launch at Login couldn\u{2019}t be changed", text: error) }
        }
        rebuild()
    }

    @objc private func openLoginItems(_ sender: NSMenuItem) { LoginItem.openLoginItemsSettings() }

    /// Version and the log folder (actions.log, S9). Started from a run-loop timer, never inside the menu's tracking.
    @objc private func showAbout(_ sender: NSMenuItem) {
        onMainRunLoop {
            let a = NSAlert()
            a.messageText = "Ejectable \(Self.versionString)"
            a.informativeText = "Shows which apps keep an external drive busy and ejects it safely.\n\n"
                + "Every scan, quit and eject is logged to \((Self.logFolder.path as NSString).abbreviatingWithTildeInPath)/actions.log."
            a.addButton(withTitle: "OK")
            a.addButton(withTitle: "Open Log Folder")
            NSApp.activate()
            if a.runModal() == .alertSecondButtonReturn {
                try? FileManager.default.createDirectory(at: Self.logFolder, withIntermediateDirectories: true)
                NSWorkspace.shared.open(Self.logFolder)
            }
            onMainRunLoop { [weak self] in self?.coordinator.drainErrors() }   // errors queued while About was up
        }
    }

    @objc private func ejectDrive(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        coordinator.eject(volumePath: path)
    }

    @objc private func ejectAll(_ sender: NSMenuItem) {
        coordinator.ejectAll(volumePaths: monitor.volumes.filter { !$0.isNetwork }.map(\.path))   // skips RAID sets
    }

    @objc private func disconnectShare(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String,
              let v = monitor.volumes.first(where: { $0.path == path && $0.isNetwork }) else { return }
        coordinator.disconnect(share: v)
    }

    @objc private func toggled(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String else { return }
        let value = !UserDefaults.standard.bool(forKey: key)
        UserDefaults.standard.set(value, forKey: key)
        ActionLog.shared.record("ui", "\(key) = \(value)")
        if key == Prefs.watchFinderEjects { coordinator.setWatchingFinderEjects(value) }
        rebuild()
    }

    // MARK: - Ejected confirmation

    func showEjected(_ base: String, name: String, success: Bool) {
        toast.show(base, name: name, editorReminder: success)
    }
}
