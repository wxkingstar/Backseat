import SwiftUI

// MARK: - Claude 状态卡

struct StatusCard: View {
    @Environment(PhoneStore.self) private var store

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Circle().fill(dotColor).frame(width: 8, height: 8)
                    .overlay(Circle().stroke(dotColor.opacity(0.25), lineWidth: 4))
                Text(title).font(.headline)
                if !project.isEmpty {
                    Text(project).font(.subheadline).foregroundStyle(P.text2).lineLimit(1)
                }
                Spacer(minLength: 0)
                if let since = store.workingSince, store.connected {
                    Text(since, style: .timer)
                        .font(.headline.monospacedDigit()).foregroundStyle(P.accent)
                }
            }
            // 始终占一行：数据到了卡片高度不变，下面的触控板不会跳
            Text(subtitle.isEmpty ? " " : subtitle).font(.footnote).foregroundStyle(P.text2).lineLimit(1)
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(P.card))
    }

    private var title: String {
        if !store.connected { return "正在连接 Mac" }
        if store.workingProject != nil { return "工作中" }
        if store.lastKind == "done" { return "完成" }
        if store.lastKind == "idle" { return "等你回复" }
        return "空闲"
    }

    private var project: String { store.workingProject ?? (store.lastKind.isEmpty ? "" : store.lastProject) }

    private var subtitle: String {
        if !store.connected { return "确认 Mac 上 backseat 在运行，且手机和 Mac 在同一网络" }
        return store.lastBody.replacingOccurrences(of: "\n", with: " ")
    }

    private var dotColor: Color {
        if !store.connected { return P.dangerText }
        if store.workingProject != nil { return P.accent }
        if store.lastKind == "done" { return P.okText }
        if store.lastKind == "idle" { return P.warn }
        return .gray
    }
}

// MARK: - 权限审批

struct ApprovalSheet: View {
    @Environment(PhoneStore.self) private var store
    let approval: PendingApproval

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: icon).font(.system(size: 20, weight: .semibold)).foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(RoundedRectangle(cornerRadius: 12).fill(risky ? Color(red: 0.9, green: 0.33, blue: 0.29) : P.accentFill))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Claude 想\(approval.title)").font(.title3.bold())
                    Text(approval.project).font(.subheadline).foregroundStyle(P.text2)
                }
                Spacer(minLength: 0)
                if store.pending.count > 1 {
                    Text("还有 \(store.pending.count - 1) 个").font(.footnote.weight(.semibold))
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(Capsule().fill(P.raised))
                }
            }
            ScrollView {
                Text(approval.detail)
                    .font(.system(.subheadline, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 120)
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 14).fill(P.sunken))

            if risky {
                Label("高风险操作，请确认后再允许", systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote.weight(.semibold)).foregroundStyle(P.dangerText)
            }

            HStack(spacing: 10) {
                Button { store.decide(approval, "deny") } label: {
                    Text("拒绝").font(.headline).foregroundStyle(P.dangerText).frame(width: 104, height: 56)
                }
                .buttonStyle(PressStyle(fill: P.dangerBg, radius: 16))
                Button { store.decide(approval, "allow") } label: {
                    Label("允许", systemImage: "checkmark").font(.headline).foregroundStyle(.white)
                        .frame(maxWidth: .infinity, minHeight: 56)
                }
                .buttonStyle(PressStyle(fill: risky ? Color(red: 0.9, green: 0.33, blue: 0.29) : P.ok, radius: 16))
            }
            Button("在电脑上处理") { store.decide(approval, "terminal") }
                .font(.subheadline).foregroundStyle(P.text2).frame(maxWidth: .infinity, minHeight: 44)
        }
        .padding(.horizontal, 20).padding(.top, 24)
        .frame(maxHeight: .infinity, alignment: .top)
        .presentationBackground(P.card)
        .onAppear { Haptics.warning() }
    }

    private var icon: String {
        switch approval.tool {
        case "Bash": return "terminal.fill"
        case "Edit", "MultiEdit", "Write", "NotebookEdit": return "pencil"
        case "WebFetch", "WebSearch": return "globe"
        default: return "wrench.and.screwdriver.fill"
        }
    }

    private var risky: Bool {
        let d = approval.detail.lowercased()
        return ["rm -rf", "rm -fr", "git push", "--force", "reset --hard", "drop table", "sudo ", "git clean"]
            .contains { d.contains($0) }
    }
}

// MARK: - 设置

struct SettingsPage: View {
    @Environment(PhoneStore.self) private var store
    @AppStorage("appearance") private var appearance = "system"
    @AppStorage("mouseSpeed") private var mouseSpeed = 1.0
    @AppStorage("threeFinger") private var threeFinger = SwipeAction.spaces.rawValue
    @AppStorage("fourFinger") private var fourFinger = SwipeAction.off.rawValue
    @State private var apps: [(name: String, bundle: String)] = []
    @State private var target = ""
    @State private var customHost = UserDefaults.standard.string(forKey: "customHost") ?? ""

