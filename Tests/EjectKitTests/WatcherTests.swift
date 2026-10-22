import EjectKit
import Foundation
import XCTest

/// EjectWatcher (phase 3, S7) against real DiskArbitration, fixture disk images only. Foreign attempts come from
/// /usr/sbin/diskutil (another process, like Finder); our own attempts from an in-process Ejector (the app's case).
/// Every diskutil call is checked against the fixture's own mount point / device first.
final class WatcherTests: XCTestCase {
    override func setUp() { redirectTestLogs() }

    func testIdleCallbackSymbolIsExported() {
        XCTAssertTrue(EjectWatcher.idleCallbackAvailable, "DARegisterIdleCallback should be exported on macOS 26")
    }

    func testInFlightRegistrySpans() {
        let reg = EjectsInFlight()
        let before = DispatchTime.now().uptimeNanoseconds
        let token = reg.begin(physicalBSD: "disk99")
        let during = DispatchTime.now().uptimeNanoseconds
        XCTAssertTrue(reg.isInFlight(physicalBSD: "disk99"))
        XCTAssertFalse(reg.isInFlight(physicalBSD: "disk98"))
        reg.end(token)
        let after = DispatchTime.now().uptimeNanoseconds
        XCTAssertFalse(reg.isInFlight(physicalBSD: "disk99"))
        XCTAssertTrue(reg.wasInFlight(physicalBSD: "disk99", at: during), "an approval delivered mid-eject is ours")
        XCTAssertFalse(reg.wasInFlight(physicalBSD: "disk99", at: before))
        XCTAssertFalse(reg.wasInFlight(physicalBSD: "disk99", at: after + 1))
        XCTAssertFalse(reg.wasInFlight(physicalBSD: "disk98", at: during))
    }

    // MARK: Acceptance 1: foreign unmount fails with holders -> failed + scan; then succeeds once they are gone

    func testForeignUnmountIdlePath() throws { try foreignUnmountFailsThenSucceeds(useIdle: true) }
    func testForeignUnmountPollFallback() throws { try foreignUnmountFailsThenSucceeds(useIdle: false) }

    private func foreignUnmountFailsThenSucceeds(useIdle: Bool) throws {
        try skipOnCI("foreign-unmount timing")
        let fx = try Fixture.make("apfs", holders: ["fd", "cwd"], name: useIdle ? "DUTEST_W_IDLE" : "DUTEST_W_POLL")
        defer { fx.cleanup() }
        let rec = EventRecorder()
        // Short poll timeout keeps the fallback test fast; the CLI uses the default 20 s.
        let options = EjectWatcherOptions(useIdleCallback: useIdle, outcomeTimeout: useIdle ? 20 : 4)
        let watcher = EjectWatcher(options: options) { rec.add($0) }
        XCTAssertTrue(watcher.start())
        defer { watcher.stop() }
        XCTAssertEqual(watcher.usesIdleCallback, useIdle)

        let started = Date()
        let busy = try diskutil(["unmount", fx.mount], fx)
        XCTAssertNotEqual(busy.status, 0, busy.output)
        XCTAssertTrue(busy.output.contains("dissented by PID"), busy.output)
        XCTAssertTrue(spin(30) { rec.events(fx.mount).contains { $0.event.isFailed } }, "no failed event: \(rec.events(fx.mount))")

        let evs = rec.events(fx.mount)
        guard case .attemptStarted(let url, let disk)? = evs.first?.event else { return XCTFail("first event: \(evs)") }
        XCTAssertEqual(url.path, fx.mount)
        XCTAssertTrue(disk.isVirtual)
        XCTAssertLessThan(evs[0].at.timeIntervalSince(started), 2.0, "attemptStarted must follow the approval promptly")
        guard let failed = evs.first(where: { $0.event.isFailed }), case .failed(let fURL, _, let scan, let kind) = failed.event else {
            return XCTFail("no failed event")
        }
        XCTAssertEqual(fURL.path, fx.mount)
        XCTAssertEqual(kind, .unmount, "diskutil unmount of one volume is an unmount attempt")
        let pids = Set(scan.holders.map(\.pid))
        XCTAssertTrue(pids.isSuperset(of: [fx.pids["fd"], fx.pids["cwd"]].compactMap { $0 }), "scan must list both holders: \(pids)")
        if useIdle {
            // DA finishing == diskutil returning; the idle callback reports within moments of that.
            XCTAssertLessThan(failed.at.timeIntervalSince(busy.finished), 1.5, "idle path must report right after DA finishes")
        } else {
            let afterAttempt = failed.at.timeIntervalSince(evs[0].at)
            XCTAssertGreaterThan(afterAttempt, 3.5)
            XCTAssertLessThan(afterAttempt, 6.0, "poll fallback reports at its timeout")
        }
        XCTAssertEqual(evs.filter { $0.event.isAttempt }.count, 1)
        print("watcher (\(useIdle ? "idle" : "poll")): attempt +\(ms(evs[0].at.timeIntervalSince(started))) after spawning diskutil, "
              + "failed +\(ms(failed.at.timeIntervalSince(evs[0].at))) after attempt; diskutil took \(ms(busy.seconds))")

        // Holders gone: the next foreign unmount succeeds and is reported as such. Wait out the dedupe window first
        // (a retry inside it is folded into the same attempt, which then flips to succeeded without a new attemptStarted).
        spin(options.dedupeWindow + 0.5) { false }
        fx.killHolders()
        var ok = false
        for _ in 0..<3 where !ok {                    // a system daemon may touch a fresh volume; allow soft retries
            ok = try diskutil(["unmount", fx.mount], fx).status == 0
            if !ok { Thread.sleep(forTimeInterval: 1) }
        }
        XCTAssertTrue(ok, "unmount after killing holders")
        XCTAssertTrue(spin(25) { rec.events(fx.mount).last?.event.isSucceeded == true }, "no succeeded event: \(rec.events(fx.mount))")
        XCTAssertGreaterThanOrEqual(rec.events(fx.mount).filter { $0.event.isAttempt }.count, 2)
        assertS7(watcher)
    }

