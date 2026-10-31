import MicKit
import SwiftUI

struct ContentView: View {
    @EnvironmentObject var c: MicController
    @StateObject private var meter = InputLevelMonitor()

    var body: some View {
        VStack(spacing: 0) {
            HeaderBar()
            if c.devices.isEmpty {
                EmptyStateView()
            } else {
                HStack(alignment: .top, spacing: 14) {
                    MixerCard(meter: meter)
                    VStack(spacing: 14) {
                        DeviceInfoCard()
                        if c.features.contains(.polarPattern) { PolarPatternCard() }
                        if c.features.contains(.rgbLighting) { LightingCard() }
                        if c.features.contains(.lowCutFilter) { EffectsCard() }
                        VoiceCard()
                        Spacer(minLength: 0)
                    }
                    .frame(minWidth: 320, maxWidth: .infinity)
                }
                .padding(.horizontal, 16).padding(.bottom, 20).padding(.top, 8)
            }
        }
        .ignoresSafeArea(edges: .top)
        .background(Theme.background.ignoresSafeArea())
        .foregroundStyle(Theme.textPrimary)
        .environment(\.colorScheme, .dark)
        // Start the meter (which may show the microphone permission prompt) only once the window
        // is on screen and focused. A prompt shown while the window is still opening stops it appearing.
        .background(WindowKeyObserver { window in
            windowReady = true
            // When the prompt closes, macOS gives focus back to the app used before it, leaving this
            // window behind. Bring it forward once that hand-back has happened.
            meter.onPermissionAnswered = { [weak window] in
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    guard let window, window.isVisible else { return }
                    NSApp.activate()
                    window.orderFrontRegardless()
                    window.makeKey()
                }
            }
            meter.start(deviceID: c.current?.audio?.id)
        })
        .onDisappear {
            windowReady = false
            meter.stop()
        }
        .onChange(of: c.current?.audio?.id) { _, id in
            if windowReady { meter.start(deviceID: id) }
        }
    }

    @State private var windowReady = false
}

/// Calls `onReady` once its window is visible and key (and again each time it reopens).
private struct WindowKeyObserver: NSViewRepresentable {
    var onReady: (NSWindow) -> Void

    func makeNSView(context: Context) -> ObserverView { ObserverView() }
    func updateNSView(_ view: ObserverView, context: Context) { view.onReady = onReady }

    final class ObserverView: NSView {
        var onReady: ((NSWindow) -> Void)?
        private var observer: NSObjectProtocol?
        private var fired = false

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
            fired = false
            guard let window else { return }
            observer = NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window,
                                                              queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.fireIfReady() }
            }
            // Already key (e.g. reopened while the app was active): wait a turn so it's drawn first.
            DispatchQueue.main.async { [weak self] in self?.fireIfReady() }
        }

        private func fireIfReady() {
            guard !fired, let window, window.isVisible, window.isKeyWindow else { return }
            fired = true
            onReady?(window)
        }

        deinit {
            if let observer { NotificationCenter.default.removeObserver(observer) }
        }
    }
}

// MARK: - Header

private struct HeaderBar: View {
    @EnvironmentObject var c: MicController

    var body: some View {
        HStack(spacing: 12) {
            Text("MicDeck").font(.system(size: 17, weight: .heavy)).tracking(0.5)
            + Text(" for Mac").font(.system(size: 17, weight: .regular)).foregroundColor(Theme.textSecondary)
            Spacer()
            if !c.devices.isEmpty {
                Menu {
                    ForEach(c.devices) { d in
                        Button(d.name) { c.select(d.id) }
                    }
                } label: {
                    HStack(spacing: 8) {
                        Circle().fill(c.current?.audio != nil ? Theme.live : Color.orange)
                            .frame(width: 7, height: 7)
                            .shadow(color: (c.current?.audio != nil ? Theme.live : .orange).opacity(0.8), radius: 4)
                        Image(systemName: "mic.fill").foregroundStyle(Theme.mic)
                        Text(c.current?.name ?? "Microphone").font(.system(size: 13, weight: .semibold))
                        Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.textSecondary)
                    }
                    .padding(.horizontal, 14).frame(height: 32)
                    .background(Capsule().fill(Theme.raised))
                    .overlay(Capsule().strokeBorder(Theme.stroke))
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
            }
        }
        .padding(.leading, 84)      // clear of the window's traffic lights
        .padding(.trailing, 16)
        .padding(.top, 10)
        .padding(.bottom, 4)
    }
}

