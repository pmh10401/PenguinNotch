import SwiftUI
import XCTest
@testable import PenguinNotch

@MainActor
final class NotchScrollTests: XCTestCase {
    private struct Screen: ScreenDescribing {
        var frameValue = CGRect(x: -900, y: 100, width: 900, height: 640)
        var visibleFrameValue: CGRect { frameValue }
        var hardwareNotch: HardwareNotch?
    }

    private func fill(_ model: NotchViewModel, count: Int = 40) {
        model.snapshots = (0..<count).map { i in
            ProviderSnapshot(id: "p\(i)", displayName: "P\(i)", glyph: .claude,
                fidelity: .official, status: .ok,
                windows: [LimitWindow(id: "w", label: "Session", usedFraction: 0.4)], headlineID: "w")
        }
        model.isExpanded = true
        model.surfaceStyle = .solid
    }

    func testViewportAndHandlesFitAndBothEndsAreReachable() {
        for edge in NotchEdge.allCases {
            for style in [NotchMeterStyle.ring, .bar] {
                for scale: CGFloat in [0.75, 1, 1.5] {
                    for hardware in [false, true] {
                        let controller = NotchWindowController(), model = controller.model
                        model.edge = edge; model.sizeScale = scale; model.notchMeterStyle = style
                        fill(model)
                        let screen = Screen(hardwareNotch: hardware ? HardwareNotch(width: 220, height: 32) : nil)
                        model.adopt(screen: screen)
                        let extent = edge.isVertical ? screen.frameValue.height : screen.frameValue.width
                        XCTAssertLessThanOrEqual(model.shapeLength * scale + model.leadingExtent + model.trailingExtent, extent)
                        XCTAssertGreaterThan(model.maxScrollOffset, 0)
                        let first = model.slack + model.ringCenter(index: 0) * scale
                        XCTAssertEqual(controller.cellIndex(along: first), 0)
                        XCTAssertNil(controller.cellIndex(along: model.slack + model.ringCenter(index: 39) * scale))
                        XCTAssertFalse(model.isCellVisible(index: 39))
                        let frame = NotchGeometry.panelFrame(for: screen, panelSize: model.panelSize,
                            edge: edge, alongOffset: 10_000, slack: model.slack,
                            trailingExtent: model.trailingExtent, leadingExtent: model.leadingExtent)
                        let place = NotchPlacement(edge: edge, panelSize: frame.size)
                        let local = place.rect(along: model.slack - model.leadingExtent, across: 0,
                            length: model.shapeLength * scale + model.leadingExtent + model.trailingExtent,
                            depth: model.notchDrawnDepth)
                        let global = CGRect(x: frame.minX + local.minX, y: frame.maxY - local.maxY,
                            width: local.width, height: local.height)
                        XCTAssertGreaterThanOrEqual(global.minX, screen.frameValue.minX - 1)
                        XCTAssertLessThanOrEqual(global.maxX, screen.frameValue.maxX + 1)
                        XCTAssertGreaterThanOrEqual(global.minY, screen.frameValue.minY - 1)
                        XCTAssertLessThanOrEqual(global.maxY, screen.frameValue.maxY + 1)
                        model.scroll(by: 100_000)
                        let last = model.slack + model.ringCenter(index: 39) * scale
                        XCTAssertEqual(controller.cellIndex(along: last), 39)
                        XCTAssertTrue(model.isCellVisible(index: 39))
                        XCTAssertFalse(model.isCellVisible(index: 0))
                        XCTAssertFalse(model.scroll(by: 100))
                        model.scroll(by: -100_000)
                        XCTAssertEqual(model.scrollOffset, 0)
                        XCTAssertEqual(controller.cellIndex(along: first), 0)
                    }
                }
            }
        }
    }

