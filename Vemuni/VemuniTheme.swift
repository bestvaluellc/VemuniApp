import SwiftUI
import UIKit

enum VemuniTheme {
    static let cream = adaptive(
        light: UIColor(red: 0.98, green: 0.96, blue: 0.91, alpha: 1),
        dark: UIColor(red: 0.06, green: 0.05, blue: 0.045, alpha: 1)
    )
    static let paper = adaptive(
        light: UIColor(red: 1.00, green: 0.99, blue: 0.96, alpha: 1),
        dark: UIColor(red: 0.14, green: 0.12, blue: 0.10, alpha: 1)
    )
    static let espresso = adaptive(
        light: UIColor(red: 0.18, green: 0.09, blue: 0.05, alpha: 1),
        dark: UIColor(red: 0.96, green: 0.92, blue: 0.87, alpha: 1)
    )
    static let copper = adaptive(
        light: UIColor(red: 0.72, green: 0.38, blue: 0.20, alpha: 1),
        dark: UIColor(red: 0.94, green: 0.58, blue: 0.34, alpha: 1)
    )
    static let sage = adaptive(
        light: UIColor(red: 0.27, green: 0.39, blue: 0.31, alpha: 1),
        dark: UIColor(red: 0.58, green: 0.78, blue: 0.64, alpha: 1)
    )

    // Kept dark in both appearances so white button labels always remain readable.
    static let primaryAction = adaptive(
        light: UIColor(red: 0.18, green: 0.09, blue: 0.05, alpha: 1),
        dark: UIColor(red: 0.36, green: 0.17, blue: 0.09, alpha: 1)
    )

    static let onCopper = adaptive(
        light: .white,
        dark: UIColor(red: 0.12, green: 0.055, blue: 0.025, alpha: 1)
    )

    private static func adaptive(light: UIColor, dark: UIColor) -> Color {
        Color(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark ? dark : light
        })
    }
}

struct VemuniWordmark: View {
    var compact = false

    var body: some View {
        HStack(spacing: compact ? 8 : 1) {
            Text("V")
                .font(.system(size: compact ? 34 : 52, weight: .bold, design: .serif))
                .foregroundStyle(VemuniTheme.espresso)
                .overlay(alignment: .leading) {
                    Capsule()
                        .fill(VemuniTheme.copper)
                        .frame(width: compact ? 3 : 4, height: compact ? 23 : 36)
                        .rotationEffect(.degrees(-15))
                        .offset(x: compact ? 10 : 15)
                }
            if !compact {
                Text("emuni")
                    .font(.system(size: 34, weight: .semibold, design: .serif))
                    .foregroundStyle(VemuniTheme.espresso)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Vemuni")
    }
}
