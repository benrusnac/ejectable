import AppKit
import EjectKit

/// One holder in the in-use alert: 32 px icon, name (+ orange "writing" tag), one or two lines of why, and the
/// row's action button (Quit / Stop / Force Quit / Force Stop / Kill / Settings…).
///
/// While the row waits for a quit / stop ("Quitting… (59s)" + spinner), its force action is a second, smaller button
/// (Force Quit / Force Stop / Kill, with a tooltip saying what it costs) revealed while the pointer is over the row or
/// keyboard focus reaches it (Tab). When the grace passes the flow makes that action the row's own button. `ForceReveal`
/// (EjectKit) decides what is drawn; this view only feeds it pointer and focus events.
@MainActor
final class HolderRowView: NSView {
    static let width: CGFloat = 420

    let pid: pid_t
    var onAction: ((pid_t, EjectFlow.RowAction) -> Void)?

    private let iconView = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let writingTag = TagView(text: "writing")
    private let detailLabel = NSTextField(wrappingLabelWithString: "")
    private let button = NSButton(title: "", target: nil, action: nil)
    private var action: EjectFlow.RowAction = .none
    /// The hover / Tab-revealed force button and the spinner shown while the row waits.
    private let forceButton = RevealButton(title: "", target: nil, action: nil)
    private let spinner = NSProgressIndicator()
    private var forceAction: EjectFlow.RowAction?
    private(set) var reveal = ForceReveal()
    private var tracking: NSTrackingArea?

    /// On a multi-volume disk, rows also name the volume ("a.txt (open) on Media").
    private let showVolume: Bool

