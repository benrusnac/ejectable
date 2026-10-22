@testable import EjectKit
import XCTest

final class ScanTests: XCTestCase {
    override func setUp() { redirectTestLogs() }

    static let allHolders = ["fd", "fdw", "cwd", "mmap", "mmapw", "evtonly"]

    func testAPFSScanFindsEveryHolderKind() throws { try scanAndVerify("apfs") }
    func testExFATScanFindsEveryHolderKind() throws { try scanAndVerify("exfat") }
    func testHFSScanFindsEveryHolderKind() throws { try scanAndVerify("hfs") }

    /// Regression for the libproc 32/64-bit fsid bug: stock proc_listpidspath misses mmap-only holders on APFS.
    func testMmapOnlyHolderFoundOnAPFS() throws {
        let fx = try Fixture.make("apfs", holders: ["mmap"])
        defer { fx.cleanup() }
        let scan = HolderScanner.scan(volumePaths: [fx.mount], log: nil)
        let h = try XCTUnwrap(scan.holders.first { $0.pid == fx.pids["mmap"] }, "mmap-only holder missed")
        XCTAssertEqual(h.reasons, [.mappedFile(path: fx.path("mmap.bin"), writable: false)])
        XCTAssertTrue(h.hasMappedFiles)
        XCTAssertFalse(h.isWriter)
    }

    /// A clean volume reports no holders and the scan only lists processes that really hold it.
    func testCleanVolumeHasNoHolders() throws {
        let fx = try Fixture.make("apfs", holders: ["evtonly"])
        defer { fx.cleanup() }
        let scan = HolderScanner.scan(volumePaths: [fx.mount], log: nil)
        XCTAssertTrue(scan.isClear, "unexpected holders: \(scan.holders.map { "\($0.pid) \($0.displayName) \($0.reasons)" })")
        XCTAssertFalse(scan.deniedPIDs.isEmpty, "root daemons should be counted as denied")
        XCTAssertEqual(scan.volumePaths, [fx.mount])
    }

    private func scanAndVerify(_ fs: String) throws {
        let fx = try Fixture.make(fs, holders: Self.allHolders)
        defer { fx.cleanup() }
        let scan = HolderScanner.scan(volumePaths: [fx.mount], log: nil)
        let byPID = Dictionary(uniqueKeysWithValues: scan.holders.map { ($0.pid, $0) })
        func holder(_ mode: String) throws -> Holder {
            let pid = try XCTUnwrap(fx.pids[mode], "no \(mode) pid")
            return try XCTUnwrap(byPID[pid], "\(fs): \(mode) holder \(pid) not found in \(scan.holders.map(\.pid))")
        }

        let fd = try holder("fd")
        XCTAssertEqual(fd.reasons, [.openFile(path: fx.path("fd.txt"), writing: false)])
        XCTAssertFalse(fd.isWriter)
        XCTAssertEqual(fd.kind, .cli)
        XCTAssertEqual(fd.displayName, "tail")
        XCTAssertTrue(fd.isQuittable)

        let fdw = try holder("fdw")
        XCTAssertEqual(fdw.reasons, [.openFile(path: fx.path("fdw.txt"), writing: true)])
        XCTAssertTrue(fdw.isWriter)

        let cwd = try holder("cwd")
        XCTAssertEqual(cwd.reasons, [.workingDirectory(path: fx.path("cwd"))])
        XCTAssertFalse(cwd.isWriter)
        XCTAssertEqual(cwd.displayName, "sleep")

        let mmap = try holder("mmap")
        XCTAssertEqual(mmap.reasons, [.mappedFile(path: fx.path("mmap.bin"), writable: false)])
        XCTAssertFalse(mmap.isWriter)

        let mmapw = try holder("mmapw")
        XCTAssertEqual(mmapw.reasons, [.mappedFile(path: fx.path("mmapw.bin"), writable: true)])
        XCTAssertTrue(mmapw.isWriter)

        // O_EVTONLY never blocks an unmount: must not be reported.
        XCTAssertNil(byPID[fx.pids["evtonly"] ?? -1], "\(fs): O_EVTONLY holder reported")
        XCTAssertTrue(fx.isAlive("evtonly"))

        XCTAssertEqual(scan.holders.count, 5, "\(fs): extra holders: \(scan.holders.map { "\($0.pid) \($0.displayName)" })")
        XCTAssertEqual(Set(scan.writers.map(\.pid)), Set([fdw.pid, mmapw.pid]))
        for h in scan.holders {
            XCTAssertEqual(h.volumePaths, [fx.mount])
            XCTAssertEqual(h.uid, getuid())
            XCTAssertTrue(h.isSameProcess(), "S6 check failed for live pid \(h.pid)")
        }
        XCTAssertLessThan(scan.duration, 0.2, "scan took \(scan.duration * 1000) ms")
    }
}

