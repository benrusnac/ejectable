import AppKit
import EjectKit
import XCTest

/// S3 / S4 / S6 / S9 for Terminator, against a real GUI test app (DUTestHolder.app, Tests/fixtures/make-test-app.sh)
/// holding a file on a fixture volume, and real CLI holders. Only processes these tests spawned are ever acted on.
final class TerminatorTests: XCTestCase {
    override func setUp() { redirectTestLogs() }

    // MARK: S3 graceful quit: the app's applicationShouldTerminate runs; refusal -> stillRunning; then quit

    @MainActor
    func testQuitWaitsForTheAppAndReportsRefusalThenQuits() async throws {
        let fx = try Fixture.make("apfs", holders: [], name: "DUTEST_T_TERM")
        defer { fx.cleanup() }
        let app = try await TestApp.launch(holding: try fx.makeFile("clip.mov"), refuse: 1)
        defer { app.forceKillIfRunning() }
        let h = try await app.holder(on: fx)
        XCTAssertEqual(h.kind, .app)
        XCTAssertEqual(h.reasons, [.openFile(path: fx.path("clip.mov"), writing: false)])

        let t = Terminator()
        var progress: [TimeInterval] = []
        let first = await t.quit(h, timeout: 2) { progress.append($0) }
        XCTAssertEqual(first, .stillRunning, "the app refused the first quit (like a Save? prompt)")
        XCTAssertTrue(app.log.contains("shouldTerminate cancel"), app.log)
        XCTAssertTrue(h.isSameProcess(), "still running after a refused quit")
        XCTAssertGreaterThanOrEqual(progress.count, 5, "progress every 250 ms")

        let second = await t.quit(h, timeout: 15)
        XCTAssertEqual(second, .quit)
        XCTAssertTrue(app.log.contains("shouldTerminate now"), "graceful path: the app's own delegate decided\n\(app.log)")
        XCTAssertFalse(h.isSameProcess())
        XCTAssertTrue(HolderScanner.scan(volumePaths: [fx.mount], log: nil).isClear)
    }

    @MainActor
    func testForceQuitKillsAnAppThatRefuses() async throws {
        let fx = try Fixture.make("apfs", holders: [], name: "DUTEST_T_TERM")
        defer { fx.cleanup() }
        let app = try await TestApp.launch(holding: try fx.makeFile("clip.mov"), refuse: 1000)
        defer { app.forceKillIfRunning() }
        let h = try await app.holder(on: fx)
        let t = Terminator()
        let graceful = await t.quit(h, timeout: 1)
        XCTAssertEqual(graceful, .stillRunning)
        let forced = await t.forceQuit(h)
        XCTAssertEqual(forced, .quit)
        XCTAssertFalse(h.isSameProcess())
        XCTAssertFalse(app.log.contains("shouldTerminate now"), "forceTerminate skips the app's quit handler")
    }

    @MainActor
    func testQuitWaitIsCancelable() async throws {
        let fx = try Fixture.make("apfs", holders: [], name: "DUTEST_T_TERM")
        defer { fx.cleanup() }
        let app = try await TestApp.launch(holding: try fx.makeFile("clip.mov"), refuse: 1000)
        defer { app.forceKillIfRunning() }
        let h = try await app.holder(on: fx)
        let t = Terminator()
        let task = Task { @MainActor in await t.quit(h, timeout: 60) }
        try await Task.sleep(nanoseconds: 600_000_000)
        task.cancel()
        let started = Date()
        let r = await task.value
        XCTAssertEqual(r, .cancelled)
        XCTAssertLessThan(Date().timeIntervalSince(started), 1)
        XCTAssertTrue(h.isSameProcess())
    }

    // MARK: S3/S4: signals only for CLI holders; GUI kinds never signalled; daemons never quit

