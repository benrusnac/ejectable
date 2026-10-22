import AppKit
import Foundation

/// Anything that can eject a physical disk or unmount one of its volumes (the real `Ejector`, or a test double).
public protocol EjectPerforming: AnyObject, Sendable {
    func eject(disk: PhysicalDisk, force: Bool, policy: EjectPolicy, completion: @escaping @Sendable (EjectResult) -> Void)
    /// One volume of `disk` (single-volume mode). `force` only from a confirmed Force Unmount.
    func unmountVolume(_ volume: VolumeInfo, of disk: PhysicalDisk, force: Bool, policy: EjectPolicy,
                       completion: @escaping @Sendable (EjectResult) -> Void)
}

extension Ejector: EjectPerforming {
    public func unmountVolume(_ volume: VolumeInfo, of disk: PhysicalDisk, force: Bool, policy: EjectPolicy,
                              completion: @escaping @Sendable (EjectResult) -> Void) {
        if force { forceUnmountVolume(volume, of: disk, policy: policy, completion: completion) }
        else { unmountVolume(volume, of: disk, policy: policy, completion: completion) }
    }
}

@MainActor
public protocol EjectFlowDelegate: AnyObject {
    /// State, rows, blockers or the primary button changed.
    func ejectFlowDidUpdate(_ flow: EjectFlow)
}

/// Issued by `EjectFlow.requestForceEject()` when the confirmation is shown; `confirmForceEject` only accepts the
/// latest one from the same flow. This is the only route to a forced eject (S1/S2).
public struct ForceEjectConfirmation: Sendable, Hashable {
    public let flowID: UUID
    let token: UUID
    public let diskName: String
    public let disk: PhysicalDisk
    /// What a forced request would do: eject the whole disk, or unmount one volume (`EjectFlow.Mode`).
    public let mode: EjectFlow.Mode
    /// Every holder the sheet lists. A fresh scan at confirmation may only find these (or fewer), else it is re-shown.
    public let holders: [Holder]
    public let risks: [ForceRisk]
}

/// What `EjectFlow.confirmForceEject` did.
public enum ForceEjectDecision: Sendable, Hashable {
    /// The forced request was sent.
    case sent
    /// Refused (stale or foreign confirmation, the flow ended, an S2 blocker, a soft request still pending). Logged.
    case refused
    /// The fresh scan found holders or crash risks the sheet did not show. Nothing was sent; show this one instead.
    case reconfirm(ForceEjectConfirmation)

    public var wasSent: Bool { self == .sent }
}

/// One eject of one physical disk (or, in `.unmountVolume` mode, the unmount of one volume), from click to done. UI-free;
/// the app's `EjectCoordinator` renders it. Main actor; DiskArbitration and scans run elsewhere and hop back.
///
///     idle → ejecting ─(scan finds holders | DA busy)→ blocked ⇄ quitting
///                                                       │  (holders clear → automatic SOFT retry)
///                                                       ├→ retrying → ejected | unmounted | volumeUnmounted | blocked
///                                                       └→ forcing (only via confirmForceEject) → forced
///     any non-final state → cancelled | failed | disconnected
///
/// `unmounted`: every volume unmounted but the disk itself refused to eject (DADiskEject dissented, e.g. Ejectable=0),
/// or (volume mode) the last mounted volume of the disk was unmounted: flushed and safe to disconnect, a success.
/// `volumeUnmounted`: volume mode, that volume is unmounted and the disk has other volumes still mounted.
/// `disconnected`: the disk went away under the flow (unplugged, USB re-enumeration): never reported as "ejected";
/// `remounted` = one of its volume paths is mounted again (from the new disk instance), so it is NOT safe to unplug.
///
/// Safety: every request uses `policy` (= `.externalDisks`); `force: true` is sent only from `confirmForceEject` after
/// S2 is re-checked on a fresh scan. Quit All only uses graceful quit / SIGTERM. `.unmountVolume` mode never touches
/// the disk's other volumes and never ejects the disk (a foreign single-volume unmount stays a single-volume unmount).
@MainActor
public final class EjectFlow {
    /// Eject the whole physical disk (menu, Eject All, a foreign eject), or unmount one volume (a foreign unmount of
    /// that volume failed: Disk Utility "Unmount", `diskutil unmount`).
    public enum Mode: Sendable, Hashable {
        case ejectDisk
        case unmountVolume(String)
    }

    public enum State: Sendable, Hashable, CustomStringConvertible {
        case idle, ejecting, blocked, quitting, retrying, forcing
        case ejected, unmounted, volumeUnmounted, forced, cancelled
        case disconnected(remounted: Bool)
        case failed(String)

        public var isFinished: Bool {
            switch self {
            case .ejected, .unmounted, .volumeUnmounted, .forced, .cancelled, .disconnected, .failed: true
            default: false
            }
        }

        public var description: String {
            switch self {
            case .idle: "idle"
            case .ejecting: "ejecting"
            case .blocked: "blocked"
            case .quitting: "quitting"
            case .retrying: "retrying"
            case .forcing: "forcing"
            case .ejected: "ejected"
            case .unmounted: "unmounted (not ejected)"
            case .volumeUnmounted: "volume unmounted"
            case .forced: "forced"
            case .disconnected(let again): again ? "disconnected, mounted again" : "disconnected"
            case .cancelled: "cancelled"
            case .failed(let m): "failed: \(m)"
            }
        }
    }

    public enum RowAction: Sendable, Hashable {
        case quit
        case forceQuit
        case stop
        case kill
        case quitApp(bundleID: String, name: String)
        case openSettings(URL)
        case none
    }

    public enum RowStatus: Sendable, Hashable {
        case idle
        /// terminate() sent; waiting up to `grace` seconds (`QuitGrace`, per kind: an app may be asking to save). The
        /// row's force button is one hover / Tab away meanwhile (`Row.secondaryAction`).
        case quitting(elapsed: TimeInterval, grace: TimeInterval)
        /// Did not quit within its grace: the row's primary button is its force action (Force Quit / Force Stop).
        case quitTimedOut
        /// The user clicked the row's Force Quit / Force Stop; waiting (up to 3 s) for the process to go.
        case forceQuitting
        /// SIGTERM sent: Kill is one hover / Tab away, and the primary button once `grace` has passed.
        case stopping(since: Date, grace: TimeInterval)
        case note(String)

        /// Waiting for a quit / stop the user asked for (the row shows a progress indicator).
        public var isWaiting: Bool {
            switch self {
            case .quitting, .forceQuitting: true
            case .stopping(let since, let grace): Date().timeIntervalSince(since) < grace
            case .idle, .quitTimedOut, .note: false
            }
        }

        /// Whole seconds left of the grace ("Quitting… (59s)"); nil when not counting down.
        public var graceRemaining: Int? {
            switch self {
            case .quitting(let elapsed, let grace): EjectFlow.remaining(elapsed: elapsed, grace: grace)
            case .stopping(let since, let grace):
                EjectFlow.remaining(elapsed: Date().timeIntervalSince(since), grace: grace)
            case .idle, .quitTimedOut, .forceQuitting, .note: nil
            }
        }
    }

    /// Countdown shown on a waiting row: whole seconds left, rounded down (59 a moment after a 60 s grace started).
    nonisolated static func remaining(elapsed: TimeInterval, grace: TimeInterval) -> Int {
        max(0, Int((grace - elapsed).rounded(.down)))
    }

