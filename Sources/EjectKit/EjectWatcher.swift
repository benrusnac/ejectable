import DiskArbitration
import Foundation
import os

// Finder-companion mode (PLAN §2, phase 3). Observes unmount/eject requests made by anyone else (Finder, diskutil,
// another app) and reports whether they failed, with a holder scan, so the app can show its alert next to Apple's.
//
// S7: this is an observe-only DiskArbitration client. The approval callbacks return nil (approve) immediately and
// never a dissenter; they only copy the BSD name / volume path and hand off to a work queue. The DA session runs on
// its own serial queue that does nothing else, so a slow scan, a blocked main thread or a bug in the work queue can
// never delay an answer to diskarbitrationd.
//
// DA has no callback for a failed unmount (RECON §3). Outcome inference:
//  - primary: the private, exported `DARegisterIdleCallback` (resolved with dlsym) fires when DA's request queue
//    drains, i.e. right after the attempt finished; an approved volume that is still mounted then => failed.
//  - fallback (symbol missing, or `useIdleCallback: false`): poll the mount table every 250 ms; all approved volumes
//    gone => succeeded, still mounted `outcomeTimeout` (20 s) after the last approval => failed.
//  - both: DA's description-changed callback (volume path -> nil, on our own session) and the poll report success as
//    soon as every approved volume is gone; the timeout also backs up the idle path in case an idle never arrives.
//
// Deliberately NOT NSWorkspace.didUnmountNotification: observing NSWorkspace mount notifications makes AppKit open its
// own DA session in this process with an *unmount approval* callback (it backs willUnmountNotification), answered on
// the main thread. Measured here (macOS 26.6, nswsprobe2): while an observer exists that approver answers in the
// default, modal-panel and event-tracking run-loop modes, so a modal alert alone does not stall it; it stops
// answering only after the LAST observer is removed (it stays registered, diskarbitrationd logs "<process> not
// responding" and every unmount on the Mac stalls ~10.9 s). It is still serviced by the main thread, so any
// main-thread stall (a TCC prompt, a hung subprocess) delays every unmount on the Mac. The app therefore observes no
// NSWorkspace mount notifications at all (VolumeMonitor uses its own DA notification session + kqueue EVFILT_FS), and
// this watcher, whose session runs on its own queue, is the only DiskArbitration approver in the process (verified
// from diskarbitrationd's log: with the watcher off, Ejectable receives no approval dispatch at all).

/// What a foreign attempt asked for, as far as DiskArbitration's approvals show it.
///
/// `.eject` only when DA asked us to approve an eject of the physical disk during the attempt. Measured on macOS 26.6:
/// `diskutil eject` / `unmountDisk` (and FileManager's unmount-and-eject) first unmount every volume (one unmount
/// approval per volume) and only ask for the eject once all of them unmounted, so a busy eject shows unmount approvals
/// only and is reported as `.unmount` here. A raw `DADiskEject` on a disk with mounted volumes shows the eject approval
/// (and then fails busy). The companion therefore never ejects a disk unless an eject was visibly requested.
public enum EjectAttemptKind: String, Sendable, Hashable { case unmount, eject }

/// What happened to an unmount/eject that someone else asked DiskArbitration for. Delivered on the main queue.
public enum EjectWatcherEvent: Sendable, CustomStringConvertible {
    /// DA asked us to approve an unmount of `volumeURL` (or an eject of its disk). At most one per physical disk per
    /// burst: Finder's Eject All approves every volume separately; those are folded into one attempt.
    case attemptStarted(volumeURL: URL, disk: PhysicalDisk)
    /// The attempt is over and `volumeURL` is still mounted. `scan` covers every volume on the physical disk and was
    /// taken right after the approval (while the requester was trying). `kind`: `.eject` when an eject approval for the
    /// physical disk was seen during the attempt, else `.unmount` (see `EjectAttemptKind`).
    case failed(volumeURL: URL, disk: PhysicalDisk, scan: HolderScan, kind: EjectAttemptKind)
    /// Every volume the attempt touched is unmounted.
    case succeeded(volumeURL: URL, disk: PhysicalDisk)