    // MARK: Acceptance 1: diskutil eject (whole disk) -> exactly one attempt per physical disk

    func testForeignWholeDiskEjectIsOneAttempt() throws {
        try skipOnCI("foreign-eject timing")
        let fx = try Fixture.make("apfs", holders: ["fd"], name: "DUTEST_W_EJECT")
        defer { fx.cleanup() }
        let physical = try XCTUnwrap(topo(forVolume: fx.mount))
        let rec = EventRecorder()
        let watcher = EjectWatcher { rec.add($0) }
        XCTAssertTrue(watcher.start())
        defer { watcher.stop() }

        let busy = try diskutil(["eject", fx.device], fx)
        XCTAssertNotEqual(busy.status, 0, busy.output)
        XCTAssertTrue(spin(30) { rec.events(fx.mount).contains { $0.event.isFailed } }, "\(rec.events(fx.mount))")
        spin(2.5) { false }                            // a second attempt event would arrive inside the dedupe window
        var evs = rec.events(fx.mount)
        XCTAssertEqual(evs.filter { $0.event.isAttempt }.count, 1, "one attempt per physical disk: \(evs.map(\.event))")
        // Measured: diskutil eject unmounts first and asks for the eject only once every volume is unmounted, so a busy
        // eject shows unmount approvals only. The companion then unmounts, never ejects (EjectAttemptKind).
        if case .failed(_, _, _, let kind)? = evs.first(where: { $0.event.isFailed })?.event { XCTAssertEqual(kind, .unmount) }
        XCTAssertTrue(evs.allSatisfy { $0.event.disk.bsdName == physical.bsdName })

        fx.killHolders()
        var ok = false
        for _ in 0..<3 where !ok {
            ok = try diskutil(["eject", fx.device], fx).status == 0
            if !ok { Thread.sleep(forTimeInterval: 1) }
        }
        XCTAssertTrue(ok, "eject after killing holders")
        XCTAssertTrue(spin(25) { rec.events(fx.mount).last?.event.isSucceeded == true }, "\(rec.events(fx.mount))")
        spin(2.5) { false }                            // the trailing eject approvals must not start a new attempt
        evs = rec.events(fx.mount)
        XCTAssertEqual(evs.filter { $0.event.isAttempt }.count, 2, "\(evs.map(\.event))")
        XCTAssertTrue(evs.last?.event.isSucceeded == true)
        assertS7(watcher)
    }

    // MARK: Acceptance 2: our own Ejector (same process) produces no watcher events

