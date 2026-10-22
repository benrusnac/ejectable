import EjectKit
import Foundation

// ejectctl: CLI harness for EjectKit.
//   ejectctl volumes
//   ejectctl scan <volumePath> [--unchecked]       scans every volume on that volume's physical disk
//                                                  (--unchecked: hand the path to HolderScanner as given, to exercise
//                                                  its own mount-point guard)
//   ejectctl eject <volumePath> [--force] [--real] [--i-understand]
//                                                  refuses anything but a disk image without --real (S5). A forced
//                                                  eject of a real disk scans first, refuses on S2 blockers (writers,
//                                                  writable mappings, Time Machine running/unknown, incomplete scan)
//                                                  unless --i-understand, and asks y/N listing the holders.
//   ejectctl topology <volumePath>
//   ejectctl disk <bsdName>                        read-only: location / internal / members / S5 verdicts
//   ejectctl state [volumePath]                    Time Machine / Spotlight facts (spawns tmutil, mdutil)
//   ejectctl watch [--no-idle-callback] [--timeout <s>] [--stop-after <s>]
//                                                  print foreign unmount/eject attempts (EjectWatcher) until Ctrl-C

func usage() -> Never {
    FileHandle.standardError.write(Data("""
    usage: ejectctl volumes
           ejectctl scan <volumePath> [--unchecked]
           ejectctl eject <volumePath> [--force] [--real] [--i-understand]
           ejectctl topology <volumePath>
           ejectctl disk <bsdName>
           ejectctl state [volumePath]
           ejectctl watch [--no-idle-callback] [--timeout <s>] [--stop-after <s>]

    """.utf8))
    exit(64)
}

func pad(_ s: String, _ n: Int) -> String { s.count >= n ? s : s + String(repeating: " ", count: n - s.count) }
func yn(_ b: Bool?) -> String { b.map { $0 ? "yes" : "no" } ?? "-" }
func ms(_ t: TimeInterval) -> String { String(format: "%.1f ms", t * 1000) }

func fail(_ message: String, _ code: Int32 = 66) -> Never {
    FileHandle.standardError.write(Data("ejectctl: \(message)\n".utf8))
    exit(code)
}

func pathArgument(_ args: [String]) -> String {
    guard let p = args.dropFirst(2).first(where: { !$0.hasPrefix("--") }) else { usage() }
    return p
}

/// The mount point named on the command line. Refuses (before anything else happens) a path that is not itself a
/// mount point, and the boot / system volumes: `/Volumes/Macintosh HD` is a symlink to `/`, a folder on a drive
/// statfs'es to that drive, and a leftover /Volumes/X folder to the boot volume.
func volumePath(_ args: [String], allowSystem: Bool = false) -> String {
    let p = pathArgument(args)
    let given = URL(fileURLWithPath: p).standardizedFileURL.path
    if let v = DiskTopology.mountedVolume(atPath: given) {        // exact mount point: no stat of the path
        if !allowSystem, v.isRootFileSystem || v.isSystemVolume { fail("\(p) is the boot volume or a system volume; refusing") }
        return v.path
    }
    if let real = realpath(given, nil) {
        defer { free(real) }
        let r = String(cString: real)
        if r != given, let v = DiskTopology.mountedVolume(atPath: r) {
            if v.isRootFileSystem || v.isSystemVolume { fail("\(p) resolves to \(r), the boot volume or a system volume; refusing") }
            fail("\(p) is a link to \(r); pass the mount point itself")
        }
        if let v = DiskTopology.volumeInfo(path: r) {
            fail("\(p) is not a mount point (it is a folder on \(v.path)\(v.isRootFileSystem || v.isSystemVolume ? ", the boot volume" : "")); refusing")
        }
    }
    fail("\(p) is not mounted")
}

