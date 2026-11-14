import SwiftUI

/// 常用指令一键发送，加上打字输入作为嘈杂环境下的备选。
/// 不用 List：List 的一行里放多个按钮，点一个可能整行都被触发。
struct QuickView: View {
    @Environment(Store.self) private var store

    static let phrases: [(String, String)] = [
        ("继续", "play.fill"),
        ("提交代码并上线", "arrow.up.circle"),
        ("按你的方案做", "checkmark"),
        ("跑一下测试，失败就修", "checkmark.seal"),
    ]

    var body: some View {
        ScrollView {
            VStack(spacing: 6) {
                // 最常用的三个：逗号、⌘回车、换行（Shift+回车，不发送）
                HStack(spacing: 6) {
                    Button { store.insert("，") } label: { Text("，").font(.title3.weight(.bold)) }
                        .buttonStyle(KeyStyle(height: 40))
                        .accessibilityLabel("逗号")
                    Button { store.press("cmd+enter") } label: { Text("⌘⏎").font(.body.weight(.bold)) }
                        .buttonStyle(KeyStyle(height: 40))
                        .accessibilityLabel("Command 加回车")
                    Button { store.press("shift+enter") } label: { Text("换行").font(.footnote.weight(.semibold)) }
                        .buttonStyle(KeyStyle(height: 40))
                }
                .padding(.bottom, 4)

                ForEach(Self.phrases, id: \.0) { text, icon in
                    Button { store.send(text) } label: { row(text, icon) }
                        .buttonStyle(RowStyle())
                }
                TextFieldLink(prompt: Text("让 Claude 做什么？")) {
                    row("打字输入", "keyboard", tint: Theme.accent)
                } onSubmit: { store.send($0) }
                .buttonStyle(RowStyle())
            }
            .padding(.horizontal, 4)
        }
        .disabled(!store.connected)
        .navigationTitle("快捷")
    }

    private func row(_ text: String, _ icon: String, tint: Color = .white) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(tint == .white ? Theme.accent : tint)
                .frame(width: 18)
            // 一行放下，太长就略微缩小字号，不换行
            Text(text).lineLimit(1).minimumScaleFactor(0.75).foregroundStyle(tint)
            Spacer(minLength: 0)
        }
    }
}

/// 快捷短语行：整行可点，统一内边距和圆角
struct RowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(.body).weight(.medium))
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(configuration.isPressed ? Theme.surfacePressed : Theme.surface)
            )
            .contentShape(RoundedRectangle(cornerRadius: 14))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.spring(duration: 0.18), value: configuration.isPressed)
    }
}
