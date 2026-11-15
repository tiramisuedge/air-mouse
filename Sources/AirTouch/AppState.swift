import AirTouchCore
import AppKit
import AVFoundation
import SwiftUI
import UniformTypeIdentifiers

enum Sensitivity: String, CaseIterable, Identifiable {
    case low, medium, high

    var id: String { rawValue }

    var title: String {
        switch self {
        case .low: return "Low (big arm movements)"
        case .medium: return "Medium"
        case .high: return "High (small hand movements)"
        }
    }

    /// Size of the active zone in the camera frame. Smaller zone = more sensitive.
    var zoneSize: CGSize {
        switch self {
        case .low: return CGSize(width: 0.62, height: 0.55)
        case .medium: return CGSize(width: 0.48, height: 0.42)
        case .high: return CGSize(width: 0.36, height: 0.32)
        }
    }
}

/// How hard the cursor is smoothed. Gentle is steadiest, Quick is most responsive.
enum Pace: String, CaseIterable, Identifiable {
    case gentle, natural, quick

    var id: String { rawValue }

    var title: String {
        switch self {
        case .gentle: return "Gentle (steadiest)"
        case .natural: return "Natural"
        case .quick: return "Quick (most responsive)"
        }
    }

    /// 1 euro filter settings. A lower cutoff is calmer when your hand rests,
    /// a higher beta lets go of the smoothing sooner when you move.
    var smoothing: (minCutoff: Double, beta: Double) {
        switch self {
        case .gentle: return (0.7, 5.0)
        case .natural: return (1.0, 8.0)
        case .quick: return (1.6, 12.0)
        }
    }
}

struct StatusSummary: Equatable {
    var text: String
    var icon: String

    static let off = StatusSummary(text: "Camera asleep", icon: "hand.raised.slash")
}

/// Owns everything: camera pipeline, gesture engine, input, overlay, settings.
@MainActor
final class AppState: ObservableObject {
    private enum Keys {
        static let sensitivity = "sensitivity"
        static let pace = "pace"
        static let showOverlay = "showOverlay"
        static let requirePalm = "requirePalm"
        static let mirrorCamera = "mirrorCamera"
        static let reverseSwipe = "reverseSwipe"
        static let reverseScroll = "reverseScroll"
        static let shortcutAppPath = "shortcutAppPath"
        static let hasLaunchedBefore = "hasLaunchedBefore"
    }

    // MARK: Published state

    @Published private(set) var isEnabled = false
    @Published private(set) var status = StatusSummary.off
    @Published private(set) var accessibilityGranted = false
    @Published private(set) var cameraGranted = false
    @Published private(set) var cameraError: String?

    // MARK: Settings (persisted)

    @Published var sensitivity: Sensitivity {
        didSet { save(sensitivity.rawValue, Keys.sensitivity); applyConfig() }
    }
    @Published var pace: Pace {
        didSet { save(pace.rawValue, Keys.pace); applyConfig() }
    }
    @Published var showOverlay: Bool {
        didSet { save(showOverlay, Keys.showOverlay); if !showOverlay { overlay.hideAll() } }
    }
    @Published var requirePalm: Bool {
        didSet { save(requirePalm, Keys.requirePalm); applyConfig() }
    }
    @Published var mirrorCamera: Bool {
        didSet { save(mirrorCamera, Keys.mirrorCamera); pipeline.mirror = mirrorCamera }
    }
    @Published var reverseSwipe: Bool {
        didSet { save(reverseSwipe, Keys.reverseSwipe) }
    }
    @Published var reverseScroll: Bool {
        didSet { save(reverseScroll, Keys.reverseScroll) }
    }
    @Published var shortcutAppPath: String? {
        didSet { save(shortcutAppPath, Keys.shortcutAppPath) }
    }

    let preview = PreviewModel()

    private let engine: GestureEngine
    private let pipeline: TrackingPipeline
    private let input: InputController
    private let overlay: OverlayController
    private let windowController: MainWindowController
    private var hotKey: GlobalHotKey?
    private var permissionTimer: Timer?

    // MARK: Init

