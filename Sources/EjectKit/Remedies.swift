import AppKit
import Foundation

/// What to tell the user about a holder and what the row's button should do. Plain value.
public struct Remedy: Sendable, Hashable {
    public enum Action: String, Sendable, Hashable {
        /// Graceful quit (`NSRunningApplication.terminate()`; the parent app for helpers, `quitAppBundleID` for daemons).
        case quit
        /// Stop: SIGTERM for same-user CLI tools and Quick Look daemons (S4 exception); terminate() for app extensions.
        case stop
        /// Finder's AirDrop/share sheet extension. The user closes the sheet; the row can also Stop it (terminate(),
        /// 3 s grace) and then Force Stop it (app extensions rarely hold unsaved work and rarely answer terminate()).
        case closeShareSheet
        case openSpotlightSettings
        case openTimeMachine
        /// Nothing to act on; it usually lets go by itself. Auto-retry covers it.
        case waitAndRetry
        /// The user does it (close a Finder window, `cd ~`); no button.
        case none
    }

    /// Plain-words name of what this is ("Spotlight", "Premiere Pro"). Nil = use the holder's own name.
    public let label: String?
    /// One sentence: why it holds the drive and what to do. Nil = the row shows only the hold reason.
    public let explanation: String?
    public let action: Action
    /// Row button title override ("Stop" for the AirDrop sheet / Quick Look); nil = default for the action.
    public let buttonTitle: String?
    /// A video editor (S10: reminded at eject time because it may still have a project on the drive).
    public let isEditor: Bool
    /// The app to quit instead of the holder itself (Photos helpers -> Photos). Matched exactly (case-insensitive), or as
    /// a prefix only when the rest starts with "." or the app's name is `quitAppName` ("com.blackmagic-design.
    /// DaVinciResolve" finds DaVinciResolveLite, named "DaVinci Resolve", but not the Project Server). Nil = the holder.
    public let quitAppBundleID: String?
    /// The display name of `quitAppBundleID`'s app ("DaVinci Resolve"), for the prefix rule above.
    public let quitAppName: String?
    /// Never signal or quit this, even if its kind would allow it (S4: Spotlight, Time Machine, fseventsd, postgres…).
    public let neverTerminate: Bool

    public init(label: String? = nil, explanation: String? = nil, action: Action, buttonTitle: String? = nil,
                isEditor: Bool = false, quitAppBundleID: String? = nil, quitAppName: String? = nil, neverTerminate: Bool = false) {
        self.label = label; self.explanation = explanation; self.action = action; self.buttonTitle = buttonTitle
        self.isEditor = isEditor; self.quitAppBundleID = quitAppBundleID; self.quitAppName = quitAppName
        self.neverTerminate = neverTerminate
    }
}

/// Knowledge table (RECON §7): bundle id / executable name -> Remedy.
///
/// Lookup precedence (first hit wins):
///  1. the holder's own bundle id, exact
///  2. the holder's own bundle id, longest matching prefix (case-insensitive)
///  3. the executable's basename, exact (`postgres` is resolved with its parent app)
///  4. the parent app's bundle id, exact then prefix (a helper inside Premiere is "Premiere Pro")
///  5. a shell whose only hold is its working directory (a terminal tab inside the drive)
///  6. a default by kind
public enum Remedies {
    // MARK: Shared remedies

    static let spotlight = Remedy(
        label: "Spotlight",
        explanation: "Spotlight is indexing this drive. It usually finishes in a minute or two. "
            + "To stop it for good, add the drive to Spotlight\u{2019}s Privacy list.",
        action: .openSpotlightSettings, neverTerminate: true)

    static let quickLook = Remedy(
        label: "Quick Look",
        explanation: "Quick Look is holding a preview. Safe to stop; it restarts on its own.",
        action: .stop, buttonTitle: "Stop")

    static let timeMachine = Remedy(
        label: "Time Machine",
        explanation: "Time Machine is backing up. Wait for it to finish or stop the backup.",
        action: .openTimeMachine, neverTerminate: true)

