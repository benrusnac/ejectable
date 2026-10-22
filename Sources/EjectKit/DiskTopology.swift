import DiskArbitration
import Foundation
import IOKit

/// A mounted volume.
public struct VolumeInfo: Sendable, Hashable, Identifiable {
    /// Mount point, e.g. `/Volumes/EXAMPLE_SSD`.
    public let path: String
    public let name: String
    /// statfs `f_fstypename`: apfs, exfat, hfs, msdos, smbfs, …
    public let fileSystem: String
    /// Not local (`MNT_LOCAL` clear): SMB/AFP/NFS share. Has no BSD disk.
    public let isNetwork: Bool
    /// `volumeIsInternal`. Nil for disk images and SMB; nil counts as external (RECON §6).
    public let isInternal: Bool?
    public let isRootFileSystem: Bool
    public let isBrowsable: Bool
    /// `disk9s1` for local volumes (also for snapshot mounts, `…@/dev/disk9s1`), nil for network shares.
    public let bsdName: String?

    public init(path: String, name: String, fileSystem: String, isNetwork: Bool, isInternal: Bool?,
                isRootFileSystem: Bool, isBrowsable: Bool, bsdName: String?) {
        self.path = path; self.name = name; self.fileSystem = fileSystem; self.isNetwork = isNetwork
        self.isInternal = isInternal; self.isRootFileSystem = isRootFileSystem; self.isBrowsable = isBrowsable
        self.bsdName = bsdName
    }

    public var id: String { path }
    public var url: URL { URL(fileURLWithPath: path, isDirectory: true) }
    /// Under `/System/Volumes` (Data, Preboot, VM, …) or `/` itself.
    public var isSystemVolume: Bool { path == "/" || path == "/System/Volumes" || path.hasPrefix("/System/Volumes/") }
    /// Mounted directly under /Volumes (`/Volumes/NAME`), where Finder shows volumes.
    public var isDirectlyUnderVolumes: Bool {
        guard path.hasPrefix("/Volumes/") else { return false }
        let name = path.dropFirst("/Volumes/".count)
        return !name.isEmpty && !name.contains("/")
    }
}

/// The physical whole disk that gets ejected, with everything mounted on it.
public struct PhysicalDisk: Sendable, Hashable {
    /// `disk8` (outermost IOMedia with Whole=true above the volume).
    public let bsdName: String
    /// Internal disk (S5). Primary signal: IOKit `Physical Interconnect Location` ("Internal"/"External", the value
    /// behind diskutil's "Device Location"); when that is absent, `DADeviceInternal` (absent too = internal, fail
    /// safe); disk images ("Virtual Interface") are external. See `DiskTopology.isInternal`.
    public let isInternal: Bool
    /// Raw `DADeviceInternal` (nil for disk images).
    public let deviceInternalKey: Bool?
    /// IOKit `Physical Interconnect Location` from the disk's protocol characteristics: "External", "Internal",
    /// "File" (disk images), nil when absent.
    public let interconnectLocation: String?
    /// Disk image: `DADeviceProtocol == "Virtual Interface"`.
    public let isVirtual: Bool
    public let deviceModel: String?
    public let deviceProtocol: String?
    public let mediaName: String?
    public let mediaSize: UInt64?
    public let isEjectable: Bool?
    public let isRemovable: Bool?
    /// `DAAppearanceTime`: when this disk appeared. Identifies the disk across a BSD-name reuse.
    public let appearanceTime: Double?
    /// Every mounted volume on this disk, including hidden ones and siblings in other containers.
    public let volumes: [VolumeInfo]
    /// Distinct whole disks (APFS synthesized containers, or the physical disk itself for plain
    /// partition schemes) that carry mounted volumes. Each is unmounted with kDADiskUnmountOptionWhole.
    public let containerBSDNames: [String]
    /// The outermost Whole IOMedia under this disk's volumes, i.e. the physical member disks: `[bsdName]` for a
    /// normal disk, several for an AppleRAID/SoftRAID set, a Fusion drive or a multi-store APFS container.
    public let wholeAncestors: [String]

    public var volumePaths: [String] { volumes.map(\.path) }
    /// RAID / Fusion / multi-store: more than one physical member. Not supported yet (refused, S5).
    public var isMultiMember: Bool { wholeAncestors.count > 1 }