func printScan(_ s: HolderScan) {
    let scanned = s.scannedTargets.isEmpty ? "nothing (no requested path is a scannable mount point)" : s.scannedTargets.joined(separator: ", ")
    print("scanned \(scanned) in \(ms(s.duration)): \(s.holders.count) holder(s), "
          + "\(s.writers.count) writer(s), \(s.deniedPIDs.count) pids not inspectable (root/other uid)"
          + (s.incomplete ? "; INCOMPLETE: \(s.incompleteReason ?? "?")" : ""))
    guard !s.holders.isEmpty else { return }
    print("  " + pad("PID", 7) + pad("UID", 6) + pad("KIND", 13) + pad("WRITER", 7) + "NAME")
    for h in s.holders {
        print("  " + pad("\(h.pid)", 7) + pad("\(h.uid)", 6) + pad(h.kind.rawValue, 13) + pad(h.isWriter ? "yes" : "-", 7) + h.displayName)
        print("      exe: \(h.executablePath)" + (h.bundleIdentifier.map { "  (\($0))" } ?? ""))
        if let p = h.parentAppBundleURL { print("      app: \(p.path)") }
        for r in h.reasons { print("      \(r)") }
    }
}

func cmdVolumes() {
    let vols = DiskTopology.externalVolumes()
    print(pad("NAME", 16) + pad("PATH", 26) + pad("FS", 7) + pad("TYPE", 9) + pad("DISK", 8) + pad("CONTAINERS", 12)
          + pad("LOCATION", 10) + pad("INTERNAL", 9) + pad("VIRTUAL", 8) + pad("MEMBERS", 9) + "MODEL")
    for v in vols {
        let disk = v.isNetwork ? nil : DiskTopology.physicalDisk(forVolume: v.path)
        print(pad(v.name, 16) + pad(v.path, 26) + pad(v.fileSystem, 7) + pad(v.isNetwork ? "network" : "external", 9)
              + pad(disk?.bsdName ?? "-", 8) + pad(disk.map { $0.containerBSDNames.joined(separator: ",") } ?? "-", 12)
              + pad(disk.map { $0.interconnectLocation ?? "absent" } ?? "-", 10)
              + pad(disk.map { yn($0.isInternal) } ?? "-", 9) + pad(disk.map { yn($0.isVirtual) } ?? "-", 8)
              + pad(disk.map { $0.wholeAncestors.joined(separator: ",") + ($0.isMultiMember ? " RAID" : "") } ?? "-", 9)
              + (disk.map { "\($0.deviceModel ?? "?") / \($0.deviceProtocol ?? "?")" } ?? (v.isNetwork ? "\(v.fileSystem) share" : "-")))
    }
}

func scanTargets(for path: String) -> (disk: PhysicalDisk?, paths: [String]) {
    guard let disk = DiskTopology.physicalDisk(forVolume: path) else { return (nil, [path]) }
    return (disk, disk.volumePaths.isEmpty ? [path] : disk.volumePaths)
}

func cmdScan(_ args: [String]) {
    if args.contains("--unchecked") {                   // the scanner's own guard, without the CLI's
        let p = pathArgument(args)
        print("--unchecked: HolderScanner.scan(volumePaths: [\"\(p)\"])")
        printScan(HolderScanner.scan(volumePaths: [p]))
        return
    }
    let path = volumePath(args)
    let (disk, paths) = scanTargets(for: path)
    if let disk { print("physical disk \(disk.bsdName): \(disk.volumes.count) mounted volume(s)") }
    printScan(HolderScanner.scan(volumePaths: paths))
}

