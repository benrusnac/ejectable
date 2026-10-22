@testable import EjectKit
import AppKit
import XCTest

final class TopologyTests: XCTestCase {
    override func setUp() { redirectTestLogs() }

    func testAPFSFixtureMapsToVirtualPhysicalDisk() throws {
        let fx = try Fixture.make("apfs", holders: [])
        defer { fx.cleanup() }
        let disk = try XCTUnwrap(topo(forVolume: fx.mount))
        XCTAssertEqual("/dev/" + disk.bsdName, fx.device, "physical disk must be the image's whole disk")
        XCTAssertTrue(disk.isVirtual)
        XCTAssertFalse(disk.isInternal)
        XCTAssertNil(disk.deviceInternalKey, "disk images carry no DADeviceInternal")
        XCTAssertEqual(disk.interconnectLocation, "File", "disk images: IOKit Physical Interconnect Location = File")
        XCTAssertEqual(disk.wholeAncestors, [disk.bsdName])
        XCTAssertFalse(disk.isMultiMember)
        XCTAssertEqual(disk.volumePaths, [fx.mount])
        XCTAssertEqual(disk.containerBSDNames.count, 1)
        XCTAssertNotEqual(disk.containerBSDNames.first, disk.bsdName, "APFS: container is the synthesized disk")
        // A container is not a physical whole disk.
        XCTAssertNil(topo(bsdName: disk.containerBSDNames[0]))
        XCTAssertNil(Ejector.safetyCheck(disk, policy: .diskImagesOnly))

        let ext = DiskTopology.externalVolumes()
        XCTAssertTrue(ext.contains { $0.path == fx.mount && !$0.isNetwork }, "browsable fixture must be listed")
        XCTAssertFalse(ext.contains { $0.path == "/" || $0.isRootFileSystem || $0.isSystemVolume })
        let mount = fx.mount
        XCTAssertFalse(offMain { DiskTopology.ioRegistryChain(forVolume: mount) }.isEmpty)
    }

    func testHFSFixtureContainerIsThePhysicalDisk() throws {
        let fx = try Fixture.make("hfs", holders: [])
        defer { fx.cleanup() }
        let disk = try XCTUnwrap(topo(forVolume: fx.mount))
        XCTAssertTrue(disk.isVirtual)
        XCTAssertEqual(disk.containerBSDNames, [disk.bsdName], "plain partition scheme: unmount the physical whole")
    }

    func testRootVolumeIsInternalAndNeverListed() throws {
        let root = try XCTUnwrap(topo(forVolume: "/"))
        XCTAssertTrue(root.isInternal)
        XCTAssertEqual(root.interconnectLocation, "Internal")
        XCTAssertEqual(root.wholeAncestors, [root.bsdName])
        XCTAssertFalse(root.isVirtual)
        XCTAssertTrue(root.volumes.contains { $0.isRootFileSystem })
        XCTAssertFalse(DiskTopology.externalVolumes().contains { $0.path == "/" })
    }

    func testBundleParsing() {
        let chrome = HolderResolver.bundleURLs(forExecutable:
            "/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Versions/1/Helpers/Google Chrome Helper (Renderer).app/Contents/MacOS/Google Chrome Helper (Renderer)")
        XCTAssertEqual(chrome.outermostApp?.path, "/Applications/Google Chrome.app")
        XCTAssertEqual(chrome.innermost?.lastPathComponent, "Google Chrome Helper (Renderer).app")
        let tail = HolderResolver.bundleURLs(forExecutable: "/usr/bin/tail")
        XCTAssertNil(tail.outermostApp)
        XCTAssertNil(tail.innermost)
    }