    @MainActor
    func testSignalsAndQuitsRefuseWrongKinds() async throws {
        let fx = try Fixture.make("apfs", holders: ["fd"], name: "DUTEST_T_TERM")
        defer { fx.cleanup() }
        let app = try await TestApp.launch(holding: try fx.makeFile("clip.mov"), refuse: 0)
        defer { app.forceKillIfRunning() }
        let gui = try await app.holder(on: fx)
        let t = Terminator()

        // The real GUI app: stop/kill refused (SIGTERM would skip its save prompt).
        XCTAssertEqual(t.stop(gui), .refused(.app))
        XCTAssertEqual(t.kill(gui), .refused(.app))
        XCTAssertTrue(gui.isSameProcess())

        // A real, killable CLI process relabelled as every non-CLI kind: the kind gate alone must refuse.
        let scan = HolderScanner.scan(volumePaths: [fx.mount], log: nil)
        let tail = try XCTUnwrap(scan.holders.first { $0.pid == fx.pids["fd"] })
        XCTAssertEqual(tail.kind, .cli)
        for kind in HolderKind.allCases where kind != .cli {
            let relabelled = tail.with(kind: kind)
            XCTAssertEqual(t.stop(relabelled), .refused(kind), "\(kind)")
            XCTAssertEqual(t.kill(relabelled), .refused(kind), "\(kind)")
        }
        for kind in [HolderKind.daemon, .inaccessible, .cli] {
            let relabelled = gui.with(kind: kind)
            let q = await t.quit(relabelled, timeout: 1)
            XCTAssertEqual(q, .refused(kind), "\(kind)")
            let f = await t.forceQuit(relabelled)
            XCTAssertEqual(f, .refused(kind), "\(kind)")
        }
        XCTAssertTrue(tail.isSameProcess(), "nothing may have been sent to the CLI holder")
        XCTAssertTrue(gui.isSameProcess(), "nothing may have been sent to the app")
        XCTAssertFalse(app.log.contains("shouldTerminate"), app.log)

        let log = try String(contentsOf: ActionLog.shared.fileURL, encoding: .utf8)
        XCTAssertTrue(log.contains("[refused] SIGTERM -> \(tail.pid)"), "S9: refusals are logged")
    }

    // MARK: S3: SIGTERM, then SIGKILL only as a second step; S6 pid verification

    @MainActor
    func testStopThenKillCLIHolders() async throws {
        let fx = try Fixture.make("apfs", holders: ["fd"], name: "DUTEST_T_TERM")
        defer { fx.cleanup() }
        let t = Terminator()

        // tail exits on SIGTERM.
        let tail = try XCTUnwrap(HolderScanner.scan(volumePaths: [fx.mount], log: nil).holders.first { $0.pid == fx.pids["fd"] })
        XCTAssertEqual(t.kill(tail), .notStoppedFirst, "SIGKILL needs a prior SIGTERM (second click)")
        XCTAssertTrue(tail.isSameProcess())
        XCTAssertEqual(t.stop(tail), .sent)
        try await waitUntil(5) { !tail.isSameProcess() }

        // A CLI tool that ignores SIGTERM (cwd on the volume): Stop, still alive, then Kill.
        let stubborn = Process()
        stubborn.executableURL = URL(fileURLWithPath: "/bin/sh")
        stubborn.arguments = ["-c", "trap '' TERM; exec /bin/sleep 300"]
        stubborn.currentDirectoryURL = URL(fileURLWithPath: fx.mount)
        try stubborn.run()
        defer { if stubborn.isRunning { stubborn.terminate(); kill(stubborn.processIdentifier, SIGKILL) } }
        var found: Holder?
        try await waitUntil(5) {
            found = HolderScanner.scan(volumePaths: [fx.mount], log: nil).holders.first { $0.pid == stubborn.processIdentifier }
            return found != nil
        }
        let h = try XCTUnwrap(found)
        XCTAssertEqual(h.kind, .cli)
        XCTAssertEqual(h.reasons, [.workingDirectory(path: fx.mount)])
        XCTAssertEqual(t.stop(h), .sent)
        try await Task.sleep(nanoseconds: 700_000_000)
        XCTAssertTrue(h.isSameProcess(), "ignores SIGTERM")
        XCTAssertEqual(t.kill(h), .sent)
        try await waitUntil(5) { !stubborn.isRunning }

        // S6: dead pid -> notFound; recycled/impostor pid -> pidMismatch, nothing sent. The impostor claims to be `cat`
        // at the pid of a `sleep` we spawned (not our own pid: Ejectable's own pid is refused before S6 is asked).
        XCTAssertEqual(t.stop(h), .notFound)
        let sleeper = Process()
        sleeper.executableURL = URL(fileURLWithPath: "/bin/sleep")
        sleeper.arguments = ["30"]
        try sleeper.run()
        defer { if sleeper.isRunning { sleeper.terminate() } }
        let real = try XCTUnwrap(HolderResolver.holder(forPID: sleeper.processIdentifier))
        let impostor = Holder(pid: real.pid, uid: real.uid, ppid: real.ppid, executablePath: "/bin/cat", startTime: real.startTime,
                              displayName: "cat", bundleIdentifier: nil, bundleURL: nil, parentAppBundleURL: nil,
                              kind: .cli, reasons: [], volumePaths: [])
        XCTAssertEqual(t.stop(impostor), .pidMismatch)
        let q = await t.quit(impostor.with(kind: .app), timeout: 1)
        XCTAssertEqual(q, .pidMismatch)
        XCTAssertTrue(sleeper.isRunning, "nothing was sent to the real process")
    }
}