private struct EmptyStateView: View {
    var body: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle().fill(Theme.panel).frame(width: 96, height: 96)
                    .overlay(Circle().strokeBorder(Theme.stroke))
                Image(systemName: "mic.slash").font(.system(size: 36, weight: .light)).foregroundStyle(Theme.textSecondary)
            }
            Text("Plug in a microphone").font(.system(size: 18, weight: .semibold))
            Text("Works with HyperX QuadCast 2 S, SoloCast 2, SoloCast 2 Pro, FlipCast, QuadCast S, QuadCast and SoloCast.")
                .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center).frame(maxWidth: 360)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
}

// MARK: - Mixer

private struct MixerCard: View {
    @EnvironmentObject var c: MicController
    @ObservedObject var meter: InputLevelMonitor

    var body: some View {
        Card("Mixer") {
            HStack(alignment: .top, spacing: 10) {
                if c.features.contains(.gain) || c.features.contains(.mute) {
                    ChannelStrip(title: "Mic", systemImage: "mic.fill", accent: Theme.mic, width: stripWidth,
                                 valueText: c.features.contains(.gain) ? "\(Int((c.gain * 100).rounded()))%" : "—") {
                        HStack(alignment: .bottom, spacing: 8) {
                            if c.features.contains(.gain) {
                                VerticalFader(value: $c.gain, accent: c.muted ? Theme.textTertiary : Theme.mic,
                                              label: "Microphone gain", onChange: c.gainChanged)
                            } else {
                                Spacer()
                            }
                            LevelMeterView(level: c.muted ? 0 : meter.level, peak: c.muted ? 0 : meter.peak,
                                           dimmed: c.muted || meter.unavailableReason != nil)
                        }
                    } footer: {
                        if c.features.contains(.mute) {
                            MuteButton(muted: c.muted) { c.muted.toggle(); c.mutedChanged() }
                        }
                    }
                    .help(meter.unavailableReason ?? "Drag to set gain. The meter shows the mic's live input.")
                }
                if c.features.contains(.headphoneVolume) {
                    ChannelStrip(title: "Headphones", systemImage: "headphones", accent: Theme.headphones,
                                 valueText: "\(Int((c.headphoneVolume * 100).rounded()))%") {
                        VerticalFader(value: $c.headphoneVolume, accent: Theme.headphones,
                                      label: "Headphone volume", onChange: c.headphoneVolumeChanged)
                    } footer: { EmptyView() }
                }
                if c.features.contains(.monitoringMix) {
                    let center = Double(DeviceCatalog.monitoringMixCenter)
                    let range = DeviceCatalog.monitoringMixRange
                    ChannelStrip(title: "Monitor mix", systemImage: "slider.vertical.3", accent: Theme.mix,
                                 valueText: mixLabel(c.monitoringMix, center: center)) {
                        VStack(spacing: 4) {
                            Text("PLAYBACK").font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.textTertiary)
                            VerticalFader(value: $c.monitoringMix,
                                          range: Double(range.lowerBound)...Double(range.upperBound), step: 1,
                                          accent: Theme.mix, resetValue: center, label: "Monitor mix",
                                          valueText: mixLabel(c.monitoringMix, center: center),
                                          onChange: c.monitoringMixChanged)
                            Text("MIC").font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.textTertiary)
                        }
                    } footer: { EmptyView() }
                }
            }
            // The strips stretch to fill the card; the note keeps its own height below them.
            Group {
                if let reason = meter.unavailableReason {
                    Label(reason, systemImage: "waveform.slash")
                } else if c.current?.hid == nil {
                    Text("Gain and mute go through macOS audio for this mic.")
                }
            }
            .font(.system(size: 11)).foregroundStyle(Theme.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
            .layoutPriority(1)
        }
        .frame(width: CGFloat(stripCount) * stripWidth + CGFloat(stripCount - 1) * 10 + 36)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    /// The card is as wide as the strips it shows; the cards on the right take the rest.
    private var stripCount: Int {
        let f = c.features
        let n = (f.contains(.gain) || f.contains(.mute) ? 1 : 0) + (f.contains(.headphoneVolume) ? 1 : 0)
            + (f.contains(.monitoringMix) ? 1 : 0)
        return max(n, 1)
    }