    func testFittingListsDoNotScrollAndShrinkingClearsOldOffset() {
        let model = NotchViewModel()
        model.adopt(screen: Screen())
        fill(model, count: 2)
        let original = model.ringCenter(index: 0)
        XCTAssertFalse(model.scroll(by: 1000))
        XCTAssertEqual(model.ringCenter(index: 0), original)
        fill(model)
        model.scroll(by: 1000)
        XCTAssertGreaterThan(model.scrollOffset, 0)
        model.updateSnapshots(Array(model.snapshots.prefix(2)))
        XCTAssertEqual(model.scrollOffset, 0)
        fill(model)
        XCTAssertEqual(model.scrollOffset, 0)
        XCTAssertFalse(model.scroll(by: .nan))
        XCTAssertFalse(model.scroll(by: .infinity))
    }

    func testWheelUsesScaledCoordinatesPreservesCardAndFoldedScrolling() throws {
        for edge in NotchEdge.allCases {
            let controller = NotchWindowController(), model = controller.model
            model.edge = edge; model.sizeScale = 1.5
            fill(model)
            controller.relocate()
            defer { controller.stop() }
            let panel = try XCTUnwrap(controller.panelContentViewForTesting?.window as? NotchPanel)
            let placement = NotchPlacement(edge: edge, panelSize: panel.frame.size)
            func location(along: CGFloat, across: CGFloat) -> CGPoint {
                let p = placement.point(along: along, across: across)
                return CGPoint(x: p.x, y: panel.frame.height - p.y)
            }
            let point = location(along: model.slack + model.ringCenter(index: 2) * model.sizeScale,
                                 across: model.notchDrawnDepth / 2)
            XCTAssertTrue(controller.scroll(at: point, deltaX: 0, deltaY: -90, precise: true))
            XCTAssertEqual(model.scrollOffset, 60, accuracy: 0.001)
            let local = CGPoint(x: point.x, y: panel.frame.height - point.y)
            XCTAssertEqual(model.hoveredIndex, controller.cellIndex(along: placement.along(of: local)))
            if !edge.isVertical {
                XCTAssertTrue(controller.scroll(at: point, deltaX: -90, deltaY: 0, precise: true))
                XCTAssertEqual(model.scrollOffset, 120, accuracy: 0.001)
            }
            let before = model.scrollOffset
            let card = location(along: placement.along(of: local), across: model.notchDrawnDepth + 60)
            XCTAssertFalse(controller.scroll(at: card, deltaX: 0, deltaY: -90, precise: true))
            XCTAssertEqual(model.scrollOffset, before)
            model.isExpanded = false
            XCTAssertFalse(controller.scroll(at: point, deltaX: 0, deltaY: -90, precise: true))
            XCTAssertEqual(model.scrollOffset, before)
            model.isExpanded = true
            XCTAssertTrue(controller.scroll(at: point, deltaX: 0, deltaY: -1, precise: false))
            XCTAssertEqual(model.scrollOffset, before + 20 / 1.5, accuracy: 0.001)
        }
    }