    /// 外观的一个选项：图标和文字排成一行，选中的用强调色描边
    private func appearanceOption(_ value: String, _ title: String, _ icon: String) -> some View {
        let selected = appearance == value
        return Button { appearance = value } label: {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 14, weight: .semibold))
                Text(title).font(.subheadline.weight(selected ? .semibold : .regular)).lineLimit(1).minimumScaleFactor(0.85)
            }
            .foregroundStyle(selected ? P.accent : P.text2)
            .frame(maxWidth: .infinity, minHeight: 36)
            .background(Capsule().fill(selected ? P.accent.opacity(0.12) : .clear))
            .overlay(Capsule().stroke(selected ? P.accent : .clear, lineWidth: 1.5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    var body: some View {
        GeometryReader { geo in
            let hasSide = geo.safeAreaInsets.trailing > 60
            Form {
                Section("外观") {
                    HStack(spacing: 4) {
                        appearanceOption("system", "跟随系统", "circle.lefthalf.filled")
                        appearanceOption("light", "浅色", "sun.max")
                        appearanceOption("dark", "深色", "moon")
                    }
                    .listRowInsets(EdgeInsets(top: 6, leading: 6, bottom: 6, trailing: 6))
                }

                Section {
                    NavigationLink { PhrasesSettings() } label: {
                        LabeledContent("快捷短语", value: "\(store.visiblePhrases.count) 条显示中")
                    }
                    // iPhone Duo 外屏右侧有一条系统状态栏，那一列快捷键只在这种屏幕上有
                    if hasSide {
                        NavigationLink { SideKeysSettings() } label: {
                            LabeledContent("右侧快捷键", value: "\(store.sideKeys.count) 个")
                        }
                    }
                } header: { Text("快捷操作") }

                Section {
                    Picker("输入到", selection: $target) {
                        Text("跟随 Mac 前台应用").tag("")
                        ForEach(apps, id: \.bundle) { Text($0.name).tag($0.bundle) }
                    }
                    .onChange(of: target) { _, t in
                        Task { try? await BridgeClient.shared.setTarget(bundle: t) }
                    }
                } header: { Text("目标应用") } footer: {
                    Text("默认跟随前台：Mac 上哪个应用在最前面，文字就输到哪个，Claude、Codex、Cursor、终端都可以。选定某个应用后，即使它不在最前面，也会先切过去再输入。")
                }

                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("鼠标灵敏度")
                            Spacer()
                            Text(String(format: "%.1f×", mouseSpeed)).foregroundStyle(.secondary).monospacedDigit()
                        }
                        Slider(value: $mouseSpeed, in: 0.4...1.6, step: 0.1) {
                            Text("鼠标灵敏度")
                        } minimumValueLabel: { Image(systemName: "tortoise") } maximumValueLabel: { Image(systemName: "hare") }
                    }
                    if mouseSpeed != 1.0 { Button("恢复默认") { mouseSpeed = 1.0 } }
                    Picker("三指轻扫", selection: $threeFinger) {
                        ForEach(SwipeAction.allCases) { Text($0.title).tag($0.rawValue) }
                    }
                    Picker("四指轻扫", selection: $fourFinger) {
                        ForEach(SwipeAction.allCases) { Text($0.title).tag($0.rawValue) }
                    }
                } header: { Text("触控板") } footer: {
                    Text("默认和 MacBook 一样：三指左右切换桌面和全屏应用，上扫打开调度中心，下扫显示当前应用的窗口；四指不使用。也可以把任意一个改成「前进 / 后退」（左右轻扫）。")
                }

                Section("连接") {
                    LabeledContent("状态", value: store.connected ? "已连接" : "未连接")
                    LabeledContent("当前地址", value: BridgeClient.shared.activeHost ?? "—")
                    LabeledContent("输入到", value: store.frontApp.isEmpty ? "—" : store.frontApp)
                }
                Section {
                    TextField("IP 或主机名，留空用默认", text: $customHost)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .onSubmit {
                            UserDefaults.standard.set(customHost.trimmingCharacters(in: .whitespaces), forKey: "customHost")
                            store.refreshNow()
                        }
                    Button("重新连接") { store.refreshNow() }
                    Button("重新配对", role: .destructive) { Pairing.shared.unpair() }
                } header: { Text("Mac 地址") } footer: {
                    Text("在外面用时，手机和 Mac 都装上 Tailscale，这里填 Mac 的 Tailscale 地址。")
                }
            }
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .modifier(DuoBackKey())
            .task {
                if let r = try? await BridgeClient.shared.apps() {
                    apps = r.apps
                    target = r.target
                }
            }
        }
    }
}

