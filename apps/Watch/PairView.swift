import SwiftUI

/// 第一次使用：填 Mac 地址和配对码，换取 token。
struct PairView: View {
    @Environment(Store.self) private var store
    @State private var address = ""
    @State private var code = ""
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                Text("连接 Mac").font(.headline)
                Text("Mac 上启动 backseat，按它显示的地址和配对码填写。")
                    .font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.center)
                TextField("Mac 地址", text: $address)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                TextField("6 位配对码", text: $code)
                Button(busy ? "配对中…" : "配对") { pair() }
                    .disabled(busy || address.isEmpty || code.isEmpty)
                if let error {
                    Text(error).font(.caption2).foregroundStyle(Theme.danger).multilineTextAlignment(.center)
                }
            }
            .padding(.horizontal, 4)
        }
    }

    private func pair() {
        busy = true
        error = nil
        Task {
            do {
                try await Pairing.shared.pair(address: address, code: code)
                WKInterfaceDevice.current().play(.success)
                store.refreshNow()
            } catch {
                WKInterfaceDevice.current().play(.failure)
                self.error = error.localizedDescription
            }
            busy = false
        }
    }
}
