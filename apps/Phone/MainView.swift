import SwiftUI

/// 唯一的主屏：上 状态，中 触控板，下 快捷短语 / 预览框、常用键、按住说话。
struct MainView: View {
    @Environment(PhoneStore.self) private var store
    @State private var talk = TalkController.shared
    @State private var showKeys = false
    @State private var showSettings = false
    @State private var showPad = false
    @State private var showInbox = false


    var body: some View {
        GeometryReader { geo in
            // iPhone Duo 外屏右侧有一条系统状态栏，安全区右边距很宽；状态下面的空白放常用键
            let side = geo.safeAreaInsets.trailing
            let hasSide = side > 60
            ZStack(alignment: .bottomTrailing) {
                mainLayer(hasSide: hasSide)
                if hasSide && !talk.isLive {
                    // 收在右侧状态栏的右下角，和底部说话条底边对齐，拇指够得着
                    SideKeys(talk: talk, showKeys: $showKeys)
                        .padding(.bottom, 14)
                        // 和上面的系统状态图标同一条中线（距屏幕右缘约 48pt）
                        .offset(x: side - 48 + SideKeys.size / 2)
                }
            }
        }
        .overlay(alignment: .top) { toast }
        .sheet(isPresented: $showKeys) {
            MoreKeysSheet().presentationDetents([.height(380)]).presentationDragIndicator(.visible)
        }
        // 全屏触控板：只留触控板，避免误触别的按钮
        .fullScreenCover(isPresented: $showPad) {
            ZStack {
                P.bg.ignoresSafeArea()
                TrackpadView(fullScreen: true) { showPad = false }
                    .padding(.horizontal, 12).padding(.vertical, 12)
            }
            .environment(store)
            .preferredColorScheme(.dark)
        }
        .sheet(isPresented: $showInbox) { InboxSheet() }
        .sheet(isPresented: $showSettings) {
            SettingsSheet().presentationDetents([.medium, .large])
        }
        .sheet(item: Binding(get: { store.pending.first }, set: { _ in })) { a in
            ApprovalSheet(approval: a).presentationDetents([.height(420)]).interactiveDismissDisabled()
        }
        .onAppear {
            store.startPolling()
            talk.recorder.prewarm()
            // 提前下载手机端的识别模型，离线时收件箱才能转文字
            Task { await PhoneTranscriber.prepare(); Inbox.shared.retryPending() }
        }
    }

    private func mainLayer(hasSide: Bool) -> some View {
        ZStack {
            P.bg.ignoresSafeArea()

            VStack(spacing: 12) {
                header
                StatusCard()
                if !Inbox.shared.items.isEmpty { InboxBanner { showInbox = true } }
                TrackpadView { showPad = true }
                // 全部隐藏时不占位置，触控板更大
                if !store.visiblePhrases.isEmpty { phraseGrid }
                // iPhone Duo：常用键都在右侧栏，这里不再放按键行，触控板更大
                if !hasSide { keyRow(compact: false) }
                TalkBar(talk: talk)
            }
            .padding(.horizontal, 16)
            // 顶部至少留 12pt：iPhone Duo 外屏顶部没有安全区，内容会顶到边上
            .padding(.top, 12)
            .padding(.bottom, 8)
            .animation(.spring(response: 0.32, dampingFraction: 0.86), value: store.visiblePhrases)

            if talk.isLive {
                RecordingOverlay(talk: talk)
                    .transition(.opacity)
            }
        }
        // 进场要快（跟手），退场稍慢一点
        .animation(talk.isLive ? .easeOut(duration: 0.08) : .easeOut(duration: 0.16), value: talk.isLive)
    }

    // MARK: - 顶部

