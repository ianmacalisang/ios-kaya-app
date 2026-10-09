//
//  KayaTheme.swift
//  Kaya
//
//  Calm, sensory-considerate design system — dark, warm, orange accent.
//

import SwiftUI

enum KayaTheme {
    static let background = Color(hex: "14100D")
    static let card = Color(hex: "242019")
    static let warm = Color(hex: "3D2E1C")
    static let text = Color(hex: "F4EDE3")
    static let subtleText = Color(hex: "A79B8A")
    static let accent = Color(hex: "F0973B")
    static let onAccent = Color(hex: "1C1309")
    static let success = Color(hex: "8FBF8F")
}

extension Color {
    init(hex: String) {
        var hexSanitized = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        hexSanitized = hexSanitized.replacingOccurrences(of: "#", with: "")
        var rgb: UInt64 = 0
        Scanner(string: hexSanitized).scanHexInt64(&rgb)
        self.init(
            red: Double((rgb >> 16) & 0xFF) / 255,
            green: Double((rgb >> 8) & 0xFF) / 255,
            blue: Double(rgb & 0xFF) / 255
        )
    }
}

// MARK: - Graphical components

/// A colored icon tile used on routine rows and profile answers.
struct KayaIconTile: View {
    let symbol: String
    var tint: Color = KayaTheme.accent
    var size: CGFloat = 44

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.42, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: size, height: size)
            .background(
                LinearGradient(
                    colors: [KayaTheme.warm, KayaTheme.warm.opacity(0.55)],
                    startPoint: .topLeading, endPoint: .bottomTrailing)
            )
            .clipShape(RoundedRectangle(cornerRadius: size * 0.28, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                    .stroke(tint.opacity(0.2), lineWidth: 1)
            )
            .accessibilityHidden(true)
    }
}

/// A circular progress ring (0…1). Calm — it fills, never drains.
struct KayaProgressRing: View {
    var value: Double
    var size: CGFloat = 64
    var lineWidth: CGFloat = 6
    var tint: Color = KayaTheme.accent

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Circle()
                .stroke(KayaTheme.warm, lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: min(max(value, 0), 1))
                .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(reduceMotion ? nil : .easeOut(duration: 0.5), value: value)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// A slim horizontal progress bar (0…1). Same calm fill-only behavior
/// as the ring — used where a circle is too heavy.
struct KayaProgressBar: View {
    var value: Double
    var height: CGFloat = 6
    var tint: Color = KayaTheme.accent

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(KayaTheme.warm)
                Capsule()
                    .fill(tint)
                    .frame(width: geo.size.width * min(max(value, 0), 1))
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.5), value: value)
            }
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }
}

struct KayaCard: ViewModifier {
    var padding: CGFloat = 20

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(KayaTheme.card)
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

extension View {
    func kayaCard(padding: CGFloat = 20) -> some View {
        modifier(KayaCard(padding: padding))
    }
}

struct KayaPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(KayaTheme.onAccent)
            .frame(maxWidth: .infinity)
            .frame(minHeight: 56)
            .background(KayaTheme.accent.opacity(configuration.isPressed ? 0.8 : 1))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

struct KayaSecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(KayaTheme.accent)
            .frame(maxWidth: .infinity)
            .frame(minHeight: 52)
            .background(KayaTheme.warm.opacity(configuration.isPressed ? 0.6 : 1))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

/// Tappable chip with a gentle press scale — suggestion pills, option chips.
struct KayaChipButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

/// Compact icon-only control for secondary actions.
struct KayaIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.title3)
            .foregroundStyle(KayaTheme.accent.opacity(configuration.isPressed ? 0.6 : 1))
            .frame(minWidth: 52, minHeight: 52)
            .background(KayaTheme.card)
            .clipShape(Circle())
    }
}
