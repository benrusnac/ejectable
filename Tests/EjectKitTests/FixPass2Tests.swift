@testable import EjectKit
import DiskArbitration
import XCTest

/// Fix pass 2 (review2.md): one test per new guard. Synthetic holders never match a real process (S6); live parts use
/// fixture disk images only.
final class FixPass2FlowTests: XCTestCase {
    override func setUp() { redirectTestLogs() }

    static let busy = EjectResult.busy(dissenterPID: nil, status: 0xC010, step: .unmount(bsdName: "disk99"))
    let reader = fake(99_931, "tail", reasons: [.openFile(path: "/Volumes/FAKE/fd.txt", writing: false)])
    let reader2 = fake(99_932, "cat", reasons: [.openFile(path: "/Volumes/FAKE/b.txt", writing: false)])

    /// Two volumes on one fake disk image: FAKE (disk99s1) and FAKE2 (disk99s2).
    static let twoVolumeDisk = PhysicalDisk(
        bsdName: "disk99", isInternal: false, deviceInternalKey: nil, isVirtual: true, deviceModel: "Disk Image",
        deviceProtocol: "Virtual Interface", mediaName: nil, mediaSize: 1, isEjectable: true, isRemovable: true,
        appearanceTime: 1,
        volumes: [VolumeInfo(path: "/Volumes/FAKE", name: "FAKE", fileSystem: "apfs", isNetwork: false, isInternal: nil,
                             isRootFileSystem: false, isBrowsable: true, bsdName: "disk99s1"),
                  VolumeInfo(path: "/Volumes/FAKE2", name: "FAKE2", fileSystem: "apfs", isNetwork: false, isInternal: nil,
                             isRootFileSystem: false, isBrowsable: true, bsdName: "disk99s2")],
        containerBSDNames: ["disk100"])

    // MARK: BUG: a scan that resolved no mount point is not "clear" (S2 fails closed, both layers)

    /// The flow's own gate: a full scan with zero scanned targets blocks Force Eject even when the scanner did not
    /// mark it incomplete.
    @MainActor
    func testFlowBlocksForceWhenNothingWasScanned() async throws {
        let scanner = FakeScanner([])
        scanner.nothingScanned = true
        let flow = makeFakeFlow(FakeEjector(default: Self.busy), scanner)
        flow.start()
        try await waitUntil(5) { flow.lastScan != nil && flow.timeMachine == .idle && flow.state == .blocked }
        XCTAssertEqual(flow.lastScan?.incomplete, false, "the fake scanner does not say incomplete")
        XCTAssertEqual(flow.blockers.map(\.kind), [.scanIncomplete])
        XCTAssertFalse(flow.canForceEject)
        XCTAssertNil(flow.requestForceEject())
        XCTAssertTrue(flow.forceRating.isBlocked)
        scanner.nothingScanned = false
        flow.retryNow()                                 // full rescan
        try await waitUntil(5) { flow.canForceEject }
        flow.cancel()
    }

    // MARK: RISK: the confirmation re-check refuses what the sheet did not show

    @MainActor
    func testConfirmationShowsTheSheetAgainForANewHolder() async throws {
        let ejector = FakeEjector(default: Self.busy)
        let scanner = FakeScanner([reader])
        let flow = makeFakeFlow(ejector, scanner)
        flow.start()
        try await waitUntil(5) { flow.state == .blocked && flow.canForceEject }
        let c = try XCTUnwrap(flow.requestForceEject())
        XCTAssertEqual(c.holders.map(\.pid), [reader.pid])
        scanner.set([reader, reader2])                  // a second (read-only) holder appears while the sheet is up
        let r = await flow.confirmForceEject(c)
        guard case .reconfirm(let again) = r else { return XCTFail("expected a new confirmation, got \(r)") }
        XCTAssertEqual(Set(again.holders.map(\.pid)), [reader.pid, reader2.pid], "the new sheet lists the fresh holders")
        XCTAssertNotEqual(again, c)
        XCTAssertTrue(flow.note?.contains("changed") ?? false, flow.note ?? "-")
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertFalse(ejector.calls.contains { $0.force }, "nothing forced on a list the user did not see")
        let stale = await flow.confirmForceEject(c)
        XCTAssertEqual(stale, .refused, "the old sheet's confirmation is dead")

        ejector.respond([.ejected])
        let ok = await flow.confirmForceEject(again)
        XCTAssertEqual(ok, .sent)
        try await waitUntil(5) { flow.state == .forced }
        XCTAssertEqual(ejector.calls.filter(\.force).count, 1)
    }