    func testOwnEjectProducesNoEvents() throws {
        try skipOnCI("DiskArbitration approval timing")
        let fx = try Fixture.make("apfs", holders: ["fd"], name: "DUTEST_W_OWN")
        defer { fx.cleanup() }
        let disk = try XCTUnwrap(topo(forVolume: fx.mount))
        let rec = EventRecorder()
        let watcher = EjectWatcher { rec.add($0) }
        XCTAssertTrue(watcher.start())
        defer { watcher.stop() }
        let ejector = Ejector()

        let busy = try XCTUnwrap(ejectSync(ejector, disk))
        guard case .busy = busy else { return XCTFail("expected busy, got \(busy)") }
        fx.killHolders()
        var result: EjectResult?
        for _ in 0..<3 {
            result = ejectSync(ejector, disk)
            if result?.isEjected == true { break }
            Thread.sleep(forTimeInterval: 1)
        }
        XCTAssertTrue(result?.isEjected == true, "\(String(describing: result))")
        XCTAssertFalse(Ejector.isInFlight(physicalBSD: disk.bsdName))
        spin(3) { false }                              // give any (wrong) event time to arrive

        XCTAssertTrue(rec.events(fx.mount).isEmpty, "own eject must not produce events: \(rec.events(fx.mount).map(\.event))")
        let st = watcher.stats
        XCTAssertGreaterThanOrEqual(st.ignoredOwnEjects, 2, "the watcher did see our approvals and recognised them: \(st)")
        XCTAssertEqual(st.attempts, 0)
        print("own eject: \(st.approvalCallbacks) approval callback(s) received, \(st.ignoredOwnEjects) recognised as ours, 0 events")
        assertS7(watcher)
    }

    // MARK: Acceptance 3: S7, a stopped watcher does not keep DA waiting

    func testStoppedWatcherDoesNotDelayUnmount() throws {
        try skipOnCI("DiskArbitration approval timing")
        let fx = try Fixture.make("apfs", holders: [], name: "DUTEST_W_STOP")
        defer { fx.cleanup() }
        let volumeBSD = try XCTUnwrap(DiskTopology.volumeInfo(path: fx.mount)?.bsdName)
        let physical = try XCTUnwrap(topo(forVolume: fx.mount))
        XCTAssertTrue(physical.isVirtual && physical.volumes.map(\.bsdName) == [volumeBSD], "volume must be on our image")
        let since = Date()
        let rec = EventRecorder()
        let watcher = EjectWatcher { rec.add($0) }

        func cycle() throws -> TimeInterval {
            let r = try diskutil(["unmount", fx.mount], fx)
            XCTAssertEqual(r.status, 0, r.output)
            XCTAssertEqual(try diskutil(["mount", volumeBSD], fx, volumeBSD: volumeBSD).status, 0)
            XCTAssertTrue(spin(5) { fx.isMounted })
            return r.seconds
        }

        XCTAssertTrue(watcher.start())
        let running = try cycle()
        XCTAssertTrue(spin(25) { rec.events(fx.mount).last?.event.isSucceeded == true }, "\(rec.events(fx.mount))")
        watcher.stop()
        XCTAssertFalse(watcher.isRunning)
        let eventsAtStop = rec.events(fx.mount).count
        spin(1.5) { false }                            // drain + session teardown
        let callbacksAtStop = watcher.stats.approvalCallbacks

        let stopped = try cycle()
        let stopped2 = try cycle()
        spin(1) { false }
        XCTAssertEqual(watcher.stats.approvalCallbacks, callbacksAtStop, "DA must not call a stopped watcher")
        XCTAssertEqual(rec.events(fx.mount).count, eventsAtStop, "no events after stop()")
        // Other approvers (PhotosPosterProvider here) can stall any unmount ~10 s, so wall time alone proves little;
        // diskarbitrationd names every approver it waited on. It must never name this process.
        let stalls = notRespondingLines(since: since)
        XCTAssertTrue(stalls.filter { $0.contains("[\(getpid())]") }.isEmpty, "DA waited on this process: \(stalls)")
        XCTAssertLessThan(max(stopped, stopped2), 15)
        print("unmount with watcher running: \(ms(running)); after stop(): \(ms(stopped)), \(ms(stopped2)); "
              + "DA 'not responding' lines in window: \(stalls.isEmpty ? "none" : stalls.joined(separator: " | "))")
        assertS7(watcher)
    }

    // MARK: - Helpers