    public var volumeURL: URL {
        switch self {
        case .attemptStarted(let u, _), .failed(let u, _, _, _), .succeeded(let u, _): u
        }
    }

    public var disk: PhysicalDisk {
        switch self {
        case .attemptStarted(_, let d), .failed(_, let d, _, _), .succeeded(_, let d): d
        }
    }

    public var description: String {
        switch self {
        case .attemptStarted(let u, let d): "attemptStarted \(u.path) on \(d.bsdName)"
        case .failed(let u, let d, let s, let k): "failed \(k) \(u.path) on \(d.bsdName): \(s.holders.count) holder(s) \(s.holders.map(\.pid))"
        case .succeeded(let u, let d): "succeeded \(u.path) on \(d.bsdName)"
        }
    }
}

public struct EjectWatcherOptions: Sendable, Hashable {
    /// Use the private `DARegisterIdleCallback` when the symbol exists. False forces the public polling fallback.
    public var useIdleCallback: Bool
    /// Mount-table poll interval while an attempt is unresolved (both modes; success only, failure needs idle/timeout).
    public var pollInterval: TimeInterval
    /// Still mounted this long after the last approval => failed. The only failure signal in fallback mode; a safety
    /// net in idle mode.
    public var outcomeTimeout: TimeInterval
    /// Approvals for the same physical disk while its attempt is unresolved, or within this long of its last
    /// approval, belong to that attempt (no second `attemptStarted`).
    public var dedupeWindow: TimeInterval

    public init(useIdleCallback: Bool = true, pollInterval: TimeInterval = 0.25, outcomeTimeout: TimeInterval = 20,
                dedupeWindow: TimeInterval = 2) {
        self.useIdleCallback = useIdleCallback; self.pollInterval = pollInterval
        self.outcomeTimeout = outcomeTimeout; self.dedupeWindow = dedupeWindow
    }
}

/// Counters for diagnostics and the S7 proof (time spent inside DA approval callbacks).
public struct EjectWatcherStats: Sendable, Hashable {
    public internal(set) var approvalCallbacks = 0
    public internal(set) var idleCallbacks = 0
    /// Longest time spent inside one approval callback, entry to return (ns).
    public internal(set) var maxApprovalCallbackNanos: UInt64 = 0
    public internal(set) var totalApprovalCallbackNanos: UInt64 = 0
    /// Approvals caused by this process's own `Ejector` (EjectsInFlight), ignored.
    public internal(set) var ignoredOwnEjects = 0
    /// Approvals for internal/system disks, hidden volumes, or disks without user-visible volumes, ignored.
    public internal(set) var ignoredOther = 0
    public internal(set) var attempts = 0
    public internal(set) var failed = 0
    public internal(set) var succeeded = 0

    public var meanApprovalCallbackNanos: UInt64 {
        approvalCallbacks == 0 ? 0 : totalApprovalCallbackNanos / UInt64(approvalCallbacks)
    }
}

/// Watches DiskArbitration for unmount/eject attempts made by other processes (Finder companion mode).
///
///     let watcher = EjectWatcher { event in coordinator.handle(event) }   // events arrive on the main queue
///     watcher.start()      // when UserDefaults `watchFinderEjects` is on
///     watcher.stop()       // when it is turned off; start() again later is fine
///
/// Attempts on internal/system disks, hidden volumes, network shares, and attempts made by this process's own
/// `Ejector` (in-flight registry) are ignored. Every attempt and outcome is written to the ActionLog (S9).
public final class EjectWatcher: @unchecked Sendable {   // `core` guarded by `lock`
    public typealias EventHandler = @MainActor @Sendable (EjectWatcherEvent) -> Void

    /// True if the private `DARegisterIdleCallback` symbol is exported on this macOS.
    public static var idleCallbackAvailable: Bool { Core.registerIdle != nil }