    /// Same pid, but it now has media mapped: a SIGBUS risk the sheet did not warn about.
    @MainActor
    func testConfirmationShowsTheSheetAgainForANewMappedRisk() async throws {
        let ejector = FakeEjector(default: Self.busy)
        let scanner = FakeScanner([reader])
        let flow = makeFakeFlow(ejector, scanner)
        flow.start()
        try await waitUntil(5) { flow.state == .blocked && flow.canForceEject }
        let c = try XCTUnwrap(flow.requestForceEject())
        let mapping = fake(reader.pid, "tail", reasons: reader.reasons + [.mappedFile(path: "/Volumes/FAKE/clip.mov", writable: false)])
        scanner.set([mapping])
        let r = await flow.confirmForceEject(c)
        guard case .reconfirm(let again) = r else { return XCTFail("expected a new confirmation, got \(r)") }
        XCTAssertTrue(again.risks.contains { $0.kind == .mappedFile && $0.pid == reader.pid })
        XCTAssertFalse(ejector.calls.contains { $0.force })
        flow.cancel()
    }

    /// Fewer holders than the sheet showed is fine (subset): sent.
    @MainActor
    func testConfirmationAcceptsFewerHolders() async throws {
        let ejector = FakeEjector(default: Self.busy)
        let scanner = FakeScanner([reader, reader2])
        let flow = makeFakeFlow(ejector, scanner)
        flow.start()
        try await waitUntil(5) { flow.state == .blocked && flow.canForceEject && flow.rows.count == 2 }
        let c = try XCTUnwrap(flow.requestForceEject())
        scanner.set([reader])
        ejector.respond([.ejected])
        let r = await flow.confirmForceEject(c)
        XCTAssertEqual(r, .sent)
        try await waitUntil(5) { flow.state == .forced }
    }

    /// Pure: a recycled pid (same pid, other start time) is a new holder; open read-only files are not crash risks.
    func testUnseenRules() {
        let c = ForceEjectConfirmation(flowID: UUID(), token: UUID(), diskName: "FAKE", disk: SafetyGateTests.disk,
                                       mode: .ejectDisk, holders: [reader], risks: SafetyGate.forceEjectRisks(holders: [reader]))
        XCTAssertEqual(EjectFlow.unseen(holders: [reader], risks: SafetyGate.forceEjectRisks(holders: [reader]), shown: c), [])
        let recycled = fake(reader.pid, "tail", reasons: reader.reasons, startTime: 2)
        XCTAssertEqual(EjectFlow.unseen(holders: [recycled], risks: [], shown: c).count, 1)
        let moreFiles = fake(reader.pid, "tail", reasons: reader.reasons + [.openFile(path: "/Volumes/FAKE/x", writing: false)])
        XCTAssertEqual(EjectFlow.unseen(holders: [moreFiles], risks: SafetyGate.forceEjectRisks(holders: [moreFiles]), shown: c), [],
                       "another read-only file of a shown holder is not a new crash risk")
        let root = fake(1, "somerootd", kind: .inaccessible, reasons: [])
        XCTAssertEqual(EjectFlow.unseen(holders: [reader], risks: SafetyGate.forceEjectRisks(holders: [root]), shown: c).count, 1,
                       "an uninspectable process the sheet did not list")
    }

    // MARK: NIT: never a forced request alongside a pending soft one

    @MainActor
    func testForceIsNotSentWhileASoftRequestIsPending() async throws {
        let ejector = FakeEjector(default: Self.busy)
        ejector.delay = 1.5                             // the first soft answer takes 1.5 s (APFS busy answers can take ~10 s)
        let flow = makeFakeFlow(ejector, FakeScanner([reader]))
        flow.softRequestWait = 0.3
        flow.start()
        try await waitUntil(5) { flow.canForceEject }
        XCTAssertTrue(flow.requestsInFlight.soft)
        let c = try XCTUnwrap(flow.requestForceEject())
        let r = await flow.confirmForceEject(c)
        XCTAssertEqual(r, .refused)
        XCTAssertTrue(flow.note?.contains("still running") ?? false, flow.note ?? "-")
        XCTAssertFalse(ejector.calls.contains { $0.force })
        flow.cancel()
    }

    @MainActor
    func testForceWaitsForThePendingSoftAnswerThenSends() async throws {
        let ejector = FakeEjector(default: Self.busy)
        ejector.delay = 0.6
        let flow = makeFakeFlow(ejector, FakeScanner([reader]))
        flow.softRequestWait = 5
        flow.start()
        try await waitUntil(5) { flow.canForceEject }
        let c = try XCTUnwrap(flow.requestForceEject())
        ejector.respond([.ejected])                     // for the forced request (the pending soft one answers busy)
        let r = await flow.confirmForceEject(c)
        XCTAssertEqual(r, .sent)
        try await waitUntil(5) { flow.state == .forced }
        XCTAssertEqual(ejector.maxConcurrent, 1, "one request at a time")
        XCTAssertEqual(ejector.calls.map(\.force), [false, true])
    }

    // MARK: NIT: Ejectable itself as the DA dissenter is dropped

    @MainActor
    func testOwnPidAsDissenterIsDropped() async throws {
        let ejector = FakeEjector(default: .busy(dissenterPID: getpid(), status: 0xC010, step: .unmount(bsdName: "disk99")))
        let flow = makeFakeFlow(ejector, FakeScanner([]), resolve: { pid, vols in HolderResolver.holder(forPID: pid, volumePaths: vols) })
        flow.start()
        try await waitUntil(5) { flow.state == .blocked && ejector.calls.count >= 1 && flow.lastResult != nil }
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(flow.rows.isEmpty, "Ejectable must never be a row (Quit All would quit it): \(flow.rows.map(\.holder.displayName))")
        XCTAssertFalse(flow.holders.contains { $0.pid == getpid() })
        flow.cancel()
    }

