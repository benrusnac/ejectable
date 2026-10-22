import EjectKit
import XCTest

/// S2 gate: pure functions over synthetic holders.
final class SafetyGateTests: XCTestCase {
    static let disk = PhysicalDisk(
        bsdName: "disk99", isInternal: false, deviceInternalKey: nil, isVirtual: true, deviceModel: "Disk Image",
        deviceProtocol: "Virtual Interface", mediaName: nil, mediaSize: 1, isEjectable: true, isRemovable: true,
        appearanceTime: 1, volumes: [VolumeInfo(path: "/Volumes/FAKE", name: "FAKE", fileSystem: "apfs", isNetwork: false,
                                                 isInternal: nil, isRootFileSystem: false, isBrowsable: true, bsdName: "disk99s1")],
        containerBSDNames: ["disk99"])

    func testWritersBlockWithNameAndFile() {
        let w = fake(1, "duhold", reasons: [.openFile(path: "/Volumes/FAKE/fdw.txt", writing: true)])
        let mw = fake(2, "Premiere Pro", kind: .app, reasons: [.mappedFile(path: "/Volumes/FAKE/clip.mov", writable: true)])
        let b = SafetyGate.forceEjectBlockers(holders: [w, mw], disk: Self.disk, timeMachine: .idle)
        XCTAssertEqual(b.map(\.kind), [.writer, .writer])
        XCTAssertEqual(b.map(\.message), ["duhold is writing fdw.txt", "Premiere Pro is writing clip.mov"])
        XCTAssertEqual(b.map(\.pid), [1, 2])
    }

    func testReadOnlyHoldersDoNotBlockButAreRisks() {
        let holders = [
            fake(1, "tail", reasons: [.openFile(path: "/Volumes/FAKE/fd.txt", writing: false)]),
            fake(2, "sleep", reasons: [.workingDirectory(path: "/Volumes/FAKE/cwd")]),
            fake(3, "AirDrop (Finder)", kind: .appExtension, reasons: [.mappedFile(path: "/Volumes/FAKE/a.jpg", writable: false)]),
            fake(4, "mds_stores", kind: .inaccessible, reasons: []),
        ]
        XCTAssertTrue(SafetyGate.forceEjectBlockers(holders: holders, disk: Self.disk, timeMachine: .idle).isEmpty)
        let risks = SafetyGate.forceEjectRisks(holders: holders)
        XCTAssertEqual(risks.map(\.message), [
            "tail loses access to fd.txt",
            "AirDrop (Finder) has media mapped in memory and may crash",
            "mds_stores is a system process Ejectable can\u{2019}t inspect",
        ])
    }

    func testCopyToolsBlockEvenWhenReading() {
        for name in ["cp", "rsync", "ditto", "ffmpeg", "HandBrakeCLI"] {
            let h = fake(10, name, reasons: [.openFile(path: "/Volumes/FAKE/clip.mov", writing: false)])
            XCTAssertEqual(SafetyGate.forceEjectBlockers(holders: [h], disk: Self.disk, timeMachine: .idle).map(\.kind), [.copyTool], name)
        }
        let ame = fake(11, "Adobe Media Encoder 2025", kind: .app, bundleID: "com.adobe.ame.application.25",
                       reasons: [.mappedFile(path: "/Volumes/FAKE/clip.mov", writable: false)])
        XCTAssertEqual(SafetyGate.forceEjectBlockers(holders: [ame], disk: Self.disk, timeMachine: .idle).first?.message,
                       "Adobe Media Encoder 2025 is copying clip.mov")
        let compressor = fake(12, "Compressor", kind: .app, bundleID: "com.apple.Compressor",
                              reasons: [.openFile(path: "/Volumes/FAKE/x.mov", writing: false)])
        XCTAssertTrue(SafetyGate.isCopyTool(compressor))
        // A copy tool whose only hold is its working directory is not copying from/to this disk.
        let cpInFolder = fake(13, "cp", reasons: [.workingDirectory(path: "/Volumes/FAKE")])
        XCTAssertTrue(SafetyGate.forceEjectBlockers(holders: [cpInFolder], disk: Self.disk, timeMachine: .idle).isEmpty)
        // A writing copy tool is reported once, as a writer.
        let rsyncW = fake(14, "rsync", reasons: [.openFile(path: "/Volumes/FAKE/clip.mov", writing: true)])
        XCTAssertEqual(SafetyGate.forceEjectBlockers(holders: [rsyncW], disk: Self.disk, timeMachine: .idle).map(\.kind), [.writer])
        XCTAssertFalse(SafetyGate.isCopyTool(fake(15, "tail", reasons: [])))
    }

