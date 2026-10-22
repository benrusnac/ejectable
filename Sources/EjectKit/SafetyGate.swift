import Foundation

/// Something that makes Force Eject unavailable (S2). The UI disables the button and shows `message`.
public struct ForceBlocker: Sendable, Hashable, CustomStringConvertible {
    public enum Kind: String, Sendable, Hashable {
        /// A same-user holder has a file open for writing or mapped writable.
        case writer
        /// Time Machine is backing up and this disk is (or may be) a destination.
        case timeMachine
        /// Time Machine's state could not be read: fail closed (S2).
        case timeMachineUnknown
        /// A known copy/encode tool holds files on the disk.
        case copyTool
        /// The last holder scan did not finish (deadline, a process stuck in the kernel): holders may be missing.
        case scanIncomplete
    }

    public let kind: Kind
    public let pid: pid_t?
    public let name: String
    public let path: String?

    public init(kind: Kind, pid: pid_t?, name: String, path: String?) {
        self.kind = kind; self.pid = pid; self.name = name; self.path = path
    }

    public var fileName: String? { path.map { ($0 as NSString).lastPathComponent } }

    /// "duhold is writing fdw.txt" / "Time Machine is backing up to this disk" / "rsync is copying clip.mov".
    public var message: String {
        switch kind {
        case .writer: "\(name) is writing \(fileName ?? "a file")"
        case .timeMachine: "Time Machine is backing up to this disk"
        case .timeMachineUnknown: "Time Machine\u{2019}s status couldn\u{2019}t be checked"
        case .copyTool: "\(name) is copying \(fileName ?? "files")"
        case .scanIncomplete: "Ejectable couldn\u{2019}t check every process"
        }
    }

    public var description: String { message }
}

/// A non-blocking warning shown in the Force Eject confirmation.
public struct ForceRisk: Sendable, Hashable, CustomStringConvertible {
    public enum Kind: String, Sendable, Hashable {
        /// Force-unmounting under a mapping crashes the holder with SIGBUS on its next page touch (RECON §3).
        case mappedFile
        /// Open read-only file: the holder gets read errors.
        case openFile
        /// Process we cannot inspect (root / other user, or a daemon).
        case uninspectable
    }

    public let kind: Kind
    public let pid: pid_t
    public let name: String
    public let path: String?

    public init(kind: Kind, pid: pid_t, name: String, path: String?) {
        self.kind = kind; self.pid = pid; self.name = name; self.path = path
    }

    public var message: String {
        let file = path.map { ($0 as NSString).lastPathComponent } ?? "files"
        return switch kind {
        case .mappedFile: "\(name) has media mapped in memory and may crash"
        case .openFile: "\(name) loses access to \(file)"
        case .uninspectable: "\(name) is a system process Ejectable can\u{2019}t inspect"
        }
    }

    public var description: String { message }
}

/// Time Machine facts that gate Force Eject. `current(for:)` spawns tmutil: background or a user click only.
/// Unknown values fail closed (S2): Force Eject stays disabled.
public struct TimeMachineFacts: Sendable, Hashable {
    /// nil = `tmutil status` could not be run or parsed.
    public var backupRunning: Bool?
    /// nil = unknown (only looked up while a backup runs).
    public var diskIsDestination: Bool?

    public init(backupRunning: Bool?, diskIsDestination: Bool?) {
        self.backupRunning = backupRunning; self.diskIsDestination = diskIsDestination
    }

    public static let idle = TimeMachineFacts(backupRunning: false, diskIsDestination: false)
    public static let unknown = TimeMachineFacts(backupRunning: nil, diskIsDestination: nil)

    /// The blocker these facts imply, if any (fail closed on unknown state).
    public var blocker: ForceBlocker? {
        guard let running = backupRunning else {
            return ForceBlocker(kind: .timeMachineUnknown, pid: nil, name: "Time Machine", path: nil)
        }
        guard running, diskIsDestination != false else { return nil }
        return ForceBlocker(kind: .timeMachine, pid: nil, name: "Time Machine", path: nil)
    }

    /// `tmutil status` (~10 ms), and only while a backup runs, `tmutil destinationinfo -X`. Spawns processes:
    /// never on the main thread.
    public static func current(for disk: PhysicalDisk) -> TimeMachineFacts {
        facts(SystemState.timeMachineState(), diskVolumePaths: disk.volumePaths)
    }

    /// Pure mapping from tmutil's answer to the facts for one disk. nil state = unknown (fail closed).
    public static func facts(_ state: SystemState.TimeMachineState?, diskVolumePaths: [String]) -> TimeMachineFacts {
        guard let state else { return .unknown }
        guard state.backupRunning else { return .idle }
        guard let dests = state.destinations else { return TimeMachineFacts(backupRunning: true, diskIsDestination: nil) }
        let uuids = diskVolumePaths.compactMap {
            try? URL(fileURLWithPath: $0).resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString
        }
        return TimeMachineFacts(
            backupRunning: true,
            diskIsDestination: isDestination(diskVolumePaths: diskVolumePaths, diskVolumeUUIDs: uuids,
                                             destinationMountPoints: dests.compactMap(\.mountPoint),
                                             destinationVolumeUUIDs: dests.compactMap(\.volumeUUID)))
    }

