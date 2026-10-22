import AppKit
import Darwin

/// Why a process keeps a volume busy.
public enum HoldReason: Sendable, Hashable, CustomStringConvertible {
    /// An open file descriptor. `writing` = opened for writing (kernel `FWRITE` in `fi_openflags`).
    case openFile(path: String, writing: Bool)
    /// The process's current working directory is on the volume.
    case workingDirectory(path: String)
    /// The process is chrooted onto the volume.
    case rootDirectory(path: String)
    /// A memory-mapped file. `writable` = some mapping of it can write to the file (`VM_PROT_WRITE` and not
    /// copy-on-write, see `LibProc.mappingWritesFile`).
    /// Force-unmounting under a mapping crashes the holder with SIGBUS on its next page touch (RECON §3).
    case mappedFile(path: String, writable: Bool)

    public var path: String {
        switch self {
        case .openFile(let p, _), .workingDirectory(let p), .rootDirectory(let p), .mappedFile(let p, _): p
        }
    }

    /// True when this reason means data may be written to the volume.
    public var isWrite: Bool {
        switch self {
        case .openFile(_, let w): w
        case .mappedFile(_, let w): w
        case .workingDirectory, .rootDirectory: false
        }
    }

    public var description: String {
        switch self {
        case .openFile(let p, let w): "\(w ? "open(w)" : "open(r)") \(p)"
        case .workingDirectory(let p): "cwd \(p)"
        case .rootDirectory(let p): "root \(p)"
        case .mappedFile(let p, let w): "\(w ? "mmap(w)" : "mmap(r)") \(p)"
        }
    }
}

public enum HolderKind: String, Sendable, Hashable, CaseIterable {
    /// GUI app or agent (NSRunningApplication non-nil, activation policy regular/accessory).
    case app
    /// LaunchServices-registered process with policy `.prohibited`, e.g. `AirDrop.appex` ("AirDrop (Finder)").
    case appExtension
    /// No NSRunningApplication, executable lives inside an outer `.app` (e.g. Google Chrome Helper).
    case helper
    /// Same-user command-line process not inside a bundle (`tail`, `ffmpeg`, a shell).
    case cli
    /// Same-user background daemon / agent (a known daemon name, or a launchd child in a system location).
    case daemon
    /// Process owned by another uid (root, `_spotlight`, …). Only seen via the DA dissenter pid; never acted on.
    case inaccessible

    /// Kinds the app may offer to quit/stop (S3/S4). Daemons and other-uid processes never.
    public var isQuittable: Bool {
        switch self {
        case .app, .appExtension, .helper, .cli: true
        case .daemon, .inaccessible: false
        }
    }
}

/// A process that holds one or more volumes of a physical disk. Plain value; safe to pass across threads.
public struct Holder: Sendable, Identifiable, Hashable {
    public let pid: pid_t
    public let uid: uid_t
    public let ppid: pid_t
    /// `proc_pidpath` at scan time. Empty if the process vanished before it could be resolved.
    public let executablePath: String
    /// Process start time (Unix seconds), read when the process was inspected; nil if unavailable. Together with
    /// `executablePath` it identifies the process for S6. A holder without one can never be acted on.
    public let startTime: Double?
    public let displayName: String
    public let bundleIdentifier: String?
    /// The process's own bundle (.app/.appex/.xpc), if it is in one.
    public let bundleURL: URL?
    /// Outermost `.app` containing the executable, when different from `bundleURL`
    /// (helpers, app extensions, XPC services inside an app).
    public let parentAppBundleURL: URL?
    public let kind: HolderKind
    public let reasons: [HoldReason]
    /// Mount points (of the scanned set) this process holds.
    public let volumePaths: [String]

    public var id: pid_t { pid }
    public var isWriter: Bool { reasons.contains { $0.isWrite } }
    public var hasMappedFiles: Bool { reasons.contains { if case .mappedFile = $0 { true } else { false } } }
    public var isQuittable: Bool { kind.isQuittable }

    public init(pid: pid_t, uid: uid_t, ppid: pid_t, executablePath: String, startTime: Double?, displayName: String,
                bundleIdentifier: String?, bundleURL: URL?, parentAppBundleURL: URL?, kind: HolderKind,
                reasons: [HoldReason], volumePaths: [String]) {
        self.pid = pid; self.uid = uid; self.ppid = ppid
        self.executablePath = executablePath; self.startTime = startTime; self.displayName = displayName
        self.bundleIdentifier = bundleIdentifier; self.bundleURL = bundleURL; self.parentAppBundleURL = parentAppBundleURL
        self.kind = kind; self.reasons = reasons; self.volumePaths = volumePaths
    }

