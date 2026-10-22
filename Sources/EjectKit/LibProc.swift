import Darwin

/// Thin, allocation-light wrappers around libproc / sysctl. Internal to EjectKit.
enum LibProc {
    /// PROC_PIDREGIONPATHINFO2 (private): first vnode-backed region at or after `arg` (an address). Only offset,
    /// protection, inheritance, address and size are filled; `pri_share_mode` is always 0 here (kernel
    /// `fill_procregioninfo_onlymappedvnodes`).
    static let regionPathInfo2: Int32 = 22
    /// PROC_PIDREGIONPATHINFO3 (private): first region whose vnode's fsid equals `arg`.
    /// libproc's own proc_listpidspath passes the 32-bit st_dev here, but on APFS/exFAT the kernel
    /// compares the 64-bit fsid (val[0] | val[1] << 32), so stock libproc misses mmap holders (RECON §2).
    /// The in-kernel walk stops at the first mapped vnode whose getattr fails (e.g. an offline SMB share), which
    /// reads exactly like "no match"; bundled processes are therefore walked with `regionPathInfo2` instead.
    static let regionPathInfo3: Int32 = 23
    /// PROC_PIDPATHINFO_MAXSIZE is not imported into Swift.
    static let pathMax = 4 * Int(MAXPATHLEN)

    /// `vm_inherit_t` values (mach/vm_inherit.h). mmap(2) gives MAP_SHARED mappings VM_INHERIT_SHARE and
    /// MAP_PRIVATE (copy-on-write) mappings VM_INHERIT_COPY.
    static let inheritShare: UInt32 = 0
    static let inheritCopy: UInt32 = 1
    /// `SM_COW` (mach/vm_region.h): copy-on-write; writes never reach the file.
    static let shareModeCOW: UInt32 = 1

    /// Decode a fixed-size, NUL-terminated C char array (imported as a tuple) without
    /// `String(cString: &tuple.0)`, which traps on Swift 6.2.
    static func string<T>(_ t: inout T) -> String {
        withUnsafeBytes(of: &t) { raw in
            let n = raw.firstIndex(of: 0) ?? raw.count
            return String(decoding: raw[..<n], as: UTF8.self)
        }
    }

    /// Decode a NUL-terminated [CChar] buffer.
    static func string(array: [CChar]) -> String {
        array.withUnsafeBufferPointer { b in
            let n = b.firstIndex(of: 0) ?? b.count
            return String(decoding: UnsafeRawBufferPointer(start: b.baseAddress, count: n), as: UTF8.self)
        }
    }

    /// All pids on the system (unprivileged). `complete` is false when the list could not be read in full: a result
    /// that fills the buffer may be truncated, so the buffer is doubled and the call repeated (up to 6 times).
    static func allPIDs() -> (pids: [pid_t], complete: Bool) {
        let estimate = Int(proc_listallpids(nil, 0))
        guard estimate > 0 else { return ([], false) }
        var capacity = estimate + 128
        for _ in 0..<6 {
            var pids = [pid_t](repeating: 0, count: capacity)
            let n = Int(pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) })
            guard n > 0 else { return ([], false) }
            if n < capacity { return (Array(pids.prefix(n)), true) }
            capacity *= 2
        }
        return ([], false)
    }

    /// Executable path. Works for every pid, including root-owned ones.
    static func executablePath(_ pid: pid_t) -> String? {
        var buf = [CChar](repeating: 0, count: pathMax)
        let n = proc_pidpath(pid, &buf, UInt32(buf.count))
        guard n > 0 else { return nil }
        return buf.withUnsafeBufferPointer { b in
            String(decoding: UnsafeRawBufferPointer(start: b.baseAddress, count: Int(n)), as: UTF8.self)
        }
    }

    struct ShortInfo {
        let uid: uid_t
        let ppid: pid_t
        let comm: String
    }

    /// uid, ppid, comm. Uses PROC_PIDT_SHORTBSDINFO because proc_name() is EPERM for root pids on macOS 26.
    static func shortInfo(_ pid: pid_t) -> ShortInfo? {
        var si = proc_bsdshortinfo()
        let size = Int32(MemoryLayout<proc_bsdshortinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDT_SHORTBSDINFO, 0, &si, size) == size else { return nil }
        return ShortInfo(uid: si.pbsi_uid, ppid: pid_t(bitPattern: si.pbsi_ppid), comm: string(&si.pbsi_comm))
    }

    /// Process start time (seconds since 1970, microsecond precision) via sysctl KERN_PROC_PID.
    /// Works for every pid. Used together with the executable path to detect pid reuse (S6).
    static func startTime(_ pid: pid_t) -> Double? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let tv = info.kp_proc.p_un.__p_starttime
        guard tv.tv_sec > 0 else { return nil }
        return Double(tv.tv_sec) + Double(tv.tv_usec) / 1_000_000
    }

    /// Full region info (PROC_PIDREGIONPATHINFO) for the region containing / following `address`. Unlike the
    /// PATHINFO2/3 calls this computes the share mode (one page walk over the region), so it is only used to
    /// confirm a single writable mapping is copy-on-write.
    static func regionShareMode(_ pid: pid_t, address: UInt64) -> (shareMode: UInt32, start: UInt64)? {
        var rw = proc_regionwithpathinfo()
        let size = Int32(MemoryLayout<proc_regionwithpathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDREGIONPATHINFO, address, &rw, size) == size else { return nil }
        return (rw.prp_prinfo.pri_share_mode, rw.prp_prinfo.pri_address)
    }

    /// End address of the region (of any kind) containing or following `address`; nil past the last region or when the
    /// process is gone. PROC_PIDREGIONINFO (one page walk of that region, ~1 µs on average here): only used to step over
    /// a region whose vnode could not be read during a PATHINFO2 walk.
    static func nextRegionEnd(_ pid: pid_t, after address: UInt64) -> UInt64? {
        var ri = proc_regioninfo()
        let size = Int32(MemoryLayout<proc_regioninfo>.size)
        guard proc_pidinfo(pid, PROC_PIDREGIONINFO, address, &ri, size) == size else { return nil }
        return ri.pri_address &+ ri.pri_size
    }

    /// S2: does this mapping let the process write to the file? `pri_share_mode` cannot be used for this: it is 0 in
    /// the PATHINFO2/3 results, and even PROC_PIDREGIONPATHINFO reports a MAP_SHARED file mapped by a single process
    /// as SM_PRIVATE (measured on macOS 26.6, kernel ref_count == 2 rule). The reliable signal is the inheritance
    /// mmap(2) sets: VM_INHERIT_SHARE for MAP_SHARED, VM_INHERIT_COPY for MAP_PRIVATE. A writable COPY mapping only
    /// counts as private (copy-on-write, e.g. the __DATA of an app or plug-in run from the drive) when the full region
    /// info confirms SM_COW; anything else that is writable counts as a writer (fail closed).
    static func mappingWritesFile(pid: pid_t, region: proc_regioninfo) -> Bool {
        guard region.pri_protection & UInt32(VM_PROT_WRITE) != 0 else { return false }
        guard region.pri_inheritance == inheritCopy else { return true }
        guard let full = regionShareMode(pid, address: region.pri_address), full.start == region.pri_address else { return true }
        return full.shareMode != shareModeCOW
    }
}
