import Foundation

/// When a row's secondary force button (Force Quit / Force Stop / Kill, `EjectFlow.Row.secondaryAction`) is drawn.
///
/// It exists only while the row waits for a quit / stop the user asked for, and is revealed while the pointer is over
/// the row or keyboard focus is on the button (Tab reaches it while it is present, which then reveals it). One process
/// per click, labelled (S3): revealing it never acts. Once the grace has passed the row's primary button is the force
/// action itself and this one goes away. The app's HolderRowView feeds pointer and focus events in; pure so tests
/// can drive it.
public struct ForceReveal: Sendable, Hashable {
    /// The row currently offers a secondary force action.
    public private(set) var isPresent = false
    public private(set) var isHovering = false
    public private(set) var isFocused = false

    public init() {}

    /// The row changed. The button exists only while the row offers a secondary force action.
    public mutating func update(_ row: EjectFlow.Row) {
        isPresent = row.secondaryAction != nil
        if !isPresent { isFocused = false }
    }

    /// Hover: the pointer entered the row.
    public mutating func pointerEntered() { isHovering = true }

    public mutating func pointerExited() { isHovering = false }

    /// Keyboard focus moved onto (true) or off (false) the force button.
    public mutating func focusChanged(_ focused: Bool) { isFocused = focused && isPresent }

    /// Keyboard focus may land on the force button only from a deliberate Tab / Shift-Tab key press (key code 48), never
    /// because AppKit moved focus there by itself (for example off the row's Quit button as it became "Quitting…"): a
    /// Space or Return meant for something else must never force-quit.
    public static func acceptsFocus(keyDownKeyCode: UInt16?) -> Bool { keyDownKeyCode == tabKeyCode }

    public static let tabKeyCode: UInt16 = 48

    /// Drawn and clickable. When present but not revealed the button keeps its place (no layout jump on hover) and stays
    /// in the key-view loop, transparent.
    public var isRevealed: Bool { isPresent && (isHovering || isFocused) }
}