    // MARK: RISK: the disk going away mid-flow is "disconnected", never "Ejected"

    @MainActor
    func testDiskGoneMidFlowIsDisconnected() async throws {
        let ejector = FakeEjector(default: Self.busy)
        let scanner = FakeScanner([reader])
        let flow = makeFakeFlow(ejector, scanner)
        flow.start()
        try await waitUntil(5) { flow.state == .blocked && flow.ejectRequestCount == 1 && !flow.requestsInFlight.soft }
        ejector.respond([.refused(.diskNotFound(bsdName: "disk99"))])
        scanner.set([])                                 // auto-retry -> "not found"
        try await pumpFlow(flow) { flow.state.isFinished }
        XCTAssertEqual(flow.state, .disconnected(remounted: false))
        XCTAssertEqual(flow.statusText, "It was disconnected.")
    }

    /// The disk instance changed (re-enumerated) and its volume is mounted again from the new instance: not safe to unplug.
    @MainActor
    func testDiskReplacedAndMountedAgainSaysStillMounted() async throws {
        let fx = try Fixture.make("apfs", holders: [], name: "DUTEST_T_REMOUNT")
        defer { fx.cleanup() }
        let real = try XCTUnwrap(topo(forVolume: fx.mount))
        // The snapshot the flow holds belongs to an older instance of the disk (another appearance time).
        let old = PhysicalDisk(bsdName: real.bsdName, isInternal: false, deviceInternalKey: nil, isVirtual: true,
                               deviceModel: real.deviceModel, deviceProtocol: real.deviceProtocol, mediaName: nil,
                               mediaSize: real.mediaSize, isEjectable: true, isRemovable: true,
                               appearanceTime: (real.appearanceTime ?? 0) - 100, volumes: real.volumes,
                               containerBSDNames: real.containerBSDNames)
        let ejector = FakeEjector(default: .refused(.diskChanged(bsdName: real.bsdName)))
        let flow = makeFakeFlow(ejector, FakeScanner([]), disk: old)
        flow.start()
        try await waitUntil(5) { flow.state.isFinished }
        XCTAssertEqual(flow.state, .disconnected(remounted: true))
        XCTAssertTrue(fx.isMounted)
    }

    // MARK: RISK: a foreign single-volume unmount stays a single-volume unmount

    @MainActor
    func testVolumeModeOnlyEverUnmountsThatVolume() async throws {
        let ejector = FakeEjector(default: .volumeUnmounted)
        let a = fake(99_941, "tail", reasons: [.openFile(path: "/Volumes/FAKE/fd.txt", writing: false)])
        var onSibling = fake(99_942, "sleep", reasons: [.workingDirectory(path: "/Volumes/FAKE2/cwd")])
        onSibling = Holder(pid: onSibling.pid, uid: onSibling.uid, ppid: 1, executablePath: onSibling.executablePath,
                           startTime: 1, displayName: "sleep", bundleIdentifier: nil, bundleURL: nil, parentAppBundleURL: nil,
                           kind: .cli, reasons: onSibling.reasons, volumePaths: ["/Volumes/FAKE2"])
        let scanner = FakeScanner([a])
        let flow = makeFakeFlow(ejector, scanner, disk: Self.twoVolumeDisk, mode: .unmountVolume("/Volumes/FAKE"))
        XCTAssertTrue(flow.isVolumeMode)
        XCTAssertEqual(flow.verb, "unmount")
        XCTAssertEqual(flow.scope.volumePaths, ["/Volumes/FAKE"])
        let seed = HolderScan(volumePaths: Self.twoVolumeDisk.volumePaths, holders: [a, onSibling], deniedPIDs: [], duration: 0,
                              scannedAt: Date())
        flow.startObserving(seed)
        XCTAssertEqual(flow.rows.map(\.holder.pid), [a.pid], "a holder of the other volume does not block this unmount")
        XCTAssertEqual(flow.statusText, "It unmounts automatically as soon as nothing is using it.")
        try await waitUntil(5) { scanner.fullScans >= 1 }
        XCTAssertTrue(scanner.scannedPaths.allSatisfy { $0 == ["/Volumes/FAKE"] }, "\(scanner.scannedPaths)")
        XCTAssertTrue(ejector.calls.isEmpty, "nothing is sent while the holder is there")

        // Force Unmount: same gates, confirmation names the mode, forced request is for that volume only.
        try await waitUntil(5) { flow.canForceEject }
        let c = try XCTUnwrap(flow.requestForceEject())
        XCTAssertEqual(c.mode, .unmountVolume("/Volumes/FAKE"))
        ejector.respond([.busy(dissenterPID: nil, status: 0xC010, step: .unmount(bsdName: "disk99s1"))])
        let r = await flow.confirmForceEject(c)
        XCTAssertEqual(r, .sent)
        try await waitUntil(5) { flow.state == .blocked && !flow.requestsInFlight.forced }

        scanner.set([])                                 // holder gone -> automatic SOFT unmount of that volume
        try await pumpFlow(flow) { flow.state.isFinished }
        XCTAssertTrue(ejector.calls.allSatisfy { $0.volume == "/Volumes/FAKE" }, "never a whole-disk eject: \(ejector.calls)")
        XCTAssertEqual(ejector.calls.map(\.force), [true, false])
        XCTAssertTrue(ejector.calls.allSatisfy { $0.policy == .externalDisks })
        // /Volumes/FAKE2 is not mounted here, so nothing of the disk is left mounted: "safe to disconnect".
        XCTAssertEqual(flow.state, .unmounted)
    }

