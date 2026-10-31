import AppKit
import SwiftUI

/// `ONAIR_SNAPSHOT=/path/out.png` renders the settings window offscreen and quits.
/// Used to check the layout without Screen Recording permission. Debug builds only
/// (`swift run OnAir`): a release build ignores the variable, so nothing outside the app
/// can make it write a file or stop driving the lights.
enum DebugSnapshot {
    /// True when this run only renders a snapshot.
    static var isRequested: Bool {
        #if DEBUG
        ProcessInfo.processInfo.environment["ONAIR_SNAPSHOT"] != nil
        #else
        false
        #endif
    }

    @MainActor static func runIfRequested(controller: MicController) {
        #if DEBUG
        guard let out = ProcessInfo.processInfo.environment["ONAIR_SNAPSHOT"] else { return }
        // Optional "WxH", e.g. ONAIR_SNAPSHOT_SIZE=760x560 to check the minimum size.
        let dims = (ProcessInfo.processInfo.environment["ONAIR_SNAPSHOT_SIZE"] ?? "")
            .split(separator: "x").compactMap { Double($0) }
        let (w, h) = dims.count == 2 ? (dims[0], dims[1]) : (800, 600)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            let view = NSHostingView(rootView: ContentView().environmentObject(controller).frame(width: w, height: h))
            view.frame = NSRect(x: 0, y: 0, width: w, height: h)
            let window = NSWindow(contentRect: view.frame, styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.contentView = view
            window.appearance = NSAppearance(named: .darkAqua)
            view.layoutSubtreeIfNeeded()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                let root = window.contentView!.superview!
                guard let rep = root.bitmapImageRepForCachingDisplay(in: root.bounds) else { exit(1) }
                root.cacheDisplay(in: root.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out))
                exit(0)
            }
        }
        #endif
    }
}
