import AppKit
import EjectKit

/// Owns the app's ejects. One `Session` (EjectFlow state machine from EjectKit + InUseAlert) per physical disk:
///  - `.menu`: started from the menu / Eject All / `--eject`; the alert runs app-modally.
///  - `.foreign`: Finder-companion mode; EjectWatcher saw someone else's eject or unmount fail, the alert floats
///    non-modally next to Apple's without taking focus. A failed foreign UNMOUNT of one volume is retried as an unmount
///    of that volume only (`EjectFlow.Mode.unmountVolume`), never as an eject of the disk.
/// Never two sessions (alerts) for one disk. Every modal is started from an event handler or `onMainRunLoop`, never
/// from a main-queue block (see `onMainRunLoop`), and never on top of another modal session (plain error alerts wait).
/// Topology comes from `VolumeMonitor`'s snapshot: no DiskArbitration / IOKit / statfs on the main thread.
@MainActor
final class EjectCoordinator: NSObject, EjectFlowDelegate {
    /// The alert is built only when it is about to be shown: creating the first NSAlert costs ~10 MB of resident
    /// memory for the life of the process (measured on macOS 26.6), and most ejects never need one.
    @MainActor
    final class Session {
        enum Mode { case menu, foreign }
        let key: String
        let mode: Mode
        let flow: EjectFlow
        private(set) var alert: InUseAlert?
        private let makeAlert: (Session) -> InUseAlert
        var presentScheduled = false
        /// Cancel was pressed while the forced request ran: the alert is gone, the flow ends with that request's result.
        var hidden = false

        init(key: String, mode: Mode, flow: EjectFlow, makeAlert: @escaping (Session) -> InUseAlert) {
            self.key = key; self.mode = mode; self.flow = flow; self.makeAlert = makeAlert
        }

        /// The alert, built on first use.
        func ensureAlert() -> InUseAlert {
            if let alert { return alert }
            let a = makeAlert(self)
            alert = a
            return a
        }
    }

    let monitor: VolumeMonitor
    private let ejector = Ejector()
    private let terminator = Terminator()
    private var sessions: [String: Session] = [:]
    private var queue: [String] = []
    private var pendingErrors: [(title: String, text: String)] = []
    private var errorShowing = false
    private lazy var watcher = EjectWatcher { [weak self] event in self?.handleForeign(event) }

    /// Called when a flow ends with a result for the status item: (toast text, volume name, success). Success toasts
    /// carry the S10 editor reminder.
    var onEjected: ((String, String, Bool) -> Void)?
    #if DEBUG
    /// Debug hooks (screenshots, scripted presses). Debug builds only.
    var debug: DebugSupport?
    #endif

    init(monitor: VolumeMonitor) {
        self.monitor = monitor
        super.init()
    }

    private var menuSession: Session? { sessions.values.first { $0.mode == .menu } }
    /// The session the debug hooks act on: the modal one, else any.
    var flow: EjectFlow? { (menuSession ?? sessions.values.first)?.flow }
    var activeAlert: InUseAlert? { (menuSession ?? sessions.values.first)?.alert }

    static func key(_ disk: PhysicalDisk) -> String { "\(disk.bsdName)@\(disk.appearanceTime ?? 0)" }

    // MARK: - Finder-companion mode (phase 3)

    /// "Watch Finder ejects". The watcher is an observe-only DA client (S7); stopping it unregisters cleanly.
    func setWatchingFinderEjects(_ on: Bool) {
        if on {
            let ok = watcher.start()
            ActionLog.shared.record("ui", "watch Finder ejects: on (\(ok ? "running" : "could not start"))")
        } else {
            watcher.stop()
            ActionLog.shared.record("ui", "watch Finder ejects: off")
        }
    }

