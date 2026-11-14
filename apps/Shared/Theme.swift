import SwiftUI

enum Theme {
    static let accent = Color(red: 0.85, green: 0.47, blue: 0.34)      // 珊瑚橙
    static let accentDeep = Color(red: 0.72, green: 0.33, blue: 0.24)
    static let ok = Color(red: 0.30, green: 0.80, blue: 0.47)
    static let danger = Color(red: 0.95, green: 0.33, blue: 0.31)
    static let warn = Color(red: 0.98, green: 0.76, blue: 0.27)
    static let surface = Color.white.opacity(0.09)
    static let surfacePressed = Color.white.opacity(0.18)
}

/// 遥控键盘、审批按钮用的实心圆角键
struct KeyStyle: ButtonStyle {
    var fill: Color = Theme.surface
    var foreground: Color = .white
    var height: CGFloat = 40

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(.body, design: .rounded).weight(.semibold))
            .foregroundStyle(foreground)
            .frame(maxWidth: .infinity, minHeight: height)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(fill)
                    .brightness(configuration.isPressed ? 0.12 : 0)
            )
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.spring(duration: 0.18), value: configuration.isPressed)
    }
}

/// 状态小圆点
struct Dot: View {
    let color: Color
    var size: CGFloat = 7
    var body: some View {
        Circle().fill(color).frame(width: size, height: size)
    }
}
