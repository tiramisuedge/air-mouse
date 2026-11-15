import AppKit
import SwiftUI

final class DrawModel: ObservableObject {
    @Published var strokes: [[CGPoint]] = []
    @Published var current: [CGPoint] = []
    /// Black ink instead of white glow, for light wallpapers.
    @Published var dark = false

    var isEmpty: Bool { strokes.isEmpty && current.isEmpty }
}

/// A see-through sheet over the whole screen that holds what you draw in the air.
///
/// It never touches your wallpaper file, your icons or your windows: the strokes live
/// in this panel and vanish with it. Click-through, so everything underneath still works.
@MainActor
final class DrawCanvasController {
    private let model = DrawModel()
    private let panel: NSPanel

    init() {
        let frame = NSScreen.screens.first?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        panel = NSPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        // Under the cursor ring, over everything else.
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        let host = NSHostingView(rootView: DrawCanvasView(model: model))
        host.frame = NSRect(origin: .zero, size: frame.size)
        panel.contentView = host
        panel.setFrame(frame, display: false)
    }

    var dark: Bool {
        get { model.dark }
        set { model.dark = newValue }
    }

    func show() {
        guard !panel.isVisible else { return }
        let frame = NSScreen.screens.first?.frame ?? panel.frame
        panel.setFrame(frame, display: false)
        panel.orderFrontRegardless()
    }

    func hide() {
        panel.orderOut(nil)
    }

    /// `point` is in global CoreGraphics coordinates, which on the main display share
    /// their top-left origin with the panel's SwiftUI content.
    func add(_ point: CGPoint) {
        model.current.append(point)
    }

    func endStroke() {
        guard model.current.count > 1 else {
            model.current.removeAll()
            return
        }
        model.strokes.append(model.current)
        model.current.removeAll()
        // Keep the sheet from filling up over a long session.
        if model.strokes.count > 60 { model.strokes.removeFirst() }
    }

    func clear() {
        model.current.removeAll()
        model.strokes.removeAll()
    }
}

struct DrawCanvasView: View {
    @ObservedObject var model: DrawModel

    private var ink: Color { model.dark ? .black : .white }

    private func path(_ points: [CGPoint]) -> Path {
        var path = Path()
        guard let first = points.first else { return path }
        path.move(to: first)
        guard points.count > 2 else {
            for point in points.dropFirst() { path.addLine(to: point) }
            return path
        }
        // Curve through the midpoints so a shaky hand still draws a smooth line.
        for index in 1..<(points.count - 1) {
            let point = points[index]
            let next = points[index + 1]
            let mid = CGPoint(x: (point.x + next.x) / 2, y: (point.y + next.y) / 2)
            path.addQuadCurve(to: mid, control: point)
        }
        path.addLine(to: points[points.count - 1])
        return path
    }

    var body: some View {
        Canvas { context, _ in
            let strokes = model.strokes + (model.current.isEmpty ? [] : [model.current])
            guard !strokes.isEmpty else { return }

            // The glow: a wide, blurred pass under the line itself.
            context.drawLayer { layer in
                layer.addFilter(.blur(radius: 11))
                for stroke in strokes {
                    layer.stroke(
                        path(stroke),
                        with: .color(ink.opacity(0.6)),
                        style: StrokeStyle(lineWidth: 16, lineCap: .round, lineJoin: .round)
                    )
                }
            }
            for stroke in strokes {
                context.stroke(
                    path(stroke),
                    with: .color(ink),
                    style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round)
                )
            }
        }
        .allowsHitTesting(false)
        .ignoresSafeArea()
    }
}