// MARK: - S4 exception: Quick Look daemons may be stopped, every other daemon never

extension TerminatorTests {
    /// Two real processes we spawn (copies of duhold holding a fixture file), named exactly like Quick Look's
    /// `QuickLookUIService` and Spotlight's `mds`, both relabelled `.daemon` (how QuickLookUIService.xpc resolves on
    /// a real Mac). Terminator stops the Quick Look one (logged as the S4 exception) and refuses `mds`.
    @MainActor
    func testQuickLookDaemonIsStoppableButMdsIsNot() async throws {
        let fx = try Fixture.make("apfs", holders: [], name: "DUTEST_T_TERM")
        defer { fx.cleanup() }
        let file = try fx.makeFile("preview.jpg")
        let dir = Fixture.fixtureDir.appendingPathComponent("qlfake", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        func spawn(_ name: String) throws -> Process {
            let exe = dir.appendingPathComponent(name)
            try? FileManager.default.removeItem(at: exe)
            try FileManager.default.copyItem(at: Fixture.fixtureDir.appendingPathComponent("duhold"), to: exe)
            let p = Process()
            p.executableURL = exe
            p.arguments = ["fd", file]
            p.standardOutput = FileHandle.nullDevice
            try p.run()
            return p
        }
        let ql = try spawn("QuickLookUIService")
        defer { if ql.isRunning { kill(ql.processIdentifier, SIGKILL) } }
        let md = try spawn("mds")
        defer { if md.isRunning { kill(md.processIdentifier, SIGKILL) } }

        var holders: [Holder] = []
        try await waitUntil(5) {
            holders = HolderScanner.scan(volumePaths: [fx.mount], log: nil).holders
            return holders.contains { $0.pid == ql.processIdentifier } && holders.contains { $0.pid == md.processIdentifier }
        }
        let qlHolder = try XCTUnwrap(holders.first { $0.pid == ql.processIdentifier })
        let mdsHolder = try XCTUnwrap(holders.first { $0.pid == md.processIdentifier })
        XCTAssertEqual(mdsHolder.kind, .daemon, "mds is a known daemon name (S4)")
        XCTAssertEqual(qlHolder.reasons, [.openFile(path: file, writing: false)])
        let qlDaemon = qlHolder.with(kind: .daemon)
        let mdsDaemon = mdsHolder.with(kind: .daemon)
        // S4: the Quick Look name alone is not Quick Look; real Quick Look lives under /System/. Our copy is not there.
        XCTAssertFalse(qlHolder.executablePath.hasPrefix("/System/"))
        XCTAssertFalse(Terminator.isQuickLookException(qlDaemon), "a same-user daemon named QuickLookUIService outside /System/")
        let t0 = Terminator()
        XCTAssertEqual(t0.stop(qlDaemon), .refused(.daemon))
        XCTAssertTrue(qlHolder.isSameProcess(), "nothing was sent to the impostor")
        // Test-only allowance (debug builds) for this fixture executable, so the exception itself can be exercised.
        Terminator.debugAllowedQuickLookPaths.withLock { _ = $0.insert(qlHolder.executablePath) }
        defer { Terminator.debugAllowedQuickLookPaths.withLock { _ = $0.remove(qlHolder.executablePath) } }
        XCTAssertTrue(Terminator.isQuickLookException(qlDaemon))
        XCTAssertFalse(Terminator.isQuickLookException(mdsDaemon))
        XCTAssertFalse(Terminator.isQuickLookException(qlHolder.with(kind: .inaccessible)), "other users' processes: never")

        let t = Terminator()
        XCTAssertEqual(t.stop(mdsDaemon), .refused(.daemon), "S4: Spotlight is never signalled")
        XCTAssertEqual(t.kill(mdsDaemon), .refused(.daemon))
        let q = await t.quit(mdsDaemon, timeout: 1)
        XCTAssertEqual(q, .refused(.daemon))
        XCTAssertEqual(t.stop(qlHolder.with(kind: .inaccessible)), .refused(.inaccessible))
        XCTAssertTrue(mdsHolder.isSameProcess(), "nothing was sent to mds")
        XCTAssertTrue(qlHolder.isSameProcess(), "nothing was sent yet to the Quick Look process")

        XCTAssertEqual(t.stop(qlDaemon), .sent, "S4 exception: Quick Look may be stopped")
        try await waitUntil(5) { !ql.isRunning }
        XCTAssertTrue(md.isRunning, "mds untouched")
        let log = try String(contentsOf: ActionLog.shared.fileURL, encoding: .utf8)
        XCTAssertTrue(log.contains("[s4-exception] SIGTERM -> \(ql.processIdentifier) QuickLookUIService"), "logged as the exception")
        XCTAssertTrue(log.contains("[refused] SIGTERM -> \(md.processIdentifier) mds"), "refusal logged")
    }
}

// MARK: - Helpers

/// One DUTestHolder (or DUTestExtension) instance launched by a test. Only ever force-killed by the pid it was launched
/// with, after checking its bundle id.
struct TestApp {
    let pid: pid_t
    let logURL: URL
    var bundleID = Self.bundleID
    static let bundleID = "com.benrusnac.ejectable.testholder"
    /// DUTestExtension.app: the same binary, LSBackgroundOnly, so LaunchServices gives it activation policy `.prohibited`
    /// and the resolver classifies it `.appExtension`, like AirDrop.appex.
    static let extensionBundleID = "com.benrusnac.ejectable.testextension"