    /// A lone Mic strip (no headphone jack or monitor mix) is wider, so the card doesn't look cramped.
    private var stripWidth: CGFloat { stripCount == 1 ? 160 : ChannelStrip<EmptyView, EmptyView>.defaultWidth }

    private func mixLabel(_ v: Double, center: Double) -> String {
        let d = Int(v - center)
        return d == 0 ? "Centre" : d < 0 ? "Mic +\(-d)" : "Play +\(d)"
    }
}

private struct ChannelStrip<Body: View, Footer: View>: View {
    let title: String
    let systemImage: String
    let accent: Color
    let valueText: String
    var width: CGFloat
    @ViewBuilder var content: Body
    @ViewBuilder var footer: Footer

    static var defaultWidth: CGFloat { 112 }

    init(title: String, systemImage: String, accent: Color, width: CGFloat = defaultWidth, valueText: String,
         @ViewBuilder content: () -> Body, @ViewBuilder footer: () -> Footer) {
        self.title = title; self.systemImage = systemImage; self.accent = accent; self.width = width
        self.valueText = valueText
        self.content = content(); self.footer = footer()
    }

    var body: some View {
        VStack(spacing: 12) {
            ZStack {
                Circle().fill(accent.opacity(0.16)).frame(width: 40, height: 40)
                Image(systemName: systemImage).font(.system(size: 16, weight: .semibold)).foregroundStyle(accent)
            }
            Text(title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
            content.frame(minHeight: 140, maxHeight: .infinity)
            Text(valueText)
                .font(.system(size: 13, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(Theme.textSecondary)
            footer
        }
        .padding(.vertical, 14).padding(.horizontal, 12)
        .frame(width: width)
        .frame(maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.raised.opacity(0.6)))
        .overlay(alignment: .top) {
            Capsule().fill(accent).frame(width: 28, height: 3).padding(.top, 1)
        }
    }
}

// MARK: - Polar pattern

private struct PolarPatternCard: View {
    @EnvironmentObject var c: MicController

    var body: some View {
        Card("Pickup pattern") {
            HStack(spacing: 8) {
                ForEach(PolarPattern.uiOrder) { p in
                    let on = c.polarPattern == p
                    Button {
                        guard !on else { return }
                        c.polarPattern = p
                        c.polarPatternChanged()
                    } label: {
                        VStack(spacing: 6) {
                            PolarShape(pattern: p)
                                .stroke(on ? Theme.mic : Theme.textSecondary, lineWidth: 1.8)
                                .background(PolarShape(pattern: p).fill(on ? Theme.mic.opacity(0.18) : .clear))
                                .frame(width: 30, height: 30)
                            Text(p.displayName).font(.system(size: 10, weight: .semibold)).lineLimit(1)
                                .minimumScaleFactor(0.8)
                        }
                        .frame(maxWidth: .infinity).frame(height: 64)
                        .foregroundStyle(on ? Theme.textPrimary : Theme.textSecondary)
                        .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(on ? Theme.mic.opacity(0.12) : Theme.raised))
                        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(on ? Theme.mic.opacity(0.7) : Theme.stroke))
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
            }
        }
    }
}

/// Polar plot of the pickup pattern, mic facing up.
private struct PolarShape: Shape {
    let pattern: PolarPattern

    func path(in rect: CGRect) -> Path {
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let r = min(rect.width, rect.height) / 2
        func plot(_ gain: (Double) -> Double) -> Path {
            var p = Path()
            for i in 0...120 {
                let th = Double(i) / 120 * 2 * .pi
                let g = gain(th) * r
                let pt = CGPoint(x: c.x + g * sin(th), y: c.y - g * cos(th))
                i == 0 ? p.move(to: pt) : p.addLine(to: pt)
            }
            p.closeSubpath()
            return p
        }
        switch pattern {
        case .cardioid: return plot { 0.5 * (1 + cos($0)) }.offsetBy(dx: 0, dy: r * 0.25)
        case .omnidirectional: return plot { _ in 0.85 }
        case .bidirectional: return plot { abs(cos($0)) }
        case .stereo:
            var p = Path()
            p.addPath(plot { th in 0.5 * (1 + cos(th + .pi / 4)) * 0.8 })
            p.addPath(plot { th in 0.5 * (1 + cos(th - .pi / 4)) * 0.8 })
            return p.offsetBy(dx: 0, dy: r * 0.15)
        }
    }
}

// MARK: - Lighting

private struct LightingCard: View {
    @EnvironmentObject var c: MicController

    private static let presets: [(Color, Color)] = [
        (Color(red: 1, green: 0.1, blue: 0.1), Color(red: 1, green: 0.1, blue: 0.1)),
        (Color(red: 1, green: 0.18, blue: 0.58), Color(red: 0.45, green: 0.2, blue: 1)),
        (Color(red: 0.2, green: 0.8, blue: 1), Color(red: 0.1, green: 0.2, blue: 1)),
        (Color(red: 0.2, green: 1, blue: 0.5), Color(red: 0, green: 0.6, blue: 0.9)),
        (Color(red: 1, green: 0.55, blue: 0.1), Color(red: 1, green: 0.1, blue: 0.3)),
        (Color.white, Color.white),
    ]

    var body: some View {
        Card("Lighting", trailing: AnyView(
            Toggle("Lighting", isOn: Binding(get: { c.lightingEnabled }, set: { c.setLightingEnabled($0) }))
                .toggleStyle(.switch).tint(Theme.mic).labelsHidden().controlSize(.small)
                .disabled(!c.lightingAvailable)
        )) {
            HStack(alignment: .top, spacing: 16) {
                CapsulePreview(top: c.topColor, bottom: c.linkColors ? c.topColor : c.bottomColor,
                               brightness: c.brightness, on: c.lightingEnabled)
                    .frame(width: 54, height: 112)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 10) {
                        colorWell(c.linkColors ? "Colour" : "Top", $c.topColor)
                        if !c.linkColors { colorWell("Bottom", $c.bottomColor) }
                        Spacer(minLength: 0)
                    }
                    HStack(spacing: 7) {
                        ForEach(Self.presets.indices, id: \.self) { i in
                            let (t, b) = Self.presets[i]
                            Button {
                                c.topColor = t
                                c.bottomColor = b
                                c.lightingChanged()
                            } label: {
                                Circle()
                                    .fill(LinearGradient(colors: [t, b], startPoint: .top, endPoint: .bottom))
                                    .frame(width: 22, height: 22)
                                    .overlay(Circle().strokeBorder(Color.white.opacity(0.2)))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Colour preset \(i + 1)")
                        }
                    }
                    HStack(spacing: 8) {
                        Image(systemName: "sun.min").font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                        ThinSlider(value: $c.brightness, accent: Theme.mic, label: "Brightness", onChange: c.lightingChanged)
                        Image(systemName: "sun.max.fill").font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                    }
                    ChipToggle(title: "Same colour", systemImage: "link", isOn: $c.linkColors,
                               onChange: c.lightingChanged)
                }
                .disabled(!c.lightingEnabled)
                .opacity(c.lightingEnabled ? 1 : 0.45)
            }

            VStack(alignment: .leading, spacing: 6) {
                if !c.lightingAvailable {
                    Label(c.lightingStatus ?? "Lighting interface not reachable", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(Color.orange)
                } else if let status = c.lightingStatus {
                    Text(status)
                }
                HStack(alignment: .firstTextBaseline) {
                    Text("Colours stay while MicDeck runs in the menu bar.")
                    Spacer()
                    #if DEBUG
                    // Hidden in release builds: the save sequence isn't reliable enough to ship.
                    Button("Save to mic (experimental)") { c.saveLighting() }
                        .buttonStyle(.plain).foregroundStyle(Theme.textSecondary).underline()
                        .disabled(!c.lightingEnabled || !c.lightingAvailable)
                    #endif
                }
            }
            .font(.system(size: 11)).foregroundStyle(Theme.textTertiary)
        }
    }

    private func colorWell(_ title: String, _ binding: Binding<Color>) -> some View {
        HStack(spacing: 6) {
            ColorPicker(title, selection: binding, supportsOpacity: false)
                .labelsHidden()
                .onChange(of: binding.wrappedValue) { c.lightingChanged() }
            Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.textSecondary)
        }
        .padding(.leading, 4).padding(.trailing, 10).frame(height: 32)
        .background(Capsule().fill(Theme.raised))
    }
}

/// The mic's two-zone light, rendered as a glowing capsule.
private struct CapsulePreview: View {
    let top: Color
    let bottom: Color
    let brightness: Double
    let on: Bool

