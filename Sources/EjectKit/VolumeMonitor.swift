import DiskArbitration
import Foundation

/// One external volume for the menu, with the physical disk under it (nil for network shares, or when the topology
/// could not be resolved). Computed on the monitor's background queue: the app never resolves topology on the main
/// thread (DiskArbitration / IOKit / statfs on a wedged drive would stall the menu and every alert).
public struct MonitoredVolume: Sendable, Hashable, Identifiable {
    public let volume: VolumeInfo
    public let disk: PhysicalDisk?
    public var id: String { volume.path }
    public init(volume: VolumeInfo, disk: PhysicalDisk?) { self.volume = volume; self.disk = disk }
}

/// External volumes (local + network) for the menu, refreshed on mount / unmount / rename. No polling.
///
/// S7: deliberately NO NSWorkspace notification observers. Observing NSWorkspace mount notifications makes AppKit open
/// its own DiskArbitration session in this process with an *unmount approval* callback (it backs
/// willUnmountNotification) that is answered on the main thread: any main-thread stall (a TCC prompt, a modal, a hung
/// subprocess) would then stall every unmount on the Mac until DA gives up (~10 s), and once the last observer is
/// removed that approver never answers again. Instead:
///  - local disks: a private DiskArbitration session on its own serial queue with disk appeared / disappeared /
///    description changed (volume path, volume name) callbacks. These are notifications: DA never waits for them.
///  - network shares, which DiskArbitration does not see: the kernel's mount-table events (kqueue EVFILT_FS: VQ_MOUNT,
///    VQ_UNMOUNT, VQ_UPDATE), which fire for every filesystem type, followed by a getfsstat(MNT_NOWAIT) re-read.
/// Bursts (an APFS container mounting several volumes) are coalesced; the list AND each local volume's physical disk
/// are rebuilt on the private queue (never stat'ing a network share) and published on the main thread as a snapshot
/// (`entries`) when it changed. The main thread only ever reads the cached snapshot.
@MainActor
public final class VolumeMonitor {
    public static let shared = VolumeMonitor()

    /// The last snapshot: every external volume with its physical disk. Empty until the first background refresh.
    public private(set) var entries: [MonitoredVolume] = []
    public var volumes: [VolumeInfo] { entries.map(\.volume) }
    /// Called on the main thread after a mount/unmount/rename changed the snapshot.
    public var onChange: (@MainActor ([VolumeInfo]) -> Void)?

    private let source: Source

    private init() {
        source = Source { list in
            Task { @MainActor in VolumeMonitor.shared.apply(list) }
        }
        source.start()
    }

    /// The cached entry for a mount point (no I/O).
    public func entry(forPath path: String) -> MonitoredVolume? { entries.first { $0.volume.path == path } }

    /// Re-read the snapshot now (on the background queue); `onChange` follows if it changed.
    public func refresh() { source.refreshSoon() }

    /// Counters for diagnostics: DA notifications and kernel mount events received, refreshes done.
    public nonisolated var stats: (diskEvents: Int, mountEvents: Int, refreshes: Int) { source.stats }

    private func apply(_ list: [MonitoredVolume]) {
        guard list != entries else { return }
        entries = list
        onChange?(volumes)
    }

    /// Off the main thread: the external volumes and the physical disk of each local one (one topology lookup per disk).
    nonisolated static func snapshot() -> [MonitoredVolume] {
        var disks: [PhysicalDisk] = []
        return DiskTopology.externalVolumes().map { v in
            guard !v.isNetwork else { return MonitoredVolume(volume: v, disk: nil) }
            if let known = disks.first(where: { d in d.volumes.contains { $0.path == v.path && $0.bsdName == v.bsdName } }) {
                return MonitoredVolume(volume: v, disk: known)
            }
            let d = DiskTopology.physicalDisk(forVolume: v.path)
            if let d { disks.append(d) }
            return MonitoredVolume(volume: v, disk: d)
        }
    }
}

