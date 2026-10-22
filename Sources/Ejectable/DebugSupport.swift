#if DEBUG
import AppKit
import CoreGraphics
import EjectKit

/// Debug-only hooks, compiled into DEBUG builds only (release builds contain none of this: no --eject, no SIGUSR1
/// source, no command file), and enabled by launch arguments AND the environment variable EJECTABLE_DEBUG=1
/// (main.swift refuses the flags without it):
///
///     --eject <volumePath> [--real]   run the menu's eject path for that volume. Disk images only unless --real.
///     --screens <dir>                 save PNGs of our own windows as they change (CGWindowListCreateImage via dlsym:
///                                     own windows need no Screen Recording permission; `screencapture` is unavailable)
///     --debug-hooks                   on SIGUSR1, run the commands in <dir>/cmd, one per line:
///                                     press <button title> | rowpress <pid> | rowhover <pid> [out] | rowfocus <pid> |
///                                     rowforce <pid> | rowclick <pid> | tab [shift] | snap <label> | state | menu |
///                                     menusnap | quit
@MainActor
final class DebugSupport {
    struct Options {
        var ejectPath: String?
        var allowReal = false
        var screensDir: URL?
        var hooks = false

        var isEmpty: Bool { ejectPath == nil && screensDir == nil && !hooks }

        static func parse(_ args: [String]) -> Options {
            var o = Options()
            var i = 1
            while i < args.count {
                switch args[i] {
                case "--eject" where i + 1 < args.count: o.ejectPath = args[i + 1]; i += 1
                case "--screens" where i + 1 < args.count: o.screensDir = URL(fileURLWithPath: args[i + 1], isDirectory: true); i += 1
                case "--real": o.allowReal = true
                case "--debug-hooks": o.hooks = true
                default: break
                }
                i += 1
            }
            return o
        }
    }

    let options: Options
    private weak var coordinator: EjectCoordinator?
    private weak var menuController: StatusMenuController?
    private var counter = 0
    private var signalSource: DispatchSourceSignal?