    /// Pure: does any destination's mount point or volume UUID belong to this disk?
    public static func isDestination(diskVolumePaths: [String], diskVolumeUUIDs: [String],
                                     destinationMountPoints: [String], destinationVolumeUUIDs: [String]) -> Bool {
        let paths = Set(diskVolumePaths.map { URL(fileURLWithPath: $0).standardizedFileURL.path })
        if destinationMountPoints.contains(where: { paths.contains(URL(fileURLWithPath: $0).standardizedFileURL.path) }) { return true }
        let uuids = Set(diskVolumeUUIDs.map { $0.uppercased() })
        return destinationVolumeUUIDs.contains { uuids.contains($0.uppercased()) }
    }
}

/// S2: decides whether Force Eject may be offered. Pure functions over holders and facts.
public enum SafetyGate {
    /// Copy / encode tools: executable names (exact) and display-name / bundle-id prefixes.
    public static let copyToolExecutables: Set<String> = [
        "cp", "mv", "rsync", "openrsync", "rsync.openrsync", "rsync.samba", "ditto", "scp", "sftp",
        "ffmpeg", "HandBrakeCLI", "HandBrake", "Compressor", "CompressorTranscoderX",
    ]
    public static let copyToolNamePrefixes = ["Adobe Media Encoder", "Compressor", "HandBrake"]
    public static let copyToolBundlePrefixes = ["com.adobe.ame", "com.apple.Compressor", "fr.handbrake."]

    public static func isCopyTool(_ h: Holder) -> Bool {
        let exe = (h.executablePath as NSString).lastPathComponent
        if copyToolExecutables.contains(exe) || copyToolExecutables.contains(h.displayName) { return true }
        if copyToolNamePrefixes.contains(where: { h.displayName.hasPrefix($0) || exe.hasPrefix($0) }) { return true }
        if let id = h.bundleIdentifier?.lowercased(),
           copyToolBundlePrefixes.contains(where: { id.hasPrefix($0.lowercased()) }) { return true }
        if let parent = h.parentAppBundleURL?.lastPathComponent,
           copyToolNamePrefixes.contains(where: { parent.hasPrefix($0) }) { return true }
        return false
    }

    /// Everything that must disable Force Eject (S2). Empty = Force Eject may be offered (still confirmed).
    /// An incomplete scan blocks (holders may be missing).
    public static func forceEjectBlockers(scan: HolderScan, disk: PhysicalDisk,
                                          timeMachine: TimeMachineFacts) -> [ForceBlocker] {
        forceEjectBlockers(holders: scan.holders, disk: disk, timeMachine: timeMachine, scanIncomplete: scan.incomplete)
    }

    public static func forceEjectBlockers(holders: [Holder], disk: PhysicalDisk, timeMachine: TimeMachineFacts,
                                          scanIncomplete: Bool = false) -> [ForceBlocker] {
        var out: [ForceBlocker] = []
        if scanIncomplete { out.append(ForceBlocker(kind: .scanIncomplete, pid: nil, name: "Ejectable", path: nil)) }
        for h in holders {
            let writes = h.reasons.filter(\.isWrite)
            for r in writes { out.append(ForceBlocker(kind: .writer, pid: h.pid, name: h.displayName, path: r.path)) }
            if writes.isEmpty, isCopyTool(h),
               let file = h.reasons.first(where: { if case .workingDirectory = $0 { false } else if case .rootDirectory = $0 { false } else { true } }) {
                out.append(ForceBlocker(kind: .copyTool, pid: h.pid, name: h.displayName, path: file.path))
            }
        }
        if let tm = timeMachine.blocker { out.append(tm) }
        return out
    }

    /// Non-blocking warnings for the confirmation: mapped media may crash, open files lose access, system
    /// processes we cannot inspect. Writers are not listed here (they are blockers).
    public static func forceEjectRisks(scan: HolderScan) -> [ForceRisk] { forceEjectRisks(holders: scan.holders) }

    public static func forceEjectRisks(holders: [Holder]) -> [ForceRisk] {
        var out: [ForceRisk] = []
        for h in holders {
            if case .inaccessible = h.kind {
                out.append(ForceRisk(kind: .uninspectable, pid: h.pid, name: h.displayName, path: nil)); continue
            }
            if let mapped = h.reasons.first(where: { if case .mappedFile(_, false) = $0 { true } else { false } }) {
                out.append(ForceRisk(kind: .mappedFile, pid: h.pid, name: h.displayName, path: mapped.path))
            }
            for r in h.reasons { if case .openFile(let p, false) = r {
                out.append(ForceRisk(kind: .openFile, pid: h.pid, name: h.displayName, path: p))
            } }
            if case .daemon = h.kind, h.reasons.isEmpty {
                out.append(ForceRisk(kind: .uninspectable, pid: h.pid, name: h.displayName, path: nil))
            }
        }
        return out
    }
}

