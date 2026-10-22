import EjectKit
import XCTest

/// The app's eject state machine (EjectFlow, driven by the app's EjectCoordinator). Acceptance 6: every request uses
/// `EjectPolicy.externalDisks`, and `force: true` is sent only after the confirmation path ran (S1/S2).
/// Fakes for DiskArbitration and the scanner; synthetic holders never match a real process (S6), so the real
/// Terminator inside the flow can never act on anything.
final class EjectFlowTests: XCTestCase {
    override func setUp() { redirectTestLogs() }

    static let busy = EjectResult.busy(dissenterPID: nil, status: 0xC010, step: .unmount(bsdName: "disk99"))
    let reader = fake(99_901, "tail", reasons: [.openFile(path: "/Volumes/FAKE/fd.txt", writing: false)])
    let mapper = fake(99_902, "duhold", reasons: [.mappedFile(path: "/Volumes/FAKE/mmap.bin", writable: false)])
    let writer = fake(99_903, "duhold", reasons: [.openFile(path: "/Volumes/FAKE/fdw.txt", writing: true)])

    @MainActor
    func testSoftOnlyAndExternalDisksPolicyThroughBlockQuitAllAndAutoRetry() async throws {
        let ejector = FakeEjector(default: Self.busy)
        let scanner = FakeScanner([reader, writer])
        let flow = makeFlow(ejector, scanner)
        XCTAssertEqual(flow.policy, .externalDisks)
        flow.start()
        try await waitUntil(5) { flow.state == .blocked && flow.rows.count == 2 && flow.timeMachine == .idle }

        // A writer: Force Eject and Quit All are both unavailable, and say why.
        XCTAssertFalse(flow.canForceEject)
        XCTAssertNil(flow.requestForceEject())
        XCTAssertEqual(flow.blockers.map(\.message), ["duhold is writing fdw.txt"])
        XCTAssertFalse(flow.canQuitAll)
        XCTAssertEqual(flow.primaryButton, .quitAll(enabled: false))
        XCTAssertEqual(flow.quitAllHint, "duhold is writing fdw.txt. Stop it with its own button first.")
        XCTAssertEqual(flow.summary, "2 processes are using it.")
        flow.quitAll()                                  // refused: no state change
        XCTAssertEqual(flow.state, .blocked)
        XCTAssertEqual(flow.perform(.stop, on: writer.pid), .needsWriterConfirmation, "S3: stopping a writer is confirmed first")
        XCTAssertEqual(flow.perform(.forceQuit, on: reader.pid), .unavailable, "rows only accept what they offer")
        XCTAssertEqual(flow.perform(.kill, on: reader.pid), .unavailable, "Kill only after Stop")

        // Writer gone: Force Eject available (still behind confirmation), Quit All available (SIGTERM for CLI).
        scanner.set([reader, mapper])
        try await pump(flow) { flow.rows.count == 2 && flow.blockers.isEmpty }
        XCTAssertGreaterThan(scanner.partialScans, 0, "1 s ticks re-check known holders only")
        XCTAssertTrue(flow.canForceEject)
        XCTAssertTrue(flow.canQuitAll)
        flow.quitAll()
        XCTAssertEqual(flow.state, .quitting)
        // The synthetic pids don't exist: Terminator verifies first (S6), reports notFound and sends nothing.
        XCTAssertTrue(flow.rows.allSatisfy { $0.status == .idle }, "\(flow.rows.map(\.status))")

        // Holders clear -> automatic retry, soft, until DA says ejected.
        scanner.set([])
        try await pump(flow) { ejector.calls.count >= 3 }
        ejector.respond([.ejected])
        for _ in 0..<50 where flow.state != .ejected {
            flow.tick()
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(flow.state, .ejected)
        XCTAssertGreaterThanOrEqual(ejector.calls.count, 3)
        XCTAssertTrue(ejector.calls.allSatisfy { !$0.force }, "S1: nothing but soft ejects without confirmation")
        XCTAssertTrue(ejector.calls.allSatisfy { $0.policy == .externalDisks })
        XCTAssertTrue(ejector.calls.allSatisfy { $0.bsdName == "disk99" })
    }

    @MainActor
    func testForceOnlyAfterConfirmation() async throws {
        let ejector = FakeEjector(default: Self.busy)
        let flushed = Box<[[String]]>([])
        let flow = makeFlow(ejector, FakeScanner([mapper]), flush: { paths in flushed.update { $0.append(paths) } })
        flow.start()
        try await waitUntil(5) { flow.state == .blocked && flow.canForceEject }
        XCTAssertEqual(flow.risks.map(\.message), ["duhold has media mapped in memory and may crash"])

        let c = try XCTUnwrap(flow.requestForceEject())
        XCTAssertEqual(c.holders.map(\.pid), [mapper.pid])
        for _ in 0..<5 { flow.tick() }
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertFalse(ejector.calls.contains { $0.force }, "showing the confirmation sends nothing")

        ejector.respond([.ejected])
        let confirmed = await flow.confirmForceEject(c)
        XCTAssertEqual(confirmed, .sent)
        try await waitUntil(5) { flow.state == .forced }
        let forced = ejector.calls.filter(\.force)
        XCTAssertEqual(forced.count, 1)
        XCTAssertEqual(forced.first?.policy, .externalDisks)
        XCTAssertEqual(flushed.value, [["/Volumes/FAKE"]], "volumes flushed before the forced request (S2)")
        let again = await flow.confirmForceEject(c)
        XCTAssertEqual(again, .refused, "a confirmation is single-use")
        XCTAssertEqual(ejector.calls.filter(\.force).count, 1)
    }

    @MainActor
    func testConfirmationRechecksTheGateOnAFreshScan() async throws {
        let ejector = FakeEjector(default: Self.busy)
        let scanner = FakeScanner([reader])
        let flow = makeFlow(ejector, scanner)
        flow.start()
        try await waitUntil(5) { flow.state == .blocked && flow.canForceEject }
        let c = try XCTUnwrap(flow.requestForceEject())
        scanner.set([reader, writer])                   // a writer appears while the confirmation is up
        let confirmed = await flow.confirmForceEject(c)
        XCTAssertEqual(confirmed, .refused)
        XCTAssertEqual(flow.state, .blocked)
        XCTAssertEqual(flow.blockers.map(\.kind), [.writer])
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertFalse(ejector.calls.contains { $0.force })
    }

    @MainActor
    func testTimeMachineFailsClosed() async throws {
        let tm = Box(TimeMachineFacts.unknown)
        let flow = makeFlow(FakeEjector(default: Self.busy), FakeScanner([reader]), tm: tm)
        flow.start()
        try await waitUntil(5) { flow.state == .blocked }
        XCTAssertEqual(flow.blockers.map(\.kind), [.timeMachineUnknown])
        XCTAssertNil(flow.requestForceEject())
        tm.value = TimeMachineFacts(backupRunning: true, diskIsDestination: true)
        for _ in 0..<5 { flow.tick() }                  // facts refresh every 5th tick
        try await waitUntil(5) { flow.blockers.map(\.kind) == [.timeMachine] }
        tm.value = .idle
        for _ in 0..<5 { flow.tick() }
        try await waitUntil(5) { flow.canForceEject }
    }

    @MainActor
    func testCancelStopsRetriesAndInvalidatesConfirmations() async throws {
        let ejector = FakeEjector(default: Self.busy)
        let scanner = FakeScanner([reader])
        let flow = makeFlow(ejector, scanner)
        flow.start()
        try await waitUntil(5) { flow.canForceEject }
        let c = try XCTUnwrap(flow.requestForceEject())
        flow.cancel()
        XCTAssertEqual(flow.state, .cancelled)
        let before = ejector.calls.count
        scanner.set([])
        for _ in 0..<5 { flow.tick() }
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(ejector.calls.count, before, "no retries after cancel")
        let confirmed = await flow.confirmForceEject(c)
        XCTAssertEqual(confirmed, .refused)
        XCTAssertNil(flow.requestForceEject())
        XCTAssertFalse(ejector.calls.contains { $0.force })
    }

    @MainActor
    func testConfirmationFromAnotherFlowIsRejected() async throws {
        let ejector = FakeEjector(default: Self.busy)
        let a = makeFlow(ejector, FakeScanner([reader]))
        let b = makeFlow(ejector, FakeScanner([reader]))
        a.start(); b.start()
        try await waitUntil(5) { a.canForceEject && b.canForceEject }
        let ca = try XCTUnwrap(a.requestForceEject())
        let foreign = await b.confirmForceEject(ca)
        XCTAssertEqual(foreign, .refused)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertFalse(ejector.calls.contains { $0.force })
    }

    /// Only a writing CLI tool: Quit All stays the (disabled) primary button and says to stop the writer first.
    @MainActor
    func testWriterOnlyKeepsQuitAllWithHint() async throws {
        let flow = makeFlow(FakeEjector(default: Self.busy), FakeScanner([writer]))
        flow.start()
        try await waitUntil(5) { flow.state == .blocked && flow.rows.count == 1 }
        XCTAssertEqual(flow.primaryButton, .quitAll(enabled: false))
        XCTAssertEqual(flow.quitAllHint, "duhold is writing fdw.txt. Stop it with its own button first.")
        XCTAssertEqual(flow.blockers.map(\.kind), [.writer])
        flow.cancel()
    }

    /// Finder-companion mode: someone else's eject failed. No eject is sent up front; once the holders clear the
    /// flow soft-retries (S1), with the same policy, and never forces on its own.
    @MainActor
    func testObservingAForeignFailureOnlySoftRetriesAfterHoldersClear() async throws {
        let ejector = FakeEjector(default: .ejected)
        let scanner = FakeScanner([reader])
        let flow = makeFlow(ejector, scanner)
        let seed = HolderScan(volumePaths: ["/Volumes/FAKE"], holders: [reader], deniedPIDs: [], duration: 0, scannedAt: Date())
        flow.startObserving(seed)
        XCTAssertTrue(flow.observing)
        XCTAssertEqual(flow.state, .blocked)
        XCTAssertEqual(flow.rows.map(\.holder.pid), [reader.pid], "rows come from the watcher's scan immediately")
        for _ in 0..<8 { flow.tick() }
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertTrue(ejector.calls.isEmpty, "nothing is ejected while the holder is there")
        scanner.set([])
        try await pump(flow) { flow.state == .ejected }
        XCTAssertEqual(ejector.calls.count, 1)
        XCTAssertTrue(ejector.calls.allSatisfy { !$0.force && $0.policy == .externalDisks })
    }

    /// DA names a pid the scan cannot see (root): it becomes a row, never actionable; Try Again replaces Quit All.
    @MainActor
    func testDissenterNotInScanBecomesARow() async throws {
        let ejector = FakeEjector(default: .busy(dissenterPID: 1, status: 0xC010, step: .unmount(bsdName: "disk99")))
        let flow = makeFlow(ejector, FakeScanner([]), resolve: { pid, vols in HolderResolver.holder(forPID: pid, volumePaths: vols) })
        flow.start()
        try await waitUntil(5) { flow.state == .blocked && flow.rows.count == 1 }
        let row = flow.rows[0]
        XCTAssertEqual(row.holder.pid, 1)
        XCTAssertEqual(row.holder.kind, .inaccessible)
        XCTAssertTrue(row.isDissenterOnly)
        XCTAssertEqual(row.action, .none)
        XCTAssertEqual(flow.perform(.stop, on: 1), .unavailable)
        XCTAssertEqual(flow.perform(.quit, on: 1), .unavailable)
        XCTAssertEqual(flow.summary, "1 system process is using it.")
        XCTAssertFalse(flow.canQuitAll)
        flow.cancel()
    }

    /// The S2 re-check at confirmation runs off the main thread: the main actor stays free while tmutil / the scan run.
    @MainActor
    func testConfirmationRecheckRunsOffTheMainThread() async throws {
        let ejector = FakeEjector(default: Self.busy)
        let onMain = Box<[Bool]>([])
        let scanner = FakeScanner([reader])
        var d = EjectFlow.Dependencies(ejector: ejector, terminator: Terminator(log: nil),
                                       scan: { disk in onMain.update { $0.append(Thread.isMainThread) }; return scanner.scan(disk) },
                                       timeMachine: { _ in onMain.update { $0.append(Thread.isMainThread) }; Thread.sleep(forTimeInterval: 0.3); return .idle },
                                       resolvePID: { _, _ in nil }, openURL: { _ in }, log: nil)
        d.rescanInterval = 0
        let flow = EjectFlow(disk: SafetyGateTests.disk, displayName: "FAKE", dependencies: d)
        flow.start()
        try await waitUntil(5) { flow.canForceEject }
        let c = try XCTUnwrap(flow.requestForceEject())
        ejector.respond([.ejected])
        let task = Task { await flow.confirmForceEject(c) }
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertFalse(flow.canForceEject, "Force Eject is off while re-checking")
        XCTAssertEqual(flow.statusText, "Checking again before force ejecting\u{2026}")
        let confirmed = await task.value
        XCTAssertEqual(confirmed, .sent)
        try await waitUntil(5) { flow.state == .forced }
        XCTAssertFalse(onMain.value.contains(true), "scan / tmutil ran on the main thread: \(onMain.value)")
    }

    /// Every volume unmounted but DADiskEject dissented (Ejectable=0 drives): success, "safe to disconnect".
    @MainActor
    func testUnmountedNotEjectedIsSuccess() async throws {
        let ejector = FakeEjector(default: .unmountedNotEjected(status: 0xC010))
        let flow = makeFlow(ejector, FakeScanner([]))
        flow.start()
        try await waitUntil(5) { flow.state == .unmounted }
        XCTAssertTrue(flow.state.isFinished)
        XCTAssertEqual(flow.statusText, "Unmounted. It is safe to disconnect.")
        XCTAssertEqual(ejector.calls.count, 1)
    }

    /// An incomplete full scan (deadline) keeps Force Eject off until a complete one arrives.
    @MainActor
    func testIncompleteScanBlocksForceEject() async throws {
        let scanner = FakeScanner([reader])
        scanner.incomplete = true
        let flow = makeFlow(FakeEjector(default: Self.busy), scanner)
        flow.start()
        try await waitUntil(5) { flow.state == .blocked && flow.rows.count == 1 }
        XCTAssertEqual(flow.blockers.map(\.kind), [.scanIncomplete])
        XCTAssertNil(flow.requestForceEject())
        scanner.incomplete = false
        for _ in 0..<4 { flow.tick() }                  // every 4th tick is a full scan
        try await waitUntil(5) { flow.canForceEject }
        flow.cancel()
    }

    /// A forced eject refused because the disk's volumes changed after confirmation (the disk itself is still there):
    /// nothing was forced, the flow goes back to blocked with a note instead of claiming "ejected". Fixture disk for a
    /// real identity; the ejector is a fake, so nothing is sent to DiskArbitration.
    @MainActor
    func testForceRefusedForChangedVolumesReturnsToBlocked() async throws {
        let fx = try Fixture.make("apfs", holders: [], name: "DUTEST_T_FVOL")
        defer { fx.cleanup() }
        let disk = try XCTUnwrap(topo(forVolume: fx.mount))
        let ejector = FakeEjector(default: .busy(dissenterPID: nil, status: 0xC010, step: .unmount(bsdName: disk.bsdName)))
        var d = EjectFlow.Dependencies(ejector: ejector, terminator: Terminator(log: nil), scan: { FakeScanner([]).scan($0) },
                                       timeMachine: { _ in .idle }, resolvePID: { _, _ in nil }, openURL: { _ in }, log: nil)
        d.rescanInterval = 0
        d.minRetryInterval = 1000
        let flow = EjectFlow(disk: disk, displayName: fx.name, dependencies: d)
        flow.start()
        try await waitUntil(5) { flow.state == .blocked && flow.canForceEject }
        let c = try XCTUnwrap(flow.requestForceEject())
        ejector.respond([.refused(.diskChanged(bsdName: disk.bsdName))])
        let confirmed = await flow.confirmForceEject(c)
        XCTAssertEqual(confirmed, .sent)
        try await waitUntil(5) { flow.state == .blocked && flow.note != nil }
        XCTAssertTrue(flow.note?.contains("volumes changed") ?? false, flow.note ?? "-")
        XCTAssertTrue(fx.isMounted)
        flow.cancel()
    }

    /// End to end against a fixture disk image with the real Ejector and scanner: blocked by a holder, holder
    /// killed, automatic soft retry ejects the image.
    @MainActor
    func testLiveFlowAgainstFixture() async throws {
        let fx = try Fixture.make("apfs", holders: ["fd"], name: "DUTEST_T_FLOW")
        defer { fx.cleanup() }
        let disk = try XCTUnwrap(topo(forVolume: fx.mount))
        // The flow below uses the app policy (.externalDisks): anything but our own disk image stops the test here.
        try XCTSkipUnless(disk.isVirtual, "\(disk.bsdName) is not a disk image")
        let ejector = RecordingEjector(Ejector())
        var deps = EjectFlow.Dependencies.live(ejector: ejector, terminator: Terminator())
        deps.minRetryInterval = 0.5
        let flow = EjectFlow(disk: disk, displayName: fx.name, dependencies: deps)
        flow.start()
        try await waitUntil(30) { flow.state == .blocked && flow.rows.contains { $0.holder.pid == fx.pids["fd"] } }
        XCTAssertEqual(flow.rows.first?.actionTitle, "Stop")
        XCTAssertTrue(fx.isMounted)
        fx.killHolders()
        try await waitUntil(40) { flow.state == .ejected }
        XCTAssertFalse(fx.isMounted)
        XCTAssertTrue(ejector.calls.allSatisfy { !$0.force && $0.policy == .externalDisks })
        flow.cancel()
    }

    // MARK: - Phase 4: remedy rows, force rating, Try Again

    /// Quick Look daemon: Stop (S4 exception), covered by Quit All. Spotlight: its settings, never stopped, keeps Quit
    /// All off with its explanation. Finder: no button, the user closes the window.
    @MainActor
    func testRemedyRows() async throws {
        let ql = fake(99_911, "QuickLookUIService", kind: .daemon, reasons: [.openFile(path: "/Volumes/FAKE/a.jpg", writing: false)],
                      path: "/System/Library/Frameworks/QuickLookUI.framework/Versions/A/XPCServices/QuickLookUIService.xpc/Contents/MacOS/QuickLookUIService")
        let md = fake(99_912, "mdworker_shared", kind: .daemon, reasons: [.openFile(path: "/Volumes/FAKE/b.mov", writing: false)])
        let finder = fake(99_913, "Finder", kind: .app, bundleID: "com.apple.finder", reasons: [.workingDirectory(path: "/Volumes/FAKE")])
        let opened = Box<[URL]>([])
        let scanner = FakeScanner([ql, md])
        let flow = makeFlow(FakeEjector(default: Self.busy), scanner, openURL: { url in opened.update { $0.append(url) } })
        flow.start()
        try await waitUntil(5) { flow.state == .blocked && flow.rows.count == 2 && flow.timeMachine == .idle }

        let qlRow = try XCTUnwrap(flow.rows.first { $0.holder.pid == ql.pid })
        XCTAssertEqual(qlRow.action, .stop)
        XCTAssertEqual(qlRow.actionTitle, "Stop")
        XCTAssertEqual(qlRow.title, "Quick Look (QuickLookUIService)")
        XCTAssertEqual(qlRow.detail().0, "a.jpg (open)\nQuick Look is holding a preview. Safe to stop; it restarts on its own.")
        XCTAssertEqual(flow.quitAllAction(for: qlRow), .stop)

        let mdRow = try XCTUnwrap(flow.rows.first { $0.holder.pid == md.pid })
        let spotlightURL = try XCTUnwrap(URL(string: Remedies.spotlightSettingsURL))
        XCTAssertEqual(mdRow.action, .openSettings(spotlightURL))
        XCTAssertEqual(mdRow.actionTitle, "Open Spotlight Settings")
        XCTAssertEqual(mdRow.title, "Spotlight (mdworker_shared)")
        XCTAssertNil(flow.quitAllAction(for: mdRow), "S4: never quit")
        XCTAssertEqual(flow.primaryButton, .quitAll(enabled: false))
        XCTAssertEqual(flow.quitAllHint, "Spotlight isn\u{2019}t something Ejectable quits; see its row.")
        XCTAssertEqual(flow.perform(.openSettings(spotlightURL), on: md.pid), .started)
        XCTAssertEqual(opened.value, [spotlightURL])
        XCTAssertEqual(flow.forceRating, .safe(except: ["Spotlight"]))
        XCTAssertEqual(flow.forceRating.text, "Force Eject is safe: nothing is writing to this drive except Spotlight")

        // Only Quick Look left: Quit All covers it (SIGTERM; the synthetic pid does not exist, so S6 sends nothing).
        scanner.set([ql])
        try await pump(flow) { flow.rows.count == 1 }
        XCTAssertEqual(flow.primaryButton, .quitAll(enabled: true))
        flow.quitAll()
        XCTAssertEqual(flow.state, .quitting)

        // Finder only: nothing quittable -> Try Again, the hint says what to do.
        scanner.set([finder])
        try await pump(flow) { flow.rows.map(\.holder.pid) == [finder.pid] }
        let fRow = flow.rows[0]
        XCTAssertEqual(fRow.action, .none)
        XCTAssertNil(fRow.actionTitle)
        XCTAssertNil(flow.quitAllAction(for: fRow))
        XCTAssertEqual(flow.primaryButton, .retry(enabled: true))
        XCTAssertEqual(fRow.detail().0, "working directory\nA Finder window is showing this drive. Close it.")
        flow.cancel()
    }

    @MainActor
    func testForceRatingFollowsHolders() async throws {
        let cwd = fake(99_921, "sleep", reasons: [.workingDirectory(path: "/Volumes/FAKE/cwd")])
        let scanner = FakeScanner([reader, cwd])
        let flow = makeFlow(FakeEjector(default: Self.busy), scanner)
        XCTAssertFalse(flow.canForceEject)
        flow.start()
        try await waitUntil(5) { flow.state == .blocked && flow.rows.count == 2 && flow.timeMachine == .idle }
        XCTAssertEqual(flow.forceRating, .safe(except: []))
        XCTAssertEqual(flow.forceRating.text, "Force Eject is safe: nothing is writing to this drive")
        XCTAssertTrue(flow.canForceEject)

        scanner.set([reader, cwd, mapper])
        try await pump(flow) { flow.rows.count == 3 }
        XCTAssertEqual(flow.forceRating.text, "Force Eject is risky: media mapped by duhold")
        XCTAssertTrue(flow.canForceEject, "risky is still allowed (confirmed)")

        scanner.set([reader, writer])
        try await pump(flow) { flow.rows.count == 2 && !flow.blockers.isEmpty }
        XCTAssertEqual(flow.forceRating.text, "Force Eject is unavailable: duhold is writing fdw.txt")
        XCTAssertTrue(flow.forceRating.isBlocked)
        XCTAssertFalse(flow.canForceEject)
        flow.cancel()
    }

    /// "Try Again" (nothing quittable: a root dissenter) runs a full rescan AND one soft eject, never forced.
    @MainActor
    func testTryAgainRescansAndSoftEjects() async throws {
        let ejector = FakeEjector(default: .busy(dissenterPID: 1, status: 0xC010, step: .unmount(bsdName: "disk99")))
        let scanner = FakeScanner([])
        let flow = makeFlow(ejector, scanner, resolve: { pid, vols in HolderResolver.holder(forPID: pid, volumePaths: vols) },
                            retryInterval: 3600)
        flow.start()
        try await waitUntil(5) { flow.state == .blocked && flow.rows.count == 1 && !flow.state.isFinished }
        try await Task.sleep(nanoseconds: 100_000_000)
        let row = flow.rows[0]
        XCTAssertEqual(row.holder.kind, .inaccessible)
        XCTAssertEqual(row.reasonText, "System process launchd (1) is using it")
        XCTAssertEqual(row.title, "launchd")
        XCTAssertEqual(flow.primaryButton, .retry(enabled: true))
        XCTAssertEqual(flow.forceRating.text, "Force Eject is risky: launchd can\u{2019}t be inspected")

        let scans = scanner.fullScans, ejects = ejector.calls.count
        XCTAssertEqual(ejects, 1, "no automatic retry within the (long) retry interval")
        flow.retryNow()
        XCTAssertEqual(flow.state, .retrying)
        try await waitUntil(5) { scanner.fullScans > scans && ejector.calls.count > ejects && flow.state == .blocked }
        XCTAssertEqual(ejector.calls.count, ejects + 1, "one soft eject per click")
        XCTAssertTrue(ejector.calls.allSatisfy { !$0.force && $0.policy == .externalDisks }, "S1")
        flow.cancel()
    }

    // MARK: - Helpers

    /// Ticks the flow (as its 1 s timer would) every 20 ms until `condition` holds.
    @MainActor
    private func pump(_ flow: EjectFlow, _ timeout: TimeInterval = 5, until condition: @MainActor () -> Bool) async throws {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if condition() { return }
            flow.tick()
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertTrue(condition(), "condition not met within \(timeout) s")
        if !condition() { throw CancellationError() }
    }

    @MainActor
    private func makeFlow(_ ejector: any EjectPerforming, _ scanner: FakeScanner, tm: Box<TimeMachineFacts> = Box(.idle),
                          resolve: @escaping @MainActor (pid_t, [String]) -> Holder? = { _, _ in nil },
                          flush: @escaping @Sendable ([String]) -> Void = { _ in },
                          openURL: @escaping @MainActor (URL) -> Void = { _ in },
                          retryInterval: TimeInterval = 0) -> EjectFlow {
        var d = EjectFlow.Dependencies(ejector: ejector, terminator: Terminator(log: nil),
                                       scan: { scanner.scan($0) }, timeMachine: { _ in tm.value },
                                       resolvePID: resolve, flush: flush,
                                       rescan: { disk, pids in scanner.scan(disk, only: pids) }, openURL: openURL, log: nil)
        d.rescanInterval = 0
        d.minRetryInterval = retryInterval
        d.slowRetryInterval = retryInterval
        return EjectFlow(disk: SafetyGateTests.disk, displayName: "FAKE", dependencies: d)
    }
}

struct EjectCall: Sendable {
    let bsdName: String
    let force: Bool
    let policy: EjectPolicy
    /// Single-volume unmount: the volume's mount point (nil = a whole-disk eject).
    var volume: String? = nil
}

/// DiskArbitration stand-in: records every request, answers from a queue (then `default`) on a background queue.
final class FakeEjector: EjectPerforming, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [EjectCall] = []
    private var queued: [EjectResult] = []
    private let fallback: EjectResult