/// The off-main part of `VolumeMonitor`: DA session + kqueue on one private serial queue. Lives for the process.
private final class Source: @unchecked Sendable {   // mutable state only touched on `queue`
    let queue = DispatchQueue(label: "com.benrusnac.ejectable.volumes", qos: .utility)
    private let deliver: @Sendable ([MonitoredVolume]) -> Void
    private var last: [MonitoredVolume]?
    private var scheduled = false
    private var session: DASession?
    private var kqueueSource: DispatchSourceRead?
    private let counters = NSLock()
    private var diskEvents = 0, mountEvents = 0, refreshes = 0
    private static let coalesce: TimeInterval = 0.25

    init(deliver: @escaping @Sendable ([MonitoredVolume]) -> Void) {
        self.deliver = deliver
    }

    var stats: (diskEvents: Int, mountEvents: Int, refreshes: Int) { counters.withLock { (diskEvents, mountEvents, refreshes) } }

    // Notification callbacks (DA does not wait for an answer). Context = unretained self: Source lives for the process.
    private let appeared: DADiskAppearedCallback = { _, ctx in
        if let ctx { Unmanaged<Source>.fromOpaque(ctx).takeUnretainedValue().diskEvent() }
    }
    private let disappeared: DADiskDisappearedCallback = { _, ctx in
        if let ctx { Unmanaged<Source>.fromOpaque(ctx).takeUnretainedValue().diskEvent() }
    }
    private let changed: DADiskDescriptionChangedCallback = { _, _, ctx in
        if let ctx { Unmanaged<Source>.fromOpaque(ctx).takeUnretainedValue().diskEvent() }
    }

    func start() {
        queue.async { [self] in
            let ctx = Unmanaged.passUnretained(self).toOpaque()
            if let s = DASessionCreate(kCFAllocatorDefault) {
                let volumes = [kDADiskDescriptionVolumeMountableKey as String: true] as CFDictionary
                DARegisterDiskAppearedCallback(s, volumes, appeared, ctx)
                DARegisterDiskDisappearedCallback(s, volumes, disappeared, ctx)
                DARegisterDiskDescriptionChangedCallback(
                    s, volumes, [kDADiskDescriptionVolumePathKey, kDADiskDescriptionVolumeNameKey] as CFArray, changed, ctx)
                DASessionSetDispatchQueue(s, queue)
                session = s
            }
            let kq = kqueue()
            guard kq >= 0 else { return }
            var ev = kevent(ident: 0, filter: Int16(EVFILT_FS), flags: UInt16(EV_ADD | EV_CLEAR), fflags: 0, data: 0, udata: nil)
            guard kevent(kq, &ev, 1, nil, 0, nil) == 0 else { close(kq); return }
            let src = DispatchSource.makeReadSource(fileDescriptor: kq, queue: queue)
            src.setEventHandler { [weak self] in self?.drain(kq) }
            src.setCancelHandler { close(kq) }
            src.resume()
            kqueueSource = src
        }
        queue.async { [self] in rebuild() }                // first snapshot, off the main thread
    }

    func refreshSoon() { queue.async { [self] in schedule() } }

    private func diskEvent() {
        counters.withLock { diskEvents += 1 }
        schedule()
    }

    private func drain(_ kq: Int32) {
        var events: [kevent] = Array(repeating: kevent(ident: 0, filter: 0, flags: 0, fflags: 0, data: 0, udata: nil), count: 16)
        var zero = timespec(tv_sec: 0, tv_nsec: 0)
        let n = kevent(kq, nil, 0, &events, Int32(events.count), &zero)
        guard n > 0 else { return }
        let relevant = events.prefix(Int(n)).contains { $0.fflags & UInt32(VQ_MOUNT | VQ_UNMOUNT | VQ_UPDATE) != 0 }
        counters.withLock { mountEvents += Int(n) }
        if relevant { schedule() }
    }

    private func schedule() {
        guard !scheduled else { return }
        scheduled = true
        queue.asyncAfter(deadline: .now() + Source.coalesce) { [self] in
            scheduled = false
            rebuild()
        }
    }

    private func rebuild() {
        let list = VolumeMonitor.snapshot()
        counters.withLock { refreshes += 1 }
        guard list != last else { return }
        last = list
        deliver(list)
    }
}
