import AppKit
import MicKit
import os
import ServiceManagement
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Set by the menu bar label, which is created at launch and can reach `openWindow`.
    var openMainWindow: (() -> Void)?

    /// QuadCast S colours only last while something keeps sending them, so closing
    /// the window must not quit; the app lives on in the menu bar.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Opening the app again (Finder, Spotlight, Dock) while it runs shows the settings window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows { openMainWindow?() }
        return true
    }
}

@main
struct MicDeckApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var controller = MicController()

    /// Show the window on the very first launch only; afterwards (including at login)
    /// the app starts quietly in the menu bar.
    private static let isFirstLaunch: Bool = {
        let key = "app.hasLaunchedBefore"
        let first = !UserDefaults.standard.bool(forKey: key)
        UserDefaults.standard.set(true, forKey: key)
        return first
    }()

    var body: some Scene {
        Window("MicDeck", id: "main") {
            ContentView()
                .environmentObject(controller)
                .environmentObject(controller.voice)
                .frame(minWidth: 760, minHeight: 560)
        }
        .windowResizability(.contentMinSize)
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 800, height: 600)
        .defaultLaunchBehavior(Self.isFirstLaunch ? .presented : .suppressed)

        Window("Optimise Voice", id: "voice") {
            VoiceOptimiserView()
                .environmentObject(controller)
                .environmentObject(controller.voice)
                .frame(minWidth: 920, minHeight: 640)
        }
        .windowResizability(.contentMinSize)
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 980, height: 700)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)

        MenuBarExtra {
            MenuBarContent().environmentObject(controller)
        } label: {
            MenuBarLabel(appDelegate: appDelegate, controller: controller)
        }
    }
}

struct MenuBarLabel: View {
    let appDelegate: AppDelegate
    @ObservedObject var controller: MicController
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Image(nsImage: MenuBarIcon.image(band: controller.menuBarBand, disconnected: controller.current == nil))
            .renderingMode(.original)
            .onAppear {
                DebugSnapshot.runIfRequested(controller: controller)
                appDelegate.openMainWindow = {
                    openWindow(id: "main")
                    NSApp.activate()
                }
            }
    }
}

struct MenuBarContent: View {
    @EnvironmentObject var c: MicController
    @Environment(\.openWindow) private var openWindow
    @State private var openAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        if let mic = c.current {
            Text(mic.name)
            Text(c.lightingSummary)
        } else {
            Text("No microphone attached")
        }
        if c.features.contains(.rgbLighting) && c.lightingAvailable {
            Toggle("Control lighting", isOn: Binding(get: { c.lightingEnabled }, set: { c.setLightingEnabled($0) }))
        }
        Divider()
        Button("Settings…") {
            openWindow(id: "main")
            NSApp.activate()
        }
        Toggle("Open at Login", isOn: Binding(get: { openAtLogin }, set: { setOpenAtLogin($0) }))
        Divider()
        Button("Quit (lighting returns to the mic's own colours)") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    private func setOpenAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            DebugLog.logger.error("Open at Login failed: \(error, privacy: .public)")
        }
        openAtLogin = SMAppService.mainApp.status == .enabled
        if SMAppService.mainApp.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
    }
}
