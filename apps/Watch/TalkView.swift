import SwiftUI
import WatchKit

/// 主页：按住说话，松手发送到 Mac。
struct TalkView: View {
    @Environment(Store.self) private var store
    @State private var recorder = Recorder()
    @State private var phase: Phase = .idle
    @State private var showFeed = false
    @State private var showSettings = false
    @State private var mic: MicSession?
    @State private var engine = ""

    enum Phase: Equatable {
        case idle, recording, cancelArmed, sending, delivered
        case sent(String), failed(String)
    }

    private let size: CGFloat = 100
    private let pad: CGFloat = 16        // 声波圈外扩的空间

    var body: some View {
        // 按整块屏幕定位（49mm Ultra 约 211×257pt）：
        // 顶部一行是系统时间和左右工具栏按钮，状态夹在两个按钮之间、时间下方；
        // 中间是说话按钮；底部一排三个操作键。
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            ZStack {
                StatusLine { showFeed = true }
                    .frame(width: w - 120)
                    .position(x: w / 2, y: 47)
                    .opacity(isLive ? 0.3 : 1)

                talkButton
                    .position(x: w / 2, y: h * 0.47)

                hint
                    .frame(width: w - 24)
                    .position(x: w / 2, y: h * 0.47 + size / 2 + 20)

                // 两边略高、中间略低，贴合表盘底部的圆角
                ActionKey(icon: "xmark", tint: Theme.danger, label: "清空输入框") { clearInput() }
                    .position(x: w * 0.2, y: h - 37)
                ActionKey(icon: "delete.left.fill", tint: .gray, label: "退格", repeats: true) { store.press("backspace") }
                    .position(x: w / 2, y: h - 30)
                ActionKey(icon: "arrow.up", tint: Theme.ok, label: "发送") { sendInput() }
                    .position(x: w * 0.8, y: h - 37)
            }
            .disabled(!store.connected)
        }
        .ignoresSafeArea()
        .toolbar {
            ToolbarItem(placement: .topBarLeading) { RemoteButton() }
            ToolbarItem(placement: .topBarTrailing) {
                Button { showSettings = true } label: { Image(systemName: "gearshape.fill") }
                    .accessibilityLabel("设置")
            }
        }
        .sheet(isPresented: $showFeed) { NavigationStack { FeedView() } }
        .sheet(isPresented: $showSettings) { NavigationStack { SettingsView() } }
        // Action Button：没在说就开始，正在说就结束
        .onChange(of: store.talkToggle) { _, _ in sideButtonPressed() }
        // App 是被侧键冷启动的：上面的 onChange 赶不上，界面出现后在这里补上
        .task { if store.talkPending { sideButtonPressed() } }
        .onChange(of: recorder.elapsed) { _, t in
            if t >= Recorder.maxDuration, phase == .recording { finish() }
        }
    }

    // MARK: - 按钮

    private var isLive: Bool { phase == .recording || phase == .cancelArmed }

    private var talkButton: some View {
        ZStack {
            // 声波圈：跟随音量扩散
            ForEach(0..<2) { i in
                Circle()
                    .stroke(Theme.accent.opacity(0.45 - Double(i) * 0.2), lineWidth: 3)
                    .scaleEffect(phase == .recording ? 1.04 + recorder.level * (0.22 + Double(i) * 0.14) : 1)
                    .opacity(phase == .recording ? 1 : 0)
            }
            .frame(width: size, height: size)
            .animation(.easeOut(duration: 0.12), value: recorder.level)

            Circle()
                .fill(buttonFill)
                .frame(width: size, height: size)
                .shadow(color: Theme.accent.opacity(isLive ? 0.55 : 0.25), radius: isLive ? 14 : 6)
                .scaleEffect(phase == .recording || phase == .delivered ? 1.06 : 1)

            VStack(spacing: 4) {
                if phase == .delivered {
                    HandwrittenCheck()
                        .frame(width: 46, height: 36)
                } else if phase == .sending {
                    ProgressView().tint(.white)
                } else {
                    Image(systemName: phase == .cancelArmed ? "xmark" : "mic.fill")
                        .font(.system(size: 38, weight: .semibold))
                        .contentTransition(.symbolEffect(.replace))
                }
                if isLive {
                    Text(Duration.seconds(recorder.elapsed), format: .time(pattern: .minuteSecond))
                        .font(.system(.footnote, design: .rounded).monospacedDigit().weight(.medium))
                        .opacity(0.9)
                }
            }
            .foregroundStyle(.white)
        }
        .frame(width: size + pad, height: size + pad)
        .contentShape(Circle().inset(by: 10))
        .opacity(store.connected ? 1 : 0.4)
        .animation(.spring(duration: 0.25), value: phase)
        .highPriorityGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { v in
                    if !isLive && phase != .sending { begin(); return }
                    guard isLive else { return }
                    // 按住往上滑超过 40pt = 准备取消（松手后删掉这一轮说的字）
                    let next: Phase = v.translation.height < -40 ? .cancelArmed : .recording
                    if next != phase {
                        WKInterfaceDevice.current().play(.click)
                        phase = next
                    }
                }
                .onEnded { _ in
                    if isLive { finish() }
                }
        )
        .accessibilityLabel("按住说话")
    }

    private var buttonFill: AnyShapeStyle {
        switch phase {
        case .cancelArmed:
            return AnyShapeStyle(Color.gray.opacity(0.5))
        case .sending:
            return AnyShapeStyle(Theme.accentDeep)
        case .delivered:
            return AnyShapeStyle(Theme.ok)
        default:
            return AnyShapeStyle(LinearGradient(colors: [Theme.accent, Theme.accentDeep],
                                                startPoint: .top, endPoint: .bottom))
        }
    }

    // MARK: - 提示

    @ViewBuilder private var hint: some View {
        switch phase {
        case .idle:
            Text(store.connected ? "按住说话" : "未连接 Mac")
                .font(.footnote).foregroundStyle(.secondary)
        case .recording:
            Text(engine == "ime" ? "输入法在听 · 上滑取消" : "松手结束 · 上滑取消")
                .font(.footnote).foregroundStyle(.secondary)
        case .cancelArmed:
            Text("松开取消，删除这一轮").font(.footnote.weight(.semibold)).foregroundStyle(Theme.danger)
        case .sending:
            Text("识别中…").font(.footnote).foregroundStyle(.secondary)
        case .delivered:
            Text("已发送").font(.footnote.weight(.semibold)).foregroundStyle(Theme.ok)
        case .sent(let text):
            Text(text)
                .font(.footnote)
                .lineLimit(1)
                .multilineTextAlignment(.center)
                .foregroundStyle(Theme.ok)
        case .failed(let msg):
            Text(msg).font(.footnote).foregroundStyle(Theme.danger)
                .multilineTextAlignment(.center).lineLimit(1).minimumScaleFactor(0.8)
        }
    }

    // MARK: - 流程

    /// 侧键：没在说就开始，正在说就结束。
    /// 侧键按下时 App 可能还在从后台切回前台，这时开麦克风会失败，所以等 App 真正到前台、连上 Mac 再开始
    private func sideButtonPressed() {
        store.talkPending = false
        remoteLog("手表侧键：当前\(isLive ? "正在录音" : "空闲")，连接=\(store.connected)，前台=\(WKApplication.shared().applicationState == .active)")
        if isLive { finish(); return }
        guard phase != .sending else { return }
        Task {
            for _ in 0..<30 {
                if WKApplication.shared().applicationState == .active && store.connected { break }
                try? await Task.sleep(for: .milliseconds(100))
            }
            begin()
            if !isLive {
                // 第一次没开起来（音频还没就绪）：稍等再试一次
                try? await Task.sleep(for: .milliseconds(700))
                begin()
            }
            remoteLog("手表侧键：\(isLive ? "已开始录音" : "没能开始录音（\(phase)）")")
        }
    }

    private func remoteLog(_ text: String) {
        Task { _ = try? await BridgeClient.shared.call("POST", "/api/log", body: ["text": text], timeout: 3) }
    }

    private func begin() {
        guard store.connected else {
            WKInterfaceDevice.current().play(.failure)
            settle(.failed("未连接 Mac"))
            return
        }
        switch recorder.permission {
        case .undetermined:
            phase = .failed("请允许使用麦克风")
            Task {
                let ok = await recorder.requestPermission()
                settle(ok ? .failed("好了，再按住说话") : .failed("麦克风被拒绝，请到设置里打开"))
            }
            return
        case .denied:
            settle(.failed("麦克风被拒绝，请到设置里打开"))
            return
        default:
            break
        }
        let s = MicSession()
        do {
            try recorder.start { seq, pcm in Task { await s.push(seq, pcm) } }
        } catch {
            settle(.failed("录音启动失败"))
            return
        }
        mic = s
        phase = .recording
        WKInterfaceDevice.current().play(.start)
        // 录音已经开始，同时通知 Mac 开麦（输入法模式会按下语音快捷键）
        Task {
            do {
                engine = try await BridgeClient.shared.micStart(id: s.id)
                await s.open()
            } catch {
                await s.fail()
            }
        }
    }

    private func finish() {
        guard let s = mic else { return }
        mic = nil
        let duration = recorder.elapsed
        let lastSeq = recorder.stop()
        // 太短也按取消处理，但仍要通知 Mac 松开 Fn
        let cancel = phase == .cancelArmed || duration < 0.6
        if cancel {
            WKInterfaceDevice.current().play(.directionDown)
            settle(phase == .cancelArmed ? .idle : .failed("按住不放，说完再松手"))
        } else {
            phase = .sending
            WKInterfaceDevice.current().play(.click)
        }
        Task {
            guard await s.drain() else {
                if !cancel {
                    WKInterfaceDevice.current().play(.failure)
                    settle(.failed("Mac 没响应，再试一次"))
                }
                return
            }
            do {
                let (eng, text) = try await BridgeClient.shared.micEnd(id: s.id, lastSeq: lastSeq,
                                                                       submit: false, cancel: cancel)
                guard !cancel else { return }
                WKInterfaceDevice.current().play(.success)
                settle(.sent(eng == "ime" ? "已输入，可修改后发送" : "“\(text)”"), after: 3)
            } catch {
                guard !cancel else { return }
                WKInterfaceDevice.current().play(.failure)
                settle(.failed(error.localizedDescription))
            }
        }
    }

    // MARK: - 底部操作：清空 / 退格 / 发送

    /// 发送：回车送达后整个按钮变绿、画出对勾
    private func sendInput() {
        Task {
            do {
                try await BridgeClient.shared.press("enter")
                WKInterfaceDevice.current().play(.success)
                phase = .delivered
                try? await Task.sleep(for: .seconds(1.6))
                if phase == .delivered { phase = .idle }
            } catch {
                WKInterfaceDevice.current().play(.failure)
                settle(.failed("发送失败"))
            }
        }
    }

    private func clearInput() {
        WKInterfaceDevice.current().play(.directionDown)
        store.clearInput()
        settle(.failed("已清空"), after: 1.5)
    }

    /// 显示一个结果状态，过几秒回到待机
    private func settle(_ p: Phase, after seconds: Double = 2.5) {
        phase = p
        guard p != .idle else { return }
        Task {
            try? await Task.sleep(for: .seconds(seconds))
            if phase == p { phase = .idle }
        }
    }
}