    var log: String { (try? String(contentsOf: logURL, encoding: .utf8)) ?? "" }

    static func bundleURL() throws -> URL {
        try skipOnCI("GUI test app (LaunchServices)")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = [Fixture.repoRoot.appendingPathComponent("Tests/fixtures/make-test-app.sh").path]
        let out = Pipe()
        p.standardOutput = out
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let path = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard p.terminationStatus == 0, !path.isEmpty else { throw XCTSkip("could not build DUTestHolder.app") }
        return URL(fileURLWithPath: path)
    }

    /// DUFakeEditor.app: the test holder with a fake Premiere-like bundle id (S10 toast test).
    static func fakeEditorURL() throws -> URL {
        try skipOnCI("GUI test app (LaunchServices)")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = [Fixture.repoRoot.appendingPathComponent("Tests/fixtures/make-test-app.sh").path, "--fake-editor"]
        let out = Pipe()
        p.standardOutput = out
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let path = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard p.terminationStatus == 0, path.hasSuffix("DUFakeEditor.app") else { throw XCTSkip("could not build DUFakeEditor.app") }
        return URL(fileURLWithPath: path)
    }

    /// DUTestExtension.app (see `extensionBundleID`).
    static func extensionURL() throws -> URL {
        try skipOnCI("GUI test app (LaunchServices)")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = [Fixture.repoRoot.appendingPathComponent("Tests/fixtures/make-test-app.sh").path, "--background-only"]
        let out = Pipe()
        p.standardOutput = out
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let path = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard p.terminationStatus == 0, path.hasSuffix("DUTestExtension.app") else { throw XCTSkip("could not build DUTestExtension.app") }
        return URL(fileURLWithPath: path)
    }

