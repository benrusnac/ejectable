import DiskArbitration
import Foundation
import os

/// What the caller allows. Internal disks are never allowed (there is no way to construct a policy that does).
public struct EjectPolicy: Sendable, Hashable {
    /// Always false. Internal disks, the root filesystem and /System/Volumes are refused unconditionally (S5).
    public var allowInternal: Bool { false }
    /// False: only disk images may be ejected (development, CLI and tests). True: real external disks too (the app).
    public let allowRealDisks: Bool

    public init(allowRealDisks: Bool) { self.allowRealDisks = allowRealDisks }

    /// Development / test policy: disk images only.
    public static let diskImagesOnly = EjectPolicy(allowRealDisks: false)
    /// App policy: any external disk.
    public static let externalDisks = EjectPolicy(allowRealDisks: true)
}

public enum EjectStep: Sendable, Hashable, CustomStringConvertible {
    case unmount(bsdName: String)
    case eject(bsdName: String)
    case networkUnmount(path: String)

    public var description: String {
        switch self {
        case .unmount(let b): "unmount \(b)"
        case .eject(let b): "eject \(b)"
        case .networkUnmount(let p): "unmount \(p)"
        }
    }
}

/// Why the S5 wrong-disk guard refused. Always decided before any DiskArbitration request is sent.
public enum SafetyRefusal: Error, Sendable, Hashable, CustomStringConvertible {
    case internalDisk(bsdName: String)
    case rootFileSystem(path: String)
    case internalVolume(path: String)
    case systemVolume(path: String)
    /// Mounted outside /Volumes (simulator runtimes, cryptexes, custom system mounts).
    case notUnderVolumes(path: String)
    /// Not a disk image and the policy does not allow real disks.
    case notADiskImage(bsdName: String, model: String?)
    case notAWholeDisk(bsdName: String)
    case diskNotFound(bsdName: String)
    /// The BSD name now refers to a different disk than the caller's snapshot (re-attached / renumbered).
    case diskChanged(bsdName: String)
    case notANetworkShare(path: String)
    /// AppleRAID / SoftRAID set, Fusion drive or multi-store APFS container: more than one physical member disk.
    /// Not supported yet; ejecting one member would leave the set half-attached.
    case multiMemberDisk(bsdName: String, members: [String])
    /// A single-volume unmount was asked for a volume that is not one of the snapshot disk's volumes.
    case volumeNotOnDisk(path: String, bsdName: String)

    public var description: String {
        switch self {
        case .internalDisk(let b): "\(b) is an internal disk"
        case .rootFileSystem(let p): "\(p) is the root filesystem"
        case .internalVolume(let p): "\(p) is an internal volume"
        case .systemVolume(let p): "\(p) is a system volume"
        case .notUnderVolumes(let p): "\(p) is not mounted under /Volumes"
        case .notADiskImage(let b, let m): "\(b) (\(m ?? "unknown model")) is a real disk, not a disk image; pass --real / allowRealDisks"
        case .notAWholeDisk(let b): "\(b) is not a physical whole disk"
        case .diskNotFound(let b): "\(b) not found"
        case .diskChanged(let b): "\(b) is no longer the same disk"
        case .notANetworkShare(let p): "\(p) is not a network share"
        case .multiMemberDisk(let b, let m): "\(b) is part of a RAID set or multi-disk volume (\(m.joined(separator: ", "))); not supported yet"
        case .volumeNotOnDisk(let p, let b): "\(p) is not a volume of \(b)"
        }
    }
}

