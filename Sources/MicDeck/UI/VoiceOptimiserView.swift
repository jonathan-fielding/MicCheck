import MicKit
import SwiftUI

/// The "Optimise voice" window: install the driver → record → analyse → tweak → apply.
struct VoiceOptimiserView: View {
    @EnvironmentObject var c: MicController
    @EnvironmentObject var voice: VoiceController
    @StateObject private var session = VoiceTuningSession()

    var body: some View {
        VStack(spacing: 0) {
            header
            Group {
                if !voice.driverInstalled && !Self.debugTake {
                    InstallDriverStep()
                } else {
                    switch session.step {
                    case .intro: IntroStep()
                    case .recording: RecordingStep()
                    case .analysing: AnalysingStep()
                    case .tune: TuneStep()
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .environmentObject(session)
        .environmentObject(session.recorder)
        .environmentObject(session.player)
        .ignoresSafeArea(edges: .top)
        .background(Theme.background.ignoresSafeArea())
        .foregroundStyle(Theme.textPrimary)
        .environment(\.colorScheme, .dark)
        .onDisappear { session.close() }
        // A take belongs to the mic it was recorded on; a different mic starts over.
        .onChange(of: c.current?.model?.name ?? c.current?.audio?.name) { session.startOver() }
        .onAppear {
            #if DEBUG
            if DebugSnapshot.isRequested, let path = ProcessInfo.processInfo.environment["MICDECK_SNAPSHOT_TAKE"] {
                session.debugLoad(path: path, hardware: c.hardwareState)
            }
            #endif
        }
    }

    /// Snapshot runs with MICDECK_SNAPSHOT_TAKE skip the install step.
    private static var debugTake: Bool {
        DebugSnapshot.isRequested && ProcessInfo.processInfo.environment["MICDECK_SNAPSHOT_TAKE"] != nil
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text("Optimise voice").font(.system(size: 17, weight: .heavy)).tracking(0.5)
            Spacer()
            if let mic = c.current {
                Label(mic.name, systemImage: "mic.fill")
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.textSecondary)
            }
        }
        .padding(.leading, 84).padding(.trailing, 16).padding(.top, 10).padding(.bottom, 8)
    }
}

// MARK: - Install

private struct InstallDriverStep: View {
    @EnvironmentObject var voice: VoiceController

    var body: some View {
        VStack(spacing: 18) {
            ZStack {
                Circle().fill(Theme.panel).frame(width: 96, height: 96).overlay(Circle().strokeBorder(Theme.stroke))
                Image(systemName: "puzzlepiece.extension").font(.system(size: 36, weight: .light)).foregroundStyle(Theme.mic)
            }
            Text("Install MicDeck Audio first").font(.system(size: 20, weight: .semibold))
            Text("Voice optimisation runs through a virtual microphone called “MicDeck Microphone”. Apps like Zoom, Discord and OBS record from it, and MicDeck fills it with your mic’s audio after EQ, compression and noise reduction.")
                .font(.system(size: 13)).foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center).frame(maxWidth: 520)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 10) {
                step(1, "Download and open the MicDeck Audio installer.")
                step(2, "Follow the installer. It asks for your password because audio drivers are installed for the whole Mac.")
                step(3, "Come back here. MicDeck notices the driver straight away, with no restart needed.")
            }
            .padding(18)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.panel))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.stroke))
            .frame(maxWidth: 520)

            if let url = voice.driverDownloadURL {
                Link(destination: url) {
                    Label("Download MicDeck Audio", systemImage: "arrow.down.circle.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .padding(.horizontal, 18).frame(height: 36)
                        .background(Capsule().fill(Theme.mic))
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
            } else {
                Text("Install MicDeckAudio.pkg (built with ./build-driver.sh).")
                    .font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.textTertiary)
            }
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Waiting for MicDeck Audio…").font(.system(size: 12)).foregroundStyle(Theme.textTertiary)
            }
        }
        .padding(40)
    }

    private func step(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(n)").font(.system(size: 12, weight: .bold, design: .rounded))
                .frame(width: 20, height: 20).background(Circle().fill(Theme.raised))
            Text(text).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Intro

private struct IntroStep: View {
    @EnvironmentObject var c: MicController
    @EnvironmentObject var session: VoiceTuningSession

    var body: some View {
        VStack(spacing: 20) {
            Text("Record a short test").font(.system(size: 22, weight: .semibold))
            Text("Use the mic the way you normally do: same distance, same room, same gain. It takes about 15 seconds.")
                .font(.system(size: 13)).foregroundStyle(Theme.textSecondary).multilineTextAlignment(.center)
                .frame(maxWidth: 520)

            HStack(alignment: .top, spacing: 14) {
                IntroTile(icon: "speaker.slash", title: "Stay quiet", detail: "\(Int(VoiceScript.quietSeconds.rounded())) seconds, so we can hear your room.")
                IntroTile(icon: "text.quote", title: "Read the sentence", detail: "At your normal speaking volume.")
                IntroTile(icon: "megaphone", title: "Then say it loud", detail: "“\(VoiceScript.loudLine)”, the way you would on stream.")
            }
            .frame(maxWidth: 720)

            ScriptView(size: 18).frame(maxWidth: 640)

            if let e = session.error {
                Label(e, systemImage: "exclamationmark.triangle.fill").font(.system(size: 12)).foregroundStyle(.orange)
            }
            Button {
                session.startRecording(deviceID: c.current?.audio?.id)
            } label: {
                Label("Start recording", systemImage: "record.circle")
                    .font(.system(size: 14, weight: .semibold))
                    .padding(.horizontal, 22).frame(height: 40)
                    .background(Capsule().fill(Theme.mic))
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .disabled(c.current?.audio == nil)
            .keyboardShortcut(.defaultAction)
        }
        .padding(32)
    }
}

private struct IntroTile: View {
    let icon: String, title: String, detail: String
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: icon).font(.system(size: 18)).foregroundStyle(Theme.mic)
            Text(title).font(.system(size: 13, weight: .semibold))
            Text(detail).font(.system(size: 12)).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.panel))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.stroke))
    }
}