    var body: some View {
        let b = on ? max(brightness, 0.08) : 0
        ZStack {
            Capsule().fill(Color.black.opacity(0.6))
            Capsule()
                .fill(LinearGradient(stops: [.init(color: top, location: 0.15), .init(color: top, location: 0.48),
                                             .init(color: bottom, location: 0.52), .init(color: bottom, location: 0.95)],
                                     startPoint: .top, endPoint: .bottom))
                .opacity(b)
                .blur(radius: 1)
            // Grille
            VStack(spacing: 5) {
                ForEach(0..<9) { _ in Capsule().fill(Color.black.opacity(0.22)).frame(height: 1.5) }
            }
            .padding(.horizontal, 10)
            Capsule().strokeBorder(Color.white.opacity(0.15), lineWidth: 1.5)
        }
        .shadow(color: top.opacity(0.6 * b), radius: 14, y: -10)
        .shadow(color: bottom.opacity(0.6 * b), radius: 14, y: 10)
        .animation(.easeOut(duration: 0.2), value: on)
    }
}

// MARK: - Effects / info

private struct EffectsCard: View {
    @EnvironmentObject var c: MicController
    var body: some View {
        Card("Effects") {
            HStack {
                ChipToggle(title: "Low-cut filter", systemImage: "waveform.path.ecg", isOn: $c.lowCut,
                           onChange: c.lowCutChanged)
                Spacer()
            }
        }
    }
}

private struct DeviceInfoCard: View {
    @EnvironmentObject var c: MicController
    var body: some View {
        Card("Device") {
            VStack(alignment: .leading, spacing: 6) {
                row("Audio device", c.current?.audio?.name ?? "not found")
                row("Hardware controls", c.current?.hid != nil ? "Connected" : "Via macOS audio")
            }
        }
    }
    private func row(_ k: String, _ v: String) -> some View {
        HStack {
            Text(k).foregroundStyle(Theme.textSecondary)
            Spacer()
            Text(v)
        }
        .font(.system(size: 12))
    }
}
