import AppKit
@testable import EjectKit
import XCTest

/// S3, per-kind grace (2026-10-22 real-drive session: AirDrop.appex never answered terminate() and the row made the user
/// wait 60 s for Force Quit). Graceful first; each row's force action is one hover / Tab away while it waits, and its
/// primary button once the kind's grace has passed. Never automatic, never from Quit All, one process per click.
final class GraceTests: XCTestCase {
    override func setUp() { redirectTestLogs() }

    // MARK: Pure: the table, the labels, the countdown, the reveal

    @MainActor
    func testGraceTablePerKind() {
        let g = QuitGrace.standard
        XCTAssertEqual(g.seconds(for: .app), 60)
        XCTAssertEqual(g.seconds(for: .helper), 15)
        XCTAssertEqual(g.seconds(for: .appExtension), 3)
        XCTAssertEqual(g.seconds(for: .cli), 5)
        XCTAssertEqual(g.seconds(for: .daemon), 5, "only the Quick Look exception is ever stopped, by signal like a CLI tool")
        XCTAssertEqual(Terminator.defaultQuitTimeout, 60)
        XCTAssertEqual(g.description, "app 60 s, helper 15 s, appExtension 3 s, cli 5 s")
        XCTAssertEqual(EjectFlow.Dependencies(ejector: FakeEjector(default: .ejected), terminator: Terminator(log: nil),
                                              scan: { FakeScanner([]).scan($0) }, timeMachine: { _ in .idle },
                                              resolvePID: { _, _ in nil }, openURL: { _ in }, log: nil).grace, g)
    }

    func testForceLabelsSayWhatTheyCost() {
        let r: [HoldReason] = [.mappedFile(path: "/Volumes/FAKE/a.jpg", writable: false)]
        let app = EjectFlow.forceButton(for: fake(1, "Premiere Pro", kind: .app, reasons: r))
        XCTAssertEqual(app.action, .forceQuit)
        XCTAssertEqual(app.title, "Force Quit")
        XCTAssertEqual(app.toolTip, "Unsaved changes in Premiere Pro will be lost")
        let helperHolder = Holder(pid: 2, uid: getuid(), ppid: 1, executablePath: "/nonexistent/x", startTime: 1,
                                  displayName: "Google Chrome Helper", bundleIdentifier: nil, bundleURL: nil,
                                  parentAppBundleURL: URL(fileURLWithPath: "/Applications/Google Chrome.app"),
                                  kind: .helper, reasons: r, volumePaths: ["/Volumes/FAKE"])
        let helper = EjectFlow.forceButton(for: helperHolder)
        XCTAssertEqual(helper.title, "Force Quit")
        XCTAssertEqual(helper.toolTip, "Unsaved changes in Google Chrome will be lost", "a helper's quit goes to its app")
        let ext = EjectFlow.forceButton(for: fake(3, "AirDrop (Finder)", kind: .appExtension, bundleID: "com.apple.share.AirDrop.send", reasons: r))
        XCTAssertEqual(ext.action, .forceQuit)
        XCTAssertEqual(ext.title, "Force Stop")
        XCTAssertEqual(ext.toolTip, "Force Stop ends AirDrop (Finder) immediately. Extensions rarely hold unsaved work.")
        let cli = EjectFlow.forceButton(for: fake(4, "ffmpeg", kind: .cli, reasons: r))
        XCTAssertEqual(cli.action, .kill)
        XCTAssertEqual(cli.title, "Kill")
        XCTAssertEqual(cli.toolTip, "Stops ffmpeg immediately; a copy or encode in progress will be incomplete")
        // AirDrop keeps "close the share sheet" and adds the force route.
        let air = Remedies.remedy(for: fake(3, "AirDrop (Finder)", kind: .appExtension, bundleID: "com.apple.share.AirDrop.send", reasons: r))
        XCTAssertEqual(air.explanation, "Finder\u{2019}s share sheet still has these files open. Close the share sheet, or Force Stop it.")
    }