    func testResolverKinds() throws {
        // Root-owned launchd: other uid -> inaccessible, named via proc_pidpath (proc_name is EPERM on root pids).
        let launchd = try XCTUnwrap(HolderResolver.holder(forPID: 1))
        XCTAssertEqual(launchd.kind, .inaccessible)
        XCTAssertEqual(launchd.displayName, "launchd")
        XCTAssertFalse(launchd.isQuittable)
        // Our own test runner: same uid, not an app -> cli (or helper when run inside Xcode's bundle).
        let me = try XCTUnwrap(HolderResolver.holder(forPID: getpid()))
        XCTAssertEqual(me.uid, getuid())
        XCTAssertTrue([.cli, .helper, .app].contains(me.kind))
        XCTAssertTrue(me.isSameProcess())
        // Finder is a regular app.
        if let finder = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == "com.apple.finder" }) {
            let h = try XCTUnwrap(HolderResolver.holder(forPID: finder.processIdentifier))
            XCTAssertEqual(h.kind, .app)
            XCTAssertEqual(h.bundleIdentifier, "com.apple.finder")
        }
    }

    /// Read-only: a real external disk (a USB SSD, say) is external by its IOKit interconnect location, has exactly
    /// one member disk, and passes S5 only under the app's real-disk policy. Nothing is sent to it.
    func testRealExternalDiskByInterconnectLocation() throws {
        guard let disk = DiskTopology.externalVolumes().filter({ !$0.isNetwork })
            .compactMap({ topo(forVolume: $0.path) }).first(where: { !$0.isVirtual }) else {
            throw XCTSkip("no real external disk mounted")
        }
        XCTAssertEqual(disk.interconnectLocation, "External")
        XCTAssertFalse(disk.isInternal)
        XCTAssertEqual(disk.wholeAncestors, [disk.bsdName])
        XCTAssertFalse(disk.isMultiMember)
        XCTAssertEqual(Ejector.safetyCheck(disk, policy: .diskImagesOnly), .notADiskImage(bsdName: disk.bsdName, model: disk.deviceModel))
        XCTAssertNil(Ejector.safetyCheck(disk, policy: .externalDisks))
    }

    func testInternalRule() {
        XCTAssertFalse(DiskTopology.isInternal(location: "External", deviceInternal: true, isVirtual: false),
                       "Thunderbolt enclosures / readers reporting DADeviceInternal but located External")
        XCTAssertTrue(DiskTopology.isInternal(location: "Internal", deviceInternal: false, isVirtual: false))
        XCTAssertFalse(DiskTopology.isInternal(location: nil, deviceInternal: false, isVirtual: false), "fallback: DADeviceInternal")
        XCTAssertTrue(DiskTopology.isInternal(location: nil, deviceInternal: true, isVirtual: false))
        XCTAssertTrue(DiskTopology.isInternal(location: nil, deviceInternal: nil, isVirtual: false), "nothing known: fail safe")
        XCTAssertTrue(DiskTopology.isInternal(location: "File", deviceInternal: nil, isVirtual: false), "unknown location: fail safe")
        XCTAssertFalse(DiskTopology.isInternal(location: "File", deviceInternal: nil, isVirtual: true), "disk images")
    }

    func testMountedFromParsing() {
        XCTAssertEqual(DiskTopology.bsdName(mountedFrom: "/dev/disk9s1"), "disk9s1")
        XCTAssertEqual(DiskTopology.bsdName(mountedFrom: "/dev/disk3s1s1"), "disk3s1s1")
        XCTAssertEqual(DiskTopology.bsdName(mountedFrom: "com.apple.TimeMachine.2026-10-21-120000.backup@/dev/disk9s1"), "disk9s1",
                       "snapshot / Time Machine mounts belong to their disk (S5/S8/scan)")
        XCTAssertNil(DiskTopology.bsdName(mountedFrom: "//user@nas.local/Share"))
        XCTAssertNil(DiskTopology.bsdName(mountedFrom: "map auto_home"))
        XCTAssertNil(DiskTopology.bsdName(mountedFrom: "/dev/disk9s1/../x"))
    }

    /// The menu list comes from the mount table: only /Volumes/NAME, browsable, never the root or system volumes.
    func testExternalVolumesFromMountTable() {
        let ext = DiskTopology.externalVolumes()
        for v in ext {
            XCTAssertTrue(v.isDirectlyUnderVolumes, v.path)
            XCTAssertTrue(v.isBrowsable, v.path)
            XCTAssertFalse(v.isRootFileSystem || v.isSystemVolume, v.path)
            XCTAssertTrue(v.isNetwork ? v.bsdName == nil : v.bsdName != nil, v.path)
        }
        XCTAssertFalse(ext.contains { $0.path == "/Volumes/Macintosh HD" })
        if let nas = ext.first(where: \.isNetwork) {             // read-only lookup in the mount table, never stat'ed
            XCTAssertEqual(DiskTopology.mountedVolume(atPath: nas.path)?.isNetwork, true)
        }
        XCTAssertNil(DiskTopology.mountedVolume(atPath: "/Volumes/DUTEST_NOT_MOUNTED"))
        XCTAssertFalse(DiskTopology.isMountPoint("/Volumes/Macintosh HD"), "a symlink to / is not a mount point")
    }

    func testSystemStateParsers() {
        XCTAssertEqual(SystemState.parseTimeMachineRunning("{\n    ClientID = \"com.apple.backupd\";\n    Running = 1;\n}"), true)
        XCTAssertEqual(SystemState.parseTimeMachineRunning("Backup session status:\n{\n    Running = 0;\n}"), false)
        XCTAssertNil(SystemState.parseTimeMachineRunning("tmutil: something else"), "unparsable = unknown")
        XCTAssertNil(SystemState.parseTimeMachineRunning("{ Running = maybe; }"))
        XCTAssertEqual(SystemState.parseDestinations(Data("<plist version=\"1.0\"><dict/></plist>".utf8))?.count, 0, "none configured")
        XCTAssertNil(SystemState.parseDestinations(Data("garbage".utf8)))
        XCTAssertEqual(SystemState.parseSpotlight("/Volumes/X:\n\tIndexing enabled. \n"), true)
        XCTAssertEqual(SystemState.parseSpotlight("/Volumes/X:\n\tIndexing disabled.\n"), false)
        XCTAssertNil(SystemState.parseSpotlight("Error: unknown volume"))
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>Destinations</key><array>
        <dict><key>ID</key><string>ABC</string><key>Kind</key><string>Local</string><key>Name</key><string>TM</string></dict>
        </array></dict></plist>
        """
        let d = SystemState.parseDestinations(Data(plist.utf8)) ?? []
        XCTAssertEqual(d.map(\.id), ["ABC"])
        XCTAssertEqual(d.first?.kind, "Local")
        XCTAssertNil(d.first?.volumeUUID)
    }
}
