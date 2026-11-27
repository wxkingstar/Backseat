import SwiftUI

/// 极致语音模式：上 1/3 看状态和电脑输入框里的字，下 2/3 整块是一个大按钮，不看屏幕也能操作。
/// 按住说话、松手进输入框；按住上滑进上面那 1/3 取消；快速左滑清空、右滑发送。
/// 大按钮正上方可以放一排常用键（逗号、换行这些低频操作）
struct VoiceModeView<Keys: View>: View {
    @Environment(PhoneStore.self) private var store
    let talk: TalkController
    let exit: () -> Void
    @ViewBuilder var keys: Keys

    /// 电脑输入框里的字：nil = 这个应用读不出来（比如终端）
    @State private var macText: String? = ""
    /// 这一次按下的时刻和是否已经开始说话
    @State private var downAt: Date?
    /// 这一次按下被认成了快速横滑：-1 左（清空），1 右（发送）
    @State private var swipe = 0
    /// 点了底边的「清空 / 发送」字样：在按钮中间提示改用滑动。-1 清空，1 发送，0 不显示
    @State private var tapHint = 0
    /// 每次提示一个新 id：连着点时，上一次的定时器不会把这次的提示提前收掉
    @State private var tapHintID = UUID()

    var body: some View {
        GeometryReader { geo in
            let bigHeight = VoiceLayout.bigHeight(geo.size.height)
            let bigTop = geo.size.height - bigHeight
            VStack(spacing: 12) {
                // 说话时上面整块（连同按键）都是取消区
                if talk.isLive {
                    cancelZone.frame(height: bigTop - 12)
                } else {
                    VStack(spacing: 12) {
                        topArea
                        keys
                    }
                    .frame(height: bigTop - 12)
                }
                bigButton(bigTop: bigTop, size: geo.size)
                    .frame(height: bigHeight)
            }
            .coordinateSpace(name: "voice")
        }
        .padding(.horizontal, 16)
        .padding(.top, VoiceLayout.topPad)
        .padding(.bottom, VoiceLayout.bottomPad)
        .background(P.bg.ignoresSafeArea())
        .animation(.easeOut(duration: 0.12), value: talk.isLive)
        .task(id: refreshKey) { await pollInput() }
    }

    // MARK: - 上 1/3

    private var topArea: some View {
        VStack(spacing: 12) {
            HStack(spacing: 8) {
                Button(action: exit) {
                    Label("切换模式", systemImage: "arrow.left.arrow.right")
                        .font(.subheadline.weight(.semibold)).foregroundStyle(P.text)
                        .padding(.horizontal, 14).frame(height: 44)
                        .background(Capsule().fill(P.card).stroke(P.line))
                }
                .accessibilityLabel("切换到普通模式")
                Spacer(minLength: 0)
                HStack(spacing: 6) {
                    Circle().fill(store.connected ? P.okText : P.dangerText).frame(width: 6, height: 6)
                    Text(store.connected ? (store.frontApp.isEmpty ? "Mac" : store.frontApp) : "连接中…")
                        .font(.footnote.weight(.semibold)).foregroundStyle(P.textSoft).lineLimit(1)
                }
                .padding(.horizontal, 12).frame(height: 32)
                .background(Capsule().fill(P.card))
            }
            .frame(height: 44)

            preview
        }
    }

    /// 电脑输入框里的字，读回来给你瞄一眼；字多时只留最后几行
    private var preview: some View {
        let text = macText ?? ""
        return VStack(alignment: .leading, spacing: 6) {
            Text("电脑输入框").font(.caption.weight(.semibold)).foregroundStyle(P.text3)
            Group {
                if macText == nil {
                    Text("这个应用读不出输入框里的字，请看电脑").foregroundStyle(P.text2)
                } else if text.isEmpty {
                    Text("空的").foregroundStyle(P.text2)
                } else {
                    Text(text).foregroundStyle(P.text).truncationMode(.head)
                }
            }
            .font(.body)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(P.card))
        .accessibilityElement(children: .combine)
    }