private struct ScriptView: View {
    var size: CGFloat
    var dimmed = false
    var body: some View {
        VStack(spacing: 10) {
            Text("“\(VoiceScript.sentence)”")
                .font(.system(size: size, weight: .medium, design: .serif))
                .multilineTextAlignment(.center)
            Text("“\(VoiceScript.loudLine)”")
                .font(.system(size: size * 1.15, weight: .heavy))
                .foregroundStyle(Theme.mic)
        }
        .opacity(dimmed ? 0.35 : 1)
        .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Recording

private struct RecordingStep: View {
    @EnvironmentObject var c: MicController
    @EnvironmentObject var session: VoiceTuningSession
    @EnvironmentObject var recorder: VoiceRecorder

    var body: some View {
        VStack(spacing: 26) {
            Spacer()
            if recorder.phase == .quiet {
                ZStack {
                    Circle().stroke(Theme.raised, lineWidth: 6)
                    Circle().trim(from: 0, to: 1 - recorder.quietRemaining / VoiceScript.quietSeconds)
                        .stroke(Theme.mic, style: StrokeStyle(lineWidth: 6, lineCap: .round)).rotationEffect(.degrees(-90))
                    Text("\(Int(recorder.quietRemaining.rounded(.up)))").font(.system(size: 34, weight: .bold, design: .rounded))
                }
                .frame(width: 96, height: 96)
                Text("Stay quiet. Listening to your room…").font(.system(size: 18, weight: .semibold))
                ScriptView(size: 22, dimmed: true).frame(maxWidth: 680)
            } else {
                HStack(spacing: 8) {
                    Circle().fill(Theme.muteRed).frame(width: 10, height: 10).shadow(color: Theme.muteRed, radius: 5)
                    Text("Recording, read aloud").font(.system(size: 14, weight: .semibold))
                    Text(String(format: "%.0fs", recorder.speakingElapsed)).monospacedDigit().foregroundStyle(Theme.textSecondary)
                }
                ScriptView(size: 24).frame(maxWidth: 700)
            }
            HorizontalMeter(level: recorder.level).frame(width: 320, height: 8)
            Spacer()
            HStack(spacing: 12) {
                Button("Cancel") { session.cancelRecording() }
                    .buttonStyle(.plain).foregroundStyle(Theme.textSecondary)
                    .keyboardShortcut(.cancelAction)
                Button {
                    session.finishRecording(hardware: c.hardwareState)
                } label: {
                    Label("Done", systemImage: "stop.circle.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .padding(.horizontal, 22).frame(height: 40)
                        .background(Capsule().fill(recorder.phase == .speaking ? Theme.mic : Theme.raised))
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .disabled(recorder.phase != .speaking)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.bottom, 30)
        }
        .padding(.horizontal, 32)
    }
}

private struct AnalysingStep: View {
    var body: some View {
        VStack(spacing: 14) {
            ProgressView().controlSize(.large)
            Text("Listening back…").font(.system(size: 15, weight: .semibold))
        }
    }
}

// MARK: - Tune

private struct TuneStep: View {
    @EnvironmentObject var session: VoiceTuningSession

    var body: some View {
        VStack(spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                VStack(spacing: 12) {
                    Card("Tone", trailing: AnyView(EQLegend())) {
                        EQChartView(settings: $session.draft, spectrum: spectrum, selected: $session.selectedBand)
                            .frame(minHeight: 200)
                        BandInspector()
                    }
                    NotesCard()
                }
                .frame(maxWidth: .infinity)
                ScrollView { DynamicsPanel() }
                    .frame(width: 300)
                    .scrollIndicators(.never)
            }
            TransportBar()
        }
        .padding(.horizontal, 16).padding(.bottom, 16).padding(.top, 4)
    }

    private var spectrum: [(Double, Double)] {
        guard let a = session.analysis else { return [] }
        return Array(zip(a.bandFrequencies, a.spectrumDB))
    }
}

private struct EQLegend: View {
    var body: some View {
        HStack(spacing: 12) {
            legend(Theme.textTertiary, "Your voice")
            legend(Theme.mic, "After EQ")
            legend(.white, "EQ")
        }
        .font(.system(size: 10, weight: .medium)).foregroundStyle(Theme.textSecondary)
    }
    private func legend(_ color: Color, _ label: String) -> some View {
        HStack(spacing: 4) { Capsule().fill(color).frame(width: 12, height: 3); Text(label) }
    }
}

/// Spectrum of the take, the EQ curve, and the voice after EQ. Drag a band's dot to move it.
struct EQChartView: View {
    @Binding var settings: VoiceSettings
    var spectrum: [(Double, Double)]
    @Binding var selected: Int?
    @State private var dragging: Int?

    private let fMin = 30.0, fMax = 16000.0, dbMin = -18.0, dbMax = 15.0
    static let bandColors: [Color] = [
        Color(red: 1.0, green: 0.55, blue: 0.2), Color(red: 1.0, green: 0.82, blue: 0.25), Theme.live,
        Theme.headphones, Theme.mix,
    ]

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            ZStack {
                Canvas { ctx, sz in draw(&ctx, sz) }
                ForEach(settings.bands) { band in
                    let on = selected == band.id
                    Circle()
                        .fill(Self.bandColors[band.id % Self.bandColors.count])
                        .frame(width: on ? 16 : 12, height: on ? 16 : 12)
                        .overlay(Circle().strokeBorder(Color.white.opacity(on ? 0.9 : 0.4), lineWidth: 2))
                        .shadow(color: .black.opacity(0.5), radius: 2)
                        .position(x: x(band.frequency, size.width), y: y(band.gainDB, size.height))
                        .accessibilityElement()
                        .accessibilityLabel("\(band.role.name) band")
                        .accessibilityValue("\(VoiceFormat.hz(band.frequency)), \(VoiceFormat.db(band.gainDB))")
                        .accessibilityAdjustableAction { dir in
                            settings.bands[band.id].gainDB = min(max(band.gainDB + (dir == .increment ? 0.5 : -0.5), -12), 12)
                        }
                }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                if dragging == nil {
                    dragging = nearest(to: g.startLocation, size)
                    selected = dragging
                }
                guard let i = dragging else { return }
                let r = settings.bands[i].role.range
                settings.bands[i].frequency = min(max(freq(g.location.x, size.width), r.lowerBound), r.upperBound).rounded()
                settings.bands[i].gainDB = (min(max(db(g.location.y, size.height), -12), 12) * 2).rounded() / 2
            }.onEnded { _ in dragging = nil })
            .simultaneousGesture(TapGesture(count: 2).onEnded {
                if let i = selected { settings.bands[i].gainDB = 0 }
            })
        }
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.black.opacity(0.25)))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func x(_ f: Double, _ w: CGFloat) -> CGFloat { CGFloat(log(f / fMin) / log(fMax / fMin)) * w }
    private func freq(_ x: CGFloat, _ w: CGFloat) -> Double { fMin * pow(fMax / fMin, Double(x / max(w, 1))) }
    private func y(_ d: Double, _ h: CGFloat) -> CGFloat { CGFloat((dbMax - d) / (dbMax - dbMin)) * h }
    private func db(_ y: CGFloat, _ h: CGFloat) -> Double { dbMax - Double(y / max(h, 1)) * (dbMax - dbMin) }

    private func nearest(to p: CGPoint, _ size: CGSize) -> Int? {
        let d = settings.bands.map { b in hypot(x(b.frequency, size.width) - p.x, y(b.gainDB, size.height) - p.y) }
        guard let m = d.min(), m < 28, let i = d.firstIndex(of: m) else { return nil }
        return settings.bands[i].id
    }

    private func draw(_ ctx: inout GraphicsContext, _ size: CGSize) {
        let w = size.width, h = size.height
        // Grid
        for f in [50.0, 100, 200, 500, 1000, 2000, 5000, 10000] {
            var p = Path(); p.move(to: CGPoint(x: x(f, w), y: 0)); p.addLine(to: CGPoint(x: x(f, w), y: h))
            ctx.stroke(p, with: .color(.white.opacity(0.05)))
            ctx.draw(Text(VoiceFormat.hzShort(f)).font(.system(size: 9)).foregroundStyle(Color.white.opacity(0.3)),
                     at: CGPoint(x: x(f, w) + 2, y: h - 8), anchor: .leading)
        }
        for d in stride(from: -12.0, through: 12, by: 6) {
            var p = Path(); p.move(to: CGPoint(x: 0, y: y(d, h))); p.addLine(to: CGPoint(x: w, y: y(d, h)))
            ctx.stroke(p, with: .color(.white.opacity(d == 0 ? 0.14 : 0.05)))
            if d != 0 {
                ctx.draw(Text("\(d > 0 ? "+" : "")\(Int(d))").font(.system(size: 9)).foregroundStyle(Color.white.opacity(0.3)),
                         at: CGPoint(x: 4, y: y(d, h) - 6), anchor: .leading)
            }
        }

        // The take's spectrum, placed so its loudest band sits near +6 dB on the chart.
        let pts = spectrum.filter { $0.0 >= fMin && $0.0 <= fMax }
        if let top = pts.map(\.1).max() {
            let shift = 6 - top
            var area = Path()
            area.move(to: CGPoint(x: x(pts[0].0, w), y: h))
            for (f, d) in pts { area.addLine(to: CGPoint(x: x(f, w), y: y(max(d + shift, dbMin), h))) }
            area.addLine(to: CGPoint(x: x(pts.last!.0, w), y: h))
            area.closeSubpath()
            ctx.fill(area, with: .color(.white.opacity(0.07)))

            var after = Path()
            for (i, (f, d)) in pts.enumerated() {
                let pt = CGPoint(x: x(f, w), y: y(max(d + shift + settings.eqResponseDB(at: f), dbMin), h))
                i == 0 ? after.move(to: pt) : after.addLine(to: pt)
            }
            ctx.stroke(after, with: .color(Theme.mic.opacity(0.85)), lineWidth: 1.5)
        }

        // EQ response
        var curve = Path()
        let steps = 160
        for i in 0...steps {
            let f = fMin * pow(fMax / fMin, Double(i) / Double(steps))
            let pt = CGPoint(x: x(f, w), y: y(max(settings.eqResponseDB(at: f), dbMin), h))
            i == 0 ? curve.move(to: pt) : curve.addLine(to: pt)
        }
        ctx.stroke(curve, with: .color(.white.opacity(0.9)), lineWidth: 2)
    }
}