    /// The AirDrop row keeps "close the share sheet", adds "or Force Stop it", and offers no force while idle; its force
    /// action is labelled Force Stop. (Synthetic holder: never a real process, S6.)
    @MainActor
    func testAirDropRowSaysForceStop() async throws {
        let air = fake(99_971, "AirDrop (Finder)", kind: .appExtension, bundleID: "com.apple.share.AirDrop.send",
                       reasons: [.mappedFile(path: "/Volumes/FAKE/Still.jpg", writable: false)])
        let flow = makeFakeFlow(FakeEjector(default: FixPass2FlowTests.busy), FakeScanner([air]))
        flow.start()
        try await pumpFlow(flow) { flow.state == .blocked && flow.rows.count == 1 }
        let idle = flow.rows[0]
        XCTAssertEqual(idle.remedy.buttonTitle, "Stop")
        XCTAssertEqual(idle.detail().0, "Still.jpg (media mapped in memory)\nFinder\u{2019}s share sheet still has these files open. Close the share sheet, or Force Stop it.")
        XCTAssertNil(idle.secondaryAction)
        XCTAssertEqual(EjectFlow.forceButton(for: air).title, "Force Stop")
        flow.cancel()
    }

    func testCountdownRoundsDown() {
        XCTAssertEqual(EjectFlow.remaining(elapsed: 0, grace: 60), 60)
        XCTAssertEqual(EjectFlow.remaining(elapsed: 0.25, grace: 60), 59, "\"Quitting… (59s)\" after the first 250 ms poll")
        XCTAssertEqual(EjectFlow.remaining(elapsed: 2.6, grace: 3), 0)
        XCTAssertEqual(EjectFlow.remaining(elapsed: 9, grace: 3), 0)
        XCTAssertEqual(EjectFlow.RowStatus.quitting(elapsed: 0.5, grace: 3).graceRemaining, 2)
        XCTAssertTrue(EjectFlow.RowStatus.quitting(elapsed: 0.5, grace: 3).isWaiting)
        XCTAssertFalse(EjectFlow.RowStatus.stopping(since: Date().addingTimeInterval(-6), grace: 5).isWaiting, "grace over")
        XCTAssertTrue(EjectFlow.RowStatus.stopping(since: Date(), grace: 5).isWaiting)
        XCTAssertFalse(EjectFlow.RowStatus.quitTimedOut.isWaiting)
    }

    /// Hover or keyboard focus reveals the force button, only while the row offers one (S3: idle rows never do).
    func testForceRevealFollowsHoverAndFocusOnlyWhileWaiting() {
        let h = fake(5, "AirDrop (Finder)", kind: .appExtension, reasons: [.mappedFile(path: "/Volumes/FAKE/a.jpg", writable: false)])
        let waiting = row(h, status: .quitting(elapsed: 0.5, grace: 3), secondary: .forceQuit)
        let idle = row(h, status: .idle, secondary: nil)

        var r = ForceReveal()
        r.update(idle)
        r.pointerEntered()
        XCTAssertFalse(r.isPresent)
        XCTAssertFalse(r.isRevealed, "an idle row has no force button, hovered or not")

        r.update(waiting)
        XCTAssertTrue(r.isPresent, "present (transparent, Tab-reachable) while the row waits")
        XCTAssertTrue(r.isRevealed, "the pointer is still over the row")
        r.pointerExited()
        XCTAssertFalse(r.isRevealed)
        r.pointerEntered()
        XCTAssertTrue(r.isRevealed, "hover reveals it")
        r.pointerExited()
        r.focusChanged(true)
        XCTAssertTrue(r.isRevealed, "Tab focus reveals it")
        r.focusChanged(false)
        XCTAssertFalse(r.isRevealed)

        r.focusChanged(true)
        r.update(row(h, status: .quitTimedOut, secondary: nil))   // grace over: the force action is the primary button
        XCTAssertFalse(r.isPresent)
        XCTAssertFalse(r.isFocused)
        XCTAssertFalse(r.isRevealed)
    }

    /// Only a Tab / Shift-Tab key press may focus the force button (and so reveal it to Space): never AppKit's automatic
    /// next responder when the row's own button turns into "Quitting…" (measured: it did, before this guard).
    func testForceButtonFocusOnlyFromTab() {
        XCTAssertTrue(ForceReveal.acceptsFocus(keyDownKeyCode: 48), "Tab / Shift-Tab")
        XCTAssertFalse(ForceReveal.acceptsFocus(keyDownKeyCode: nil), "no key event: AppKit moving focus by itself, a click")
        XCTAssertFalse(ForceReveal.acceptsFocus(keyDownKeyCode: 49), "Space")
        XCTAssertFalse(ForceReveal.acceptsFocus(keyDownKeyCode: 36), "Return")
    }

    // MARK: Live: the fixture GUI app (refuses every quit, like an app showing a Save prompt or an extension that never
    // answers), relabelled per kind; the real Terminator, scanner and Ejector against a fixture disk image.