/// iPhone Duo：返回键放在右侧栏的系统状态图标下面，导航栏上不再放。普通 iPhone 不受影响
struct DuoBackKey: ViewModifier {
    @Environment(\.dismiss) private var dismiss

    /// 右侧系统状态图标平时的下沿（距屏幕顶）。系统没有提供这块区域的尺寸（状态栏接口报的是 2pt 高的一条），只能按实测值写
    static let statusBottom: CGFloat = 166

    func body(content: Content) -> some View {
        GeometryReader { geo in
            let hasSide = geo.safeAreaInsets.trailing > 60
            content
                .navigationBarBackButtonHidden(hasSide)
                .overlay {
                    if hasSide {
                        Button { dismiss() } label: {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 17, weight: .semibold)).foregroundStyle(P.text)
                                .frame(width: SideKeys.cell, height: SideKeys.cellHeight)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(FlatKeyStyle())
                        .padding(.vertical, 2)
                        // 和主屏右侧那一列同一种胶囊底
                        .sidePill()
                        .accessibilityLabel("返回")
                        // 和系统状态图标同一条中线（距屏幕右缘约 48pt），紧贴在它们下面
                        .padding(.trailing, 48 - SideKeys.cell / 2)
                        .padding(.top, Self.statusBottom + 10)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                        .ignoresSafeArea()
                    }
                }
        }
    }
}

/// 设置 → 右侧快捷键：增删、拖动排序
struct SideKeysSettings: View {
    @Environment(PhoneStore.self) private var store

    var body: some View {
        let unused = SideKeyKind.allCases.filter { !store.sideKeys.contains($0) }
        List {
            Section {
                ForEach(store.sideKeys) { Text($0.title) }
                    .onDelete { store.sideKeys.remove(atOffsets: $0) }
                    .onMove { store.sideKeys.move(fromOffsets: $0, toOffset: $1) }
            } header: { Text("已添加") } footer: {
                Text("这里从上到下就是屏幕上从上到下的顺序，最下面的离拇指最近。最多 \(SideKeyKind.limit) 个。")
            }
            if !unused.isEmpty {
                Section("可以添加") {
                    ForEach(unused) { k in
                        Button { store.sideKeys.append(k) } label: {
                            Label(k.title, systemImage: "plus.circle.fill")
                        }
                        .disabled(store.sideKeys.count >= SideKeyKind.limit)
                    }
                }
            }
            Section {
                Button("恢复默认", role: .destructive) { store.sideKeys = SideKeyKind.defaults }
            }
        }
        // 一直处于编辑状态：直接能拖动排序、点红色减号删除
        .environment(\.editMode, .constant(.active))
        .navigationTitle("右侧快捷键")
        .navigationBarTitleDisplayMode(.inline)
        .modifier(DuoBackKey())
    }
}

/// 设置 → 快捷短语：改文字、隐藏、增删、拖动排序
struct PhrasesSettings: View {
    @Environment(PhoneStore.self) private var store

    var body: some View {
        @Bindable var store = store
        List {
            Section {
                ForEach($store.phrases) { $p in
                    HStack(spacing: 12) {
                        TextField("短语内容", text: $p.text)
                            .foregroundStyle(p.enabled ? .primary : .secondary)
                        Toggle("显示", isOn: $p.enabled).labelsHidden()
                    }
                }
                .onDelete { store.phrases.remove(atOffsets: $0) }
                .onMove { store.phrases.move(fromOffsets: $0, toOffset: $1) }
                Button { store.phrases.append(Phrase(text: "")) } label: {
                    Label("添加短语", systemImage: "plus.circle.fill")
                }
            } footer: {
                Text("默认都不显示，打开开关的才会出现在主屏。点文字直接改；拖右边的把手调整顺序。")
            }
            Section {
                Button("恢复默认", role: .destructive) { store.phrases = Phrase.defaults }
            }
        }
        // 一直处于编辑状态：直接能拖动排序、点红色减号删除
        .environment(\.editMode, .constant(.active))
        .navigationTitle("快捷短语")
        .navigationBarTitleDisplayMode(.inline)
        .modifier(DuoBackKey())
    }
}

/// 隐藏系统返回键（iPhone Duo 上返回键放在右侧栏）后，系统会连带关掉「从屏幕左边缘右滑返回」。
/// 这里重新打开：只要不是在最底下那一页，就允许滑动返回。
extension UINavigationController: @retroactive UIGestureRecognizerDelegate {
    override open func viewDidLoad() {
        super.viewDidLoad()
        interactivePopGestureRecognizer?.delegate = self
    }

    public func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        viewControllers.count > 1
    }
}