    private var header: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Circle().fill(store.connected ? P.okText : P.dangerText).frame(width: 6, height: 6)
                Text(store.connected ? "Mac · \(store.frontApp.isEmpty ? "—" : store.frontApp)" : "连接中…")
                    .font(.footnote.weight(.semibold)).foregroundStyle(Color(white: 0.79))
                    .lineLimit(1)
            }
            .padding(.horizontal, 12).frame(height: 32)
            .background(Capsule().fill(P.card))

            Spacer(minLength: 0)

            Button { store.setRemote(!store.remote) } label: {
                Label(store.remote ? "遥控中" : "离开电脑", systemImage: store.remote ? "figure.walk.motion" : "figure.walk")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(store.remote ? P.okText : .white)
                    .padding(.horizontal, 14).frame(height: 44)
                    .background(Capsule().fill(P.card).stroke(store.remote ? P.okText.opacity(0.5) : P.line))
            }
            .disabled(!store.connected || store.remoteBusy)
            .accessibilityHint("开启后，Claude 的权限审批会发到手机")

            Button { showSettings = true } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 17, weight: .semibold)).foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(Circle().fill(P.card).stroke(P.line))
            }
            .accessibilityLabel("设置")
        }
        .frame(height: 44)
    }

    // MARK: - 快捷短语（两列，内容在设置里配置）

    private var phraseGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
            ForEach(store.visiblePhrases) { p in
                Button { store.send(p.text) } label: {
                    Text(p.text).font(.subheadline).foregroundStyle(.white).lineLimit(1).minimumScaleFactor(0.8)
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(PressStyle(fill: P.card, radius: 14))
            }
        }
        .disabled(!store.connected)
    }

    // MARK: - 常用键

    /// compact：逗号、换行已经放到右侧栏（iPhone Duo），这一排只留其余的键
    private func keyRow(compact: Bool) -> some View {
        HStack(spacing: 8) {
            if !compact {
                keyButton(label: "，", font: .system(size: 20, weight: .bold), a11y: "逗号") { store.insert("，") }
            }
            keyButton(label: "⌘⏎", font: .system(size: 15, weight: .bold), a11y: "Command 加回车") { store.press("cmd+enter") }
            if !compact {
                keyButton(label: "换行", font: .system(size: 14, weight: .semibold), a11y: "换行") { store.newline() }
            }
            BackspaceKey()
            Button { showKeys = true } label: {
                Image(systemName: "keyboard").font(.system(size: 18, weight: .semibold)).foregroundStyle(.white)
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(PressStyle(fill: P.key, radius: 12))
            .accessibilityLabel("更多按键")
        }
        .disabled(!store.connected)
    }

    private func keyButton(label: String, font: Font, a11y: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label).font(font).foregroundStyle(.white).frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(PressStyle(fill: P.key, radius: 12))
        .accessibilityLabel(a11y)
    }

    @ViewBuilder private var toast: some View {
        if let t = store.toast {
            Text(t)
                .font(.subheadline.weight(.medium))
                .padding(.horizontal, 16).padding(.vertical, 10)
                .background(.ultraThinMaterial, in: Capsule())
                .padding(.top, 4)
                .transition(.move(edge: .top).combined(with: .opacity))
        }
    }
}

/// 按下：立刻轻震 + 变亮 + 缩小，松开用弹簧回弹；只改亮度和缩放，不挪动布局
struct PressStyle: ButtonStyle {
    var fill: Color
    var radius: CGFloat
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(fill))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(Color.white.opacity(configuration.isPressed ? 0.1 : 0)))
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(configuration.isPressed ? .easeOut(duration: 0.08)
                       : .spring(response: 0.3, dampingFraction: 0.55), value: configuration.isPressed)
            .onChange(of: configuration.isPressed) { _, down in if down { Haptics.press() } }
    }
}

/// 退格：点一下删一个，按住 0.4 秒后连续删
struct BackspaceKey: View {
    @Environment(PhoneStore.self) private var store
    @State private var repeater: Task<Void, Never>?
    @State private var pressed = false

    var body: some View {
        Image(systemName: "delete.left")
            .font(.system(size: 18, weight: .semibold)).foregroundStyle(.white)
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(P.key))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(pressed ? 0.1 : 0)))
            .scaleEffect(pressed ? 0.94 : 1)
            .animation(pressed ? .easeOut(duration: 0.08) : .spring(response: 0.3, dampingFraction: 0.55), value: pressed)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard !pressed else { return }
                        pressed = true
                        Haptics.press()
                        store.backspace()
                        repeater = Task {
                            try? await Task.sleep(for: .milliseconds(400))
                            while !Task.isCancelled {
                                Haptics.tap()
                                store.backspace()
                                try? await Task.sleep(for: .milliseconds(80))
                            }
                        }
                    }
                    .onEnded { _ in
                        pressed = false
                        repeater?.cancel()
                        repeater = nil
                    }
            )
            .accessibilityLabel("退格，按住连续删除")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { store.backspace() }
    }
}