    /// The same disk (identity, containers, members) with only the volume mounted at `path` (and nothing if it is not
    /// one of this disk's volumes). What a single-volume unmount scans and flushes.
    public func restricted(toVolumePath path: String) -> PhysicalDisk {
        PhysicalDisk(bsdName: bsdName, isInternal: isInternal, deviceInternalKey: deviceInternalKey, isVirtual: isVirtual,
                     deviceModel: deviceModel, deviceProtocol: deviceProtocol, mediaName: mediaName, mediaSize: mediaSize,
                     isEjectable: isEjectable, isRemovable: isRemovable, appearanceTime: appearanceTime,
                     volumes: volumes.filter { $0.path == path }, containerBSDNames: containerBSDNames,
                     interconnectLocation: interconnectLocation, wholeAncestors: wholeAncestors)
    }

    public init(bsdName: String, isInternal: Bool, deviceInternalKey: Bool?, isVirtual: Bool, deviceModel: String?, deviceProtocol: String?,
                mediaName: String?, mediaSize: UInt64?, isEjectable: Bool?, isRemovable: Bool?, appearanceTime: Double?,
                volumes: [VolumeInfo], containerBSDNames: [String], interconnectLocation: String? = nil,
                wholeAncestors: [String]? = nil) {
        self.bsdName = bsdName; self.isInternal = isInternal; self.deviceInternalKey = deviceInternalKey; self.isVirtual = isVirtual
        self.deviceModel = deviceModel; self.deviceProtocol = deviceProtocol; self.mediaName = mediaName
        self.mediaSize = mediaSize; self.isEjectable = isEjectable; self.isRemovable = isRemovable
        self.appearanceTime = appearanceTime; self.volumes = volumes; self.containerBSDNames = containerBSDNames
        self.interconnectLocation = interconnectLocation
        self.wholeAncestors = wholeAncestors ?? [bsdName]
    }
}

/// One node of the IOKit chain above a volume (for `ejectctl topology`).
public struct IORegistryNode: Sendable, Hashable {
    public let className: String
    public let name: String
    public let bsdName: String?
    public let isWhole: Bool?
    public let content: String?
    public let size: UInt64?
}

/// Read-only queries. Nothing here changes any disk.
public enum DiskTopology {
    static let volumeKeys: [URLResourceKey] = [
        .volumeNameKey, .volumeIsInternalKey, .volumeIsLocalKey, .volumeIsRootFileSystemKey, .volumeIsBrowsableKey,
    ]

    /// Volumes for the menu: mounted directly under /Volumes, browsable (no `nobrowse` mounts: snapshots, simulator
    /// runtimes, …), not the root filesystem or /System/Volumes, and not internal (nil = external). Network shares are
    /// included with `isNetwork`. Built from the kernel mount table (getfsstat MNT_NOWAIT); network mounts are never
    /// stat'ed, so an unresponsive NAS cannot block the caller. Removable/ejectable flags are deliberately not used:
    /// they are false for USB SSDs (RECON §6).
    public static func externalVolumes() -> [VolumeInfo] {
        mountTable().compactMap { entry -> VolumeInfo? in
            var sfs = entry
            let mount = LibProc.string(&sfs.f_mntonname)
            guard sfs.f_flags & UInt32(MNT_DONTBROWSE) == 0, sfs.f_flags & UInt32(MNT_ROOTFS) == 0 else { return nil }
            let v = volumeInfo(statfs: entry)
            guard v.path == mount, v.isDirectlyUnderVolumes, v.isBrowsable, !v.isRootFileSystem, !v.isSystemVolume else { return nil }
            return v.isNetwork || !(v.isInternal ?? false) ? v : nil
        }
    }

    /// Every mounted volume, from the kernel mount table (getfsstat, MNT_NOWAIT: network shares are never stat'ed),
    /// including /System/Volumes/* and other hidden mounts. Used for guards and sibling discovery.
    public static func mountedVolumes() -> [VolumeInfo] {
        mountTable().map { volumeInfo(statfs: $0) }
    }

    /// The volume mounted exactly at `path`, looked up in the mount table: no statfs/stat on the path itself, so this
    /// is safe for network shares. Nil if nothing is mounted there.
    public static func mountedVolume(atPath path: String) -> VolumeInfo? {
        for entry in mountTable() {
            var sfs = entry
            if LibProc.string(&sfs.f_mntonname) == path { return volumeInfo(statfs: entry) }
        }
        return nil
    }