    init(row: EjectFlow.Row, showVolume: Bool = false) {
        pid = row.holder.pid
        self.showVolume = showVolume
        super.init(frame: NSRect(x: 0, y: 0, width: Self.width, height: 44))
        translatesAutoresizingMaskIntoConstraints = false

        iconView.image = Self.icon(for: row.holder)
        iconView.imageScaling = .scaleProportionallyUpOrDown
        nameLabel.font = .systemFont(ofSize: NSFont.systemFontSize)
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        detailLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.maximumNumberOfLines = 5
        detailLabel.lineBreakMode = .byWordWrapping
        detailLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        button.bezelStyle = .push
        button.controlSize = .small
        button.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        button.target = self
        button.action = #selector(clicked(_:))
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        forceButton.bezelStyle = .push
        forceButton.controlSize = .mini
        forceButton.font = .systemFont(ofSize: NSFont.systemFontSize(for: .mini))
        forceButton.hasDestructiveAction = true
        forceButton.target = self
        forceButton.action = #selector(forceClicked(_:))
        forceButton.isHidden = true
        forceButton.setContentHuggingPriority(.required, for: .horizontal)
        forceButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        forceButton.onFocusChange = { [weak self] focused in
            guard let self else { return }
            self.reveal.focusChanged(focused)
            self.applyReveal()
        }
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.isHidden = true
        spinner.setAccessibilityLabel("Waiting")

        let nameLine = NSStackView(views: [nameLabel, writingTag])
        nameLine.orientation = .horizontal
        nameLine.spacing = 6
        nameLine.alignment = .centerY
        let text = NSStackView(views: [nameLine, detailLabel])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 1

        // Hidden controls take no space (NSStackView detaches them): idle rows look exactly as before.
        let controls = NSStackView(views: [forceButton, spinner, button])
        controls.orientation = .horizontal
        controls.spacing = 6
        controls.alignment = .centerY
        controls.setContentHuggingPriority(.required, for: .horizontal)
        controls.setContentCompressionResistancePriority(.required, for: .horizontal)
        self.controls = controls

        for v in [iconView, text, controls] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Self.width),
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 32),
            iconView.heightAnchor.constraint(equalToConstant: 32),
            text.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 10),
            text.topAnchor.constraint(equalTo: topAnchor, constant: 3),
            text.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3),
            text.trailingAnchor.constraint(lessThanOrEqualTo: controls.leadingAnchor, constant: -10),
            text.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            controls.trailingAnchor.constraint(equalTo: trailingAnchor),
            controls.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(greaterThanOrEqualToConstant: 38),
        ])
        update(row)
    }

    private var controls: NSStackView?

    required init?(coder: NSCoder) { fatalError("not used") }

    func update(_ row: EjectFlow.Row) {
        let h = row.holder
        nameLabel.stringValue = Self.title(for: row)
        writingTag.isHidden = !h.isWriter
        let (detail, warn) = Self.detail(for: row, showVolume: showVolume)
        detailLabel.stringValue = detail
        detailLabel.textColor = warn ? .systemOrange : .secondaryLabelColor
        action = row.action
        if let title = row.actionTitle {
            button.isHidden = false
            button.title = title
            button.isEnabled = row.actionEnabled
            button.hasDestructiveAction = row.action == .forceQuit || row.action == .kill
            button.toolTip = (row.action == .forceQuit || row.action == .kill) ? row.forceToolTip : nil
        } else {
            button.isHidden = true
        }

        // While waiting: spinner + countdown on the button, and the force action one hover / Tab away.
        if row.status.isWaiting { spinner.isHidden = false; spinner.startAnimation(nil) }
        else { spinner.stopAnimation(nil); spinner.isHidden = true }
        forceAction = row.secondaryAction
        if let title = row.secondaryTitle {
            forceButton.title = title
            forceButton.toolTip = row.secondaryToolTip
            forceButton.setAccessibilityHelp(row.secondaryToolTip)
        }
        let wasPresent = reveal.isPresent
        reveal.update(row)
        if reveal.isPresent && !wasPresent { syncHoverWithPointer() }   // the pointer may already be over the row
        applyReveal()

        // Leave room for the controls ("Open Spotlight Settings" is wide) so text wraps instead of pushing them out.
        let controlsWidth = controls.map { $0.arrangedSubviews.contains { !$0.isHidden } ? ceil($0.fittingSize.width) + 10 : 0 } ?? 0
        detailLabel.preferredMaxLayoutWidth = Self.width - 42 - controlsWidth
        toolTip = Self.tooltip(for: row)
    }

    /// Draws what `reveal` says: absent (hidden, not focusable), present but transparent (keeps its place and its spot
    /// in the key-view loop, so Tab reaches it), or revealed.
    private func applyReveal() {
        if !reveal.isPresent {
            // Never leave keyboard focus on a vanishing force button (a second Space must not land on another row's).
            if let w = window, w.firstResponder === forceButton { w.makeFirstResponder(nil) }
            forceButton.isHidden = true
            forceButton.focusable = false
            return
        }
        forceButton.isHidden = false
        forceButton.focusable = true
        forceButton.alphaValue = reveal.isRevealed ? 1 : 0
        forceButton.setAccessibilityElement(true)
    }

    private func syncHoverWithPointer() {
        guard let w = window else { return }
        let p = convert(w.mouseLocationOutsideOfEventStream, from: nil)
        if bounds.contains(p) { reveal.pointerEntered() } else { reveal.pointerExited() }
    }

    // MARK: Hover

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        // activeAlways: the companion alert floats without the app being active.
        let t = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                               owner: self, userInfo: nil)
        addTrackingArea(t)
        tracking = t
    }

    override func mouseEntered(with event: NSEvent) {
        reveal.pointerEntered()
        applyReveal()
    }

    override func mouseExited(with event: NSEvent) {
        reveal.pointerExited()
        applyReveal()
    }

    // MARK: Debug hooks (`rowpress`, `rowhover`, `rowfocus`, `rowforce <pid>`)

    func pressButton() { if !button.isHidden && button.isEnabled { button.performClick(nil) } }

    /// Simulated pointer enter / exit (same path as the tracking area).
    func simulateHover(_ inside: Bool) {
        if inside { reveal.pointerEntered() } else { reveal.pointerExited() }
        applyReveal()
    }

    /// Programmatic focus onto the force button (refused unless the current event is a Tab key press). False when it is
    /// not present or refused.
    @discardableResult
    func focusForceButton() -> Bool {
        guard reveal.isPresent, let w = window else { return false }
        w.makeFirstResponder(forceButton)
        return w.firstResponder === forceButton
    }

    /// Clicks the force button only when it is revealed (what a user can see and click).
    func pressForceButton() -> Bool {
        guard reveal.isRevealed, !forceButton.isHidden, forceButton.isEnabled else { return false }
        forceButton.performClick(nil)
        return true
    }

    /// The force button's centre in window coordinates (debug `rowclick`), nil when absent.
    var forceButtonCenterInWindow: NSPoint? {
        guard reveal.isPresent, !forceButton.isHidden else { return nil }
        return forceButton.convert(NSPoint(x: forceButton.bounds.midX, y: forceButton.bounds.midY), to: nil)
    }

    var forceButtonState: String {
        guard reveal.isPresent else { return "absent" }
        return "\(forceButton.title) \(reveal.isRevealed ? "revealed" : "present-transparent") "
            + "(hover=\(reveal.isHovering) focus=\(reveal.isFocused) alpha=\(forceButton.alphaValue)) tooltip='\(forceButton.toolTip ?? "-")'"
    }

    var primaryButtonTitle: String { button.isHidden ? "-" : button.title }
    var isSpinning: Bool { !spinner.isHidden }

    @objc private func clicked(_ sender: NSButton) { onAction?(pid, action) }

    @objc private func forceClicked(_ sender: NSButton) {
        guard let forceAction, reveal.isPresent else { return }
        onAction?(pid, forceAction)
    }

    // MARK: Text

    // Words live in EjectKit (EjectFlow.Row.title / detail, RowText.swift) so tests can check them.
    static func title(for row: EjectFlow.Row) -> String { row.title }

    /// (text, isWarning)
    static func detail(for row: EjectFlow.Row, showVolume: Bool = false) -> (String, Bool) { row.detail(showVolume: showVolume) }

    static func describe(_ r: HoldReason) -> String { EjectFlow.Row.describe(r) }

    static func tooltip(for row: EjectFlow.Row) -> String {
        let h = row.holder
        var lines = ["\(h.displayName) \u{2014} pid \(h.pid), \(h.kind.rawValue)"]
        if !h.executablePath.isEmpty { lines.append(h.executablePath) }
        lines += h.reasons.map { "\u{2022} \($0)" }
        return lines.joined(separator: "\n")
    }

    // MARK: Icons (RECON §6)

    static func icon(for h: Holder) -> NSImage {
        let ws = NSWorkspace.shared
        if h.kind == .app || h.kind == .appExtension, let icon = NSRunningApplication(processIdentifier: h.pid)?.icon { return icon }
        if let parent = h.parentAppBundleURL { return ws.icon(forFile: parent.path) }
        if let bundle = h.bundleURL { return ws.icon(forFile: bundle.path) }
        if !h.executablePath.isEmpty { return ws.icon(forFile: h.executablePath) }
        return ws.icon(for: .unixExecutable)
    }
}