    // MARK: RISK: Cancel while forcing closes the window; the flow ends with the forced result

    @MainActor
    func testAbandonedForceEndsWithItsResult() async throws {
        let ejector = FakeEjector(default: Self.busy)
        let flow = makeFakeFlow(ejector, FakeScanner([reader]))
        flow.start()
        try await waitUntil(5) { flow.canForceEject && !flow.requestsInFlight.soft }
        ejector.delay = 0.4
        let c = try XCTUnwrap(flow.requestForceEject())
        let r = await flow.confirmForceEject(c)
        XCTAssertEqual(r, .sent)
        XCTAssertEqual(flow.state, .forcing)
        XCTAssertFalse(flow.state.isFinished)
        flow.abandonDuringForce()
        try await waitUntil(5) { flow.state.isFinished }
        guard case .failed(let m) = flow.state else { return XCTFail("\(flow.state)") }
        XCTAssertTrue(m.contains("didn\u{2019}t complete"), m)
        XCTAssertEqual(ejector.calls.filter(\.force).count, 1, "no retries after the window was closed")
    }
}

/// HolderScanner: zero targets, mmap paths (bundled walk, network mounts, unreadable regions), COPY-inherited writers.
final class FixPass2ScanTests: XCTestCase {
    override func setUp() { redirectTestLogs() }
    override func tearDown() {
        HolderScanner.debugFaults.withLock { $0 = HolderScanner.DebugFaults() }
    }

    func testScanOfNothingResolvableIsIncomplete() {
        let s = HolderScanner.scan(volumePaths: ["/Volumes/DUTEST_NOPE_\(UUID().uuidString.prefix(8))"], log: nil)
        XCTAssertEqual(s.scannedTargets, [])
        XCTAssertTrue(s.incomplete)
        XCTAssertTrue(s.incompleteReason?.contains("no mount point could be resolved") ?? false, s.incompleteReason ?? "-")
        XCTAssertEqual(SafetyGate.forceEjectBlockers(scan: s, disk: SafetyGateTests.disk, timeMachine: .idle).map(\.kind), [.scanIncomplete])
        // A volume still in the mount table whose statfs fails is named too (pure rule).
        XCTAssertEqual(HolderScanner.coverageReasons(requested: ["/Volumes/A"], targets: [], unreadable: ["/Volumes/A"]),
                       ["no mount point could be resolved", "/Volumes/A is mounted but could not be read"])
        XCTAssertEqual(HolderScanner.coverageReasons(requested: [], targets: [], unreadable: []), [])
    }

    /// Guard-sensitive: with the PATHINFO3 probe failing (offline-SMB behaviour) a bundled process is still found
    /// (region walk), and a plain CLI holder is not (proves the fault is real). Deleting the bundled branch fails this.
    func testBundledProcessIsWalkedNotProbed() throws {
        let fx = try Fixture.make("apfs", holders: ["mmap"], name: "DUTEST_T_PROBE")
        defer { fx.cleanup() }
        let p = try launchInFakeBundle(app: "DUMapper2.app", exe: "dumapper", args: ["mmap", fx.path("mmap.bin")])
        defer { p.terminate(); p.waitUntilExit() }
        let cli = try XCTUnwrap(fx.pids["mmap"])
        try waitFor { HolderScanner.scan(volumePaths: [fx.mount], log: nil).holders.contains { $0.pid == p.processIdentifier } }

        HolderScanner.debugFaults.withLock { $0.networkMountPresent = false; $0.probeAlwaysMisses = true }
        let s = HolderScanner.scan(volumePaths: [fx.mount], log: nil)
        let bundled = try XCTUnwrap(s.holders.first { $0.pid == p.processIdentifier }, "bundled mapper missed: \(s.holders.map(\.pid))")
        XCTAssertEqual(bundled.reasons, [.mappedFile(path: fx.path("mmap.bin"), writable: false)])
        XCTAssertNil(s.holders.first { $0.pid == cli }, "the probe fault hides the CLI holder (control)")
    }

