import AppKit
import EjectKit
import XCTest

/// PLAN §4b safety rules that EjectKit enforces in phase 1 (S5 wrong-disk guard, S1/S2 force only on request,
/// S6 pid verification, S9 logging). Real disks are only ever inspected read-only; refusals happen before any
/// DiskArbitration request, which `diskArbitrationRequestCount` proves.
final class SafetyTests: XCTestCase {
    override func setUp() { redirectTestLogs() }

    // MARK: S5 — internal / root / system disks are refused before DA, under every policy

    func testS5RefusesRootFilesystemDisk() throws {
        let root = try XCTUnwrap(topo(forVolume: "/"))
        for policy in [EjectPolicy.diskImagesOnly, .externalDisks] {
            XCTAssertEqual(Ejector.safetyCheck(root, policy: policy), .internalDisk(bsdName: root.bsdName))
            let ejector = Ejector(dryRun: true)          // real disk: never able to send a DA request
            for force in [false, true] {
                let r = try XCTUnwrap(ejectSync(ejector, root, force: force, policy: policy))
                guard case .refused(.internalDisk) = r else { return XCTFail("expected refusal, got \(r)") }
            }
            XCTAssertEqual(ejector.diskArbitrationRequestCount, 0, "no DA request may be sent for the boot disk")
        }
    }

    func testS5InternalIsNeverAllowed() {
        XCTAssertFalse(EjectPolicy.externalDisks.allowInternal)
        XCTAssertFalse(EjectPolicy(allowRealDisks: true).allowInternal)
    }

    /// A real external disk (read-only use) is refused when the policy only allows disk images.
    func testS5RefusesRealDiskWithoutAllowRealDisks() throws {
        let real = DiskTopology.externalVolumes()
            .filter { !$0.isNetwork }
            .compactMap { topo(forVolume: $0.path) }
            .first { !$0.isVirtual }
        guard let disk = real else { throw XCTSkip("no real external disk mounted") }
        XCTAssertFalse(disk.isInternal)
        XCTAssertEqual(Ejector.safetyCheck(disk, policy: .diskImagesOnly),
                       .notADiskImage(bsdName: disk.bsdName, model: disk.deviceModel))
        let ejector = Ejector(dryRun: true)              // real disk: never able to send a DA request
        for force in [false, true] {
            let r = try XCTUnwrap(ejectSync(ejector, disk, force: force, policy: .diskImagesOnly))
            guard case .refused(.notADiskImage) = r else { return XCTFail("expected refusal, got \(r)") }
        }
        XCTAssertEqual(ejector.diskArbitrationRequestCount, 0, "refusal must happen before any DA call")
    }

    /// A stale/forged snapshot cannot smuggle the boot disk past the guard: the ejector re-resolves the BSD
    /// name from DiskArbitration and checks identity and S5 again on the fresh state.
    func testS5ForgedSnapshotIsReResolvedAndRefused() throws {
        let root = try XCTUnwrap(topo(forVolume: "/"))
        let forged = PhysicalDisk(bsdName: root.bsdName, isInternal: false, deviceInternalKey: false, isVirtual: true,
                                  deviceModel: "Disk Image", deviceProtocol: "Virtual Interface", mediaName: nil,
                                  mediaSize: root.mediaSize, isEjectable: true, isRemovable: true,
                                  appearanceTime: root.appearanceTime, volumes: [], containerBSDNames: [])
        XCTAssertNil(Ejector.safetyCheck(forged, policy: .diskImagesOnly), "forged snapshot passes the static check")
        let ejector = Ejector(dryRun: true)
        let r = try XCTUnwrap(ejectSync(ejector, forged, force: true, policy: .externalDisks))
        guard case .refused = r else { return XCTFail("forged snapshot must be refused, got \(r)") }
        XCTAssertEqual(ejector.diskArbitrationRequestCount, 0)
    }

