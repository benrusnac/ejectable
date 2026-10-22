import Darwin
import Foundation
import os

/// Finds every same-user process holding any of a set of volumes (cwd/root, open fds, mmapped files).
///
/// Replaces `proc_listpidspath(…PATH_IS_VOLUME…)`, which misses mmap-only holders on APFS/exFAT
/// (RECON §2). Root and other-uid processes cannot be inspected unprivileged; they are counted in
/// `deniedPIDs`. `O_EVTONLY` descriptors are ignored because they never block an unmount.
///
/// Only real mount points are scanned (`uniqueTargets`): a leftover /Volumes/X directory, a subdirectory or the
/// `/Volumes/Macintosh HD -> /` symlink would otherwise statfs to the boot volume and list every process on the Mac.
/// A scan that could resolve none of the requested paths (or one still mounted but unreadable) is `incomplete`: it
/// knows nothing about holders (S2 fails closed).
///
/// Work is spread over `workerCount` threads (GCD global queue) pulling pids from a shared index. A scan that is not
/// done after `deadline` returns what it has with `incomplete = true` (S2: Force Eject is then unavailable); a pid
/// whose inspection is still stuck in the kernel (e.g. getattr on an unresponsive network share) is skipped by later
/// scans, which stay incomplete, until that inspection returns.
public enum HolderScanner {
    /// Wall-clock limit of one scan.
    public static let defaultDeadline: TimeInterval = 2
    /// Worker threads per scan. 4 keeps a full scan well under 200 ms here and touches half the threads of
    /// `concurrentPerform` (one per core); each worker's buffers are freed when it finishes.
    static let workerCount = 4

    /// Synchronous; call from a background queue.
    public static func scan(volumePaths: [String], deadline: TimeInterval = defaultDeadline,
                            log: ActionLog? = .shared) -> HolderScan {
        let started = Date()
        let t0 = DispatchTime.now().uptimeNanoseconds
        let (targets, unreadable) = resolveTargets(volumePaths)
        var outcome = Outcome()
        if !targets.isEmpty {
            let (all, complete) = LibProc.allPIDs()
            let me = getpid()
            outcome = run(pids: all.filter { $0 > 0 && $0 != me }, targets: targets, workers: workerCount, deadline: deadline,
                          walkAll: walkEveryProcess())
            if !complete { outcome.reasons.insert("process list could not be read in full", at: 0) }
        }
        return finish(volumePaths, targets, unreadable, outcome, started: started, t0: t0, log: log)
    }

    /// Every mounted volume of a physical disk (a holder on a sibling volume blocks the eject too).
    public static func scan(disk: PhysicalDisk, deadline: TimeInterval = defaultDeadline, log: ActionLog? = .shared) -> HolderScan {
        scan(volumePaths: disk.volumePaths, deadline: deadline, log: log)
    }

    /// Re-inspects only `pids` (the holders already known) on `volumePaths`: a few syscalls per pid instead of a
    /// walk over every process (~1 ms vs ~150 ms of kernel CPU). Used for the alert's 1 s refresh; new holders are
    /// found by the periodic full scan.
    public static func rescan(pids: [pid_t], volumePaths: [String], deadline: TimeInterval = defaultDeadline,
                              log: ActionLog? = .shared) -> HolderScan {
        let started = Date()
        let t0 = DispatchTime.now().uptimeNanoseconds
        let (targets, unreadable) = resolveTargets(volumePaths)
        var outcome = Outcome()
        if !targets.isEmpty {
            let me = getpid()
            let wanted = Array(Set(pids)).filter { $0 > 0 && $0 != me }.sorted()
            outcome = run(pids: wanted, targets: targets, workers: min(2, max(1, wanted.count)), deadline: deadline,
                          walkAll: walkEveryProcess())
        }
        return finish(volumePaths, targets, unreadable, outcome, started: started, t0: t0, log: log)
    }

    /// S2: a scan that could not look at a requested volume does not know its holders. Nothing resolved at all (every
    /// statfs/realpath failed on a sick drive, or every path vanished) is "no mount point could be resolved", and a
    /// requested path that is still in the kernel mount table but could not be statfs'ed is named.
    static func coverageReasons(requested: [String], targets: [Target], unreadable: [String]) -> [String] {
        var reasons: [String] = []
        if targets.isEmpty && !requested.isEmpty { reasons.append("no mount point could be resolved") }
        if !unreadable.isEmpty { reasons.append("\(unreadable.joined(separator: ", ")) is mounted but could not be read") }
        return reasons
    }

