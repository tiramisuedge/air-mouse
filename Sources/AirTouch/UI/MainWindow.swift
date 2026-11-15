import AirTouchCore
import AppKit
import SwiftUI

/// Live data for the AirTouch window. Only updated while the window is open.
final class PreviewModel: ObservableObject {
    @Published var image: CGImage?
    @Published var hands: [Hand] = []
    @Published var snapshot = EngineSnapshot.idle
    /// The active zone (normalized camera coords) that maps to the screen.
    @Published var zone = CGRect(x: 0.26, y: 0.34, width: 0.48, height: 0.42)
    var isVisible = false
}

@MainActor
final class MainWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    var onVisibilityChange: (@MainActor (Bool) -> Void)?

    func show<Content: View>(_ makeContent: () -> Content) {
        if window == nil {
            let controller = NSHostingController(rootView: makeContent())
            let window = NSWindow(contentViewController: controller)
            window.title = "AirTouch"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.setContentSize(NSSize(width: 1040, height: 620))
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        onVisibilityChange?(true)
    }

    func windowWillClose(_ notification: Notification) {
        onVisibilityChange?(false)
    }
}

/// Just the gesture list, in its own window, so you can keep it open beside
/// whatever you are doing while you learn the gestures.
@MainActor
final class GuideWindowController {
    private var window: NSWindow?

    func show() {
        if window == nil {
            let controller = NSHostingController(rootView: GestureGuide())
            let window = NSWindow(contentViewController: controller)
            window.title = "Gesture Guide"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.setContentSize(NSSize(width: 460, height: 660))
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

struct MainWindowView: View {
    @ObservedObject var state: AppState
    @ObservedObject var preview: PreviewModel

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                header
                CameraPreview(preview: preview, enabled: state.isEnabled)
                statusRow
                PermissionsPanel(state: state)
                Spacer(minLength: 0)
            }
            .padding(20)
            .frame(minWidth: 620)

            Divider()

            GestureGuide()
                .frame(width: 340)
        }
        .frame(minWidth: 980, minHeight: 600)
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("AirTouch").font(.largeTitle.bold())
                Text("Control your Mac with your hand, no touching needed.")
                    .foregroundColor(.secondary)
            }
            Spacer()
            Toggle(isOn: Binding(get: { state.isEnabled }, set: { state.setEnabled($0) })) {
                Text(state.isEnabled ? "On" : "Off").font(.headline)
            }
            .toggleStyle(.switch)
            .controlSize(.large)
        }
    }

    private var statusRow: some View {
        HStack(spacing: 18) {
            Label(state.isEnabled ? preview.snapshot.mode.title : "Off", systemImage: "circle.fill")
                .foregroundColor(state.isEnabled ? preview.snapshot.mode.color : .secondary)
            Text("Pose: \(preview.snapshot.pose.emoji) \(preview.snapshot.pose.title)")
            Text("Hands: \(preview.snapshot.handCount)")
            Spacer()
            Text("Shortcut: ⌥⌘A").foregroundColor(.secondary)
        }
        .font(.callout.monospacedDigit())
    }
}

struct CameraPreview: View {
    @ObservedObject var preview: PreviewModel
    let enabled: Bool

    static let bones: [(Joint, Joint)] = [
        (.wrist, .thumbCMC), (.thumbCMC, .thumbMP), (.thumbMP, .thumbIP), (.thumbIP, .thumbTip),
        (.wrist, .indexMCP), (.indexMCP, .indexPIP), (.indexPIP, .indexDIP), (.indexDIP, .indexTip),
        (.wrist, .middleMCP), (.middleMCP, .middlePIP), (.middlePIP, .middleDIP), (.middleDIP, .middleTip),
        (.wrist, .ringMCP), (.ringMCP, .ringPIP), (.ringPIP, .ringDIP), (.ringDIP, .ringTip),
        (.wrist, .littleMCP), (.littleMCP, .littlePIP), (.littlePIP, .littleDIP), (.littleDIP, .littleTip),
        (.indexMCP, .middleMCP), (.middleMCP, .ringMCP), (.ringMCP, .littleMCP),
    ]

    private var aspect: CGFloat {
        guard let image = preview.image, image.height > 0 else { return 16.0 / 9.0 }
        return CGFloat(image.width) / CGFloat(image.height)
    }

    var body: some View {
        ZStack {
            Canvas { context, size in
                let rect = CGRect(origin: .zero, size: size)
                context.fill(Path(rect), with: .color(.black))
                if let image = preview.image {
                    context.draw(Image(decorative: image, scale: 1), in: rect)
                }

                // Active zone
                let z = preview.zone
                let zoneRect = CGRect(x: z.minX * size.width, y: z.minY * size.height,
                                      width: z.width * size.width, height: z.height * size.height)
                context.stroke(Path(roundedRect: zoneRect, cornerRadius: 8),
                               with: .color(.white.opacity(0.6)),
                               style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))

                // Hand skeletons
                let color = preview.snapshot.engaged ? preview.snapshot.mode.color : Color.yellow
                for hand in preview.hands {
                    func pt(_ j: Joint) -> CGPoint? {
                        hand[j].map { CGPoint(x: $0.x * size.width, y: $0.y * size.height) }
                    }
                    var bones = Path()
                    for (a, b) in CameraPreview.bones {
                        if let p = pt(a), let q = pt(b) {
                            bones.move(to: p)
                            bones.addLine(to: q)
                        }
                    }
                    context.stroke(bones, with: .color(color), lineWidth: 3)
                    for joint in Joint.allCases {
                        if let p = pt(joint) {
                            context.fill(Path(ellipseIn: CGRect(x: p.x - 4, y: p.y - 4, width: 8, height: 8)),
                                         with: .color(.white))
                        }
                    }
                }
            }
            if !enabled {
                VStack(spacing: 8) {
                    Image(systemName: "hand.raised.slash").font(.system(size: 40))
                    Text("AirTouch is off. Switch it on to see the camera.")
                }
                .foregroundColor(.white.opacity(0.8))
            }
        }
        .aspectRatio(aspect, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(alignment: .bottomLeading) {
            Text("Dashed box = active zone. Keep your hand inside it.")
                .font(.caption)
                .foregroundColor(.white.opacity(0.8))
                .padding(8)
        }
    }
}