/// Fix pass: mount-point guard, copy-on-write mappings, bundled-process region walk, deadline / incomplete scans.
final class ScanGuardTests: XCTestCase {
    override func setUp() { redirectTestLogs() }

    /// HIGH (review): only real mount points are scanned. The `/Volumes/Macintosh HD -> /` symlink, the root
    /// filesystem, /System/Volumes, a subdirectory of a volume and a leftover folder are not targets: nothing is
    /// scanned, and an unscanned set is not "clear".
    func testOnlyMountPointsAreScanned() throws {
        let fx = try Fixture.make("apfs", holders: ["cwd"], name: "DUTEST_T_GUARD")
        defer { fx.cleanup() }
        let leftover = Fixture.fixtureDir.appendingPathComponent("leftover-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: leftover, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: leftover) }
        var refused = ["/", "/System/Volumes/Data", "/System/Volumes/VM", fx.path("cwd"), leftover, "/Volumes/DUTEST_NOPE"]
        if FileManager.default.fileExists(atPath: "/Volumes/Macintosh HD") { refused.append("/Volumes/Macintosh HD") }
        for path in refused {
            let s = HolderScanner.scan(volumePaths: [path], log: nil)
            XCTAssertEqual(s.scannedTargets, [], "\(path) must not be scanned")
            XCTAssertTrue(s.holders.isEmpty, "\(path): \(s.holders.map(\.displayName))")
            XCTAssertFalse(s.isClear, "\(path): nothing scanned is unknown, not clear")
        }
        // The real mount point (also with a trailing slash) is scanned; mixed lists keep only it.
        let s = HolderScanner.scan(volumePaths: ["/", fx.mount + "/", fx.path("cwd")], log: nil)
        XCTAssertEqual(s.scannedTargets, [fx.mount])
        XCTAssertEqual(s.holders.map(\.pid), [fx.pids["cwd"]].compactMap { $0 })
    }

    /// S2: a writable MAP_PRIVATE (copy-on-write) mapping never writes the file: not a writer. MAP_SHARED writable is.
    func testCopyOnWriteMappingIsNotAWriter() throws {
        let fx = try Fixture.make("apfs", holders: ["mmapp", "mmapw"], name: "DUTEST_T_COW")
        defer { fx.cleanup() }
        let scan = HolderScanner.scan(volumePaths: [fx.mount], log: nil)
        let cow = try XCTUnwrap(scan.holders.first { $0.pid == fx.pids["mmapp"] }, "\(scan.holders)")
        XCTAssertEqual(cow.reasons, [.mappedFile(path: fx.path("mmapp.bin"), writable: false)])
        XCTAssertFalse(cow.isWriter)
        let shared = try XCTUnwrap(scan.holders.first { $0.pid == fx.pids["mmapw"] })
        XCTAssertEqual(shared.reasons, [.mappedFile(path: fx.path("mmapw.bin"), writable: true)])
        XCTAssertEqual(SafetyGate.forceEjectBlockers(scan: scan, disk: SafetyGateTests.disk, timeMachine: .idle).map(\.pid), [shared.pid])
    }

    /// Bundled processes (apps, helpers, XPC) are walked region by region instead of relying on the PATHINFO3 probe:
    /// a copy of duhold inside a fake .app bundle maps a file and is found, with its parent app.
    func testBundledProcessMappingFoundByRegionWalk() throws {
        let fx = try Fixture.make("apfs", holders: [], name: "DUTEST_T_BUNDLE")
        defer { fx.cleanup() }
        let p = try launchInFakeBundle(app: "DUMapper.app", exe: "dumapper", args: ["mmap", fx.path("mmap.bin")])
        defer { p.terminate(); p.waitUntilExit() }
        let exe = try XCTUnwrap(p.executableURL?.path)
        XCTAssertTrue(HolderScanner.isBundled(exe))
        let h = try XCTUnwrap(waitForHolder(p.processIdentifier, on: fx))
        XCTAssertEqual(h.reasons, [.mappedFile(path: fx.path("mmap.bin"), writable: false)])
        XCTAssertEqual(h.kind, .helper)
        XCTAssertEqual(h.parentAppBundleURL?.lastPathComponent, "DUMapper.app")
    }

    /// S4 (review MED): a known daemon name stays a daemon even inside an .app bundle (postgres in an NLE).
    func testKnownDaemonInsideAppBundleIsNotQuittable() throws {
        let fx = try Fixture.make("apfs", holders: [], name: "DUTEST_T_PG")
        defer { fx.cleanup() }
        let p = try launchInFakeBundle(app: "DUEditor.app", exe: "postgres", args: ["fd", fx.path("fd.txt")])
        defer { p.terminate(); p.waitUntilExit() }
        let h = try XCTUnwrap(waitForHolder(p.processIdentifier, on: fx))
        XCTAssertEqual(h.kind, .daemon)
        XCTAssertFalse(h.isQuittable)
        XCTAssertEqual(h.displayName, "postgres")
    }

    /// Deadline: a process stuck in the kernel makes the scan incomplete (S2 blocker), is skipped by later scans
    /// (still incomplete) until its inspection returns, and the scan after that is complete again.
    func testDeadlineMarksScanIncompleteAndSkipsStuckPid() throws {
        #if !DEBUG
        throw XCTSkip("HolderScanner.inspectHook exists in debug builds only")
        #else
        let fx = try Fixture.make("apfs", holders: ["fd"], name: "DUTEST_T_DEADLINE")
        defer { fx.cleanup() }
        let stuckPID = try XCTUnwrap(fx.pids["fd"])
        HolderScanner.inspectHook.withLock { $0 = { pid in if pid == stuckPID { Thread.sleep(forTimeInterval: 1.5) } } }
        defer { HolderScanner.inspectHook.withLock { $0 = nil } }

        let first = HolderScanner.scan(volumePaths: [fx.mount], deadline: 0.5, log: nil)
        XCTAssertTrue(first.incomplete, "the stuck pid outlives the deadline")
        XCTAssertFalse(first.isClear)
        XCTAssertTrue(first.incompleteReason?.contains("\(stuckPID)") ?? false, first.incompleteReason ?? "-")
        XCTAssertLessThan(first.duration, 1.2, "the scan returns at its deadline, not when the stuck inspection ends")
        XCTAssertTrue(HolderScanner.stuckPIDs.contains(stuckPID))
        XCTAssertEqual(SafetyGate.forceEjectBlockers(scan: first, disk: SafetyGateTests.disk, timeMachine: .idle).map(\.kind),
                       [.scanIncomplete])

        HolderScanner.inspectHook.withLock { $0 = nil }
        let second = HolderScanner.scan(volumePaths: [fx.mount], log: nil)
        if HolderScanner.stuckPIDs.contains(stuckPID) || second.incomplete {
            XCTAssertTrue(second.incomplete && (second.incompleteReason?.contains("still stuck") ?? false), "\(second.incompleteReason ?? "-")")
        }
        let end = Date().addingTimeInterval(5)
        while HolderScanner.stuckPIDs.contains(stuckPID) && Date() < end { Thread.sleep(forTimeInterval: 0.1) }
        XCTAssertFalse(HolderScanner.stuckPIDs.contains(stuckPID), "released when the late inspection returns")
        let third = HolderScanner.scan(volumePaths: [fx.mount], log: nil)
        XCTAssertFalse(third.incomplete, third.incompleteReason ?? "")
        XCTAssertEqual(third.holders.map(\.pid), [stuckPID])
        #endif
    }

    /// The 1 s refresh re-inspects only known pids (public API, moved out of EjectFlow).
    func testRescanOnlyLooksAtGivenPids() throws {
        let fx = try Fixture.make("apfs", holders: ["fd", "cwd"], name: "DUTEST_T_RESCAN")
        defer { fx.cleanup() }
        let fd = try XCTUnwrap(fx.pids["fd"])
        let r = HolderScanner.rescan(pids: [fd, getpid(), 0], volumePaths: [fx.mount], log: nil)
        XCTAssertEqual(r.holders.map(\.pid), [fd])
        XCTAssertEqual(r.scannedTargets, [fx.mount])
        XCTAssertFalse(r.incomplete)
        XCTAssertTrue(HolderScanner.rescan(pids: [fd], volumePaths: [fx.path("cwd")], log: nil).holders.isEmpty)
    }

    // MARK: helpers

    /// Copies duhold to .build/fixtures/<app>/Contents/MacOS/<exe> and runs it (cwd /).
    private func launchInFakeBundle(app: String, exe: String, args: [String]) throws -> Process {
        let dir = Fixture.fixtureDir.appendingPathComponent("\(app)/Contents/MacOS", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let bin = dir.appendingPathComponent(exe)
        try? FileManager.default.removeItem(at: bin)
        try FileManager.default.copyItem(at: Fixture.fixtureDir.appendingPathComponent("duhold"), to: bin)
        let p = Process()
        p.executableURL = bin
        p.arguments = args
        p.currentDirectoryURL = URL(fileURLWithPath: "/")
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        return p
    }

    private func waitForHolder(_ pid: pid_t, on fx: Fixture) -> Holder? {
        let end = Date().addingTimeInterval(5)
        while Date() < end {
            if let h = HolderScanner.scan(volumePaths: [fx.mount], log: nil).holders.first(where: { $0.pid == pid }) { return h }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return nil
    }
}