/// Details for the selected band (or a hint when none is selected).
private struct BandInspector: View {
    @EnvironmentObject var session: VoiceTuningSession

    var body: some View {
        HStack(spacing: 14) {
            if let i = session.selectedBand, session.draft.bands.indices.contains(i) {
                let band = session.draft.bands[i]
                Circle().fill(EQChartView.bandColors[i % EQChartView.bandColors.count]).frame(width: 9, height: 9)
                Text(band.role.name).font(.system(size: 12, weight: .semibold)).frame(width: 66, alignment: .leading)
                Text(VoiceFormat.hz(band.frequency)).monospacedDigit().frame(width: 64, alignment: .leading)
                Text(VoiceFormat.db(band.gainDB)).monospacedDigit().frame(width: 56, alignment: .leading)
                if band.kind == .peak {
                    Text("Width").foregroundStyle(Theme.textSecondary)
                    // Q 0.5 (wide) … 4 (narrow), shown left = narrow so dragging right widens.
                    ThinSlider(value: Binding(get: { 1 - (min(max(band.q, 0.5), 4) - 0.5) / 3.5 },
                                              set: { session.draft.bands[i].q = ((1 - $0) * 3.5 + 0.5).rounded(toPlaces: 2) }),
                               accent: EQChartView.bandColors[i % EQChartView.bandColors.count], label: "Band width")
                } else {
                    Spacer()
                }
                Button("Reset") { session.draft.bands[i].gainDB = 0 }
                    .buttonStyle(.plain).foregroundStyle(Theme.textSecondary).underline()
            } else {
                Text("Drag a dot to shape your tone. Double-click resets it.")
                    .foregroundStyle(Theme.textTertiary)
                Spacer()
            }
        }
        .font(.system(size: 12))
        .frame(height: 22)
    }
}