    private static func finish(_ requested: [String], _ targets: [Target], _ unreadable: [String], _ outcome: Outcome,
                               started: Date, t0: UInt64, log: ActionLog?) -> HolderScan {
        var o = outcome
        o.reasons = coverageReasons(requested: requested, targets: targets, unreadable: unreadable) + o.reasons
        // Identity (S6) is the start time read during inspection; a pid that was recycled (or exited) since then is
        // dropped instead of being resolved to the new process.
        let holders = o.hits.sorted { $0.pid < $1.pid }.compactMap { hit -> Holder? in
            let now = LibProc.startTime(hit.pid)
            if let then = hit.startTime, now.map({ abs($0 - then) > 0.001 }) ?? true { return nil }
            return HolderResolver.resolve(pid: hit.pid, path: LibProc.executablePath(hit.pid) ?? "", info: LibProc.shortInfo(hit.pid),
                                          reasons: hit.reasons, volumePaths: hit.volumes, startTime: hit.startTime)
        }
        let duration = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e9
        let result = HolderScan(volumePaths: requested, holders: holders, deniedPIDs: o.denied.sorted(), duration: duration,
                                scannedAt: started, scannedTargets: targets.map(\.path), incomplete: !o.reasons.isEmpty,
                                incompleteReason: o.reasons.isEmpty ? nil : o.reasons.joined(separator: "; "))
        log?.scan(result)
        return result
    }

    // MARK: - Worker pool

    struct Hit {
        let pid: pid_t
        let reasons: [HoldReason]
        let volumes: [String]
        let startTime: Double?
    }

    struct Outcome {
        var hits: [Hit] = []
        var denied: [pid_t] = []
        /// Non-empty = incomplete.
        var reasons: [String] = []
    }

    /// Pids whose inspection outlived a scan deadline and has not returned yet. Later scans skip them.
    private static let stuck = OSAllocatedUnfairLock(initialState: Set<pid_t>())

    static var stuckPIDs: Set<pid_t> { stuck.withLock { $0 } }

    #if DEBUG
    /// Tests only (debug builds): called at the start of every inspection (simulates a process stuck in the kernel).
    /// Compiled out of release builds.
    static let inspectHook = OSAllocatedUnfairLock<(@Sendable (pid_t) -> Void)?>(initialState: nil)

    /// Tests only (debug builds): fault injection for the mmap paths. Compiled out of release builds.
    struct DebugFaults: Sendable {
        /// Overrides "a network share is mounted" (nil = the real mount table).
        var networkMountPresent: Bool?
        /// Every PROC_PIDREGIONPATHINFO3 probe reports "no match" (the offline-SMB getattr failure, which reads the same).
        var probeAlwaysMisses = false
        /// (pid, address of the region the kernel returned) -> errno to report instead (a vnode that cannot be read).
        var regionWalkError: (@Sendable (pid_t, UInt64) -> Int32?)?
    }
    static let debugFaults = OSAllocatedUnfairLock(initialState: DebugFaults())
    #endif

    /// Mapped files are found by walking every vnode-backed region when any network filesystem is mounted: the cheap
    /// PROC_PIDREGIONPATHINFO3 probe stops at the first mapping whose getattr fails (a file of an offline SMB share)
    /// and that reads exactly like "nothing mapped" (S2). Measured here: ~26k regions over ~700 same-user processes,
    /// 130-190 ms of kernel CPU spread over the workers. Without network mounts only bundled processes are walked.
    static func walkEveryProcess() -> Bool {
        #if DEBUG
        if let forced = debugFaults.withLock({ $0.networkMountPresent }) { return forced }
        #endif
        return DiskTopology.mountTable().contains { $0.f_flags & UInt32(MNT_LOCAL) == 0 }
    }