func cmdTopology(_ args: [String]) {
    let path = volumePath(args, allowSystem: true)                  // read-only
    let chain = DiskTopology.ioRegistryChain(forVolume: path)
    if chain.isEmpty { print("\(path): no IOMedia (network share?)") }
    print("IOService chain above \(path) (nearest first):")
    for (i, n) in chain.enumerated() {
        var line = String(repeating: " ", count: min(i, 20)) + "\(n.className) \"\(n.name)\""
        if let b = n.bsdName { line += " bsd=\(b)" }
        if let w = n.isWhole { line += " whole=\(w)" }
        if let c = n.content, !c.isEmpty { line += " content=\(c)" }
        if let s = n.size { line += " size=\(s)" }
        print(line)
    }
    guard let d = DiskTopology.physicalDisk(forVolume: path) else { return }
    print("""
    physical disk: \(d.bsdName)  model=\(d.deviceModel ?? "-")  protocol=\(d.deviceProtocol ?? "-")  media=\(d.mediaName ?? "-")
      internal=\(yn(d.isInternal)) (location=\(d.interconnectLocation ?? "absent"), DADeviceInternal=\(d.deviceInternalKey.map { "\($0)" } ?? "absent")) virtual=\(yn(d.isVirtual)) ejectable=\(yn(d.isEjectable)) removable=\(yn(d.isRemovable)) size=\(d.mediaSize.map(String.init) ?? "-")
      member disks: \(d.wholeAncestors.joined(separator: ", "))\(d.isMultiMember ? " (RAID / multi-disk: not supported)" : "")
      containers to unmount (Whole): \(d.containerBSDNames.joined(separator: ", "))
      volumes: \(d.volumes.map { "\($0.path) [\($0.bsdName ?? "-") \($0.fileSystem)]" }.joined(separator: ", "))
    """)
}

func cmdEject(_ args: [String]) {
    let path = volumePath(args)
    let force = args.contains("--force")
    let policy = EjectPolicy(allowRealDisks: args.contains("--real"))
    let ejector = Ejector()
    let done = DispatchSemaphore(value: 0)
    nonisolated(unsafe) var result: EjectResult = .failed(status: 0, step: .eject(bsdName: "?"))
    let t0 = Date()

    if let v = DiskTopology.mountedVolume(atPath: path), v.isNetwork {
        guard policy.allowRealDisks else {
            print("refused: \(path) is a network share; pass --real to disconnect it"); exit(2)
        }
        ejector.unmountNetworkShare(url: v.url) { result = $0; done.signal() }
    } else {
        guard let disk = DiskTopology.physicalDisk(forVolume: path) else { print("no physical disk for \(path)"); exit(1) }
        print("\(force ? "FORCE " : "")eject \(disk.bsdName) (\(disk.deviceModel ?? "?"), \(disk.isVirtual ? "disk image" : "real disk")): "
              + "unmount \(disk.containerBSDNames.joined(separator: ", ")) then eject \(disk.bsdName); "
              + "\(disk.volumes.count) volume(s): \(disk.volumePaths.joined(separator: ", "))")
        if let refusal = Ejector.safetyCheck(disk, policy: policy) {   // S5 first: nothing is scanned, asked or sent
            print("result: refused: \(refusal) (\(ejector.diskArbitrationRequestCount) DiskArbitration requests sent)")
            exit(2)
        }
        if force && (policy.allowRealDisks || !disk.isVirtual) { confirmForce(disk, args) }
        ejector.eject(disk: disk, force: force, policy: policy) { result = $0; done.signal() }
    }
    if done.wait(timeout: .now() + 90) == .timedOut { print("timed out after 90 s waiting for DiskArbitration"); exit(3) }
    print("result: \(result) after \(Int(Date().timeIntervalSince(t0) * 1000)) ms "
          + "(\(ejector.diskArbitrationRequestCount) DiskArbitration request(s) sent)")

    switch result {
    case .ejected, .volumeUnmounted: exit(0)
    case .unmountedNotEjected:
        print("every volume is unmounted: safe to disconnect")
        exit(0)
    case .refused: exit(2)
    case .failed: exit(1)
    case .busy(let pid, _, _):
        if let pid, let h = HolderResolver.holder(forPID: pid) {
            print("dissenter: \(h.pid) \(h.displayName) [\(h.kind.rawValue)] uid=\(h.uid) \(h.executablePath)")
        } else {
            print("dissenter: unknown (DA reported pid 0: root holder or mmap-only holder)")
        }
        let (_, paths) = scanTargets(for: path)
        printScan(HolderScanner.scan(volumePaths: paths))
        exit(4)
    }
}

