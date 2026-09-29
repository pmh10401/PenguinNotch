import AppKit

/// Borderless, non-activating panel that floats over everything, including the
/// menu bar and full-screen apps. Non-activating matters: glancing at your
/// usage must never take focus off what you were actually doing.
final class NotchPanel: NSPanel {
    /// Supplies the right-click menu. Handled here rather than on the content
    /// view because `NSWindow.sendEvent` sees every event first — the hosting
    /// view's hit test resolves to a SwiftUI-owned subview, which has no menu
    /// of its own and may consume the click before it reaches us.
    var contextMenuProvider: (() -> NSMenu?)?
    /// A left click on the visible chrome. Handled here for the same reason the
    /// menu is: the hit test lands on a SwiftUI subview that may consume it.
    var onClick: ((CGPoint) -> Void)?
    var canReorder: ((CGPoint) -> Bool)?
    var onReorderHover: ((CGPoint, CGPoint) -> Void)?
    var onReorderDrop: ((CGPoint, CGPoint) -> Void)?
    var onReorderEnd: (() -> Void)?
    /// Nil uses AppKit. Tests supply window-local events without the platform's
    /// synthetic event queue changing their coordinates.
    var nextCellDragEvent: (() -> NSEvent?)?
    /// Consume wheel input only over an overflowing list. Cards keep native scrolling.
    var onScroll: ((NSEvent) -> Bool)?
    /// ⌥-drag on the chrome, reported as the raw pointer delta since the last
    /// event — not a cumulative offset, so the caller decides what "along the
    /// edge" means for the current one. Chosen over a plain click-and-hold
    /// threshold so an ordinary click never risks being read as a tiny nudge.
    var onDragStart: (() -> Void)?
    var onDrag: ((CGFloat, CGFloat) -> Void)?
    /// The ⌥-drag ended. Where to persist the offset the drags above moved to.
    var onDragEnd: (() -> Void)?

    override func sendEvent(_ event: NSEvent) {
        if event.type == .scrollWheel, onScroll?(event) == true { return }
        guard event.type == .rightMouseDown,
              let menu = contextMenuProvider?(),
              let view = contentView,
              // Only over the visible chrome; elsewhere the panel is a hole.
              view.hitTest(event.locationInWindow) != nil
        else { return super.sendEvent(event) }

        NSMenu.popUpContextMenu(menu, with: event, for: view)
    }

    /// Whether a press at this point, in the window's own coordinates, is on
    /// something that carries the notch without ⌥ — the grip beside the
    /// settings button.
    var startsDrag: ((CGPoint) -> Bool)?

    override func mouseDown(with event: NSEvent) {
        guard let view = contentView, view.hitTest(event.locationInWindow) != nil else {
            return super.mouseDown(with: event)
        }
        let carries = event.modifierFlags.contains(.option)
            || startsDrag?(event.locationInWindow) == true
        guard carries, onDrag != nil else {
            if canReorder?(event.locationInWindow) == true {
                trackCellDrag(from: event.locationInWindow)
            } else {
                onClick?(event.locationInWindow)
            }
            return
        }
        onDragStart?()
        trackOptionDrag()
    }

    /// Blocks on this window's own event stream until the button lifts, the
    /// standard AppKit pattern for a custom drag started from `mouseDown`.
    /// Never falls through to `onClick` on release: an ⌥-drag is a distinct
    /// gesture from the start, not a click that grew into one, so there is
    /// nothing to reinterpret once the button comes up.
    private func trackOptionDrag() {
        while let event = nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            switch event.type {
            case .leftMouseDragged:
                onDrag?(event.deltaX, event.deltaY)
            case .leftMouseUp:
                onDragEnd?()
                return
            default:
                return
            }
        }
    }

    private func trackCellDrag(from start: CGPoint) {
        var dragging = false
        defer { if dragging { onReorderEnd?() } }
        let readEvent = nextCellDragEvent ?? { self.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) }
        while let event = readEvent() {
            switch event.type {
            case .leftMouseDragged:
                let point = event.locationInWindow
                if !dragging {
                    dragging = hypot(point.x - start.x, point.y - start.y) >= 5
                }
                if dragging { onReorderHover?(start, point) }
            case .leftMouseUp:
                // Release can be the first delivered movement in a fast drag.
                let point = event.locationInWindow
                dragging = dragging || hypot(point.x - start.x, point.y - start.y) >= 5
                if dragging {
                    onReorderDrop?(start, point)
                } else {
                    onClick?(start)
                }
                return
            default:
                return
            }
        }
    }

    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovable = false
        isMovableByWindowBackground = false
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        isReleasedWhenClosed = false
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