    /// S7: time inside every approval callback < 1 ms, and DA never reported this process as not responding.
    private func assertS7(_ watcher: EjectWatcher, file: StaticString = #filePath, line: UInt = #line) {
        let st = watcher.stats
        XCTAssertLessThan(st.maxApprovalCallbackNanos, 1_000_000, "approval callback took \(st.maxApprovalCallbackNanos) ns", file: file, line: line)
        print("S7: \(st.approvalCallbacks) approval callback(s), max \(String(format: "%.1f", Double(st.maxApprovalCallbackNanos) / 1e3)) µs, "
              + "mean \(String(format: "%.1f", Double(st.meanApprovalCallbackNanos) / 1e3)) µs inside the callback")
    }

    private func ms(_ t: TimeInterval) -> String { String(format: "%.0f ms", t * 1000) }

    struct DiskutilRun { let status: Int32; let output: String; let seconds: TimeInterval; let finished: Date }

    /// Runs /usr/sbin/diskutil, but only against this fixture: its mount point, its own image's device (re-checked to
    /// be the disk image under the mount right now), or `volumeBSD`, which the caller captured from the mounted fixture.
    private func diskutil(_ args: [String], _ fx: Fixture, volumeBSD: String? = nil) throws -> DiskutilRun {
        guard let target = args.last, fx.mount.hasPrefix("/Volumes/DUTEST_W") else { throw XCTSkip("not a watcher fixture") }
        let device = (fx.device as NSString).lastPathComponent
        let allowed: Bool
        if target == fx.mount {
            allowed = true
        } else if target == fx.device {
            let d = topo(forVolume: fx.mount)
            allowed = d?.bsdName == device && d?.isVirtual == true
        } else {
            allowed = volumeBSD != nil && target == volumeBSD && topo(bsdName: device)?.isVirtual == true
        }
        guard allowed else {
            XCTFail("refusing diskutil \(args) outside fixture \(fx.name)")
            throw XCTSkip("refused")
        }
        // Output goes to a file and the main run loop keeps spinning, so watcher events (main queue) are delivered,
        // and timestamped, while diskutil is still waiting on DiskArbitration.
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("watchertests-diskutil-\(UUID().uuidString).txt")
        FileManager.default.createFile(atPath: out.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: out) }
        let handle = try FileHandle(forWritingTo: out)
        defer { try? handle.close() }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
        p.arguments = args
        p.standardOutput = handle
        p.standardError = handle
        let t0 = Date()
        try p.run()
        spin(120) { !p.isRunning }
        p.waitUntilExit()
        let end = Date()
        let output = (try? String(contentsOf: out, encoding: .utf8)) ?? ""
        return DiskutilRun(status: p.terminationStatus, output: output, seconds: end.timeIntervalSince(t0), finished: end)
    }

    /// diskarbitrationd's "<process> [pid]:port not responding" lines since `since` (approvers it gave up waiting for).
    private func notRespondingLines(since: Date) -> [String] {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/log")
        p.arguments = ["show", "--style", "compact", "--start", f.string(from: since.addingTimeInterval(-1)),
                       "--predicate", #"process == "diskarbitrationd" AND eventMessage CONTAINS "not responding""#]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return [] }
        let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        return out.split(separator: "\n").map(String.init).filter { $0.contains("not responding") }
    }
}

/// Collects watcher events (delivered on the main queue) with their arrival time.
final class EventRecorder: @unchecked Sendable {   // guarded by lock
    private let lock = NSLock()
    private var items: [(at: Date, event: EjectWatcherEvent)] = []
    func add(_ e: EjectWatcherEvent) { lock.withLock { items.append((Date(), e)) } }
    /// Events for one fixture (other processes may be ejecting other disk images at the same time).
    func events(_ mount: String) -> [(at: Date, event: EjectWatcherEvent)] {
        lock.withLock { items.filter { $0.event.volumeURL.path == mount } }
    }
}

extension EjectWatcherEvent {
    var isAttempt: Bool { if case .attemptStarted = self { true } else { false } }
    var isFailed: Bool { if case .failed = self { true } else { false } }
    var isSucceeded: Bool { if case .succeeded = self { true } else { false } }
}

/// Runs the main run loop (watcher events are delivered on the main queue) until `cond` or the timeout.
@discardableResult
func spin(_ timeout: TimeInterval, until cond: () -> Bool) -> Bool {
    let end = Date().addingTimeInterval(timeout)
    while Date() < end {
        if cond() { return true }
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
    }
    return cond()
}
