import ActivityKit
import AppIntents
import Observation
import SwiftUI
import UIKit

/// 按住说话的流程：手机录音实时推给 Mac → Mac 灌进虚拟麦克风给语音输入法识别 → 松手后把输入框文字读回手机预览。
@MainActor @Observable
final class TalkController {
    /// 全局只有一个：主屏的说话条和「不开 App 快速说」的快捷操作共用
    static let shared = TalkController()

    enum Phase: Equatable { case idle, recording, cancelArmed, syncing, delivered, failed(String) }

    var phase: Phase = .idle
    let recorder = Recorder()
    private var mic: MicSession?
    var engine = ""

    var isLive: Bool { phase == .recording || phase == .cancelArmed }

    /// 手指上移超过这个距离 = 准备取消（和遮罩里的取消圆圈位置对应）
    static let cancelDistance: CGFloat = 150

    /// quick = 由侧键 / 控制中心 / 快捷指令触发（App 可能在后台）：用实时活动显示状态
    func begin(_ store: PhoneStore, quick: Bool = false) {
        // 不拿「未连接」拦住：连不上 Mac 时照样录，结束后存进灵感收件箱
        switch recorder.permission {
        case .undetermined:
            Task {
                let ok = await recorder.requestPermission()
                flash(.failed(ok ? "好了，再按住说话" : "麦克风被拒绝，请到设置里打开"))
            }
            return
        case .denied:
            flash(.failed("麦克风被拒绝，请到设置里打开"))
            return
        default: break
        }
        // Mac 正在采集手机屏幕（Device Hub、QuickTime 录屏等）时，iOS 会把麦克风静音成全零，录了也没字
        if UIScreen.main.isCaptured {
            flash(.failed("Mac 正在镜像手机屏幕，麦克风被系统静音"))
            store.show("关掉 Mac 上的 Device Hub / 录屏后再说话")
            Haptics.error()
            return
        }
        let s = MicSession()
        do {
            try recorder.start { seq, pcm in Task { await s.push(seq, pcm) } }
        } catch {
            flash(.failed("录音启动失败"))
            return
        }
        mic = s
        phase = .recording
        Haptics.medium()
        self.quick = quick
        if quick {
            startActivity()
            // 没有界面盯着时长，自己到点结束
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(Recorder.maxDuration))
                if let self, self.mic === s { self.finish(store) }
            }
        }
        Task {
            do {
                engine = try await BridgeClient.shared.micStart(id: s.id)
                await s.open()
            } catch {
                await s.fail()
            }
        }
    }

    func drag(_ dy: CGFloat) {
        guard isLive else { return }
        let next: Phase = dy < -Self.cancelDistance ? .cancelArmed : .recording
        if next != phase {
            phase = next
            Haptics.tap()
        }
    }

    func finish(_ store: PhoneStore) {
        guard let s = mic, isLive else { return }
        mic = nil
        let cancel = phase == .cancelArmed || recorder.elapsed < 0.6
        let tooShort = phase != .cancelArmed && recorder.elapsed < 0.6
        let diag = recorder.diagnostics
        let lastSeq = recorder.stop()
        phase = cancel ? .idle : .syncing
        if cancel { Haptics.warning() }
        if tooShort { flash(.failed("按住不放，说完再松手")) }
        let quick = self.quick
        if quick { cancel ? endActivity(after: 0) : updateActivity(.processing) }
        Task {
            guard await s.drain() else {
                if !cancel { await self.saveToInbox(s, quick: quick) }
                return
            }
            do {
                _ = try await BridgeClient.shared.micEnd(id: s.id, lastSeq: lastSeq, submit: false,
                                                         cancel: cancel, diag: diag)
                guard !cancel else { return }
                // 文字直接看电脑；手机上只给一个「已输入」的震动
                Haptics.success()
                if phase == .syncing { phase = .idle }
                if quick { await showReady() }
            } catch {
                if !cancel { await self.saveToInbox(s, quick: quick) }
            }
        }
    }

    func send(_ store: PhoneStore) {
        Task {
            if await store.sendInput() {
                phase = .delivered
                try? await Task.sleep(for: .seconds(1.6))
                if phase == .delivered { phase = .idle }
            }
        }
    }

    /// 这句话没能送到 Mac：存进灵感收件箱，用手机识别成文字
    private func saveToInbox(_ s: MicSession, quick: Bool) async {
        Inbox.shared.add(pcm: await s.recorded)
        Haptics.warning()
        flash(.failed("连不上 Mac，已存到收件箱"))
        if quick {
            updateActivity(.failed, text: "连不上 Mac，这句话已存到灵感收件箱")
            endActivity(after: 6)
        }
    }

    // MARK: - 不开 App 快速说：快捷操作入口 + 实时活动

    private var quick = false
    private var activity: Activity<TalkAttributes>?
    private var startedAt = Date()

    /// 侧键 / 控制中心 / 快捷指令：没在说就开始，正在说就结束
    func handle(_ action: TalkAction) async {
        let store = PhoneStore.shared
        switch action {
        case .toggle:
            if isLive { finish(store) } else if phase != .syncing { begin(store, quick: true) }
        case .cancel:
            if isLive { phase = .cancelArmed; finish(store) } else { endActivity(after: 0) }
        case .send:
            if await store.sendInput() {
                updateActivity(.sent)
                endActivity(after: 2)
            } else {
                updateActivity(.failed, text: "发送失败，连不上 Mac")
                endActivity(after: 8)
            }
        case .clear:
            store.clearInput()
            endActivity(after: 0)
        }
    }

    private func startActivity() {
        startedAt = Date()
        // 上一条还挂着就先收掉
        if let old = activity { Task { await old.end(nil, dismissalPolicy: .immediate) } }
        let state = TalkAttributes.ContentState(phase: .recording, text: "", startedAt: startedAt)
        activity = try? Activity.request(attributes: TalkAttributes(), content: .init(state: state, staleDate: nil))
    }

    private func updateActivity(_ p: TalkAttributes.ContentState.Phase, text: String = "") {
        guard let activity else { return }
        let state = TalkAttributes.ContentState(phase: p, text: text, startedAt: startedAt)
        Task { await activity.update(.init(state: state, staleDate: nil)) }
    }

    private func endActivity(after seconds: Double) {
        guard let a = activity else { return }
        activity = nil
        Task {
            if seconds > 0 { try? await Task.sleep(for: .seconds(seconds)) }
            await a.end(nil, dismissalPolicy: .immediate)
        }
    }

    /// 说完后：把 Mac 输入框里的字读回来放到锁屏卡片上（人不在电脑前时靠它确认），等用户点发送或清空
    private func showReady() async {
        var text = ""
        for delay in [500, 700] {
            try? await Task.sleep(for: .milliseconds(delay))
            if let t = try? await BridgeClient.shared.inputText(), !t.isEmpty { text = t }
        }
        updateActivity(.ready, text: String(text.suffix(200)))
        // 一分钟没处理就收起卡片；文字还留在 Mac 的输入框里
        let current = activity
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(60))
            if let self, self.activity === current { self.endActivity(after: 0) }
        }
    }

    private func flash(_ p: Phase) {
        phase = p
        Task {
            try? await Task.sleep(for: .seconds(2))
            if phase == p { phase = .idle }
        }
    }
}

