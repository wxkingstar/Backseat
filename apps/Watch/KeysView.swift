import SwiftUI

/// 第四页：按键。上面是自己选出来的常用键，其余的收在「所有按键」里。双指互点 = 回车。
struct KeysView: View {
    @Environment(Store.self) private var store
    @State private var showAll = false

    /// 手表上用不到「所有按键」这个键本身
    static let catalog = SideKeyKind.allCases.filter { $0 != .more }
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 3)

    var body: some View {
        let rest = Self.catalog.filter { !store.keys.contains($0) }
        ScrollView {
            VStack(spacing: 6) {
                LazyVGrid(columns: columns, spacing: 6) {
                    ForEach(store.keys) { keyCap($0) }
                }
                if !rest.isEmpty {
                    Button { withAnimation(.spring(duration: 0.25)) { showAll.toggle() } } label: {
                        HStack(spacing: 6) {
                            Text("所有按键").font(.footnote.weight(.semibold))
                            Image(systemName: "chevron.down").font(.caption2.weight(.bold))
                                .rotationEffect(.degrees(showAll ? 180 : 0))
                        }
                    }
                    .buttonStyle(KeyStyle(fill: .clear, foreground: .secondary, height: 32))
                    if showAll {
                        LazyVGrid(columns: columns, spacing: 6) {
                            ForEach(rest) { keyCap($0) }
                        }
                    }
                }
            }
            .padding(.horizontal, 6)
        }
        .disabled(!store.connected)
        .opacity(store.connected ? 1 : 0.5)
        .navigationTitle("按键")
    }

    /// Esc 是中断，用红色；回车用强调色，并且可以双指互点触发
    @ViewBuilder private func keyCap(_ k: SideKeyKind) -> some View {
        let button = Button { store.run(k) } label: {
            Image("key-\(k.rawValue)").resizable().scaledToFit().frame(height: 20)
        }
        .accessibilityLabel(k.title)
        switch k {
        case .esc: button.buttonStyle(KeyStyle(fill: Theme.danger.opacity(0.25), foreground: Theme.danger, height: 44))
        case .enter: button.buttonStyle(KeyStyle(fill: Theme.accent, height: 44)).handGestureShortcut(.primaryAction)
        default: button.buttonStyle(KeyStyle(height: 44))
        }
    }
}

/// 设置 → 按键页：选哪些键直接摆在按键页上
struct KeysSettings: View {
    @Environment(Store.self) private var store

    var body: some View {
        List {
            Section {
                ForEach(KeysView.catalog) { k in
                    Toggle(k.title, isOn: Binding(
                        get: { store.keys.contains(k) },
                        set: { on in
                            if on { store.keys.append(k) } else { store.keys.removeAll { $0 == k } }
                        }))
                }
            } footer: {
                Text("打开的直接摆在按键页上，按打开的先后排列；没打开的收在「所有按键」里。")
            }
            Button("恢复默认", role: .destructive) { store.keys = SideKeyKind.watchDefaults }
        }
        .navigationTitle("按键页")
    }
}