    init() {
        let d = UserDefaults.standard
        _sensitivity = Published(initialValue: Sensitivity(rawValue: d.string(forKey: Keys.sensitivity) ?? "") ?? .medium)
        _pace = Published(initialValue: Pace(rawValue: d.string(forKey: Keys.pace) ?? "") ?? .natural)
        _showOverlay = Published(initialValue: d.object(forKey: Keys.showOverlay) as? Bool ?? true)
        _requirePalm = Published(initialValue: d.object(forKey: Keys.requirePalm) as? Bool ?? true)
        _mirrorCamera = Published(initialValue: d.object(forKey: Keys.mirrorCamera) as? Bool ?? true)
        _reverseSwipe = Published(initialValue: d.bool(forKey: Keys.reverseSwipe))
        _reverseScroll = Published(initialValue: d.bool(forKey: Keys.reverseScroll))
        _shortcutAppPath = Published(initialValue: d.string(forKey: Keys.shortcutAppPath))

        engine = GestureEngine()
        pipeline = TrackingPipeline()
        input = InputController()
        overlay = OverlayController()
        windowController = MainWindowController()

        pipeline.mirror = mirrorCamera
        pipeline.onResult = { [weak self] result in self?.handle(result) }
        windowController.onVisibilityChange = { [weak self] visible in self?.setPreviewVisible(visible) }

        hotKey = GlobalHotKey.optionCommandA { [weak self] in
            Task { @MainActor in self?.toggle() }
        }

        applyConfig()
        refreshPermissions()
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshPermissions() }
        }

        if !d.bool(forKey: Keys.hasLaunchedBefore) {
            d.set(true, forKey: Keys.hasLaunchedBefore)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                Task { @MainActor in self?.showWindow() }
            }
        }
    }

    // MARK: On / off

    func toggle() { setEnabled(!isEnabled) }

    func setEnabled(_ on: Bool) {
        guard on != isEnabled else { return }
        if on {
            cameraError = nil
            accessibilityGranted = Permissions.isAccessibilityGranted(prompt: true)
            switch Permissions.cameraStatus {
            case .authorized:
                startTracking()
            case .notDetermined:
                AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                    Task { @MainActor in
                        guard let self else { return }
                        self.refreshPermissions()
                        if granted { self.startTracking() } else { self.cameraDenied() }
                    }
                }
            default:
                cameraDenied()
            }
        } else {
            stopTracking()
        }
    }

    private func startTracking() {
        do {
            try pipeline.start()
            isEnabled = true
            updateStatus(engine.snapshot)
        } catch {
            cameraError = error.localizedDescription
            isEnabled = false
        }
    }

    private func stopTracking() {
        pipeline.stop()
        engine.reset().forEach(perform)
        isEnabled = false
        overlay.hideAll()
        status = .off
        preview.image = nil
        preview.hands = []
        preview.snapshot = .idle
    }

    private func cameraDenied() {
        cameraError = "Camera access is off. Allow AirTouch in System Settings › Privacy & Security › Camera."
        isEnabled = false
        Permissions.openCameraSettings()
    }

    // MARK: Frame handling

    private func handle(_ result: FrameResult) {
        guard isEnabled else { return }
        engine.process(hands: result.hands, time: result.time).forEach(perform)
        let snapshot = engine.snapshot

        if showOverlay, let pointer = snapshot.pointer, snapshot.handCount > 0 {
            overlay.show(at: screenPoint(pointer), snapshot: snapshot)
        } else {
            overlay.hideRing()
        }

        updateStatus(snapshot)

        if preview.isVisible {
            preview.hands = result.hands
            preview.snapshot = snapshot
            if let image = result.preview { preview.image = image }
        }
    }

    private func perform(_ action: GestureAction) {
        switch action {
        case .engaged:
            toast("🖐 AirTouch active")
        case .paused:
            toast("Paused")
        case .moveCursor(let p):
            input.moveMouse(to: screenPoint(p))
        case .mouseDown(let p, let count):
            input.mouseDown(at: screenPoint(p), clickCount: count)
        case .mouseDrag(let p):
            input.mouseDragged(to: screenPoint(p))
        case .mouseUp(let p, let count):
            input.mouseUp(at: screenPoint(p), clickCount: count)
        case .rightClick(let p):
            input.rightClick(at: screenPoint(p))
        case .scroll(let dx, let dy):
            let sign: Double = reverseScroll ? -1 : 1
            input.scroll(vertical: dy * sign, horizontal: dx * sign)
        case .swipe(let direction):
            switch reverseSwipe ? direction.opposite : direction {
            case .left:
                input.nextDesktop()
                toast("Next desktop →")
            case .right:
                input.previousDesktop()
                toast("← Previous desktop")
            case .up:
                input.missionControl()
                toast("Mission Control")
            case .down:
                input.appExpose()
                toast("App Exposé")
            }
        case .minimize:
            input.minimizeWindow()
            toast("Minimized")
        case .zoom(.zoomIn):
            input.zoomIn()
            toast("Zoom in")
        case .zoom(.zoomOut):
            input.zoomOut()
            toast("Zoom out")
        case .volume(let direction):
            if direction == .up {
                input.volumeUp()
                toast("Volume up")
            } else {
                input.volumeDown()
                toast("Volume down")
            }
        case .playPause:
            input.playPause()
            toast("Play / pause")
        case .navigate(let direction):
            if direction == .back {
                input.goBack()
                toast("Back")
            } else {
                input.goForward()
                toast("Forward")
            }
        case .screenshot(let from, let to):
            input.screenshotRegion(from: screenPoint(from), to: screenPoint(to))
            toast("Screenshot")
        case .shortcut:
            runShortcut()
        }
    }

    private func toast(_ text: String) {
        if showOverlay { overlay.toast(text) }
    }

    private func updateStatus(_ s: EngineSnapshot) {
        let new: StatusSummary
        if !isEnabled {
            new = .off
        } else if !s.engaged {
            new = StatusSummary(
                text: s.handCount > 0 ? "Hand seen: hold 🖐 to start" : "Waiting: raise your hand",
                icon: "hand.raised"
            )
        } else {
            new = StatusSummary(text: "Active: \(s.mode.title)", icon: "hand.raised.fill")
        }
        if new != status { status = new }
    }

    /// Normalized (0...1) → global screen coordinates of the main display.
    private func screenPoint(_ p: CGPoint) -> CGPoint {
        let bounds = CGDisplayBounds(CGMainDisplayID())
        return CGPoint(
            x: bounds.minX + p.x * (bounds.width - 1),
            y: bounds.minY + p.y * (bounds.height - 1)
        )
    }

    // MARK: Shortcut app (🤙)

    var shortcutName: String {
        guard let path = shortcutAppPath else { return "Spotlight" }
        return FileManager.default.displayName(atPath: path).replacingOccurrences(of: ".app", with: "")
    }

    private func runShortcut() {
        if let path = shortcutAppPath, FileManager.default.fileExists(atPath: path) {
            NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: path), configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
        } else {
            input.spotlight()
        }
        toast("🤙 \(shortcutName)")
    }

    func chooseShortcutApp() {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.title = "Choose the app 🤙 opens"
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            shortcutAppPath = url.path
        }
    }

    // MARK: Window & permissions

    func showWindow() {
        windowController.show { MainWindowView(state: self, preview: self.preview) }
    }

    private func setPreviewVisible(_ visible: Bool) {
        preview.isVisible = visible
        pipeline.previewEnabled = visible
        if !visible { preview.image = nil }
    }

    func requestAccessibility() {
        accessibilityGranted = Permissions.isAccessibilityGranted(prompt: true)
        if !accessibilityGranted { Permissions.openAccessibilitySettings() }
    }

    func refreshPermissions() {
        let ax = Permissions.isAccessibilityGranted()
        if ax != accessibilityGranted { accessibilityGranted = ax }
        let cam = Permissions.cameraStatus == .authorized
        if cam != cameraGranted { cameraGranted = cam }
    }

    // MARK: Settings helpers

    private func applyConfig() {
        var config = engine.config
        config.zoneSize = sensitivity.zoneSize
        config.requirePalmToEngage = requirePalm
        config.smoothingMinCutoff = pace.smoothing.minCutoff
        config.smoothingBeta = pace.smoothing.beta
        engine.config = config
        preview.zone = CGRect(
            x: config.zoneCenter.x - config.zoneSize.width / 2,
            y: config.zoneCenter.y - config.zoneSize.height / 2,
            width: config.zoneSize.width,
            height: config.zoneSize.height
        )
    }

    private func save(_ value: Any?, _ key: String) {
        UserDefaults.standard.set(value, forKey: key)
    }
}