    /// With a network share mounted, every process is walked: the CLI mmap holder is found although the probe fails.
    func testNetworkMountWalksEveryProcess() throws {
        let fx = try Fixture.make("apfs", holders: ["mmap"], name: "DUTEST_T_NETWALK")
        defer { fx.cleanup() }
        let cli = try XCTUnwrap(fx.pids["mmap"])
        HolderScanner.debugFaults.withLock { $0.networkMountPresent = true; $0.probeAlwaysMisses = true }
        XCTAssertTrue(HolderScanner.walkEveryProcess())
        let s = HolderScanner.scan(volumePaths: [fx.mount], log: nil)
        XCTAssertEqual(s.holders.first { $0.pid == cli }?.reasons, [.mappedFile(path: fx.path("mmap.bin"), writable: false)])
        XCTAssertFalse(s.incomplete, s.incompleteReason ?? "")
        XCTAssertLessThan(s.duration, 0.5, "walking every process: \(s.duration * 1000) ms")
        HolderScanner.debugFaults.withLock { $0.networkMountPresent = false }
        XCTAssertNil(HolderScanner.scan(volumePaths: [fx.mount], log: nil).holders.first { $0.pid == cli }, "control")
    }

    /// A region that cannot be read (vn_stat error) does not end the walk: later mappings are still found, and the scan
    /// says it is incomplete (S2: Force Eject blocked).
    func testRegionWalkContinuesPastAnUnreadableRegion() throws {
        let fx = try Fixture.make("apfs", holders: ["mmap"], name: "DUTEST_T_WALKERR")
        defer { fx.cleanup() }
        let cli = try XCTUnwrap(fx.pids["mmap"])
        let failing = SendableBox<UInt64>()
        HolderScanner.debugFaults.withLock {
            $0.networkMountPresent = true                 // walk this CLI process too
            $0.regionWalkError = { pid, region in
                guard pid == cli else { return nil }
                if failing.get() == nil { failing.set(region) }   // the first vnode region (the executable) fails, always
                return failing.get() == region ? EIO : nil
            }
        }
        let s = HolderScanner.scan(volumePaths: [fx.mount], log: nil)
        XCTAssertNotNil(failing.get())
        XCTAssertEqual(s.holders.first { $0.pid == cli }?.reasons, [.mappedFile(path: fx.path("mmap.bin"), writable: false)],
                       "the mapping after the unreadable region is still found")
        XCTAssertTrue(s.incomplete)
        XCTAssertTrue(s.incompleteReason?.contains("\(cli)") ?? false, s.incompleteReason ?? "-")
    }

    /// MAP_SHARED writable with inheritance COPY still writes the file: a writer (the SM_COW confirmation decides).
    func testSharedWritableMappingWithCopyInheritanceIsAWriter() throws {
        let fx = try Fixture.make("apfs", holders: ["mmapwc", "mmapp"], name: "DUTEST_T_WCOPY")
        defer { fx.cleanup() }
        let s = HolderScanner.scan(volumePaths: [fx.mount], log: nil)
        let wc = try XCTUnwrap(s.holders.first { $0.pid == fx.pids["mmapwc"] })
        XCTAssertEqual(wc.reasons, [.mappedFile(path: fx.path("mmapwc.bin"), writable: true)])
        XCTAssertTrue(wc.isWriter)
        let cow = try XCTUnwrap(s.holders.first { $0.pid == fx.pids["mmapp"] })
        XCTAssertFalse(cow.isWriter, "real copy-on-write stays a reader")
    }

    // MARK: helpers

    private func waitFor(_ timeout: TimeInterval = 5, _ cond: () -> Bool) throws {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end { if cond() { return }; Thread.sleep(forTimeInterval: 0.1) }
        XCTAssertTrue(cond(), "condition not met")
        if !cond() { throw XCTSkip("condition not met") }
    }
}

/// S3/S4: never-quit list, Finder graceful only, Quick Look under /System/ only, parent app by ppid, remedy app matching.
final class FixPass2TerminatorTests: XCTestCase {
    override func setUp() { redirectTestLogs() }

    @MainActor
    func testSessionProcessesAndEjectableAreNeverQuit() async {
        let t = Terminator()
        for id in ["com.apple.loginwindow", "com.apple.dock", "com.apple.systemuiserver", "com.apple.controlcenter",
                   "com.apple.WindowManager", "com.apple.notificationcenterui", "com.apple.Spotlight",
                   "com.apple.UserNotificationCenter", Remedies.ownBundleID] {
            let h = fake(99_951, "X", kind: .app, bundleID: id, reasons: [.workingDirectory(path: "/Volumes/FAKE")])
            let q = await t.quit(h, timeout: 0.1)
            XCTAssertEqual(q, .refused(.app), id)
            let f = await t.forceQuit(h)
            XCTAssertEqual(f, .refused(.app), id)
            let remedy = Remedies.remedy(for: h)
            XCTAssertTrue(remedy.neverTerminate, id)
            XCTAssertEqual(remedy.action, .none, id)
            XCTAssertTrue(remedy.explanation?.contains("can\u{2019}t be quit") ?? false, id)
        }
        // Our own pid, whatever the kind.
        let me = fake(getpid(), "Ejectable", kind: .cli, reasons: [.workingDirectory(path: "/Volumes/FAKE")])
        XCTAssertEqual(t.stop(me), .refused(.cli))
        let q = await t.quit(me.with(kind: .app), timeout: 0.1)
        XCTAssertEqual(q, .refused(.app))
        XCTAssertTrue(Remedies.remedy(for: me).neverTerminate)
    }