/// The one-line verdict shown next to Force Eject… (S2): blocked (red, button disabled), risky (orange) or safe (green).
public enum ForceRating: Sendable, Hashable, CustomStringConvertible {
    /// Nothing writes to the drive and nothing has media mapped. `except`: rebuildable metadata writers that may be
    /// cut off (Spotlight's index, the file events log).
    case safe(except: [String])
    /// Force Eject is available but something may crash or lose data: short reasons ("media mapped by duhold").
    case risky([String])
    /// Force Eject is unavailable (S2 blockers).
    case blocked([ForceBlocker])

    public var text: String { text(verb: "eject") }

    /// `verb`: "eject", or "unmount" for a single-volume flow ("Force Unmount is safe: …").
    public func text(verb: String) -> String {
        let force = "Force \(verb.capitalized)"
        return switch self {
        case .safe(let except) where except.isEmpty: "\(force) is safe: nothing is writing to this drive"
        case .safe(let except): "\(force) is safe: nothing is writing to this drive except \(SafetyGate.list(except))"
        case .risky(let reasons): "\(force) is risky: \(reasons.joined(separator: "; "))"
        case .blocked(let b): "\(force) is unavailable: \(b.map(\.message).joined(separator: "; "))"
        }
    }

    public var isBlocked: Bool { if case .blocked = self { true } else { false } }
    public var description: String { text }
}

extension SafetyGate {
    /// System processes a forced unmount cannot harm: they only keep rebuildable metadata (Spotlight index, FSEvents
    /// log) or read-only previews (Quick Look). Seen without reasons (root / other uid), they are not a risk.
    public static let forceSafeSystemExecutables: Set<String> = Set([
        "mds", "mds_stores", "mdworker", "mdworker_shared", "mdsync", "mdbulkimport", "corespotlightd", "fseventsd",
    ]).union(Remedies.quickLookExecutables)

    /// Of those, the ones that write (named in the safe line).
    static let metadataWriterLabels: [String: String] = [
        "mds": "Spotlight", "mds_stores": "Spotlight", "mdworker": "Spotlight", "mdworker_shared": "Spotlight",
        "mdsync": "Spotlight", "mdbulkimport": "Spotlight", "corespotlightd": "Spotlight",
        "fseventsd": "the file events log",
    ]

    /// The verdict for the Force Eject line. `scanComplete`: a full scan finished in time (an incomplete one is also a
    /// blocker). Safe needs no blockers, no mapped files and a complete scan; holders whose files we cannot see
    /// (other-uid processes, or none found at all while the disk is busy) make it risky unless they are known
    /// metadata/preview processes.
    public static func forceRating(holders: [Holder], blockers: [ForceBlocker], scanComplete: Bool) -> ForceRating {
        if !blockers.isEmpty { return .blocked(blockers) }
        if !scanComplete { return .blocked([ForceBlocker(kind: .scanIncomplete, pid: nil, name: "Ejectable", path: nil)]) }
        var reasons: [String] = []
        let mappers = holders.filter(\.hasMappedFiles)
        if !mappers.isEmpty { reasons.append("media mapped by \(list(unique(mappers.map(\.displayName))))") }
        let unseen = holders.filter { h in
            let exe = (h.executablePath as NSString).lastPathComponent.nilIfEmpty ?? h.displayName
            return h.reasons.isEmpty && !forceSafeSystemExecutables.contains(exe)
        }
        if !unseen.isEmpty {
            let names = unique(unseen.map(\.displayName))
            reasons.append(names.count == 1 ? "\(names[0]) can\u{2019}t be inspected"
                                            : "\(names.count) system processes can\u{2019}t be inspected")
        }
        if holders.isEmpty { reasons.append("something Ejectable can\u{2019}t see is using it") }
        if !reasons.isEmpty { return .risky(reasons) }
        let writers = holders.compactMap { metadataWriterLabels[(($0.executablePath as NSString).lastPathComponent.nilIfEmpty ?? $0.displayName)] }
        return .safe(except: unique(writers))
    }

    static func unique(_ names: [String]) -> [String] {
        var seen = Set<String>()
        return names.filter { seen.insert($0).inserted }
    }

    /// "a", "a and b", "a, b and c".
    static func list(_ items: [String]) -> String {
        guard items.count > 1 else { return items.first ?? "" }
        return items.dropLast().joined(separator: ", ") + " and " + items.last!
    }
}