public enum EjectResult: Sendable, CustomStringConvertible {
    case ejected
    /// Single-volume mode (`Ejector.unmountVolume`): that one volume is unmounted (or already was). The disk and its
    /// other volumes are untouched, so this alone does not make the disk safe to disconnect.
    case volumeUnmounted
    /// Every volume unmounted (so everything is flushed and the disk is safe to disconnect), but `DADiskEject` on
    /// the physical disk dissented, e.g. a USB SSD reporting Ejectable=0 or a process holding the raw device.
    case unmountedNotEjected(status: DAReturn)
    /// A process holds the disk. `dissenterPID` is DA's single named holder: nil when DA gave 0
    /// (root holder, or mmap-only holder on APFS/exFAT). Busy = `status & 0x3fff == EBUSY`.
    case busy(dissenterPID: pid_t?, status: DAReturn, step: EjectStep)
    case refused(SafetyRefusal)
    case failed(status: DAReturn, step: EjectStep)

    public var description: String {
        switch self {
        case .ejected: "ejected"
        case .volumeUnmounted: "volume unmounted"
        case .unmountedNotEjected(let s): "unmounted, not ejected (eject status 0x\(String(UInt32(bitPattern: s), radix: 16)))"
        case .busy(let pid, let s, let step): "busy at \(step) (dissenter pid \(pid.map(String.init) ?? "unknown"), status 0x\(String(UInt32(bitPattern: s), radix: 16)))"
        case .refused(let r): "refused: \(r)"
        case .failed(let s, let step): "failed at \(step) (status 0x\(String(UInt32(bitPattern: s), radix: 16)))"
        }
    }

    public var isEjected: Bool { if case .ejected = self { true } else { false } }
    /// Ejected, or at least every volume unmounted: nothing left to flush, safe to disconnect.
    public var isSafeToDisconnect: Bool {
        switch self {
        case .ejected, .unmountedNotEjected: true
        default: false
        }
    }
}

/// Ejects a physical disk the way Finder does (RECON §3): unmount every container/whole with
/// `kDADiskUnmountOptionWhole`, then `DADiskEject` the physical disk. DiskArbitration runs on a private
/// serial queue; completions are called on that queue.
public final class Ejector: @unchecked Sendable {   // DASession is only touched on `queue`
    private let queue = DispatchQueue(label: "com.benrusnac.ejectable.ejector")
    private let session: DASession
    private let log: ActionLog?
    private let requests = OSAllocatedUnfairLock(initialState: 0)
    private let dryRun: Bool

    /// Number of mutating DiskArbitration requests (unmount/eject) this instance has sent (or, in dry-run
    /// mode, would have sent). Lets tests prove that a refusal happened before any DA call.
    public var diskArbitrationRequestCount: Int { requests.withLock { $0 } }

    /// `dryRun`: run every guard and re-resolution but never send an unmount/eject; a request that would
    /// have been sent completes as `.failed(status: 0, step:)`. Tests use it whenever the target is a real
    /// disk, so a regression in the guard can never act on the boot disk or a user's drive.
    public init(log: ActionLog? = .shared, dryRun: Bool = false) {
        guard let s = DASessionCreate(kCFAllocatorDefault) else { fatalError("DASessionCreate failed") }
        session = s
        self.log = log
        self.dryRun = dryRun
        DASessionSetDispatchQueue(session, queue)
    }

    deinit { DASessionSetDispatchQueue(session, nil) }

    /// S5 wrong-disk guard on a snapshot. Pure; no DA calls.
    public static func safetyCheck(_ disk: PhysicalDisk, policy: EjectPolicy) -> SafetyRefusal? {
        guard disk.bsdName.range(of: #"^disk[0-9]+$"#, options: .regularExpression) != nil else {
            return .notAWholeDisk(bsdName: disk.bsdName)
        }
        if disk.isInternal { return .internalDisk(bsdName: disk.bsdName) }
        if disk.isMultiMember || disk.wholeAncestors != [disk.bsdName] {
            return .multiMemberDisk(bsdName: disk.bsdName, members: disk.wholeAncestors)
        }
        for v in disk.volumes {
            if v.isRootFileSystem || v.path == "/" { return .rootFileSystem(path: v.path) }
            if v.isInternal == true { return .internalVolume(path: v.path) }
            if v.isSystemVolume { return .systemVolume(path: v.path) }
            if !v.path.hasPrefix("/Volumes/") { return .notUnderVolumes(path: v.path) }
        }
        if !policy.allowRealDisks && !disk.isVirtual {
            return .notADiskImage(bsdName: disk.bsdName, model: disk.deviceModel)
        }
        return nil
    }