    /// .app 60 s, .helper 15 s (its app), .appExtension 3 s: the row counts down from its kind's grace, offers its labelled
    /// force button only while waiting (hover), and the revealed button force-quits that one app; the disk then ejects by
    /// itself (soft).
    @MainActor
    func testEachKindCountsDownItsGraceAndTheRevealedForceEndsIt() async throws {
        let fx = try Fixture.make("apfs", holders: [], name: "DUTEST_T_GRACE")
        defer { fx.cleanup() }
        let disk = try XCTUnwrap(topo(forVolume: fx.mount))
        try XCTSkipUnless(disk.isVirtual, "\(disk.bsdName) is not a disk image")
        let bundle = URL(fileURLWithPath: try TestApp.bundleURL().path, isDirectory: true)   // as HolderResolver builds it
        let a = try await TestApp.launch(holding: try fx.makeFile("a.mov"), refuse: 1000)
        defer { a.forceKillIfRunning() }
        let b = try await TestApp.launch(holding: try fx.makeFile("b.mov"), refuse: 1000)
        defer { b.forceKillIfRunning() }
        let c = try await TestApp.launch(holding: try fx.makeFile("c.mov"), refuse: 1000)
        defer { c.forceKillIfRunning() }
        let logStart = actionLogSize()

        let ejector = RecordingEjector(Ejector())
        let flow = liveFlow(disk: disk, name: fx.name, ejector: ejector,
                            relabel: [a.pid: .init(kind: .app), b.pid: .init(kind: .helper, parent: bundle), c.pid: .init(kind: .appExtension)])
        flow.start()
        try await waitUntil(30) { flow.state == .blocked && flow.rows.count == 3 }

        let expected: [(TestApp, HolderKind, TimeInterval, String, String)] = [
            (a, .app, 60, "Force Quit", "Unsaved changes in DUTestHolder will be lost"),
            (b, .helper, 15, "Force Quit", "Unsaved changes in DUTestHolder will be lost"),
            (c, .appExtension, 3, "Force Stop", "Force Stop ends DUTestHolder immediately. Extensions rarely hold unsaved work."),
        ]
        for (app, kind, grace, forceTitle, toolTip) in expected {
            let idle = try XCTUnwrap(flow.rows.first { $0.holder.pid == app.pid })
            XCTAssertEqual(idle.holder.kind, kind)
            XCTAssertEqual(idle.action, .quit)
            XCTAssertNil(idle.secondaryAction, "S3: no force before the user asked it to quit")
            XCTAssertEqual(flow.perform(.forceQuit, on: app.pid), .unavailable, "S3: \(kind)")

            XCTAssertEqual(flow.perform(.quit, on: app.pid), .started)
            try await waitUntil(1) { flow.rows.first { $0.holder.pid == app.pid }?.actionTitle == "Quitting\u{2026} (\(Int(grace) - 1)s)" }
            let w = try XCTUnwrap(flow.rows.first { $0.holder.pid == app.pid })
            guard case .quitting(_, let g) = w.status else { return XCTFail("\(kind): \(w.status)") }
            XCTAssertEqual(g, grace, "\(kind)")
            XCTAssertFalse(w.actionEnabled)
            XCTAssertTrue(w.status.isWaiting, "progress indicator")
            XCTAssertEqual(w.secondaryAction, .forceQuit)
            XCTAssertEqual(w.secondaryTitle, forceTitle)
            XCTAssertEqual(w.secondaryToolTip, toolTip)
            try await waitUntil(5) { app.log.contains("shouldTerminate cancel") }

            // The view's hover path, then the click on the revealed button.
            var reveal = ForceReveal()
            reveal.update(w)
            XCTAssertFalse(reveal.isRevealed)
            reveal.pointerEntered()
            XCTAssertTrue(reveal.isRevealed, "hovering the row reveals \(forceTitle)")
            XCTAssertTrue(NSRunningApplication(processIdentifier: app.pid).map { !$0.isTerminated } ?? false, "nothing forced by revealing it")
            XCTAssertEqual(flow.perform(.forceQuit, on: app.pid), .started)
            try await waitUntil(5) { NSRunningApplication(processIdentifier: app.pid)?.isTerminated ?? true }
            XCTAssertFalse(app.log.contains("shouldTerminate now"), "forced, not quit normally")
        }
        try await waitUntil(40) { flow.state == .ejected }
        XCTAssertFalse(fx.isMounted)
        XCTAssertTrue(ejector.calls.allSatisfy { !$0.force && $0.policy == .externalDisks }, "S1: soft ejects only")

        let log = actionLogTail(from: logStart)
        for (app, kind, grace, title, _) in expected {
            XCTAssertTrue(log.contains("[quit] \(app.pid) DUTestHolder [\(kind.rawValue)]: grace \(Int(grace)) s before the row offers its force action"), "grace logged (\(kind))\n\(log)")
            XCTAssertTrue(log.contains("[flow] \(title) clicked for \(app.pid) DUTestHolder [\(kind.rawValue)]"), "early force logged (\(kind))")
            XCTAssertTrue(log.contains("[force-quit] result \(app.pid) DUTestHolder: quit"), "\(kind)")
        }
    }