/// S2 for a forced eject of a real disk: scan, Time Machine, blockers (refused unless --i-understand), then y/N.
func confirmForce(_ disk: PhysicalDisk, _ args: [String]) {
    let scan = HolderScanner.scan(disk: disk)
    printScan(scan)
    let tm = TimeMachineFacts.current(for: disk)
    let blockers = SafetyGate.forceEjectBlockers(scan: scan, disk: disk, timeMachine: tm)
    let risks = SafetyGate.forceEjectRisks(scan: scan)
    print("time machine: " + (tm.backupRunning.map { $0 ? "backup running\(tm.diskIsDestination == false ? " (another disk)" : "")" : "idle" } ?? "UNKNOWN (tmutil failed)"))
    for r in risks { print("  risk: \(r.message)") }
    if !blockers.isEmpty {
        print("Force eject is blocked (S2): " + blockers.map(\.message).joined(separator: "; "))
        guard args.contains("--i-understand") else {
            print("refused: stop the writers / wait for the backup, or pass --i-understand to override"); exit(2)
        }
        print("--i-understand given: continuing despite the blockers above")
    }
    print("Force eject \(disk.bsdName) (\(disk.volumes.count) volume(s): \(disk.volumePaths.joined(separator: ", ")))? "
          + "\(scan.holders.count) holder(s) above lose access immediately; apps with media mapped in memory may crash. [y/N] ",
          terminator: "")
    fflush(stdout)
    let answer = readLine()?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
    guard answer == "y" || answer == "yes" else { print("cancelled (nothing sent)"); exit(5) }
    ActionLog.shared.forceEjectConfirmed(disk: disk, holders: scan.holders)
}

/// Read-only description of a physical whole disk by BSD name (also one with nothing mounted).
func cmdDisk(_ args: [String]) {
    let bsd = pathArgument(args)
    guard let d = DiskTopology.physicalDisk(bsdName: bsd) else { fail("\(bsd) is not a physical whole disk", 1) }
    print("""
    \(d.bsdName): model=\(d.deviceModel ?? "-") protocol=\(d.deviceProtocol ?? "-") media=\(d.mediaName ?? "-")
      location=\(d.interconnectLocation ?? "absent") DADeviceInternal=\(d.deviceInternalKey.map { "\($0)" } ?? "absent") -> internal=\(yn(d.isInternal)) virtual=\(yn(d.isVirtual))
      member disks: \(d.wholeAncestors.joined(separator: ", "))  mounted volumes: \(d.volumes.isEmpty ? "none" : d.volumePaths.joined(separator: ", "))
      S5 (app policy): \(Ejector.safetyCheck(d, policy: .externalDisks).map { "refused: \($0)" } ?? "allowed")
      S5 (CLI policy): \(Ejector.safetyCheck(d, policy: .diskImagesOnly).map { "refused: \($0)" } ?? "allowed")
    """)
}

func cmdState(_ args: [String]) {
    let path = args.count > 2 ? volumePath(args, allowSystem: true) : nil
    guard let tm = SystemState.timeMachineState() else {
        print("time machine: UNKNOWN (tmutil missing, timed out, failed or unparsable): Force Eject stays disabled")
        return
    }
    print("time machine backup running: \(tm.backupRunning)")
    let dests = tm.destinations ?? []
    print("time machine destinations: \(tm.destinations == nil ? "not read (only while a backup runs)" : dests.isEmpty ? "none" : dests.map { "\($0.name ?? $0.id) [\($0.kind ?? "?")] mount=\($0.mountPoint ?? "-") uuid=\($0.volumeUUID ?? "-")" }.joined(separator: "; "))")
    if let path {
        print("spotlight indexing on \(path): \(SystemState.spotlightIndexingEnabled(volumePath: path).map { $0 ? "enabled" : "disabled" } ?? "unknown")")
    }
}

// MARK: - watch

/// Local wall-clock time with milliseconds, e.g. 14:02:11.123.
func stamp() -> String {
    var tv = timeval()
    gettimeofday(&tv, nil)
    var secs = time_t(tv.tv_sec)
    var t = tm()
    localtime_r(&secs, &t)
    return String(format: "%02d:%02d:%02d.%03d", t.tm_hour, t.tm_min, t.tm_sec, Int(tv.tv_usec / 1000))
}