    func testTimeMachineBlocksAndFailsClosed() {
        func kinds(_ tm: TimeMachineFacts) -> [ForceBlocker.Kind] {
            SafetyGate.forceEjectBlockers(holders: [], disk: Self.disk, timeMachine: tm).map(\.kind)
        }
        XCTAssertEqual(kinds(.idle), [])
        XCTAssertEqual(kinds(TimeMachineFacts(backupRunning: true, diskIsDestination: false)), [], "backing up elsewhere")
        XCTAssertEqual(kinds(TimeMachineFacts(backupRunning: true, diskIsDestination: true)), [.timeMachine])
        XCTAssertEqual(kinds(TimeMachineFacts(backupRunning: true, diskIsDestination: nil)), [.timeMachine], "fail closed")
        XCTAssertEqual(kinds(.unknown), [.timeMachineUnknown], "fail closed when tmutil can't be read")
        XCTAssertEqual(kinds(TimeMachineFacts(backupRunning: false, diskIsDestination: nil)), [])
    }

    func testTimeMachineDestinationMatching() {
        XCTAssertTrue(TimeMachineFacts.isDestination(diskVolumePaths: ["/Volumes/Backup"], diskVolumeUUIDs: [],
                                                     destinationMountPoints: ["/Volumes/Backup/"], destinationVolumeUUIDs: []))
        XCTAssertTrue(TimeMachineFacts.isDestination(diskVolumePaths: ["/Volumes/X"], diskVolumeUUIDs: ["abcd-1234"],
                                                     destinationMountPoints: [], destinationVolumeUUIDs: ["ABCD-1234"]))
        XCTAssertFalse(TimeMachineFacts.isDestination(diskVolumePaths: ["/Volumes/X"], diskVolumeUUIDs: ["1"],
                                                      destinationMountPoints: ["/Volumes/Backup"], destinationVolumeUUIDs: ["2"]))
    }

    /// tmutil's answer -> facts: unknown (nil) fails closed; running with unreadable destinations fails closed.
    func testTimeMachineStateMapping() {
        let paths = ["/Volumes/FAKE"]
        XCTAssertEqual(TimeMachineFacts.facts(nil, diskVolumePaths: paths), .unknown)
        XCTAssertEqual(TimeMachineFacts.facts(.init(backupRunning: false, destinations: nil), diskVolumePaths: paths), .idle)
        XCTAssertEqual(TimeMachineFacts.facts(.init(backupRunning: true, destinations: nil), diskVolumePaths: paths),
                       TimeMachineFacts(backupRunning: true, diskIsDestination: nil))
        XCTAssertEqual(TimeMachineFacts.facts(.init(backupRunning: true, destinations: []), diskVolumePaths: paths),
                       TimeMachineFacts(backupRunning: true, diskIsDestination: false))
        XCTAssertEqual(SafetyGate.forceEjectBlockers(holders: [], disk: Self.disk,
                                                     timeMachine: TimeMachineFacts.facts(nil, diskVolumePaths: paths)).map(\.kind),
                       [.timeMachineUnknown])
    }

    func testIncompleteScanBlocksForce() {
        let scan = HolderScan(volumePaths: ["/Volumes/FAKE"], holders: [], deniedPIDs: [], duration: 2, scannedAt: Date(),
                              incomplete: true, incompleteReason: "deadline")
        XCTAssertFalse(scan.isClear)
        XCTAssertEqual(SafetyGate.forceEjectBlockers(scan: scan, disk: Self.disk, timeMachine: .idle).map(\.kind), [.scanIncomplete])
        let none = HolderScan(volumePaths: ["/Volumes/FAKE"], holders: [], deniedPIDs: [], duration: 0, scannedAt: Date(), scannedTargets: [])
        XCTAssertFalse(none.isClear, "nothing scanned is not clear")
    }

    /// The live query on this Mac answers (tmutil runs) and is not "unknown".
    func testTimeMachineCurrentIsKnownHere() {
        let facts = TimeMachineFacts.current(for: Self.disk)
        XCTAssertNotNil(facts.backupRunning, "tmutil status should be readable")
        XCTAssertNotNil(SystemState.timeMachineState())
    }