    /// The fresh-state S5 check is what catches a snapshot that has the boot disk's real identity (model, size,
    /// appearance time, not virtual) but claims to be external with no volumes: the identity check passes, the first
    /// (static) check passes, and only the second `safetyCheck` on the re-resolved disk refuses it. Removing that
    /// second check makes this test fail (dry run: nothing could be sent even then).
    func testS5FreshStateCheckRefusesBootDiskBehindAnInnocentSnapshot() throws {
        let root = try XCTUnwrap(topo(forVolume: "/"))
        let forged = PhysicalDisk(bsdName: root.bsdName, isInternal: false, deviceInternalKey: false, isVirtual: root.isVirtual,
                                  deviceModel: root.deviceModel, deviceProtocol: root.deviceProtocol, mediaName: root.mediaName,
                                  mediaSize: root.mediaSize, isEjectable: root.isEjectable, isRemovable: root.isRemovable,
                                  appearanceTime: root.appearanceTime, volumes: [], containerBSDNames: [])
        XCTAssertNil(Ejector.safetyCheck(forged, policy: .externalDisks), "the forged snapshot passes the static check")
        for force in [false, true] {
            let ejector = Ejector(dryRun: true)
            let r = try XCTUnwrap(ejectSync(ejector, forged, force: force, policy: .externalDisks))
            guard case .refused(.internalDisk(let bsd)) = r, bsd == root.bsdName else {
                return XCTFail("force=\(force): the fresh-state S5 check must refuse the boot disk, got \(r)")
            }
            XCTAssertEqual(ejector.diskArbitrationRequestCount, 0)
        }
    }

    /// RAID sets / Fusion / multi-store containers are refused before any DA request (and listed, not offered).
    func testS5RefusesMultiMemberDisks() throws {
        let raid = PhysicalDisk(bsdName: "disk98", isInternal: false, deviceInternalKey: false, isVirtual: true, deviceModel: "Disk Image",
                                deviceProtocol: "Virtual Interface", mediaName: nil, mediaSize: 1, isEjectable: true, isRemovable: true,
                                appearanceTime: 1, volumes: [], containerBSDNames: ["disk98"], wholeAncestors: ["disk96", "disk97"])
        XCTAssertTrue(raid.isMultiMember)
        for policy in [EjectPolicy.diskImagesOnly, .externalDisks] {
            XCTAssertEqual(Ejector.safetyCheck(raid, policy: policy), .multiMemberDisk(bsdName: "disk98", members: ["disk96", "disk97"]))
        }
        let ejector = Ejector(dryRun: true)
        let r = try XCTUnwrap(ejectSync(ejector, raid, force: true, policy: .externalDisks))
        guard case .refused(.multiMemberDisk) = r else { return XCTFail("\(r)") }
        XCTAssertEqual(ejector.diskArbitrationRequestCount, 0)
    }

    /// A forced eject is refused when the disk's volumes changed after the snapshot the user confirmed.
    func testForceRefusedWhenVolumeSetChanged() throws {
        let fx = try Fixture.make("apfs", holders: [], name: "DUTEST_T_VOLS")
        defer { fx.cleanup() }
        let disk = try XCTUnwrap(topo(forVolume: fx.mount))
        let stale = PhysicalDisk(bsdName: disk.bsdName, isInternal: disk.isInternal, deviceInternalKey: disk.deviceInternalKey,
                                 isVirtual: disk.isVirtual, deviceModel: disk.deviceModel, deviceProtocol: disk.deviceProtocol,
                                 mediaName: disk.mediaName, mediaSize: disk.mediaSize, isEjectable: disk.isEjectable,
                                 isRemovable: disk.isRemovable, appearanceTime: disk.appearanceTime, volumes: [],
                                 containerBSDNames: disk.containerBSDNames, interconnectLocation: disk.interconnectLocation,
                                 wholeAncestors: disk.wholeAncestors)
        let ejector = Ejector(dryRun: true)
        let r = try XCTUnwrap(ejectSync(ejector, stale, force: true))
        guard case .refused(.diskChanged) = r else { return XCTFail("forced eject with a changed volume set: \(r)") }
        XCTAssertEqual(ejector.diskArbitrationRequestCount, 0)
        // The same stale snapshot is fine for a soft eject (kernel-enforced): it gets as far as the (dry-run) request.
        let soft = try XCTUnwrap(ejectSync(ejector, stale, force: false))
        guard case .failed(0, .unmount) = soft else { return XCTFail("\(soft)") }
        XCTAssertTrue(fx.isMounted)
    }