    private func handleForeign(_ event: EjectWatcherEvent) {
        switch event {
        case .attemptStarted:
            break
        case .failed(let url, let disk, let scan, let kind):
            guard UserDefaults.standard.bool(forKey: Prefs.watchFinderEjects), sessions[Self.key(disk)] == nil else { return }
            let name = disk.volumes.first { $0.path == url.path }?.name ?? url.lastPathComponent
            // Only what was asked for: an eject (an eject approval was seen) ejects the disk; anything else is retried
            // as an unmount of that one volume.
            let flowMode: EjectFlow.Mode = kind == .eject ? .ejectDisk : .unmountVolume(url.path)
            guard let s = makeSession(disk: disk, name: name, path: url.path, mode: .foreign, flowMode: flowMode) else { return }
            ActionLog.shared.record("ui", "foreign \(kind) of \(name) failed: companion alert (\(kind == .eject ? "will eject the disk" : "will unmount only \(url.path)")), \(scan.holders.count) holder(s)")
            s.flow.startObserving(scan)
        case .succeeded(_, let disk):
            // Someone else's retry worked: drop our companion alert for that disk.
            guard let s = sessions[Self.key(disk)], s.mode == .foreign, !s.flow.state.isFinished else { return }
            end(s)
            s.flow.cancel()
        }
    }

    // MARK: - Entry points (menu, Eject All, `--eject`)

    func eject(volumePath: String) {
        onMainRunLoop { self.start(volumePath: volumePath) }
    }

    /// Ejects every local external disk in turn. Stops at the first one the user cancels or that fails.
    func ejectAll(volumePaths: [String]) {
        var seen = Set<String>()
        let unique = volumePaths.filter { p in
            guard let d = monitor.entry(forPath: p)?.disk, !d.isMultiMember else { return false }   // RAID: not yet
            return seen.insert(d.bsdName).inserted
        }
        guard !unique.isEmpty else { return }
        ActionLog.shared.record("flow", "eject all: \(unique)")
        if menuSession == nil {
            queue = Array(unique.dropFirst())
            eject(volumePath: unique[0])
        } else {
            queue += unique
        }
    }

    func disconnect(share: VolumeInfo) {
        ActionLog.shared.record("flow", "disconnect \(share.path)")
        ejector.unmountNetworkShare(url: share.url) { r in
            Task { @MainActor in
                let failTitle = "\u{201C}\(share.name)\u{201D} couldn\u{2019}t be disconnected"
                let error: (String, String)? = switch r {
                case .ejected, .unmountedNotEjected, .volumeUnmounted: nil
                case .busy(let pid, _, _):
                    ("\u{201C}\(share.name)\u{201D} is in use",
                     pid.flatMap { HolderResolver.holder(forPID: $0)?.displayName }
                        .map { "\($0) is using it. Quit it, then disconnect again." }
                        ?? "A program is using it. Quit it, then disconnect again.")
                case .refused(let reason): (failTitle, "\(reason)")
                case .failed: (failTitle, "\(r)")
                }
                if let error {
                    onMainRunLoop { self.showError(title: error.0, text: error.1) }   // never a modal in a main-queue block
                } else {
                    self.onEjected?("Disconnected \(share.name)", share.name, false)
                }
            }
        }
    }

    // MARK: - Sessions