private struct NotesCard: View {
    @EnvironmentObject var c: MicController
    @EnvironmentObject var session: VoiceTuningSession

    var body: some View {
        Card("What we heard") {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if session.hardwareChanged {
                        NoteRow(icon: "arrow.clockwise.circle.fill", color: Theme.headphones, title: "Mic settings changed",
                                detail: "Record again so the suggestions match how the mic sounds now.") {
                            Button("Record again") { session.startRecording(deviceID: c.current?.audio?.id) }
                        }
                    }
                    ForEach(session.notes) { note in
                        NoteRow(icon: icon(note.kind), color: color(note.kind), title: note.title, detail: note.detail) {
                            if let action = note.action {
                                Button(actionTitle(action)) {
                                    c.perform(action)
                                    session.markHardwareChanged(note.id)
                                }
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.automatic)
        }
        .frame(maxHeight: .infinity)
    }

    private func icon(_ k: VoiceNote.Kind) -> String {
        switch k {
        case .good: "checkmark.circle.fill"
        case .change: "slider.horizontal.3"
        case .warning: "exclamationmark.triangle.fill"
        case .tip: "lightbulb.fill"
        }
    }
    private func color(_ k: VoiceNote.Kind) -> Color {
        switch k {
        case .good: Theme.live
        case .change: Theme.mic
        case .warning: .orange
        case .tip: Color(red: 1, green: 0.82, blue: 0.25)
        }
    }
    private func actionTitle(_ a: VoiceNote.Action) -> String {
        switch a {
        case .adjustHardwareGain(let db): db < 0 ? "Turn gain down \(Int(-db)) dB" : "Turn gain up \(Int(db)) dB"
        case .enableLowCut: "Turn on low-cut"
        case .useCardioid: "Switch to cardioid"
        }
    }
}

private struct NoteRow<Accessory: View>: View {
    let icon: String, color: Color, title: String, detail: String
    @ViewBuilder var accessory: Accessory

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).foregroundStyle(color).font(.system(size: 13)).frame(width: 16)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 12, weight: .semibold))
                Text(detail).font(.system(size: 11)).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
                accessory.font(.system(size: 11, weight: .semibold)).buttonStyle(.link)
            }
        }
    }
}