    public struct Row: Sendable, Hashable, Identifiable {
        public let holder: Holder
        public let remedy: Remedy
        public let status: RowStatus
        public let action: RowAction
        public let actionTitle: String?
        public let actionEnabled: Bool
        /// Known only from DiskArbitration's dissenter pid; the scan cannot see its files.
        public let isDissenterOnly: Bool
        /// While the row waits for a quit / stop: its force action (`.forceQuit` = Force Quit / Force Stop, or `.kill`),
        /// revealed when the pointer is over the row or keyboard focus reaches it (`ForceReveal`), and accepted by
        /// `perform`. One process per click, labelled (S3). Nil otherwise (idle rows never offer force).
        public let secondaryAction: RowAction?
        /// "Force Quit" / "Force Stop" / "Kill".
        public let secondaryTitle: String?
        /// What the force action costs: "Unsaved changes in X will be lost", …
        public let secondaryToolTip: String?
        public var id: pid_t { holder.pid }
    }

    public enum PrimaryButton: Sendable, Hashable {
        /// "Quit All & Eject": graceful quit / SIGTERM for every holder, then soft eject.
        case quitAll(enabled: Bool)
        /// Nothing is quittable (system processes only): "Try Again" = one soft eject now.
        case retry(enabled: Bool)
    }

    public enum PerformResult: Sendable, Hashable {
        case started
        /// The holder writes to the drive: confirm with the user, then call again with `writerConfirmed: true` (S3).
        case needsWriterConfirmation
        case unavailable
    }

    public struct Dependencies {
        public var ejector: any EjectPerforming
        public var terminator: Terminator
        /// Synchronous scan of every volume on the disk; always called off the main thread.
        public var scan: @Sendable (PhysicalDisk) -> HolderScan
        /// Re-inspects only the given pids (known holders): ~1 ms instead of ~150 ms CPU for a full scan.
        /// Nil = always full scans.
        public var rescan: (@Sendable (PhysicalDisk, [pid_t]) -> HolderScan)?
        /// Every n-th tick is a full scan (new holders); the others only re-check known holders.
        public var fullScanEvery: Int = 4
        /// Time Machine facts; spawns tmutil. Always called off the main thread.
        public var timeMachine: @Sendable (PhysicalDisk) -> TimeMachineFacts
        public var resolvePID: @MainActor (pid_t, [String]) -> Holder?
        /// Flush every volume before a forced unmount (S2). Called off the main thread.
        public var flush: @Sendable ([String]) -> Void
        public var openURL: @MainActor (URL) -> Void
        public var log: ActionLog?
        /// Rescan period while the flow runs. 0 = no timer (tests call `tick()`).
        public var rescanInterval: TimeInterval = 1
        public var minRetryInterval: TimeInterval = 2
        /// Retry period once several retries in a row came back busy with nothing visible (system holder).
        public var slowRetryInterval: TimeInterval = 5
        /// How long a row's graceful quit / SIGTERM waits before its primary button becomes the force action, per kind.
        public var grace: QuitGrace = .standard

        public init(ejector: any EjectPerforming, terminator: Terminator,
                    scan: @escaping @Sendable (PhysicalDisk) -> HolderScan,
                    timeMachine: @escaping @Sendable (PhysicalDisk) -> TimeMachineFacts,
                    resolvePID: @escaping @MainActor (pid_t, [String]) -> Holder?,
                    flush: @escaping @Sendable ([String]) -> Void = { _ in },
                    rescan: (@Sendable (PhysicalDisk, [pid_t]) -> HolderScan)? = nil,
                    openURL: @escaping @MainActor (URL) -> Void, log: ActionLog?) {
            self.ejector = ejector; self.terminator = terminator; self.scan = scan; self.rescan = rescan
            self.timeMachine = timeMachine
            self.resolvePID = resolvePID; self.flush = flush; self.openURL = openURL; self.log = log
        }

        public static func live(ejector: any EjectPerforming, terminator: Terminator, log: ActionLog? = .shared) -> Dependencies {
            Dependencies(
                ejector: ejector, terminator: terminator,
                scan: { disk in
                    // The scanner keeps only real mount points (a leftover /Volumes/X directory would statfs to the
                    // boot volume and list every process on the Mac), and reports a scan of nothing as incomplete.
                    HolderScanner.scan(volumePaths: disk.volumePaths, log: log)
                },
                timeMachine: { TimeMachineFacts.current(for: $0) },
                resolvePID: { pid, volumes in HolderResolver.holder(forPID: pid, volumePaths: volumes) },
                // sync() returns before buffers reach the disk; sync_volume_np waits (S2). The Ejector flushes again
                // right before the forced request.
                flush: { paths in Ejector.flush(paths, log: log) },
                rescan: { disk, pids in
                    HolderScanner.rescan(pids: pids, volumePaths: disk.volumePaths, log: log)
                },
                // A deep link that does not open (renamed pane on a future macOS) falls back to System Settings.
                openURL: { url in
                    if !NSWorkspace.shared.open(url) {
                        log?.record("flow", "could not open \(url.absoluteString); opening System Settings")
                        NSWorkspace.shared.open(Remedies.settingsRoot)
                    }
                },
                log: log)
        }
    }

    public let id = UUID()
    /// The disk snapshot every request is sent with. Refreshed (same disk, same appearance time) only when a forced
    /// eject was refused because its volumes changed, so the next confirmation lists the current set (S8).
    public private(set) var disk: PhysicalDisk {
        didSet { scope = Self.scope(disk, mode) }
    }
    public let mode: Mode
    /// What is scanned, flushed and checked for Time Machine: the whole disk, or (volume mode) only that volume.
    public private(set) var scope: PhysicalDisk
    public let displayName: String
    /// The only policy this flow ever passes to the ejector.
    public let policy: EjectPolicy = .externalDisks
    public weak var delegate: EjectFlowDelegate?

    public private(set) var state: State = .idle
    public private(set) var rows: [Row] = []
    public private(set) var blockers: [ForceBlocker] = []
    public private(set) var risks: [ForceRisk] = []
    public private(set) var lastResult: EjectResult?
    public private(set) var lastScan: HolderScan?
    /// Starts unknown, so Force Eject is disabled until tmutil answered (fail closed, S2).
    public private(set) var timeMachine: TimeMachineFacts = .unknown
    public private(set) var ejectRequestCount = 0
    /// Set when a forced eject was attempted but did not eject.
    public private(set) var note: String?

    private var deps: Dependencies
    private var scanHolders: [Holder] = []
    private var dissenter: Holder?
    private var statuses: [pid_t: RowStatus] = [:]
    private var tasks: [pid_t: Task<Void, Never>] = [:]
    /// The current wait of each row. A wait superseded by another (Force Quit clicked during the graceful wait) still
    /// finishes, cancelled; its result must not overwrite the newer status.
    private var taskTokens: [pid_t: UUID] = [:]
    /// When each row's current graceful quit / SIGTERM was sent (for the early-force log line).
    private var waitStarted: [pid_t: Date] = [:]
    private var timer: Timer?
    private var ticks = 0
    private var scanInFlight = false
    private var rescanPending = false
    private var pendingFull = false
    private var tmInFlight = false
    private var ejectInFlight = false
    private var forceInFlight = false
    private var forceAuthorized = false
    /// `confirmForceEject` is re-checking S2 (fresh scan + tmutil, off the main thread).
    private var forceCheckInFlight = false
    /// The last FULL scan was incomplete (S2 blocker). Partial rescans only re-check known holders, so they keep it.
    private var lastFullScanIncomplete = false
    private var lastEjectAt = Date.distantPast
    private var consecutiveBusy = 0
    private var pendingConfirmation: UUID?
    private var activity: NSObjectProtocol?
    private var forceStartedAt: Date?
    private var slowForceNoted = false
    /// The UI was closed while the forced request ran (Cancel during `.forcing`): end the flow with its result.
    private var abandonedDuringForce = false