// MARK: - 状态（顶部两个工具栏按钮之间，点击看动态）

struct StatusLine: View {
    @Environment(Store.self) private var store
    var onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 4) {
                Dot(color: color, size: 5)
                Text(title).font(.caption2.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.8)
                if let w = store.working, store.connected {
                    Text(w.since, style: .timer)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .fixedSize()
                }
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint("查看动态")
    }

    private var last: FeedItem? { store.feed.first { ["done", "idle"].contains($0.kind) } }

    private var title: String {
        if !store.connected { return store.everConnected ? "已断开" : "连接中" }
        if store.working != nil { return "工作中" }
        if let l = last { return l.kind == "done" ? "完成" : "等你回复" }
        return "空闲"
    }

    private var color: Color {
        if !store.connected { return Theme.danger }
        if store.working != nil { return Theme.accent }
        if let l = last { return l.kind == "done" ? Theme.ok : Theme.warn }
        return .gray
    }
}

// MARK: - 遥控模式开关（工具栏）

struct RemoteButton: View {
    @Environment(Store.self) private var store

    var body: some View {
        Button {
            store.setRemote(!store.remote)
        } label: {
            if store.remoteBusy {
                ProgressView()
            } else {
                Image(systemName: store.remote ? "figure.walk" : "laptopcomputer")
                    .foregroundStyle(store.remote ? Theme.ok : .white)
            }
        }
        .disabled(!store.connected || store.remoteBusy)
        .accessibilityLabel(store.remote ? "遥控模式已开启" : "开启遥控模式")
    }
}