    public let options: EjectWatcherOptions
    private let onEvent: EventHandler
    private let trace: (@Sendable (String) -> Void)?
    private let log: ActionLog?
    private let statsBox = OSAllocatedUnfairLock(initialState: EjectWatcherStats())
    private let lock = NSLock()
    private var core: Core?

    /// `trace`: optional verbose diagnostics (approval callbacks, timings, ignore reasons), called on a private queue.
    public init(options: EjectWatcherOptions = .init(), log: ActionLog? = .shared,
                trace: (@Sendable (String) -> Void)? = nil, onEvent: @escaping EventHandler) {
        self.options = options
        self.log = log
        self.trace = trace
        self.onEvent = onEvent
    }

    deinit { stop() }

    public var isRunning: Bool { lock.withLock { core != nil } }

    /// Whether the running watcher infers failures from the idle callback (false: polling fallback).
    public var usesIdleCallback: Bool { lock.withLock { core?.idleRegistered ?? false } }

    public var stats: EjectWatcherStats { statsBox.withLock { $0 } }

    /// Registers the DA approval callbacks. Idempotent. Returns false if no DA session could be created.
    @discardableResult
    public func start() -> Bool {
        lock.withLock {
            if core != nil { return true }
            let c = Core(options: options, log: log, trace: trace, stats: statsBox, onEvent: onEvent)
            guard c.start() else { return false }
            core = c
            return true
        }
    }

    /// Unregisters and tears the session down. Safe to call repeatedly, from any thread. No event is delivered after
    /// `stop()` returns (on the main thread) / once it has been observed. DA callbacks that were already in flight are
    /// still answered (nil) during a short drain, so diskarbitrationd is never left waiting on us.
    public func stop() {
        let c: Core? = lock.withLock { defer { core = nil }; return core }
        c?.stop()
    }
}

// MARK: - Core (one per start/stop cycle)

private final class Core: @unchecked Sendable {
    // Confinement: `session`/`retained` are set in start() before the session is scheduled, then only touched on
    // `daQueue`. `attempts`, `timer`, `lookupSession`, `nextID` only on `workQueue`.

    typealias ApprovalKind = EjectAttemptKind

    struct Approval: Sendable {
        let kind: ApprovalKind
        let bsd: String
        let path: String?
        /// Uptime (ns) at callback entry.
        let at: UInt64
        /// Time spent in the callback up to the hand-off (ns).
        let callbackNanos: UInt64
    }

    struct Watched: Hashable { let bsd: String; let path: String }

    enum Trigger: String { case idle = "idle callback", poll = "poll", pathCleared = "volume path cleared", timeout = "timeout" }

    enum Outcome: Equatable { case failed, succeeded }

    final class Attempt {
        let id: Int
        let physical: String
        var disk: PhysicalDisk
        let volumeURL: URL
        let kind: ApprovalKind
        /// An eject approval for the physical disk arrived during this attempt (the first one or a joined one).
        var sawEject: Bool
        let firstApprovalAt: UInt64
        var lastApprovalAt: UInt64
        var watched: [Watched]
        var scan: HolderScan?
        var needsOutcome = true
        var reported: Outcome?
        /// Failure decided before the scan finished: emitted when it does.
        var pendingFailure: (still: [Watched], trigger: Trigger, at: UInt64)?

        init(id: Int, physical: String, disk: PhysicalDisk, volumeURL: URL, kind: ApprovalKind, at: UInt64, watched: [Watched]) {
            self.id = id; self.physical = physical; self.disk = disk; self.volumeURL = volumeURL; self.kind = kind
            self.sawEject = kind == .eject
            self.firstApprovalAt = at; self.lastApprovalAt = at; self.watched = watched
        }
    }