    init(default fallback: EjectResult) { self.fallback = fallback }

    var calls: [EjectCall] { lock.withLock { _calls } }
    func respond(_ results: [EjectResult]) { lock.withLock { queued += results } }

    /// Answer delay (tests of a soft request that is still pending).
    var delay: TimeInterval {
        get { lock.withLock { _delay } }
        set { lock.withLock { _delay = newValue } }
    }
    private var _delay: TimeInterval = 0.01

    func eject(disk: PhysicalDisk, force: Bool, policy: EjectPolicy, completion: @escaping @Sendable (EjectResult) -> Void) {
        answer(EjectCall(bsdName: disk.bsdName, force: force, policy: policy), completion)
    }

    func unmountVolume(_ volume: VolumeInfo, of disk: PhysicalDisk, force: Bool, policy: EjectPolicy,
                       completion: @escaping @Sendable (EjectResult) -> Void) {
        answer(EjectCall(bsdName: disk.bsdName, force: force, policy: policy, volume: volume.path), completion)
    }

    private var inFlight = 0
    private var _maxConcurrent = 0
    /// The most requests that were waiting for an answer at the same time (a flow never sends two at once).
    var maxConcurrent: Int { lock.withLock { _maxConcurrent } }

    private func answer(_ call: EjectCall, _ completion: @escaping @Sendable (EjectResult) -> Void) {
        let (r, d): (EjectResult, TimeInterval) = lock.withLock {
            _calls.append(call)
            inFlight += 1
            _maxConcurrent = max(_maxConcurrent, inFlight)
            return (queued.isEmpty ? fallback : queued.removeFirst(), _delay)
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + d) { [self] in
            lock.withLock { inFlight -= 1 }
            completion(r)
        }
    }
}

