import SwiftUI

// Aether palette — matches the macOS Aether Courier client.
extension Color {
    static let aetherViolet  = Color(red: 0.60, green: 0.38, blue: 0.96)
    static let aetherMagenta = Color(red: 0.925, green: 0.282, blue: 0.60)
    static let aetherBlue    = Color(red: 0.231, green: 0.510, blue: 0.965)
}

extension LinearGradient {
    /// Violet → magenta accent used on buttons, avatars, highlights.
    static let aether = LinearGradient(colors: [.aetherViolet, .aetherMagenta],
                                       startPoint: .topLeading, endPoint: .bottomTrailing)
}

/// Deep-indigo "aurora glass" backdrop — soft blurred blooms of colored light
/// behind the app's frosted panels, the same feel as the macOS client.
struct AuroraBackdrop: View {
    var intensity: Double = 1.0

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height, s = max(w, h)
            ZStack {
                LinearGradient(colors: [Color(red: 0.058, green: 0.050, blue: 0.104),
                                        Color(red: 0.026, green: 0.022, blue: 0.052)],
                               startPoint: .top, endPoint: .bottom)
                bloom(.aetherViolet,  at: CGPoint(x: w * 0.10, y: h * 0.04), r: s * 0.60)
                bloom(.aetherMagenta, at: CGPoint(x: w * 1.02, y: h * 0.14), r: s * 0.55)
                bloom(.aetherBlue,    at: CGPoint(x: w * 0.55, y: h * 1.05), r: s * 0.70)
                bloom(.aetherViolet,  at: CGPoint(x: w * -0.05, y: h * 0.85), r: s * 0.5)
            }
            .compositingGroup()
        }
        .ignoresSafeArea()
    }

    private func bloom(_ color: Color, at p: CGPoint, r: CGFloat) -> some View {
        RadialGradient(colors: [color.opacity(0.42 * intensity), .clear],
                       center: .center, startRadius: 0, endRadius: r)
            .frame(width: r * 2, height: r * 2)
            .position(p)
            .blur(radius: 42)
    }
}

/// Frosted-glass card surface with a subtle top highlight.
struct GlassCard: ViewModifier {
    var corner: CGFloat = 16
    func body(content: Content) -> some View {
        content
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: corner, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .strokeBorder(
                        LinearGradient(colors: [.white.opacity(0.18), .white.opacity(0.04)],
                                       startPoint: .top, endPoint: .bottom),
                        lineWidth: 1)
            )
    }
}

extension View {
    func glassCard(_ corner: CGFloat = 16) -> some View { modifier(GlassCard(corner: corner)) }
}

/// A soft glowing gradient orb — used as the AI/brand accent.
struct GlowOrb: View {
    var systemImage: String = "sparkles"
    var size: CGFloat = 44
    var body: some View {
        ZStack {
            Circle().fill(LinearGradient.aether)
            Circle().strokeBorder(.white.opacity(0.25), lineWidth: 1)
            Image(systemName: systemImage)
                .font(.system(size: size * 0.42, weight: .semibold))
                .foregroundStyle(.white)
        }
        .frame(width: size, height: size)
        .shadow(color: .aetherViolet.opacity(0.5), radius: size * 0.28, y: 2)
    }
}
