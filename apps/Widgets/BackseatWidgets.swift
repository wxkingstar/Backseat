import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

@main
struct BackseatWidgets: WidgetBundle {
    var body: some Widget {
        TalkLiveActivity()
        TalkControl()
    }
}

private let accent = Color(red: 0.878, green: 0.541, blue: 0.427)
private let accentFill = Color(red: 0.784, green: 0.376, blue: 0.247)
private let ok = Color(red: 0.204, green: 0.659, blue: 0.369)

// MARK: - 控制中心 / 锁屏按钮 / 侧键可选的控制项

struct TalkControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "dev.backseat.control.talk") {
            ControlWidgetButton(action: ToggleTalkIntent()) {
                Label("Backseat 说话", systemImage: "mic.fill")
            }
        }
        .displayName("Backseat 说话")
        .description("按一下开始说话，再按一下结束，文字进入 Mac 的输入框。")
    }
}

// MARK: - 实时活动：锁屏卡片 + 灵动岛

struct TalkLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: TalkAttributes.self) { context in
            LockCard(state: context.state)
                .padding(16)
                .activityBackgroundTint(Color.black.opacity(0.75))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label(title(context.state), systemImage: icon(context.state))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(tint(context.state))
                }
                DynamicIslandExpandedRegion(.trailing) {
                    if context.state.phase == .recording {
                        Text(context.state.startedAt, style: .timer)
                            .font(.title3.weight(.semibold).monospacedDigit())
                            .foregroundStyle(accent)
                            .frame(maxWidth: 64, alignment: .trailing)
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 10) {
                        if !context.state.text.isEmpty {
                            Text(context.state.text).font(.subheadline).lineLimit(3)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        Actions(state: context.state)
                    }
                }
            } compactLeading: {
                Image(systemName: icon(context.state)).foregroundStyle(tint(context.state))
            } compactTrailing: {
                if context.state.phase == .recording {
                    Text(context.state.startedAt, style: .timer)
                        .monospacedDigit().foregroundStyle(accent).frame(maxWidth: 44)
                } else {
                    Text(short(context.state)).font(.caption.weight(.semibold)).foregroundStyle(tint(context.state))
                }
            } minimal: {
                Image(systemName: icon(context.state)).foregroundStyle(tint(context.state))
            }
        }
    }
}

private func title(_ s: TalkAttributes.ContentState) -> String {
    switch s.phase {
    case .recording: return "Backseat 正在听"
    case .processing: return "正在输入到 Mac"
    case .ready: return "已写入输入框，还没发送"
    case .sent: return "已发送"
    case .failed: return "没有成功"
    }
}

private func short(_ s: TalkAttributes.ContentState) -> String {
    switch s.phase {
    case .recording: return ""
    case .processing: return "输入中"
    case .ready: return "待发送"
    case .sent: return "已发送"
    case .failed: return "失败"
    }
}

private func icon(_ s: TalkAttributes.ContentState) -> String {
    switch s.phase {
    case .recording: return "mic.fill"
    case .processing: return "ellipsis"
    case .ready: return "text.bubble.fill"
    case .sent: return "checkmark.circle.fill"
    case .failed: return "exclamationmark.triangle.fill"
    }
}

private func tint(_ s: TalkAttributes.ContentState) -> Color {
    switch s.phase {
    case .recording, .processing: return accent
    case .ready, .sent: return Color(red: 0.298, green: 0.824, blue: 0.478)
    case .failed: return Color(red: 1, green: 0.541, blue: 0.502)
    }
}

private struct LockCard: View {
    let state: TalkAttributes.ContentState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: icon(state))
                    .font(.system(size: 14, weight: .bold)).foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(state.phase == .sent ? ok : accentFill))
                Text(title(state)).font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                Spacer(minLength: 0)
                if state.phase == .recording {
                    Text(state.startedAt, style: .timer)
                        .font(.title3.weight(.semibold).monospacedDigit()).foregroundStyle(accent)
                        .frame(maxWidth: 70, alignment: .trailing)
                }
            }
            if !state.text.isEmpty {
                Text(state.text).font(.callout).foregroundStyle(.white).lineLimit(4)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Actions(state: state)
        }
    }
}

/// 录音中：取消 / 说完了；说完后：清空 / 发送
private struct Actions: View {
    let state: TalkAttributes.ContentState

    var body: some View {
        switch state.phase {
        case .recording:
            HStack(spacing: 8) {
                Button(intent: CancelTalkIntent()) { label("取消") }.tint(.white.opacity(0.18))
                Button(intent: ToggleTalkIntent()) { label("说完了").fontWeight(.bold) }.tint(accentFill)
            }
            .buttonStyle(.borderedProminent)
        case .ready:
            HStack(spacing: 8) {
                Button(intent: ClearTalkIntent()) { label("清空") }.tint(.white.opacity(0.18))
                Button(intent: SendTalkIntent()) { label("发送").fontWeight(.bold) }.tint(ok)
            }
            .buttonStyle(.borderedProminent)
        default:
            EmptyView()
        }
    }

    private func label(_ t: String) -> some View {
        Text(t).font(.subheadline.weight(.semibold)).frame(maxWidth: .infinity, minHeight: 28)
    }
}
