import Darwin
import Foundation
import AppKit
import DiskArbitration
import IOKit

// MARK: - (1) Who is holding a volume?
public struct VolumeHolder {
    public let pid: pid_t
    public let uid: uid_t
    public let executable: String          // proc_pidpath (works for root pids too)
    public let app: NSRunningApplication?  // nil for daemons / CLI tools
    public var reasons: [String]           // "cwd …", "fd7 …", "mmap …"
}

private func cstr<T>(_ t: inout T) -> String {
    withUnsafePointer(to: &t) { $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) } }
}

/// Replaces proc_listpidspath(…PATH_IS_VOLUME…): libproc passes the 32-bit st_dev to
/// PROC_PIDREGIONPATHINFO3 but the kernel compares the 64-bit fsid on APFS/exFAT, so mmapped files are missed.
/// Returns (holders, pidsWeCouldNotInspect). Same-user processes only; root/other-uid pids come back EPERM.
public func scanVolumeHolders(_ mountPoint: String) -> (holders: [VolumeHolder], denied: [pid_t]) {
    var sfs = statfs()
    guard statfs(mountPoint, &sfs) == 0 else { return ([], []) }
    let dev = sfs.f_fsid.val.0                                            // == stat.st_dev
    let fsid64 = UInt64(UInt32(bitPattern: sfs.f_fsid.val.0)) | UInt64(UInt32(bitPattern: sfs.f_fsid.val.1)) << 32
    let PROC_PIDREGIONPATHINFO3: Int32 = 23

    var pids = [pid_t](repeating: 0, count: Int(proc_listallpids(nil, 0)) + 64)
    let n = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
    var out: [VolumeHolder] = [], denied: [pid_t] = []
    var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: 512)

    for pid in pids.prefix(Int(n)) where pid > 0 && pid != getpid() {
        var why: [String] = []
        var vpi = proc_vnodepathinfo()
        if proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &vpi, Int32(MemoryLayout.size(ofValue: vpi))) <= 0 {
            if errno == EPERM { denied.append(pid) }; continue
        }
        if vpi.pvi_cdir.vip_vi.vi_stat.vst_dev == dev { why.append("cwd \(cstr(&vpi.pvi_cdir.vip_path))") }
        if vpi.pvi_rdir.vip_vi.vi_stat.vst_dev == dev { why.append("root \(cstr(&vpi.pvi_rdir.vip_path))") }

        var rw = proc_regionwithpathinfo(); let rwSize = Int32(MemoryLayout.size(ofValue: rw))
        if proc_pidinfo(pid, PROC_PIDREGIONPATHINFO3, fsid64, &rw, rwSize) > 0                       // APFS, exFAT(FSKit)
            || proc_pidinfo(pid, PROC_PIDREGIONPATHINFO3, UInt64(UInt32(bitPattern: dev)), &rw, rwSize) > 0 { // HFS+
            why.append("mmap \(cstr(&rw.prp_vip.vip_path))")
        }

        let need = Int(proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0))
        if need > fds.count * MemoryLayout<proc_fdinfo>.stride { fds = .init(repeating: proc_fdinfo(), count: need / MemoryLayout<proc_fdinfo>.stride + 64) }
        let got = Int(fds.withUnsafeMutableBytes { proc_pidinfo(pid, PROC_PIDLISTFDS, 0, $0.baseAddress, Int32($0.count)) })
        for fd in fds.prefix(max(0, got) / MemoryLayout<proc_fdinfo>.stride) where fd.proc_fdtype == UInt32(PROX_FDTYPE_VNODE) {
            var vi = vnode_fdinfowithpath()
            guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDVNODEPATHINFO, &vi, Int32(MemoryLayout.size(ofValue: vi))) > 0,
                  vi.pvip.vip_vi.vi_stat.vst_dev == dev,
                  vi.pfi.fi_openflags & UInt32(O_EVTONLY) == 0 else { continue }   // O_EVTONLY never blocks (kernel revokes it)
            why.append("fd\(fd.proc_fd) \(cstr(&vi.pvip.vip_path))")
        }
        guard !why.isEmpty else { continue }
        var si = proc_bsdshortinfo()
        _ = proc_pidinfo(pid, PROC_PIDT_SHORTBSDINFO, 0, &si, Int32(MemoryLayout.size(ofValue: si)))
        var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        _ = proc_pidpath(pid, &path, UInt32(path.count))
        out.append(VolumeHolder(pid: pid, uid: si.pbsi_uid, executable: path.withUnsafeBufferPointer { String(cString: $0.baseAddress!) },
                                app: NSRunningApplication(processIdentifier: pid), reasons: why))
    }
    return (out, denied)
}