// MARK: - Dynamics

private struct DynamicsPanel: View {
    @EnvironmentObject var session: VoiceTuningSession

    var body: some View {
        VStack(spacing: 12) {
            Card("Clean up") {
                Section(title: "Rumble filter", isOn: $session.draft.highPassEnabled) {
                    ParamSlider(value: $session.draft.highPassFrequency, range: 40...200, text: VoiceFormat.hz(session.draft.highPassFrequency), label: "Rumble filter frequency")
                }
                Section(title: "Noise gate", isOn: $session.draft.gateEnabled) {
                    ParamSlider(value: $session.draft.gateThresholdDB, range: -80...(-25), step: 1,
                                text: "Opens at \(VoiceFormat.db(session.draft.gateThresholdDB))", label: "Noise gate threshold")
                }
            }
            Card("Dynamics") {
                Section(title: "De-esser", isOn: $session.draft.deEsserEnabled) {
                    ParamSlider(value: $session.draft.deEsserThresholdDB, range: -60...(-10), step: 1, invert: true,
                                text: "Strength", label: "De-esser strength")
                    ParamSlider(value: $session.draft.deEsserFrequency, range: 4000...10000, step: 100,
                                text: VoiceFormat.hz(session.draft.deEsserFrequency), label: "De-esser frequency")
                }
                Section(title: "Compressor", isOn: $session.draft.compressorEnabled) {
                    ParamSlider(value: $session.draft.compressorThresholdDB, range: -50...(-6), step: 1,
                                text: "Threshold \(VoiceFormat.db(session.draft.compressorThresholdDB))", label: "Compressor threshold")
                    ParamSlider(value: $session.draft.compressorRatio, range: 1.5...8, step: 0.5,
                                text: String(format: "Ratio %g:1", session.draft.compressorRatio), label: "Compressor ratio")
                }
                Section(title: "Output level", isOn: nil) {
                    ParamSlider(value: $session.draft.outputGainDB, range: -12...18, step: 0.5,
                                text: VoiceFormat.db(session.draft.outputGainDB), label: "Output gain")
                }
                Section(title: "Limiter at −1 dB", isOn: $session.draft.limiterEnabled) { EmptyView() }
            }
        }
    }
}