    /// Soft (or forced) eject of a whole physical disk and every volume on it.
    /// The snapshot is re-resolved from DiskArbitration and both snapshot and fresh state must pass S5. A forced
    /// eject is also refused when the disk's volumes changed since the snapshot the user confirmed (S2/S8), and is
    /// preceded by `sync_volume_np(FULLSYNC|WAIT)` on every volume. Before each DiskArbitration request the target's
    /// `DAAppearanceTime` is compared again, so a BSD name re-used during a slow sequence is never acted on.
    /// Never call with force=true without explicit user confirmation (S1/S2).
    public func eject(disk: PhysicalDisk, force: Bool, policy: EjectPolicy,
                      completion: @escaping @Sendable (EjectResult) -> Void) {
        let started = DispatchTime.now().uptimeNanoseconds
        let finish: @Sendable (EjectResult) -> Void = { [log, dryRun] r in
            let ms = Double(DispatchTime.now().uptimeNanoseconds - started) / 1e6
            log?.ejectResult(r, disk: disk.bsdName, force: force, milliseconds: ms, dryRun: dryRun)
            completion(r)
        }
        queue.async { [self] in
            if let r = Ejector.safetyCheck(disk, policy: policy) { return finish(.refused(r)) }
            guard let fresh = DiskTopology.physicalDisk(bsdName: disk.bsdName) else {
                return finish(.refused(.diskNotFound(bsdName: disk.bsdName)))
            }
            guard fresh.appearanceTime == disk.appearanceTime, fresh.deviceModel == disk.deviceModel,
                  fresh.mediaSize == disk.mediaSize, fresh.isVirtual == disk.isVirtual else {
                return finish(.refused(.diskChanged(bsdName: disk.bsdName)))
            }
            if let r = Ejector.safetyCheck(fresh, policy: policy) { return finish(.refused(r)) }
            if force, Set(fresh.volumePaths) != Set(disk.volumePaths) {
                log?.record("force-eject", "\(dryRun ? "[dry-run] " : "")refused \(disk.bsdName): volumes changed since confirmation "
                            + "(confirmed \(disk.volumePaths), now \(fresh.volumePaths))")
                return finish(.refused(.diskChanged(bsdName: disk.bsdName)))
            }
            log?.ejectAttempt(fresh, force: force, dryRun: dryRun)
            // Identities of everything a request will be sent to, re-checked right before each request.
            var expected: [String: Double?] = [fresh.bsdName: fresh.appearanceTime]
            for c in fresh.containerBSDNames where c != fresh.bsdName {
                expected[c] = DiskTopology.appearanceTime(bsdName: c, session: session)
            }
            if force {                                                  // flush before a forced unmount (S2)
                if dryRun { log?.record("force-eject", "[dry-run] would sync_volume_np \(fresh.volumePaths)") }
                else { Ejector.flush(fresh.volumePaths, log: log) }
            }
            let span = EjectsInFlight.shared.begin(physicalBSD: fresh.bsdName)   // before the first DA request
            runSteps(physical: fresh.bsdName, containers: fresh.containerBSDNames, expected: expected, force: force) { r in
                EjectsInFlight.shared.end(span)
                finish(r)
            }
        }
    }

    // MARK: - One volume (Finder-companion after someone else's unmount of a single volume failed)