    /// Rows: no button, not in Quit All, the explanation instead.
    @MainActor
    func testSessionProcessRowHasNoButton() async throws {
        let dock = fake(99_952, "Dock", kind: .app, bundleID: "com.apple.dock", reasons: [.openFile(path: "/Volumes/FAKE/a.png", writing: false)])
        let flow = makeFakeFlow(FakeEjector(default: FixPass2FlowTests.busy), FakeScanner([dock]))
        flow.start()
        try await waitUntil(5) { flow.rows.count == 1 && flow.state == .blocked && !flow.requestsInFlight.soft }
        let row = flow.rows[0]
        XCTAssertNil(row.actionTitle)
        XCTAssertEqual(row.action, .none)
        XCTAssertNil(flow.quitAllAction(for: row))
        XCTAssertEqual(flow.primaryButton, .retry(enabled: true))
        XCTAssertEqual(row.detail().0, "a.png (open)\nDock is part of macOS and can\u{2019}t be quit. It usually lets go on its own; Ejectable retries.")
        flow.cancel()
    }

    @MainActor
    func testFinderIsNeverForceQuit() async {
        let t = Terminator()
        let finder = fake(99_953, "Finder", kind: .app, bundleID: "com.apple.finder", reasons: [.workingDirectory(path: "/Volumes/FAKE")])
        let f = await t.forceQuit(finder)
        XCTAssertEqual(f, .refused(.app))
        let q = await t.quit(finder, timeout: 0.1)
        XCTAssertTrue([.notFound, .pidMismatch].contains(q), "a normal quit is allowed (S6 then finds the synthetic pid is not Finder): \(q)")
        XCTAssertTrue(Terminator.isGracefulOnly("com.apple.finder"))
    }

    func testQuickLookExceptionNeedsSystemPath() {
        let ql = "/System/Library/Frameworks/QuickLook.framework/Versions/A/Resources/QuickLookSatellite"
        XCTAssertTrue(Terminator.isQuickLookException(fake(1, "QuickLookSatellite", kind: .daemon, reasons: [], path: ql)))
        for impostor in ["/Library/Application Support/X/QuickLookSatellite", "/Users/x/QuickLookSatellite", "/tmp/System/QuickLookSatellite"] {
            XCTAssertFalse(Terminator.isQuickLookException(fake(1, "QuickLookSatellite", kind: .daemon, reasons: [], path: impostor)), impostor)
        }
        let other = Holder(pid: 1, uid: getuid() + 1, ppid: 1, executablePath: ql, startTime: 1, displayName: "QuickLookSatellite",
                           bundleIdentifier: nil, bundleURL: nil, parentAppBundleURL: nil, kind: .daemon, reasons: [], volumePaths: [])
        XCTAssertFalse(Terminator.isQuickLookException(other), "another user's")
        XCTAssertFalse(Terminator.isQuickLookException(fake(1, "QuickLookSatellite", kind: .inaccessible, reasons: [], path: ql)))
    }

    func testParentAppByPPID() {
        XCTAssertEqual(Holder.parentIndex(candidatePIDs: [500], ppid: 1), 0, "a single instance")
        XCTAssertEqual(Holder.parentIndex(candidatePIDs: [500, 600], ppid: 600), 1, "open -n: the helper's own parent")
        XCTAssertNil(Holder.parentIndex(candidatePIDs: [500, 600], ppid: 1), "several, none the parent: never guess")
        XCTAssertNil(Holder.parentIndex(candidatePIDs: [], ppid: 1))
    }

    func testRemedyAppMatching() {
        func idx(_ id: String, _ name: String?, _ c: [(String?, String?)]) -> Int? {
            Remedies.remedyAppIndex(quitAppBundleID: id, quitAppName: name, candidates: c.map { (bundleID: $0.0, name: $0.1) })
        }
        XCTAssertNil(idx("com.apple.Music", "Music", [("com.apple.MusicRecognitionMac", "MusicRecognitionMac")]))
        XCTAssertEqual(idx("com.apple.Music", "Music", [("com.apple.MusicRecognitionMac", "x"), ("com.apple.Music", "Music")]), 1, "exact first")
        XCTAssertEqual(idx("com.apple.Photos", "Photos", [("com.apple.photos", "Photos")]), 0, "case-insensitive")
        let resolve = "com.blackmagic-design.DaVinciResolve"
        XCTAssertNil(idx(resolve, "DaVinci Resolve", [("com.blackmagic-design.DaVinciResolveProjectServer", "DaVinci Resolve Project Server")]))
        XCTAssertEqual(idx(resolve, "DaVinci Resolve", [("com.blackmagic-design.DaVinciResolveProjectServer", "DaVinci Resolve Project Server"),
                                                        ("com.blackmagic-design.DaVinciResolveLite", "DaVinci Resolve")]), 1)
        XCTAssertEqual(idx("com.example.App", nil, [("com.example.App.helper", "Helper")]), 0, "\".\" continues the id")
        XCTAssertNil(idx("com.example.App", nil, [("com.example.AppStore", "App Store")]))
    }
}