    static let fileEvents = Remedy(
        label: "File events log",
        explanation: "macOS is still flushing file events. Try again in a few seconds.",
        action: .waitAndRetry, neverTerminate: true)

    static let shareSheet = Remedy(
        label: "Share sheet",
        explanation: "Finder\u{2019}s share sheet still has these files open. Close the share sheet, or Force Stop it.",
        action: .closeShareSheet, buttonTitle: "Stop")

    static let terminal = "A terminal window is inside this drive. Run `cd ~` or close the tab."

    static let photosHelper = Remedy(
        label: "Photos",
        explanation: "Photos is using a library on this drive. Quit Photos.",
        action: .quit, quitAppBundleID: "com.apple.Photos", quitAppName: "Photos", neverTerminate: true)

    static let musicHelper = Remedy(
        label: "Music",
        explanation: "Music is using a library on this drive. Quit Music.",
        action: .quit, quitAppBundleID: "com.apple.Music", quitAppName: "Music", neverTerminate: true)

    static let backblaze = Remedy(
        label: "Backblaze",
        explanation: "Backblaze is scanning this drive. Pause it from its menu-bar icon.",
        action: .waitAndRetry, neverTerminate: true)

    static let ccc = Remedy(
        label: "Carbon Copy Cloner",
        explanation: "Carbon Copy Cloner is copying to or from this drive. Let the task finish or stop it in CCC.",
        action: .none, neverTerminate: true)

    static let antivirus = Remedy(
        label: "Antivirus scan",
        explanation: "An antivirus scanner is checking new files on this drive. It usually finishes in a minute or two.",
        action: .waitAndRetry, neverTerminate: true)

    static let cloudSync = Remedy(
        label: "iCloud / File Provider",
        explanation: "A sync service is reading this drive. It usually lets go on its own; Ejectable retries.",
        action: .waitAndRetry, neverTerminate: true)

    /// Login-session processes (S3/S4): shown with an explanation, never quit, never in Quit All, whatever their kind.
    static func sessionProcess(_ name: String) -> Remedy {
        Remedy(label: name,
               explanation: "\(name) is part of macOS and can\u{2019}t be quit. It usually lets go on its own; Ejectable retries.",
               action: .none, neverTerminate: true)
    }

    /// Ejectable's own bundle id. Its own process is never quit or signalled.
    public static let ownBundleID = "com.benrusnac.ejectable"

    static let ownProcess = Remedy(
        label: "Ejectable",
        explanation: "Ejectable itself; it can\u{2019}t be quit from here. It lets go when this alert closes.",
        action: .none, neverTerminate: true)

    /// Bundle ids of the login session's own processes: never quit, never signalled (Terminator refuses them too).
    /// Finder is not here: it may be quit normally (it relaunches), but is never force-quit.
    public static let sessionProcessBundleIDs: Set<String> = Set(sessionProcessNames.keys)

    static let sessionProcessNames: [String: String] = [
        "com.apple.loginwindow": "Login window",
        "com.apple.dock": "Dock",
        "com.apple.systemuiserver": "SystemUIServer",
        "com.apple.controlcenter": "Control Center",
        "com.apple.WindowManager": "Window Manager",
        "com.apple.notificationcenterui": "Notification Center",
        "com.apple.Spotlight": "Spotlight",
        "com.apple.UserNotificationCenter": "Notifications",
    ]

    static let resolveText = "Resolve\u{2019}s database/cache is on this drive. Quit Resolve."
    static let resolveBundle = "com.blackmagic-design.DaVinciResolve"

    /// "Quit X normally so it can finish writing." (Adobe and other media apps).
    static func quitNormally(_ name: String, editor: Bool = false) -> Remedy {
        Remedy(label: name, explanation: "Quit \(name) normally so it can finish writing.", action: .quit, isEditor: editor)
    }

