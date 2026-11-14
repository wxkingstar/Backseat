import Network
import SwiftUI

/// 在局域网里找正在运行 backseat 的 Mac（Mac 端用 Bonjour 广播 _backseat._tcp）
@MainActor @Observable
final class MacFinder {
    struct Mac: Identifiable {
        let name: String
        let address: String
        var id: String { address }
    }

    var macs: [Mac] = []
    private var browser: NWBrowser?

    func start() {
        guard browser == nil else { return }
        let b = NWBrowser(for: .bonjourWithTXTRecord(type: "_backseat._tcp", domain: nil), using: .tcp)
        b.browseResultsChangedHandler = { [weak self] results, _ in
            let found = results.compactMap { r -> Mac? in
                guard case .service(let name, _, _, _) = r.endpoint else { return nil }
                var port = "8787"
                if case .bonjour(let txt) = r.metadata, let p = txt["port"] { port = p }
                // 服务名就是 Mac 的 Bonjour 主机名
                return Mac(name: name, address: "\(name).local:\(port)")
            }
            Task { @MainActor in self?.macs = found }
        }
        b.start(queue: .main)
        browser = b
    }

    func stop() {
        browser?.cancel()
        browser = nil
    }
}

/// 没配对时显示配对页，配对后进主屏
struct Gate: View {
    var body: some View {
        if Pairing.shared.isPaired { MainView() } else { PairView() }
    }
}

/// 第一次使用：选一台 Mac，输入它显示的配对码。
struct PairView: View {
    @Environment(PhoneStore.self) private var store
    @State private var finder = MacFinder()
    @State private var address = ""
    @State private var code = ""
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(finder.macs) { mac in
                        Button { address = mac.address } label: {
                            HStack {
                                Label(mac.name, systemImage: "desktopcomputer")
                                Spacer()
                                if address == mac.address { Image(systemName: "checkmark") }
                            }
                        }
                    }
                    TextField("或手动填 Mac 的 IP / 主机名", text: $address)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                } header: { Text("Mac") } footer: {
                    Text("先在 Mac 上启动 backseat。手机和 Mac 在同一个局域网时会自动出现在这里。")
                }

                Section {
                    TextField("6 位配对码", text: $code).keyboardType(.numberPad)
                } header: { Text("配对码") } footer: {
                    Text("显示在 Mac 的 backseat 窗口里。")
                }

                Section {
                    Button(busy ? "配对中…" : "配对") { pair() }
                        .disabled(busy || address.isEmpty || code.isEmpty)
                    if let error { Text(error).foregroundStyle(.red) }
                }
            }
            .navigationTitle("连接 Mac")
        }
        .onAppear { finder.start() }
        .onDisappear { finder.stop() }
        .onChange(of: finder.macs.first?.address) { _, first in
            if address.isEmpty, let first { address = first }
        }
    }

    private func pair() {
        busy = true
        error = nil
        Task {
            do {
                try await Pairing.shared.pair(address: address, code: code)
                store.refreshNow()
            } catch {
                self.error = error.localizedDescription
            }
            busy = false
        }
    }
}
