import Foundation
import os

/// S9: every scan, quit, signal, eject and force-eject goes to os_log (subsystem com.benrusnac.ejectable) and is
/// appended to ~/Library/Logs/Ejectable/actions.log with a timestamp, pids and paths.
///
/// Privacy: the os_log message (file paths, volume and process names) is `.private` (redacted in a sysdiagnose);
/// only the category is public. The file is created 0600 and rotated at ~1 MB, keeping one `actions.log.1`.
public final class ActionLog: @unchecked Sendable {   // mutable state guarded by `lock`
    public static let shared = ActionLog()
    public static let subsystem = "com.benrusnac.ejectable"
    /// The file is rotated when an append would grow it past this.
    public static let rotateBytes: off_t = 1_000_000

    private let logger = Logger(subsystem: ActionLog.subsystem, category: "actions")
    private let lock = NSLock()
    private var directory: URL
    private var lastScanSignature: String?
    private let maxBytes: off_t

    public init(directory: URL? = nil, rotateAt maxBytes: off_t = ActionLog.rotateBytes) {
        self.directory = directory ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Ejectable", isDirectory: true)
        self.maxBytes = maxBytes
    }

    public var fileURL: URL { lock.withLock { directory.appendingPathComponent("actions.log") } }

    /// Redirect the file log (tests write under .build/).
    public func setDirectory(_ url: URL) { lock.withLock { directory = url; lastScanSignature = nil } }

    /// Append one line: `2026-10-21T15:04:05.123Z [category] message`.
    public func record(_ category: String, _ message: String) {
        logger.log("[\(category, privacy: .public)] \(message, privacy: .private)")
        let stamp = Date.ISO8601FormatStyle(includingFractionalSeconds: true, timeZone: .current).format(Date())
        let line = "\(stamp) [\(category)] \(message)\n"
        lock.withLock {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                     attributes: [.posixPermissions: 0o700])
            let path = directory.appendingPathComponent("actions.log").path
            var fd = open(path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
            guard fd >= 0 else { return }
            var st = stat()
            if fstat(fd, &st) == 0 {
                if st.st_mode & 0o077 != 0 { fchmod(fd, 0o600) }       // files created by older builds were 0644
                if st.st_size > 0, st.st_size + off_t(line.utf8.count) > maxBytes {
                    close(fd)
                    rename(path, path + ".1")                          // keeps exactly one previous file
                    fd = open(path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
                    guard fd >= 0 else { return }
                }
            }
            defer { close(fd) }
            _ = line.utf8CString.withUnsafeBufferPointer { write(fd, $0.baseAddress, $0.count - 1) }
        }
    }

    // MARK: - Typed events

    /// Scans repeat every second while an alert is open; an identical consecutive result is logged to
    /// os_log only (debug), so the file shows each change rather than every poll.
    public func scan(_ s: HolderScan) {
        let holders = s.holders.map { h in
            "\(h.pid) \(h.displayName) [\(h.kind.rawValue)\(h.isWriter ? ",writer" : "")] " + h.reasons.map(\.description).joined(separator: ", ")
        }
        let scanned = s.scannedTargets == s.volumePaths ? ""
            : " [scanned: \(s.scannedTargets.isEmpty ? "none, not a mount point" : s.scannedTargets.joined(separator: ","))]"
        let incomplete = s.incomplete ? " INCOMPLETE (\(s.incompleteReason ?? "?"))" : ""
        let signature = "\(s.volumePaths)\(scanned)\(incomplete) " + holders.joined(separator: "; ")
        let changed: Bool = lock.withLock {
            defer { lastScanSignature = signature }
            return lastScanSignature != signature
        }
        let msg = "\(s.volumePaths.joined(separator: ",")):\(scanned) \(s.holders.count) holder(s), \(s.deniedPIDs.count) denied, "
            + String(format: "%.0f ms", s.duration * 1000) + incomplete + (holders.isEmpty ? "" : " | " + holders.joined(separator: " | "))
        if changed { record("scan", msg) } else { logger.debug("[scan] unchanged: \(msg, privacy: .private)") }
    }

    /// `dryRun`: the attempt only ran the guards (tests); no DiskArbitration request is sent.
    public func ejectAttempt(_ disk: PhysicalDisk, force: Bool, dryRun: Bool = false) {
        record(force ? "force-eject" : "eject",
               "\(dryRun ? "[dry-run] " : "")attempt \(disk.bsdName) (\(disk.deviceModel ?? "?"), \(disk.isVirtual ? "virtual" : "real")) "
               + "containers=\(disk.containerBSDNames) volumes=\(disk.volumePaths)")
    }

    public func ejectResult(_ r: EjectResult, disk: String, force: Bool, milliseconds: Double, dryRun: Bool = false) {
        record(force ? "force-eject" : "eject", "\(dryRun ? "[dry-run] " : "")result \(disk): \(r) after \(Int(milliseconds)) ms")
    }

    /// Phase 2: graceful quit (`terminate()`) or force quit of a holder.
    public func quit(_ h: Holder, force: Bool) {
        record(force ? "force-quit" : "quit", "\(h.pid) \(h.displayName) \(h.executablePath) holds \(h.reasons.map(\.description))")
    }

    /// Phase 2: SIGTERM / SIGKILL sent to a same-user CLI holder.
    public func signal(_ h: Holder, signal: Int32) {
        record("signal", "\(signal == SIGKILL ? "SIGKILL" : signal == SIGTERM ? "SIGTERM" : "signal \(signal)") -> \(h.pid) \(h.executablePath) holds \(h.reasons.map(\.description))")
    }

    /// Phase 2: the user confirmed Force Eject in the confirmation sheet (before the DA call).
    public func forceEjectConfirmed(disk: PhysicalDisk, holders: [Holder]) {
        record("force-eject", "confirmed \(disk.bsdName) volumes=\(disk.volumePaths) holders=\(holders.map { "\($0.pid) \($0.displayName)\($0.isWriter ? " (writer)" : "")" })")
    }
}
