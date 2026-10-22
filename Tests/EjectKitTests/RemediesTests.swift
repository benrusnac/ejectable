import AppKit
import EjectKit
import XCTest

final class RemediesTests: XCTestCase {
    private func r(_ exe: String, bundle: String? = nil, kind: HolderKind = .daemon, reasons: [HoldReason] = [],
                   parent: String? = nil, parentBundle: String? = nil, path: String = "") -> Remedy {
        Remedies.remedy(bundleIdentifier: bundle, executableName: exe, kind: kind, reasons: reasons,
                        parentAppName: parent, parentBundleIdentifier: parentBundle, executablePath: path)
    }

    func testAirDropIsKeyedByBundleID() {
        // parentAppBundleURL is nil for AirDrop.appex (it lives in FinderKit.framework): the bundle id is the key.
        let air = r("AirDrop", bundle: "com.apple.share.AirDrop.send", kind: .appExtension)
        XCTAssertEqual(air.action, .closeShareSheet)
        XCTAssertEqual(air.buttonTitle, "Stop")
        XCTAssertTrue(air.explanation?.contains("Close the share sheet") ?? false)
        XCTAssertFalse(air.neverTerminate)
        // Other share extensions get the same remedy through the com.apple.share. prefix.
        let mail = r("ShareKitHelper", bundle: "com.apple.share.Mail.compose", kind: .appExtension)
        XCTAssertEqual(mail.action, .closeShareSheet)
        XCTAssertEqual(mail.label, "Share sheet")
    }

    // MARK: Lookup precedence: own bundle id (exact > longest prefix) > executable > parent bundle id > shell > kind

    func testLookupPrecedence() {
        // 1 beats 2: the exact AirDrop entry, not the generic com.apple.share. prefix.
        XCTAssertEqual(r("x", bundle: "com.apple.share.AirDrop.send").label, "AirDrop share sheet")
        // 2: longest prefix wins, case-insensitive.
        XCTAssertEqual(r("x", bundle: "com.adobe.LightroomClassicCC7", kind: .app).label, "Lightroom Classic")
        XCTAssertEqual(r("x", bundle: "com.adobe.lightroomCC", kind: .app).label, "Lightroom")
        XCTAssertEqual(r("x", bundle: "com.adobe.Photoshop", kind: .app).explanation,
                       "An Adobe app. Quit it normally so it can finish writing.")
        XCTAssertEqual(r("x", bundle: "com.avid.MediaComposer", kind: .app).label, "Media Composer")
        // 2 beats 3: a bundle id wins over the executable name.
        XCTAssertEqual(r("mds", bundle: "com.adobe.PremierePro.25", kind: .app).label, "Premiere Pro")
        // 3 beats 4: the executable wins over the parent app (postgres inside Resolve is never quit itself).
        let pg = r("postgres", kind: .daemon, parent: "DaVinci Resolve", parentBundle: "com.blackmagic-design.DaVinciResolve")
        XCTAssertEqual(pg.label, "DaVinci Resolve database")
        XCTAssertTrue(pg.neverTerminate)
        XCTAssertEqual(pg.quitAppBundleID, "com.blackmagic-design.DaVinciResolve")
        XCTAssertEqual(pg.explanation, "Resolve\u{2019}s database/cache is on this drive. Quit Resolve.")
        let otherPG = r("postgres", kind: .daemon, path: "/Applications/Postgres.app/Contents/Versions/16/bin/postgres")
        XCTAssertEqual(otherPG.label, "PostgreSQL database")
        XCTAssertTrue(otherPG.neverTerminate)
        XCTAssertEqual(otherPG.action, .none)
        // 4: a helper with no entry of its own takes its parent app's remedy.
        let helper = r("Adobe Premiere Pro Helper", bundle: "com.adobe.dynamiclinkmanager.helper", kind: .helper,
                       parent: "Adobe Premiere Pro 2025", parentBundle: "com.adobe.PremierePro.25")
        XCTAssertEqual(helper.explanation, "An Adobe app. Quit it normally so it can finish writing.", "own bundle id first")
        let plainHelper = r("Renderer", kind: .helper, parent: "Adobe Premiere Pro 2025", parentBundle: "com.adobe.PremierePro.25")
        XCTAssertEqual(plainHelper.label, "Premiere Pro")
        XCTAssertTrue(plainHelper.isEditor)
        // 4 beats 6: parent bundle before the kind default.
        XCTAssertEqual(r("Something", kind: .helper, parent: "Final Cut Pro", parentBundle: "com.apple.FinalCut").label, "Final Cut Pro")
        // 5: a shell in a folder on the drive, never stopped; with an open file it is an ordinary CLI holder (6).
        XCTAssertEqual(r("zsh", kind: .cli, reasons: [.workingDirectory(path: "/Volumes/X")]).action, .none)
        XCTAssertEqual(r("zsh", kind: .cli, reasons: [.openFile(path: "/Volumes/X/a", writing: false)]).action, .stop)
        // 6: kind last.
        XCTAssertEqual(r("unknownd", kind: .daemon).action, .waitAndRetry)
        XCTAssertEqual(r("unknownd", kind: .cli).action, .stop)
    }