    /// Reads the cached snapshot only (VolumeMonitor resolves topology on its own queue).
    private func start(volumePath: String) {
        if let s = menuSession {                        // one menu eject at a time
            if s.hidden {
                ActionLog.shared.record("ui", "eject of \(volumePath) refused: a forced \(s.flow.verb) of \(s.flow.displayName) is still running")
            } else {
                s.alert?.bringToFront()
            }
            NSSound.beep()
            return
        }
        guard let entry = monitor.entry(forPath: volumePath), !entry.volume.isNetwork else {
            return next()                               // gone since the menu was built
        }
        let vol = entry.volume
        guard let disk = entry.disk else {
            return showError(title: "\u{201C}\(vol.name)\u{201D} couldn\u{2019}t be ejected", text: "Its disk could not be found.")
        }
        if disk.isMultiMember {                         // S5: refused by the Ejector too; say so without a flow
            ActionLog.shared.record("flow", "eject \(vol.name) refused: RAID / multi-disk \(disk.wholeAncestors)")
            return showError(title: "\u{201C}\(vol.name)\u{201D} can\u{2019}t be ejected by Ejectable",
                             text: "It is on a RAID set or a volume that spans several disks (\(disk.wholeAncestors.joined(separator: ", "))). "
                                + "That isn\u{2019}t supported yet; eject it in Disk Utility.")
        }
        if let existing = sessions[Self.key(disk)] {    // a companion alert already covers this disk
            if !existing.hidden { existing.alert?.bringToFront() } else { NSSound.beep() }
            return
        }
        // S8: a whole-disk eject of several volumes is confirmed before anything is unmounted.
        if disk.volumes.count > 1, !confirmMultiVolume(disk, name: vol.name, path: volumePath) {
            ActionLog.shared.record("flow", "multi-volume eject of \(disk.bsdName) cancelled at S8 confirmation")
            queue.removeAll()
            return
        }
        // The S8 modal ran the run loop: a companion session for this disk may have started meanwhile.
        if let existing = sessions[Self.key(disk)] {
            ActionLog.shared.record("flow", "eject of \(disk.bsdName): a companion alert started during the S8 confirmation; showing it")
            if !existing.hidden { existing.alert?.bringToFront() }
            return
        }
        makeSession(disk: disk, name: vol.name, path: volumePath, mode: .menu, flowMode: .ejectDisk)?.flow.start()
    }

    /// Nil (refused, logged) when a session for that disk exists: never two flows, never an orphaned one.
    @discardableResult
    private func makeSession(disk: PhysicalDisk, name: String, path: String, mode: Session.Mode,
                             flowMode: EjectFlow.Mode) -> Session? {
        let key = Self.key(disk)
        if sessions[key] != nil {
            ActionLog.shared.record("flow", "not starting a second flow for \(disk.bsdName) (\(name)): one is already running")
            return nil
        }
        let f = EjectFlow(disk: disk, displayName: name, mode: flowMode,
                          dependencies: .live(ejector: ejector, terminator: terminator))
        let volumeCount = f.isVolumeMode ? 1 : disk.volumes.count
        let s = Session(key: key, mode: mode, flow: f) { [weak self, weak f] s in
            let a = InUseAlert(volumeName: name, volumePath: path, volumeCount: volumeCount,
                               verb: f?.verb ?? "eject", companion: mode == .foreign)
            a.onPrimary = { [weak f] in
                guard let f else { return }
                switch f.primaryButton {
                case .quitAll: f.quitAll()
                case .retry: f.retryNow()
                }
            }
            a.onCancel = { [weak self, weak s, weak f] in
                guard let f else { return }
                if f.state == .forcing, let self, let s {
                    self.hideDuringForce(s)               // the forced request cannot be called back
                } else {
                    f.cancel()
                }
            }
            a.onForceEject = { [weak self, weak s] in
                guard let self, let s else { return }
                self.forceEject(s)
            }
            a.onRowAction = { [weak self, weak s] pid, action in
                guard let self, let s else { return }
                self.rowAction(s, pid, action)
            }
            a.onModalEnded = { [weak self] in
                onMainRunLoop { self?.drainErrors() }
            }
            #if DEBUG
            self?.debug?.attach(a)
            #endif
            return a
        }
        f.delegate = self
        sessions[key] = s
        return s
    }

    func ejectFlowDidUpdate(_ f: EjectFlow) {
        guard let s = sessions.values.first(where: { $0.flow === f }) else {
            // A request sent before Cancel still finished the job.
            if let (text, success) = Self.resultToast(f) { onEjected?(text, f.displayName, success) }
            return
        }
        switch f.state {
        case .ejected, .forced, .unmounted, .volumeUnmounted, .disconnected:
            end(s)
            let toast = Self.resultToast(f)
            if let toast { onEjected?(toast.text, f.displayName, toast.success) }
            if s.mode == .menu {
                if toast?.success ?? false { next() } else { queue.removeAll() }
            }
        case .cancelled:
            end(s)
            if s.mode == .menu { queue.removeAll() }
        case .failed(let message):
            end(s)
            if s.mode == .menu { queue.removeAll() }
            let name = f.displayName, verb = f.verb
            onMainRunLoop { self.showError(title: "\u{201C}\(name)\u{201D} couldn\u{2019}t be \(verb)ed", text: message) }
        case .idle, .ejecting, .blocked, .quitting, .retrying, .forcing:
            guard !s.hidden else { return }
            s.alert?.update(from: f)
            // Show as soon as the scan finds holders (DA's busy answer can take ~10 s on APFS).
            let show = f.state != .ejecting || !f.rows.isEmpty
            guard show, s.alert.map({ $0.presentation == .none && !$0.isDismissed }) ?? true, !s.presentScheduled else { return }
            s.presentScheduled = true
            onMainRunLoop { self.present(s) }
        }
    }

