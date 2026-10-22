import AppKit
import EjectKit

/// Runs `body` from a run-loop timer (common modes), never from inside a GCD main-queue block. A modal session
/// started inside a main-queue block would stop the main queue (scan results, DiskArbitration callbacks, Tasks)
/// until it ends, so every modal in the app is started through here or from an event handler.
@MainActor
func onMainRunLoop(after delay: TimeInterval = 0, _ body: @escaping @MainActor @Sendable () -> Void) {
    let t = Timer(timeInterval: delay, repeats: false) { _ in MainActor.assumeIsolated { body() } }
    RunLoop.main.add(t, forMode: .common)
}

/// `stopModal` from a non-event source takes effect on the next event; post one.
@MainActor
func wakeModalLoop() {
    if let e = NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [], timestamp: 0,
                                  windowNumber: 0, context: nil, subtype: 0, data1: 0, data2: 0) {
        NSApp.postEvent(e, atStart: true)
    }
}

/// `"NAME" is in use`: NSAlert styled like Apple's (RECON §6), with one HolderRowView per holder and the buttons
/// Quit All & Eject (default) / Force Eject… (red, never Return) / Cancel. Live-updated from an EjectFlow. A flow that
/// only unmounts one volume says "unmount" everywhere (Quit All & Unmount, Force Unmount…).
///
/// The alert's own buttons are retargeted to this object, so no button click ends the modal session by itself;
/// `dismiss()` does. That makes the same object work modally (`presentModal`, menu ejects) and non-modally
/// (`presentNonModal`, phase 3 Finder-companion mode). Cancel stays enabled while a forced request runs: it then only
/// closes the window (the coordinator keeps the flow until the result).
@MainActor
final class InUseAlert: NSObject {
    enum Presentation { case none, modal, nonModal }

    static let accessoryWidth = HolderRowView.width

    let alert = NSAlert()
    let volumeName: String
    let volumeCount: Int
    /// "eject" or "unmount".
    let verb: String
    private(set) var presentation = Presentation.none

    var onPrimary: (() -> Void)?
    var onForceEject: (() -> Void)?
    var onCancel: (() -> Void)?
    var onRowAction: ((pid_t, EjectFlow.RowAction) -> Void)?
    /// A modal session of ours ended (the alert's own, or a nested confirmation): queued error alerts may show now.
    var onModalEnded: (() -> Void)?
    /// Debug: called after a visible change (screenshots).
    var onVisibleChange: ((String) -> Void)?

    private let content = NSStackView()
    private let rowsStack = NSStackView()
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let footnoteLabel = NSTextField(wrappingLabelWithString: "")
    /// The Force Eject verdict, last line above the buttons: green safe / orange risky / red unavailable (S2).
    private let ratingLabel = NSTextField(wrappingLabelWithString: "")
    private var rowViews: [pid_t: HolderRowView] = [:]
    private var signature = ""
    /// `signature` without the countdown digits: a visible change worth a debug screenshot.
    private var coarseSignature = ""
    private var lastRowCount = -1
    private var dismissed = false
    /// Nested confirmation currently shown (debug hook presses its buttons).
    private(set) var confirmation: NSAlert?
    /// The flow last rendered (the confirmation repeats its Force Eject rating).
    private weak var ratingSource: EjectFlow?