    /// An app extension that never answers (DUTestExtension.app: LSBackgroundOnly, so LaunchServices reports policy
    /// `.prohibited` and the real resolver says `.appExtension`, as for AirDrop.appex): after 3 s its primary button is
    /// "Force Stop" and the row says it is safe. Nothing is forced until that button is clicked.
    @MainActor
    func testAppExtensionPromotesForceStopAfterThreeSeconds() async throws {
        let fx = try Fixture.make("apfs", holders: [], name: "DUTEST_T_GRACE")
        defer { fx.cleanup() }
        let disk = try XCTUnwrap(topo(forVolume: fx.mount))
        try XCTSkipUnless(disk.isVirtual, "\(disk.bsdName) is not a disk image")
        let app = try await TestApp.launch(holding: try fx.makeFile("still.jpg"), refuse: 1000, backgroundOnly: true)
        defer { app.forceKillIfRunning() }
        let resolved = try await app.holder(on: fx)
        XCTAssertEqual(resolved.kind, .appExtension, "classified by the resolver (policy .prohibited), not relabelled")
        let logStart = actionLogSize()
        let flow = liveFlow(disk: disk, name: fx.name, ejector: RecordingEjector(Ejector()), relabel: [:])
        flow.start()
        try await waitUntil(30) { flow.state == .blocked && flow.rows.count == 1 }

        let started = Date()
        XCTAssertEqual(flow.perform(.quit, on: app.pid), .started)
        XCTAssertEqual(flow.rows[0].secondaryTitle, "Force Stop")
        try await waitUntil(10) { flow.rows.first?.status == .quitTimedOut }
        let waited = Date().timeIntervalSince(started)
        XCTAssertGreaterThanOrEqual(waited, 2.9)
        XCTAssertLessThan(waited, 5, "an app extension gets 3 s, not 60")
        let row = flow.rows[0]
        XCTAssertEqual(row.action, .forceQuit)
        XCTAssertEqual(row.actionTitle, "Force Stop", "grace over: Force Stop is the row's button")
        XCTAssertTrue(row.actionEnabled)
        XCTAssertNil(row.secondaryAction)
        XCTAssertFalse(row.status.isWaiting)
        XCTAssertEqual(row.detail().0, "DUTestExtension doesn\u{2019}t respond to Quit. Force Stop ends it; extensions rarely hold unsaved work.")
        XCTAssertEqual(row.forceToolTip, "Force Stop ends DUTestExtension immediately. Extensions rarely hold unsaved work.")

        // S3: nothing automatic. Still running a second later, no force-quit sent.
        try await Task.sleep(nanoseconds: 1_000_000_000)
        XCTAssertFalse(NSRunningApplication(processIdentifier: app.pid)?.isTerminated ?? true)
        XCTAssertFalse(actionLogTail(from: logStart).contains("[force-quit] \(app.pid) "))
        XCTAssertTrue(actionLogTail(from: logStart).contains("[quit] result \(app.pid) DUTestExtension: still running after 3."))

        XCTAssertEqual(flow.perform(.forceQuit, on: app.pid), .started)
        try await waitUntil(5) { NSRunningApplication(processIdentifier: app.pid)?.isTerminated ?? true }
        try await waitUntil(40) { flow.state == .ejected }
    }