    /// How long `confirmForceEject` waits for a soft request that is still pending before refusing (never both at once).
    public var softRequestWait: TimeInterval = 15

    public init(disk: PhysicalDisk, displayName: String, mode: Mode = .ejectDisk, dependencies: Dependencies) {
        self.disk = disk
        self.mode = mode
        self.scope = Self.scope(disk, mode)
        self.displayName = displayName
        self.deps = dependencies
    }

    static func scope(_ disk: PhysicalDisk, _ mode: Mode) -> PhysicalDisk {
        switch mode {
        case .ejectDisk: disk
        case .unmountVolume(let path): disk.restricted(toVolumePath: path)
        }
    }

    /// Volume mode: the volume being unmounted.
    public var targetVolume: VolumeInfo? {
        guard case .unmountVolume(let path) = mode else { return nil }
        return disk.volumes.first { $0.path == path }
    }

    /// True when this flow only unmounts one volume.
    public var isVolumeMode: Bool { if case .unmountVolume = mode { true } else { false } }

    /// A soft / forced request is waiting for DiskArbitration (logged when the app quits mid-flow, S9).
    public var requestsInFlight: (soft: Bool, forced: Bool) { (ejectInFlight, forceInFlight) }

    // MARK: - Derived state for the UI

    /// Scan holders plus the DA dissenter when the scan cannot see it.
    public var holders: [Holder] { scanHolders + (dissenter.map { [$0] } ?? []) }

    public var canQuitAll: Bool {
        guard !rows.isEmpty, !state.isFinished, state != .forcing, state != .idle, !forceCheckInFlight else { return false }
        return rows.allSatisfy { quitAllAction(for: $0) != nil }
    }

    /// S2: no blockers, and at least one full scan has answered (no scan yet = holders unknown, like an incomplete one).
    /// In volume mode the button is "Force Unmount…", with exactly the same gates.
    public var canForceEject: Bool {
        blockers.isEmpty && lastScan != nil && !state.isFinished && state != .forcing && state != .idle && !forceCheckInFlight
    }

    /// The line next to Force Eject…: blocked (red) / risky (orange) / safe (green). Safe needs a complete full scan.
    public var forceRating: ForceRating {
        SafetyGate.forceRating(holders: holders, blockers: blockers, scanComplete: lastScan != nil && !lastFullScanIncomplete)
    }

    /// Processes the last full scan could not inspect (root / other uid). Shown as a footer, never acted on.
    public private(set) var deniedProcessCount = 0

    public var primaryButton: PrimaryButton {
        let anyQuittable = rows.contains(where: isQuittableInPrinciple)
        if rows.isEmpty || !anyQuittable {
            return .retry(enabled: !ejectInFlight && !forceInFlight && !forceCheckInFlight && !state.isFinished && state != .idle)
        }
        return .quitAll(enabled: canQuitAll)
    }

    /// The first row that keeps Quit All unavailable (nil when Quit All is available or nothing is quittable).
    public var quitAllBlockingRow: Row? {
        guard !canQuitAll, !rows.isEmpty, rows.contains(where: isQuittableInPrinciple) else { return nil }
        return rows.first { quitAllAction(for: $0) == nil }
    }

    /// Why Quit All is unavailable, for the alert's footnote.
    public var quitAllHint: String? {
        if let row = quitAllBlockingRow {
            let h = row.holder
            let name = row.remedy.label ?? h.displayName
            if h.kind == .cli, h.isWriter {
                let file = h.reasons.first(where: \.isWrite).map { ($0.path as NSString).lastPathComponent } ?? "a file"
                return "\(h.displayName) is writing \(file). Stop it with its own button first."
            }
            // The row already shows the remedy's explanation: point at it instead of repeating it.
            if row.remedy.action == .none || row.remedy.neverTerminate, row.remedy.explanation != nil {
                return "\(name) isn\u{2019}t something Ejectable quits; see its row."
            }
            if h.kind == .helper { return "\(name) has no running app to quit." }
            return "\(name) can\u{2019}t be quit."
        }
        return nil
    }

    /// "2 apps and 1 system process are using it."
    public var summary: String {
        if rows.isEmpty { return "Something Ejectable can\u{2019}t see is still using it, probably a system process." }
        var apps = 0, procs = 0, system = 0
        for r in rows {
            switch r.holder.kind {
            case .app, .appExtension, .helper: apps += 1
            case .cli: procs += 1
            case .daemon, .inaccessible: system += 1
            }
        }
        var parts: [String] = []
        if apps > 0 { parts.append("\(apps) \(apps == 1 ? "app" : "apps")") }
        if procs > 0 { parts.append("\(procs) \(procs == 1 ? "process" : "processes")") }
        if system > 0 { parts.append("\(system) system \(system == 1 ? "process" : "processes")") }
        let list = parts.count > 1 ? parts.dropLast().joined(separator: ", ") + " and " + parts.last! : parts[0]
        return "\(list) \(rows.count == 1 ? "is" : "are") using it."
    }

    /// "eject" / "unmount": the words of every line the user reads for this flow.
    public var verb: String { isVolumeMode ? "unmount" : "eject" }

    /// One line under the rows describing what happens next.
    public var statusText: String {
        let v = verb
        if forceCheckInFlight {
            return ejectInFlight ? "Waiting for the normal \(v) attempt to finish before force \(v)ing\u{2026}"
                                 : "Checking again before force \(v)ing\u{2026}"
        }
        return switch state {
        case .idle, .ejecting, .blocked:
            note ?? "It \(v)s automatically as soon as nothing is using it."
        case .quitting: "Waiting for them to quit\u{2026} it \(v)s as soon as they do."
        case .retrying: "\(v.capitalized)ing\u{2026}"
        case .forcing:
            slowForceNoted
                ? "Still force \(v)ing\u{2026} a slow drive can take a while to flush. Cancel closes this window; the request continues."
                : "Force \(v)ing\u{2026}"
        case .ejected: "Ejected."
        case .unmounted: "Unmounted. It is safe to disconnect."
        case .volumeUnmounted: "Unmounted."
        case .forced: isVolumeMode ? "Force unmounted." : "Force ejected."
        case .disconnected(let again):
            again ? "It was disconnected and is mounted again. Try again." : "It was disconnected."
        case .cancelled: "Cancelled."
        case .failed(let m): m
        }
    }

    // MARK: - Commands

    /// Start: holder scan and soft eject in parallel (on APFS a busy answer can take ~10 s; the scan takes ~40 ms).
    public func start() {
        guard state == .idle else { return }
        if disk.isMultiMember {                                   // S5: refused by the Ejector anyway; say why up front
            deps.log?.record("flow", "eject \(displayName) refused: \(disk.bsdName) has \(disk.wholeAncestors.count) member disks \(disk.wholeAncestors)")
            finish(.failed("\u{201C}\(displayName)\u{201D} is on a RAID set or multi-disk volume. Ejectable can\u{2019}t eject those yet."))
            return
        }
        state = .ejecting
        deps.log?.record("flow", "\(verb) \(displayName) (\(disk.bsdName), \(scope.volumes.count) of \(disk.volumes.count) volume(s): \(scope.volumePaths.joined(separator: ", ")))")
        beginActivity()
        startTimer()
        requestScan(full: true)
        refreshTimeMachine()
        sendEject(force: false)
        notify()
    }