    static func appleEditor(_ name: String, library: Bool) -> Remedy {
        Remedy(label: name,
               explanation: library ? "Let \(name)\u{2019}s background tasks finish, close the library, then quit."
                                    : "Let \(name)\u{2019}s background tasks finish, then quit.",
               action: .quit, isEditor: true)
    }

    static func player(_ name: String) -> Remedy {
        Remedy(label: name, explanation: "\(name) is playing a file from this drive. Quit it.", action: .quit)
    }

    static func sync(_ name: String) -> Remedy {
        Remedy(label: name, explanation: "\(name) is syncing or scanning this drive. Pause it from its menu-bar icon, or quit it.",
               action: .quit)
    }

    static func vm(_ name: String, what: String) -> Remedy {
        Remedy(label: name, explanation: "\(name) has \(what) using this drive. Shut \(what == "containers" ? "them" : "it") down, then quit \(name).",
               action: .quit)
    }

    // MARK: Tables

    static let byBundleID: [String: Remedy] = sessionProcessNames.mapValues(sessionProcess).merging([
        "com.apple.finder": Remedy(label: "Finder", explanation: "A Finder window is showing this drive. Close it.", action: .none),
        "com.apple.share.AirDrop.send": Remedy(
            label: "AirDrop share sheet",
            explanation: "Finder\u{2019}s share sheet still has these files open. Close the share sheet, or Force Stop it.",
            action: .closeShareSheet, buttonTitle: "Stop"),
        "com.apple.quicklook.QuickLookUIService": quickLook,
        "com.apple.quicklook.QuickLookSatellite": quickLook,
        "com.apple.QuickLookUIFramework.QLPreviewGenerationExtension": quickLook,
        "com.apple.quicklook.ThumbnailsAgent": quickLook,
        "com.apple.Photos": Remedy(label: "Photos", explanation: "Photos is using a library on this drive. Quit Photos.", action: .quit),
        "com.apple.Music": Remedy(label: "Music", explanation: "Music is using a library on this drive. Quit Music.", action: .quit),
        "com.apple.TV": Remedy(label: "TV", explanation: "TV is using a library on this drive. Quit TV.", action: .quit),
        "com.apple.motionapp": appleEditor("Motion", library: false),
        "com.apple.Terminal": Remedy(label: "Terminal", explanation: terminal, action: .quit),
        "com.googlecode.iterm2": Remedy(label: "iTerm", explanation: terminal, action: .quit),
        "com.mitchellh.ghostty": Remedy(label: "Ghostty", explanation: terminal, action: .quit),
        "net.kovidgoyal.kitty": Remedy(label: "kitty", explanation: terminal, action: .quit),
        "org.alacritty": Remedy(label: "Alacritty", explanation: terminal, action: .quit),
        "com.apple.QuickTimePlayerX": player("QuickTime Player"),
        "org.videolan.vlc": player("VLC"),
        "com.colliderli.iina": player("IINA"),
        "com.getdropbox.dropbox": sync("Dropbox"),
        "com.google.drivefs": sync("Google Drive"),
        "com.docker.docker": vm("Docker", what: "containers"),
        "com.vmware.fusion": vm("VMware Fusion", what: "a virtual machine"),
        "com.parallels.desktop.console": vm("Parallels Desktop", what: "a virtual machine"),
        ownBundleID: ownProcess,
    ]) { session, _ in session }

    static let byBundleIDLowercased: [String: Remedy] = Dictionary(byBundleID.map { ($0.key.lowercased(), $0.value) }) { a, _ in a }