    /// The status-item text for a finished flow, and whether it is a success (S10 reminder). Nil: nothing to say.
    static func resultToast(_ f: EjectFlow) -> (text: String, success: Bool)? {
        let name = f.displayName
        return switch f.state {
        case .ejected: ("Ejected \(name)", true)
        case .forced: ("\(f.isVolumeMode ? "Force unmounted" : "Force ejected") \(name)", true)
        case .unmounted: (unmountedText(name), true)
        case .volumeUnmounted: ("Unmounted \(name)", true)
        case .disconnected(let remounted):
            remounted ? ("\(name) is still mounted \u{2014} try again", false) : ("\(name) disconnected", false)
        default: nil
        }
    }

    private func present(_ s: Session) {
        s.presentScheduled = false
        guard sessions[s.key] === s, !s.flow.state.isFinished, !s.hidden else { return }
        let alert = s.ensureAlert()
        alert.update(from: s.flow)
        ActionLog.shared.record("ui", "in-use alert (\(s.mode == .menu ? "modal" : "companion"), \(s.flow.verb)) for \(s.flow.displayName): \(s.flow.rows.count) row(s)")
        switch s.mode {
        case .menu: alert.presentModal()                // returns after end(s) or Cancel while forcing
        case .foreign: alert.presentNonModal()          // floating, does not activate the app
        }
    }

    /// Cancel while the forced request runs: close the alert, keep the flow until the result arrives (then the toast or
    /// an error alert). Logged.
    private func hideDuringForce(_ s: Session) {
        s.flow.abandonDuringForce()
        s.hidden = true
        ActionLog.shared.record("ui", "alert for \(s.flow.displayName) closed while the forced \(s.flow.verb) runs; "
                                + "the request continues in the background and its result is shown when it arrives")
        s.alert?.dismiss()
    }

    static func unmountedText(_ name: String) -> String { "\(name) unmounted \u{2014} safe to disconnect" }

    private func end(_ s: Session) {
        s.alert?.dismiss()
        if sessions[s.key] === s { sessions[s.key] = nil }
        if sessions.isEmpty { Self.returnFreedMemory() }
        onMainRunLoop { [weak self] in self?.drainErrors() }
    }