    /// Quit All is graceful only (S1/S3): it never force-quits, whatever the grace. Afterwards each row follows its own
    /// kind's grace: the extension's Force Stop is its button after 3 s while the app still counts down from 60 with
    /// Force Quit one hover away.
    @MainActor
    func testQuitAllNeverForcesAndEachRowKeepsItsOwnGrace() async throws {
        let fx = try Fixture.make("apfs", holders: [], name: "DUTEST_T_GRACE")
        defer { fx.cleanup() }
        let disk = try XCTUnwrap(topo(forVolume: fx.mount))
        try XCTSkipUnless(disk.isVirtual, "\(disk.bsdName) is not a disk image")
        let ext = try await TestApp.launch(holding: try fx.makeFile("e.jpg"), refuse: 1000, backgroundOnly: true)
        defer { ext.forceKillIfRunning() }
        let app = try await TestApp.launch(holding: try fx.makeFile("p.mov"), refuse: 1000)
        defer { app.forceKillIfRunning() }
        let logStart = actionLogSize()
        let ejector = RecordingEjector(Ejector())
        let flow = liveFlow(disk: disk, name: fx.name, ejector: ejector, relabel: [:])
        flow.start()
        try await waitUntil(30) { flow.state == .blocked && flow.rows.count == 2 && flow.canQuitAll }
        XCTAssertEqual(flow.rows.first { $0.holder.pid == ext.pid }?.holder.kind, .appExtension)

        flow.quitAll()
        XCTAssertEqual(flow.state, .quitting)
        try await waitUntil(10) { flow.rows.first { $0.holder.pid == ext.pid }?.status == .quitTimedOut }
        let extRow = try XCTUnwrap(flow.rows.first { $0.holder.pid == ext.pid })
        XCTAssertEqual(extRow.actionTitle, "Force Stop")
        let appRow = try XCTUnwrap(flow.rows.first { $0.holder.pid == app.pid })
        guard case .quitting(let elapsed, 60) = appRow.status else { return XCTFail("\(appRow.status)") }
        XCTAssertLessThan(elapsed, 10)
        XCTAssertEqual(appRow.secondaryTitle, "Force Quit")
        XCTAssertTrue(appRow.actionTitle?.hasPrefix("Quitting\u{2026} (5") ?? false, appRow.actionTitle ?? "-")

        try await Task.sleep(nanoseconds: 1_000_000_000)
        for p in [ext.pid, app.pid] {
            XCTAssertFalse(NSRunningApplication(processIdentifier: p)?.isTerminated ?? true, "Quit All never forces")
            XCTAssertFalse(actionLogTail(from: logStart).contains("[force-quit] \(p) "))
        }
        XCTAssertTrue(ext.log.contains("shouldTerminate cancel") && app.log.contains("shouldTerminate cancel"), "both asked normally")
        XCTAssertFalse(ejector.calls.contains { $0.force })
        XCTAssertTrue(fx.isMounted)
        flow.cancel()
    }

    /// CLI: SIGTERM, then Kill one hover away (a second click on the same process, S3) and the row's button after 5 s.
    @MainActor
    func testCLIStopRevealsKillThenPromotesItAfterFiveSeconds() async throws {
        let fx = try Fixture.make("apfs", holders: [], name: "DUTEST_T_GRACE")
        defer { fx.cleanup() }
        let disk = try XCTUnwrap(topo(forVolume: fx.mount))
        try XCTSkipUnless(disk.isVirtual, "\(disk.bsdName) is not a disk image")
        func stubborn() throws -> Process {                       // ignores SIGTERM; cwd on the fixture volume
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/sh")
            p.arguments = ["-c", "trap '' TERM; exec /bin/sleep 300"]
            p.currentDirectoryURL = URL(fileURLWithPath: fx.mount)
            try p.run()
            return p
        }
        let early = try stubborn()
        defer { if early.isRunning { kill(early.processIdentifier, SIGKILL) } }
        let late = try stubborn()
        defer { if late.isRunning { kill(late.processIdentifier, SIGKILL) } }
        let flow = liveFlow(disk: disk, name: fx.name, ejector: RecordingEjector(Ejector()), relabel: [:])
        flow.start()
        try await waitUntil(30) { flow.state == .blocked && flow.rows.count == 2 }
        let ep = early.processIdentifier, lp = late.processIdentifier

        XCTAssertNil(flow.rows.first { $0.holder.pid == ep }?.secondaryAction)
        XCTAssertEqual(flow.perform(.kill, on: ep), .unavailable, "Kill only after Stop")
        XCTAssertEqual(flow.perform(.stop, on: ep), .started)
        XCTAssertEqual(flow.perform(.stop, on: lp), .started)
        let s = try XCTUnwrap(flow.rows.first { $0.holder.pid == ep })
        XCTAssertEqual(s.actionTitle, "Stopping\u{2026} (4s)", "whole seconds left, rounded down")
        XCTAssertFalse(s.actionEnabled)
        XCTAssertEqual(s.secondaryAction, .kill)
        XCTAssertEqual(s.secondaryToolTip, "Stops sleep immediately; a copy or encode in progress will be incomplete")
        XCTAssertEqual(s.detail().0, "Asked it to stop\u{2026}")
        try await waitUntil(2) { flow.rows.first { $0.holder.pid == ep }?.actionTitle == "Stopping\u{2026} (3s)" }

        XCTAssertEqual(flow.perform(.kill, on: ep), .started, "the revealed Kill, before the grace ends")
        try await waitUntil(5) { !early.isRunning }

        try await waitUntil(8) { flow.rows.first { $0.holder.pid == lp }?.action == .kill }
        let k = try XCTUnwrap(flow.rows.first { $0.holder.pid == lp })
        XCTAssertEqual(k.actionTitle, "Kill")
        XCTAssertTrue(k.actionEnabled)
        XCTAssertNil(k.secondaryAction)
        XCTAssertEqual(k.detail().0, "Didn\u{2019}t stop. Click Kill to stop it immediately.")
        XCTAssertTrue(late.isRunning, "nothing automatic")
        XCTAssertEqual(flow.perform(.kill, on: lp), .started)
        try await waitUntil(5) { !late.isRunning }
        try await waitUntil(40) { flow.state == .ejected }
    }