    /// Bundle id prefixes, case-insensitive. The longest matching prefix wins.
    static let byBundlePrefix: [(prefix: String, remedy: Remedy)] = [
        ("com.apple.share.", shareSheet),
        ("com.adobe.PremierePro", quitNormally("Premiere Pro", editor: true)),
        ("com.adobe.AfterEffects", quitNormally("After Effects", editor: true)),
        ("com.adobe.ame", quitNormally("Media Encoder", editor: true)),
        ("com.adobe.bridge", quitNormally("Bridge")),
        ("com.adobe.lightroom", quitNormally("Lightroom")),
        ("com.adobe.LightroomClassic", quitNormally("Lightroom Classic")),
        ("com.adobe.acc.AdobeCreativeCloud", quitNormally("Creative Cloud")),
        ("com.adobe.acc.AdobeDesktopService", quitNormally("Adobe Desktop Service")),
        ("com.adobe.CCXProcess", quitNormally("Creative Cloud")),
        ("com.adobe.", Remedy(explanation: "An Adobe app. Quit it normally so it can finish writing.", action: .quit)),
        (resolveBundle, Remedy(label: "DaVinci Resolve", explanation: resolveText, action: .quit, isEditor: true)),
        ("com.apple.FinalCut", appleEditor("Final Cut Pro", library: true)),
        ("com.apple.Compressor", appleEditor("Compressor", library: false)),
        ("com.avid.mediacomposer", quitNormally("Media Composer", editor: true)),
        ("dev.warp.Warp", Remedy(label: "Warp", explanation: terminal, action: .quit)),
        ("com.parallels.", vm("Parallels Desktop", what: "a virtual machine")),
        ("com.docker.", vm("Docker", what: "containers")),
        ("com.vmware.", vm("VMware Fusion", what: "a virtual machine")),
        ("com.backblaze.", backblaze),
        ("com.bombich.", ccc),
    ]

    static let byExecutable: [String: Remedy] = {
        var t: [String: Remedy] = [:]
        for n in ["mds", "mds_stores", "mdworker", "mdworker_shared", "mdsync", "mdbulkimport", "corespotlightd"] { t[n] = spotlight }
        for n in quickLookExecutables { t[n] = quickLook }
        for n in ["ImageThumbnailExtension", "AudiovisualThumbnailExtension"] { t[n] = quickLook }   // .appex: terminate()
        for n in ["backupd", "backupd-helper", "systemmigrationd"] { t[n] = timeMachine }
        t["revisiond"] = Remedy(
            label: "Document versions",
            explanation: "macOS is saving document versions on this drive. It lets go on its own; Ejectable retries.",
            action: .waitAndRetry, neverTerminate: true)
        t["fseventsd"] = fileEvents
        for n in ["photolibraryd", "photoanalysisd", "mediaanalysisd", "cloudphotod"] { t[n] = photosHelper }
        // AMP* are the Apple Media Platform agents behind Music / TV (library, device sync, artwork).
        for n in ["AMPLibraryAgent", "AMPDevicesAgent", "AMPArtworkAgent"] { t[n] = musicHelper }
        for n in ["CCXProcess", "Creative Cloud", "Adobe Desktop Service", "Core Sync", "AdobeIPCBroker", "Adobe Crash Processor"] {
            t[n] = quitNormally(n == "CCXProcess" ? "Creative Cloud" : n)
        }
        for n in ["bztransmit", "bzserv", "bzfilelist", "bzbmenu"] { t[n] = backblaze }
        for n in ["com.bombich.ccchelper", "ccchelper"] { t[n] = ccc }
        for n in ["BDLDaemon", "virusbarriers", "VirusBarrier", "VirusBarrier Scanner", "SophosScanD", "RTProtectionDaemon",
                  "wdavdaemon", "com.avast.daemon"] { t[n] = antivirus }
        for n in ["cloudd", "bird", "fileproviderd"] { t[n] = cloudSync }
        t["Dropbox"] = sync("Dropbox")
        t["Google Drive"] = sync("Google Drive")
        for n in ["prl_vm_app", "prl_client_app"] { t[n] = vm("Parallels Desktop", what: "a virtual machine") }
        for n in ["com.docker.backend", "com.docker.virtualization", "Docker Desktop"] { t[n] = vm("Docker", what: "containers") }
        t["vmware-vmx"] = vm("VMware Fusion", what: "a virtual machine")
        t["userfsd"] = Remedy(
            label: "File system service",
            explanation: "macOS\u{2019}s file system service for this drive. It lets go when the drive unmounts.",
            action: .waitAndRetry, neverTerminate: true)
        // `postgres` is resolved in `remedy(...)` (Resolve's database or another app's).
        return t
    }()