    /// Dry run on a real fixture: every guard and re-resolution runs, exactly one request is counted, none is sent.
    func testDryRunOnFixtureSendsNothing() throws {
        let fx = try Fixture.make("hfs", holders: [], name: "DUTEST_T_DRY")
        defer { fx.cleanup() }
        let disk = try XCTUnwrap(topo(forVolume: fx.mount))
        for force in [false, true] {
            let ejector = Ejector(dryRun: true)
            let r = try XCTUnwrap(ejectSync(ejector, disk, force: force))
            guard case .failed(0, .unmount(let bsd)) = r, bsd == disk.containerBSDNames.first else { return XCTFail("\(r)") }
            XCTAssertEqual(ejector.diskArbitrationRequestCount, 1)
            XCTAssertTrue(fx.isMounted, "dry run must leave the fixture mounted")
            XCTAssertEqual(topo(bsdName: disk.bsdName)?.appearanceTime, disk.appearanceTime)
        }
    }

    /// A snapshot taken before the disk went away must not act on whatever now has that BSD name.
    func testS5StaleSnapshotOfReattachedImageIsRefused() throws {
        let first = try Fixture.make("hfs", holders: [])
        let stale = try XCTUnwrap(topo(forVolume: first.mount))
        first.cleanup()
        let second = try Fixture.make("hfs", holders: [])
        defer { second.cleanup() }
        let current = try XCTUnwrap(topo(forVolume: second.mount))
        print("stale \(stale.bsdName) @\(stale.appearanceTime ?? 0), current \(current.bsdName) @\(current.appearanceTime ?? 0)")
        let ejector = Ejector(dryRun: true)              // a regressed identity check must still not eject `second`
        let r = try XCTUnwrap(ejectSync(ejector, stale))
        switch r {
        case .refused(.diskChanged), .refused(.diskNotFound): break
        default: XCTFail("stale snapshot must be refused, got \(r)")
        }
        XCTAssertEqual(ejector.diskArbitrationRequestCount, 0)
        XCTAssertTrue(second.isMounted)
    }

    func testS5RefusesSystemAndNonVolumesMounts() {
        func disk(_ volumes: [VolumeInfo]) -> PhysicalDisk {
            PhysicalDisk(bsdName: "disk99", isInternal: false, deviceInternalKey: nil, isVirtual: true, deviceModel: "Disk Image",
                         deviceProtocol: "Virtual Interface", mediaName: nil, mediaSize: nil, isEjectable: true, isRemovable: true,
                         appearanceTime: nil, volumes: volumes, containerBSDNames: [])
        }
        func vol(_ path: String, isInternal: Bool? = nil, root: Bool = false) -> VolumeInfo {
            VolumeInfo(path: path, name: "x", fileSystem: "apfs", isNetwork: false, isInternal: isInternal,
                       isRootFileSystem: root, isBrowsable: true, bsdName: "disk99s1")
        }
        XCTAssertEqual(Ejector.safetyCheck(disk([vol("/", root: true)]), policy: .externalDisks), .rootFileSystem(path: "/"))
        XCTAssertEqual(Ejector.safetyCheck(disk([vol("/System/Volumes/Data")]), policy: .externalDisks),
                       .systemVolume(path: "/System/Volumes/Data"))
        XCTAssertEqual(Ejector.safetyCheck(disk([vol("/Volumes/X", isInternal: true)]), policy: .externalDisks),
                       .internalVolume(path: "/Volumes/X"))
        XCTAssertEqual(Ejector.safetyCheck(disk([vol("/Library/Developer/CoreSimulator/Volumes/iOS")]), policy: .externalDisks),
                       .notUnderVolumes(path: "/Library/Developer/CoreSimulator/Volumes/iOS"))
        XCTAssertEqual(Ejector.safetyCheck(disk([vol("/Volumes/X")]).withName("disk99s1"), policy: .externalDisks),
                       .notAWholeDisk(bsdName: "disk99s1"))
        XCTAssertNil(Ejector.safetyCheck(disk([vol("/Volumes/X")]), policy: .diskImagesOnly))
    }