    // Private SPI: void DARegisterIdleCallback(DASessionRef, void (*)(void *context), void *context). Exported by
    // DiskArbitration.framework, not in the headers (RECON §3).
    typealias IdleCallback = @convention(c) (UnsafeMutableRawPointer?) -> Void
    typealias RegisterIdle = @convention(c) (DASession, IdleCallback, UnsafeMutableRawPointer?) -> Void
    static let registerIdle: RegisterIdle? = {
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "DARegisterIdleCallback") else { return nil }  // RTLD_DEFAULT
        return unsafeBitCast(sym, to: RegisterIdle.self)
    }()

    /// How long a stopped session stays scheduled to answer approvals DA dispatched before it saw the unregistration.
    static let drainDelay: TimeInterval = 1.0
    static let logger = Logger(subsystem: ActionLog.subsystem, category: "watcher")

    let options: EjectWatcherOptions
    let log: ActionLog?
    let trace: (@Sendable (String) -> Void)?
    let stats: OSAllocatedUnfairLock<EjectWatcherStats>
    let onEvent: EjectWatcher.EventHandler
    let daQueue = DispatchQueue(label: "com.benrusnac.ejectable.watcher.da", qos: .userInteractive)
    let workQueue = DispatchQueue(label: "com.benrusnac.ejectable.watcher", qos: .userInitiated)
    let stopped = OSAllocatedUnfairLock(initialState: false)

    private var session: DASession?
    private var retained: Unmanaged<Core>?
    private(set) var idleRegistered = false
    private var lookupSession: DASession?
    private var attempts: [String: Attempt] = [:]
    private var timer: DispatchSourceTimer?
    private var nextID = 1

    // C entry points, stored so the identical pointers can be unregistered. Approval callbacks always return nil (S7).
    private let unmountApproval: DADiskUnmountApprovalCallback = { disk, ctx in
        if let ctx { Unmanaged<Core>.fromOpaque(ctx).takeUnretainedValue().approval(disk, .unmount) }
        return nil
    }
    private let ejectApproval: DADiskEjectApprovalCallback = { disk, ctx in
        if let ctx { Unmanaged<Core>.fromOpaque(ctx).takeUnretainedValue().approval(disk, .eject) }
        return nil
    }
    private let idle: IdleCallback = { ctx in
        if let ctx { Unmanaged<Core>.fromOpaque(ctx).takeUnretainedValue().idleFired() }
    }
    // Notification (DA does not wait for an answer): a volume's path changed, e.g. to nil on unmount.
    private let pathChanged: DADiskDescriptionChangedCallback = { _, _, ctx in
        if let ctx { Unmanaged<Core>.fromOpaque(ctx).takeUnretainedValue().volumePathChanged() }
    }

    init(options: EjectWatcherOptions, log: ActionLog?, trace: (@Sendable (String) -> Void)?,
         stats: OSAllocatedUnfairLock<EjectWatcherStats>, onEvent: @escaping EjectWatcher.EventHandler) {
        self.options = options; self.log = log; self.trace = trace; self.stats = stats; self.onEvent = onEvent
    }

    var isStopped: Bool { stopped.withLock { $0 } }

    static func uptime() -> UInt64 { DispatchTime.now().uptimeNanoseconds }

    // MARK: Lifecycle

    func start() -> Bool {
        guard let s = DASessionCreate(kCFAllocatorDefault) else { return false }
        // The context must outlive the session's schedule: released only after the session is torn down.
        let ctx = Unmanaged.passRetained(self)
        retained = ctx
        let p = ctx.toOpaque()
        // Same dictionaries as kDADiskDescriptionMatchVolumeMountable / kDADiskDescriptionMatchMediaWhole.
        let volumes = [kDADiskDescriptionVolumeMountableKey as String: true] as CFDictionary
        let wholeDisks = [kDADiskDescriptionMediaWholeKey as String: true] as CFDictionary
        DARegisterDiskUnmountApprovalCallback(s, volumes, unmountApproval, p)
        DARegisterDiskEjectApprovalCallback(s, wholeDisks, ejectApproval, p)
        DARegisterDiskDescriptionChangedCallback(s, volumes, [kDADiskDescriptionVolumePathKey] as CFArray, pathChanged, p)
        if options.useIdleCallback, let register = Core.registerIdle {
            register(s, idle, p)
            idleRegistered = true
        }
        session = s
        DASessionSetDispatchQueue(s, daQueue)

        workQueue.async { [self] in lookupSession = DASessionCreate(kCFAllocatorDefault) }

        let mode = idleRegistered ? "DARegisterIdleCallback"
            : "poll fallback (\(Core.registerIdle == nil ? "symbol missing" : "idle callback disabled"))"
        log?.record("watch", "started: observing foreign unmount/eject attempts; outcome via \(mode), "
                    + "poll \(Int(options.pollInterval * 1000)) ms, timeout \(Int(options.outcomeTimeout)) s")
        return true
    }

    func stop() {
        let first = stopped.withLock { s -> Bool in defer { s = true }; return !s }
        guard first else { return }
        daQueue.async { [self] in
            guard let s = session else { return }
            let p = retained?.toOpaque()
            DAUnregisterCallback(s, unsafeBitCast(unmountApproval, to: UnsafeMutableRawPointer.self), p)
            DAUnregisterCallback(s, unsafeBitCast(ejectApproval, to: UnsafeMutableRawPointer.self), p)
            DAUnregisterCallback(s, unsafeBitCast(pathChanged, to: UnsafeMutableRawPointer.self), p)
            if idleRegistered { DAUnregisterCallback(s, unsafeBitCast(idle, to: UnsafeMutableRawPointer.self), p) }
            // Keep answering (nil) anything DA dispatched before it processed the unregistration, then drop the
            // session; releasing it closes its port, which diskarbitrationd treats as the client going away.
            daQueue.asyncAfter(deadline: .now() + Core.drainDelay) { [self] in
                if let s = session { DASessionSetDispatchQueue(s, nil) }
                session = nil
                retained?.release()
                retained = nil
            }
        }
        workQueue.async { [self] in
            timer?.cancel(); timer = nil
            attempts.removeAll()
            lookupSession = nil
        }
        let st = stats.withLock { $0 }
        log?.record("watch", "stopped: \(st.approvalCallbacks) approval callback(s), max \(Core.micros(st.maxApprovalCallbackNanos)) µs, "
                    + "mean \(Core.micros(st.meanApprovalCallbackNanos)) µs inside the callback; \(st.attempts) attempt(s), "
                    + "\(st.failed) failed, \(st.succeeded) succeeded, \(st.ignoredOwnEjects) own eject(s) ignored")
    }

    // MARK: DA callbacks (daQueue). Nothing here may block: copy two values, hand off, return.

    func approval(_ disk: DADisk, _ kind: ApprovalKind) {
        let t0 = Core.uptime()
        defer {                                         // every callback is counted and timed, also during the drain
            let dt = Core.uptime() - t0
            stats.withLock {
                $0.approvalCallbacks += 1
                $0.totalApprovalCallbackNanos += dt
                $0.maxApprovalCallbackNanos = max($0.maxApprovalCallbackNanos, dt)
            }
        }
        if stopped.withLock({ $0 }) { return }
        guard let name = DADiskGetBSDName(disk) else { return }
        let bsd = String(cString: name)
        var path: String?
        if kind == .unmount, let desc = DADiskCopyDescription(disk) {
            path = ((desc as NSDictionary)[kDADiskDescriptionVolumePathKey as String] as? URL)?.path
        }
        let item = Approval(kind: kind, bsd: bsd, path: path, at: t0, callbackNanos: Core.uptime() - t0)
        workQueue.async { [self] in handle(item) }
    }

    func idleFired() {
        if stopped.withLock({ $0 }) { return }
        stats.withLock { $0.idleCallbacks += 1 }
        workQueue.async { [self] in evaluate(.idle) }
    }

    func volumePathChanged() {
        if stopped.withLock({ $0 }) { return }
        workQueue.async { [self] in
            guard attempts.values.contains(where: { $0.needsOutcome }) else { return }
            evaluate(.pathCleared)
        }
    }

    // MARK: Work queue

    private func handle(_ a: Approval) {
        guard !isStopped else { return }
        let tag = "\(a.kind) approval \(a.bsd)\(a.path.map { " \($0)" } ?? "")"
        guard let (physical, isInternal) = resolvePhysical(a.bsd) else {
            trace?("\(tag): callback \(Core.micros(a.callbackNanos)) µs; disk already gone, ignored")
            return
        }
        // Our own Ejector (same process) asked for this: not a foreign attempt.
        if EjectsInFlight.shared.wasInFlight(physicalBSD: physical, at: a.at) {
            stats.withLock { $0.ignoredOwnEjects += 1 }
            trace?("\(tag): callback \(Core.micros(a.callbackNanos)) µs; own eject of \(physical) in flight, ignored")
            Core.logger.debug("ignored own eject approval \(a.bsd, privacy: .public) on \(physical, privacy: .public)")
            return
        }
        if isInternal { return ignore(tag, a, "internal disk \(physical)") }

        var approved: [Watched] = []
        if a.kind == .unmount {
            let mounts = Core.mounts()
            let entry = mounts.first { $0.from == "/dev/" + a.bsd } ?? a.path.flatMap { p in mounts.first { $0.path == p } }
            guard let path = entry?.path ?? a.path, Core.isUserVolume(path, browsable: entry?.browsable ?? true) else {
                return ignore(tag, a, "not a user-visible volume")
            }
            approved = [Watched(bsd: a.bsd, path: path)]
        }

        let now = Core.uptime()
        if let att = attempts[physical], att.needsOutcome || now < att.lastApprovalAt + Core.nanos(options.dedupeWindow) {
            att.lastApprovalAt = max(att.lastApprovalAt, a.at)
            if a.kind == .eject { att.sawEject = true }
            for w in approved where !att.watched.contains(w) { att.watched.append(w) }
            att.needsOutcome = true
            trace?("\(tag): callback \(Core.micros(a.callbackNanos)) µs; joins attempt #\(att.id) on \(physical)")
            updateTimer()
            return
        }

        guard let disk = DiskTopology.physicalDisk(bsdName: physical) else { return ignore(tag, a, "\(physical) vanished") }
        if let refusal = Ejector.safetyCheck(disk, policy: .externalDisks) { return ignore(tag, a, "\(refusal)") }
        if a.kind == .eject {
            approved = disk.volumes.filter { Core.isUserVolume($0.path, browsable: $0.isBrowsable) }
                .compactMap { v in v.bsdName.map { Watched(bsd: $0, path: v.path) } }
            guard !approved.isEmpty else { return ignore(tag, a, "no user-visible volume mounted on \(physical)") }
        }

        let att = Attempt(id: nextID, physical: physical, disk: disk,
                          volumeURL: URL(fileURLWithPath: approved[0].path, isDirectory: true),
                          kind: a.kind, at: a.at, watched: approved)
        nextID += 1
        attempts[physical] = att
        stats.withLock { $0.attempts += 1 }
        let latency = Core.millis(Core.uptime() - a.at)
        log?.record("watch", "attempt #\(att.id): foreign \(a.kind) of \(approved.map(\.path).joined(separator: ", ")) on \(physical) "
                    + "(\(disk.deviceModel ?? "?"), \(disk.isVirtual ? "disk image" : "real disk")); approval callback "
                    + "\(Core.micros(a.callbackNanos)) µs, answered nil")
        trace?("\(tag): callback \(Core.micros(a.callbackNanos)) µs; attempt #\(att.id) on \(physical), reported \(latency) ms after approval")
        emit(.attemptStarted(volumeURL: att.volumeURL, disk: disk))

        // Scan every volume on the physical disk (a sibling's holder blocks the eject too), off the work queue.
        let paths = disk.volumePaths.isEmpty ? approved.map(\.path) : disk.volumePaths
        let id = att.id
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let scan = HolderScanner.scan(volumePaths: paths, log: log)
            workQueue.async { [self] in scanFinished(id: id, physical: physical, scan) }
        }
        updateTimer()
    }

    private func ignore(_ tag: String, _ a: Approval, _ why: String) {
        stats.withLock { $0.ignoredOther += 1 }
        trace?("\(tag): callback \(Core.micros(a.callbackNanos)) µs; ignored (\(why))")
        Core.logger.debug("ignored \(tag, privacy: .public): \(why, privacy: .public)")
    }

    private func scanFinished(id: Int, physical: String, _ scan: HolderScan) {
        guard !isStopped, let att = attempts[physical], att.id == id else { return }
        att.scan = scan
        trace?("attempt #\(id): scan \(String(format: "%.0f", scan.duration * 1000)) ms, \(scan.holders.count) holder(s) "
               + "\(scan.holders.map { "\($0.pid) \($0.displayName)" }), \(scan.deniedPIDs.count) pids not inspectable")
        if let pf = att.pendingFailure {
            att.pendingFailure = nil
            emitFailed(att, still: pf.still, trigger: pf.trigger, decidedAt: pf.at)
        }
    }

    /// Decide outcomes. Success whenever every approved volume is gone; failure only on idle (DA finished) or timeout.
    private func evaluate(_ trigger: Trigger) {
        guard !isStopped else { return }
        let now = Core.uptime()
        let pending = attempts.values.filter(\.needsOutcome)
        if trigger == .idle { trace?("idle callback (\(pending.count) attempt(s) pending)") }
        if !pending.isEmpty {
            let mounts = Core.mounts()
            for att in pending.sorted(by: { $0.id < $1.id }) {
                let still = att.watched.filter { w in mounts.contains { $0.from == "/dev/" + w.bsd || $0.path == w.path } }
                if still.isEmpty {
                    resolve(att, .succeeded, still: [], trigger: trigger, now: now)
                } else if trigger == .idle {
                    resolve(att, .failed, still: still, trigger: .idle, now: now)
                } else if now >= att.lastApprovalAt + Core.nanos(options.outcomeTimeout) {
                    resolve(att, .failed, still: still, trigger: .timeout, now: now)
                }
            }
        }
        attempts = attempts.filter { _, a in
            a.needsOutcome || a.pendingFailure != nil || now < a.lastApprovalAt + Core.nanos(options.dedupeWindow)
        }
        updateTimer()
    }

    private func resolve(_ att: Attempt, _ outcome: Outcome, still: [Watched], trigger: Trigger, now: UInt64) {
        att.needsOutcome = false
        guard att.reported != outcome else { return }       // e.g. a joined approval failing again: one alert
        att.reported = outcome
        switch outcome {
        case .succeeded:
            stats.withLock { $0.succeeded += 1 }
            let after = Core.millis(now - att.firstApprovalAt)
            log?.record("watch", "attempt #\(att.id) on \(att.physical) succeeded: \(att.watched.map(\.path).joined(separator: ", ")) "
                        + "unmounted (\(trigger.rawValue), \(after) ms after approval)")
            trace?("attempt #\(att.id): succeeded via \(trigger.rawValue), \(after) ms after approval")
            emit(.succeeded(volumeURL: att.volumeURL, disk: att.disk))
        case .failed:
            if att.scan == nil {
                att.pendingFailure = (still, trigger, now)
                trace?("attempt #\(att.id): failed via \(trigger.rawValue); waiting for the scan")
            } else {
                emitFailed(att, still: still, trigger: trigger, decidedAt: now)
            }
        }
    }

    private func emitFailed(_ att: Attempt, still: [Watched], trigger: Trigger, decidedAt: UInt64) {
        guard let scan = att.scan else { return }
        stats.withLock { $0.failed += 1 }
        // Fresh snapshot for the coordinator's retry, if it is still the same disk.
        if let fresh = DiskTopology.physicalDisk(bsdName: att.physical), fresh.appearanceTime == att.disk.appearanceTime {
            att.disk = fresh
        }
        let url = still.first.map { URL(fileURLWithPath: $0.path, isDirectory: true) } ?? att.volumeURL
        let after = Core.millis(decidedAt - att.firstApprovalAt)
        let holders = scan.holders.map { "\($0.pid) \($0.displayName)\($0.isWriter ? " (writer)" : "")" }
        let kind: EjectAttemptKind = att.sawEject ? .eject : .unmount
        log?.record("watch", "attempt #\(att.id) on \(att.physical) FAILED (\(kind)): still mounted \(still.map(\.path).joined(separator: ", ")) "
                    + "(\(trigger.rawValue), \(after) ms after approval); \(scan.holders.count) holder(s) \(holders), "
                    + "\(scan.deniedPIDs.count) pids not inspectable")
        trace?("attempt #\(att.id): failed via \(trigger.rawValue), \(after) ms after approval")
        emit(.failed(volumeURL: url, disk: att.disk, scan: scan, kind: kind))
    }

    private func emit(_ event: EjectWatcherEvent) {
        let handler = onEvent
        DispatchQueue.main.async { [self] in
            guard !isStopped else { return }
            MainActor.assumeIsolated { handler(event) }
        }
    }

    private func updateTimer() {
        let active = attempts.values.contains { $0.needsOutcome }
        if active, timer == nil {
            let t = DispatchSource.makeTimerSource(queue: workQueue)
            let interval = DispatchTimeInterval.milliseconds(Int(options.pollInterval * 1000))
            t.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(20))
            t.setEventHandler { [weak self] in self?.evaluate(.poll) }
            t.resume()
            timer = t
        } else if !active, let t = timer {
            t.cancel()
            timer = nil
        }
    }

    // MARK: Helpers

    /// Physical whole disk (IOKit Whole=true walk) and whether it is internal (same rule as `PhysicalDisk.isInternal`).
    private func resolvePhysical(_ bsd: String) -> (String, Bool)? {
        if lookupSession == nil { lookupSession = DASessionCreate(kCFAllocatorDefault) }
        guard let session = lookupSession,
              let disk = DADiskCreateFromBSDName(kCFAllocatorDefault, session, bsd),
              let physical = DiskTopology.physicalBSDName(volumeDisk: disk),
              let physicalDisk = DADiskCreateFromBSDName(kCFAllocatorDefault, session, physical) else { return nil }
        let desc = DADiskCopyDescription(physicalDisk) as NSDictionary?
        let isInternal = DiskTopology.isInternal(
            location: DiskTopology.interconnectLocation(disk: physicalDisk),
            deviceInternal: desc?[kDADiskDescriptionDeviceInternalKey as String] as? Bool,
            isVirtual: desc?[kDADiskDescriptionDeviceProtocolKey as String] as? String == "Virtual Interface")
        return (physical, isInternal)
    }

    struct Mount { let path: String; let from: String; let browsable: Bool }

    /// Kernel mount table (getfsstat MNT_NOWAIT: never blocks on a network share).
    static func mounts() -> [Mount] {
        DiskTopology.mountTable().map { entry in
            var s = entry
            return Mount(path: LibProc.string(&s.f_mntonname), from: LibProc.string(&s.f_mntfromname),
                         browsable: s.f_flags & UInt32(MNT_DONTBROWSE) == 0)
        }
    }

    /// A volume the user sees in Finder: mounted directly under /Volumes and browsable (not a Time Machine snapshot,
    /// simulator runtime or other nobrowse mount).
    static func isUserVolume(_ path: String, browsable: Bool) -> Bool {
        guard browsable, path.hasPrefix("/Volumes/") else { return false }
        let name = path.dropFirst("/Volumes/".count)
        return !name.isEmpty && !name.contains("/")
    }

    static func nanos(_ t: TimeInterval) -> UInt64 { UInt64(max(0, t) * 1e9) }
    static func micros(_ ns: UInt64) -> String { String(format: "%.1f", Double(ns) / 1e3) }
    static func millis(_ ns: UInt64) -> Int { Int(Double(ns) / 1e6) }
}
