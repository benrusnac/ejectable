import EjectKit
import XCTest

/// Real DiskArbitration ejects, against fixture disk images only (the policy is `.diskImagesOnly`).
final class EjectTests: XCTestCase {
    override func setUp() { redirectTestLogs() }

    /// Busy (fd holder named by DA) -> clear holders -> soft eject succeeds and the image is gone.
    func testBusyThenClearThenEjectAPFS() throws { try busyThenEject("apfs") }
    func testBusyThenClearThenEjectHFS() throws { try busyThenEject("hfs") }
    func testBusyThenClearThenEjectExFAT() throws { try busyThenEject("exfat") }

    func testForceEjectWithHoldersPresent() throws {
        let fx = try Fixture.make("apfs", holders: ["fd", "fdw", "cwd", "mmap"])
        defer { fx.cleanup() }
        let disk = try XCTUnwrap(topo(forVolume: fx.mount))
        let r = try XCTUnwrap(ejectSync(Ejector(), disk, force: true))
        XCTAssertTrue(r.isEjected, "force eject: \(r)")
        XCTAssertFalse(fx.isMounted)
        XCTAssertNil(topo(bsdName: disk.bsdName).flatMap { $0.appearanceTime == disk.appearanceTime ? $0 : nil },
                     "the image's disk must be gone")
        // Holders survive a forced unmount (fd -> EBADF on next read, mmap -> SIGBUS on next touch; ours never touch).
        XCTAssertTrue(fx.isAlive("fd"))
        XCTAssertTrue(fx.isAlive("mmap"))
    }

    /// DA names no pid when the only holder is an mmap on APFS (same libproc bug); our scan still finds it.
    func testMmapOnlyHolderBlocksEjectAndScanExplainsIt() throws {
        let fx = try Fixture.make("apfs", holders: ["mmap"])
        defer { fx.cleanup() }
        let disk = try XCTUnwrap(topo(forVolume: fx.mount))
        let r = try XCTUnwrap(ejectSync(Ejector(), disk))
        guard case .busy(let pid, _, _) = r else { return XCTFail("mmap holder must block the eject: \(r)") }
        print("mmap-only dissenter pid: \(pid.map(String.init) ?? "nil (as in RECON §3)")")
        let scan = HolderScanner.scan(disk: disk, log: nil)
        XCTAssertEqual(scan.holders.map(\.pid), [fx.pids["mmap"]].compactMap { $0 })
    }

    private func busyThenEject(_ fs: String) throws {
        let fx = try Fixture.make(fs, holders: ["fd"])
        defer { fx.cleanup() }
        let disk = try XCTUnwrap(topo(forVolume: fx.mount))
        XCTAssertTrue(disk.isVirtual)
        let ejector = Ejector()

        let busy = try XCTUnwrap(ejectSync(ejector, disk))
        guard case .busy(let pid, let status, let step) = busy else { return XCTFail("\(fs): expected busy, got \(busy)") }
        XCTAssertEqual(pid, fx.pids["fd"], "\(fs): DA dissenter must be the fd holder")
        XCTAssertEqual(status & 0x3fff, EBUSY)
        XCTAssertEqual(step, .unmount(bsdName: disk.containerBSDNames[0]))
        XCTAssertTrue(fx.isMounted)
        XCTAssertGreaterThanOrEqual(ejector.diskArbitrationRequestCount, 1)

        fx.killHolders()
        XCTAssertTrue(HolderScanner.scan(volumePaths: disk.volumePaths, log: nil).isClear)
        // A system daemon (mds/fseventsd) may briefly touch a fresh volume; allow a couple of soft retries.
        var result: EjectResult?
        for attempt in 0..<3 {
            result = ejectSync(ejector, disk)
            if result?.isEjected == true { break }
            print("\(fs): retry \(attempt + 1) after \(String(describing: result))")
            Thread.sleep(forTimeInterval: 1)
        }
        XCTAssertTrue(result?.isEjected == true, "\(fs): eject after clearing holders: \(String(describing: result))")
        XCTAssertFalse(fx.isMounted)
    }
}