    /// One scan's shared work list and results. All mutable state is guarded by `lock`.
    private final class Job: @unchecked Sendable {
        let pids: [pid_t]
        let targets: [Target]
        let walkAll: Bool
        private let lock = NSLock()
        private var next = 0
        private var abandoned = false
        private var inProgress = Set<pid_t>()
        private var hits: [Hit] = []
        private var denied: [pid_t] = []
        private var truncated: [pid_t] = []

        init(pids: [pid_t], targets: [Target], walkAll: Bool) { self.pids = pids; self.targets = targets; self.walkAll = walkAll }

        var isAbandoned: Bool { lock.withLock { abandoned } }

        func claim() -> pid_t? {
            lock.withLock {
                guard !abandoned, next < pids.count else { return nil }
                let pid = pids[next]
                next += 1
                inProgress.insert(pid)
                return pid
            }
        }

        func complete(_ pid: pid_t, _ r: Inspection) {
            lock.withLock {
                inProgress.remove(pid)
                if abandoned {                              // late: the scan already returned without it
                    _ = HolderScanner.stuck.withLock { $0.remove(pid) }
                    return
                }
                if r.denied { denied.append(pid); return }
                if r.truncated { truncated.append(pid) }
                if !r.reasons.isEmpty { hits.append(Hit(pid: pid, reasons: r.reasons, volumes: r.volumes, startTime: r.startTime)) }
            }
        }

        /// Ends the job. `timedOut`: pids still being inspected are recorded as stuck.
        func close(timedOut: Bool) -> Outcome {
            lock.withLock {
                abandoned = true
                var o = Outcome(hits: hits, denied: denied, reasons: [])
                if timedOut {
                    let busy = inProgress
                    HolderScanner.stuck.withLock { $0.formUnion(busy) }
                    let unclaimed = pids.count - next
                    o.reasons.append("deadline reached with \(busy.count + unclaimed) process(es) not inspected"
                                     + (busy.isEmpty ? "" : " (stuck: \(busy.sorted().map(String.init).joined(separator: ",")))"))
                }
                if !truncated.isEmpty {
                    o.reasons.append("file or region list of pid(s) \(truncated.sorted().map(String.init).joined(separator: ",")) could not be read in full")
                }
                return o
            }
        }
    }

