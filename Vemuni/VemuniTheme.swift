import SwiftUI

enum VemuniTheme {
    static let cream = Color(red: 0.98, green: 0.96, blue: 0.91)
    static let paper = Color(red: 1.00, green: 0.99, blue: 0.96)
    static let espresso = Color(red: 0.18, green: 0.09, blue: 0.05)
    static let copper = Color(red: 0.72, green: 0.38, blue: 0.20)
    static let sage = Color(red: 0.27, green: 0.39, blue: 0.31)
}

struct VemuniWordmark: View {
    var compact = false

    var body: some View {
        HStack(spacing: compact ? 8 : 12) {
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
                Text("Vemuni")
                    .font(.system(size: 34, weight: .semibold, design: .serif))
                    .foregroundStyle(VemuniTheme.espresso)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Vemuni")
    }
}