    /// 说话时上 1/3 变成取消区：手指推到这里松开就取消
    private var cancelZone: some View {
        let on = talk.phase == .cancelArmed
        return VStack(spacing: 10) {
            Image(systemName: "xmark").font(.system(size: on ? 34 : 26, weight: .bold))
                .foregroundStyle(on ? .white : P.textSoft)
                .frame(width: on ? 92 : 72, height: on ? 92 : 72)
                .background(Circle().fill(on ? Color(red: 0.9, green: 0.33, blue: 0.29) : P.raised))
            Text(on ? "松开 取消" : "上滑到这里取消")
                .font(on ? .headline : .subheadline)
                .foregroundStyle(on ? P.dangerText : P.text2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(on ? P.dangerBg : .clear)
                .stroke(on ? .clear : P.line, style: StrokeStyle(lineWidth: 1.5, dash: [6, 6]))
        )
        .animation(.spring(duration: 0.25), value: on)
    }

    // MARK: - 下 2/3：大按钮

    private func bigButton(bigTop: CGFloat, size: CGSize) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 32, style: .continuous).fill(fill)
                .overlay(RoundedRectangle(cornerRadius: 32, style: .continuous)
                    .stroke(talk.phase == .idle ? P.raisedLine : .clear, lineWidth: 1.5))
            if tapHint != 0 && !talk.isLive { tapHintView } else { content }
            if !talk.isLive { swipeHints }
        }
        .contentShape(RoundedRectangle(cornerRadius: 32, style: .continuous))
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .named("voice"))
                .onChanged { v in changed(v, bigTop: bigTop) }
                .onEnded { v in ended(v, size: size) }
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("按住说话")
        .accessibilityHint("松手后文字进电脑输入框；往上滑到屏幕上方取消；快速左滑清空，右滑发送")
        .accessibilityAddTraits(.isButton)
    }

    private var fill: Color {
        switch talk.phase {
        case .recording: P.accentFill
        case .cancelArmed: P.raised
        case .delivered: P.ok
        default: P.raised
        }
    }

    @ViewBuilder private var content: some View {
        switch talk.phase {
        case .recording, .cancelArmed:
            let on = talk.phase == .recording
            VStack(spacing: 18) {
                if on {
                    Waveform(level: talk.recorder.level, color: .white).frame(height: 48)
                    Text(Duration.seconds(talk.recorder.elapsed), format: .time(pattern: .minuteSecond))
                        .font(.largeTitle.weight(.semibold).monospacedDigit())
                    Text(talk.engine == "ime" ? "松开 结束 · 文字进电脑输入框" : "松开 结束")
                        .font(.subheadline)
                } else {
                    Text("手指在上方").font(.title3.weight(.semibold))
                    Text("滑回来继续说").font(.subheadline)
                }
            }
            .foregroundStyle(on ? .white : P.text3)
        case .syncing:
            VStack(spacing: 12) {
                ProgressView().tint(P.accent).controlSize(.large)
                Text("正在输入…").font(.headline).foregroundStyle(P.text2)
            }
        case .delivered:
            VStack(spacing: 14) {
                DrawnCheck().frame(width: 52, height: 40)
                Text("已发送").font(.title2.weight(.semibold))
            }
            .foregroundStyle(.white)
        case .failed(let msg):
            Text(msg).font(.headline).foregroundStyle(P.dangerText)
                .multilineTextAlignment(.center).padding(.horizontal, 24)
        case .idle:
            VStack(spacing: 14) {
                Image(systemName: "mic").font(.system(size: 44, weight: .semibold)).foregroundStyle(P.accent)
                Text(hasText ? "按住 接着说" : "按住 说话").font(.title2.weight(.semibold)).tracking(3)
                    .foregroundStyle(P.text)
            }
        }
    }

    /// 底边的左右滑提示：有字可发时才点亮
    private var swipeHints: some View {
        VStack {
            Spacer()
            HStack {
                Label("清空", systemImage: "arrow.left")
                    .foregroundStyle(hasText ? P.dangerText : P.text3)
                Spacer()
                Label { Text("发送") } icon: { Image(systemName: "arrow.right") }
                    .labelStyle(TrailingIcon())
                    .foregroundStyle(hasText ? P.okText : P.text3)
            }
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal, 22).padding(.bottom, 20)
        }
        .allowsHitTesting(false)
    }

    /// 点了底边字样时的提示：清空 / 发送要靠滑，不是点
    private var tapHintView: some View {
        let left = tapHint < 0
        return VStack(spacing: 14) {
            Image(systemName: left ? "arrow.left" : "arrow.right")
                .font(.system(size: 44, weight: .bold))
                .foregroundStyle(left ? P.dangerText : P.okText)
            Text(left ? "向左滑 清空" : "向右滑 发送").font(.title2.weight(.semibold)).foregroundStyle(P.text)
            Text("在大按钮上任意位置快速\(left ? "左" : "右")滑，不用点").font(.subheadline).foregroundStyle(P.text2)
        }
        .transition(.opacity)
    }

    /// 输入框里有没有能发的字（读不出来的应用就按手机这边记的草稿算）
    private var hasText: Bool {
        store.hasDraft || !(macText ?? "").isEmpty
    }

    // MARK: - 手势

    private func changed(_ v: DragGesture.Value, bigTop: CGFloat) {
        if downAt == nil {
            downAt = Date()
            swipe = 0
            // 一碰就开始录，不丢开头的字；如果后面认出是滑动，再悄悄丢掉这一轮
            if talk.phase != .syncing && !talk.isLive { talk.begin(store) }
        }
        guard swipe == 0 else { return }
        let dx = v.translation.width, dy = v.translation.height
        if let t = downAt, Date().timeIntervalSince(t) < VoiceLayout.swipeWindow,
           abs(dx) > VoiceLayout.swipeDistance, abs(dx) > abs(dy) * 2 {
            swipe = dx < 0 ? -1 : 1
            talk.armCancel(false)
            return
        }
        // 手指推进上面那 1/3 就是准备取消
        talk.armCancel(v.location.y < bigTop)
    }

    private func ended(_ v: DragGesture.Value, size: CGSize) {
        let dir = swipe
        let held = downAt.map { Date().timeIntervalSince($0) } ?? 0
        downAt = nil
        swipe = 0
        guard dir != 0 else {
            // 轻点了底边左右两角的「清空 / 发送」字样：这一下不算说话，在中间提示要用滑的
            let moved = hypot(v.translation.width, v.translation.height)
            let corner = v.location.y > size.height - 80
                && (v.location.x < 140 || v.location.x > size.width - 140)
            if held < 0.6 && moved < 20 && corner {
                talk.finish(store, silent: true)
                showTapHint(v.location.x < size.width / 2 ? -1 : 1)
                return
            }
            talk.finish(store)
            return
        }
        // 先等 Mac 结束这一轮（输入法松开），再清空 / 发送，免得按键落在输入法还在听的时候
        let pending = talk.finish(store, silent: true)
        Task {
            await pending?.value
            if dir < 0 {
                store.clearInput()
            } else if hasText {
                talk.send(store)
            } else {
                // 没东西可发：给一下错误震动，告诉你这次什么都没做
                Haptics.error()
            }
        }
    }

    private func showTapHint(_ dir: Int) {
        Haptics.tap()
        let id = UUID()
        tapHintID = id
        withAnimation(.easeOut(duration: 0.15)) { tapHint = dir }
        Task {
            try? await Task.sleep(for: .seconds(2.2))
            if tapHintID == id { withAnimation(.easeOut(duration: 0.2)) { tapHint = 0 } }
        }
    }

    // MARK: - 读回电脑输入框

    private var refreshKey: String {
        "\(store.connected)-\(store.hasDraft)-\(talk.phase)"
    }

    /// 状态一变就读一次，之后每 2 秒读一次（你在电脑上直接改字也能跟上）；说话时不读
    private func pollInput() async {
        guard store.connected, !talk.isLive else { return }
        try? await Task.sleep(for: .milliseconds(300))
        while !Task.isCancelled {
            // 请求本身失败不算「读不出来」，保留上次的内容
            do { macText = try await BridgeClient.shared.inputText() } catch {}
            try? await Task.sleep(for: .seconds(2))
        }
    }
}

/// 极致语音模式的尺寸：大按钮占内容区的 2/3。「所有按键」面板要按它算出浮在哪
enum VoiceLayout {
    static let topPad: CGFloat = 12
    static let bottomPad: CGFloat = 8
    /// 按下后多久内的横向快速移动算滑动手势；超过这个时间就只当在说话
    static let swipeWindow: TimeInterval = 0.35
    static let swipeDistance: CGFloat = 50
    static func bigHeight(_ content: CGFloat) -> CGFloat { (content * 2 / 3).rounded() }
    /// 面板底边离屏幕（安全区）底部的距离：让开大按钮和它上面那排 44pt 的键，再空 8pt
    static func panelBottom(_ screen: CGFloat) -> CGFloat {
        bottomPad + bigHeight(screen - topPad - bottomPad) + 12 + 44 + 8
    }
}

/// 图标放在文字右边
private struct TrailingIcon: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) { configuration.title; configuration.icon }
    }
}
