import AirTouchCore
import AppKit
import SwiftUI

final class OverlayModel: ObservableObject {
    @Published var ringVisible = false
    @Published var mode: EngineMode = .paused
    @Published var engaged = false
    @Published var progress: Double = 0
    @Published var toast: String?
}

extension EngineMode {
    var color: Color {
        switch self {
        case .paused: return .gray
        case .tracking: return .blue
        case .pressing: return .green
        case .scrolling: return .purple
        case .palm: return .orange
        case .fist: return .red
        case .shortcut: return .pink
        case .zooming: return .teal
        }
    }
}

/// The floating ring that follows your hand. Click-through, on every Space, above everything.
@MainActor
final class OverlayController {
    private let model = OverlayModel()
    private let panel: NSPanel
    private let size = NSSize(width: 220, height: 170)
    private var toastWork: DispatchWorkItem?

    init() {
        panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        let host = NSHostingView(rootView: OverlayView(model: model))
        host.frame = NSRect(origin: .zero, size: size)
        panel.contentView = host
    }

    /// `point` is in global CoreGraphics coordinates (origin top-left of the main display).
    func show(at point: CGPoint, snapshot: EngineSnapshot) {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let origin = NSPoint(x: point.x - size.width / 2, y: primaryHeight - point.y - size.height / 2)
        panel.setFrameOrigin(origin)

        if model.mode != snapshot.mode { model.mode = snapshot.mode }
        if model.engaged != snapshot.engaged { model.engaged = snapshot.engaged }
        if abs(model.progress - snapshot.progress) > 0.01 { model.progress = snapshot.progress }
        if !model.ringVisible { model.ringVisible = true }
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    func hideRing() {
        if model.ringVisible { model.ringVisible = false }
        if model.toast == nil, panel.isVisible { panel.orderOut(nil) }
    }

    func hideAll() {
        toastWork?.cancel()
        model.toast = nil
        model.ringVisible = false
        panel.orderOut(nil)
    }

    func toast(_ text: String) {
        model.toast = text
        if !panel.isVisible { panel.orderFrontRegardless() }
        toastWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.model.toast = nil
                if !self.model.ringVisible { self.panel.orderOut(nil) }
            }
        }
        toastWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.1, execute: work)
    }
}

struct OverlayView: View {
    @ObservedObject var model: OverlayModel

    private var ringSize: CGFloat {
        switch model.mode {
        case .pressing: return 22
        case .palm, .zooming: return 46
        default: return 34
        }
    }

    var body: some View {
        ZStack {
            if model.ringVisible {
                Circle()
                    .fill(model.mode.color.opacity(model.engaged ? 0.18 : 0.06))
                    .frame(width: ringSize, height: ringSize)
                Circle()
                    .stroke(
                        model.mode.color.opacity(model.engaged ? 0.95 : 0.6),
                        style: StrokeStyle(lineWidth: 3, dash: model.engaged ? [] : [5, 4])
                    )
                    .frame(width: ringSize, height: ringSize)
                if model.progress > 0 {
                    Circle()
                        .trim(from: 0, to: model.progress)
                        .stroke(Color.white, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                        .shadow(color: .black.opacity(0.4), radius: 2)
                        .rotationEffect(.degrees(-90))
                        .frame(width: ringSize + 14, height: ringSize + 14)
                }
            }
            if let toast = model.toast {
                Text(toast)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundColor(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(Color.black.opacity(0.75)))
                    .offset(y: 50)
            }
        }
        .frame(width: 220, height: 170)
        .animation(.easeOut(duration: 0.12), value: model.mode)
    }
}