    /// Soft unmount of ONE volume of `disk` (`DADiskUnmount` on that volume's own DADisk, without
    /// `kDADiskUnmountOptionWhole`): the disk and its other volumes stay mounted. Never forced. Same S5 guard as `eject`
    /// on the snapshot and on the freshly re-resolved disk; the volume must still be that disk's volume (same BSD name,
    /// same mount point), and the disk's and the volume's `DAAppearanceTime` are compared again right before the request.
    /// A volume that is no longer mounted completes as `.volumeUnmounted` without a request.
    public func unmountVolume(_ volume: VolumeInfo, of disk: PhysicalDisk, policy: EjectPolicy,
                              completion: @escaping @Sendable (EjectResult) -> Void) {
        unmountOneVolume(volume, of: disk, force: false, policy: policy, completion: completion)
    }

    /// Forced unmount of ONE volume (`kDADiskUnmountOptionForce`, still without Whole), flushed first
    /// (`sync_volume_np` FULLSYNC|WAIT). Only ever from a confirmed Force Unmount (S1/S2): `EjectFlow.confirmForceEject`.
    public func forceUnmountVolume(_ volume: VolumeInfo, of disk: PhysicalDisk, policy: EjectPolicy,
                                   completion: @escaping @Sendable (EjectResult) -> Void) {
        unmountOneVolume(volume, of: disk, force: true, policy: policy, completion: completion)
    }

    private func unmountOneVolume(_ volume: VolumeInfo, of disk: PhysicalDisk, force: Bool, policy: EjectPolicy,
                                  completion: @escaping @Sendable (EjectResult) -> Void) {
        let started = DispatchTime.now().uptimeNanoseconds
        let what = "\(volume.bsdName ?? "?") \(volume.path) on \(disk.bsdName)"
        let finish: @Sendable (EjectResult) -> Void = { [log, dryRun] r in
            let ms = Double(DispatchTime.now().uptimeNanoseconds - started) / 1e6
            log?.ejectResult(r, disk: what, force: force, milliseconds: ms, dryRun: dryRun)
            completion(r)
        }
        queue.async { [self] in
            if let r = Ejector.safetyCheck(disk, policy: policy) { return finish(.refused(r)) }
            guard let bsd = volume.bsdName, disk.volumes.contains(where: { $0.path == volume.path && $0.bsdName == bsd }) else {
                return finish(.refused(.volumeNotOnDisk(path: volume.path, bsdName: disk.bsdName)))
            }
            guard let fresh = DiskTopology.physicalDisk(bsdName: disk.bsdName) else {
                return finish(.refused(.diskNotFound(bsdName: disk.bsdName)))
            }
            guard fresh.appearanceTime == disk.appearanceTime, fresh.deviceModel == disk.deviceModel,
                  fresh.mediaSize == disk.mediaSize, fresh.isVirtual == disk.isVirtual else {
                return finish(.refused(.diskChanged(bsdName: disk.bsdName)))
            }
            if let r = Ejector.safetyCheck(fresh, policy: policy) { return finish(.refused(r)) }
            guard let current = fresh.volumes.first(where: { $0.bsdName == bsd }) else {
                if fresh.volumes.contains(where: { $0.path == volume.path }) {      // another volume mounted there now
                    return finish(.refused(.diskChanged(bsdName: bsd)))
                }
                log?.record(force ? "force-eject" : "eject", "\(dryRun ? "[dry-run] " : "")\(what): no longer mounted; nothing sent")
                return finish(.volumeUnmounted)
            }
            guard current.path == volume.path else { return finish(.refused(.diskChanged(bsdName: bsd))) }
            let volumeTime = DiskTopology.appearanceTime(bsdName: bsd, session: session)
            log?.record(force ? "force-eject" : "eject",
                        "\(dryRun ? "[dry-run] " : "")attempt \(force ? "FORCED " : "")unmount of one volume \(what) "
                        + "(\(fresh.deviceModel ?? "?"), \(fresh.isVirtual ? "virtual" : "real")); other volumes stay: "
                        + "\(fresh.volumePaths.filter { $0 != volume.path })")
            if force {                                                  // flush before a forced unmount (S2)
                if dryRun { log?.record("force-eject", "[dry-run] would sync_volume_np \(volume.path)") }
                else { Ejector.flush([volume.path], log: log) }
            }
            let step = EjectStep.unmount(bsdName: bsd)
            let span = EjectsInFlight.shared.begin(physicalBSD: fresh.bsdName)   // before the DA request
            let done: @Sendable (EjectResult) -> Void = { r in EjectsInFlight.shared.end(span); finish(r) }
            // Still the same disk and the same volume (BSD names are re-used after an unplug + re-attach)?
            guard DiskTopology.appearanceTime(bsdName: fresh.bsdName, session: session) == fresh.appearanceTime,
                  DiskTopology.appearanceTime(bsdName: bsd, session: session) == volumeTime else {
                return done(.refused(.diskChanged(bsdName: bsd)))
            }
            guard let d = DADiskCreateFromBSDName(kCFAllocatorDefault, session, bsd) else {
                return done(.failed(status: DAReturn(truncatingIfNeeded: kDAReturnNotFound), step: step))
            }
            requests.withLock { $0 += 1 }
            if dryRun { return done(.failed(status: 0, step: step)) }
            let cb = Callback { dissenter in
                done(dissenter.map { Ejector.result($0, step: step) } ?? .volumeUnmounted)
            }
            let options = DADiskUnmountOptions(kDADiskUnmountOptionDefault) | (force ? DADiskUnmountOptions(kDADiskUnmountOptionForce) : 0)
            DADiskUnmount(d, options, { _, dissenter, ctx in
                Unmanaged<Callback>.fromOpaque(ctx!).takeRetainedValue().fn(dissenter)
            }, Unmanaged.passRetained(cb).toOpaque())
        }
    }

