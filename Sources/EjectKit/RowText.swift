import Foundation

/// The words of one holder row in the in-use alert (the app's HolderRowView draws them). Pure, so tests can check them.
extension EjectFlow.Row {
    /// "Premiere Pro" · "Spotlight (mdworker_shared)" for a same-user daemon · "Spotlight" for a root process.
    public var title: String {
        let h = holder
        switch h.kind {
        case .daemon: return remedy.label.map { "\($0) (\(h.displayName))" } ?? h.displayName
        case .inaccessible: return remedy.label ?? h.displayName
        default: return h.displayName
        }
    }

    /// (text, isWarning): what it holds, then the remedy's explanation; or the quit/stop progress.
    public func detail(showVolume: Bool = false) -> (String, Bool) {
        switch status {
        case .quitting:
            // The countdown is on the button ("Quitting… (59s)"); the force button is one hover / Tab away.
            switch holder.kind {
            case .appExtension: return ("Waiting for it to quit\u{2026}", false)
            case .helper:
                let app = Remedies.parentName(holder).map { "\($0) " } ?? "its app "
                return ("Waiting for \(app)to quit\u{2026} it may be asking to save changes.", false)
            default: return ("Waiting for it to quit\u{2026} it may be asking to save changes.", false)
            }
        case .forceQuitting:
            return (holder.kind == .appExtension ? "Force stopping\u{2026}" : "Force quitting\u{2026}", false)
        case .quitTimedOut:
            if action != .forceQuit {                  // Finder: never force-quit, it relaunches after a normal quit
                return ("Didn\u{2019}t quit yet. Click Quit to ask again.", true)
            }
            if holder.kind == .appExtension {          // extensions rarely hold a document and rarely answer terminate()
                return ("\(title) doesn\u{2019}t respond to Quit. Force Stop ends it; extensions rarely hold unsaved work.", true)
            }
            return ("Didn\u{2019}t quit. Force Quit: unsaved changes will be lost.", true)
        case .stopping:
            if action == .kill {                       // its grace has passed: Kill is the row's button
                return ("Didn\u{2019}t stop. Click Kill to stop it immediately.", true)
            }
            return ("Asked it to stop\u{2026}", false)
        case .note(let s):
            return (s, true)
        case .idle:
            break
        }
        var first = reasonText
        if showVolume, !holder.volumePaths.isEmpty {
            first += " on " + holder.volumePaths.map { ($0 as NSString).lastPathComponent }.joined(separator: ", ")
        }
        var lines = [first]
        if let e = remedy.explanation { lines.append(e) }
        return (lines.joined(separator: "\n"), false)
    }

    /// What this row's force action costs, for its tooltip (primary or revealed): "Unsaved changes in X will be lost",
    /// "Force Stop ends X immediately. Extensions rarely hold unsaved work.", "Stops X immediately; a copy or encode in progress will be incomplete".
    public var forceToolTip: String { EjectFlow.forceButton(for: holder).toolTip }

    /// "clip.mov (open) +2 more" · "System process mds_stores (525) is using it" · "macOS reports it is using the disk".
    public var reasonText: String {
        let reasons = holder.reasons
        guard let first = reasons.first else {
            if holder.kind == .inaccessible { return "System process \(holder.displayName) (\(holder.pid)) is using it" }
            return isDissenterOnly ? "macOS reports it is using the disk" : "using the disk"
        }
        let more = reasons.count > 1 ? " +\(reasons.count - 1) more" : ""
        return Self.describe(first) + more
    }

    public static func describe(_ r: HoldReason) -> String {
        let file = (r.path as NSString).lastPathComponent
        return switch r {
        case .openFile(_, true): "\(file) (open for writing)"
        case .openFile(_, false): "\(file) (open)"
        case .mappedFile(_, true): "\(file) (mapped for writing)"
        case .mappedFile(_, false): "\(file) (media mapped in memory)"
        case .workingDirectory: "working directory"
        case .rootDirectory: "root directory"
        }
    }
}

extension EjectFlow {
    /// "1,204 system processes can't be inspected without admin rights." Nil when there are none.
    public var deniedFooter: String? {
        guard deniedProcessCount > 0 else { return nil }
        let n = deniedProcessCount.formatted()
        return "\(n) system \(deniedProcessCount == 1 ? "process" : "processes") can\u{2019}t be inspected without admin rights."
    }
}