struct PermissionsPanel: View {
    @ObservedObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            row(
                ok: state.cameraGranted,
                title: "Camera",
                detail: "Video is processed on your Mac and never leaves it.",
                action: { Permissions.openCameraSettings() }
            )
            row(
                ok: state.accessibilityGranted,
                title: "Accessibility",
                detail: "Lets AirTouch move the cursor, click and press shortcuts.",
                action: { state.requestAccessibility() }
            )
            if let error = state.cameraError {
                Label(error, systemImage: "exclamationmark.triangle.fill").foregroundColor(.orange)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.05)))
    }

    private func row(ok: Bool, title: String, detail: String, action: @escaping () -> Void) -> some View {
        HStack {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundColor(ok ? .green : .orange)
            VStack(alignment: .leading) {
                Text(title).bold()
                Text(detail).font(.caption).foregroundColor(.secondary)
            }
            Spacer()
            if !ok { Button("Grant…", action: action) }
        }
    }
}

struct GestureGuide: View {
    struct Item: Identifiable {
        let id = UUID()
        let emoji: String
        let gesture: String
        let action: String
    }

    struct Section: Identifiable {
        let title: String
        let items: [Item]
        var id: String { title }
        init(_ title: String, _ items: [Item]) {
            self.title = title
            self.items = items
        }
    }

    static let sections: [Section] = [
        Section("Start & stop", [
            Item(emoji: "🖐", gesture: "Hold open palm still (½ s)", action: "Start controlling"),
            Item(emoji: "✊", gesture: "Hold a fist still (1 s)", action: "Pause"),
            Item(emoji: "👋", gesture: "Lower your hand", action: "Auto-pause after 1.5 s"),
        ]),
        Section("Mouse", [
            Item(emoji: "☝️", gesture: "Move your hand", action: "Move the cursor"),
            Item(emoji: "🤏", gesture: "Pinch thumb + index", action: "Click"),
            Item(emoji: "🤏🤏", gesture: "Pinch twice quickly", action: "Double-click"),
            Item(emoji: "🤏➡️", gesture: "Pinch, hold and move", action: "Drag / select"),
            Item(emoji: "🤌", gesture: "Pinch thumb + middle", action: "Right-click"),
            Item(emoji: "✌️", gesture: "Two fingers up, move hand", action: "Scroll"),
        ]),
        Section("Media", [
            Item(emoji: "💍", gesture: "Tap thumb + ring finger", action: "Play / pause"),
            Item(emoji: "💍↕️", gesture: "Hold thumb + ring, move up / down", action: "Volume"),
        ]),
        Section("Draw", [
            Item(emoji: "🤟", gesture: "Hold three fingers up (½ s)", action: "Draw mode on / off"),
            Item(emoji: "✍️", gesture: "Pinch and move while drawing", action: "Draw a glowing line"),
            Item(emoji: "🖐", gesture: "Open palm while drawing", action: "Wipe the sheet"),
        ]),
        Section("System", [
            Item(emoji: "🖐⬅️", gesture: "Swipe open hand left", action: "Next desktop / full-screen app"),
            Item(emoji: "🖐➡️", gesture: "Swipe open hand right", action: "Previous desktop"),
            Item(emoji: "🖐⬆️", gesture: "Swipe open hand up", action: "Mission Control"),
            Item(emoji: "🖐⬇️", gesture: "Swipe open hand down", action: "App Exposé"),
            Item(emoji: "✊⬇️", gesture: "Make a fist and pull down", action: "Minimize window"),
            Item(emoji: "🤏 🤏", gesture: "Pinch both hands, spread / squeeze", action: "Zoom in / out"),
            Item(emoji: "🤙", gesture: "Hold shaka (½ s)", action: "Open your shortcut app"),
            Item(emoji: "🤙⬅️", gesture: "Flick shaka left / right", action: "Back / forward"),
            Item(emoji: "📷", gesture: "Both hands make corners, hold", action: "Screenshot that region"),
        ]),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Gestures").font(.title2.bold())
                ForEach(GestureGuide.sections) { section in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(section.title.uppercased())
                            .font(.caption.bold())
                            .foregroundColor(.secondary)
                        ForEach(section.items) { item in
                            HStack(alignment: .top, spacing: 10) {
                                Text(item.emoji).font(.title3).frame(width: 52, alignment: .leading)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(item.action).bold()
                                    Text(item.gesture).font(.caption).foregroundColor(.secondary)
                                }
                            }
                        }
                    }
                }
                Text("Tip: sit about an arm's length away, with your face and raised hand both in view. Good lighting helps a lot.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(20)
        }
    }
}
