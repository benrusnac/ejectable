import AppKit
import Darwin
import os

/// How long a graceful quit (`terminate()`) or a SIGTERM gets before the row's primary button becomes its force action
/// (S3). Per kind, because what is at stake differs: an app may be showing its own "Save changes?" prompt; an XPC helper's
/// quit goes to its parent app, which may too; an app extension (AirDrop.appex, measured 2026-10-22) or a CLI tool rarely holds a
/// document and either answers at once or never. During the grace the row's force button is still one hover / Tab away
/// (one process per click, labelled); nothing is ever forced automatically.
public struct QuitGrace: Sendable, Hashable, CustomStringConvertible {
    public var app: TimeInterval
    public var helper: TimeInterval
    public var appExtension: TimeInterval
    /// SIGTERM to a CLI tool (and the Quick Look daemons, S4 exception) before Kill becomes the primary button.
    public var cli: TimeInterval

    public init(app: TimeInterval = 60, helper: TimeInterval = 15, appExtension: TimeInterval = 3, cli: TimeInterval = 5) {
        self.app = app; self.helper = helper; self.appExtension = appExtension; self.cli = cli
    }

    /// `.app` 60 s, `.helper` 15 s, `.appExtension` 3 s, `.cli` 5 s.
    public static let standard = QuitGrace()

    /// The grace for a holder of this kind. Daemons are only ever stopped by signal (the Quick Look exception): `cli`.
    public func seconds(for kind: HolderKind) -> TimeInterval {
        switch kind {
        case .app: app
        case .helper: helper
        case .appExtension: appExtension
        case .cli, .daemon, .inaccessible: cli
        }
    }

    public var description: String {
        "app \(Self.format(app)) s, helper \(Self.format(helper)) s, appExtension \(Self.format(appExtension)) s, cli \(Self.format(cli)) s"
    }

    static func format(_ t: TimeInterval) -> String { t == t.rounded() ? String(Int(t)) : String(format: "%.1f", t) }
}

/// Outcome of a graceful or forced quit.
public enum QuitOutcome: Sendable, Hashable, CustomStringConvertible {
    /// The holder process is gone.
    case quit
    /// Still running after the timeout (the app refused or is showing a save dialog). The UI may now offer Force Quit.
    case stillRunning
    /// The pid now belongs to a different process (S6). Nothing was sent.
    case pidMismatch
    /// The process is already gone. Nothing was sent.
    case notFound
    /// No NSRunningApplication to quit (helper whose app is not running). Nothing was sent.
    case noApplication
    /// This kind is never quit (daemons, other-uid processes). Nothing was sent.
    case refused(HolderKind)
    /// The wait was cancelled (the quit request itself was already sent).
    case cancelled

    public var description: String {
        switch self {
        case .quit: "quit"
        case .stillRunning: "still running"
        case .pidMismatch: "pid mismatch"
        case .notFound: "not found"
        case .noApplication: "no application"
        case .refused(let k): "refused (\(k.rawValue))"
        case .cancelled: "cancelled"
        }
    }
}

/// Outcome of SIGTERM / SIGKILL to a CLI holder.
public enum SignalOutcome: Sendable, Hashable, CustomStringConvertible {
    case sent
    case pidMismatch
    case notFound
    /// Only `.cli` holders are ever signalled (S3/S4). Nothing was sent.
    case refused(HolderKind)
    /// SIGKILL is only sent after a SIGTERM to the same process (second click, S3). Nothing was sent.
    case notStoppedFirst
    case failed(errno: Int32)

    public var description: String {
        switch self {
        case .sent: "sent"
        case .pidMismatch: "pid mismatch"
        case .notFound: "not found"
        case .refused(let k): "refused (\(k.rawValue))"
        case .notStoppedFirst: "refused (SIGKILL needs a prior SIGTERM)"
        case .failed(let e): "failed (\(String(cString: strerror(e))))"
        }
    }
}