private struct Section<Content: View>: View {
    let title: String
    var isOn: Binding<Bool>?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(.system(size: 12, weight: .semibold))
                Spacer()
                if let isOn {
                    Toggle(title, isOn: isOn).toggleStyle(.switch).tint(Theme.mic).labelsHidden().controlSize(.mini)
                }
            }
            content
                .disabled(isOn.map { !$0.wrappedValue } ?? false)
                .opacity(isOn.map { $0.wrappedValue ? 1 : 0.4 } ?? 1)
        }
    }
}

/// ThinSlider over an arbitrary range, with a caption.
private struct ParamSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double = 1
    var invert = false
    let text: String
    let label: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ThinSlider(value: Binding(get: {
                let t = (value - range.lowerBound) / (range.upperBound - range.lowerBound)
                return invert ? 1 - t : t
            }, set: { t in
                let u = invert ? 1 - t : t
                value = ((range.lowerBound + u * (range.upperBound - range.lowerBound)) / step).rounded() * step
            }), accent: Theme.mic, label: label)
            Text(text).font(.system(size: 10)).foregroundStyle(Theme.textSecondary).monospacedDigit()
        }
    }
}

// MARK: - Transport

private struct TransportBar: View {
    @EnvironmentObject var c: MicController
    @EnvironmentObject var voice: VoiceController
    @EnvironmentObject var session: VoiceTuningSession
    @EnvironmentObject var player: PreviewPlayer