    func testRECONTable() {
        // Spotlight: never killed, opens Spotlight settings.
        for exe in ["mds", "mds_stores", "mdworker", "mdworker_shared"] {
            let s = r(exe, kind: .inaccessible)
            XCTAssertEqual(s.action, .openSpotlightSettings, exe)
            XCTAssertTrue(s.neverTerminate, exe)
            XCTAssertEqual(s.label, "Spotlight")
            XCTAssertTrue(s.explanation?.contains("Privacy list") ?? false)
        }
        // Finder: the user closes the window; no button.
        let finder = r("Finder", bundle: "com.apple.finder", kind: .app)
        XCTAssertEqual(finder.action, .none)
        XCTAssertEqual(finder.explanation, "A Finder window is showing this drive. Close it.")
        // Quick Look family: stop.
        for exe in ["QuickLookUIService", "QuickLookSatellite", "QLPreviewGenerationExtension",
                    "com.apple.quicklook.ThumbnailsAgent", "quicklookd"] {
            let q = r(exe)
            XCTAssertEqual(q.action, .stop, exe)
            XCTAssertFalse(q.neverTerminate, exe)
            XCTAssertEqual(q.explanation, "Quick Look is holding a preview. Safe to stop; it restarts on its own.")
        }
        // Time Machine.
        for exe in ["backupd", "backupd-helper", "systemmigrationd"] {
            XCTAssertEqual(r(exe, kind: .inaccessible).action, .openTimeMachine, exe)
            XCTAssertTrue(r(exe).neverTerminate, exe)
            XCTAssertEqual(r(exe).explanation, "Time Machine is backing up. Wait for it to finish or stop the backup.")
        }
        XCTAssertEqual(r("fseventsd", kind: .inaccessible).action, .waitAndRetry)
        XCTAssertEqual(r("fseventsd").explanation, "macOS is still flushing file events. Try again in a few seconds.")
        XCTAssertTrue(r("fseventsd").neverTerminate)
        // Photos helpers: quit Photos, never the helper.
        for exe in ["photolibraryd", "photoanalysisd", "mediaanalysisd"] {
            let p = r(exe)
            XCTAssertEqual(p.action, .quit, exe)
            XCTAssertEqual(p.quitAppBundleID, "com.apple.Photos", exe)
            XCTAssertTrue(p.neverTerminate, exe)
        }
        // Music / AMP agents.
        for exe in ["AMPLibraryAgent", "AMPDevicesAgent"] {
            XCTAssertEqual(r(exe).quitAppBundleID, "com.apple.Music", exe)
            XCTAssertTrue(r(exe).neverTerminate, exe)
        }
        // Adobe.
        for (id, name, editor) in [("com.adobe.PremierePro.25", "Premiere Pro", true),
                                   ("com.adobe.AfterEffects.application", "After Effects", true),
                                   ("com.adobe.ame.application.25", "Media Encoder", true),
                                   ("com.adobe.bridge14", "Bridge", false),
                                   ("com.adobe.acc.AdobeCreativeCloud", "Creative Cloud", false)] {
            let a = r("x", bundle: id, kind: .app)
            XCTAssertEqual(a.label, name, id)
            XCTAssertEqual(a.action, .quit, id)
            XCTAssertEqual(a.isEditor, editor, id)
            XCTAssertEqual(a.explanation, "Quit \(name) normally so it can finish writing.", id)
        }
        for exe in ["CCXProcess", "Adobe Desktop Service", "Creative Cloud"] {
            XCTAssertEqual(r(exe, kind: .helper).action, .quit, exe)
        }
        // Resolve, Final Cut family, Avid.
        let resolve = r("Resolve", bundle: "com.blackmagic-design.DaVinciResolveLite", kind: .app)
        XCTAssertEqual(resolve.label, "DaVinci Resolve")
        XCTAssertTrue(resolve.isEditor)
        for (id, name) in [("com.apple.FinalCut", "Final Cut Pro"), ("com.apple.FinalCutTrial", "Final Cut Pro"),
                           ("com.apple.Compressor", "Compressor"), ("com.apple.motionapp", "Motion")] {
            let e = r("x", bundle: id, kind: .app)
            XCTAssertEqual(e.label, name, id)
            XCTAssertTrue(e.isEditor, id)
            XCTAssertTrue(e.explanation?.contains("background tasks finish") ?? false, id)
        }
        XCTAssertTrue(r("x", bundle: "com.avid.mediacomposer", kind: .app).isEditor)
        // Backup / sync / antivirus.
        let bz = r("bztransmit", kind: .inaccessible)
        XCTAssertEqual(bz.explanation, "Backblaze is scanning this drive. Pause it from its menu-bar icon.")
        XCTAssertTrue(bz.neverTerminate)
        XCTAssertEqual(r("Dropbox", bundle: "com.getdropbox.dropbox", kind: .app).label, "Dropbox")
        XCTAssertEqual(r("Google Drive", bundle: "com.google.drivefs", kind: .app).label, "Google Drive")
        XCTAssertTrue(r("com.bombich.ccchelper", kind: .inaccessible).neverTerminate)
        for exe in ["BDLDaemon", "virusbarriers"] { XCTAssertTrue(r(exe, kind: .inaccessible).neverTerminate, exe) }
        // Terminals.
        for id in ["com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp-Stable"] {
            XCTAssertEqual(r("x", bundle: id, kind: .app).explanation,
                           "A terminal window is inside this drive. Run `cd ~` or close the tab.", id)
        }
        // VMs, players.
        XCTAssertTrue(r("prl_vm_app", kind: .helper).explanation?.contains("virtual machine") ?? false)
        XCTAssertTrue(r("x", bundle: "com.docker.docker", kind: .app).explanation?.contains("containers") ?? false)
        XCTAssertTrue(r("vmware-vmx", kind: .helper).explanation?.contains("virtual machine") ?? false)
        for id in ["org.videolan.vlc", "com.apple.QuickTimePlayerX", "com.colliderli.iina"] {
            XCTAssertEqual(r("x", bundle: id, kind: .app).action, .quit, id)
        }
    }