    /// After the last alert closes, hand malloc's free pages back to the system (the scan workers, rows and alert
    /// leave several MB of freed-but-resident heap). Off the main thread, a moment later so the alert is gone.
    static func returnFreedMemory() {
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) { _ = malloc_zone_pressure_relief(nil, 0) }
    }

    private func next() {
        guard !queue.isEmpty else { return }
        eject(volumePath: queue.removeFirst())
    }

    /// S9: the app is quitting. Flows still open lose their pending results; say which, in what state.
    func logOpenFlowsAtQuit() {
        let open = sessions.values.filter { !$0.flow.state.isFinished }
        guard !open.isEmpty else { return ActionLog.shared.record("app", "quit: no eject in progress") }
        for s in open {
            let f = s.flow, inFlight = f.requestsInFlight
            ActionLog.shared.record("app", "quit with an open \(s.mode == .menu ? "menu" : "companion") flow: \(f.displayName) "
                                    + "(\(f.disk.bsdName), \(f.verb)) state=\(f.state) rows=\(f.rows.count) "
                                    + "soft request pending=\(inFlight.soft) forced request pending=\(inFlight.forced)"
                                    + (inFlight.forced ? " (its result will not be seen)" : "") + (s.hidden ? " [window closed]" : ""))
        }
    }

    // MARK: - Buttons

    /// Force Eject… / Force Unmount…: the S2 confirmation, then the flow's re-check. A re-check that finds holders or
    /// crash risks the sheet did not show sends nothing and shows the sheet again with the fresh list.
    private func forceEject(_ s: Session, confirmation preset: ForceEjectConfirmation? = nil) {
        let f = s.flow
        guard sessions[s.key] === s, !f.state.isFinished, !s.hidden else { return }
        guard let c = preset ?? f.requestForceEject() else { NSSound.beep(); return }
        guard let alert = s.alert, alert.runForceConfirmation(c) else {
            ActionLog.shared.record("force-eject", "confirmation cancelled for \(f.displayName)")
            return
        }
        guard sessions[s.key] === s, !f.state.isFinished else { return }
        // The S2 re-check (fresh scan + tmutil) runs off the main thread; the alert keeps updating meanwhile.
        Task { @MainActor in
            switch await f.confirmForceEject(c) {
            case .sent: break
            case .refused: NSSound.beep()
            case .reconfirm(let again):
                onMainRunLoop { [weak self] in self?.forceEject(s, confirmation: again) }   // a modal, never from a Task
            }
        }
    }

    private func rowAction(_ s: Session, _ pid: pid_t, _ action: EjectFlow.RowAction) {
        let f = s.flow
        guard f.perform(action, on: pid) == .needsWriterConfirmation,
              let row = f.rows.first(where: { $0.holder.pid == pid }) else { return }
        if let alert = s.alert, alert.confirmStopWriter(row), sessions[s.key] === s {
            f.perform(action, on: pid, writerConfirmed: true)
        }
    }

    // MARK: - Plain alerts

    private func confirmMultiVolume(_ disk: PhysicalDisk, name: String, path: String) -> Bool {
        let a = NSAlert()
        a.icon = NSWorkspace.shared.icon(forFile: path)
        a.messageText = "Eject all \(disk.volumes.count) volumes on this disk?"
        a.informativeText = "\u{201C}\(name)\u{201D} shares its disk with "
            + disk.volumes.filter { $0.path != path }.map { "\u{201C}\($0.name)\u{201D}" }.joined(separator: ", ")
            + ". Ejecting the disk unmounts all of them."
        a.addButton(withTitle: "Eject All \(disk.volumes.count)")
        a.addButton(withTitle: "Cancel")
        #if DEBUG
        debug?.attachPlain(a, label: "s8-confirm")
        #endif
        NSApp.activate()
        let ok = a.runModal() == .alertFirstButtonReturn
        onMainRunLoop { [weak self] in self?.drainErrors() }
        return ok
    }

    /// A plain error alert. Queued while any other modal session runs (an in-use alert or one of its confirmations):
    /// ending that session would otherwise stop this alert's modal loop instead and leave the in-use alert wedged.
    /// Call only from an event handler or `onMainRunLoop`.
    func showError(title: String, text: String) {
        ActionLog.shared.record("ui", "error alert: \(title): \(text)")
        pendingErrors.append((title, text))
        drainErrors()
    }

    /// Shows the next queued error alert when no modal session is running. Called whenever one of ours ends.
    func drainErrors() {
        guard !errorShowing, !pendingErrors.isEmpty else { return }
        guard NSApp.modalWindow == nil, !sessions.values.contains(where: { $0.alert?.isRunningModal ?? false }) else { return }
        let e = pendingErrors.removeFirst()
        let a = NSAlert()
        a.alertStyle = .warning
        a.messageText = e.title
        a.informativeText = e.text
        a.addButton(withTitle: "OK")
        #if DEBUG
        debug?.attachPlain(a, label: "error")
        #endif
        errorShowing = true
        NSApp.activate()
        a.runModal()
        errorShowing = false
        if !pendingErrors.isEmpty { onMainRunLoop { [weak self] in self?.drainErrors() } }
    }
}