    static func unregisterFromLaunchServices(_ url: URL) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister")
        p.arguments = ["-u", url.path]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
        p.waitUntilExit()
    }

    @MainActor
    static func launch(holding file: String, refuse: Int, backgroundOnly: Bool = false) async throws -> TestApp {
        let url = try backgroundOnly ? extensionURL() : bundleURL()
        let logURL = Fixture.fixtureDir.appendingPathComponent("testholder-\(UUID().uuidString).log")
        let config = NSWorkspace.OpenConfiguration()
        config.activates = false
        config.createsNewApplicationInstance = true
        config.addsToRecentItems = false
        config.arguments = ["--hold", file, "--refuse", "\(refuse)", "--log", logURL.path]
        let pid: pid_t = try await withCheckedThrowingContinuation { cont in
            NSWorkspace.shared.openApplication(at: url, configuration: config) { app, error in
                if let app { cont.resume(returning: app.processIdentifier) } else { cont.resume(throwing: error ?? CocoaError(.fileNoSuchFile)) }
            }
        }
        let app = TestApp(pid: pid, logURL: logURL, bundleID: backgroundOnly ? extensionBundleID : bundleID)
        try await waitUntil(10) { app.log.contains("ready \(pid)") }
        return app
    }

    /// The app as the scanner sees it on the fixture volume.
    @MainActor
    func holder(on fx: Fixture) async throws -> Holder {
        var found: Holder?
        try await waitUntil(5) {
            found = HolderScanner.scan(volumePaths: [fx.mount], log: nil).holders.first { $0.pid == pid }
            return found != nil
        }
        return try XCTUnwrap(found)
    }

    /// Cleanup: only our own test app, by the pid we launched, after checking its bundle id.
    @MainActor
    func forceKillIfRunning() {
        guard let app = NSRunningApplication(processIdentifier: pid), app.bundleIdentifier == bundleID,
              !app.isTerminated else { return }
        app.forceTerminate()
    }
}

extension Fixture {
    /// Creates a small file on the fixture volume and returns its path.
    func makeFile(_ name: String) throws -> String {
        let p = path(name)
        try Data(repeating: 0, count: 4096).write(to: URL(fileURLWithPath: p))
        return p
    }
}

extension Holder {
    /// Same process facts, different kind (tests the kind gate in isolation).
    func with(kind: HolderKind) -> Holder {
        Holder(pid: pid, uid: uid, ppid: ppid, executablePath: executablePath, startTime: startTime, displayName: displayName,
               bundleIdentifier: bundleIdentifier, bundleURL: bundleURL, parentAppBundleURL: parentAppBundleURL, kind: kind,
               reasons: reasons, volumePaths: volumePaths)
    }
}

/// Polls `condition` on the main actor every 50 ms; fails the test after `timeout` seconds.
@MainActor
func waitUntil(_ timeout: TimeInterval, file: StaticString = #filePath, line: UInt = #line,
               _ condition: @MainActor () -> Bool) async throws {
    let end = Date().addingTimeInterval(timeout)
    while Date() < end {
        if condition() { return }
        try await Task.sleep(nanoseconds: 50_000_000)
    }
    if condition() { return }
    XCTFail("condition not met within \(timeout) s", file: file, line: line)
    throw CancellationError()
}