    /// S2: `sync()` returns before buffers reach the disk, and a forced unmount skips VFS_SYNC. `sync_volume_np` with
    /// FULLSYNC|WAIT flushes each volume and waits. Blocking: never call on the main thread.
    public static func flush(_ volumePaths: [String], log: ActionLog?) {
        for p in volumePaths where DiskTopology.isMountPoint(p) {
            let r = sync_volume_np(p, SYNC_VOLUME_FULLSYNC | SYNC_VOLUME_WAIT)
            log?.record("force-eject", "sync_volume_np \(p) -> \(r == 0 ? "ok" : String(cString: strerror(r)))")
        }
    }

    /// True while this process's `Ejector` is unmounting/ejecting `physicalBSD` (EjectWatcher ignores those).
    public static func isInFlight(physicalBSD: String) -> Bool { EjectsInFlight.shared.isInFlight(physicalBSD: physicalBSD) }

    /// Disconnect an SMB/AFP/NFS share (no BSD disk, so no DADiskUnmount). Refuses local volumes and anything not
    /// mounted directly under /Volumes (an NFS home under /Users, autofs maps, …). The share is looked up in the
    /// mount table, never stat'ed (an unresponsive server cannot block the caller). Completion runs on the ejector's
    /// queue, like `eject`.
    public func unmountNetworkShare(url: URL, completion: @escaping @Sendable (EjectResult) -> Void) {
        let path = url.standardizedFileURL.path
        queue.async { [self] in
            let refusal: SafetyRefusal? = {
                guard path.hasPrefix("/Volumes/") else { return .notUnderVolumes(path: path) }
                guard let v = DiskTopology.mountedVolume(atPath: path), v.isNetwork, v.isDirectlyUnderVolumes,
                      !v.isRootFileSystem, !v.isSystemVolume else { return .notANetworkShare(path: path) }
                return nil
            }()
            if let refusal {
                let r = EjectResult.refused(refusal)
                log?.ejectResult(r, disk: path, force: false, milliseconds: 0, dryRun: dryRun)
                return completion(r)
            }
            let step = EjectStep.networkUnmount(path: path)
            log?.record("eject", "\(dryRun ? "[dry-run] " : "")network unmount \(path)")
            requests.withLock { $0 += 1 }
            if dryRun { return completion(.failed(status: 0, step: step)) }
            let started = DispatchTime.now().uptimeNanoseconds
            FileManager.default.unmountVolume(at: URL(fileURLWithPath: path, isDirectory: true), options: [.withoutUI]) { [log, queue] error in
                let ms = Double(DispatchTime.now().uptimeNanoseconds - started) / 1e6
                let r: EjectResult
                if let error = error as NSError? {
                    let underlying = (error.userInfo[NSUnderlyingErrorKey] as? NSError)?.code
                    let status = DAReturn(truncatingIfNeeded: underlying ?? error.code)
                    if error.domain == NSCocoaErrorDomain && error.code == CocoaError.Code.fileManagerUnmountBusy.rawValue {
                        let pid = (error.userInfo[NSFileManagerUnmountDissentingProcessIdentifierErrorKey] as? NSNumber)?.int32Value
                        r = .busy(dissenterPID: pid.flatMap { $0 > 0 ? $0 : nil }, status: status, step: step)
                    } else {
                        r = .failed(status: status, step: step)
                    }
                } else {
                    r = .ejected
                }
                log?.ejectResult(r, disk: path, force: false, milliseconds: ms, dryRun: false)
                queue.async { completion(r) }
            }
        }
    }