    /// True when `path` is itself a mount point (plain statfs, no URL resource caches). A leftover /Volumes/X
    /// directory statfs'es to the boot volume and is not one.
    public static func isMountPoint(_ path: String) -> Bool {
        var sfs = statfs()
        guard statfs(path, &sfs) == 0 else { return false }
        return LibProc.string(&sfs.f_mntonname) == path
    }

    /// Kernel mount table without blocking on unresponsive network filesystems.
    static func mountTable() -> [statfs] {
        let count = getfsstat(nil, 0, MNT_NOWAIT)
        guard count > 0 else { return [] }
        var buf: [statfs] = Array(repeating: statfs(), count: Int(count) + 8)
        let n = buf.withUnsafeMutableBufferPointer {
            getfsstat($0.baseAddress, Int32($0.count * MemoryLayout<statfs>.stride), MNT_NOWAIT)
        }
        return n > 0 ? Array(buf.prefix(Int(n))) : []
    }

    /// The volume containing `path` (statfs on the path: may block on an unresponsive network share; for shares use
    /// `mountedVolume(atPath:)`).
    public static func volumeInfo(path: String) -> VolumeInfo? {
        var sfs = statfs()
        guard statfs(path, &sfs) == 0 else { return nil }
        return volumeInfo(statfs: sfs)
    }

    /// Resource values are only read for local mounts; network mounts are described from statfs alone.
    static func volumeInfo(statfs entry: statfs) -> VolumeInfo {
        var sfs = entry
        let mount = LibProc.string(&sfs.f_mntonname)
        let from = LibProc.string(&sfs.f_mntfromname)
        let fsType = LibProc.string(&sfs.f_fstypename)
        let isLocal = sfs.f_flags & UInt32(MNT_LOCAL) != 0
        let rv = isLocal ? try? URL(fileURLWithPath: mount, isDirectory: true).resourceValues(forKeys: Set(volumeKeys)) : nil
        return VolumeInfo(
            path: mount,
            name: rv?.volumeName ?? (mount as NSString).lastPathComponent,
            fileSystem: fsType,
            isNetwork: !isLocal,
            isInternal: rv?.volumeIsInternal,
            isRootFileSystem: rv?.volumeIsRootFileSystem ?? (sfs.f_flags & UInt32(MNT_ROOTFS) != 0),
            isBrowsable: (sfs.f_flags & UInt32(MNT_DONTBROWSE) == 0) && (rv?.volumeIsBrowsable ?? true),
            bsdName: isLocal ? bsdName(mountedFrom: from) : nil)
    }

