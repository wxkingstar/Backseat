import AppKit
import CoreImage.CIFilterBuiltins
import ServiceManagement
import SwiftUI

/// 设置引导窗口：第一次启动、没有辅助功能权限、或者再次打开 Backseat 时弹出。
/// 一页列出所有要做的事，每一步的状态每秒刷新，做完自动打勾。
@MainActor
final class Onboarding {
    static let appStoreURL = URL(string: "https://apps.apple.com/app/id6835461317")!
    static let pkgURL = URL(string: "https://github.com/wxkingstar/Backseat/releases/latest/download/Backseat.pkg")!
    static let doubaoURL = URL(string: "https://shurufa.doubao.com/")!

    private var window: NSWindow?
    private let model: OnboardingModel

    init(bridge: Bridge, port: UInt16) {
        model = OnboardingModel(bridge: bridge, port: port)
    }

    func show() {
        model.refresh()
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 680),
                             styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
            w.title = "Backseat 设置"
            w.titlebarAppearsTransparent = true
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: OnboardingView(model: model) { [weak self] in self?.finish() })
            w.center()
            window = w
        }
        model.start()
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    private func finish() {
        Setup.onboarded = true
        model.stop()
        window?.close()
    }
}

@MainActor
final class OnboardingModel: ObservableObject {
    let bridge: Bridge
    let port: UInt16
    @Published var trusted = false
    @Published var hasMic = false
    @Published var imeName: String?
    @Published var holdKey = "fn"
    @Published var connected = false
    @Published var hooks = false
    @Published var loginItem = false
    @Published var pairCode = ""
    @Published var hosts: [String] = []
    private var timer: Timer?

    init(bridge: Bridge, port: UInt16) { self.bridge = bridge; self.port = port }

    func start() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    func stop() { timer?.invalidate(); timer = nil }

    func refresh() {
        trusted = Keyboard.isTrusted(prompt: false)
        hasMic = VirtualMic().deviceID != nil
        // 引导过程中刚装好的输入法也要能认出来
        if MicStream.voiceIME == nil {
            MicStream.voiceIME = MicStream.knownIMEs.first { MicStream.inputSource($0.sourceID) != nil }
        }
        imeName = MicStream.voiceIME.flatMap { MicStream.inputSource($0.sourceID) } != nil ? MicStream.imeName : nil
        holdKey = MicStream.voiceIME?.holdKey ?? "fn"
        connected = bridge.clientConnected
        hooks = Setup.hooksInstalled
        loginItem = SMAppService.mainApp.status == .enabled
        pairCode = bridge.pairCode
        hosts = Bridge.hosts
    }