    /// `companion`: floats next to Apple's "wasn't ejected / unmounted" dialog, so the title says what failed.
    init(volumeName: String, volumePath: String, volumeCount: Int, verb: String = "eject", companion: Bool = false) {
        self.volumeName = volumeName
        self.volumeCount = volumeCount
        self.verb = verb
        super.init()
        alert.alertStyle = .warning
        alert.icon = NSWorkspace.shared.icon(forFile: volumePath)
        alert.messageText = companion ? "\u{201C}\(volumeName)\u{201D} couldn\u{2019}t be \(verb)ed"
                                      : "\u{201C}\(volumeName)\u{201D} is in use"
        alert.informativeText = " "

        let primary = alert.addButton(withTitle: "Quit All & \(verb.capitalized)")
        let force = alert.addButton(withTitle: "Force \(verb.capitalized)\u{2026}")
        let cancel = alert.addButton(withTitle: "Cancel")
        primary.keyEquivalent = "\r"
        force.keyEquivalent = ""                        // S2: never reachable by Return
        force.hasDestructiveAction = true
        cancel.keyEquivalent = "\u{1b}"
        for (b, sel) in [(primary, #selector(primaryClicked(_:))), (force, #selector(forceClicked(_:))),
                         (cancel, #selector(cancelClicked(_:)))] {
            b.target = self
            b.action = sel
        }
        primary.isEnabled = false
        force.isEnabled = false

        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 8
        content.translatesAutoresizingMaskIntoConstraints = true
        rowsStack.orientation = .vertical
        rowsStack.alignment = .leading
        rowsStack.spacing = 6
        if volumeCount > 1 && verb == "eject" {         // S8
            let s8 = NSTextField(wrappingLabelWithString: "Ejects all \(volumeCount) volumes on this disk.")
            s8.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
            s8.preferredMaxLayoutWidth = Self.accessoryWidth
            content.addArrangedSubview(s8)
        }
        content.addArrangedSubview(rowsStack)
        for l in [statusLabel, footnoteLabel, ratingLabel] {
            l.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            l.textColor = .secondaryLabelColor
            l.preferredMaxLayoutWidth = Self.accessoryWidth
            content.addArrangedSubview(l)
        }
        ratingLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
        footnoteLabel.isHidden = true
        ratingLabel.isHidden = true
        content.frame = NSRect(x: 0, y: 0, width: Self.accessoryWidth, height: 40)
        alert.accessoryView = content
        // Tab reaches a row's revealed force button (accessory views are not in NSAlert's own key-view loop).
        alert.window.autorecalculatesKeyViewLoop = true
    }

    var window: NSWindow { alert.window }
    var primaryButton: NSButton { alert.buttons[0] }
    var forceButton: NSButton { alert.buttons[1] }
    var cancelButton: NSButton { alert.buttons[2] }

    // MARK: - Live update

    func update(from flow: EjectFlow) {
        ratingSource = flow
        alert.informativeText = flow.summary

        // Rows: keep views for pids still present (no flicker), drop gone ones, add new ones in flow order.
        let wanted = flow.rows.map(\.holder.pid)
        for (pid, view) in rowViews where !wanted.contains(pid) {
            rowsStack.removeArrangedSubview(view)
            view.removeFromSuperview()
            rowViews[pid] = nil
        }
        for (i, row) in flow.rows.enumerated() {
            if let v = rowViews[row.holder.pid] {
                v.update(row)
                if rowsStack.arrangedSubviews.firstIndex(of: v) != i {
                    rowsStack.removeArrangedSubview(v)
                    rowsStack.insertArrangedSubview(v, at: min(i, rowsStack.arrangedSubviews.count))
                }
            } else {
                let v = HolderRowView(row: row, showVolume: volumeCount > 1)
                v.onAction = { [weak self] pid, action in self?.onRowAction?(pid, action) }
                rowViews[row.holder.pid] = v
                rowsStack.insertArrangedSubview(v, at: min(i, rowsStack.arrangedSubviews.count))
            }
        }
        rowsStack.isHidden = flow.rows.isEmpty

        // Buttons (S1/S2/S3).
        let busy = flow.state == .forcing || flow.state.isFinished
        switch flow.primaryButton {
        case .quitAll(let enabled):
            primaryButton.title = "Quit All & \(verb.capitalized)"
            primaryButton.isEnabled = enabled && !busy
        case .retry(let enabled):
            primaryButton.title = "Try Again"
            primaryButton.isEnabled = enabled && !busy
        }
        forceButton.isEnabled = flow.canForceEject && !busy
        // Enabled while forcing too: a stalled flush or forced request must never leave a window that can't be closed.
        cancelButton.isEnabled = !flow.state.isFinished

        statusLabel.stringValue = flow.statusText
        var notes: [String] = []
        // One sentence when the same writer keeps both Quit All and Force Eject off.
        let sameWriter = flow.quitAllBlockingRow.map { r in r.holder.isWriter && flow.blockers.contains { $0.pid == r.holder.pid } } ?? false
        if let hint = flow.quitAllHint, !sameWriter { notes.append("Quit All is unavailable: \(hint)") }
        if let denied = flow.deniedFooter { notes.append(denied) }
        footnoteLabel.stringValue = notes.joined(separator: "\n")
        footnoteLabel.isHidden = notes.isEmpty

        let (rating, color) = Self.ratingLine(flow, sameWriter: sameWriter)
        ratingLabel.stringValue = rating
        ratingLabel.textColor = color
        ratingLabel.isHidden = rating.isEmpty

        relayoutIfNeeded(flow)
    }

    /// The Force Eject line: red while blocked (button disabled), orange when risky, green when safe. Empty while the
    /// force eject itself runs or the flow has finished.
    static func ratingLine(_ flow: EjectFlow, sameWriter: Bool = false) -> (String, NSColor) {
        guard flow.state != .forcing, !flow.state.isFinished else { return ("", .secondaryLabelColor) }
        let rating = flow.forceRating
        switch rating {
        case .blocked(let blockers) where sameWriter:
            return ("Quit All and Force \(flow.verb.capitalized) are unavailable while \(blockers.map(\.message).joined(separator: "; ")). "
                    + "Stop it with its own button first.", .systemRed)
        case .blocked: return (rating.text(verb: flow.verb), .systemRed)
        case .risky: return (rating.text(verb: flow.verb), .systemOrange)
        case .safe: return (rating.text(verb: flow.verb), .systemGreen)
        }
    }

    /// Resize the accessory and re-run NSAlert layout only when something visible changed (the window then
    /// resizes top-pinned, RECON §6).
    private func relayoutIfNeeded(_ flow: EjectFlow) {
        let sig = [alert.informativeText, primaryButton.title, "\(primaryButton.isEnabled)", "\(forceButton.isEnabled)",
                   statusLabel.stringValue, footnoteLabel.stringValue, ratingLabel.stringValue]
            .joined(separator: "|") + flow.rows.map {
                "\($0.holder.pid):\(HolderRowView.detail(for: $0).0):\($0.actionTitle ?? ""):\($0.secondaryTitle ?? "")"
            }.joined()
        guard sig != signature else { return }
        let rowsChanged = flow.rows.count != lastRowCount
        lastRowCount = flow.rows.count
        signature = sig
        let coarse = sig.replacingOccurrences(of: #"\(\d+s\)"#, with: "", options: .regularExpression)
        let visible = coarse != coarseSignature
        coarseSignature = coarse
        content.layoutSubtreeIfNeeded()
        let height = ceil(content.fittingSize.height)
        if abs(content.frame.height - height) > 0.5 || content.frame.width != Self.accessoryWidth {
            content.setFrameSize(NSSize(width: Self.accessoryWidth, height: height))
        }
        alert.layout()
        if visible { onVisibleChange?(rowsChanged ? "rows\(flow.rows.count)" : "update") }   // not every countdown second
    }

    // MARK: - Presentation

    /// The alert's own modal session or a nested confirmation is running (no other modal may start on top).
    var isRunningModal: Bool { presentation == .modal || confirmation != nil }
    var isDismissed: Bool { dismissed }

    /// Runs the alert app-modally until `dismiss()`. Call only from an event handler or `onMainRunLoop`.
    func presentModal() {
        guard presentation == .none, !dismissed else { return }
        presentation = .modal
        alert.layout()
        NSApp.activate()
        _ = alert.runModal()                            // returns when dismiss() calls stopModal
        presentation = .none
        alert.window.orderOut(nil)
        onModalEnded?()
    }

    /// Finder-companion mode: floating, not modal, does not activate the app (no focus steal). Buttons already
    /// target this object. Placed below the screen centre, where Apple's own "not ejected" dialog sits.
    func presentNonModal() {
        guard presentation == .none, !dismissed else { return }
        presentation = .nonModal
        alert.layout()
        let w = alert.window
        w.level = .floating
        w.hidesOnDeactivate = false                     // NSPanel default would hide it while we are inactive
        w.collectionBehavior.insert(.canJoinAllSpaces)
        if let vf = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame {
            let origin = NSPoint(x: vf.midX - w.frame.width / 2, y: max(vf.minY + 24, vf.midY - w.frame.height - 120))
            w.setFrameOrigin(origin)
        } else {
            w.center()
        }
        w.makeKeyAndOrderFront(nil)
    }

    func bringToFront() {
        NSApp.activate()
        alert.window.makeKeyAndOrderFront(nil)
    }

    func dismiss() {
        guard !dismissed else { return }
        dismissed = true
        if confirmation != nil {
            // A nested confirmation (Force…, Stop writer) is the current modal session, whatever our own presentation:
            // stop it. For a modal alert its caller then sees `dismissed` and ends ours too (see runNested).
            NSApp.stopModal(withCode: .cancel)
            wakeModalLoop()
            if presentation == .nonModal { alert.window.orderOut(nil); presentation = .none }
            return
        }
        switch presentation {
        case .modal:
            NSApp.stopModal(withCode: .cancel)
            wakeModalLoop()
        case .nonModal:
            alert.window.orderOut(nil)
            presentation = .none
        case .none:
            break
        }
    }

    // MARK: - Buttons

    @objc private func primaryClicked(_ sender: NSButton) { onPrimary?() }
    @objc private func forceClicked(_ sender: NSButton) { onForceEject?() }
    @objc private func cancelClicked(_ sender: NSButton) { onCancel?() }

    func row(pid: pid_t) -> HolderRowView? { rowViews[pid] }

    // MARK: - Nested confirmations

    /// S2 confirmation: every holder with its file and state, the risks, and a red "Force Eject" (volume mode: "Force
    /// Unmount") that is not the default button: Cancel is, and has the initial focus. Returns true only if the user
    /// pressed Force Eject.
    func runForceConfirmation(_ c: ForceEjectConfirmation) -> Bool {
        let v: String = if case .unmountVolume = c.mode { "unmount" } else { "eject" }
        let a = NSAlert()
        a.alertStyle = .critical
        a.icon = alert.icon
        a.messageText = "Force \(v) \u{201C}\(c.diskName)\u{201D}?"
        a.informativeText = c.holders.isEmpty
            ? "Something Ejectable can\u{2019}t see is using it. It loses access immediately."
            : "These lose access immediately. Files they have open can show errors or go offline."
        var lines: [(String, NSColor)] = []
        if let flow = ratingSource {
            let (rating, color) = Self.ratingLine(flow)
            if !rating.isEmpty { lines.append((rating, color)) }
        }
        if let note = ratingSource?.note, note.contains("changed") { lines.insert((note, .systemOrange), at: 0) }
        if volumeCount > 1 && v == "eject" { lines.append(("Ejects all \(volumeCount) volumes on this disk.", .labelColor)) }
        for h in c.holders {
            let what = h.reasons.isEmpty ? "reported by macOS" : h.reasons.map(HolderRowView.describe).joined(separator: ", ")
            lines.append(("\u{2022} \(h.displayName): \(what)", .secondaryLabelColor))
        }
        for r in c.risks where r.kind != .openFile {
            lines.append(("\u{26A0}\u{FE0E} \(r.message)", .systemOrange))
        }
        a.accessoryView = Self.lines(lines)
        let force = a.addButton(withTitle: "Force \(v.capitalized)")
        let cancel = a.addButton(withTitle: "Cancel")
        force.hasDestructiveAction = true
        force.keyEquivalent = ""                        // S2: never the default button, never Return
        cancel.keyEquivalent = "\r"                     // Return (and Escape, by title) = Cancel
        return runNested(a, label: "force-confirm", focus: cancel) == .alertFirstButtonReturn
    }

    /// S3: stopping a CLI holder that writes to the drive needs a confirmation.
    func confirmStopWriter(_ row: EjectFlow.Row) -> Bool {
        let h = row.holder
        let file = h.reasons.first(where: \.isWrite).map { ($0.path as NSString).lastPathComponent } ?? "a file"
        let a = NSAlert()
        a.alertStyle = .warning
        a.icon = HolderRowView.icon(for: h)
        a.messageText = "Stop \u{201C}\(h.displayName)\u{201D}?"
        a.informativeText = "It is writing \u{201C}\(file)\u{201D} on \u{201C}\(volumeName)\u{201D}. "
            + "Stopping it now can leave that file incomplete."
        let stop = a.addButton(withTitle: "Stop")
        let cancel = a.addButton(withTitle: "Cancel")
        stop.hasDestructiveAction = true
        stop.keyEquivalent = ""
        cancel.keyEquivalent = "\r"
        return runNested(a, label: "stop-writer", focus: cancel) == .alertFirstButtonReturn
    }

    /// A nested confirmation, app-modal. `focus` (Cancel) is the initial first responder, so with Full Keyboard Access
    /// Space presses Cancel, never the destructive button.
    private func runNested(_ a: NSAlert, label: String, focus: NSButton) -> NSApplication.ModalResponse {
        guard !dismissed else { return .cancel }
        confirmation = a
        a.layout()
        // NSAlert's layout assigns key equivalents itself; set ours afterwards: Return = Cancel, nothing on the rest.
        for b in a.buttons where b !== focus { b.keyEquivalent = "" }
        focus.keyEquivalent = "\r"
        a.window.initialFirstResponder = focus
        onVisibleChange?(label)
        let r = a.runModal()
        confirmation = nil
        defer { onModalEnded?() }
        if dismissed {                                  // dismissed while the confirmation was up
            if presentation == .modal {
                NSApp.stopModal(withCode: .cancel)
                wakeModalLoop()
            }
            return .cancel
        }
        return r
    }

    static func lines(_ lines: [(String, NSColor)]) -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 3
        for (text, color) in lines {
            let l = NSTextField(wrappingLabelWithString: text)
            l.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            l.textColor = color
            l.preferredMaxLayoutWidth = accessoryWidth
            stack.addArrangedSubview(l)
        }
        stack.layoutSubtreeIfNeeded()
        stack.frame = NSRect(x: 0, y: 0, width: accessoryWidth, height: ceil(stack.fittingSize.height))
        return stack
    }
}
