import SwiftUI

/// 唯一的主屏：上 状态，中 触控板，下 快捷短语 / 预览框、常用键、按住说话。
struct MainView: View {
    @Environment(PhoneStore.self) private var store
    @State private var talk = TalkController.shared
    /// 「所有按键」展开着：浮出一块面板，放没摆出来的那些键
    @State private var showAllKeys = ProcessInfo.processInfo.arguments.contains("-showAllKeys")
    // 启动参数 -showSettings：直接打开设置页，调界面时截图用
    @State private var showSettings = ProcessInfo.processInfo.arguments.contains("-showSettings")
    @State private var showPad = false
    @State private var showInbox = false
    /// 极致语音模式：主屏换成一个大按钮。默认就是这个模式，切换后记住上次用的模式。启动参数 -voiceMode NO 可直接看普通模式
    @AppStorage("voiceMode") private var voiceMode = true


    var body: some View {
        // 导航栈只用来把设置页推进来（整页，能右滑返回）；主屏自己不显示导航栏
        NavigationStack {
            GeometryReader { geo in
                // iPhone Duo 外屏右侧有一条系统状态栏，安全区右边距很宽；状态下面的空白放常用键
                let side = geo.safeAreaInsets.trailing
                let hasSide = side > 60
                ZStack(alignment: .bottomTrailing) {
                    if voiceMode {
                        VoiceModeView(talk: talk, exit: { voiceMode = false }) {
                            // iPhone Duo 的常用键在右侧栏，这里不再放
                            if !hasSide { keyRow(compact: false) }
                        }
                            .overlay(alignment: .top) { toast.padding(.top, 56) }
                            .animation(.spring(response: 0.3, dampingFraction: 0.85), value: store.toast)
                    } else {
                        mainLayer(hasSide: hasSide)
                    }
                    if hasSide && !talk.isLive {
                        // 收在右侧状态栏的右下角，和底部说话条底边对齐，拇指够得着
                        SideKeys(talk: talk, expanded: $showAllKeys)
                            // 胶囊底边离屏幕底 24pt，和系统、其他 App 在这一栏的位置一致（要减掉底部安全区）
                            .padding(.bottom, 24 - geo.safeAreaInsets.bottom)
                            // 和上面的系统状态图标同一条中线（距屏幕右缘约 48pt）
                            .offset(x: side - 48 + SideKeys.cell / 2)
                    }
                    if showAllKeys && !talk.isLive {
                        // 点面板以外的地方收起
                        Color.clear.contentShape(Rectangle()).onTapGesture { showAllKeys = false }
                        AllKeysPanel(kinds: hiddenKeys(hasSide: hasSide))
                            .padding(.trailing, 12)
                            // 浮在说话条上方（普通 iPhone 还要让开那一排常用键）；极致语音模式下浮在大按钮上方那排键的上面
                            .padding(.bottom, hasSide ? 84 : voiceMode ? VoiceLayout.panelBottom(geo.size.height) : 140)
                            .transition(.scale(scale: 0.9, anchor: .bottomTrailing).combined(with: .opacity))
                    }
                }
            }
            .animation(.spring(response: 0.28, dampingFraction: 0.82), value: showAllKeys)
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(isPresented: $showSettings) { SettingsPage() }
        }
        // 全屏触控板：只留触控板，避免误触别的按钮
        .fullScreenCover(isPresented: $showPad) {
            ZStack {
                P.bg.ignoresSafeArea()
                TrackpadView(fullScreen: true) { showPad = false }
                    .padding(.horizontal, 12).padding(.vertical, 12)
            }
            .environment(store)
        }
        .sheet(isPresented: $showInbox) { InboxSheet() }
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

    /// 没摆出来的键：iPhone Duo 是右侧栏里没放的；普通 iPhone 是底下那排常用键以外的
    private func hiddenKeys(hasSide: Bool) -> [SideKeyKind] {
        let shown: [SideKeyKind] = hasSide ? store.sideKeys : [.comma, .cmdEnter, .newline, .backspace]
        return SideKeyKind.allCases.filter { $0 != .more && !shown.contains($0) }
    }

    private func mainLayer(hasSide: Bool) -> some View {
        ZStack {
            P.bg.ignoresSafeArea()

            VStack(spacing: 12) {
                header
                StatusCard()
                if !Inbox.shared.items.isEmpty { InboxBanner { showInbox = true } }
                TrackpadView { showPad = true }
                    // 提示浮在触控板底部：不挡顶部的状态和按钮，又离下面刚点的按键近
                    .overlay(alignment: .bottom) { toast }
                    .animation(.spring(response: 0.3, dampingFraction: 0.85), value: store.toast)
                // 全部隐藏时不占位置，触控板更大
                if !store.visiblePhrases.isEmpty { phraseGrid }
                // iPhone Duo：常用键都在右侧栏，这里不再放按键行，触控板更大
                if !hasSide { keyRow(compact: false) }
                TalkBar(talk: talk)
            }
            .padding(.horizontal, 16)
            // iPhone Duo 外屏顶部没有安全区，内容会顶到边上，留 24pt（和屏幕圆角的弧度错开）；普通 iPhone 有安全区，12pt 就够
            .padding(.top, hasSide ? 24 : 12)
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
                    .font(.footnote.weight(.semibold)).foregroundStyle(P.textSoft)
                    .lineLimit(1)
            }
            .padding(.horizontal, 12).frame(height: 32)
            .background(Capsule().fill(P.card))

            Spacer(minLength: 0)

            Button { store.setRemote(!store.remote) } label: {
                Label(store.remote ? "遥控中" : "离开电脑", systemImage: store.remote ? "figure.walk.motion" : "figure.walk")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(store.remote ? P.okText : P.text)
                    .padding(.horizontal, 14).frame(height: 44)
                    .background(Capsule().fill(P.card).stroke(store.remote ? P.okText.opacity(0.5) : P.line))
            }
            .disabled(!store.connected || store.remoteBusy)
            .accessibilityHint("开启后，Claude 的权限审批会发到手机")

            Button { voiceMode = true } label: {
                Image(systemName: "waveform")
                    .font(.system(size: 17, weight: .semibold)).foregroundStyle(P.text)
                    .frame(width: 44, height: 44)
                    .background(Circle().fill(P.card).stroke(P.line))
            }
            .accessibilityLabel("极致语音模式")
            .accessibilityHint("整个下半屏变成一个按住说话的大按钮，不用看屏幕")

            Button { showSettings = true } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 17, weight: .semibold)).foregroundStyle(P.text)
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
                    Text(p.text).font(.subheadline).foregroundStyle(P.text).lineLimit(1).minimumScaleFactor(0.8)
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
            Button { showAllKeys.toggle() } label: {
                Image("key-more").resizable().scaledToFit().frame(height: 22)
                    .foregroundStyle(showAllKeys ? .white : P.text)
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(PressStyle(fill: showAllKeys ? P.accentFill : P.key, radius: 12))
            .accessibilityLabel("所有按键")
        }
        .disabled(!store.connected)
    }

    private func keyButton(label: String, font: Font, a11y: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label).font(font).foregroundStyle(P.text).frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(PressStyle(fill: P.key, radius: 12))
        .accessibilityLabel(a11y)
    }

    @ViewBuilder private var toast: some View {
        if let t = store.toast {
            let undo = store.toastUndo != nil
            HStack(spacing: 4) {
                Text(t)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(2).multilineTextAlignment(.center)
                    .padding(.vertical, 10)
                if undo {
                    Button("撤回") { store.undoToast() }
                        .font(.subheadline.weight(.semibold)).foregroundStyle(P.accent)
                        .fixedSize()
                        .padding(.horizontal, 10).frame(minHeight: 44)
                        .contentShape(Rectangle())
                }
            }
            .padding(.leading, 16).padding(.trailing, undo ? 6 : 16)
            .background(.regularMaterial, in: Capsule())
            .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
            .padding(.horizontal, 12).padding(.bottom, 12)
            // 没有撤回按钮时只是提示，不挡触控板的手势
            .allowsHitTesting(undo)
            .transition(.move(edge: .bottom).combined(with: .opacity))
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
                .fill(P.text.opacity(configuration.isPressed ? 0.1 : 0)))
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(configuration.isPressed ? .easeOut(duration: 0.08)
                       : .spring(response: 0.3, dampingFraction: 0.55), value: configuration.isPressed)
            .onChange(of: configuration.isPressed) { _, down in if down { Haptics.press() } }
    }
}