    private static func run(pids: [pid_t], targets: [Target], workers: Int, deadline: TimeInterval, walkAll: Bool) -> Outcome {
        let skipped = stuck.withLock { s in pids.filter { s.contains($0) } }
        let job = Job(pids: skipped.isEmpty ? pids : pids.filter { !skipped.contains($0) }, targets: targets, walkAll: walkAll)
        let group = DispatchGroup()
        for _ in 0..<max(1, workers) {
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                var fdBuffer = [proc_fdinfo](repeating: proc_fdinfo(), count: 256)   // per worker, freed on return
                while let pid = job.claim() {
                    job.complete(pid, inspect(pid: pid, targets: job.targets, fdBuffer: &fdBuffer, walkAll: job.walkAll,
                                              shouldStop: { job.isAbandoned }))
                }
                group.leave()
            }
        }
        let timedOut = group.wait(timeout: .now() + max(0.05, deadline)) == .timedOut
        var o = job.close(timedOut: timedOut)
        if !skipped.isEmpty {
            o.reasons.append("pid(s) \(skipped.sorted().map(String.init).joined(separator: ",")) still stuck in an earlier scan")
        }
        return o
    }

    // MARK: - Targets

    struct Target {
        let path: String
        /// 32-bit dev_t, == st_dev == f_fsid.val[0]. Matches vinfo_stat.vst_dev for fds, cwd, regions.
        let dev: UInt32
        /// Keys for PROC_PIDREGIONPATHINFO3: the 64-bit fsid (APFS, exFAT/FSKit), then the 32-bit dev (HFS+).
        let regionKeys: [UInt64]
    }

    /// `realpath(3)`; nil if the path does not resolve.
    static func realPath(_ path: String) -> String? {
        guard let p = realpath(path, nil) else { return nil }
        defer { free(p) }
        return String(cString: p)
    }

    /// The mount points among `paths`. A path counts only if, after resolving symlinks, it IS the mount point
    /// (`f_mntonname == realpath(path)`), and the mount is neither the root filesystem nor under /System/Volumes.
    static func uniqueTargets(_ paths: [String]) -> [Target] { resolveTargets(paths).targets }

    /// `uniqueTargets`, plus the requested paths that could not be resolved (realpath/statfs failed) although the
    /// kernel mount table (getfsstat MNT_NOWAIT, never blocks) still lists a filesystem mounted there: a sick drive.
    /// A path that is simply not mounted any more (unmounted mid-flow) is not "unreadable".
    static func resolveTargets(_ paths: [String]) -> (targets: [Target], unreadable: [String]) {
        var seen = Set<UInt32>()
        var out: [Target] = []
        var unreadable: [String] = []
        lazy var mounted = Set(DiskTopology.mountTable().map { entry -> String in var e = entry; return LibProc.string(&e.f_mntonname) })
        for path in paths {
            var sfs = statfs()
            guard let real = realPath(path), statfs(real, &sfs) == 0 else {
                let p = URL(fileURLWithPath: path).standardizedFileURL.path
                if mounted.contains(p) { unreadable.append(p) }
                continue
            }
            let mount = LibProc.string(&sfs.f_mntonname)
            guard mount == real, mount != "/", sfs.f_flags & UInt32(MNT_ROOTFS) == 0,
                  mount != "/System/Volumes", !mount.hasPrefix("/System/Volumes/") else { continue }
            let dev = UInt32(bitPattern: sfs.f_fsid.val.0)
            guard seen.insert(dev).inserted else { continue }
            let fsid64 = UInt64(dev) | UInt64(UInt32(bitPattern: sfs.f_fsid.val.1)) << 32
            // The kernel compares va_fsid64 when the filesystem supports it (APFS, exFAT/FSKit), else the
            // 32-bit va_fsid (HFS+). Each probe is a full in-kernel region walk (~80 ms over all pids), so
            // only send the key that can match; unknown filesystems get both.
            let keys: [UInt64]
            switch LibProc.string(&sfs.f_fstypename) {
            case _ where fsid64 == UInt64(dev): keys = [fsid64]
            case "apfs": keys = [fsid64]
            case "hfs": keys = [UInt64(dev)]
            default: keys = [fsid64, UInt64(dev)]
            }
            out.append(Target(path: mount, dev: dev, regionKeys: keys))
        }
        return (out, unreadable)
    }

    // MARK: - One process

    struct Inspection {
        var denied = false
        var reasons: [HoldReason] = []
        var volumes: [String] = []
        /// Read before any vnode call: identifies the process the reasons belong to (S6).
        var startTime: Double?
        /// The fd list or the mapped-region walk could not be read in full (S2: the scan is then incomplete).
        var truncated = false
    }

    /// Executables inside a bundle (GUI apps, app extensions, helpers, XPC services): where media apps live.
    static func isBundled(_ path: String) -> Bool {
        path.contains(".app/") || path.contains(".appex/") || path.contains(".xpc/")
    }

    static func inspect(pid: pid_t, targets: [Target], fdBuffer: inout [proc_fdinfo], walkAll: Bool = false,
                        shouldStop: () -> Bool = { false }) -> Inspection {
        var result = Inspection()
        result.startTime = LibProc.startTime(pid)
        #if DEBUG
        if let hook = inspectHook.withLock({ $0 }) { hook(pid) }
        #endif
        var reasons: [HoldReason] = []
        var hit = Set<Int>()                                            // indices into targets

        // cwd / chroot
        var vpi = proc_vnodepathinfo()
        let vpiSize = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &vpi, vpiSize) > 0 else {
            result.denied = errno == EPERM                              // ESRCH: exited mid-scan
            return result
        }
        for (i, t) in targets.enumerated() {
            if vpi.pvi_cdir.vip_vi.vi_stat.vst_dev == t.dev, vpi.pvi_cdir.vip_vi.vi_type != 0 {
                reasons.append(.workingDirectory(path: LibProc.string(&vpi.pvi_cdir.vip_path))); hit.insert(i)
            }
            if vpi.pvi_rdir.vip_vi.vi_stat.vst_dev == t.dev, vpi.pvi_rdir.vip_vi.vi_type != 0 {
                reasons.append(.rootDirectory(path: LibProc.string(&vpi.pvi_rdir.vip_path))); hit.insert(i)
            }
        }

        // mmapped files
        if walkAll || isBundled(LibProc.executablePath(pid) ?? "") {
            // The PATHINFO3 probe stops at the first mapped vnode whose getattr fails (a file of an offline SMB share,
            // common for editors) and then reads like "no match": a missed mmap holder would let Force Eject through
            // and SIGBUS the app. Bundled processes (and every process while a network share is mounted) are walked
            // region by region instead, all targets at once.
            let walk = mappedFiles(pid: pid, targets: targets, only: nil, from: 0, shouldStop: shouldStop)
            if walk.truncated { result.truncated = true }
            for (i, reason) in walk.found {
                hit.insert(i); reasons.append(reason)
            }
        } else {
            // One cheap in-kernel probe per volume, full region walk only on a hit.
            var probed: [Int: proc_regionwithpathinfo] = [:]
            #if DEBUG
            let probeMisses = debugFaults.withLock { $0.probeAlwaysMisses }
            #else
            let probeMisses = false
            #endif
            for (i, t) in targets.enumerated() where !probeMisses {
                var rw = proc_regionwithpathinfo()
                let rwSize = Int32(MemoryLayout<proc_regionwithpathinfo>.size)
                if t.regionKeys.contains(where: { proc_pidinfo(pid, LibProc.regionPathInfo3, $0, &rw, rwSize) > 0 }) { probed[i] = rw }
            }
            if let start = probed.values.map(\.prp_prinfo.pri_address).min() {
                let walk = mappedFiles(pid: pid, targets: targets, only: Set(probed.keys), from: start, shouldStop: shouldStop)
                if walk.truncated { result.truncated = true }
                for i in probed.keys.sorted() {
                    hit.insert(i)
                    let mine = walk.found.filter { $0.0 == i }.map(\.1)
                    if mine.isEmpty, var rw = probed[i] {               // fall back to the probe's own answer
                        reasons.append(.mappedFile(path: LibProc.string(&rw.prp_vip.vip_path),
                                                   writable: LibProc.mappingWritesFile(pid: pid, region: rw.prp_prinfo)))
                    } else {
                        reasons.append(contentsOf: mine)
                    }
                }
            }
        }

        // open file descriptors. A list that fills the buffer may be truncated: grow and read again.
        let fdStride = MemoryLayout<proc_fdinfo>.stride
        var got = 0
        for attempt in 0..<4 {
            let need = Int(proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0))
            guard need > 0 else { got = 0; break }
            if need > fdBuffer.count * fdStride || attempt > 0 {
                fdBuffer = [proc_fdinfo](repeating: proc_fdinfo(), count: max(need / fdStride + 64, fdBuffer.count * (attempt > 0 ? 2 : 1)))
            }
            got = Int(fdBuffer.withUnsafeMutableBytes { proc_pidinfo(pid, PROC_PIDLISTFDS, 0, $0.baseAddress, Int32($0.count)) })
            if got < fdBuffer.count * fdStride { break }
            if attempt == 3 { result.truncated = true }
        }
        if got > 0 {
            var open: [String: Bool] = [:]                              // path -> writing (merged across fds)
            var order: [String] = []
            for k in 0..<(got / fdStride) where fdBuffer[k].proc_fdtype == UInt32(PROX_FDTYPE_VNODE) {
                var vi = vnode_fdinfowithpath()
                let viSize = Int32(MemoryLayout<vnode_fdinfowithpath>.size)
                guard proc_pidfdinfo(pid, fdBuffer[k].proc_fd, PROC_PIDFDVNODEPATHINFO, &vi, viSize) > 0 else { continue }
                // fi_openflags holds kernel FFLAGS (FREAD=1, FWRITE=2), not O_* values.
                let flags = vi.pfi.fi_openflags
                guard flags & UInt32(O_EVTONLY) == 0,                   // never blocks: kernel revokes it
                      let i = targets.firstIndex(where: { $0.dev == vi.pvip.vip_vi.vi_stat.vst_dev }) else { continue }
                hit.insert(i)
                let path = LibProc.string(&vi.pvip.vip_path)
                let writing = flags & UInt32(FWRITE) != 0
                if let prev = open[path] { open[path] = prev || writing } else { open[path] = writing; order.append(path) }
            }
            reasons.append(contentsOf: order.map { .openFile(path: $0, writing: open[$0] ?? false) })
        }

        result.reasons = reasons
        result.volumes = hit.sorted().map { targets[$0].path }
        return result
    }

    /// Walks the vnode-backed regions of `pid` (PROC_PIDREGIONPATHINFO2) from `start` and returns one `.mappedFile`
    /// per distinct path on a target (restricted to `only` when given), writable if any mapping of it writes to the file.
    ///
    /// A failing call does not end the walk silently. PATHINFO2 answers EINVAL both at the end (no vnode-backed region
    /// at or after the address) and when the next region's vnode cannot be taken (`vnode_getwithvid` failed: the vnode
    /// is being reclaimed), and the error of `vn_stat` (EIO, ETIMEDOUT, … from a file of an offline share) otherwise.
    /// On a failure the walk steps over the next region with PROC_PIDREGIONINFO and asks again from its end:
    ///  - another error than EINVAL is always a region that could not be read: `truncated`, keep stepping (bounded)
    ///    until the walk gets past it;
    ///  - EINVAL followed by a region found right after the next one means that next region failed: `truncated`, go on;
    ///  - EINVAL again: treated as the end. (A vnode being reclaimed behind a run of anonymous regions is not told apart
    ///    from the end: that would take one PROC_PIDREGIONINFO per remaining region, measured ~1 s over all processes.
    ///    Mappings of a filesystem that was force-unmounted are skipped by the kernel itself, measured on macOS 26.6.)
    static func mappedFiles(pid: pid_t, targets: [Target], only: Set<Int>?, from start: UInt64,
                            shouldStop: () -> Bool = { false }) -> (found: [(Int, HoldReason)], truncated: Bool) {
        var writable: [String: Bool] = [:]
        var order: [(Int, String)] = []
        var truncated = false
        var addr = start
        var failureSteps = 0
        var n = 0
        walk: while true {
            n += 1
            if n > 100_000 { truncated = true; break }                 // runaway map: say so instead of guessing
            if n & 63 == 63, shouldStop() { break }
            var rw = proc_regionwithpathinfo()
            var err = regionPathInfo2(pid, addr, &rw)
            while err != 0 {
                // Step over the next region of any kind and ask again from its end.
                guard let next = LibProc.nextRegionEnd(pid, after: addr), next > addr else { break walk }   // end of map
                let first = err
                rw = proc_regionwithpathinfo()
                err = regionPathInfo2(pid, next, &rw)
                addr = next
                if err == 0 {
                    truncated = true                                    // the region we stepped over could not be read
                } else if err == EINVAL {
                    if first != EINVAL { truncated = true }
                    break walk                                          // end (see above)
                } else {
                    truncated = true
                    failureSteps += 1
                    if failureSteps > 4096 { break walk }
                }
            }
            let dev = rw.prp_vip.vip_vi.vi_stat.vst_dev
            if let i = targets.firstIndex(where: { $0.dev == dev }), only?.contains(i) ?? true {
                let path = LibProc.string(&rw.prp_vip.vip_path)
                let w = LibProc.mappingWritesFile(pid: pid, region: rw.prp_prinfo)
                if let prev = writable[path] { writable[path] = prev || w } else { writable[path] = w; order.append((i, path)) }
            }
            let next = rw.prp_prinfo.pri_address &+ rw.prp_prinfo.pri_size
            guard next > addr else { break }
            addr = next
        }
        return (order.map { ($0.0, .mappedFile(path: $0.1, writable: writable[$0.1] ?? false)) }, truncated)
    }

    /// PROC_PIDREGIONPATHINFO2 at `address`: 0, or the errno.
    private static func regionPathInfo2(_ pid: pid_t, _ address: UInt64, _ rw: inout proc_regionwithpathinfo) -> Int32 {
        let size = Int32(MemoryLayout<proc_regionwithpathinfo>.size)
        guard proc_pidinfo(pid, LibProc.regionPathInfo2, address, &rw, size) > 0 else { return errno == 0 ? EINVAL : errno }
        #if DEBUG
        if let inject = debugFaults.withLock({ $0.regionWalkError }), let e = inject(pid, rw.prp_prinfo.pri_address) {
            rw = proc_regionwithpathinfo()
            return e
        }
        #endif
        return 0
    }
}
