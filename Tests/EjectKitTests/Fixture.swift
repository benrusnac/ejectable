import EjectKit
import Foundation
import XCTest

/// Drives Tests/fixtures/make-busy-volume.sh. Test fixtures use their own names (DUTEST_T_*) so they never
/// collide with manually created ones, and the script only ever detaches its own image (S5).
struct Fixture {
    let name: String
    let fs: String
    let mount: String
    /// Second APFS volume on the same disk (`make(…, secondVolume:)`), nil otherwise.
    var mount2: String? = nil
    let device: String
    let image: String
    /// holder mode (fd, fdw, cwd, mmap, mmapw, mmapp, evtonly) -> pid
    let pids: [String: pid_t]

    static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static let script = repoRoot.appendingPathComponent("Tests/fixtures/make-busy-volume.sh").path
    static let fixtureDir = repoRoot.appendingPathComponent(".build/fixtures", isDirectory: true)

    /// Default test fixture name per filesystem (newfs_exfat rejects '_').
    static func testName(_ fs: String) -> String { fs == "exfat" ? "DUTESTTXFAT" : "DUTEST_T_\(fs.uppercased())" }

    @discardableResult
    static func run(_ args: [String]) -> (status: Int32, output: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = [script] + args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return (-1, "\(error)") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    /// Creates and mounts a busy volume. Skips the test if hdiutil is unavailable or fails, or if the state file does
    /// not name a /Volumes/DUTEST… mount (an empty mount would make `physicalDisk(forVolume: "")` resolve the cwd's
    /// volume, i.e. the boot disk).
    static func make(_ fs: String, holders: [String], name: String? = nil, secondVolume: String? = nil,
                     holders2: [String] = []) throws -> Fixture {
        let name = name ?? testName(fs)
        guard name.hasPrefix("DUTEST"), secondVolume?.hasPrefix("DUTEST") ?? true else { throw XCTSkip("refusing fixture name \(name)") }
        let statePath = fixtureDir.appendingPathComponent("\(name).state").path
        if FileManager.default.fileExists(atPath: statePath) { run(["--cleanup", name]) }   // stale from a crashed run
        var args = [fs, "--holders", holders.joined(separator: ","), "--name", name]
        if let secondVolume {
            args += ["--second-volume", secondVolume]
            if !holders2.isEmpty { args += ["--holders2", holders2.joined(separator: ",")] }
        }
        let r = run(args)
        guard r.status == 0, let state = try? String(contentsOfFile: statePath, encoding: .utf8) else {
            throw XCTSkip("fixture \(name) unavailable (hdiutil failed?): \(r.output)")
        }
        var kv: [String: String] = [:]
        for line in state.split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
            if parts.count == 2 { kv[parts[0]] = parts[1] }
        }
        var pids: [String: pid_t] = [:]
        for (k, v) in kv where k.hasPrefix("holder.") { pids[String(k.dropFirst(7))] = pid_t(v) }
        guard let mount = kv["mount"], mount == "/Volumes/\(name)", mount.hasPrefix("/Volumes/DUTEST"),
              let device = kv["device"], device.hasPrefix("/dev/disk") else {
            run(["--cleanup", name])
            throw XCTSkip("fixture \(name): state file has no /Volumes/DUTEST mount or device: \(state)")
        }
        if let secondVolume {
            guard kv["mount2"] == "/Volumes/\(secondVolume)" else {
                run(["--cleanup", name])
                throw XCTSkip("fixture \(name): no second volume /Volumes/\(secondVolume): \(state)")
            }
        }
        return Fixture(name: name, fs: fs, mount: mount, mount2: kv["mount2"], device: device, image: kv["image"] ?? "", pids: pids)
    }

    func killHolders() { Fixture.run(["--kill-holders", name]) }
    func cleanup() { Fixture.run(["--cleanup", name]) }

    var isMounted: Bool { DiskTopology.volumeInfo(path: mount)?.path == mount }
    /// In the kernel mount table (no statfs).
    func isInMountTable(_ path: String) -> Bool { DiskTopology.mountedPaths().contains(path) }
    func path(_ file: String) -> String { mount + "/" + file }
    func isAlive(_ mode: String) -> Bool { pids[mode].map { kill($0, 0) == 0 } ?? false }
}

/// Blocking wrapper around the async Ejector (completion runs on the ejector's private queue).
func ejectSync(_ ejector: Ejector, _ disk: PhysicalDisk, force: Bool = false,
               policy: EjectPolicy = .diskImagesOnly, timeout: TimeInterval = 60) -> EjectResult? {
    let box = ResultBox()
    let done = DispatchSemaphore(value: 0)
    ejector.eject(disk: disk, force: force, policy: policy) { box.set($0); done.signal() }
    guard done.wait(timeout: .now() + timeout) == .success else { return nil }
    return box.get()
}

final class ResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: EjectResult?
    func set(_ v: EjectResult) { lock.withLock { value = v } }
    func get() -> EjectResult? { lock.withLock { value } }
}

/// Send test logs to .build/test-logs instead of ~/Library/Logs.
func redirectTestLogs() {
    ActionLog.shared.setDirectory(Fixture.repoRoot.appendingPathComponent(".build/test-logs", isDirectory: true))
}

/// Runs `body` on a background thread and waits for it. DiskTopology's DiskArbitration / IOKit lookups assert (debug
/// builds) that they never run on the main thread, where XCTest runs the tests.
func offMain<T: Sendable>(_ body: @escaping @Sendable () -> T) -> T {
    let box = SendableBox<T>()
    let done = DispatchSemaphore(value: 0)
    DispatchQueue.global(qos: .userInitiated).async { box.set(body()); done.signal() }
    done.wait()
    return box.get()!
}

/// `DiskTopology.physicalDisk(forVolume:)` off the main thread.
func topo(forVolume path: String) -> PhysicalDisk? { offMain { DiskTopology.physicalDisk(forVolume: path) } }
/// `DiskTopology.physicalDisk(bsdName:)` off the main thread.
func topo(bsdName: String) -> PhysicalDisk? { offMain { DiskTopology.physicalDisk(bsdName: bsdName) } }

final class SendableBox<T: Sendable>: @unchecked Sendable {   // guarded by lock
    private let lock = NSLock()
    private var value: T?
    func set(_ v: T) { lock.withLock { value = v } }
    func get() -> T? { lock.withLock { value } }
}

/// On CI (GitHub Actions sets CI=true) the tests that depend on the timing of another process's DiskArbitration
/// request (EjectWatcher) or on LaunchServices launching the GUI test apps are skipped: hosted runners are slow and
/// shared, and a timing failure there says nothing about the code. Run the full suite locally with `swift test`.
/// Fixture disk images themselves skip (never fail) when `hdiutil` is unavailable: see `Fixture.make`.
func skipOnCI(_ what: String) throws {
    try XCTSkipIf(ProcessInfo.processInfo.environment["CI"] == "true", "\(what): skipped on CI; run `swift test` locally")
}