// MARK: - (2d) Eject like Finder
/// Outermost IOMedia with Whole=true above the volume (APFS: disk9s1 -> disk9 (synth) -> disk8s2 -> disk8).
public func physicalWholeDiskBSD(volumeDisk: DADisk) -> String? {
    let media = DADiskCopyIOMedia(volumeDisk); defer { IOObjectRelease(media) }
    var it: io_iterator_t = 0
    guard IORegistryEntryCreateIterator(media, kIOServicePlane, IOOptionBits(kIORegistryIterateParents | kIORegistryIterateRecursively), &it) == KERN_SUCCESS else { return nil }
    defer { IOObjectRelease(it) }
    var result: String?
    while case let e = IOIteratorNext(it), e != 0 {
        defer { IOObjectRelease(e) }
        guard IOObjectConformsTo(e, "IOMedia") != 0,
              (IORegistryEntryCreateCFProperty(e, "Whole" as CFString, nil, 0)?.takeRetainedValue() as? Bool) == true,
              let bsd = IORegistryEntryCreateCFProperty(e, "BSD Name" as CFString, nil, 0)?.takeRetainedValue() as? String else { continue }
        result = bsd
    }
    return result ?? DADiskCopyWholeDisk(volumeDisk).flatMap { DADiskGetBSDName($0).map { String(cString: $0) } }
}

public enum EjectResult { case ejected; case busy(pid: pid_t?, status: DAReturn, step: String) }

/// 1) DADiskUnmount(kDADiskUnmountOptionWhole) on every distinct "whole" that has mounted volumes on this physical
///    disk (APFS synthesized containers + the physical disk itself for plain partitions), 2) DADiskEject(physical).
/// Unmounting the physical disk alone does NOT unmount APFS volumes (returns OK, no-op); ejecting it then fails EBUSY.
public func ejectLikeFinder(volumePath: String, force: Bool = false, session: DASession,
                            completion: @escaping (EjectResult) -> Void) {
    guard let vol = DADiskCreateFromVolumePath(nil, session, URL(fileURLWithPath: volumePath) as CFURL),
          let physBSD = physicalWholeDiskBSD(volumeDisk: vol),
          let phys = DADiskCreateFromBSDName(nil, session, physBSD) else { return completion(.busy(pid: nil, status: DAReturn(truncatingIfNeeded: kDAReturnNotFound), step: "lookup")) }
    // All mounted volumes on the same physical disk -> their whole disks (dedup by BSD name)
    var wholes: [String: DADisk] = [:]
    for url in FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: nil, options: []) ?? [] {
        guard let d = DADiskCreateFromVolumePath(nil, session, url as CFURL), physicalWholeDiskBSD(volumeDisk: d) == physBSD,
              let w = DADiskCopyWholeDisk(d), let wb = DADiskGetBSDName(w) else { continue }
        wholes[String(cString: wb)] = w
    }
    var queue = Array(wholes.values)
    let opts = DADiskUnmountOptions(kDADiskUnmountOptionWhole) | (force ? DADiskUnmountOptions(kDADiskUnmountOptionForce) : 0)

    final class Box { let fn: (DADisk, DADissenter?) -> Void; init(_ f: @escaping (DADisk, DADissenter?) -> Void) { fn = f } }
    func dissenterPID(_ d: DADissenter) -> pid_t? {          // private key; 0/absent = unknown (root holder or mmap on APFS/exFAT)
        ((d as AnyObject as? NSDictionary)?["DAProcessID"] as? NSNumber).map { pid_t($0.int32Value) }.flatMap { $0 > 0 ? $0 : nil }
    }
    func next() {
        guard let w = queue.popLast() else {
            let box = Box { _, dis in
                if let dis { completion(.busy(pid: dissenterPID(dis), status: DADissenterGetStatus(dis), step: "eject")) } else { completion(.ejected) }
            }
            DADiskEject(phys, DADiskEjectOptions(kDADiskEjectOptionDefault), { d, dis, ctx in
                Unmanaged<Box>.fromOpaque(ctx!).takeRetainedValue().fn(d, dis)
            }, Unmanaged.passRetained(box).toOpaque())
            return
        }
        let box = Box { _, dis in
            if let dis { completion(.busy(pid: dissenterPID(dis), status: DADissenterGetStatus(dis), step: "unmount")) } else { next() }
        }
        DADiskUnmount(w, opts, { d, dis, ctx in
            Unmanaged<Box>.fromOpaque(ctx!).takeRetainedValue().fn(d, dis)
        }, Unmanaged.passRetained(box).toOpaque())
    }
    next()
}
