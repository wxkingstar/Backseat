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
        if store.lastKind == "idle" { return Color(red: 0.96, green: 0.76, blue: 0.28) }
        return .gray
    }
}

// MARK: - 更多按键

struct MoreKeysSheet: View {
    @Environment(PhoneStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("更多按键").font(.title3.bold())
                Spacer()
                Button("完成") { dismiss() }.font(.body.weight(.semibold)).tint(P.accent).frame(minHeight: 44)
            }
            Text("选菜单 / 中断").font(.footnote).foregroundStyle(P.text2)
            HStack(spacing: 10) {
                Button { store.press("esc") } label: {
                    VStack(spacing: 1) { Text("Esc").font(.body.weight(.semibold)); Text("中断").font(.caption2) }
                        .foregroundStyle(P.dangerText).frame(maxWidth: .infinity, minHeight: 56)
                }
                .buttonStyle(PressStyle(fill: P.dangerBg, radius: 14))
                ForEach(["1", "2", "3"], id: \.self) { k in key(k) { store.press(k) } }
            }
            Text("方向与编辑").font(.footnote).foregroundStyle(P.text2)
            HStack(spacing: 10) {
                icon("arrow.up", "上") { store.press("up") }
                icon("arrow.down", "下") { store.press("down") }
                key("Tab") { store.press("tab") }
                key("空格") { store.press("space") }
            }
            Button { store.press("enter") } label: {
                Label("回车", systemImage: "return").font(.body.weight(.bold)).foregroundStyle(.white)
                    .frame(maxWidth: .infinity, minHeight: 56)
            }
            .buttonStyle(PressStyle(fill: P.accentFill, radius: 14))
        }
        .padding(.horizontal, 16).padding(.top, 20)
        .frame(maxHeight: .infinity, alignment: .top)
        .presentationBackground(P.card)
    }

    private func key(_ t: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(t).font(.body.weight(.semibold)).foregroundStyle(.white).frame(maxWidth: .infinity, minHeight: 56)
        }
        .buttonStyle(PressStyle(fill: Color(white: 0.17), radius: 14))
    }

    private func icon(_ name: String, _ label: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name).font(.body.weight(.semibold)).foregroundStyle(.white).frame(maxWidth: .infinity, minHeight: 56)
        }
        .buttonStyle(PressStyle(fill: Color(white: 0.17), radius: 14))
        .accessibilityLabel(label)
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
                        .background(Capsule().fill(Color(white: 0.17)))
                }
            }
            ScrollView {
                Text(approval.detail)
                    .font(.system(.subheadline, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 120)
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 14).fill(Color(white: 0.055)))

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

struct SettingsSheet: View {
    @Environment(PhoneStore.self) private var store
    @AppStorage("mouseSpeed") private var mouseSpeed = 1.0
    @AppStorage("threeFinger") private var threeFinger = SwipeAction.spaces.rawValue
    @AppStorage("fourFinger") private var fourFinger = SwipeAction.off.rawValue
    @State private var apps: [(name: String, bundle: String)] = []
    @State private var target = ""
    @State private var customHost = UserDefaults.standard.string(forKey: "customHost") ?? ""

    var body: some View {
        @Bindable var store = store
        NavigationStack {
            Form {
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
                        Label("添加短语", systemImage: "plus")
                    }
                    Button("恢复默认", role: .destructive) { store.phrases = Phrase.defaults }
                } header: { Text("快捷短语") } footer: {
                    Text("点文字直接改；关掉开关就从主屏隐藏；左滑删除；点右上角「编辑」可以拖动排序。全部隐藏后主屏不再显示这一块。")
                }

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
            .toolbar { EditButton() }
            .task {
                if let r = try? await BridgeClient.shared.apps() {
                    apps = r.apps
                    target = r.target
                }
            }
        }
    }
}