    // MARK: Helpers

    struct Relabel: Sendable {
        var kind: HolderKind
        var parent: URL? = nil
    }

    /// A live flow (real scanner, Terminator, Ejector; app policy `.externalDisks` on our disk image) whose scans
    /// report the given pids as other kinds. A relabelled helper's app is its own bundle, found by its own pid.
    @MainActor
    private func liveFlow(disk: PhysicalDisk, name: String, ejector: any EjectPerforming, relabel: [pid_t: Relabel]) -> EjectFlow {
        var d = EjectFlow.Dependencies.live(ejector: ejector, terminator: Terminator())
        d.minRetryInterval = 0.5
        let scan = d.scan, rescan = d.rescan
        d.scan = { disk in Self.relabelled(scan(disk), relabel) }
        if let rescan { d.rescan = { disk, pids in Self.relabelled(rescan(disk, pids), relabel) } }
        return EjectFlow(disk: disk, displayName: name, dependencies: d)
    }

    nonisolated static func relabelled(_ s: HolderScan, _ map: [pid_t: Relabel]) -> HolderScan {
        let holders = s.holders.map { h -> Holder in
            guard let r = map[h.pid] else { return h }
            return Holder(pid: h.pid, uid: h.uid, ppid: r.parent == nil ? h.ppid : h.pid, executablePath: h.executablePath,
                          startTime: h.startTime, displayName: h.displayName, bundleIdentifier: h.bundleIdentifier,
                          bundleURL: h.bundleURL, parentAppBundleURL: r.parent ?? h.parentAppBundleURL, kind: r.kind,
                          reasons: h.reasons, volumePaths: h.volumePaths)
        }
        return HolderScan(volumePaths: s.volumePaths, holders: holders, deniedPIDs: s.deniedPIDs, duration: s.duration,
                          scannedAt: s.scannedAt, scannedTargets: s.scannedTargets, incomplete: s.incomplete,
                          incompleteReason: s.incompleteReason)
    }

    private func row(_ h: Holder, status: EjectFlow.RowStatus, secondary: EjectFlow.RowAction?) -> EjectFlow.Row {
        EjectFlow.Row(holder: h, remedy: Remedies.remedy(for: h), status: status, action: .quit, actionTitle: "Quit",
                      actionEnabled: secondary == nil, isDissenterOnly: false, secondaryAction: secondary,
                      secondaryTitle: secondary == nil ? nil : "Force Stop", secondaryToolTip: nil)
    }

    private func actionLogSize() -> Int {
        (try? FileManager.default.attributesOfItem(atPath: ActionLog.shared.fileURL.path)[.size] as? Int) ?? 0
    }

    private func actionLogTail(from offset: Int) -> String {
        guard let data = FileManager.default.contents(atPath: ActionLog.shared.fileURL.path), data.count >= offset else { return "" }
        return String(decoding: data.dropFirst(offset), as: UTF8.self)
    }
}