    func testSettingsLinks() {
        XCTAssertEqual(Remedies.settingsURL(for: .openSpotlightSettings)?.scheme, "x-apple.systempreferences")
        XCTAssertEqual(Remedies.settingsURL(for: .openTimeMachine)?.scheme, "x-apple.systempreferences")
        XCTAssertNil(Remedies.settingsURL(for: .quit))
        XCTAssertEqual(Remedies.settingsButtonTitle(for: .openSpotlightSettings), "Open Spotlight Settings")
        XCTAssertEqual(Remedies.settingsButtonTitle(for: .openTimeMachine), "Open Time Machine")
    }

    // MARK: S10

    func testEditorsAndToastText() {
        XCTAssertEqual(Remedies.editorName(bundleIdentifier: "com.adobe.PremierePro.25"), "Premiere Pro")
        XCTAssertEqual(Remedies.editorName(bundleIdentifier: "com.adobe.ame.application.25"), "Media Encoder")
        XCTAssertEqual(Remedies.editorName(bundleIdentifier: "com.blackmagic-design.DaVinciResolve"), "DaVinci Resolve")
        XCTAssertEqual(Remedies.editorName(bundleIdentifier: "com.apple.FinalCut"), "Final Cut Pro")
        XCTAssertNil(Remedies.editorName(bundleIdentifier: "com.apple.Safari"))
        XCTAssertNil(Remedies.editorName(bundleIdentifier: "com.adobe.acc.AdobeCreativeCloud"), "always running: no reminder")
        XCTAssertEqual(Remedies.editorNames(bundleIdentifiers: ["com.apple.Safari", "com.adobe.PremierePro.dutest",
                                                                "com.apple.FinalCut", "com.adobe.PremierePro.25"]),
                       ["Premiere Pro", "Final Cut Pro"])
        XCTAssertEqual(Remedies.ejectedToastText(base: "Ejected EXAMPLE_SSD", runningEditors: []), "Ejected EXAMPLE_SSD")
        XCTAssertEqual(Remedies.ejectedToastText(base: "Ejected EXAMPLE_SSD", runningEditors: ["Premiere Pro", "Final Cut Pro"]),
                       "Ejected EXAMPLE_SSD \u{00B7} Premiere Pro still running")
        XCTAssertEqual(Remedies.ejectedToastText(base: "X unmounted \u{2014} safe to disconnect", runningEditors: ["DaVinci Resolve"]),
                       "X unmounted \u{2014} safe to disconnect \u{00B7} DaVinci Resolve still running")
    }