/// Wraps the real Ejector and records what the flow asked for.
final class RecordingEjector: EjectPerforming, @unchecked Sendable {
    private let inner: Ejector
    private let lock = NSLock()
    private var _calls: [EjectCall] = []
    init(_ inner: Ejector) { self.inner = inner }
    var calls: [EjectCall] { lock.withLock { _calls } }
    func eject(disk: PhysicalDisk, force: Bool, policy: EjectPolicy, completion: @escaping @Sendable (EjectResult) -> Void) {
        lock.withLock { _calls.append(EjectCall(bsdName: disk.bsdName, force: force, policy: policy)) }
        inner.eject(disk: disk, force: force, policy: policy, completion: completion)
    }
    func unmountVolume(_ volume: VolumeInfo, of disk: PhysicalDisk, force: Bool, policy: EjectPolicy,
                       completion: @escaping @Sendable (EjectResult) -> Void) {
        lock.withLock { _calls.append(EjectCall(bsdName: disk.bsdName, force: force, policy: policy, volume: volume.path)) }
        inner.unmountVolume(volume, of: disk, force: force, policy: policy, completion: completion)
    }
}

final class FakeScanner: @unchecked Sendable {
    private let lock = NSLock()
    private var holders: [Holder]
    private var _incomplete = false
    private var _nothingScanned = false
    /// Full scans resolve no mount point at all (every statfs failed) but do NOT say incomplete: the flow's own gate
    /// must block Force Eject anyway.
    var nothingScanned: Bool {
        get { lock.withLock { _nothingScanned } }
        set { lock.withLock { _nothingScanned = newValue } }
    }
    init(_ holders: [Holder]) { self.holders = holders }
    func set(_ h: [Holder]) { lock.withLock { holders = h } }
    /// Full scans report `incomplete` (deadline) while true.
    var incomplete: Bool {
        get { lock.withLock { _incomplete } }
        set { lock.withLock { _incomplete = newValue } }
    }
    private(set) var partialScans = 0
    private var _fullScans = 0
    var fullScans: Int { lock.withLock { _fullScans } }
    /// The volume paths full scans were asked for (volume mode scans only that volume).
    private(set) var scannedPaths: [[String]] = []
    func scan(_ disk: PhysicalDisk) -> HolderScan {
        let (h, inc, none) = lock.withLock { _fullScans += 1; scannedPaths.append(disk.volumePaths); return (holders, _incomplete, _nothingScanned) }
        return HolderScan(volumePaths: disk.volumePaths, holders: h, deniedPIDs: [], duration: 0, scannedAt: Date(),
                          scannedTargets: none ? [] : disk.volumePaths, incomplete: inc, incompleteReason: inc ? "deadline (fake)" : nil)
    }
    func scan(_ disk: PhysicalDisk, only pids: [pid_t]) -> HolderScan {
        let h = lock.withLock { partialScans += 1; return holders.filter { pids.contains($0.pid) } }
        return HolderScan(volumePaths: disk.volumePaths, holders: h, deniedPIDs: [], duration: 0, scannedAt: Date())
    }
}

final class Box<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: T
    init(_ v: T) { _value = v }
    var value: T {
        get { lock.withLock { _value } }
        set { lock.withLock { _value = newValue } }
    }
    func update(_ f: (inout T) -> Void) { lock.withLock { f(&_value) } }
}
