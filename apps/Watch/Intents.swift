import AppIntents

/// 给 Action Button / 快捷指令用：按一下就开始听写，说完直接发到 Mac。
struct SendPromptIntent: AppIntent {
    static var title: LocalizedStringResource = "发送给 Claude"
    static var description = IntentDescription("听写一句话，输入到 Mac 当前的 Claude 会话。")

    @Parameter(title: "内容", requestValueDialog: "让 Claude 做什么？")
    var text: String

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let submit = UserDefaults.standard.object(forKey: "autoSubmit") as? Bool ?? true
        let target = try await BridgeClient.shared.sendPrompt(text, submit: submit)
        return .result(dialog: "已发送到 \(target)")
    }
}

/// 给 Action Button 用：按一下开始说话，再按一下结束（系统不提供按住 / 松开事件，只能做成切换）。
struct ToggleTalkIntent: AppIntent {
    static var title: LocalizedStringResource = "开始 / 结束说话"
    static var description = IntentDescription("第一次按开始录音，第二次按结束，文字进入 Mac 的输入框。")
    static var openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        Store.shared.talkToggle += 1
        return .result()
    }
}

/// 让 Backseat 出现在「设置 → 操作按钮 → 体能训练」的 App 列表里。
/// watchOS 的侧键只对第三方开放「开始体能训练」这一类意图，所以借这个通道：按侧键 = 打开 Backseat 并开始说话。
struct StartTalkWorkoutIntent: StartWorkoutIntent {
    static var title: LocalizedStringResource = "开始说话"

    static var suggestedWorkouts: [StartTalkWorkoutIntent] { [StartTalkWorkoutIntent()] }

    @Parameter(title: "方式")
    var workoutStyle: TalkStyle

    init() { workoutStyle = .talk }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "说话给 Claude", image: .init(systemName: "mic.fill"))
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        _ = try? await BridgeClient.shared.call("POST", "/api/log", body: ["text": "手表侧键：系统调用了开始说话"], timeout: 2)
        Store.shared.talkPending = true
        Store.shared.talkToggle += 1
        return .result()
    }
}

enum TalkStyle: String, AppEnum {
    case talk
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "说话方式"
    static var caseDisplayRepresentations: [TalkStyle: DisplayRepresentation] = [.talk: "说话给 Claude"]
}

struct InterruptIntent: AppIntent {
    static var title: LocalizedStringResource = "中断 Claude"

    func perform() async throws -> some IntentResult & ProvidesDialog {
        try await BridgeClient.shared.press("esc")
        return .result(dialog: "已发送 Esc")
    }
}

struct BackseatWatchShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: ToggleTalkIntent(),
                    phrases: ["\(.applicationName)说话"],
                    shortTitle: "开始 / 结束说话", systemImageName: "mic.circle.fill")
        AppShortcut(intent: SendPromptIntent(),
                    phrases: ["用\(.applicationName)发送", "\(.applicationName)听写"],
                    shortTitle: "发送给 Claude", systemImageName: "mic.fill")
        AppShortcut(intent: InterruptIntent(),
                    phrases: ["\(.applicationName)中断"],
                    shortTitle: "中断 Claude", systemImageName: "stop.fill")
    }
}
