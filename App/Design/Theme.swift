import SwiftUI
import UIKit

/// The palette of the app icon: a teal gradient, white and mint circles, and an amber overlap.
enum Theme {
    static let tealLight = Color(red: 0x0B / 255, green: 0x94 / 255, blue: 0x86 / 255)
    static let tealDeep = Color(red: 0x14 / 255, green: 0x5A / 255, blue: 0x7C / 255)
    static let mint = Color(red: 0x7A / 255, green: 0xEF / 255, blue: 0xCB / 255)
    static let amber = Color(red: 0xFD / 255, green: 0xC3 / 255, blue: 0x43 / 255)

    /// The icon's background, bottom-left deep blue to top-right teal.
    static let gradient = LinearGradient(
        colors: [tealDeep, tealLight], startPoint: .bottomLeading, endPoint: .topTrailing
    )

    /// Brand colour for text and controls on the system background: darker in light mode so it stays readable.
    static let accent = dynamic(light: UIColor(red: 0x0B / 255, green: 0x7F / 255, blue: 0x80 / 255, alpha: 1),
                                dark: UIColor(red: 0x7A / 255, green: 0xEF / 255, blue: 0xCB / 255, alpha: 1))
    static let background = dynamic(light: UIColor(red: 0.94, green: 0.96, blue: 0.96, alpha: 1),
                                    dark: UIColor(red: 0.04, green: 0.08, blue: 0.10, alpha: 1))
    static let card = dynamic(light: .white, dark: UIColor(red: 0.09, green: 0.15, blue: 0.18, alpha: 1))
    /// Money owed to you, and money you owe. Both stay legible on cards in either appearance.
    static let positive = dynamic(light: UIColor(red: 0.04, green: 0.55, blue: 0.40, alpha: 1),
                                  dark: UIColor(red: 0.45, green: 0.90, blue: 0.72, alpha: 1))
    static let negative = dynamic(light: UIColor(red: 0.80, green: 0.28, blue: 0.22, alpha: 1),
                                  dark: UIColor(red: 1.0, green: 0.55, blue: 0.48, alpha: 1))
    static let warning = dynamic(light: UIColor(red: 0.72, green: 0.45, blue: 0.0, alpha: 1),
                                 dark: UIColor(red: 0.99, green: 0.76, blue: 0.26, alpha: 1))

    private static func dynamic(light: UIColor, dark: UIColor) -> Color {
        Color(UIColor { $0.userInterfaceStyle == .dark ? dark : light })
    }

    /// A stable colour per person, picked from the icon's family so avatars feel part of the same set.
    static func avatarColors(for id: UUID) -> [Color] {
        let options: [[Color]] = [
            [tealLight, tealDeep],
            [Color(red: 0.13, green: 0.62, blue: 0.78), Color(red: 0.08, green: 0.36, blue: 0.62)],
            [Color(red: 0.96, green: 0.66, blue: 0.16), Color(red: 0.86, green: 0.45, blue: 0.10)],
            [Color(red: 0.30, green: 0.78, blue: 0.62), Color(red: 0.06, green: 0.52, blue: 0.50)],
            [Color(red: 0.50, green: 0.45, blue: 0.85), Color(red: 0.30, green: 0.28, blue: 0.62)],
        ]
        let sum = id.uuidString.unicodeScalars.reduce(0) { ($0 &+ Int($1.value)) }
        return options[sum % options.count]
    }
}

/// The icon's motif: two overlapping circles with the overlap in amber.
struct LogoMark: View {
    var body: some View {
        GeometryReader { proxy in
            let d = min(proxy.size.width, proxy.size.height)
            let r = d * 0.34
            let offset = d * 0.17
            let center = CGPoint(x: proxy.size.width / 2, y: proxy.size.height / 2)
            let left = Circle().path(in: CGRect(x: center.x - offset - r, y: center.y - r, width: r * 2, height: r * 2))
            let right = Circle().path(in: CGRect(x: center.x + offset - r, y: center.y - r, width: r * 2, height: r * 2))
            ZStack {
                left.fill(.white)
                right.fill(Theme.mint)
                left.intersection(right).fill(Theme.amber)
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityHidden(true)
    }
}

/// The teal gradient with a few soft circles, used behind hero areas.
struct BrandBackground: View {
    var body: some View {
        ZStack {
            Theme.gradient
            Circle().fill(.white.opacity(0.07)).frame(width: 260).offset(x: 130, y: -70)
            Circle().fill(Theme.mint.opacity(0.10)).frame(width: 200).offset(x: 190, y: 20)
        }
        .clipped()
    }
}

/// A person's initials on a gradient disc.
struct Avatar: View {
    let name: String
    let id: UUID
    var size: CGFloat = 40

    var body: some View {
        Text(initials)
            .font(.system(size: size * 0.38, weight: .semibold, design: .rounded))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(LinearGradient(colors: Theme.avatarColors(for: id), startPoint: .topTrailing, endPoint: .bottomLeading), in: Circle())
            .accessibilityHidden(true)
    }

    private var initials: String {
        let parts = name.split(separator: " ").prefix(2).compactMap(\.first)
        return String(parts).uppercased()
    }
}

/// Rows and sections sit on rounded cards over a tinted background.
struct CardSection<Content: View>: View {
    let title: LocalizedStringKey?
    var trailing: AnyView?
    @ViewBuilder var content: Content

    init(_ title: LocalizedStringKey? = nil, trailing: AnyView? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.trailing = trailing
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title {
                HStack {
                    Text(title).font(.headline).foregroundStyle(.primary)
                    Spacer()
                    trailing
                }
                .padding(.horizontal, 4)
            }
            VStack(spacing: 0) { content }
                .background(Theme.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(Color(red: 0.07, green: 0.20, blue: 0.24))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 15)
            .background(Theme.amber.opacity(isEnabled ? 1 : 0.45), in: Capsule())
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
    }
}

extension View {
    /// Page background shared by every screen.
    func brandScreen() -> some View {
        background(Theme.background.ignoresSafeArea())
    }
}