    func testPanelRoutesRealWheelEventBeforeSwiftUI() throws {
        let panel = NotchPanel(contentRect: CGRect(x: 0, y: 0, width: 200, height: 200))
        let cg = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .pixel,
            wheelCount: 1, wheel1: -30, wheel2: 0, wheel3: 0))
        let event = try XCTUnwrap(NSEvent(cgEvent: cg))
        var calls = 0
        panel.onScroll = { received in
            XCTAssertEqual(received.type, .scrollWheel)
            XCTAssertEqual(received.scrollingDeltaY, event.scrollingDeltaY)
            calls += 1
            return true
        }
        panel.sendEvent(event)
        XCTAssertEqual(calls, 1)
    }

    func testScrolledCellsStillClickAndDragTheVisibleItem() async throws {
        let name = "NotchScroll.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let preferences = Preferences(defaults: defaults)
        let controller = NotchWindowController(), model = controller.model
        fill(model)
        preferences.providerOrder = model.snapshots.map(\.id)
        model.todoPreferences = preferences
        controller.relocate()
        defer { controller.stop() }
        model.scroll(by: 100_000)
        let panel = try XCTUnwrap(controller.panelContentViewForTesting?.window as? NotchPanel)
        panel.contentView?.layoutSubtreeIfNeeded()
        let placement = NotchPlacement(edge: model.edge, panelSize: panel.frame.size)
        func location(_ index: Int) -> CGPoint {
            let p = placement.point(along: model.slack + model.ringCenter(index: index),
                                    across: model.notchDrawnDepth / 2)
            return CGPoint(x: p.x, y: panel.frame.height - p.y)
        }
        func mouse(_ type: NSEvent.EventType, _ point: CGPoint) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                timestamp: 0, windowNumber: panel.windowNumber, context: nil,
                eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1))
        }
        let clicked = expectation(description: "visible last item refreshed")
        controller.onRefreshProvider = { id in
            XCTAssertEqual(id, "p39")
            clicked.fulfill()
        }
        let click = location(39)
        let queuedClick = CGPoint(x: click.x - panel.frame.minX, y: click.y + panel.frame.minY)
        NSApp.postEvent(try mouse(.leftMouseUp, queuedClick), atStart: true)
        panel.mouseDown(with: try mouse(.leftMouseDown, click))
        await fulfillment(of: [clicked], timeout: 1)
        let target = location(38)
        XCTAssertEqual(panel.canReorder?(click), true)
        XCTAssertEqual(panel.canReorder?(target), true)
        let drop = panel.onReorderDrop
        var didDrop = false
        panel.onReorderDrop = { source, destination in
            didDrop = true
            XCTAssertEqual(source.x, click.x, accuracy: 1)
            XCTAssertEqual(destination.x, target.x, accuracy: 1)
            XCTAssertEqual(destination.y, target.y, accuracy: 1)
            drop?(source, destination)
        }
        NSApp.postEvent(try mouse(.leftMouseUp, target), atStart: true)
        NSApp.postEvent(try mouse(.leftMouseDragged, target), atStart: true)
        panel.mouseDown(with: try mouse(.leftMouseDown, click))
        XCTAssertTrue(didDrop)
        XCTAssertEqual(Array(preferences.providerOrder.suffix(2)), ["p39", "p38"])
        XCTAssertNil(model.dragTargetID)
    }

    func testRealViewMovesLastRingIntoViewport() throws {
        for edge in NotchEdge.allCases {
            let model = NotchViewModel()
            model.edge = edge
            fill(model)
            model.snapshots[39].systemColor = .green
            model.adopt(screen: Screen())
            model.scroll(by: 100_000)
            let size = model.panelSize
            let renderer = ImageRenderer(content: NotchRootView(model: model)
                .frame(width: size.width, height: size.height)
                .environment(\.colorScheme, .dark))
            renderer.scale = 1
            let image = try XCTUnwrap(renderer.cgImage)
            let bitmap = NSBitmapImageRep(cgImage: image)
            let attachment = XCTAttachment(image: NSImage(cgImage: image, size: size))
            attachment.name = "mac-scroll-\(edge.rawValue)"
            attachment.lifetime = .keepAlways
            add(attachment)
            let centre = model.placement.point(along: model.slack + model.ringCenter(index: 39),
                across: NotchLayout.ringMargin(for: edge) + NotchLayout.ringDiameter / 2)
            var greenPixels = 0
            for x in Int(centre.x - 22)...Int(centre.x + 22) {
                for y in Int(centre.y - 22)...Int(centre.y + 22) {
                    if let color = bitmap.colorAt(x: x, y: y), color.alphaComponent > 0.5,
                       color.greenComponent > 0.35,
                       color.greenComponent > color.redComponent * 1.3,
                       color.greenComponent > color.blueComponent * 1.3 {
                        greenPixels += 1
                    }
                }
            }
            XCTAssertGreaterThan(greenPixels, 30, "\(edge): final ring did not render at its hit-test position")
        }
    }
}