// MARK: - 底部：✕ 清空 · 按住 说话 · ↑ 发送

struct TalkBar: View {
    @Environment(PhoneStore.self) private var store
    let talk: TalkController

    var body: some View {
        HStack(spacing: 10) {
            Button { store.clearInput() } label: {
                Image(systemName: "xmark").font(.system(size: 20, weight: .bold)).foregroundStyle(P.dangerText)
                    .frame(width: 56, height: 56)
            }
            .buttonStyle(PressStyle(fill: P.dangerBg, radius: 28))
            .accessibilityLabel("清空输入框")
            .disabled(!store.connected)

            center
                .frame(maxWidth: .infinity)
                .frame(height: 56)

            Button { talk.send(store) } label: {
                Image(systemName: "arrow.up").font(.system(size: 22, weight: .bold)).foregroundStyle(.white)
                    .frame(width: 56, height: 56)
            }
            .buttonStyle(PressStyle(fill: P.ok, radius: 28))
            .accessibilityLabel("发送")
            .disabled(!store.connected)
        }
        .opacity(talk.phase == .delivered ? 0.999 : 1)
    }

    @ViewBuilder private var center: some View {
        switch talk.phase {
        case .delivered:
            HStack(spacing: 10) {
                DrawnCheck().frame(width: 26, height: 20)
                Text("已发送").font(.headline)
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Capsule().fill(P.ok).shadow(color: P.ok.opacity(0.45), radius: 14, y: 6))
            .transition(.scale(scale: 0.9).combined(with: .opacity))
            .accessibilityLabel("已发送")
        case .syncing:
            HStack(spacing: 8) {
                ProgressView().tint(P.accent)
                Text("正在输入…").font(.subheadline).foregroundStyle(P.text2)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Capsule().fill(Color(white: 0.165)))
        case .failed(let msg):
            Text(msg).font(.subheadline.weight(.semibold)).foregroundStyle(P.dangerText).lineLimit(1)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Capsule().fill(Color(white: 0.165)))
        default:
            HStack(spacing: 8) {
                Image(systemName: "mic").font(.system(size: 18, weight: .semibold)).foregroundStyle(P.accent)
                Text("按住 说话").font(.headline).tracking(2)
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Capsule().fill(Color(white: 0.165)).stroke(Color(white: 0.24)))
            .contentShape(Capsule())
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .global)
                    .onChanged { v in
                        if !talk.isLive { talk.begin(store) } else { talk.drag(v.translation.height) }
                    }
                    .onEnded { _ in talk.finish(store) }
            )
            .accessibilityLabel("按住说话")
            .accessibilityHint("按住说话，松手后文字进入 Mac 输入框；往上滑可取消")
        }
    }
}