    /// Graceful quit of every holder (terminate() for apps, SIGTERM for non-writing CLI tools), then the usual
    /// automatic soft eject once the scan is clear. Never force-quits, never SIGKILLs, never force-ejects (S1/S3).
    public func quitAll() {
        guard canQuitAll else {
            deps.log?.record("flow", "quit all refused for \(displayName): \(quitAllHint ?? "not available")")
            return
        }
        deps.log?.record("flow", "quit all for \(displayName): \(rows.map { "\($0.holder.pid) \($0.holder.displayName)" })")
        state = .quitting
        for row in rows {
            switch quitAllAction(for: row) {
            case .quit?:
                if case .quitting = row.status { continue }
                if case .forceQuitting = row.status { continue }
                startQuit(row.holder, rowPID: row.holder.pid)
            case .stop?:
                if case .stopping = row.status { continue }
                handleSignal(row.holder, deps.terminator.stop(row.holder), stopping: true)
            default: break
            }
        }
        rebuildRows()
        requestScan()
        notify()
    }

    /// A row button. `action` must be what the row currently offers: its (enabled) primary button, or the force button
    /// it reveals while it waits for a quit / stop (`Row.secondaryAction`, hover or Tab). So Force Quit / Force Stop /
    /// Kill are only reachable after the user asked that one process to quit or stop, one per click (S3). Stopping a
    /// writer needs `writerConfirmed` (S3).
    @discardableResult
    public func perform(_ action: RowAction, on pid: pid_t, writerConfirmed: Bool = false) -> PerformResult {
        guard !state.isFinished, state != .forcing, action != .none,
              let row = rows.first(where: { $0.holder.pid == pid }),
              (row.action == action && row.actionEnabled) || row.secondaryAction == action else {
            return .unavailable
        }
        let h = row.holder
        if row.secondaryAction == action, !(row.action == action && row.actionEnabled) {
            logEarlyForce(row)
        }
        switch action {
        case .quit: startQuit(h, rowPID: pid)
        case .forceQuit: startForceQuit(h)
        case .stop:
            if h.isWriter && !writerConfirmed { return .needsWriterConfirmation }
            handleSignal(h, deps.terminator.stop(h), stopping: true)
        case .kill: handleSignal(h, deps.terminator.kill(h), stopping: false)
        case .quitApp(let bundleID, _):
            guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first(where: { !$0.isTerminated }),
                  let appHolder = deps.resolvePID(app.processIdentifier, []) else { return .unavailable }
            startQuit(appHolder, rowPID: pid)
        case .openSettings(let url):
            deps.log?.record("flow", "open \(url.absoluteString) for \(h.pid) \(h.displayName)")
            deps.openURL(url)
        case .none: return .unavailable
        }
        rebuildRows()
        requestScan()
        notify()
        return .started
    }

    /// Finder-companion mode (phase 3): someone else's unmount/eject already failed with `scan`'s holders. No eject
    /// is sent now; the flow starts blocked, polls holders like `start()`, and soft-retries once they clear (S1).
    public func startObserving(_ seed: HolderScan, requester: String = "another app") {
        guard state == .idle else { return }
        observing = true
        state = .blocked
        // Volume mode: the watcher scanned every volume of the disk; only holders of this volume block its unmount.
        let wanted = Set(scope.volumePaths)
        let scan = isVolumeMode
            ? HolderScan(volumePaths: scope.volumePaths, holders: seed.holders.filter { !wanted.isDisjoint(with: $0.volumePaths) },
                         deniedPIDs: seed.deniedPIDs, duration: seed.duration, scannedAt: seed.scannedAt,
                         scannedTargets: seed.scannedTargets.filter(wanted.contains), incomplete: seed.incomplete,
                         incompleteReason: seed.incompleteReason)
            : seed
        lastScan = scan
        lastFullScanIncomplete = scan.incomplete
        deniedProcessCount = scan.deniedPIDs.count
        scanHolders = scan.holders
        lastEjectAt = Date()                              // the foreign attempt counts for retry pacing
        deps.log?.record("flow", "observe \(displayName) (\(disk.bsdName)): \(verb) by \(requester) failed, \(scan.holders.count) holder(s)"
                         + (isVolumeMode ? "; only \(scope.volumePaths.joined(separator: ", ")) will be unmounted" : ""))
        beginActivity()
        startTimer()
        refreshTimeMachine()
        recomputeGate()
        rebuildRows()
        requestScan(full: true)
        notify()
    }

    /// True when started by `startObserving` (someone else's eject failed).
    public private(set) var observing = false

    /// "Try Again" (when nothing is quittable): a full rescan (new or departed holders, fresh rows and rating) and
    /// one soft eject now (S1: never forced).
    public func retryNow() {
        guard !state.isFinished, state != .forcing, !ejectInFlight, !forceCheckInFlight else { return }
        deps.log?.record("flow", "retry requested for \(displayName): full rescan + soft \(verb)")
        state = .retrying
        requestScan(full: true)
        refreshTimeMachine()
        sendEject(force: false)
        notify()
    }

    /// Call when the Force Eject confirmation is about to be shown. Nil when S2 blocks it.
    public func requestForceEject() -> ForceEjectConfirmation? {
        guard canForceEject else {
            deps.log?.record("force-eject", "unavailable for \(displayName): \(blockers.map(\.message))")
            return nil
        }
        return issueConfirmation()
    }

    private func issueConfirmation() -> ForceEjectConfirmation {
        let token = UUID()
        pendingConfirmation = token
        deps.log?.record("force-eject", "confirmation shown for \(displayName) (\(disk.bsdName), force \(verb)): holders=\(holders.map { "\($0.pid) \($0.displayName)" }) risks=\(risks.map(\.message))")
        return ForceEjectConfirmation(flowID: id, token: token, diskName: displayName, disk: disk, mode: mode,
                                      holders: holders, risks: risks)
    }

    /// Identity of a holder for the confirmation re-check (pid + start time: a recycled pid is a new process).
    struct HolderKey: Hashable { let pid: pid_t; let start: Double? }
    /// The crash risks the sheet must have shown: mapped media (SIGBUS) and processes nobody can inspect.
    struct RiskKey: Hashable { let kind: ForceRisk.Kind; let pid: pid_t }

    /// S2: everything the fresh scan found that the confirmation did not show. Empty = the user saw it all.
    nonisolated static func unseen(holders fresh: [Holder], risks freshRisks: [ForceRisk], shown c: ForceEjectConfirmation) -> [String] {
        let shownHolders = Set(c.holders.map { HolderKey(pid: $0.pid, start: $0.startTime) })
        let critical: Set<ForceRisk.Kind> = [.mappedFile, .uninspectable]
        let shownRisks = Set(c.risks.filter { critical.contains($0.kind) }.map { RiskKey(kind: $0.kind, pid: $0.pid) })
        var out = fresh.filter { !shownHolders.contains(HolderKey(pid: $0.pid, start: $0.startTime)) }
            .map { "new holder \($0.pid) \($0.displayName)" }
        out += freshRisks.filter { critical.contains($0.kind) && !shownRisks.contains(RiskKey(kind: $0.kind, pid: $0.pid)) }
            .map { "new risk: \($0.message)" }
        return out
    }