/// iPhone Duo 右侧栏：系统状态图标下方的一列圆键，靠下对齐
struct SideKeys: View {
    static let size: CGFloat = 44
    static let gap: CGFloat = 8
    static var width: CGFloat { size * 2 + gap }
    @Environment(PhoneStore.self) private var store
    let talk: TalkController
    @Binding var showKeys: Bool

    var body: some View {
        // 单列竖排：和 iOS 27.1 在 iPhone Duo 上把工具栏竖排在状态栏下方的做法一致；回车在最下面，拇指最顺手
        // 从上到下：键盘、⌘⏎、退格、逗号、换行。越常用越靠下，离拇指越近
        VStack(spacing: Self.gap) {
            key(label: "更多按键") { Image(systemName: "keyboard") } action: { showKeys = true }
            key(label: "Command 加回车") { combo("command") } action: { store.press("cmd+enter") }
            SmallBackspace()
            // 逗号用画出来的字形：全角「，」在字框里偏左下，放进圆键里会歪
            key(label: "逗号") { CommaGlyph().fill(.white).frame(width: 9, height: 14) } action: { store.insert("，") }
            // 换行 = ⇧⏎，和上面的 ⌘⏎ 是一对
            key(label: "换行") { combo("shift") } action: { store.newline() }
        }
        .disabled(!store.connected)
    }

    /// 修饰键 + 回车 的组合图标
    private func combo(_ modifier: String) -> some View {
        HStack(spacing: 1.5) {
            Image(systemName: modifier).font(.system(size: 12, weight: .bold))
            Image(systemName: "return").font(.system(size: 12, weight: .bold))
        }
    }

    private func key<L: View>(label: String, @ViewBuilder _ content: () -> L, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            content().font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                .frame(width: Self.size, height: Self.size)
        }
        .buttonStyle(PressStyle(fill: P.key, radius: Self.size / 2))
        .accessibilityLabel(label)
    }
}

/// 小号退格：点一下删一个，按住连删
struct SmallBackspace: View {
    @Environment(PhoneStore.self) private var store
    @State private var repeater: Task<Void, Never>?
    @State private var pressed = false

    var body: some View {
        Image(systemName: "delete.left")
            .font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
            .frame(width: SideKeys.size, height: SideKeys.size)
            .background(Circle().fill(P.key))
            .overlay(Circle().fill(Color.white.opacity(pressed ? 0.1 : 0)))
            .scaleEffect(pressed ? 0.92 : 1)
            .animation(pressed ? .easeOut(duration: 0.08) : .spring(response: 0.3, dampingFraction: 0.55), value: pressed)
            .contentShape(Circle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard !pressed else { return }
                        pressed = true
                        Haptics.press()
                        store.backspace()
                        repeater = Task {
                            try? await Task.sleep(for: .milliseconds(400))
                            while !Task.isCancelled {
                                Haptics.tap()
                                store.backspace()
                                try? await Task.sleep(for: .milliseconds(80))
                            }
                        }
                    }
                    .onEnded { _ in
                        pressed = false
                        repeater?.cancel()
                        repeater = nil
                    }
            )
            .accessibilityLabel("退格，按住连续删除")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { store.backspace() }
    }
}

/// 逗号字形：圆头 + 向左下收的尾巴，自己画保证在圆键里居中
struct CommaGlyph: Shape {
    func path(in r: CGRect) -> Path {
        let w = r.width, h = r.height
        let d = w * 0.78                      // 圆头直径
        var p = Path()
        p.addEllipse(in: CGRect(x: r.minX + w - d, y: r.minY, width: d, height: d))
        p.move(to: CGPoint(x: r.minX + w, y: r.minY + d * 0.45))
        p.addQuadCurve(to: CGPoint(x: r.minX + w * 0.1, y: r.minY + h),
                       control: CGPoint(x: r.minX + w * 1.05, y: r.minY + h * 0.82))
        p.addQuadCurve(to: CGPoint(x: r.minX + w * 0.55, y: r.minY + d * 0.8),
                       control: CGPoint(x: r.minX + w * 0.6, y: r.minY + h * 0.8))
        p.closeSubpath()
        return p
    }
}
