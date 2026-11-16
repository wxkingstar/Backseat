import SwiftUI

struct SettingsView: View {
    @Environment(Store.self) private var store
    @State private var customHost = UserDefaults.standard.string(forKey: "customHost") ?? ""

    var body: some View {
        List {
            Section {
                HStack(spacing: 8) {
                    Dot(color: store.connected ? Theme.ok : Theme.danger, size: 8)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(store.connected ? "已连接" : "未连接")
                        if let host = BridgeClient.shared.activeHost {
                            Text(host).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
                if store.connected {
                    LabeledContent("输入到", value: store.frontApp)
                }
            }

            Section {
                Toggle("快捷短语自动回车", isOn: Binding(get: { store.autoSubmit }, set: { store.autoSubmit = $0 }))
            } footer: {
                Text("只影响快捷页。说话的内容不会自动发送，在主页点 ↑ 才发出去。")
            }

            Section {
                NavigationLink("按键页") { KeysSettings() }
            }

            Section("Mac 地址") {
                ForEach(BridgeClient.shared.candidates, id: \.self) { h in
                    Text(h).font(.footnote).foregroundStyle(.secondary)
                }
                TextFieldLink(prompt: Text("IP 或主机名，留空恢复默认")) {
                    Label(customHost.isEmpty ? "手动指定" : customHost, systemImage: "pencil")
                } onSubmit: { v in
                    customHost = v.trimmingCharacters(in: .whitespaces)
                    UserDefaults.standard.set(customHost, forKey: "customHost")
                    store.refreshNow()
                }
                Button { store.refreshNow() } label: {
                    Label("重新连接", systemImage: "arrow.clockwise")
                }
                Button(role: .destructive) { Pairing.shared.unpair() } label: {
                    Label("重新配对", systemImage: "link")
                }
            }
        }
        .navigationTitle("设置")
    }
}