// MARK: - 底部操作键

/// 圆形操作键。repeats = true 时按住会连续触发（退格）。
struct ActionKey: View {
    let icon: String
    let tint: Color
    let label: String
    var repeats = false
    let action: () -> Void

    /// 手指是否按着。用 GestureState：手势被系统打断（放下手腕、弹出审批、别的手势抢走）时也会自动复位，
    /// 不会出现松手了还在一直删的情况
    @GestureState private var pressed = false
    /// 这一次按下已经触发过第一下了
    @State private var fired = false
    private let size: CGFloat = 44

    var body: some View {
        Image(systemName: icon)
            .font(.system(size: 18, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(Circle().fill(tint.opacity(pressed ? 1 : 0.8)))
            .scaleEffect(pressed ? 0.9 : 1)
            .animation(.spring(duration: 0.15), value: pressed)
            .contentShape(Circle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .updating($pressed) { _, down, _ in down = true }
                    // 连删键的第一下在手指碰到的那一刻就触发。不能放进下面的任务里：
                    // 点得很快时，按下和抬起落在同一帧，界面看不到 pressed 变过，任务根本不会启动
                    .onChanged { _ in
                        guard repeats, !fired else { return }
                        fired = true
                        WKInterfaceDevice.current().play(.click)
                        action()
                    }
                    .onEnded { _ in
                        fired = false
                        if !repeats { action() }
                    }
            )
            // 手势被打断时没有 onEnded，靠 pressed 复位
            .onChange(of: pressed) { _, down in if !down { fired = false } }
            // 按住不放的连删。跟着 pressed 走：一松手（或手势被打断、按键从屏幕上消失）这个任务就被取消
            .task(id: pressed) {
                guard repeats, pressed else { return }
                await repeatWhilePressed()
            }
            .accessibilityLabel(label)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { action() }
    }

    /// 按住 0.4 秒后每 0.08 秒删一个（第一个在按下时已经删了）
    private func repeatWhilePressed() async {
        try? await Task.sleep(for: .milliseconds(400))
        while !Task.isCancelled {
            action()
            try? await Task.sleep(for: .milliseconds(80))
        }
    }
}

/// 手写效果的对勾：按钮变绿后停一下，先慢写短笔，再快速划出长笔，写完轻弹一下。
/// 独立成视图，出现后才从 0 开始描线（和状态切换放在同一帧会直接显示终态，看不到过程）。
struct HandwrittenCheck: View {
    @State private var progress: CGFloat = 0
    @State private var pop = false

    var body: some View {
        CheckShape()
            .trim(from: 0, to: progress)
            .stroke(.white, style: StrokeStyle(lineWidth: 7, lineCap: .round, lineJoin: .round))
            .scaleEffect(pop ? 1.12 : 1)
            .onAppear {
                progress = 0
                Task {
                    try? await Task.sleep(for: .milliseconds(120))
                    // 短笔约占路径前 30%：慢一点，像落笔
                    withAnimation(.easeIn(duration: 0.18)) { progress = 0.3 }
                    try? await Task.sleep(for: .milliseconds(180))
                    // 长笔：快速上挑
                    withAnimation(.easeOut(duration: 0.26)) { progress = 1 }
                    try? await Task.sleep(for: .milliseconds(240))
                    withAnimation(.spring(response: 0.22, dampingFraction: 0.45)) { pop = true }
                    try? await Task.sleep(for: .milliseconds(140))
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.7)) { pop = false }
                }
            }
    }
}

/// 对勾路径（配合 trim 做描线动画）
struct CheckShape: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.midY))
        p.addLine(to: CGPoint(x: r.minX + r.width * 0.36, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY))
        return p
    }
}
