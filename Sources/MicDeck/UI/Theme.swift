import SwiftUI

/// Dark mixer look: layered charcoal surfaces, one accent colour per channel.
enum Theme {
    static let background = Color(red: 0.067, green: 0.071, blue: 0.086)      // #111216
    static let panel = Color(red: 0.102, green: 0.110, blue: 0.133)           // #1A1C22
    static let raised = Color(red: 0.137, green: 0.145, blue: 0.176)          // #23252D
    static let stroke = Color.white.opacity(0.07)
    static let textPrimary = Color.white.opacity(0.92)
    static let textSecondary = Color.white.opacity(0.55)
    static let textTertiary = Color.white.opacity(0.32)

    static let mic = Color(red: 1.0, green: 0.18, blue: 0.58)                 // magenta, as in the icon's band
    static let headphones = Color(red: 0.20, green: 0.80, blue: 1.0)         // cyan
    static let mix = Color(red: 0.56, green: 0.36, blue: 1.0)                 // violet
    static let muteRed = Color(red: 1.0, green: 0.27, blue: 0.27)
    static let live = Color(red: 0.25, green: 0.86, blue: 0.47)

    static let sectionFont = Font.system(size: 11, weight: .semibold).width(.expanded)
}

struct Card<Content: View>: View {
    var title: String?
    var trailing: AnyView?
    @ViewBuilder var content: Content

    init(_ title: String? = nil, trailing: AnyView? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.trailing = trailing
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if title != nil || trailing != nil {
                HStack {
                    if let title { SectionLabel(title) }
                    Spacer()
                    trailing
                }
            }
            content
        }
        .padding(18)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Theme.panel))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Theme.stroke))
    }
}

struct SectionLabel: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text.uppercased())
            .font(Theme.sectionFont)
            .tracking(1.2)
            .foregroundStyle(Theme.textSecondary)
    }
}
