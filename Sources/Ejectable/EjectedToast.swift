import AppKit
import EjectKit

/// "Ejected NAME" (or "NAME unmounted — safe to disconnect") flashed in the status item for a few seconds (no
/// notification permission needed), with the S10 reminder when a known video editor is still running.
@MainActor
final class EjectedToast {
    private weak var button: NSStatusBarButton?
    private var timer: Timer?
    /// Debug: called with the title each time it changes ("" when cleared).
    var onChange: ((String) -> Void)?

    init(statusItem: NSStatusItem) { button = statusItem.button }

    /// "Ejected EXAMPLE_SSD · Premiere Pro still running" (S10; first running editor, see `Remedies.ejectedToastText`).
    static func text(base: String, editors: [String]) -> String {
        Remedies.ejectedToastText(base: base, runningEditors: editors)
    }

    /// Restored when the toast clears ("Ejectable — 2 drives").
    var idleToolTip = "Ejectable"

    /// `base`: "Ejected NAME", "NAME unmounted — safe to disconnect", "Disconnected NAME", "NAME disconnected".
    /// `editorReminder`: add the S10 "· Premiere Pro still running" (only after a successful eject / unmount).
    func show(_ base: String, name: String, editorReminder: Bool = true, seconds: TimeInterval = 4) {
        let editors = editorReminder ? Remedies.runningEditorNames() : []
        let title = Self.text(base: base, editors: editors)
        guard let button else { return }
        button.imagePosition = .imageLeading
        button.title = " " + title
        button.toolTip = editors.isEmpty ? title
            : "\(title). If it had a project on \(name), it will report media offline until the drive is back."
            + (editors.count > 1 ? " Also running: \(editors.dropFirst().joined(separator: ", "))." : "")
        ActionLog.shared.record("ui", "status item: \(title)")
        onChange?(title)
        timer?.invalidate()
        let t = Timer(timeInterval: seconds, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.clear() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func clear() {
        timer?.invalidate()
        timer = nil
        button?.title = ""
        button?.imagePosition = .imageOnly
        button?.toolTip = idleToolTip
        onChange?("")
    }
}