    /// The user pressed "Force Eject" (volume mode: "Force Unmount") in the confirmation. Re-checks S2 on a fresh full
    /// scan and fresh Time Machine state (both off the main thread: tmutil can hang, and the main thread must keep
    /// serving the alert). The fresh holders and crash risks must be ones the sheet showed, else nothing is sent and a new
    /// confirmation is returned to show instead. A soft request still waiting for DiskArbitration is waited for (bounded)
    /// first: a forced request is never sent alongside it. Then logs the confirmation, flushes the volumes
    /// (`sync_volume_np` FULLSYNC|WAIT, off the main thread) and sends the forced request.
    @discardableResult
    public func confirmForceEject(_ c: ForceEjectConfirmation) async -> ForceEjectDecision {
        guard c.flowID == id, let expected = pendingConfirmation, expected == c.token,
              !state.isFinished, state != .forcing, !forceCheckInFlight else {
            deps.log?.record("force-eject", "refused for \(displayName): stale or foreign confirmation")
            return .refused
        }
        pendingConfirmation = nil
        forceCheckInFlight = true                         // also keeps auto-retry from sending a new soft request
        notify()
        // Never two requests at once: a soft request sent before the confirmation may still be pending (an APFS busy
        // answer can take ~10 s). Wait for its answer (it may even eject the disk), then re-check.
        let waitUntil = Date().addingTimeInterval(softRequestWait)
        while ejectInFlight && !state.isFinished && Date() < waitUntil {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        if ejectInFlight && !state.isFinished {
            forceCheckInFlight = false
            deps.log?.record("force-eject", "refused for \(displayName): a soft request is still pending after \(Int(softRequestWait)) s")
            note = "A normal \(verb) attempt is still running. Try again in a moment."
            notify()
            return .refused
        }
        let scan = deps.scan, tm = deps.timeMachine, scope = scope
        let (fresh, facts) = state.isFinished ? (nil, nil)
            : await Task.detached(priority: .userInitiated) { (scan(scope), tm(scope)) }.value
        forceCheckInFlight = false
        guard let fresh, let facts, !state.isFinished, state != .forcing else {
            deps.log?.record("force-eject", "refused for \(displayName): the flow ended (\(state)) while re-checking")
            notify()
            return .refused
        }
        lastScan = fresh
        lastFullScanIncomplete = fresh.incomplete
        deniedProcessCount = fresh.deniedPIDs.count
        scanHolders = fresh.holders
        timeMachine = facts
        recomputeGate()
        rebuildRows()
        if state == .ejecting && !scanHolders.isEmpty { state = .blocked }
        guard blockers.isEmpty else {
            deps.log?.record("force-eject", "refused for \(displayName) at confirmation: \(blockers.map(\.message))")
            notify()
            return .refused
        }
        let unseen = Self.unseen(holders: holders, risks: risks, shown: c)
        if !unseen.isEmpty { return reconfirm(unseen) }   // S2: every holder and crash risk must have been on the sheet
        deps.log?.forceEjectConfirmed(disk: scope, holders: holders)
        state = .forcing
        note = nil
        forceAuthorized = true
        sendEject(force: true)
        notify()
        return .sent
    }

    /// Nothing is sent: the fresh scan found holders or crash risks the sheet did not show. A new confirmation to show.
    private func reconfirm(_ unseen: [String]) -> ForceEjectDecision {
        deps.log?.record("force-eject", "refused for \(displayName): holders changed since the confirmation (\(unseen.joined(separator: "; "))); showing it again")
        note = "What is using it changed. Check the list again."
        let again = issueConfirmation()
        notify()
        return .reconfirm(again)
    }

    /// Cancel while the forced request runs: it cannot be called back. The UI goes away; the flow keeps running until the
    /// result arrives and then ends: `.forced`, or `.failed` when it did not complete (no retries without a window). Logged.
    public func abandonDuringForce() {
        guard state == .forcing, !abandonedDuringForce else { return }
        abandonedDuringForce = true
        deps.log?.record("force-eject", "\(displayName): window closed while the forced \(verb) runs; it continues in the background")
    }

    /// The user cancelled. Stops rescans and waits; quits already sent are not undone. A DA request already in
    /// flight may still eject the disk, which is then reported as `.ejected`.
    public func cancel() {
        guard !state.isFinished else { return }
        finish(.cancelled)
    }

    /// One rescan step (the timer calls this every `rescanInterval`; tests call it directly).
    public func tick() {
        guard !state.isFinished else { return }
        ticks += 1
        if state == .forcing, !slowForceNoted, let t = forceStartedAt, Date().timeIntervalSince(t) >= 10 {
            slowForceNoted = true
            deps.log?.record("force-eject", "\(displayName): forced \(verb) still running after 10 s")
            notify()
        }
        requestScan(full: deps.rescan == nil || ticks % max(1, deps.fullScanEvery) == 0)
        if ticks % 5 == 0 { refreshTimeMachine() }
        if rows.contains(where: { if case .stopping = $0.status { true } else { false } }) {
            rebuildRows()                                     // the stop countdown / Kill promotion, also without a task
            notify()
        }
    }

    // MARK: - Eject

    private func sendEject(force: Bool) {
        if force {
            guard forceAuthorized else {
                deps.log?.record("force-eject", "BUG: forced eject without confirmation blocked for \(displayName)")
                assertionFailure("forced eject without confirmation")
                return
            }
            forceAuthorized = false
            forceInFlight = true
            forceStartedAt = Date()
        } else {
            ejectInFlight = true
        }
        lastEjectAt = Date()
        ejectRequestCount += 1
        let ejector = deps.ejector, disk = disk, policy = policy, volume = targetVolume, mode = mode
        let done: @Sendable (EjectResult) -> Void = { r in
            let probe = EjectFlow.probe(r, disk: disk, mode: mode)          // DA / mount table, off the main thread
            Task { @MainActor in self.handleEject(r, force: force, probe: probe) }
        }
        let send: @Sendable () -> Void = {
            switch mode {
            case .ejectDisk:
                ejector.eject(disk: disk, force: force, policy: policy, completion: done)
            case .unmountVolume(let path):
                guard let volume else {
                    return done(.refused(.volumeNotOnDisk(path: path, bsdName: disk.bsdName)))
                }
                ejector.unmountVolume(volume, of: disk, force: force, policy: policy, completion: done)
            }
        }
        guard force else { return send() }
        let flush = deps.flush, paths = scope.volumePaths
        Task.detached(priority: .userInitiated) { flush(paths); send() }   // flush, then the forced request
    }

    /// What became of the disk, read off the main thread right after a result: gone / mounted again (refused because
    /// the disk is not found or changed), and in volume mode whether any volume of the disk is still mounted.
    struct Probe: Sendable {
        var gone = false
        var remounted = false
        var fresh: PhysicalDisk?
        var otherVolumesMounted = true
    }

    nonisolated static func probe(_ r: EjectResult, disk: PhysicalDisk, mode: Mode) -> Probe {
        var p = Probe()
        switch r {
        case .refused(.diskNotFound):
            p.gone = true
            p.remounted = !Set(disk.volumePaths).isDisjoint(with: DiskTopology.mountedPaths())
        case .refused(.diskChanged):
            p.fresh = DiskTopology.physicalDisk(bsdName: disk.bsdName)
            p.gone = p.fresh.map { $0.appearanceTime != disk.appearanceTime } ?? true
            if p.gone { p.remounted = !Set(disk.volumePaths).isDisjoint(with: DiskTopology.mountedPaths()) }
        case .volumeUnmounted:
            if case .unmountVolume(let path) = mode {
                p.otherVolumesMounted = !Set(disk.volumePaths.filter { $0 != path }).isDisjoint(with: DiskTopology.mountedPaths())
            }
        default: break
        }
        return p
    }

    private func handleEject(_ r: EjectResult, force: Bool, probe: Probe) {
        if force { forceInFlight = false; forceStartedAt = nil } else { ejectInFlight = false }
        lastResult = r
        let success: State? = switch r {
        case .ejected: force ? .forced : .ejected
        case .unmountedNotEjected: force ? .forced : .unmounted
        case .volumeUnmounted: force ? .forced : (probe.otherVolumesMounted ? .volumeUnmounted : .unmounted)
        default: nil
        }
        if state.isFinished {
            if let success, state == .cancelled {           // in flight when the user cancelled
                state = success
                deps.log?.record("flow", "\(displayName): \(state) by a request sent before cancel")
                notify()
            }
            return
        }
        if state == .forcing && !force {                     // a soft answer while the forced request is pending
            if let success { finish(success) }
            return
        }
        if let success { return finish(success) }
        switch r {
        case .busy(let pid, _, _):
            consecutiveBusy += 1
            if let pid, pid == getpid() {
                // Ejectable itself was named (an icon or a file it read): never a row, never "quit" (Quit All would
                // terminate Ejectable). Logged; the scan decides.
                deps.log?.record("flow", "\(displayName): DiskArbitration named Ejectable itself (pid \(pid)) as the holder; ignored")
                dissenter = nil
            } else if let pid, !scanHolders.contains(where: { $0.pid == pid }) {
                dissenter = deps.resolvePID(pid, scope.volumePaths)
            } else {
                dissenter = nil
            }
            if force {
                note = "Force \(verb) didn\u{2019}t complete; something still holds \(isVolumeMode ? "the volume" : "the disk")."
                if abandonedDuringForce {                    // nobody is looking: stop here instead of retrying
                    return finish(.failed("Force \(verb) of \u{201C}\(displayName)\u{201D} didn\u{2019}t complete; something still holds it."))
                }
            }
            if force || state != .quitting { state = .blocked }
            recomputeGate()
            rebuildRows()
            notify()
            requestScan(full: true)
        case .refused(let reason):
            if probe.gone {
                // Unplugged or re-enumerated under the flow: never "ejected" (S10/RECON: the user would unplug a disk
                // that may be mounted again from the new instance).
                deps.log?.record("flow", "\(displayName): disk is gone (\(reason))\(probe.remounted ? ", and a volume path is mounted again" : "")")
                finish(.disconnected(remounted: probe.remounted))
            } else if force, case .diskChanged = reason {
                // S2/S8: a volume appeared or went away after the user confirmed. Nothing was forced; show the
                // current set and let them confirm again.
                if let fresh = probe.fresh, fresh.appearanceTime == disk.appearanceTime { disk = fresh }
                note = "Its volumes changed after you confirmed, so nothing was forced. Check and try again."
                if abandonedDuringForce { return finish(.failed(note ?? "")) }
                state = .blocked
                recomputeGate()
                rebuildRows()
                notify()
                requestScan(full: true)
            } else if case .multiMemberDisk = reason {
                finish(.failed("\u{201C}\(displayName)\u{201D} is on a RAID set or multi-disk volume. Ejectable can\u{2019}t eject those yet."))
            } else {
                finish(.failed("Ejectable refused to \(verb) it: \(reason)."))
            }
        case .failed:
            finish(.failed("macOS couldn\u{2019}t \(verb) it (\(r))."))
        case .ejected, .unmountedNotEjected, .volumeUnmounted:
            break                                            // handled above
        }
    }

    private func maybeAutoRetry() {
        guard state == .blocked || state == .quitting, scanHolders.isEmpty, !ejectInFlight, !forceInFlight,
              !forceCheckInFlight else { return }
        let wait = consecutiveBusy <= 2 ? deps.minRetryInterval : deps.slowRetryInterval
        guard Date().timeIntervalSince(lastEjectAt) >= wait else { return }
        deps.log?.record("flow", "\(displayName): nothing visible holds it; soft \(verb) retry #\(ejectRequestCount)")
        state = .retrying
        sendEject(force: false)                               // S1: never force here
    }

    private func finish(_ s: State) {
        state = s
        timer?.invalidate()
        timer = nil
        if let activity { ProcessInfo.processInfo.endActivity(activity); self.activity = nil }
        tasks.values.forEach { $0.cancel() }
        tasks.removeAll()
        taskTokens.removeAll()
        waitStarted.removeAll()
        pendingConfirmation = nil
        deps.log?.record("flow", "\(displayName) (\(disk.bsdName)\(isVolumeMode ? ", volume mode" : "")): \(s)")
        notify()
    }

    // MARK: - Scan

    /// While a flow runs, App Nap must not throttle the 1 s holder poll, the Terminator waits or DA callbacks:
    /// an unfocused accessory app with an occluded alert was measured answering its main queue tens of seconds late.
    private func beginActivity() {
        guard activity == nil else { return }
        activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiatedAllowingIdleSystemSleep],
                                                         reason: "Ejecting \(displayName)")
    }

    private func startTimer() {
        guard deps.rescanInterval > 0 else { return }
        let t = Timer(timeInterval: deps.rescanInterval, repeats: true) { _ in
            MainActor.assumeIsolated { self.tick() }
        }
        RunLoop.main.add(t, forMode: .common)                 // keeps firing inside the alert's modal loop
        timer = t
    }

    /// `full: false` re-inspects only the known holders (cheap; used for the 1 s ticks and after quit/stop).
    /// A clear partial result triggers a full scan, and only a full scan can trigger the automatic retry.
    private func requestScan(full: Bool = false) {
        guard !state.isFinished else { return }
        let full = full || deps.rescan == nil
        if !full && scanHolders.isEmpty { return }        // nothing known to re-check; periodic full scans find new ones
        guard !scanInFlight else {
            rescanPending = true
            pendingFull = pendingFull || full
            return
        }
        scanInFlight = true
        let scope = scope
        if full {
            let scan = deps.scan
            Task.detached(priority: .userInitiated) {
                let result = scan(scope)
                await self.handleScan(result, full: true)
            }
        } else if let rescan = deps.rescan {
            let pids = scanHolders.map(\.pid)
            Task.detached(priority: .userInitiated) {
                let result = rescan(scope, pids)
                await self.handleScan(result, full: false)
            }
        }
    }

    private func handleScan(_ s: HolderScan, full: Bool) {
        scanInFlight = false
        guard !state.isFinished else { return }
        lastScan = s
        if full { lastFullScanIncomplete = s.incomplete; deniedProcessCount = s.deniedPIDs.count }
        scanHolders = s.holders
        if let d = dissenter, scanHolders.contains(where: { $0.pid == d.pid }) || !d.isSameProcess() { dissenter = nil }
        let present = Set(holders.map(\.pid))
        statuses = statuses.filter { present.contains($0.key) }
        recomputeGate()
        rebuildRows()
        if state == .ejecting && !scanHolders.isEmpty { state = .blocked }
        if state == .quitting && !rows.contains(where: isActivelyQuitting) { state = .blocked }
        if full { maybeAutoRetry() } else if scanHolders.isEmpty { rescanPending = true; pendingFull = true }
        notify()
        if rescanPending {
            let f = pendingFull
            rescanPending = false
            pendingFull = false
            requestScan(full: f)
        }
    }

    private func refreshTimeMachine() {
        guard !tmInFlight else { return }
        tmInFlight = true
        let tm = deps.timeMachine, scope = scope
        Task.detached(priority: .utility) {
            let facts = tm(scope)
            await self.setTimeMachine(facts)
        }
    }

    private func setTimeMachine(_ f: TimeMachineFacts) {
        tmInFlight = false
        guard !state.isFinished, f != timeMachine else { return }
        timeMachine = f
        recomputeGate()
        notify()
    }

    /// S2. Besides the scan's own `incomplete`, a scan that resolved no mount point at all while the disk has volumes
    /// knows nothing (every statfs/realpath failed on a sick drive): blocked here too, whatever the scanner said.
    private func recomputeGate() {
        var unknown = lastFullScanIncomplete
        if (lastScan?.scannedTargets.isEmpty ?? false) && !scope.volumePaths.isEmpty { unknown = true }   // nothing scanned
        blockers = SafetyGate.forceEjectBlockers(holders: holders, disk: disk, timeMachine: timeMachine, scanIncomplete: unknown)
        risks = SafetyGate.forceEjectRisks(holders: holders)
    }

    // MARK: - Quit / stop

    /// A new wait for this row; the previous one (if any) is cancelled and its result ignored.
    private func newToken(_ pid: pid_t) -> UUID {
        tasks[pid]?.cancel()
        tasks[pid] = nil
        let token = UUID()
        taskTokens[pid] = token
        return token
    }

    private func isCurrent(_ pid: pid_t, _ token: UUID) -> Bool { taskTokens[pid] == token }

    private func startQuit(_ target: Holder, rowPID: pid_t) {
        let token = newToken(rowPID)
        let grace = deps.grace.seconds(for: target.kind)
        statuses[rowPID] = .quitting(elapsed: 0, grace: grace)
        waitStarted[rowPID] = Date()
        let terminator = deps.terminator
        tasks[rowPID] = Task {
            let r = await terminator.quit(target, timeout: grace) { elapsed in
                if self.isCurrent(rowPID, token) { self.quitProgress(rowPID, elapsed) }
            }
            if self.isCurrent(rowPID, token) { self.quitFinished(rowPID, r) }
        }
    }

    private func startForceQuit(_ h: Holder) {
        let token = newToken(h.pid)
        statuses[h.pid] = .forceQuitting
        let terminator = deps.terminator
        tasks[h.pid] = Task {
            let r = await terminator.forceQuit(h)
            if self.isCurrent(h.pid, token) { self.quitFinished(h.pid, r) }
        }
    }

    /// The countdown changes once a second (the Terminator polls every 250 ms).
    private func quitProgress(_ pid: pid_t, _ elapsed: TimeInterval) {
        guard case .quitting(let prev, let grace)? = statuses[pid],
              Self.remaining(elapsed: elapsed, grace: grace) != Self.remaining(elapsed: prev, grace: grace) else { return }
        statuses[pid] = .quitting(elapsed: elapsed, grace: grace)
        rebuildRows()
        notify()
    }

    /// After SIGTERM: every 250 ms, until the process is gone or its grace has passed, keep the countdown current; at
    /// the end of the grace the row's primary button becomes Kill (`makeRow`).
    private func startStopWait(_ h: Holder, grace: TimeInterval) {
        let token = newToken(h.pid)
        tasks[h.pid] = Task {
            let started = Date()
            var shown = Self.remaining(elapsed: 0, grace: grace)
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(Terminator.pollInterval * 1e9))
                guard self.isCurrent(h.pid, token), !self.state.isFinished else { return }
                let elapsed = Date().timeIntervalSince(started)
                if !h.isSameProcess() || elapsed >= grace { break }
                let left = Self.remaining(elapsed: elapsed, grace: grace)
                if left != shown {
                    shown = left
                    self.rebuildRows()
                    self.notify()
                }
            }
            guard self.isCurrent(h.pid, token), !self.state.isFinished else { return }
            self.tasks[h.pid] = nil
            self.taskTokens[h.pid] = nil
            if case .stopping? = self.statuses[h.pid], h.isSameProcess() {
                self.deps.log?.record("flow", "\(h.pid) \(h.displayName) still running \(QuitGrace.format(grace)) s after SIGTERM: Kill is now its row\u{2019}s button")
            }
            if self.state == .quitting && !self.rows.contains(where: self.isActivelyQuitting) { self.state = .blocked }
            self.rebuildRows()
            self.requestScan()
            self.notify()
        }
    }

    /// S9: the force button was used while the graceful wait still ran (revealed on hover / keyboard focus).
    private func logEarlyForce(_ row: Row) {
        let h = row.holder
        let elapsed = waitStarted[h.pid].map { String(format: "%.1f", Date().timeIntervalSince($0)) } ?? "?"
        let into: String = switch row.status {
        case .quitting(_, let grace), .stopping(_, let grace): "\(elapsed) s into its \(QuitGrace.format(grace)) s grace"
        default: "while waiting"
        }
        deps.log?.record("flow", "\(row.secondaryTitle ?? "force") clicked for \(h.pid) \(h.displayName) [\(h.kind.rawValue)] \(into) (revealed on hover / focus)")
    }

    private func quitFinished(_ pid: pid_t, _ r: QuitOutcome) {
        tasks[pid] = nil
        taskTokens[pid] = nil
        guard !state.isFinished else { return }
        switch r {
        case .quit, .notFound, .cancelled: statuses[pid] = nil
        case .stillRunning: statuses[pid] = .quitTimedOut
        case .pidMismatch: statuses[pid] = .note("The process changed; nothing was sent.")
        case .noApplication: statuses[pid] = .note("No running app to quit.")
        case .refused: statuses[pid] = .note("This process is never quit.")
        }
        if state == .quitting && !rows.contains(where: isActivelyQuitting) { state = .blocked }
        rebuildRows()
        requestScan()
        notify()
    }

    private func handleSignal(_ h: Holder, _ outcome: SignalOutcome, stopping: Bool) {
        if case .sent = outcome, stopping {
            let grace = deps.grace.seconds(for: h.kind)
            statuses[h.pid] = .stopping(since: Date(), grace: grace)
            waitStarted[h.pid] = Date()
            deps.log?.record("flow", "\(h.pid) \(h.displayName) [\(h.kind.rawValue)]: SIGTERM sent; grace \(QuitGrace.format(grace)) s before Kill becomes its row\u{2019}s button")
            startStopWait(h, grace: grace)
            return
        }
        if !stopping { _ = newToken(h.pid); taskTokens[h.pid] = nil }   // Kill ends the stop wait
        switch outcome {
        case .sent: statuses[h.pid] = .note("Killed.")
        case .notFound: statuses[h.pid] = nil
        case .pidMismatch: statuses[h.pid] = .note("The process changed; nothing was sent.")
        case .refused: statuses[h.pid] = .note("This process is never stopped.")
        case .notStoppedFirst: statuses[h.pid] = .note("Stop it first.")
        case .failed(let e): statuses[h.pid] = .note("Couldn\u{2019}t stop it (\(String(cString: strerror(e)))).")
        }
    }

    private func isActivelyQuitting(_ row: Row) -> Bool { row.status.isWaiting }

    // MARK: - Rows

    /// Quit All could cover this row once it is unblocked: everything Quit All handles, plus CLI writers (which
    /// need their own confirmed Stop first, S3). Decides "Quit All & Eject" (disabled + hint) vs "Try Again".
    func isQuittableInPrinciple(_ row: Row) -> Bool {
        if quitAllAction(for: row) != nil { return true }
        return row.holder.kind == .cli && row.holder.isWriter && row.remedy.action != .none && !row.remedy.neverTerminate
    }

    /// GUI kinds Quit All / the row may end with terminate(): not when the remedy says the user does it (Finder
    /// window: close it) or never (S4).
    static func isGUIQuittable(_ h: Holder, _ remedy: Remedy) -> Bool {
        Terminator.quittableKinds.contains(h.kind) && !remedy.neverTerminate && remedy.action != .none
    }

    /// CLI tools (SIGTERM, not shells sitting in a folder) and the Quick Look daemons (S4 exception).
    static func isStoppable(_ h: Holder, _ remedy: Remedy) -> Bool {
        if Terminator.isQuickLookException(h) { return true }
        return h.kind == .cli && remedy.action != .none && !remedy.neverTerminate
    }

    /// The running app a daemon's remedy says to quit (Photos for photolibraryd): exact bundle id first, a prefix
    /// only as `Remedies.remedyAppIndex` allows (never com.apple.MusicRecognitionMac for Music).
    static func remedyApp(_ remedy: Remedy) -> NSRunningApplication? {
        guard let id = remedy.quitAppBundleID else { return nil }
        let apps = NSWorkspace.shared.runningApplications.filter { !$0.isTerminated }
        guard let i = Remedies.remedyAppIndex(quitAppBundleID: id, quitAppName: remedy.quitAppName,
                                              candidates: apps.map { ($0.bundleIdentifier, $0.localizedName) }) else { return nil }
        let app = apps[i]
        if Terminator.neverQuitReason(bundleIdentifier: app.bundleIdentifier, pid: app.processIdentifier) != nil { return nil }
        return app
    }

    /// What Quit All does for this row; nil = not quittable, so Quit All is unavailable (S1/S3/S4).
    public func quitAllAction(for row: Row) -> RowAction? {
        let h = row.holder
        if Terminator.isQuickLookException(h) { return .stop }       // S4 exception: read-only, respawns
        guard !row.remedy.neverTerminate else { return nil }
        switch h.kind {
        case .app, .appExtension, .helper:
            guard Self.isGUIQuittable(h, row.remedy) else { return nil }
            if row.status.isWaiting { return .quit }
            return Terminator.targetApplication(for: h) != nil ? .quit : nil
        case .cli:
            guard !h.isWriter, row.remedy.action != .none else { return nil }   // writers: per-row Stop + confirm
            return .stop
        case .daemon, .inaccessible:
            return nil
        }
    }

    private func rebuildRows() {
        let order: [HolderKind: Int] = [.app: 0, .appExtension: 1, .helper: 2, .cli: 3, .daemon: 4, .inaccessible: 5]
        let scanPIDs = Set(scanHolders.map(\.pid))
        rows = holders
            .sorted { (order[$0.kind] ?? 9, $0.displayName.lowercased(), $0.pid) < (order[$1.kind] ?? 9, $1.displayName.lowercased(), $1.pid) }
            .map { makeRow($0, isDissenterOnly: !scanPIDs.contains($0.pid)) }
    }

    /// The labelled force action of a holder's row (S3): what it is called and what it costs. Apps and helpers (whose
    /// quit goes to their app) lose unsaved changes; app extensions rarely hold any (a share extension may hold a draft); a CLI tool stops mid-work.
    nonisolated static func forceButton(for h: Holder) -> (action: RowAction, title: String, toolTip: String) {
        switch h.kind {
        case .app:
            return (.forceQuit, "Force Quit", "Unsaved changes in \(h.displayName) will be lost")
        case .helper:
            return (.forceQuit, "Force Quit", "Unsaved changes in \(Remedies.parentName(h) ?? h.displayName) will be lost")
        case .appExtension:
            return (.forceQuit, "Force Stop", "Force Stop ends \(h.displayName) immediately. Extensions rarely hold unsaved work.")
        case .cli, .daemon, .inaccessible:
            if Terminator.isQuickLookException(h) {
                return (.kill, "Kill", "Stops \(h.displayName) immediately; Quick Look restarts on its own")
            }
            return (.kill, "Kill", "Stops \(h.displayName) immediately; a copy or encode in progress will be incomplete")
        }
    }

    /// Never force-quit (Finder: it relaunches after a normal quit). Checks the holder's own bundle id and, for helpers,
    /// its app's; `Terminator.forceQuit` refuses these too.
    nonisolated static func isGracefulOnly(_ h: Holder) -> Bool {
        if let id = h.bundleIdentifier, Terminator.isGracefulOnly(id) { return true }
        if h.kind == .helper, let id = Remedies.parentBundleID(h), Terminator.isGracefulOnly(id) { return true }
        return false
    }

    private func makeRow(_ h: Holder, isDissenterOnly: Bool) -> Row {
        let remedy = Remedies.remedy(for: h)
        let status = statuses[h.pid] ?? .idle
        var action = RowAction.none
        var title: String?
        var enabled = true
        var secondary: (action: RowAction, title: String, toolTip: String)?

        let guiQuittable = Self.isGUIQuittable(h, remedy)
        let cliStoppable = Self.isStoppable(h, remedy)
        if guiQuittable {
            let force = Self.forceButton(for: h)
            switch status {
            case .quitting:
                // "Stop" rows (the AirDrop share sheet) count down as "Stopping…", the rest as "Quitting…".
                let verbing = remedy.buttonTitle == "Stop" ? "Stopping" : "Quitting"
                action = .quit; title = "\(verbing)\u{2026} (\(status.graceRemaining ?? 0)s)"; enabled = false
                if !Self.isGracefulOnly(h) { secondary = force }      // hover / Tab: one click, labelled (S3)
            case .forceQuitting:
                action = .forceQuit; title = force.title == "Force Stop" ? "Stopping\u{2026}" : "Quitting\u{2026}"; enabled = false
            case .quitTimedOut:
                if Self.isGracefulOnly(h) || Terminator.targetApplication(for: h)?.bundleIdentifier.map(Terminator.isGracefulOnly) == true {
                    // Finder relaunches after a normal quit; it is never force-quit.
                    action = .quit; title = "Quit"
                } else {
                    // Grace expired: the force action becomes the row's button (still one click per process).
                    action = force.action; title = force.title
                }
            default:
                if Terminator.targetApplication(for: h) != nil { action = .quit; title = remedy.buttonTitle ?? "Quit" }
            }
        } else if cliStoppable {
            if case .stopping(let since, let grace) = status {
                if Date().timeIntervalSince(since) >= grace {
                    action = .kill; title = "Kill"                   // grace expired: Kill is the row's button
                } else {
                    action = .stop; title = "Stopping\u{2026} (\(status.graceRemaining ?? 0)s)"; enabled = false
                    secondary = Self.forceButton(for: h)            // Kill, one hover / Tab away (second click, S3)
                }
            } else {
                action = .stop; title = "Stop"
            }
        } else {
            if let url = Remedies.settingsURL(for: remedy.action) {
                action = .openSettings(url)
                title = Remedies.settingsButtonTitle(for: remedy.action)
            } else if let app = Self.remedyApp(remedy), let bid = app.bundleIdentifier {
                let name = app.localizedName ?? "App"
                if case .quitting = status {
                    action = .quitApp(bundleID: bid, name: name); title = "Quitting\u{2026} (\(status.graceRemaining ?? 0)s)"; enabled = false
                } else {
                    action = .quitApp(bundleID: bid, name: name); title = "Quit \(name)"
                }
            }
        }
        return Row(holder: h, remedy: remedy, status: status, action: action, actionTitle: title,
                   actionEnabled: enabled, isDissenterOnly: isDissenterOnly, secondaryAction: secondary?.action,
                   secondaryTitle: secondary?.title, secondaryToolTip: secondary?.toolTip)
    }

    private func notify() { delegate?.ejectFlowDidUpdate(self) }
}