/// 退格：点一下删一个，按住 0.4 秒后连续删
struct BackspaceKey: View {
    @Environment(PhoneStore.self) private var store
    /// 手指是否按着。用 GestureState：手势被系统打断（切后台、弹出面板、别的手势抢走）时也会自动复位，
    /// 不会出现松手了还在一直删的情况
    @GestureState private var pressed = false
    /// 这一次按下已经删过第一个字了
    @State private var fired = false

    var body: some View {
        Image(systemName: "delete.left")
            .font(.system(size: 18, weight: .semibold)).foregroundStyle(P.text)
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(P.key))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(P.text.opacity(pressed ? 0.1 : 0)))
            .scaleEffect(pressed ? 0.94 : 1)
            .animation(pressed ? .easeOut(duration: 0.08) : .spring(response: 0.3, dampingFraction: 0.55), value: pressed)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .updating($pressed) { _, down, _ in down = true }
                    // 第一个字在手指碰到的那一刻就删。不能放进下面的任务里：
                    // 点得很快时，按下和抬起落在同一帧，界面看不到 pressed 变过，任务根本不会启动
                    .onChanged { _ in
                        guard !fired else { return }
                        fired = true
                        Haptics.press()
                        store.backspace()
                    }
                    .onEnded { _ in fired = false }
            )
            // 手势被打断时没有 onEnded，靠 pressed 复位
            .onChange(of: pressed) { _, down in if !down { fired = false } }
            // 按住不放的连删。跟着 pressed 走：一松手（或手势被打断、按键从屏幕上消失）这个任务就被取消
            .task(id: pressed) {
                guard pressed else { return }
                try? await Task.sleep(for: .milliseconds(400))
                while !Task.isCancelled {
                    Haptics.tap()
                    store.backspace()
                    try? await Task.sleep(for: .milliseconds(80))
                }
            }
            .accessibilityLabel("退格，按住连续删除")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { store.backspace() }
    }
}