/// Quits and stops holders, enforcing S3 (graceful first, force per click), S4 (never daemons / other users) and
/// S6 (re-verify the pid immediately before acting). Every action and refusal is logged (S9).
///
/// - GUI kinds (`.app`, `.appExtension`, `.helper`) are only ever ended through NSRunningApplication:
///   `terminate()` (lets the app ask to save) or, on an explicit click, `forceTerminate()`. Never a signal.
/// - `.cli` holders get SIGTERM (`stop`), and SIGKILL (`kill`) only after a SIGTERM to the same process.
/// - `.daemon` and `.inaccessible` are refused by every method, with ONE exception (S4): a same-user `.daemon` whose
///   executable is exactly one of `quickLookExecutables` AND lives under /System/ (Quick Look: read-only previews,
///   launchd respawns it) may get `stop` / `kill` like a CLI holder. The path is the verified `proc_pidpath` (S6), and
///   each use is logged.
/// - Never, whatever the kind: the login session's own processes (`Remedies.sessionProcessBundleIDs`: loginwindow,
///   Dock, SystemUIServer, Control Center, WindowManager, Notification Center, Spotlight, UserNotificationCenter),
///   Ejectable itself (bundle id or pid). Finder only through `terminate()` (it relaunches), never `forceTerminate()`.
@MainActor
public final class Terminator {
    /// The `.app` grace (`QuitGrace.standard.app`). Other kinds: `QuitGrace`.
    public nonisolated static let defaultQuitTimeout: TimeInterval = QuitGrace.standard.app
    public nonisolated static let pollInterval: TimeInterval = 0.25
    /// Kinds that may be quit through NSRunningApplication.
    public nonisolated static let quittableKinds: Set<HolderKind> = [.app, .appExtension, .helper]
    /// Kinds that may receive signals.
    public nonisolated static let signalableKinds: Set<HolderKind> = [.cli]
    /// S4 exception: the only daemons that may ever be signalled. Exact executable basenames.
    public nonisolated static let quickLookExecutables: Set<String> = Remedies.quickLookExecutables

    /// True for a same-user `.daemon` whose executable is one of `quickLookExecutables` and lives under /System/ (S4
    /// exception): a same-user daemon that merely carries a Quick Look name (say /Library/…/QuickLookSatellite) is not
    /// Quick Look. `executablePath` is re-checked against `proc_pidpath` before any signal (S6).
    public nonisolated static func isQuickLookException(_ h: Holder) -> Bool {
        guard h.kind == .daemon, h.uid == getuid(),
              quickLookExecutables.contains((h.executablePath as NSString).lastPathComponent) else { return false }
        // Real Quick Look lives under /System/ (SIP-protected); the name alone is not enough.
        guard h.executablePath.hasPrefix("/System/") || debugAllowsQuickLookPath(h.executablePath) else { return false }
        return true
    }

    #if DEBUG
    /// Tests only (debug builds): executables outside /System/ that count as Quick Look (the fixture copies of duhold).
    /// Compiled out of release builds.
    public nonisolated static let debugAllowedQuickLookPaths = OSAllocatedUnfairLock(initialState: Set<String>())
    #endif

    private nonisolated static func debugAllowsQuickLookPath(_ path: String) -> Bool {
        #if DEBUG
        debugAllowedQuickLookPaths.withLock { $0.contains(path) }
        #else
        false
        #endif
    }

    /// Why this process must never be quit / signalled, or nil. Login-session processes (by bundle id), and Ejectable
    /// itself (bundle id or pid). Checked on the holder and again on the app `quit` / `forceQuit` would act on.
    public nonisolated static func neverQuitReason(bundleIdentifier: String?, pid: pid_t) -> String? {
        if pid == getpid() { return "Ejectable itself" }
        guard let id = bundleIdentifier else { return nil }
        if id == Remedies.ownBundleID || id == Bundle.main.bundleIdentifier { return "Ejectable itself" }
        if Remedies.sessionProcessBundleIDs.contains(where: { $0.caseInsensitiveCompare(id) == .orderedSame }) {
            return "part of the login session (\(id))"
        }
        return nil
    }

    /// Apps that may be quit gracefully but never force-quit (Finder: relaunches by itself after `terminate()`).
    public nonisolated static let gracefulOnlyBundleIDs: Set<String> = ["com.apple.finder"]

    public nonisolated static func isGracefulOnly(_ bundleIdentifier: String) -> Bool {
        gracefulOnlyBundleIDs.contains { $0.caseInsensitiveCompare(bundleIdentifier) == .orderedSame }
    }