    // MARK: - DiskArbitration sequence (runs on `queue`)

    private final class Callback {
        let fn: (DADissenter?) -> Void
        init(_ fn: @escaping (DADissenter?) -> Void) { self.fn = fn }
    }

    private func runSteps(physical: String, containers: [String], expected: [String: Double?], force: Bool,
                          completion: @escaping @Sendable (EjectResult) -> Void) {
        var pending = containers
        let options = DADiskUnmountOptions(kDADiskUnmountOptionWhole)
            | (force ? DADiskUnmountOptions(kDADiskUnmountOptionForce) : 0)
        let session = session

        /// Still the disk that was checked? (BSD names are re-used after an unplug + re-attach.)
        func sameDisk(_ bsd: String) -> Bool {
            guard let want = expected[bsd] else { return false }
            return DiskTopology.appearanceTime(bsdName: bsd, session: session) == want
        }

        func next() {
            guard !pending.isEmpty else { return eject() }
            let bsd = pending.removeFirst()
            let step = EjectStep.unmount(bsdName: bsd)
            guard sameDisk(bsd) else { return completion(.refused(.diskChanged(bsdName: bsd))) }
            guard let whole = DADiskCreateFromBSDName(kCFAllocatorDefault, session, bsd) else {
                return completion(.failed(status: DAReturn(truncatingIfNeeded: kDAReturnNotFound), step: step))
            }
            let cb = Callback { dissenter in
                if let dissenter { completion(Ejector.result(dissenter, step: step)) } else { next() }
            }
            requests.withLock { $0 += 1 }
            if dryRun { return completion(.failed(status: 0, step: step)) }
            DADiskUnmount(whole, options, { _, dissenter, ctx in
                Unmanaged<Callback>.fromOpaque(ctx!).takeRetainedValue().fn(dissenter)
            }, Unmanaged.passRetained(cb).toOpaque())
        }

        func eject() {
            let step = EjectStep.eject(bsdName: physical)
            guard sameDisk(physical) else { return completion(.refused(.diskChanged(bsdName: physical))) }
            guard let disk = DADiskCreateFromBSDName(kCFAllocatorDefault, session, physical) else {
                return completion(.failed(status: DAReturn(truncatingIfNeeded: kDAReturnNotFound), step: step))
            }
            // Every unmount succeeded: a dissent here still leaves the disk flushed and safe to disconnect.
            let cb = Callback { dissenter in
                completion(dissenter.map { .unmountedNotEjected(status: DADissenterGetStatus($0)) } ?? .ejected)
            }
            requests.withLock { $0 += 1 }
            if dryRun { return completion(.failed(status: 0, step: step)) }
            DADiskEject(disk, DADiskEjectOptions(kDADiskEjectOptionDefault), { _, dissenter, ctx in
                Unmanaged<Callback>.fromOpaque(ctx!).takeRetainedValue().fn(dissenter)
            }, Unmanaged.passRetained(cb).toOpaque())
        }

        next()
    }

