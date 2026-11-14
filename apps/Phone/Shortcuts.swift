import AppIntents

/// 让「开始 / 结束说话」出现在快捷指令 App、侧键设置和 Siri 里
struct BackseatShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: ToggleTalkIntent(),
                    phrases: ["\(.applicationName)说话", "用\(.applicationName)说话"],
                    shortTitle: "开始 / 结束说话", systemImageName: "mic.fill")
    }
}