/// Live, fixture disk images only: single-volume unmount (sibling stays), and the watcher's attempt kind.
final class FixPass2LiveTests: XCTestCase {
    override func setUp() { redirectTestLogs() }

    func testUnmountVolumeLeavesTheSiblingMounted() throws {
        let fx = try Fixture.make("apfs", holders: ["fd"], name: "DUTEST_T_VOLA", secondVolume: "DUTEST_T_VOLB", holders2: ["cwd"])
        defer { fx.cleanup() }
        let sibling = try XCTUnwrap(fx.mount2)
        let disk = try XCTUnwrap(topo(forVolume: fx.mount))
        try XCTSkipUnless(disk.isVirtual && disk.volumes.count == 2, "\(disk.bsdName): \(disk.volumePaths)")
        let volume = try XCTUnwrap(disk.volumes.first { $0.path == fx.mount })
        let ejector = Ejector()

        // S5 still applies (dry-run ejector: even a broken guard could not send anything): a volume that is not the
        // snapshot's, and the boot disk under the app policy.
        let guarded = Ejector(dryRun: true)
        let stranger = VolumeInfo(path: "/Volumes/DUTEST_NOT_HERE", name: "x", fileSystem: "apfs", isNetwork: false, isInternal: nil,
                                  isRootFileSystem: false, isBrowsable: true, bsdName: "disk999s1")
        guard case .refused(.volumeNotOnDisk)? = unmountSync(guarded, stranger, disk) else { return XCTFail("stranger volume") }
        if let root = topo(forVolume: "/"), let rootVolume = root.volumes.first {
            guard case .refused? = unmountSync(guarded, rootVolume, root, policy: .externalDisks) else { return XCTFail("boot disk") }
        }
        XCTAssertEqual(guarded.diskArbitrationRequestCount, 0, "refused before any DiskArbitration request")

        // Busy (tail on A): the sibling's holder (cwd on B) is irrelevant to this unmount.
        guard case .busy? = unmountSync(ejector, volume, disk) else { return XCTFail("expected busy") }
        fx.killHolders()
        var r: EjectResult?
        for _ in 0..<3 {
            r = unmountSync(ejector, volume, disk)
            if case .volumeUnmounted? = r { break }
            Thread.sleep(forTimeInterval: 1)
        }
        guard case .volumeUnmounted? = r else { return XCTFail("\(String(describing: r))") }
        XCTAssertFalse(fx.isInMountTable(fx.mount), "A unmounted")
        XCTAssertTrue(fx.isInMountTable(sibling), "B stays mounted")
        XCTAssertNotNil(topo(bsdName: disk.bsdName), "the disk is still attached (not ejected)")
    }

    /// The companion flow in volume mode, live: holder quits -> only that volume is unmounted.
    @MainActor
    func testCompanionVolumeFlowUnmountsOnlyThatVolume() async throws {
        let fx = try Fixture.make("apfs", holders: ["fd"], name: "DUTEST_T_FLOWA", secondVolume: "DUTEST_T_FLOWB")
        defer { fx.cleanup() }
        let sibling = try XCTUnwrap(fx.mount2)
        let disk = try XCTUnwrap(topo(forVolume: fx.mount))
        try XCTSkipUnless(disk.isVirtual, "\(disk.bsdName) is not a disk image")
        let ejector = RecordingEjector(Ejector())
        var deps = EjectFlow.Dependencies.live(ejector: ejector, terminator: Terminator())
        deps.minRetryInterval = 0.5
        let flow = EjectFlow(disk: disk, displayName: fx.name, mode: .unmountVolume(fx.mount), dependencies: deps)
        let seed = offMain { HolderScanner.scan(volumePaths: disk.volumePaths, log: nil) }
        flow.startObserving(seed)
        try await waitUntil(30) { flow.rows.contains { $0.holder.pid == fx.pids["fd"] } }
        fx.killHolders()
        try await waitUntil(40) { flow.state.isFinished }
        XCTAssertEqual(flow.state, .volumeUnmounted)
        XCTAssertFalse(fx.isInMountTable(fx.mount))
        XCTAssertTrue(fx.isInMountTable(sibling), "the sibling volume stays mounted")
        XCTAssertTrue(ejector.calls.allSatisfy { $0.volume == fx.mount && !$0.force })
    }

