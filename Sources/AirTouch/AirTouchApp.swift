import AirTouchCore
import SwiftUI

@main
struct AirTouchApp: App {
    @StateObject private var state = AppState()

    var body: some Scene {
        MenuBarExtra {
            MenuContent(state: state)
        } label: {
            Image(systemName: state.status.icon)
        }
        .menuBarExtraStyle(.menu)
    }
}

struct MenuContent: View {
    @ObservedObject var state: AppState

    var body: some View {
        Button(state.isEnabled ? "Turn AirTouch Off   ⌥⌘A" : "Turn AirTouch On   ⌥⌘A") {
            state.toggle()
        }

        Text(state.status.text)

        if !state.accessibilityGranted {
            Button("⚠️ Grant Accessibility Access…") { state.requestAccessibility() }
        }
        if let error = state.cameraError {
            Text("⚠️ \(error)")
        }

        Divider()

        Button("Open AirTouch Window…") { state.showWindow() }
        Button("Gesture Guide…") { state.showGuide() }

        Divider()

        Picker("Sensitivity", selection: $state.sensitivity) {
            ForEach(Sensitivity.allCases) { level in
                Text(level.title).tag(level)
            }
        }

        Picker("Pace", selection: $state.pace) {
            ForEach(Pace.allCases) { level in
                Text(level.title).tag(level)
            }
        }

        Toggle("Show Cursor Ring", isOn: $state.showOverlay)
        Toggle("Draw in Black Ink", isOn: $state.darkInk)
        Toggle("Require 🖐 Palm to Start", isOn: $state.requirePalm)

        Menu("Directions") {
            Toggle("Reverse Swipe Direction", isOn: $state.reverseSwipe)
            Toggle("Reverse Scroll Direction", isOn: $state.reverseScroll)
            Toggle("Mirror Camera", isOn: $state.mirrorCamera)
        }

        Menu("🤙 Shaka Opens: \(state.shortcutName)") {
            Button("Spotlight") { state.shortcutAppPath = nil }
            Button("Choose App…") { state.chooseShortcutApp() }
        }

        Divider()

        Button("Quit AirTouch") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }
}
