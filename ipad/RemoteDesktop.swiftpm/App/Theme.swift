import SwiftUI

/// アプリ全体の見た目 (色・背景・カード・ボタン)
enum Theme {
    static let indigo = Color(red: 0.35, green: 0.24, blue: 1.0)
    static let blue = Color(red: 0.22, green: 0.44, blue: 1.0)
    static let cyan = Color(red: 0.08, green: 0.82, blue: 0.96)
    static let amber = Color(red: 1.0, green: 0.77, blue: 0.25)

    /// ブランドのグラデーション (アイコンと同じ色)
    static let brand = LinearGradient(colors: [indigo, blue, cyan], startPoint: .topLeading, endPoint: .bottomTrailing)
    static let brandSoft = LinearGradient(colors: [indigo.opacity(0.9), blue.opacity(0.9)],
                                          startPoint: .topLeading, endPoint: .bottomTrailing)
}

/// ゆっくり動くグラデーションの背景 (接続画面)
struct AuroraBackground: View {
    @Environment(\.colorScheme) private var scheme
    @State private var phase = false

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            ZStack {
                (scheme == .dark ? Color(red: 0.04, green: 0.05, blue: 0.12) : Color(red: 0.95, green: 0.96, blue: 1.0))
                Circle()
                    .fill(Theme.indigo.opacity(scheme == .dark ? 0.55 : 0.35))
                    .frame(width: w * 0.9)
                    .blur(radius: 120)
                    .offset(x: phase ? -w * 0.25 : -w * 0.35, y: phase ? -h * 0.30 : -h * 0.22)
                Circle()
                    .fill(Theme.cyan.opacity(scheme == .dark ? 0.40 : 0.30))
                    .frame(width: w * 0.8)
                    .blur(radius: 130)
                    .offset(x: phase ? w * 0.35 : w * 0.25, y: phase ? h * 0.25 : h * 0.32)
                Circle()
                    .fill(Theme.blue.opacity(scheme == .dark ? 0.35 : 0.22))
                    .frame(width: w * 0.6)
                    .blur(radius: 110)
                    .offset(x: phase ? w * 0.10 : -w * 0.05, y: phase ? -h * 0.05 : h * 0.05)
            }
            .frame(width: w, height: h)
        }
        .ignoresSafeArea()
        .onAppear {
            withAnimation(.easeInOut(duration: 9).repeatForever(autoreverses: true)) { phase.toggle() }
        }
    }
}

/// すりガラス調のカード
struct CardModifier: ViewModifier {
    var padding: CGFloat = 18

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(LinearGradient(colors: [.white.opacity(0.55), .white.opacity(0.08)],
                                                 startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.08), radius: 18, y: 8)
    }
}

extension View {
    func card(padding: CGFloat = 18) -> some View { modifier(CardModifier(padding: padding)) }
}

/// カードの見出し (アイコン + 文字)
struct CardHeader: View {
    let title: String
    let systemImage: String
    var tint: Color = Theme.blue

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(tint.gradient, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            Text(title).font(.headline)
            Spacer()
        }
    }
}

/// 大きなグラデーションのボタン
struct PrimaryButtonStyle: ButtonStyle {
    var busy = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(.headline, design: .rounded))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(Theme.brand, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(.white.opacity(0.25), lineWidth: 1)
            )
            .shadow(color: Theme.blue.opacity(0.45), radius: configuration.isPressed ? 6 : 16, y: configuration.isPressed ? 3 : 10)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .opacity(busy ? 0.85 : 1)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

/// 選べるカード (接続方法など)
struct ChoiceCard: View {
    let title: String
    let subtitle: String
    let systemImage: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: systemImage)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(selected ? .white : Theme.blue)
                    .frame(width: 48, height: 48)
                    .background {
                        if selected {
                            RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.brand)
                        } else {
                            RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.blue.opacity(0.12))
                        }
                    }
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.headline).foregroundStyle(.primary)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(selected ? Theme.blue : Color.secondary.opacity(0.5))
            }
            .padding(14)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(selected ? AnyShapeStyle(Theme.brand) : AnyShapeStyle(Color.white.opacity(0.25)),
                                  lineWidth: selected ? 2 : 1)
            )
        }
        .buttonStyle(.plain)
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: selected)
    }
}

/// 入力欄 (アイコンつき)
struct FieldRow<Content: View>: View {
    let systemImage: String
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .foregroundStyle(.secondary)
                .frame(width: 22)
            content
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

/// 状態を示す小さなバッジ
struct StatusPill: View {
    let text: String
    let color: Color
    var pulsing = false
    @State private var on = false

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
                .scaleEffect(pulsing && on ? 1.5 : 1)
                .opacity(pulsing && on ? 0.5 : 1)
            Text(text).font(.caption.weight(.semibold))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(color.opacity(0.14), in: Capsule())
        .foregroundStyle(color)
        .onAppear {
            if pulsing {
                withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { on = true }
            }
        }
    }
}