    init(options: Options, coordinator: EjectCoordinator, menuController: StatusMenuController) {
        self.options = options
        self.coordinator = coordinator
        self.menuController = menuController
        if let dir = options.screensDir {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        // Status item content is drawn out of process on macOS 26 (window capture and cacheDisplay both come back
        // empty), so the toast is verified by reading the button's title back.
        menuController.toast.onChange = { [weak menuController] title in
            Self.say("TOAST \(title.isEmpty ? "(cleared)" : title)")
            onMainRunLoop(after: 0.2) {
                let shown = menuController?.statusItem.button?.title ?? "-"
                Self.say("STATUS button title now '\(shown)'")
            }
        }
        if options.hooks { installSignalHook() }
    }

    static func say(_ s: String) { FileHandle.standardError.write(Data("DEBUG \(s)\n".utf8)) }

    // MARK: --eject

    /// Uses the monitor's snapshot like the menu does (no topology lookups on the main thread); waits up to 5 s for
    /// the first snapshot after launch.
    func runEject(attempt: Int = 0) {
        guard let path = options.ejectPath, let coordinator else { return }
        guard let entry = coordinator.monitor.entry(forPath: path), let disk = entry.disk, !entry.volume.isNetwork else {
            if attempt < 25 { onMainRunLoop(after: 0.2) { [weak self] in self?.runEject(attempt: attempt + 1) }; return }
            return Self.say("--eject \(path): not a mounted local volume")
        }
        // Same guard as ejectctl: development ejects only touch disk images unless --real is given.
        guard disk.isVirtual || options.allowReal else {
            return Self.say("--eject \(path): refused, \(disk.bsdName) is a real disk (pass --real)")
        }
        Self.say("--eject \(path) -> \(disk.bsdName) (\(disk.isVirtual ? "disk image" : "real disk"))")
        coordinator.eject(volumePath: path)
    }

    // MARK: Screenshots

    func attach(_ a: InUseAlert) {
        let cancel = a.onCancel
        a.onCancel = {
            Self.say("CANCEL pressed; key=\(NSApp.keyWindow?.title ?? "-") event=\(NSApp.currentEvent.map { "\($0.type.rawValue)" } ?? "-")\n"
                     + Thread.callStackSymbols.prefix(12).joined(separator: "\n"))
            cancel?()
        }
        a.onVisibleChange = { [weak self, weak a] label in
            guard let self, let a else { return }
            let nested = label == "force-confirm" || label == "stop-writer"
            onMainRunLoop(after: nested ? 0.6 : 0.4) { [weak a] in
                guard let a else { return }
                if nested, let c = a.confirmation {
                    let def = c.buttons.first { $0.keyEquivalent == "\r" }?.title ?? "-"
                    let focus = (c.window.initialFirstResponder as? NSButton)?.title ?? "-"
                    let keys = c.buttons.map { "\($0.title)=\($0.keyEquivalent.unicodeScalars.map { String(format: "U+%04X", $0.value) }.joined())" }
                    Self.say("CONFIRM \"\(c.messageText)\" buttons=\(keys) default(Return)=\(def) initialFocus=\(focus) "
                             + "firstResponder=\((c.window.firstResponder as? NSButton)?.title ?? String(describing: c.window.firstResponder.map { type(of: $0) }))")
                    let tree = Self.descendants(of: c.window.contentView?.superview ?? NSView())
                        .compactMap { $0 as? NSButton }
                        .map { "\($0.title)[\(type(of: $0))]=\($0.keyEquivalent.unicodeScalars.map { String(format: "U+%04X", $0.value) }.joined())" }
                    Self.say("CONFIRM window buttons: \(tree) defaultButtonCell=\(c.window.defaultButtonCell?.title ?? "-")")
                    self.snap(c.window, label: label)
                }
                else if !nested, a.window.isVisible { self.snap(a.window, label: "alert-\(label)") }
            }
        }
    }

    func attachPlain(_ alert: NSAlert, label: String) {
        plainAlerts = plainAlerts.filter { $0.value != nil } + [Weak(value: alert)]
        onMainRunLoop(after: 0.6) { [weak self] in
            if alert.window.isVisible { self?.snap(alert.window, label: label) }
        }
    }

    private typealias CreateImage = @convention(c) (CGRect, UInt32, CGWindowID, UInt32) -> Unmanaged<CGImage>?

    /// CGWindowListCreateImage is unavailable in the macOS 15+ SDK; it still works at runtime for own windows.
    private static let createImage: CreateImage? = {
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else { return nil }
        return unsafeBitCast(sym, to: CreateImage.self)
    }()

    /// Window capture; while the screen is locked the window server hands back a blank image, so the window's view
    /// tree is rendered offscreen instead (`cacheDisplay`).
    @discardableResult
    func snap(_ window: NSWindow, label: String) -> URL? {
        if let id = CGWindowID(exactly: window.windowNumber), let create = Self.createImage, options.screensDir != nil,
           let image = create(.null, 8, id, 8)?.takeRetainedValue() {
            let rep = NSBitmapImageRep(cgImage: image)
            if !Self.isBlank(rep) { return write(rep, label: label) }
        }
        guard let view = window.contentView?.superview ?? window.contentView else { return nil }
        // Vibrant text (labels inside the alert's visual-effect background) does not render offscreen: flatten the
        // effect views and use the plain light appearance for the capture, then restore them.
        let effects = Self.descendants(of: view).compactMap { $0 as? NSVisualEffectView }
        let saved = effects.map { ($0, $0.state, $0.isHidden) }
        let savedAppearance = window.appearance
        window.appearance = NSAppearance(named: .aqua)
        effects.forEach { $0.state = .inactive; $0.isHidden = true }
        view.layoutSubtreeIfNeeded()
        defer {
            saved.forEach { $0.0.state = $0.1; $0.0.isHidden = $0.2 }
            window.appearance = savedAppearance
        }
        let size = view.bounds.size
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.windowBackgroundColor.setFill()
        NSRect(origin: .zero, size: size).fill()
        NSGraphicsContext.restoreGraphicsState()
        view.cacheDisplay(in: view.bounds, to: rep)
        return write(rep, label: label + "-offscreen")
    }

    static func descendants(of v: NSView) -> [NSView] { v.subviews + v.subviews.flatMap(descendants) }

    /// One colour everywhere (sampled): what a capture returns while the screen is locked.
    static func isBlank(_ rep: NSBitmapImageRep) -> Bool {
        guard rep.pixelsWide > 0, rep.pixelsHigh > 0, let first = rep.colorAt(x: 0, y: 0) else { return true }
        for y in stride(from: 0, to: rep.pixelsHigh, by: max(1, rep.pixelsHigh / 24)) {
            for x in stride(from: 0, to: rep.pixelsWide, by: max(1, rep.pixelsWide / 24)) where rep.colorAt(x: x, y: y) != first {
                return false
            }
        }
        return true
    }

    @discardableResult
    func snapWindowID(_ id: CGWindowID, label: String) -> URL? {
        guard options.screensDir != nil, let create = Self.createImage,
              // kCGWindowListOptionIncludingWindow = 8; kCGWindowImageBestResolution = 8
              let image = create(.null, 8, id, 8)?.takeRetainedValue() else { return nil }
        return write(NSBitmapImageRep(cgImage: image), label: label)
    }

    @discardableResult
    private func write(_ rep: NSBitmapImageRep, label: String) -> URL? {
        guard let dir = options.screensDir, let png = rep.representation(using: .png, properties: [:]) else { return nil }
        counter += 1
        let url = dir.appendingPathComponent(String(format: "%02d-%@.png", counter, label))
        do { try png.write(to: url) } catch { Self.say("snap failed: \(error)"); return nil }
        Self.say("SNAP \(url.path) \(rep.pixelsWide)x\(rep.pixelsHigh)")
        return url
    }

    // MARK: SIGUSR1 command hook

    private func installSignalHook() {
        signal(SIGUSR1, SIG_IGN)
        let src = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
        src.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.readCommands() } }
        src.resume()
        signalSource = src
        Self.say("hooks: kill -USR1 \(getpid()) runs \(commandFile?.path ?? "-")")
    }

    private var commandFile: URL? { options.screensDir?.appendingPathComponent("cmd") }

    private func readCommands() {
        guard let file = commandFile else { return }
        let text: String
        do { text = try String(contentsOf: file, encoding: .utf8) } catch { return Self.say("SIGUSR1: \(error.localizedDescription)") }
        try? FileManager.default.removeItem(at: file)
        Self.say("SIGUSR1: \(text.split(separator: "\n").joined(separator: "; "))")
        let lines = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        // Each command in its own run-loop timer (never inside this main-queue block): a press that opens a
        // nested modal then does not block the main queue or the following commands.
        for (i, line) in lines.enumerated() {
            onMainRunLoop(after: Double(i) * 0.3) { [weak self] in self?.execute(line) }
        }
    }

    private func execute(_ line: String) {
        let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
        let arg = parts.count > 1 ? parts[1] : ""
        switch parts[0] {
        case "press": press(arg)
        case "rowpress":
            if let pid = pid_t(arg), let row = coordinator?.activeAlert?.row(pid: pid) {
                Self.say("rowpress \(pid)")
                row.pressButton()
            } else { Self.say("rowpress \(arg): no such row") }
        case "rowhover":
            // Same path as the row's tracking area (mouseEntered / mouseExited).
            let a = arg.split(separator: " ").map(String.init)
            if let pid = a.first.flatMap({ pid_t($0) }), let row = coordinator?.activeAlert?.row(pid: pid) {
                row.simulateHover(a.count < 2 || a[1] != "out")
                Self.say("rowhover \(arg): force button \(row.forceButtonState)")
            } else { Self.say("rowhover \(arg): no such row") }
        case "rowfocus":
            if let pid = pid_t(arg), let row = coordinator?.activeAlert?.row(pid: pid) {
                let ok = row.focusForceButton()
                Self.say("rowfocus \(pid): focused=\(ok); force button \(row.forceButtonState)")
            } else { Self.say("rowfocus \(arg): no such row") }
        case "rowforce":
            if let pid = pid_t(arg), let row = coordinator?.activeAlert?.row(pid: pid) {
                let state = row.forceButtonState
                Self.say("rowforce \(pid): pressed=\(row.pressForceButton()) (was \(state))")
            } else { Self.say("rowforce \(arg): no such row") }
        case "activate":
            // The same cooperative activation the modal alert asks for; macOS may decline it.
            NSApp.activate()
            onMainRunLoop(after: 0.3) {
                Self.say("activate: active=\(NSApp.isActive) key=\(NSApp.keyWindow.map { "\(type(of: $0))" } ?? "-")")
            }
        case "rowclick":
            // A real click (mouseDown + mouseUp posted to the event queue) on the row's force button.
            guard let pid = pid_t(arg), let row = coordinator?.activeAlert?.row(pid: pid), let w = row.window,
                  let p = row.forceButtonCenterInWindow else { Self.say("rowclick \(arg): no force button"); break }
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                if let e = NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                              windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
                    NSApp.postEvent(e, atStart: false)
                }
            }
            Self.say("rowclick \(pid): posted click at \(p) on \(row.forceButtonState)")
        case "tab":
            // A real Tab (or Shift-Tab: `tab shift`) key press, posted to the event queue like the keyboard's.
            guard let w = coordinator?.activeAlert?.window else { Self.say("tab: no window"); break }
            if let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: arg == "shift" ? [.shift] : [],
                                        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: w.windowNumber,
                                        context: nil, characters: "\t", charactersIgnoringModifiers: "\t", isARepeat: false,
                                        keyCode: ForceReveal.tabKeyCode) {
                NSApp.postEvent(e, atStart: false)
            }
            Self.say("tab: posted Tab keyDown (FKA=\(NSApp.isFullKeyboardAccessEnabled), active=\(NSApp.isActive), alert is key=\(w.isKeyWindow)); \(Self.focusDescription(w))")
        case "snap":
            let w = coordinator?.activeAlert?.confirmation?.window ?? NSApp.modalWindow ?? coordinator?.activeAlert?.window
            if let w { snap(w, label: arg.isEmpty ? "snap" : arg) } else { Self.say("snap: no window") }
        case "state": dumpState()
        case "menu": dumpMenu()
        case "menusnap": menuSnap()
        case "quit": NSApp.terminate(nil)
        default: Self.say("unknown command \(line)")
        }
    }

    /// Press a button by title in the frontmost of: nested confirmation, plain alerts, the in-use alert.
    /// (NSAlert's buttons are not in its window's view tree on macOS 26: use `NSAlert.buttons`.)
    private func press(_ title: String) {
        var alerts: [NSAlert] = []
        if let c = coordinator?.activeAlert?.confirmation { alerts.append(c) }
        alerts += plainAlerts.compactMap(\.value).filter { $0.window.isVisible }.reversed()
        if let a = coordinator?.activeAlert { alerts.append(a.alert) }
        for a in alerts {
            if let b = a.buttons.first(where: { $0.title == title }) {
                Self.say("press \(title) (enabled=\(b.isEnabled)) in \"\(a.messageText)\"")
                if b.isEnabled { b.performClick(nil) }
                return
            }
        }
        Self.say("press \(title): not found in \(alerts.map { "\"\($0.messageText)\": \($0.buttons.map(\.title))" })")
    }

    private struct Weak { weak var value: NSAlert? }
    private var plainAlerts: [Weak] = []

    static func focusDescription(_ w: NSWindow) -> String {
        let fr = w.firstResponder
        return "firstResponder before=" + ((fr as? NSButton).map { "button '\($0.title)'" } ?? String(describing: fr.map { type(of: $0) }))
    }

    private func dumpState() {
        guard let f = coordinator?.flow, let a = coordinator?.activeAlert else { return Self.say("STATE no active flow") }
        Self.say("STATE focus: \(Self.focusDescription(a.window).replacingOccurrences(of: " before", with: "")) active=\(NSApp.isActive) alert is key=\(a.window.isKeyWindow)")
        Self.say("STATE \(f.state) rows=\(f.rows.count) primary='\(a.primaryButton.title)' enabled=\(a.primaryButton.isEnabled) "
                 + "force=\(a.forceButton.isEnabled) blockers=\(f.blockers.map(\.message)) quitAllHint=\(f.quitAllHint ?? "-")")
        Self.say("STATE title: \(a.alert.messageText) | buttons: \(a.alert.buttons.map(\.title)) | mode: \(f.mode) | status: \(f.statusText)")
        Self.say("STATE informative: \(a.alert.informativeText)")
        Self.say("STATE rating: \(InUseAlert.ratingLine(f).0) | footer: \(f.deniedFooter ?? "-")")
        for r in f.rows {
            let v = a.row(pid: r.holder.pid)
            Self.say("STATE row \(r.holder.pid) \(HolderRowView.title(for: r)) [\(r.holder.kind.rawValue)\(r.holder.isWriter ? ",writer" : "")] "
                     + "'\(HolderRowView.detail(for: r).0.replacingOccurrences(of: "\n", with: " / "))' button=\(r.actionTitle ?? "-")"
                     + "\(r.actionEnabled ? "" : " (disabled)") status=\(r.status) view.button='\(v?.primaryButtonTitle ?? "-")' spinner=\(v?.isSpinning ?? false) "
                     + "force=\(v?.forceButtonState ?? "-")")
        }
    }

    private func dumpMenu() {
        guard let menu = menuController?.currentMenu else { return }
        menuController?.rebuild()
        Self.say("MENU status item tooltip: \(menuController?.statusItem.button?.toolTip ?? "-"), autosaveName: \(menuController?.statusItem.autosaveName ?? "-")")
        for item in menu.items {
            if item.isSeparatorItem { Self.say("MENU ----"); continue }
            let title = item.attributedTitle?.string ?? item.title
            var subtitle = ""
            if #available(macOS 14.4, *), let s = item.subtitle { subtitle = " (\(s))" }
            Self.say("MENU \(item.isSectionHeader ? "[header] " : "")\(title)\(subtitle)"
                     + "\(item.state == .on ? " [x]" : "")\(item.isEnabled ? "" : " (disabled)")")
        }
    }

    /// Opens the status menu, captures our menu window(s), closes it.
    private func menuSnap() {
        guard let menuController, let button = menuController.statusItem.button else { return }
        onMainRunLoop(after: 0.7) { [weak self] in
            guard let self else { return }
            let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
            let mine = info.filter { ($0[kCGWindowOwnerPID as String] as? Int32) == getpid() && ($0[kCGWindowLayer as String] as? Int ?? 0) > 0 }
            for w in mine {
                if let id = w[kCGWindowNumber as String] as? UInt32,
                   let bounds = w[kCGWindowBounds as String] as? [String: Double], (bounds["Height"] ?? 0) > 60 {
                    self.snapWindowID(id, label: "menu")
                }
            }
            menuController.currentMenu.cancelTracking()
        }
        button.performClick(nil)                        // runs the menu's tracking loop until cancelTracking
    }
}
#endif
