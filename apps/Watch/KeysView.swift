import SwiftUI

/// 第四页：扩展按键。双指互点 = 回车。
struct KeysView: View {
    @Environment(Store.self) private var store

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                key("Esc", hint: "中断", fill: Theme.danger.opacity(0.25), fg: Theme.danger) { store.press("esc") }
                key("Tab") { store.press("tab") }
            }
            HStack(spacing: 6) {
                ForEach(["1", "2", "3"], id: \.self) { k in key(k) { store.press(k) } }
            }
            HStack(spacing: 6) {
                key(icon: "arrow.up") { store.press("up") }
                key(icon: "arrow.down") { store.press("down") }
                Button { store.press("enter") } label: { Image(systemName: "return") }
                    .buttonStyle(KeyStyle(fill: Theme.accent, height: 44))
                    .handGestureShortcut(.primaryAction)
                    .accessibilityLabel("回车")
            }
        }
        .padding(.horizontal, 6)
        .frame(maxHeight: .infinity)
        .disabled(!store.connected)
        .opacity(store.connected ? 1 : 0.5)
        .navigationTitle("按键")
    }

    private func key(_ title: String, hint: String? = nil, fill: Color = Theme.surface, fg: Color = .white,
                     action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 0) {
                Text(title).font(.system(.body, design: .rounded).weight(.semibold))
                if let hint { Text(hint).font(.system(size: 9)).opacity(0.7) }
            }
        }
        .buttonStyle(KeyStyle(fill: fill, foreground: fg, height: 44))
    }

    private func key(icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: icon) }
            .buttonStyle(KeyStyle(height: 44))
    }
}