    /// S4 exception: Quick Look processes may be stopped even when classified `.daemon` (read-only, launchd respawns
    /// them). Exact executable names; `Terminator` enforces the same list.
    public static let quickLookExecutables: Set<String> = [
        "QuickLookUIService", "QuickLookSatellite", "QLPreviewGenerationExtension",
        "com.apple.quicklook.ThumbnailsAgent", "quicklookd",
    ]

    /// Shells: a terminal tab whose working directory is on the drive.
    static let shells: Set<String> = ["zsh", "bash", "sh", "fish", "tcsh", "csh", "ksh", "dash", "login", "-zsh", "-bash", "nu"]

    // MARK: Lookup

    public static func remedy(for h: Holder) -> Remedy {
        if h.pid == getpid() { return ownProcess }
        return remedy(bundleIdentifier: h.bundleIdentifier,
               executableName: (h.executablePath as NSString).lastPathComponent.nilIfEmpty ?? h.displayName,
               displayName: h.displayName, kind: h.kind, reasons: h.reasons, parentAppName: parentName(h),
               parentBundleIdentifier: parentBundleID(h), executablePath: h.executablePath)
    }

    public static func remedy(bundleIdentifier: String?, executableName: String, displayName: String = "",
                              kind: HolderKind, reasons: [HoldReason], parentAppName: String? = nil,
                              parentBundleIdentifier: String? = nil, executablePath: String = "") -> Remedy {
        // 1-2. own bundle id
        if let id = bundleIdentifier, let r = lookup(bundleIdentifier: id) { return r }
        // 3. executable
        if executableName == "postgres" { return postgres(parentAppName: parentAppName, path: executablePath) }
        if let r = byExecutable[executableName] { return r }
        // 4. parent app (helpers, XPC services, extensions inside an app)
        if let id = parentBundleIdentifier, let r = lookup(bundleIdentifier: id) { return r }
        // 5. a shell sitting in a folder on the drive: never SIGTERM the user's shell
        if shells.contains(executableName), !reasons.isEmpty,
           reasons.allSatisfy({ if case .workingDirectory = $0 { true } else { false } }) {
            return Remedy(label: "Terminal", explanation: terminal, action: .none)
        }
        // 6. kind
        switch kind {
        case .app: return Remedy(action: .quit)
        case .appExtension: return Remedy(action: .quit)
        case .helper:
            return Remedy(explanation: parentAppName.map { "Part of \($0). Quitting \($0) releases the drive." },
                          action: .quit)
        case .cli: return Remedy(action: .stop)
        case .daemon:
            return Remedy(explanation: "Background process. It usually lets go on its own; Ejectable retries.",
                          action: .waitAndRetry)
        case .inaccessible:
            return Remedy(explanation: "Wait a moment; Ejectable retries. If it doesn\u{2019}t let go, Force Eject is the last resort.",
                          action: .waitAndRetry)
        }
    }

    /// Which running app a remedy's `quitAppBundleID` names (see `Remedy.quitAppBundleID`): an exact bundle id first
    /// (case-insensitive); otherwise the first whose id continues the remedy's id with "." or whose name is the remedy's
    /// app name. A bare prefix never matches (com.apple.Music must not find com.apple.MusicRecognitionMac).
    public static func remedyAppIndex(quitAppBundleID: String, quitAppName: String?,
                                      candidates: [(bundleID: String?, name: String?)]) -> Int? {
        let want = quitAppBundleID.lowercased()
        if let i = candidates.firstIndex(where: { $0.bundleID?.lowercased() == want }) { return i }
        return candidates.firstIndex { c in
            guard let id = c.bundleID?.lowercased(), id.hasPrefix(want) else { return false }
            return id.dropFirst(want.count).hasPrefix(".") || (quitAppName != nil && c.name == quitAppName)
        }
    }