    func testScanOverloadsMatchHolderOverloads() {
        let holders = [fake(1, "duhold", reasons: [.openFile(path: "/Volumes/FAKE/fdw.txt", writing: true)]),
                       fake(2, "duhold", reasons: [.mappedFile(path: "/Volumes/FAKE/m.bin", writable: false)])]
        let scan = HolderScan(volumePaths: ["/Volumes/FAKE"], holders: holders, deniedPIDs: [], duration: 0, scannedAt: Date())
        XCTAssertEqual(SafetyGate.forceEjectBlockers(scan: scan, disk: Self.disk, timeMachine: .idle),
                       SafetyGate.forceEjectBlockers(holders: holders, disk: Self.disk, timeMachine: .idle))
        XCTAssertEqual(SafetyGate.forceEjectRisks(scan: scan), SafetyGate.forceEjectRisks(holders: holders))
    }
}

/// Synthetic holder. The executable path never exists, so S6 (`isSameProcess`) can never match a real process.
extension SafetyGateTests {
    func testForceRating() {
        let reader = fake(1, "tail", reasons: [.openFile(path: "/Volumes/FAKE/fd.txt", writing: false)])
        let cwd = fake(2, "sleep", reasons: [.workingDirectory(path: "/Volumes/FAKE/cwd")])
        let mapper = fake(3, "duhold", reasons: [.mappedFile(path: "/Volumes/FAKE/mmap.bin", writable: false)])
        let cow = fake(4, "duhold", reasons: [.mappedFile(path: "/Volumes/FAKE/mmapp.bin", writable: false)])
        let spotlight = fake(5, "mds_stores", kind: .inaccessible, reasons: [])
        let unknownRoot = fake(6, "somerootd", kind: .inaccessible, reasons: [])
        let ql = fake(7, "QuickLookUIService", kind: .daemon, reasons: [.openFile(path: "/Volumes/FAKE/a.jpg", writing: false)])
        func rating(_ h: [Holder], complete: Bool = true, tm: TimeMachineFacts = .idle) -> ForceRating {
            SafetyGate.forceRating(holders: h, blockers: SafetyGate.forceEjectBlockers(holders: h, disk: Self.disk, timeMachine: tm,
                                                                                       scanIncomplete: !complete),
                                   scanComplete: complete)
        }
        // Safe: read-only fd + cwd, complete scan, nothing mapped.
        XCTAssertEqual(rating([reader, cwd]), .safe(except: []))
        XCTAssertEqual(rating([reader, cwd]).text, "Force Eject is safe: nothing is writing to this drive")
        // Known metadata / preview processes keep it safe and are named when they write.
        XCTAssertEqual(rating([reader, spotlight, ql]).text, "Force Eject is safe: nothing is writing to this drive except Spotlight")
        // Risky: mapped media (incl. copy-on-write private mappings), unknown processes, or nothing visible at all.
        XCTAssertEqual(rating([reader, cwd, mapper]).text, "Force Eject is risky: media mapped by duhold")
        XCTAssertEqual(rating([cow, mapper]).text, "Force Eject is risky: media mapped by duhold")
        XCTAssertEqual(rating([reader, unknownRoot]).text, "Force Eject is risky: somerootd can\u{2019}t be inspected")
        XCTAssertEqual(rating([mapper, unknownRoot]), .risky(["media mapped by duhold", "somerootd can\u{2019}t be inspected"]))
        XCTAssertEqual(rating([]).text, "Force Eject is risky: something Ejectable can\u{2019}t see is using it")
        // Blocked: writers, Time Machine unknown, incomplete scan — never safe.
        let writer = fake(8, "duhold", reasons: [.openFile(path: "/Volumes/FAKE/fdw.txt", writing: true)])
        XCTAssertEqual(rating([reader, writer]).text, "Force Eject is unavailable: duhold is writing fdw.txt")
        XCTAssertTrue(rating([reader], tm: .unknown).isBlocked)
        XCTAssertTrue(rating([reader], complete: false).isBlocked)
        XCTAssertTrue(SafetyGate.forceRating(holders: [reader], blockers: [], scanComplete: false).isBlocked,
                      "safe needs a complete scan even without blockers")
    }
}

func fake(_ pid: pid_t, _ name: String, kind: HolderKind = .cli, bundleID: String? = nil, reasons: [HoldReason],
          path: String? = nil, startTime: Double = 1) -> Holder {
    Holder(pid: pid, uid: getuid(), ppid: 1, executablePath: path ?? "/nonexistent/drivetest/\(name)", startTime: startTime,
           displayName: name, bundleIdentifier: bundleID, bundleURL: nil, parentAppBundleURL: nil, kind: kind,
           reasons: reasons, volumePaths: ["/Volumes/FAKE"])
}