    /// Network disconnect: only shares mounted directly under /Volumes; local volumes and anything outside /Volumes
    /// (an NFS home under /Users) are refused before any request. Completion runs on the ejector's queue.
    func testS5NetworkUnmountRefusesLocalAndNonVolumesPaths() throws {
        let ejector = Ejector(dryRun: true)
        var cases: [(String, SafetyRefusal)] = [("/", .notUnderVolumes(path: "/")),
                                                (NSHomeDirectory(), .notUnderVolumes(path: NSHomeDirectory())),
                                                ("/Volumes/DUTEST_NOT_MOUNTED", .notANetworkShare(path: "/Volumes/DUTEST_NOT_MOUNTED"))]
        if let local = DiskTopology.externalVolumes().first(where: { !$0.isNetwork }) {   // read-only: refused by kind
            cases.append((local.path, .notANetworkShare(path: local.path)))
        }
        for (path, expected) in cases {
            let box = ResultBox()
            let done = DispatchSemaphore(value: 0)
            ejector.unmountNetworkShare(url: URL(fileURLWithPath: path)) { r in
                XCTAssertFalse(Thread.isMainThread)
                box.set(r); done.signal()
            }
            XCTAssertEqual(done.wait(timeout: .now() + 10), .success)
            guard case .refused(let refusal) = try XCTUnwrap(box.get()), refusal == expected else {
                return XCTFail("\(path): \(String(describing: box.get()))")
            }
        }
        XCTAssertEqual(ejector.diskArbitrationRequestCount, 0)
    }

    /// The fixture script itself refuses to clean up anything that is not a DUTEST fixture.
    func testS5FixtureScriptRefusesForeignNames() {
        for name in ["EXAMPLE_SSD", "NAS_SHARE", "Macintosh HD", "../DUTEST_X", "DUTEST_X/..", "DUTEST_X/../../x", "DUTEST*",
                     "DUTEST", "DUTEST x", "DUTEST_x"] {
            let r = Fixture.run(["--cleanup", name])
            XCTAssertNotEqual(r.status, 0, "script accepted \(name)")
            XCTAssertTrue(r.output.contains("refusing") || r.output.contains("no state file"), r.output)
        }
        XCTAssertTrue(DiskTopology.volumeInfo(path: "/")?.isRootFileSystem ?? false)
    }

    // MARK: S1/S2 — soft unless asked; force works and flushes

    func testS1SoftEjectNeverForcesOnItsOwn() throws {
        let fx = try Fixture.make("apfs", holders: ["fd"])
        defer { fx.cleanup() }
        let disk = try XCTUnwrap(topo(forVolume: fx.mount))
        let r = try XCTUnwrap(ejectSync(Ejector(), disk))
        guard case .busy = r else { return XCTFail("soft eject with a holder must be busy, got \(r)") }
        XCTAssertTrue(fx.isMounted, "a soft eject must leave a busy volume mounted")
        XCTAssertTrue(fx.isAlive("fd"))
    }

    // MARK: S6 — pid re-verification

    /// S6 fails closed: no recorded start time (or none readable now) means "not the same process".
    func testS6FailsClosedWithoutStartTime() throws {
        let me = try XCTUnwrap(HolderResolver.holder(forPID: getpid()))
        XCTAssertTrue(me.isSameProcess())
        let noStart = Holder(pid: me.pid, uid: me.uid, ppid: me.ppid, executablePath: me.executablePath, startTime: nil,
                             displayName: me.displayName, bundleIdentifier: nil, bundleURL: nil, parentAppBundleURL: nil,
                             kind: me.kind, reasons: [], volumePaths: [])
        XCTAssertFalse(noStart.isSameProcess(), "a holder without a start time can never be acted on")
        let gone = Holder(pid: 99_999_9, uid: me.uid, ppid: 1, executablePath: me.executablePath, startTime: me.startTime,
                          displayName: "gone", bundleIdentifier: nil, bundleURL: nil, parentAppBundleURL: nil,
                          kind: .cli, reasons: [], volumePaths: [])
        XCTAssertFalse(gone.isSameProcess())
    }