/// The revealed force button: reports keyboard focus (Tab reveals it), and is in the key-view loop only while its row
/// offers a force action, independent of the Full Keyboard Access setting (it is the only way to it without a pointer).
@MainActor
final class RevealButton: NSButton {
    var onFocusChange: ((Bool) -> Void)?
    var focusable = false

    override var acceptsFirstResponder: Bool { focusable && !isHidden && isEnabled }
    override var canBecomeKeyView: Bool { focusable && !isHidden && isEnabled }

    override func becomeFirstResponder() -> Bool {
        // Only a Tab / Shift-Tab focuses it (ForceReveal.acceptsFocus): AppKit's own choice of a next responder is refused.
        let e = NSApp.currentEvent
        guard ForceReveal.acceptsFocus(keyDownKeyCode: e?.type == .keyDown ? e?.keyCode : nil) else { return false }
        let ok = super.becomeFirstResponder()
        if ok { onFocusChange?(true) }
        return ok
    }

    override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        if ok { onFocusChange?(false) }
        return ok
    }
}

/// Small rounded orange tag ("writing").
@MainActor
final class TagView: NSView {
    private let label: NSTextField

    init(text: String) {
        label = NSTextField(labelWithString: text)
        super.init(frame: .zero)
        wantsLayer = true
        label.font = .systemFont(ofSize: 10, weight: .semibold)
        label.textColor = .systemOrange
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 5),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -5),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 1),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -1),
        ])
        setContentHuggingPriority(.required, for: .horizontal)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.cornerRadius = 4
        layer?.backgroundColor = NSColor.systemOrange.withAlphaComponent(0.16).cgColor
    }
}
