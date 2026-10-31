import MicKit
import SwiftUI

/// Main-window card: status of the voice processing and the way into the optimiser.
struct VoiceCard: View {
    @EnvironmentObject var voice: VoiceController
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Card("Voice", trailing: trailing) {
            VStack(alignment: .leading, spacing: 10) {
                if voice.driverInstalled && voice.hasSettings {
                    status
                    if let name = voice.profileName {
                        Text("Tuned for your \(name). Each mic model keeps its own settings.")
                            .font(.system(size: 11)).foregroundStyle(Theme.textTertiary)
                    }
                } else {
                    Text(voice.profileName.map { "Record a short test and MicDeck tunes EQ, compression and noise reduction for your voice on this \($0)." }
                         ?? "Record a short test and MicDeck tunes EQ, compression and noise reduction for your voice.")
                        .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    Button {
                        openWindow(id: "voice")
                        NSApp.activate()
                    } label: {
                        Label(voice.hasSettings ? "Tune again…" : "Optimise voice…", systemImage: "waveform.badge.magnifyingglass")
                            .font(.system(size: 12, weight: .semibold))
                            .padding(.horizontal, 12).frame(height: 30)
                            .background(Capsule().fill(voice.hasSettings ? Theme.raised : Theme.mic.opacity(0.85)))
                            .overlay(Capsule().strokeBorder(voice.hasSettings ? Theme.stroke : .clear))
                    }
                    .buttonStyle(.plain)
                    Spacer()
                    if !voice.driverInstalled {
                        Text("Needs MicDeck Audio").font(.system(size: 11)).foregroundStyle(Theme.textTertiary)
                    }
                }
            }
        }
    }

    private var trailing: AnyView? {
        guard voice.driverInstalled && voice.hasSettings else { return nil }
        return AnyView(
            Toggle("Voice processing", isOn: $voice.processingEnabled)
                .toggleStyle(.switch).tint(Theme.mic).labelsHidden().controlSize(.small)
                .help("Turn the voice processing on MicDeck Microphone on or off")
        )
    }

    @ViewBuilder private var status: some View {
        HStack(spacing: 8) {
            switch voice.route {
            case .active:
                Circle().fill(Theme.live).frame(width: 7, height: 7).shadow(color: Theme.live.opacity(0.8), radius: 4)
                Text(voice.processingEnabled ? "Live: an app is using MicDeck Microphone" : "Live, processing off")
                    .font(.system(size: 12, weight: .medium))
                Spacer()
                HorizontalMeter(level: voice.outputLevel).frame(width: 70, height: 6)
            case .idle:
                Circle().fill(Theme.textTertiary).frame(width: 7, height: 7)
                Text("Choose “MicDeck Microphone” as the mic in Zoom, Discord, OBS…")
                    .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            case .failed(let msg):
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(msg).font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct HorizontalMeter: View {
    var level: Float
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.black.opacity(0.45))
                Capsule()
                    .fill(LinearGradient(colors: [Theme.live, Theme.live, Color(red: 1, green: 0.76, blue: 0.2), Theme.muteRed],
                                         startPoint: .leading, endPoint: .trailing))
                    .mask(alignment: .leading) { Rectangle().frame(width: geo.size.width * CGFloat(level)) }
            }
        }
        .animation(.linear(duration: 0.06), value: level)
        .accessibilityElement()
        .accessibilityLabel("Level")
        .accessibilityValue("\(Int((level * 100).rounded())) percent")
    }
}
