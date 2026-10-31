import SwiftUI

/// Tall mixer fader: rounded track filled from the bottom in the channel colour,
/// with a grippy cap. Drag anywhere on the track; double-click resets.
struct VerticalFader: View {
    @Binding var value: Double
    var range: ClosedRange<Double> = 0...1
    var step: Double? = nil
    var accent: Color
    var resetValue: Double? = nil
    var onChange: () -> Void = {}

    private let capHeight: CGFloat = 16

    var body: some View {
        GeometryReader { geo in
            let h = geo.size.height - capHeight
            let t = CGFloat((value - range.lowerBound) / (range.upperBound - range.lowerBound))
            ZStack(alignment: .bottom) {
                // Tick marks
                VStack(spacing: 0) {
                    ForEach(0..<11) { i in
                        Rectangle().fill(Color.white.opacity(i % 5 == 0 ? 0.18 : 0.08))
                            .frame(width: i % 5 == 0 ? 26 : 18, height: 1)
                        if i < 10 { Spacer(minLength: 0) }
                    }
                }
                .padding(.vertical, capHeight / 2)
                // Track
                Capsule().fill(Color.black.opacity(0.45))
                    .overlay(Capsule().strokeBorder(Color.white.opacity(0.06)))
                    .frame(width: 8)
                    .padding(.vertical, capHeight / 2)
                Capsule()
                    .fill(LinearGradient(colors: [accent.opacity(0.55), accent], startPoint: .bottom, endPoint: .top))
                    .frame(width: 8, height: max(8, h * t + capHeight / 2))
                    .padding(.bottom, capHeight / 2)
                    .shadow(color: accent.opacity(0.6), radius: 6)
                // Cap
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(LinearGradient(colors: [Color(white: 0.92), Color(white: 0.72)], startPoint: .top, endPoint: .bottom))
                    .overlay(VStack(spacing: 2.5) {
                        ForEach(0..<3) { _ in Rectangle().fill(Color.black.opacity(0.25)).frame(width: 18, height: 1) }
                    })
                    .frame(width: 38, height: capHeight)
                    .shadow(color: .black.opacity(0.5), radius: 3, y: 2)
                    .offset(y: -h * t)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                let y = min(max(g.location.y - capHeight / 2, 0), h)
                set(range.lowerBound + Double(1 - y / h) * (range.upperBound - range.lowerBound))
            })
            .onTapGesture(count: 2) { if let r = resetValue { set(r) } }
        }
    }

    private func set(_ v: Double) {
        var v = min(max(v, range.lowerBound), range.upperBound)
        if let step { v = (v / step).rounded() * step }
        guard v != value else { return }
        value = v
        onChange()
    }
}

/// Segmented vertical meter (green → amber → red) with a peak-hold line.
struct LevelMeterView: View {
    var level: Float      // 0…1
    var peak: Float       // 0…1
    var dimmed: Bool

    private let segments = 28

    var body: some View {
        GeometryReader { geo in
            let gap: CGFloat = 2
            let segH = (geo.size.height - gap * CGFloat(segments - 1)) / CGFloat(segments)
            VStack(spacing: gap) {
                ForEach((0..<segments).reversed(), id: \.self) { i in
                    let pos = Float(i) / Float(segments - 1)
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(color(for: pos).opacity(lit(pos) ? 1 : 0.13))
                        .frame(height: segH)
                        .overlay(isPeak(pos) ? RoundedRectangle(cornerRadius: 1.5).fill(Color.white.opacity(0.85)) : nil)
                }
            }
        }
        .frame(width: 8)
        .saturation(dimmed ? 0 : 1)
        .opacity(dimmed ? 0.5 : 1)
        .animation(.linear(duration: 0.06), value: level)
    }

    private func lit(_ pos: Float) -> Bool { level > 0.001 && pos <= level }
    private func isPeak(_ pos: Float) -> Bool {
        peak > 0.02 && abs(pos - peak) < 0.5 / Float(segments)
    }
    private func color(for pos: Float) -> Color {
        pos > 0.86 ? Color(red: 1, green: 0.27, blue: 0.27) : pos > 0.68 ? Color(red: 1, green: 0.76, blue: 0.2) : Theme.live
    }
}

struct MuteButton: View {
    var muted: Bool
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: muted ? "mic.slash.fill" : "mic.fill")
                Text(muted ? "MUTED" : "MUTE").font(.system(size: 11, weight: .bold)).tracking(0.8)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 34)
            .foregroundStyle(muted ? Color.white : Theme.textSecondary)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(muted ? Theme.muteRed : Theme.raised))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(muted ? .clear : Theme.stroke))
            .shadow(color: muted ? Theme.muteRed.opacity(0.5) : .clear, radius: 10)
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: 0.15), value: muted)
    }
}

/// Pill toggle for effects ("Low-cut", "Same colour", …).
struct ChipToggle: View {
    let title: String
    let systemImage: String
    @Binding var isOn: Bool
    var accent: Color = Theme.mic
    var onChange: () -> Void = {}

    var body: some View {
        Button {
            isOn.toggle(); onChange()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                Text(title).font(.system(size: 12, weight: .semibold))
            }
            .padding(.horizontal, 12).frame(height: 30)
            .foregroundStyle(isOn ? Color.white : Theme.textSecondary)
            .background(Capsule().fill(isOn ? accent.opacity(0.85) : Theme.raised))
            .overlay(Capsule().strokeBorder(isOn ? .clear : Theme.stroke))
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: 0.15), value: isOn)
    }
}

/// Compact horizontal slider in the mixer style.
struct ThinSlider: View {
    @Binding var value: Double
    var accent: Color
    var onChange: () -> Void = {}

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(Color.black.opacity(0.45)).frame(height: 6)
                Capsule().fill(accent).frame(width: max(6, w * value), height: 6)
                Circle().fill(Color.white).frame(width: 16, height: 16)
                    .shadow(color: .black.opacity(0.4), radius: 2, y: 1)
                    .offset(x: min(max(0, w * value - 8), w - 16))
            }
            .frame(height: geo.size.height)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                let v = min(max(g.location.x / w, 0), 1)
                if v != value { value = v; onChange() }
            })
        }
        .frame(height: 20)
    }
}
