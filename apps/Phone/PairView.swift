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
        // -showPair：已配对时也显示配对页，截图检查界面用
        if Pairing.shared.isPaired && !ProcessInfo.processInfo.arguments.contains("-showPair") { MainView() } else { PairView() }
    }
}

/// 第一次使用：选一台 Mac，输入它显示的 4 位配对码。
struct PairView: View {
    @Environment(PhoneStore.self) private var store
    @State private var finder = MacFinder()
    @State private var address = ""
    @State private var code = ""
    @State private var busy = false
    @State private var error: String?
    @State private var manual = false
    @FocusState private var codeFocused: Bool

    private var ready: Bool { !address.isEmpty && code.count == 4 && !busy }

    var body: some View {
        ZStack {
            P.bg.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 8) {
                        Image("Logo").resizable().scaledToFit().foregroundStyle(.white)
                            .frame(width: 40, height: 40)
                            .frame(width: 52, height: 52)
                            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(P.accentFill))
                        Text("连接你的 Mac").font(.largeTitle.bold()).foregroundStyle(P.text)
                        Text("先在 Mac 上启动 Backseat，点菜单栏的 Backseat 图标能看到配对码。")
                            .font(.subheadline).foregroundStyle(P.text2)
                    }

                    macSection
                    codeSection

                    if let error {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.subheadline).foregroundStyle(P.dangerText)
                    }

                    Button(action: pair) {
                        HStack(spacing: 8) {
                            if busy { ProgressView().tint(.white) }
                            Text(busy ? "配对中…" : "配对").font(.headline)
                        }
                        .foregroundStyle(ready || busy ? Color.white : P.text3)
                        .frame(maxWidth: .infinity, minHeight: 56)
                    }
                    .buttonStyle(PressStyle(fill: ready || busy ? P.accentFill : P.key, radius: 16))
                    .disabled(!ready)
                }
                .padding(.horizontal, 20).padding(.top, 28).padding(.bottom, 24)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .onAppear { finder.start() }
        .onDisappear { finder.stop() }
        .onChange(of: finder.macs.first?.address) { _, first in
            if address.isEmpty, let first { address = first }
        }
        .onChange(of: code) { _, c in
            // 只留数字，最多 4 位；输满就直接配对，不用再点按钮
            let digits = String(c.filter(\.isNumber).prefix(4))
            if digits != c { code = digits; return }
            if digits.count == 4, !address.isEmpty, !busy { pair() }
        }
    }

    // MARK: - 选 Mac

    private var macSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("选择 Mac").font(.footnote.weight(.semibold)).foregroundStyle(P.text2)
            if finder.macs.isEmpty && !manual {
                HStack(spacing: 10) {
                    ProgressView().tint(P.text2)
                    Text("正在局域网里找 Mac…").font(.subheadline).foregroundStyle(P.text2)
                }
                .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading).padding(.horizontal, 16)
                .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(P.card))
            }
            ForEach(finder.macs) { mac in
                let selected = address == mac.address
                Button { address = mac.address; manual = false } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "desktopcomputer").font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(selected ? P.accent : P.text)
                        Text(mac.name).font(.body.weight(.medium)).foregroundStyle(P.text)
                        Spacer()
                        Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 20)).foregroundStyle(selected ? P.accent : P.text3)
                    }
                    .padding(.horizontal, 16).frame(minHeight: 56)
                    .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(selected ? P.accent : .clear, lineWidth: 1.5))
                }
                .buttonStyle(PressStyle(fill: P.card, radius: 16))
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
            if manual {
                TextField("Mac 的 IP 或主机名", text: $address)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                    .padding(.horizontal, 16).frame(minHeight: 56)
                    .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(P.card))
            } else {
                Button("找不到？手动填地址") { manual = true; address = "" }
                    .font(.subheadline).tint(P.accent).frame(minHeight: 44)
            }
        }
    }

    // MARK: - 配对码：4 个格子，真正的输入框藏在上面

    private var codeSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("配对码").font(.footnote.weight(.semibold)).foregroundStyle(P.text2)
            ZStack {
                HStack(spacing: 12) {
                    ForEach(0..<4, id: \.self) { i in
                        let chars = Array(code)
                        let current = codeFocused && i == min(chars.count, 3)
                        Text(i < chars.count ? String(chars[i]) : "")
                            .font(.system(size: 30, weight: .semibold, design: .rounded).monospacedDigit())
                            .foregroundStyle(P.text)
                            .frame(maxWidth: .infinity).frame(height: 64)
                            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(P.card))
                            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .stroke(current ? P.accent : P.line, lineWidth: current ? 2 : 1))
                    }
                }
                // 透明的输入框盖在格子上：点任何一格都能弹出数字键盘
                TextField("", text: $code)
                    .keyboardType(.numberPad).textContentType(.oneTimeCode)
                    .focused($codeFocused)
                    .foregroundStyle(.clear).tint(.clear)
                    .frame(maxWidth: .infinity).frame(height: 64)
                    .contentShape(Rectangle())
                    .accessibilityLabel("4 位配对码")
            }
        }
    }

    private func pair() {
        guard !busy else { return }
        busy = true
        error = nil
        codeFocused = false
        Task {
            do {
                try await Pairing.shared.pair(address: address, code: code)
                DeviceSync.shared.pushToWatch()   // 手表不用再配一遍
                Haptics.success()
                store.refreshNow()
            } catch {
                Haptics.error()
                self.error = error.localizedDescription
                code = ""
                codeFocused = true
            }
            busy = false
        }
    }
}