    /// An unmount dissent. `unix_err(EBUSY)` (0xC010) names a holder pid; DA's own kDAReturnBusy / ExclusiveAccess
    /// mean busy too, without a pid. Anything else is a failure.
    static func result(_ dissenter: DADissenter, step: EjectStep) -> EjectResult {
        result(status: DADissenterGetStatus(dissenter), pid: dissenterPID(dissenter), step: step)
    }

    static func result(status: DAReturn, pid: pid_t?, step: EjectStep) -> EjectResult {
        if status & 0x3fff == EBUSY { return .busy(dissenterPID: pid, status: status, step: step) }
        if status == DAReturn(truncatingIfNeeded: kDAReturnBusy) || status == DAReturn(truncatingIfNeeded: kDAReturnExclusiveAccess) {
            return .busy(dissenterPID: nil, status: status, step: step)
        }
        return .failed(status: status, step: step)
    }

    /// The dissenter is a CFDictionary `{DAProcessID = pid; DAStatus = 0xC010}`. Private key; 0/absent = unknown.
    static func dissenterPID(_ dissenter: DADissenter) -> pid_t? {
        guard let n = (dissenter as AnyObject as? NSDictionary)?["DAProcessID"] as? NSNumber else { return nil }
        let pid = pid_t(truncatingIfNeeded: n.int64Value)
        return pid > 0 ? pid : nil
    }
}

/// Physical disks this process's `Ejector` is ejecting, with the uptime span of each request, so `EjectWatcher`
/// (same process) can tell approvals caused by our own DiskArbitration requests from Finder's. DA delivers the
/// approval to the watcher strictly between `begin` (before our first unmount) and `end` (after our completion
/// callback), so `wasInFlight(physicalBSD:at:)` with the approval's timestamp has no race. Times are
/// `DispatchTime.now().uptimeNanoseconds`. Thread-safe.
public final class EjectsInFlight: Sendable {
    public static let shared = EjectsInFlight()

    private struct Span: Sendable { let id: UInt64; let bsdName: String; let start: UInt64; var end: UInt64? }
    private let state = OSAllocatedUnfairLock(initialState: (nextID: UInt64(1), spans: [Span]()))
    /// Finished spans are kept this long (only to answer late `wasInFlight` questions; bounds memory).
    private static let retention: UInt64 = 120_000_000_000

    public init() {}

    /// Marks `physicalBSD` as being ejected by us. Returns a token for `end`.
    public func begin(physicalBSD: String) -> UInt64 {
        let now = DispatchTime.now().uptimeNanoseconds
        return state.withLock { s in
            s.spans.removeAll { $0.end.map { now - $0 > Self.retention } ?? false }
            let id = s.nextID
            s.nextID += 1
            s.spans.append(Span(id: id, bsdName: physicalBSD, start: now, end: nil))
            return id
        }
    }

    public func end(_ token: UInt64) {
        let now = DispatchTime.now().uptimeNanoseconds
        state.withLock { s in
            if let i = s.spans.firstIndex(where: { $0.id == token }) { s.spans[i].end = now }
        }
    }

    public func isInFlight(physicalBSD: String) -> Bool {
        state.withLock { $0.spans.contains { $0.bsdName == physicalBSD && $0.end == nil } }
    }

    /// Was `physicalBSD` being ejected by us at `uptimeNanoseconds` (e.g. when a DA approval callback fired)?
    public func wasInFlight(physicalBSD: String, at uptimeNanoseconds: UInt64) -> Bool {
        state.withLock {
            $0.spans.contains { $0.bsdName == physicalBSD && $0.start <= uptimeNanoseconds && ($0.end ?? .max) >= uptimeNanoseconds }
        }
    }
}