func argValue(_ args: [String], _ flag: String) -> Double? {
    guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
    guard let v = Double(args[i + 1]), v >= 0 else { usage() }
    return v
}

func printEvent(_ e: EjectWatcherEvent) {
    let d = e.disk
    let what = "\(e.volumeURL.path) on \(d.bsdName) (\(d.deviceModel ?? "?"), \(d.isVirtual ? "disk image" : "real disk"))"
    switch e {
    case .attemptStarted:
        print("\(stamp())  ATTEMPT    \(what): \(d.volumes.count) volume(s) on the disk")
    case .succeeded:
        print("\(stamp())  SUCCEEDED  \(what)")
    case .failed(_, _, let scan, let kind):
        print("\(stamp())  FAILED     \(what): still mounted (attempt kind: \(kind))")
        printScan(scan)
    }
}

func printStats(_ s: EjectWatcherStats) {
    print("\(stamp())  stats: \(s.approvalCallbacks) approval callback(s), time inside callback max "
          + String(format: "%.1f µs, mean %.1f µs", Double(s.maxApprovalCallbackNanos) / 1e3, Double(s.meanApprovalCallbackNanos) / 1e3)
          + "; \(s.idleCallbacks) idle callback(s); \(s.attempts) attempt(s), \(s.failed) failed, \(s.succeeded) succeeded; "
          + "ignored: \(s.ignoredOwnEjects) own, \(s.ignoredOther) other")
}

func cmdWatch(_ args: [String]) -> Never {
    setvbuf(stdout, nil, _IOLBF, 0)
    var options = EjectWatcherOptions(useIdleCallback: !args.contains("--no-idle-callback"))
    if let t = argValue(args, "--timeout") { options.outcomeTimeout = t }
    let stopAfter = argValue(args, "--stop-after")
    let watcher = EjectWatcher(options: options, trace: { print("\(stamp())    · \($0)") }) { event in printEvent(event) }
    guard watcher.start() else { print("ejectctl: could not create a DiskArbitration session"); exit(1) }
    let mode = watcher.usesIdleCallback ? "DARegisterIdleCallback (private, via dlsym)"
        : "polling fallback every \(Int(options.pollInterval * 1000)) ms, failed after \(options.outcomeTimeout) s"
          + (EjectWatcher.idleCallbackAvailable ? " (idle callback disabled)" : " (DARegisterIdleCallback not found)")
    print("\(stamp())  watching foreign unmount/eject attempts, pid \(getpid()); outcome via \(mode). Ctrl-C to stop.")
    print("\(stamp())  observe-only: every approval callback returns nil (S7); this process never unmounts anything.")

    if let stopAfter {
        DispatchQueue.main.asyncAfter(deadline: .now() + stopAfter) {
            watcher.stop()
            print("\(stamp())  stopped the watcher (--stop-after \(stopAfter)); process stays alive, Ctrl-C to exit")
            printStats(watcher.stats)
        }
    }
    var sources: [DispatchSourceSignal] = []
    for sig in [SIGINT, SIGTERM] {
        signal(sig, SIG_IGN)
        let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
        src.setEventHandler {
            watcher.stop()
            printStats(watcher.stats)
            exit(0)
        }
        src.resume()
        sources.append(src)
    }
    withExtendedLifetime((watcher, sources)) { RunLoop.main.run() }
    exit(0)
}

let args = CommandLine.arguments
guard args.count >= 2 else { usage() }
if args[1] == "watch" { cmdWatch(args) }      // main run loop; the watcher resolves disks on its own queues
// Every other command runs off the main thread, like the app: DiskArbitration / IOKit lookups never run on it (debug
// builds of EjectKit check).
DispatchQueue.global(qos: .userInitiated).async {
    switch args[1] {
    case "volumes": cmdVolumes()
    case "scan": cmdScan(args)
    case "topology": cmdTopology(args)
    case "disk": cmdDisk(args)
    case "eject": cmdEject(args)
    case "state": cmdState(args)
    default: usage()
    }
    exit(0)
}
dispatchMain()