/// 发送成功时手写出来的对勾：先慢写短笔，再快速划出长笔，写完轻弹一下
struct DrawnCheck: View {
    @State private var progress: CGFloat = 0
    @State private var pop = false

    var body: some View {
        CheckPath()
            .trim(from: 0, to: progress)
            .stroke(.white, style: StrokeStyle(lineWidth: 3.5, lineCap: .round, lineJoin: .round))
            .scaleEffect(pop ? 1.15 : 1)
            .onAppear {
                Task {
                    try? await Task.sleep(for: .milliseconds(80))
                    withAnimation(.easeIn(duration: 0.16)) { progress = 0.3 }
                    try? await Task.sleep(for: .milliseconds(160))
                    withAnimation(.easeOut(duration: 0.24)) { progress = 1 }
                    try? await Task.sleep(for: .milliseconds(220))
                    withAnimation(.spring(response: 0.22, dampingFraction: 0.45)) { pop = true }
                    try? await Task.sleep(for: .milliseconds(130))
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.7)) { pop = false }
                }
            }
    }
}

struct CheckPath: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.midY))
        p.addLine(to: CGPoint(x: r.minX + r.width * 0.36, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY))
        return p
    }
}

// MARK: - 说话中的全屏遮罩（微信式）

struct RecordingOverlay: View {
    let talk: TalkController

    private var cancelling: Bool { talk.phase == .cancelArmed }
    @State private var appeared = false

    var body: some View {
        ZStack {
            Color.black.opacity(0.82).ignoresSafeArea()
            VStack(spacing: 16) {
                Spacer()
                VStack(spacing: 16) {
                    Waveform(level: talk.recorder.level, color: .white)
                        .frame(height: 48)
                    Text(Duration.seconds(talk.recorder.elapsed), format: .time(pattern: .minuteSecond))
                        .font(.title2.weight(.semibold).monospacedDigit()).foregroundStyle(.white)
                }
                .padding(.vertical, 24)
                .frame(width: 230)
                .background(RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .fill(cancelling ? Color(white: 0.23) : P.accentFill))
                .shadow(color: cancelling ? .clear : P.accentFill.opacity(0.45), radius: 30, y: 12)
                .scaleEffect(appeared ? 1 : 0.8)

                if cancelling {
                    Text("松开手指，取消并删掉这一轮的字").font(.subheadline).foregroundStyle(Color(white: 0.79))
                } else {
                    Text(talk.engine == "ime" ? "输入法在听，文字直接出现在电脑上" : "正在听…")
                        .font(.subheadline).foregroundStyle(Color(white: 0.79))
                }
                Spacer()

                VStack(spacing: 10) {
                    Image(systemName: "xmark").font(.system(size: cancelling ? 34 : 28, weight: .bold))
                        .foregroundStyle(cancelling ? .white : Color(white: 0.79))
                        .frame(width: cancelling ? 92 : 76, height: cancelling ? 92 : 76)
                        .background(Circle().fill(cancelling ? Color(red: 0.9, green: 0.33, blue: 0.29) : Color(white: 0.17)))
                    Text(cancelling ? "松开 取消" : "上滑到这里取消")
                        .font(cancelling ? .subheadline.weight(.semibold) : .subheadline)
                        .foregroundStyle(cancelling ? P.dangerText : P.text2)
                }
                .animation(.spring(duration: 0.25), value: cancelling)
                .padding(.bottom, 40)

                VStack(spacing: 8) {
                    Image(systemName: "mic").font(.system(size: 22, weight: .semibold)).foregroundStyle(P.accent)
                    Text(cancelling ? "手指在上方" : "松开 结束").font(.headline)
                        .foregroundStyle(cancelling ? P.text3 : .white)
                    Text(cancelling ? "滑回来继续说" : "文字进电脑输入框，点 ↑ 才发送")
                        .font(.footnote).foregroundStyle(P.text3)
                }
                .frame(maxWidth: .infinity).frame(height: 150).padding(.top, 10)
                .background(
                    UnevenRoundedRectangle(topLeadingRadius: 70, topTrailingRadius: 70)
                        .fill(LinearGradient(colors: [Color(white: 0.23), Color(white: 0.17)], startPoint: .top, endPoint: .bottom))
                        .ignoresSafeArea(edges: .bottom)
                )
            }
        }
        .allowsHitTesting(false)   // 手势仍由底部说话条持有
        .onAppear { withAnimation(.spring(response: 0.25, dampingFraction: 0.7)) { appeared = true } }
    }
}

struct Waveform: View {
    let level: Double
    let color: Color
    private let weights: [Double] = [0.3, 0.6, 0.85, 0.5, 1, 0.65, 0.4, 0.8, 0.55, 0.25]

    var body: some View {
        HStack(spacing: 5) {
            ForEach(weights.indices, id: \.self) { i in
                Capsule().fill(color)
                    .frame(width: 5, height: max(6, 48 * (0.15 + 0.85 * level) * weights[i]))
            }
        }
        .animation(.easeOut(duration: 0.1), value: level)
        .accessibilityHidden(true)
    }
}