    func requestAccessibility() {
        _ = Keyboard.isTrusted(prompt: true)
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    func setLoginItem(_ on: Bool) {
        let service = SMAppService.mainApp
        if on { try? service.register() } else { try? service.unregister() }
        refresh()
    }

    var holdKeyTitle: String {
        ["fn": "Fn", "rightCommand": "右 ⌘", "rightOption": "右 ⌥", "rightControl": "右 ⌃", "rightShift": "右 ⇧"][holdKey] ?? holdKey
    }
}

private struct OnboardingView: View {
    @ObservedObject var model: OnboardingModel
    let onDone: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header.padding(.horizontal, 28).padding(.top, 36).padding(.bottom, 18)
            ScrollView {
                VStack(spacing: 10) {
                    accessibility
                    microphone
                    voice
                    phone
                    pairing
                    claude
                }
                .padding(.horizontal, 28)
                .padding(.bottom, 12)
            }
            Divider()
            footer.padding(.horizontal, 28).padding(.vertical, 14)
        }
        .frame(width: 560, height: 680)
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 56, height: 56)
            VStack(alignment: .leading, spacing: 4) {
                Text("欢迎使用 Backseat").font(.system(size: 22, weight: .semibold))
                Text("做完下面几步，就能用 iPhone 和 Apple Watch 给这台 Mac 说话打字。")
                    .font(.system(size: 13)).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: 步骤

    private var accessibility: some View {
        StepCard(number: 1, title: "允许辅助功能", state: model.trusted ? .done : .todo, required: true,
                 detail: model.trusted
                     ? "已授权。Backseat 可以替你输入文字、按键和移动指针。"
                     : "Backseat 要靠这项权限把手机上说的话和按键送进 Mac。点右边按钮，在系统设置里打开 Backseat 的开关。") {
            if !model.trusted { Button("去授权") { model.requestAccessibility() }.buttonStyle(.borderedProminent) }
        }
    }

    private var microphone: some View {
        StepCard(number: 2, title: "虚拟麦克风「Backseat Mic」", state: model.hasMic ? .done : .warn, required: true,
                 detail: model.hasMic
                     ? "已就绪。手机的声音会经过它交给语音输入法。"
                     : "系统里没有找到这块虚拟声卡。请下载安装包重新安装一次，装完不用重启电脑。") {
            if !model.hasMic { Button("下载安装包") { NSWorkspace.shared.open(Onboarding.pkgURL) } }
        }
    }

    private var voice: some View {
        StepCard(number: 3, title: "语音输入法", state: model.imeName != nil ? .done : .optional, required: false,
                 detail: model.imeName.map {
                     "已检测到「\($0)」。请确认它的「长按说话」快捷键是 \(model.holdKeyTitle)（不一样的话在菜单栏 Backseat 图标里改），麦克风设为「自动检测」或「跟随系统」。"
                 } ?? "没装也能用：会用 Mac 自带的识别，说完整段上屏。想要边说边出字，推荐装豆包输入法。") {
            if model.imeName == nil { Button("下载豆包输入法") { NSWorkspace.shared.open(Onboarding.doubaoURL) } }
        }
    }

    private var phone: some View {
        StepCard(number: 4, title: "在 iPhone 上安装 Backseat", state: model.connected ? .done : .todo, required: true,
                 detail: "用 iPhone 相机扫右边的二维码，或在 App Store 搜「Backseat」。Apple Watch 版包含在里面。目前只在非中国大陆地区的 App Store 上架。") {
            VStack(spacing: 6) {
                if let qr = Self.qrImage(Onboarding.appStoreURL.absoluteString) {
                    Image(nsImage: qr).interpolation(.none).resizable().frame(width: 88, height: 88)
                }
                Button("打开链接") { NSWorkspace.shared.open(Onboarding.appStoreURL) }.controlSize(.small)
            }
        }
    }

    private var pairing: some View {
        StepCard(number: 5, title: "配对", state: model.connected ? .done : .todo, required: true,
                 detail: model.connected
                     ? "手机已连接。"
                     : "手机和这台 Mac 连同一个 Wi-Fi，打开手机上的 Backseat，选这台 Mac，输入右边的配对码。如果 Mac 询问是否允许传入连接，请选「允许」。") {
            VStack(alignment: .trailing, spacing: 4) {
                HStack(spacing: 4) {
                    ForEach(Array(model.pairCode.enumerated()), id: \.offset) { _, ch in
                        Text(String(ch))
                            .font(.system(size: 20, weight: .semibold, design: .rounded).monospacedDigit())
                            .frame(width: 28, height: 34)
                            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(.quaternary))
                    }
                }
                Text(model.hosts.first ?? "没有网络").font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
    }

    private var claude: some View {
        StepCard(number: 6, title: "Claude Code 审批和提醒", state: model.hooks ? .done : .optional, required: false,
                 detail: model.hooks
                     ? "已自动接入。Claude Code 要执行命令或改文件时，手机和手表上会弹出请求。"
                     : "没有找到 Claude Code 的配置。装好 Claude Code 后重新打开 Backseat，会自动接入。不用 Claude Code 可以跳过。") {
            EmptyView()
        }
    }

    private var footer: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Toggle("登录时自动启动", isOn: Binding(get: { model.loginItem }, set: { model.setLoginItem($0) }))
                    .toggleStyle(.checkbox)
                Text("之后在屏幕右上角菜单栏点 Backseat 图标查看配对码和状态。图标被刘海挡住时，再打开一次 Backseat 就会回到这个窗口。")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button(model.trusted ? "完成" : "稍后再说") { onDone() }
                .keyboardShortcut(.defaultAction)
                .controlSize(.large)
        }
    }

    static func qrImage(_ text: String) -> NSImage? {
        let f = CIFilter.qrCodeGenerator()
        f.message = Data(text.utf8)
        f.correctionLevel = "M"
        guard let out = f.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)) else { return nil }
        let rep = NSCIImageRep(ciImage: out)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }
}

private enum StepState { case done, todo, warn, optional }

private struct StepCard<Accessory: View>: View {
    let number: Int
    let title: String
    let state: StepState
    let required: Bool
    let detail: String
    @ViewBuilder let accessory: () -> Accessory

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            badge
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(title).font(.system(size: 14, weight: .semibold))
                    if !required {
                        Text("可选").font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Capsule().fill(.quaternary))
                    }
                }
                Text(detail).font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            accessory()
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(state == .warn ? Color.orange.opacity(0.6) : Color.primary.opacity(0.08)))
    }

    @ViewBuilder private var badge: some View {
        ZStack {
            Circle().fill(color.opacity(state == .done ? 1 : 0.15)).frame(width: 26, height: 26)
            if state == .done {
                Image(systemName: "checkmark").font(.system(size: 12, weight: .bold)).foregroundStyle(.white)
            } else {
                Text("\(number)").font(.system(size: 12, weight: .semibold)).foregroundStyle(color)
            }
        }
        .accessibilityLabel(state == .done ? "第 \(number) 步，已完成" : "第 \(number) 步，未完成")
    }

    private var color: Color {
        switch state {
        case .done: .green
        case .todo: .accentColor
        case .warn: .orange
        case .optional: .secondary
        }
    }
}