/// iPhone Duo 右侧栏：系统状态图标下方的一条竖胶囊，里面一列图标键，靠下对齐。
/// 样式跟系统和其他 App 在这块区域的做法一致：键本身没有底，整列共用一个胶囊底；按下 / 选中时图标后面出一块圆角高亮
struct SideKeys: View {
    /// 圆形键的直径（展开面板里的键、设置页的返回键用）
    static let size: CGFloat = 44
    static let gap: CGFloat = 8
    /// 胶囊里每个键占的格子
    static let cell: CGFloat = 48
    static let cellHeight: CGFloat = 50
    @Environment(PhoneStore.self) private var store
    let talk: TalkController
    /// 「所有按键」是否展开
    @Binding var expanded: Bool

    var body: some View {
        // 放哪些键、什么顺序在设置里调；默认从上到下：所有按键、⌘⏎、退格、逗号、换行，越常用越靠下，离拇指越近
        VStack(spacing: 0) {
            ForEach(store.sideKeys) { k in
                KeyCap(kind: k, active: k == .more && expanded) { expanded.toggle() }
            }
        }
        .padding(.vertical, 4)
        .sidePill()
        .disabled(!store.connected)
    }
}

extension View {
    /// 右侧栏里的胶囊底：卡片色、细描边、很淡的投影
    func sidePill() -> some View {
        background(Capsule().fill(P.card).shadow(color: .black.opacity(0.08), radius: 8, y: 2))
            .overlay(Capsule().stroke(P.line, lineWidth: 0.5))
    }
}

