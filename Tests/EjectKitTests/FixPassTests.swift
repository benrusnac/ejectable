@testable import EjectKit
import DiskArbitration
import XCTest

/// Fix pass (phase-1 review): DA status mapping, ActionLog privacy/rotation, VolumeMonitor without NSWorkspace.
final class FixPassTests: XCTestCase {
    override func setUp() { redirectTestLogs() }

    // MARK: Ejector status mapping

    func testBusyStatusesMapToBusy() {
        let step = EjectStep.unmount(bsdName: "disk99")
        guard case .busy(let pid, _, _) = Ejector.result(status: 0xC010, pid: 123, step: step), pid == 123 else {
            return XCTFail("unix_err(EBUSY) names the dissenter")
        }
        for s in [kDAReturnBusy, kDAReturnExclusiveAccess] {
            guard case .busy(nil, _, _) = Ejector.result(status: DAReturn(truncatingIfNeeded: s), pid: 456, step: step) else {
                return XCTFail("DA status 0x\(String(UInt32(truncatingIfNeeded: s), radix: 16)) must be busy without a pid")
            }
        }
        guard case .failed = Ejector.result(status: DAReturn(truncatingIfNeeded: kDAReturnNotPermitted), pid: nil, step: step) else {
            return XCTFail("other statuses fail")
        }
        XCTAssertTrue(EjectResult.unmountedNotEjected(status: 0xC010).isSafeToDisconnect)
        XCTAssertFalse(EjectResult.unmountedNotEjected(status: 0xC010).isEjected)
        XCTAssertFalse(EjectResult.busy(dissenterPID: nil, status: 0xC010, step: step).isSafeToDisconnect)
    }

    // MARK: ActionLog (S9 + privacy)

    func testActionLogFileIsPrivateAndRotates() throws {
        let dir = Fixture.repoRoot.appendingPathComponent(".build/test-logs/rotate-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = ActionLog(directory: dir, rotateAt: 4096)
        for i in 0..<80 { log.record("test", "line \(i) /Volumes/SECRET/clip-\(i).mov " + String(repeating: "x", count: 40)) }
        let file = log.fileURL.path
        let attrs = try FileManager.default.attributesOfItem(atPath: file)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertLessThanOrEqual((attrs[.size] as? NSNumber)?.intValue ?? .max, 4096)
        let rotated = file + ".1"
        XCTAssertTrue(FileManager.default.fileExists(atPath: rotated), "one previous file is kept")
        XCTAssertFalse(FileManager.default.fileExists(atPath: file + ".2"))
        let text = try String(contentsOfFile: file, encoding: .utf8)
        XCTAssertTrue(text.contains("line 79 "), "the newest line is in the current file")
        // A file left 0644 by an older build is tightened on the next write.
        chmod(file, 0o644)
        log.record("test", "after chmod")
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: file)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    // MARK: VolumeMonitor (S7: no NSWorkspace observers)

    /// The menu list follows a fixture mount and unmount through the private DA session + kqueue (EVFILT_FS), with no
    /// NSWorkspace notification observer anywhere.
    @MainActor
    func testVolumeMonitorSeesFixtureMountAndUnmount() async throws {
        let monitor = VolumeMonitor.shared
        let changes = Box<Int>(0)
        let previous = monitor.onChange
        monitor.onChange = { _ in changes.update { $0 += 1 } }
        defer { monitor.onChange = previous }
        let before = monitor.stats
        let fx = try Fixture.make("hfs", holders: [], name: "DUTEST_T_MON")
        var cleaned = false
        defer { if !cleaned { fx.cleanup() } }
        try await waitUntil(10) { monitor.volumes.contains { $0.path == fx.mount } }
        XCTAssertGreaterThan(monitor.stats.mountEvents, before.mountEvents, "kernel mount events (EVFILT_FS)")
        XCTAssertGreaterThan(monitor.stats.diskEvents, before.diskEvents, "DiskArbitration notifications")
        fx.cleanup()
        cleaned = true
        try await waitUntil(10) { !monitor.volumes.contains { $0.path == fx.mount } }
        XCTAssertGreaterThanOrEqual(changes.value, 2)
    }
}