    /// `/dev/disk9s1` -> disk9s1; snapshot and Time Machine mounts (`com.apple.TimeMachine.…@/dev/disk9s1`) -> disk9s1.
    static func bsdName(mountedFrom from: String) -> String? {
        let dev: Substring
        if from.hasPrefix("/dev/disk") {
            dev = from.dropFirst(5)
        } else if let at = from.range(of: "@/dev/disk", options: .backwards) {
            dev = from[at.lowerBound...].dropFirst(6)
        } else {
            return nil
        }
        return dev.range(of: #"^disk[0-9]+(s[0-9]+)*$"#, options: .regularExpression) != nil ? String(dev) : nil
    }

    /// Debug builds: DiskArbitration / IOKit lookups never run on the main thread (a wedged disk would stall the menu
    /// and every alert). The app reads `VolumeMonitor`'s snapshots instead. Not checked in release builds.
    @inline(__always) static func assertOffMain() {
        #if DEBUG
        dispatchPrecondition(condition: .notOnQueue(.main))
        #endif
    }

    /// Mount points in the kernel mount table (getfsstat MNT_NOWAIT: no statfs of any path, never blocks).
    public static func mountedPaths() -> Set<String> {
        Set(mountTable().map { entry -> String in var e = entry; return LibProc.string(&e.f_mntonname) })
    }

    /// The physical disk under a mounted volume (IOKit `Whole=true` walk). Nil for network shares. Not on the main
    /// thread (debug builds check).
    public static func physicalDisk(forVolume path: String) -> PhysicalDisk? {
        assertOffMain()
        guard let session = DASessionCreate(kCFAllocatorDefault),
              let vol = DADiskCreateFromVolumePath(kCFAllocatorDefault, session, URL(fileURLWithPath: path) as CFURL),
              let phys = physicalBSDName(volumeDisk: vol) else { return nil }
        return physicalDisk(bsdName: phys, session: session)
    }

    /// Fresh description of a physical whole disk by BSD name, or nil if it is not (or no longer) one. Not on the main
    /// thread (debug builds check).
    public static func physicalDisk(bsdName: String) -> PhysicalDisk? {
        assertOffMain()
        guard let session = DASessionCreate(kCFAllocatorDefault) else { return nil }
        return physicalDisk(bsdName: bsdName, session: session)
    }

    static func physicalDisk(bsdName: String, session: DASession) -> PhysicalDisk? {
        guard let disk = DADiskCreateFromBSDName(kCFAllocatorDefault, session, bsdName),
              let desc = DADiskCopyDescription(disk) as? [String: Any],
              (desc[kDADiskDescriptionMediaWholeKey as String] as? Bool) == true,
              physicalBSDName(volumeDisk: disk) == bsdName else { return nil }   // must itself be the outermost whole

        var volumes: [VolumeInfo] = []
        var containers: [String] = []
        var roots = Set<String>()
        for v in mountedVolumes() where !v.isNetwork {
            guard let vb = v.bsdName, let d = DADiskCreateFromBSDName(kCFAllocatorDefault, session, vb) else { continue }
            let members = wholeRoots(disk: d)
            guard members.first == bsdName else { continue }
            volumes.append(v)
            roots.formUnion(members)
            if let w = DADiskCopyWholeDisk(d), let wb = DADiskGetBSDName(w) {
                let name = String(cString: wb)
                if !containers.contains(name) { containers.append(name) }
            }
        }
        let model = (desc[kDADiskDescriptionDeviceModelKey as String] as? String)?.trimmingCharacters(in: .whitespaces)
        let proto = desc[kDADiskDescriptionDeviceProtocolKey as String] as? String
        let isVirtual = proto == "Virtual Interface"
        let internalKey = desc[kDADiskDescriptionDeviceInternalKey as String] as? Bool
        let location = interconnectLocation(disk: disk)
        return PhysicalDisk(
            bsdName: bsdName,
            isInternal: isInternal(location: location, deviceInternal: internalKey, isVirtual: isVirtual),
            deviceInternalKey: internalKey,
            isVirtual: isVirtual,
            deviceModel: model,
            deviceProtocol: proto,
            mediaName: desc[kDADiskDescriptionMediaNameKey as String] as? String,
            mediaSize: (desc[kDADiskDescriptionMediaSizeKey as String] as? NSNumber)?.uint64Value,
            isEjectable: desc[kDADiskDescriptionMediaEjectableKey as String] as? Bool,
            isRemovable: desc[kDADiskDescriptionMediaRemovableKey as String] as? Bool,
            appearanceTime: appearanceTime(desc),
            volumes: volumes,
            containerBSDNames: containers,
            interconnectLocation: location,
            wholeAncestors: roots.isEmpty ? [bsdName] : roots.sorted(by: bsdOrder))
    }

    /// S5 internal test. Disk images ("Virtual Interface") are external. Otherwise the IOKit interconnect location
    /// decides ("External" / "Internal"); when it is absent, `DADeviceInternal == false` means external; anything
    /// else (absent key, unknown location) counts as internal (fail safe).
    public static func isInternal(location: String?, deviceInternal: Bool?, isVirtual: Bool) -> Bool {
        if isVirtual { return false }
        switch location {
        case "External"?: return false
        case "Internal"?: return true
        case nil: return deviceInternal ?? true
        default: return true
        }
    }

    static func appearanceTime(_ desc: [String: Any]) -> Double? { (desc["DAAppearanceTime"] as? NSNumber)?.doubleValue }

    /// `DAAppearanceTime` of the disk currently named `bsdName` (nil if there is none).
    static func appearanceTime(bsdName: String, session: DASession) -> Double? {
        guard let d = DADiskCreateFromBSDName(kCFAllocatorDefault, session, bsdName),
              let desc = DADiskCopyDescription(d) as? [String: Any] else { return nil }
        return appearanceTime(desc)
    }

    /// `Physical Interconnect Location` from the nearest "Protocol Characteristics" above the disk's media (or the
    /// bare property, which disk images carry).
    static func interconnectLocation(disk: DADisk) -> String? {
        let media = DADiskCopyIOMedia(disk)
        guard media != 0 else { return nil }
        defer { IOObjectRelease(media) }
        let options = IOOptionBits(kIORegistryIterateParents | kIORegistryIterateRecursively)
        if let pc = IORegistryEntrySearchCFProperty(media, kIOServicePlane, "Protocol Characteristics" as CFString,
                                                    kCFAllocatorDefault, options) as? [String: Any],
           let loc = pc["Physical Interconnect Location"] as? String {
            return loc
        }
        return IORegistryEntrySearchCFProperty(media, kIOServicePlane, "Physical Interconnect Location" as CFString,
                                               kCFAllocatorDefault, options) as? String
    }

    /// The physical whole disk above a volume (or a whole disk): the first of `wholeRoots`.
    static func physicalBSDName(volumeDisk: DADisk) -> String? {
        wholeRoots(disk: volumeDisk).first
            ?? DADiskCopyWholeDisk(volumeDisk).flatMap { DADiskGetBSDName($0).map { String(cString: $0) } }
    }

    /// Every outermost IOMedia with Whole=true above the disk's media, i.e. Whole media with no Whole media above
    /// them (APFS: disk9s1 -> disk9 (synthesized) -> disk8s2 -> disk8 gives [disk8]). One entry for a normal disk,
    /// several for RAID / Fusion / multi-store containers. Sorted by BSD number.
    static func wholeRoots(disk: DADisk) -> [String] {
        let media = DADiskCopyIOMedia(disk)
        guard media != 0 else { return [] }
        defer { IOObjectRelease(media) }
        var memo: [UInt64: Set<String>] = [:]
        func roots(_ e: io_registry_entry_t, depth: Int) -> Set<String> {
            var id: UInt64 = 0
            IORegistryEntryGetRegistryEntryID(e, &id)
            if let known = memo[id] { return known }
            var above = Set<String>()
            var it: io_iterator_t = 0
            if depth < 64, IORegistryEntryGetParentIterator(e, kIOServicePlane, &it) == KERN_SUCCESS {
                while case let p = IOIteratorNext(it), p != 0 {
                    above.formUnion(roots(p, depth: depth + 1))
                    IOObjectRelease(p)
                }
                IOObjectRelease(it)
            }
            var result = above
            if above.isEmpty, isWholeMedia(e), let bsd = property(e, "BSD Name") as? String { result = [bsd] }
            memo[id] = result
            return result
        }
        return roots(media, depth: 0).sorted(by: bsdOrder)
    }

    /// disk2 < disk10 (numeric, not lexical).
    static func bsdOrder(_ a: String, _ b: String) -> Bool {
        a.compare(b, options: .numeric) == .orderedAscending
    }

    /// The IOService-plane ancestry of a volume's media, nearest first.
    public static func ioRegistryChain(forVolume path: String) -> [IORegistryNode] {
        assertOffMain()
        guard let session = DASessionCreate(kCFAllocatorDefault),
              let vol = DADiskCreateFromVolumePath(kCFAllocatorDefault, session, URL(fileURLWithPath: path) as CFURL) else { return [] }
        let media = DADiskCopyIOMedia(vol)
        guard media != 0 else { return [] }
        defer { IOObjectRelease(media) }
        var nodes = [node(media)]
        var it: io_iterator_t = 0
        guard IORegistryEntryCreateIterator(media, kIOServicePlane,
                                            IOOptionBits(kIORegistryIterateParents | kIORegistryIterateRecursively), &it) == KERN_SUCCESS
        else { return nodes }
        defer { IOObjectRelease(it) }
        while case let e = IOIteratorNext(it), e != 0 {
            defer { IOObjectRelease(e) }
            nodes.append(node(e))
        }
        return nodes
    }

    static func node(_ e: io_registry_entry_t) -> IORegistryNode {
        var cls = [CChar](repeating: 0, count: 128)
        var nm = [CChar](repeating: 0, count: 128)
        IOObjectGetClass(e, &cls)
        IORegistryEntryGetName(e, &nm)
        let isMedia = IOObjectConformsTo(e, "IOMedia") != 0
        return IORegistryNode(
            className: LibProc.string(array: cls), name: LibProc.string(array: nm),
            bsdName: property(e, "BSD Name") as? String,
            isWhole: isMedia ? (property(e, "Whole") as? Bool) : nil,
            content: isMedia ? (property(e, "Content") as? String) : nil,
            size: isMedia ? (property(e, "Size") as? NSNumber)?.uint64Value : nil)
    }

    static func isWholeMedia(_ e: io_registry_entry_t) -> Bool {
        IOObjectConformsTo(e, "IOMedia") != 0 && (property(e, "Whole") as? Bool) == true
    }

    static func property(_ e: io_registry_entry_t, _ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(e, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }
}