/// 没有底的图标键：按下或选中时，图标后面出一块圆角高亮
struct FlatKeyStyle: ButtonStyle {
    var active = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(FlatKeyHighlight(on: active || configuration.isPressed))
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(configuration.isPressed ? .easeOut(duration: 0.08)
                       : .spring(response: 0.3, dampingFraction: 0.55), value: configuration.isPressed)
            .onChange(of: configuration.isPressed) { _, down in if down { Haptics.press() } }
    }
}

struct FlatKeyHighlight: View {
    let on: Bool
    var body: some View {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
            .fill(P.text.opacity(on ? 0.1 : 0))
            .padding(.horizontal, 3).padding(.vertical, 1)
    }
}

/// 一个快捷键。图标是自己画的一套（Keys.xcassets 里的 key-*）：同一套线条粗细和圆角，高度一致
struct KeyCap: View {
    @Environment(PhoneStore.self) private var store
    let kind: SideKeyKind
    /// 高亮（「所有按键」展开时）
    var active = false
    /// 点「所有按键」时做什么
    var onMore: () -> Void = {}

    var body: some View {
        if kind == .backspace {
            SmallBackspace()
        } else {
            Button { kind == .more ? onMore() : store.run(kind) } label: {
                Image("key-\(kind.rawValue)").resizable().scaledToFit().frame(height: 22)
                    .foregroundStyle(active ? P.accent : P.text)
                    .frame(width: SideKeys.cell, height: SideKeys.cellHeight)
                    .contentShape(Rectangle())
            }
            .buttonStyle(FlatKeyStyle(active: active))
            .accessibilityLabel(kind.title)
        }
    }
}

/// 「所有按键」展开后的面板：没摆出来的键排成几行，可以连着点，点面板外面收起
struct AllKeysPanel: View {
    @Environment(PhoneStore.self) private var store
    let kinds: [SideKeyKind]

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(SideKeys.cell), spacing: 0), count: 4), spacing: 0) {
            ForEach(kinds) { KeyCap(kind: $0) }
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 26, style: .continuous).fill(P.card)
            .shadow(color: .black.opacity(0.18), radius: 18, y: 8))
        .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).stroke(P.line, lineWidth: 0.5))
        .fixedSize()
        .disabled(!store.connected)
    }
}

/// 小号退格：点一下删一个，按住连删
struct SmallBackspace: View {
    @Environment(PhoneStore.self) private var store
    /// 手指是否按着。用 GestureState：手势被系统打断（切后台、弹出面板、别的手势抢走）时也会自动复位，
    /// 不会出现松手了还在一直删的情况
    @GestureState private var pressed = false
    /// 这一次按下已经删过第一个字了
    @State private var fired = false

    var body: some View {
        Image("key-backspace").resizable().scaledToFit().frame(height: 22).foregroundStyle(P.text)
            .frame(width: SideKeys.cell, height: SideKeys.cellHeight)
            .background(FlatKeyHighlight(on: pressed))
            .scaleEffect(pressed ? 0.94 : 1)
            .animation(pressed ? .easeOut(duration: 0.08) : .spring(response: 0.3, dampingFraction: 0.55), value: pressed)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .updating($pressed) { _, down, _ in down = true }
                    // 第一个字在手指碰到的那一刻就删。不能放进下面的任务里：
                    // 点得很快时，按下和抬起落在同一帧，界面看不到 pressed 变过，任务根本不会启动
                    .onChanged { _ in
                        guard !fired else { return }
                        fired = true
                        Haptics.press()
                        store.backspace()
                    }
                    .onEnded { _ in fired = false }
            )
            // 手势被打断时没有 onEnded，靠 pressed 复位
            .onChange(of: pressed) { _, down in if !down { fired = false } }
            // 按住不放的连删。跟着 pressed 走：一松手（或手势被打断、按键从屏幕上消失）这个任务就被取消
            .task(id: pressed) {
                guard pressed else { return }
                try? await Task.sleep(for: .milliseconds(400))
                while !Task.isCancelled {
                    Haptics.tap()
                    store.backspace()
                    try? await Task.sleep(for: .milliseconds(80))
                }
            }
            .accessibilityLabel("退格，按住连续删除")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { store.backspace() }
    }
}