    /// S10 with a real running app whose bundle id is faked to look like Premiere (DUFakeEditor.app, built from the
    /// test holder; not an NLE). Only that app, by the pid we launched, is ever terminated.
    @MainActor
    func testRunningFakeEditorIsNamedInTheToast() async throws {
        let url = try TestApp.fakeEditorURL()
        let config = NSWorkspace.OpenConfiguration()
        config.activates = false
        config.createsNewApplicationInstance = true
        config.addsToRecentItems = false
        let app = try await NSWorkspace.shared.openApplication(at: url, configuration: config)
        defer {
            if app.bundleIdentifier == "com.adobe.PremierePro.dutest", !app.isTerminated { app.forceTerminate() }
            TestApp.unregisterFromLaunchServices(url)       // leave no fake "Premiere" bundle id registered
        }
        XCTAssertEqual(app.bundleIdentifier, "com.adobe.PremierePro.dutest")
        XCTAssertEqual(Remedies.runningEditorNames(in: [app]), ["Premiere Pro"], "matched by its (fake) bundle id")
        try await waitUntil(5) { Remedies.runningEditorNames().contains("Premiere Pro") }
        XCTAssertEqual(Remedies.ejectedToastText(base: "Ejected DUTEST", runningEditors: Remedies.runningEditorNames()),
                       "Ejected DUTEST \u{00B7} Premiere Pro still running")
        app.forceTerminate()
        try await waitUntil(5) { app.isTerminated }
        XCTAssertFalse(Remedies.runningEditorNames(in: [app]).contains("Premiere Pro"), "terminated apps are ignored")
    }

    @MainActor
    func testRunningEditorsNoneInEmptyList() {
        XCTAssertEqual(Remedies.runningEditorNames(in: []), [])
        XCTAssertFalse(Remedies.runningEditorNames().contains("Finder"))
    }

    func testDefaultsByKind() {
        XCTAssertEqual(r("Preview", bundle: "com.apple.Preview", kind: .app).action, .quit)
        XCTAssertEqual(r("Foo", kind: .appExtension).action, .quit)
        XCTAssertEqual(r("Foo Helper", kind: .helper).action, .quit)
        XCTAssertEqual(r("tail", kind: .cli).action, .stop)
        XCTAssertEqual(r("somed", kind: .daemon).action, .waitAndRetry)
        XCTAssertEqual(r("rootd", kind: .inaccessible).action, .waitAndRetry)
        let helper = Remedies.remedy(bundleIdentifier: nil, executableName: "Google Chrome Helper", kind: .helper,
                                     reasons: [], parentAppName: "Google Chrome")
        XCTAssertEqual(helper.explanation, "Part of Google Chrome. Quitting Google Chrome releases the drive.")
    }
}
