import AppKit
import Darwin

/// pid -> `Holder` (kind, name, bundles). Thread-safe; called from the scanner's background queue.
public enum HolderResolver {
    /// Same-user processes classified as `.daemon` by name, regardless of location (S4: report, never kill).
    public static let knownDaemonNames: Set<String> = [
        "mds", "mds_stores", "mdworker", "mdworker_shared", "mdsync", "mdbulkimport", "corespotlightd",
        "fseventsd", "backupd", "backupd-helper", "systemmigrationd", "revisiond",
        "photolibraryd", "photoanalysisd", "mediaanalysisd", "AMPLibraryAgent", "AMPDevicesAgent",
        "userfsd", "bztransmit", "bzserv", "bzfilelist", "postgres", "cloudd", "bird", "fileproviderd",
        "diskimagesiod", "storagekitd", "diskarbitrationd", "deleted",
    ]

    /// Same-user launchd children (ppid 1) running from these locations are system agents, not user tools.
    static let systemPrefixes = ["/System/", "/usr/libexec/", "/usr/sbin/", "/sbin/", "/Library/Apple/"]

    /// Describe an arbitrary pid, e.g. the DiskArbitration dissenter (which may be root-owned).
    /// `reasons` is empty when the pid is only known from the dissenter.
    public static func holder(forPID pid: pid_t, reasons: [HoldReason] = [], volumePaths: [String] = []) -> Holder? {
        let path = LibProc.executablePath(pid)
        let info = LibProc.shortInfo(pid)
        let start = LibProc.startTime(pid)
        guard path != nil || info != nil else { return nil }       // process is gone
        return resolve(pid: pid, path: path ?? "", info: info, reasons: reasons, volumePaths: volumePaths, startTime: start)
    }

    /// `startTime`: read when the process was inspected (the scanner) or looked up (`holder(forPID:)`), so the
    /// holder's identity (S6) is that of the process the reasons came from.
    static func resolve(pid: pid_t, path: String, info: LibProc.ShortInfo?, reasons: [HoldReason], volumePaths: [String],
                        startTime start: Double?) -> Holder {
        let uid = info?.uid ?? uid_t.max
        let ppid = info?.ppid ?? 0
        let execName = path.isEmpty ? (info?.comm ?? "pid \(pid)") : (path as NSString).lastPathComponent
        let bundles = bundleURLs(forExecutable: path)

        func make(_ kind: HolderKind, name: String, bundleID: String?, bundle: URL?) -> Holder {
            // Helpers always carry the app to quit; others only when nested inside a different bundle.
            let sameAsOwn = bundles.outermostApp?.standardizedFileURL == bundle?.standardizedFileURL
            let parent = (kind == .helper || !sameAsOwn) ? bundles.outermostApp : nil
            return Holder(pid: pid, uid: uid, ppid: ppid, executablePath: path, startTime: start, displayName: name,
                          bundleIdentifier: bundleID, bundleURL: bundle, parentAppBundleURL: parent, kind: kind,
                          reasons: reasons, volumePaths: volumePaths)
        }

        guard uid == getuid() else {
            return make(.inaccessible, name: execName, bundleID: nil, bundle: bundles.innermost)
        }
        // S4: a known daemon stays a daemon even when it has an NSRunningApplication or lives inside an app bundle
        // (postgres inside Postgres.app or an NLE, photolibraryd, …): it must never become quittable.
        if knownDaemonNames.contains(execName) {
            return make(.daemon, name: execName, bundleID: bundles.innermost.flatMap { Bundle(url: $0)?.bundleIdentifier },
                        bundle: bundles.innermost)
        }
        if let app = NSRunningApplication(processIdentifier: pid) {
            let kind: HolderKind = app.activationPolicy == .prohibited ? .appExtension : .app
            return make(kind, name: app.localizedName ?? execName, bundleID: app.bundleIdentifier,
                        bundle: app.bundleURL ?? bundles.innermost)
        }
        if bundles.outermostApp != nil {
            let ownBundle = bundles.innermost == bundles.outermostApp ? nil : bundles.innermost
            return make(.helper, name: bundleName(ownBundle) ?? execName,
                        bundleID: bundles.innermost.flatMap { Bundle(url: $0)?.bundleIdentifier }, bundle: bundles.innermost)
        }
        let isDaemon = knownDaemonNames.contains(execName)
            || (ppid == 1 && systemPrefixes.contains { path.hasPrefix($0) })
            || path.contains(".xpc/")
        return make(isDaemon ? .daemon : .cli, name: execName,
                    bundleID: bundles.innermost.flatMap { Bundle(url: $0)?.bundleIdentifier }, bundle: bundles.innermost)
    }

    struct Bundles {
        var outermostApp: URL?
        var innermost: URL?
    }

    /// `/Applications/Google Chrome.app/Contents/Frameworks/…/Google Chrome Helper.app/Contents/MacOS/x`
    /// -> outermostApp = Google Chrome.app, innermost = Google Chrome Helper.app.
    static func bundleURLs(forExecutable path: String) -> Bundles {
        guard path.hasPrefix("/") else { return Bundles() }
        var result = Bundles()
        var prefix = ""
        for component in path.split(separator: "/", omittingEmptySubsequences: true).dropLast() {
            prefix += "/" + component
            let ext = (component as NSString).pathExtension.lowercased()
            guard ["app", "appex", "xpc"].contains(ext) else { continue }
            let url = URL(fileURLWithPath: prefix, isDirectory: true)
            if ext == "app", result.outermostApp == nil { result.outermostApp = url }
            result.innermost = url
        }
        return result
    }

    static func bundleName(_ url: URL?) -> String? {
        guard let url else { return nil }
        return ((url.lastPathComponent as NSString).deletingPathExtension).nilIfEmpty
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