    /// True if `stop` / `kill` may act on this holder (kind gate only; S6 is checked at the time of the signal).
    public nonisolated static func isSignalable(_ h: Holder) -> Bool {
        (signalableKinds.contains(h.kind) && h.uid == getuid()) || isQuickLookException(h)
    }

    private let log: ActionLog?
    /// Processes (pid + start time) that received SIGTERM from us: SIGKILL is only allowed for these.
    private var stopped: Set<ProcessKey> = []

    struct ProcessKey: Hashable { let pid: pid_t; let start: Double? }

    public init(log: ActionLog? = .shared) { self.log = log }

    /// The NSRunningApplication `quit`/`forceQuit` act on: the holder's own app, or the parent app for helpers.
    public static func targetApplication(for h: Holder) -> NSRunningApplication? {
        switch h.kind {
        case .app, .appExtension: h.runningApplication()
        case .helper: h.isSameProcess() ? h.parentRunningApplication() : nil
        case .cli, .daemon, .inaccessible: nil
        }
    }

    // MARK: Graceful quit (S3)

    /// `terminate()` the holder's app (the parent app for helpers), then poll every 250 ms until the holder process
    /// is gone or `timeout` passes (nil = the kind's grace, `QuitGrace.standard`; logged). The app may show its own
    /// "Save changes?" dialog meanwhile. Cancel the calling Task to stop waiting. `onProgress` gets the elapsed seconds
    /// after each poll.
    public func quit(_ h: Holder, timeout: TimeInterval? = nil,
                     onProgress: (@MainActor (TimeInterval) -> Void)? = nil) async -> QuitOutcome {
        let timeout = timeout ?? QuitGrace.standard.seconds(for: h.kind)
        guard Self.quittableKinds.contains(h.kind) else { return refuse(h, "quit") }
        if let why = Self.neverQuitReason(bundleIdentifier: h.bundleIdentifier, pid: h.pid) { return refuseNever(h, "quit", why) }
        if let early = verify(h) { return finish(h, "quit", early) }
        guard let app = Self.targetApplication(for: h) else { return finish(h, "quit", .noApplication) }
        if let why = Self.neverQuitReason(bundleIdentifier: app.bundleIdentifier, pid: app.processIdentifier) {
            return refuseNever(h, "quit", "its app \(app.localizedName ?? "?") is \(why)")
        }
        log?.quit(h, force: false)
        log?.record("quit", "\(h.pid) \(h.displayName) [\(h.kind.rawValue)]: grace \(QuitGrace.format(timeout)) s before the row offers its force action")
        if app.processIdentifier != h.pid {
            log?.record("quit", "\(h.pid) \(h.displayName) is a helper: terminate() sent to app \(app.processIdentifier) \(app.localizedName ?? "?")")
        }
        _ = app.terminate()             // returns true even when the app refuses (RECON §5): watch the process
        let started = Date()
        while true {
            if !h.isSameProcess() { return finish(h, "quit", .quit, after: started) }
            if Task.isCancelled { return finish(h, "quit", .cancelled, after: started) }
            let elapsed = Date().timeIntervalSince(started)
            if elapsed >= timeout { return finish(h, "quit", .stillRunning, after: started) }
            try? await Task.sleep(nanoseconds: UInt64(Self.pollInterval * 1e9))
            onProgress?(Date().timeIntervalSince(started))
        }
    }