    var body: some View {
        VStack(spacing: 8) {
            if let msg = session.appliedMessage {
                Label(msg, systemImage: "checkmark.seal.fill")
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.live)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: 12) {
                Button { player.toggle() } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 15, weight: .bold))
                        .frame(width: 40, height: 40)
                        .background(Circle().fill(Theme.raised))
                        .overlay(Circle().strokeBorder(Theme.stroke))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.space, modifiers: [])
                .accessibilityLabel(player.isPlaying ? "Pause" : "Play")

                ABSwitch(optimised: $player.optimised)

                ProgressTrack(progress: player.progress) { player.seek($0) }
                    .frame(height: 24)

                Button("Record again") { session.startRecording(deviceID: c.current?.audio?.id) }
                    .buttonStyle(.plain).foregroundStyle(Theme.textSecondary)
                Button("Reset") { session.resetToSuggested() }
                    .buttonStyle(.plain).foregroundStyle(Theme.textSecondary)
                    .disabled(session.draft == session.suggested)
                Button {
                    voice.apply(session.draft)
                    let mic = voice.profileName.map { " to your \($0)" } ?? ""
                    session.appliedMessage = "Saved\(mic). Choose “MicDeck Microphone” as your mic in Zoom, Discord, OBS and other apps."
                } label: {
                    Text("Use on MicDeck Microphone")
                        .font(.system(size: 13, weight: .semibold))
                        .padding(.horizontal, 16).frame(height: 36)
                        .background(Capsule().fill(Theme.mic))
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .disabled(voice.hasSettings && voice.settings == session.draft)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Theme.panel))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Theme.stroke))
    }
}

private struct ABSwitch: View {
    @Binding var optimised: Bool
    var body: some View {
        HStack(spacing: 0) {
            seg("Original", !optimised) { optimised = false }
            seg("Optimised", optimised) { optimised = true }
        }
        .padding(3)
        .background(Capsule().fill(Color.black.opacity(0.35)))
        .help("Switch while playing to compare")
    }
    private func seg(_ t: String, _ on: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(t).font(.system(size: 12, weight: .semibold))
                .padding(.horizontal, 12).frame(height: 28)
                .background(Capsule().fill(on ? Theme.mic.opacity(0.85) : .clear))
                .foregroundStyle(on ? Color.white : Theme.textSecondary)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

private struct ProgressTrack: View {
    var progress: Double
    var onSeek: (Double) -> Void
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.black.opacity(0.45)).frame(height: 6)
                Capsule().fill(Theme.textSecondary).frame(width: max(6, geo.size.width * progress), height: 6)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { g in onSeek(min(max(g.location.x / geo.size.width, 0), 1)) })
        }
        .accessibilityElement()
        .accessibilityLabel("Playback position")
        .accessibilityValue("\(Int((progress * 100).rounded())) percent")
    }
}

enum VoiceFormat {
    static func hz(_ f: Double) -> String {
        f >= 1000 ? String(format: "%.1f kHz", f / 1000) : "\(Int(f.rounded())) Hz"
    }
    static func hzShort(_ f: Double) -> String { f >= 1000 ? "\(Int(f / 1000))k" : "\(Int(f))" }
    static func db(_ d: Double) -> String { String(format: "%+.1f dB", d).replacingOccurrences(of: "+0.0", with: "0.0") }
}

extension Double {
    func rounded(toPlaces p: Int) -> Double {
        let m = pow(10, Double(p))
        return (self * m).rounded() / m
    }
}