    /// S6 for helpers: the parent app is only looked up for a holder that is still the same process.
    @MainActor
    func testS6ParentAppNeedsTheSameProcess() throws {
        let finder = try XCTUnwrap(NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == "com.apple.finder" })
        let recycled = Holder(pid: getpid(), uid: getuid(), ppid: 1, executablePath: "/nonexistent/Finder Helper", startTime: 1,
                              displayName: "Finder Helper", bundleIdentifier: nil, bundleURL: nil,
                              parentAppBundleURL: finder.bundleURL, kind: .helper, reasons: [], volumePaths: [])
        XCTAssertNil(recycled.parentRunningApplication(), "a recycled helper pid must not lead to Finder")
        XCTAssertNil(Terminator.targetApplication(for: recycled))
    }

    func testS6RecycledPidIsDetected() throws {
        let fx = try Fixture.make("apfs", holders: ["fd"])
        defer { fx.cleanup() }
        let scan = HolderScanner.scan(volumePaths: [fx.mount], log: nil)
        let h = try XCTUnwrap(scan.holders.first { $0.pid == fx.pids["fd"] })
        XCTAssertTrue(h.isSameProcess())
        let impostor = Holder(pid: h.pid, uid: h.uid, ppid: h.ppid, executablePath: "/bin/sleep", startTime: h.startTime,
                              displayName: "sleep", bundleIdentifier: nil, bundleURL: nil, parentAppBundleURL: nil,
                              kind: .cli, reasons: h.reasons, volumePaths: h.volumePaths)
        XCTAssertFalse(impostor.isSameProcess(), "different executable at the same pid must not verify")
        let restarted = Holder(pid: h.pid, uid: h.uid, ppid: h.ppid, executablePath: h.executablePath,
                               startTime: (h.startTime ?? 0) - 60, displayName: h.displayName, bundleIdentifier: nil,
                               bundleURL: nil, parentAppBundleURL: nil, kind: h.kind, reasons: h.reasons, volumePaths: h.volumePaths)
        XCTAssertFalse(restarted.isSameProcess(), "same executable, different start time must not verify")
        fx.killHolders()
        XCTAssertFalse(h.isSameProcess(), "dead pid must not verify")
    }

    // MARK: S9 — logging

    func testS9EjectsAndScansAreLogged() throws {
        let dir = Fixture.repoRoot.appendingPathComponent(".build/test-logs/s9-\(UUID().uuidString)", isDirectory: true)
        let log = ActionLog(directory: dir)
        let root = try XCTUnwrap(topo(forVolume: "/"))
        _ = ejectSync(Ejector(log: log, dryRun: true), root)
        _ = HolderScanner.scan(volumePaths: ["/System/Volumes/VM"], log: log)
        let text = try String(contentsOf: log.fileURL, encoding: .utf8)
        XCTAssertTrue(text.contains("[eject] [dry-run] result \(root.bsdName): refused"), "dry runs are tagged: \(text)")
        XCTAssertTrue(text.contains("[scan] /System/Volumes/VM: [scanned: none"), "system volumes are never scanned: \(text)")
        try? FileManager.default.removeItem(at: dir)
    }
}

private extension PhysicalDisk {
    func withName(_ bsd: String) -> PhysicalDisk {
        PhysicalDisk(bsdName: bsd, isInternal: isInternal, deviceInternalKey: deviceInternalKey, isVirtual: isVirtual,
                     deviceModel: deviceModel, deviceProtocol: deviceProtocol, mediaName: mediaName, mediaSize: mediaSize,
                     isEjectable: isEjectable, isRemovable: isRemovable, appearanceTime: appearanceTime,
                     volumes: volumes, containerBSDNames: containerBSDNames)
    }
}