    /// `forceTerminate()` (unsaved changes are lost). Only ever called from a user click on a "Force Quit" button.
    /// Waits up to `wait` seconds for the process to disappear.
    public func forceQuit(_ h: Holder, wait: TimeInterval = 3) async -> QuitOutcome {
        guard Self.quittableKinds.contains(h.kind) else { return refuse(h, "force-quit") }
        if let why = Self.neverQuitReason(bundleIdentifier: h.bundleIdentifier, pid: h.pid) { return refuseNever(h, "force-quit", why) }
        if let id = h.bundleIdentifier, Self.isGracefulOnly(id) {
            return refuseNever(h, "force-quit", "\(id) is only ever quit normally")
        }
        if let early = verify(h) { return finish(h, "force-quit", early) }
        guard let app = Self.targetApplication(for: h) else { return finish(h, "force-quit", .noApplication) }
        if let why = Self.neverQuitReason(bundleIdentifier: app.bundleIdentifier, pid: app.processIdentifier) {
            return refuseNever(h, "force-quit", "its app \(app.localizedName ?? "?") is \(why)")
        }
        if let id = app.bundleIdentifier, Self.isGracefulOnly(id) {
            return refuseNever(h, "force-quit", "its app \(id) is only ever quit normally")
        }
        log?.quit(h, force: true)
        _ = app.forceTerminate()
        let started = Date()
        while Date().timeIntervalSince(started) < wait {
            if !h.isSameProcess() { return finish(h, "force-quit", .quit, after: started) }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return finish(h, "force-quit", h.isSameProcess() ? .stillRunning : .quit, after: started)
    }

    // MARK: Signals for CLI holders (S3)

    /// SIGTERM to a same-user CLI holder. Refuses every other kind.
    public func stop(_ h: Holder) -> SignalOutcome {
        signal(h, SIGTERM)
    }

    /// SIGKILL to a same-user CLI holder that already received SIGTERM from `stop` (second click). Refuses
    /// every other kind, and CLI processes that were not stopped first.
    public func kill(_ h: Holder) -> SignalOutcome {
        signal(h, SIGKILL)
    }

    private func signal(_ h: Holder, _ sig: Int32) -> SignalOutcome {
        let what = sig == SIGKILL ? "SIGKILL" : "SIGTERM"
        guard Self.isSignalable(h) else {
            log?.record("refused", "\(what) -> \(h.pid) \(h.displayName) [\(h.kind.rawValue), uid \(h.uid)]: only same-user CLI holders (and Quick Look) are signalled")
            return .refused(h.kind)
        }
        if let why = Self.neverQuitReason(bundleIdentifier: h.bundleIdentifier, pid: h.pid) {
            log?.record("refused", "\(what) -> \(h.pid) \(h.displayName): never signalled (\(why))")
            return .refused(h.kind)
        }
        if let early = verify(h) {
            let r: SignalOutcome = early == .notFound ? .notFound : .pidMismatch
            log?.record("signal", "\(what) -> \(h.pid) \(h.displayName) not sent: \(r)")
            return r
        }
        let key = ProcessKey(pid: h.pid, start: h.startTime)
        if sig == SIGKILL, !stopped.contains(key) {
            log?.record("refused", "SIGKILL -> \(h.pid) \(h.displayName): no prior SIGTERM")
            return .notStoppedFirst
        }
        if Self.isQuickLookException(h) {
            log?.record("s4-exception", "\(what) -> \(h.pid) \(h.displayName) [daemon \((h.executablePath as NSString).lastPathComponent)]: Quick Look is read-only and respawns; allowed")
        }
        log?.signal(h, signal: sig)
        guard Darwin.kill(h.pid, sig) == 0 else {
            let e = errno
            log?.record("signal", "\(what) -> \(h.pid) failed: \(String(cString: strerror(e)))")
            return .failed(errno: e)
        }
        if sig == SIGTERM { stopped.insert(key) }
        return .sent
    }

    // MARK: Helpers

    /// S6. Nil = same process, go ahead.
    private func verify(_ h: Holder) -> QuitOutcome? {
        if h.isSameProcess() { return nil }
        return LibProc.executablePath(h.pid) == nil ? .notFound : .pidMismatch
    }

    private func refuseNever(_ h: Holder, _ verb: String, _ why: String) -> QuitOutcome {
        log?.record("refused", "\(verb) -> \(h.pid) \(h.displayName) [\(h.kind.rawValue)]: never \(verb == "quit" ? "quit" : "force-quit") (\(why))")
        return .refused(h.kind)
    }

    private func refuse(_ h: Holder, _ verb: String) -> QuitOutcome {
        log?.record("refused", "\(verb) -> \(h.pid) \(h.displayName) [\(h.kind.rawValue)]: kind is never quit")
        return .refused(h.kind)
    }

    private func finish(_ h: Holder, _ verb: String, _ r: QuitOutcome, after started: Date? = nil) -> QuitOutcome {
        let t = started.map { String(format: " after %.1f s", Date().timeIntervalSince($0)) } ?? ""
        log?.record(verb == "quit" ? "quit" : "force-quit", "result \(h.pid) \(h.displayName): \(r)\(t)")
        return r
    }
}