    /// A raw DADiskEject while volumes are mounted shows an eject approval: reported as an eject attempt.
    func testForeignRawEjectIsAnEjectAttempt() throws {
        let fx = try Fixture.make("apfs", holders: ["fd"], name: "DUTEST_W_RAWEJ")
        defer { fx.cleanup() }
        let disk = try XCTUnwrap(topo(forVolume: fx.mount))
        try XCTSkipUnless(disk.isVirtual && "/dev/" + disk.bsdName == fx.device, "not our disk image")
        let rec = EventRecorder()
        let watcher = EjectWatcher { rec.add($0) }
        XCTAssertTrue(watcher.start())
        defer { watcher.stop() }
        // Another DiskArbitration client (not our Ejector, so not in EjectsInFlight) ejects the physical disk directly.
        let status = rawEject(bsdName: disk.bsdName, expectedAppearance: disk.appearanceTime)
        XCTAssertNotEqual(status, 0, "busy: a holder is there")
        XCTAssertTrue(spin(30) { rec.events(fx.mount).contains { $0.event.isFailed } }, "\(rec.events(fx.mount).map(\.event))")
        guard case .failed(_, _, _, let kind)? = rec.events(fx.mount).first(where: { $0.event.isFailed })?.event else {
            return XCTFail("no failed event")
        }
        XCTAssertEqual(kind, .eject)
    }

    // MARK: helpers

    private func unmountSync(_ e: Ejector, _ v: VolumeInfo, _ d: PhysicalDisk, policy: EjectPolicy = .diskImagesOnly) -> EjectResult? {
        let box = ResultBox()
        let done = DispatchSemaphore(value: 0)
        e.unmountVolume(v, of: d, policy: policy) { box.set($0); done.signal() }
        guard done.wait(timeout: .now() + 60) == .success else { return nil }
        return box.get()
    }

    /// DADiskEject on our own fixture's physical disk (re-checked: disk image, same appearance time). Returns the
    /// dissenter status (0 = ejected).
    private func rawEject(bsdName: String, expectedAppearance: Double?) -> UInt32 {
        guard let s = DASessionCreate(kCFAllocatorDefault),
              let d = DADiskCreateFromBSDName(kCFAllocatorDefault, s, bsdName),
              let desc = DADiskCopyDescription(d) as NSDictionary?,
              desc[kDADiskDescriptionDeviceProtocolKey as String] as? String == "Virtual Interface",
              (desc["DAAppearanceTime"] as? NSNumber)?.doubleValue == expectedAppearance else {
            XCTFail("refusing raw eject of \(bsdName)")
            return 0
        }
        let q = DispatchQueue(label: "test.raweject")
        DASessionSetDispatchQueue(s, q)
        defer { DASessionSetDispatchQueue(s, nil) }
        let box = SendableBox<UInt32>()
        let done = DispatchSemaphore(value: 0)
        final class Ctx { let box: SendableBox<UInt32>; let done: DispatchSemaphore; init(_ b: SendableBox<UInt32>, _ d: DispatchSemaphore) { box = b; self.done = d } }
        let ctx = Unmanaged.passRetained(Ctx(box, done)).toOpaque()
        DADiskEject(d, DADiskEjectOptions(kDADiskEjectOptionDefault), { _, dissenter, c in
            let ctx = Unmanaged<Ctx>.fromOpaque(c!).takeRetainedValue()
            ctx.box.set(dissenter.map { UInt32(bitPattern: DADissenterGetStatus($0)) } ?? 0)
            ctx.done.signal()
        }, ctx)
        _ = done.wait(timeout: .now() + 30)
        return box.get() ?? 0
    }
}

// MARK: - Shared helpers

/// A flow over fakes (no timer: tests tick or pump).
@MainActor
func makeFakeFlow(_ ejector: any EjectPerforming, _ scanner: FakeScanner, disk: PhysicalDisk = SafetyGateTests.disk,
                  mode: EjectFlow.Mode = .ejectDisk,
                  resolve: @escaping @MainActor (pid_t, [String]) -> Holder? = { _, _ in nil }) -> EjectFlow {
    var d = EjectFlow.Dependencies(ejector: ejector, terminator: Terminator(log: nil),
                                   scan: { scanner.scan($0) }, timeMachine: { _ in .idle },
                                   resolvePID: resolve, flush: { _ in },
                                   rescan: { disk, pids in scanner.scan(disk, only: pids) }, openURL: { _ in }, log: nil)
    d.rescanInterval = 0
    d.minRetryInterval = 0
    d.slowRetryInterval = 0
    return EjectFlow(disk: disk, displayName: "FAKE", mode: mode, dependencies: d)
}

/// Ticks the flow every 20 ms until `condition` holds.
@MainActor
func pumpFlow(_ flow: EjectFlow, _ timeout: TimeInterval = 5, until condition: @MainActor () -> Bool) async throws {
    let end = Date().addingTimeInterval(timeout)
    while Date() < end {
        if condition() { return }
        flow.tick()
        try await Task.sleep(nanoseconds: 20_000_000)
    }
    XCTAssertTrue(condition(), "condition not met within \(timeout) s")
    if !condition() { throw CancellationError() }
}

/// Copies duhold to .build/fixtures/<app>/Contents/MacOS/<exe> and runs it (cwd /).
func launchInFakeBundle(app: String, exe: String, args: [String]) throws -> Process {
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