    /// Exact bundle id, then the longest matching prefix (case-insensitive).
    static func lookup(bundleIdentifier id: String) -> Remedy? {
        if let r = byBundleID[id] ?? byBundleIDLowercased[id.lowercased()] { return r }
        let lower = id.lowercased()
        return byBundlePrefix
            .filter { lower.hasPrefix($0.prefix.lowercased()) }
            .max { $0.prefix.count < $1.prefix.count }?.remedy
    }

    /// `postgres` is never killed. Inside DaVinci Resolve (or with "Resolve" in its path) the remedy is to quit
    /// Resolve; otherwise it is some other app's database server.
    static func postgres(parentAppName: String?, path: String) -> Remedy {
        if (parentAppName ?? "").localizedCaseInsensitiveContains("Resolve") || path.localizedCaseInsensitiveContains("Resolve") {
            return Remedy(label: "DaVinci Resolve database", explanation: resolveText, action: .quit,
                          quitAppBundleID: resolveBundle, quitAppName: "DaVinci Resolve", neverTerminate: true)
        }
        return Remedy(label: "PostgreSQL database",
                      explanation: "A database server keeps its data on this drive. Stop it from its app (Postgres.app, "
                          + "Resolve Project Server); never kill it.",
                      action: .none, neverTerminate: true)
    }

    static func parentName(_ h: Holder) -> String? {
        h.parentAppBundleURL.map { ($0.lastPathComponent as NSString).deletingPathExtension }
    }

    /// The parent app's bundle id (Bundle caches its Info.plist).
    static func parentBundleID(_ h: Holder) -> String? {
        h.parentAppBundleURL.flatMap { Bundle(url: $0)?.bundleIdentifier }
    }

    // MARK: Editors (S10)

    /// Editor name for a bundle id ("Premiere Pro"), or nil unless its remedy is an editor's.
    public static func editorName(bundleIdentifier id: String) -> String? {
        guard let r = lookup(bundleIdentifier: id), r.isEditor else { return nil }
        return r.label
    }

    /// Known editors among these bundle ids, de-duplicated, in the order given.
    public static func editorNames(bundleIdentifiers ids: [String]) -> [String] {
        var seen = Set<String>()
        return ids.compactMap(editorName(bundleIdentifier:)).filter { seen.insert($0).inserted }
    }

    /// Known editors currently running (S10).
    @MainActor public static func runningEditorNames(in apps: [NSRunningApplication] = NSWorkspace.shared.runningApplications) -> [String] {
        editorNames(bundleIdentifiers: apps.filter { !$0.isTerminated }.compactMap(\.bundleIdentifier))
    }

    /// S10 status-item confirmation: "Ejected EXAMPLE_SSD · Premiere Pro still running" (first editor only).
    public static func ejectedToastText(base: String, runningEditors editors: [String]) -> String {
        guard let first = editors.first else { return base }
        return "\(base) \u{00B7} \(first) still running"
    }

    // MARK: Settings links

    /// System Settings deep links for the settings actions. Verified on macOS 26.6 with `open` (see README);
    /// `settingsRoot` is the fallback when one does not open.
    public static func settingsURL(for action: Remedy.Action) -> URL? {
        switch action {
        case .openSpotlightSettings: URL(string: spotlightSettingsURL)
        case .openTimeMachine: URL(string: timeMachineSettingsURL)
        default: nil
        }
    }

    public static let spotlightSettingsURL = "x-apple.systempreferences:com.apple.Spotlight-Settings.extension"
    public static let timeMachineSettingsURL = "x-apple.systempreferences:com.apple.Time-Machine-Settings.extension"
    public static let settingsRoot = URL(fileURLWithPath: "/System/Applications/System Settings.app")

    /// Row button title for an action that opens settings.
    public static func settingsButtonTitle(for action: Remedy.Action) -> String? {
        switch action {
        case .openSpotlightSettings: "Open Spotlight Settings"
        case .openTimeMachine: "Open Time Machine"
        default: nil
        }
    }
}