    /// S6: true only if `pid` still runs the same executable and started at the same time, so a recycled pid can
    /// never be mistaken for this holder. Fails closed: a missing start time (recorded or current) is "not the same".
    /// Call immediately before any signal/terminate.
    public func isSameProcess() -> Bool {
        guard !executablePath.isEmpty, let startTime, LibProc.executablePath(pid) == executablePath,
              let now = LibProc.startTime(pid), abs(now - startTime) <= 0.001 else { return false }
        return true
    }

    /// Re-resolves the NSRunningApplication for this pid, after verifying the pid was not recycled (S6).
    /// Nil for helpers/CLI/daemons and when the process is gone or changed.
    @MainActor public func runningApplication() -> NSRunningApplication? {
        guard isSameProcess(), let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated else { return nil }
        return app
    }

    /// For helpers / extensions: the running app whose bundle is `parentAppBundleURL` (the thing to quit). Nil unless
    /// this holder is still the same process (S6): a recycled pid must not lead to quitting some app.
    /// Several instances of that app (`open -n`): only the one that is this helper's parent process; none is → nil.
    @MainActor public func parentRunningApplication() -> NSRunningApplication? {
        guard isSameProcess(), let parent = parentAppBundleURL?.standardizedFileURL else { return nil }
        let candidates = NSWorkspace.shared.runningApplications.filter {
            $0.bundleURL?.standardizedFileURL == parent && !$0.isTerminated
        }
        guard let i = Holder.parentIndex(candidatePIDs: candidates.map(\.processIdentifier), ppid: ppid) else { return nil }
        return candidates[i]
    }

    /// Which of the running instances of the parent app to quit: the only one, or (several) the one whose pid is the
    /// holder's parent pid. Several and none is the parent → nil (never guess which instance to quit).
    public static func parentIndex(candidatePIDs: [pid_t], ppid: pid_t) -> Int? {
        if candidatePIDs.count == 1 { return 0 }
        return candidatePIDs.firstIndex(of: ppid)
    }
}

/// Result of one scan over all volumes of a physical disk.
public struct HolderScan: Sendable {
    /// The paths the caller asked for.
    public let volumePaths: [String]
    /// The mount points that were actually scanned: requested paths that are themselves mount points, not the root
    /// filesystem and not under /System/Volumes. Empty = nothing was scanned (unknown, not clear): the scanner then
    /// reports `incomplete` ("no mount point could be resolved") and the S2 gate blocks Force Eject on its own too.
    public let scannedTargets: [String]
    /// One entry per pid, merged across volumes, sorted by pid.
    public let holders: [Holder]
    /// Pids we could not inspect (EPERM: root / other-uid processes). They may hold the volume invisibly.
    public let deniedPIDs: [pid_t]
    public let duration: TimeInterval
    public let scannedAt: Date
    /// Some same-user processes were not inspected in full (deadline, a process stuck in the kernel, a truncated
    /// process list). Holders may be missing: Force Eject is unavailable on an incomplete scan (S2).
    public let incomplete: Bool
    /// Why `incomplete` (for logs and the UI).
    public let incompleteReason: String?

    /// Nothing holds the scanned volumes: at least one target was scanned, completely, and no holder was found.
    public var isClear: Bool { holders.isEmpty && !scannedTargets.isEmpty && !incomplete }
    public var writers: [Holder] { holders.filter(\.isWriter) }

    public init(volumePaths: [String], holders: [Holder], deniedPIDs: [pid_t], duration: TimeInterval, scannedAt: Date,
                scannedTargets: [String]? = nil, incomplete: Bool = false, incompleteReason: String? = nil) {
        self.volumePaths = volumePaths; self.holders = holders; self.deniedPIDs = deniedPIDs
        self.duration = duration; self.scannedAt = scannedAt
        self.scannedTargets = scannedTargets ?? volumePaths
        self.incomplete = incomplete; self.incompleteReason = incomplete ? (incompleteReason ?? "incomplete") : nil
    }
}
