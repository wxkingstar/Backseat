import SwiftUI
import WatchKit

/// 第三页：表冠 = Mac 鼠标滚轮。表冠每转一格震一下、滚一格；转得快会加速。
/// 进入这一页表冠就被接管，离开靠上下滑动屏幕。
struct ScrollPadView: View {
    let isActive: Bool
    @Environment(Store.self) private var store
    @State private var crown = 0.0
    @State private var lastCrown = 0.0
    @State private var lastTick = Date()
    @State private var wheel = 0.0
    @FocusState private var focused: Bool

    private static let span = 200.0

    /// 表冠一格滚多少像素（约等于鼠标滚轮一格）
    private let pixelsPerDetent = 36.0

    var body: some View {
        VStack(spacing: 8) {
            WheelGraphic(phase: wheel, active: focused)
                .frame(width: 58, height: 84)

            Text(focused ? "转动表冠滚动" : "点一下开始滚动")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(focused ? .white : .secondary)

            HStack(spacing: 6) {
                Button { page(-1) } label: { Image(systemName: "chevron.up.2") }
                    .buttonStyle(KeyStyle(height: 38))
                    .accessibilityLabel("上一屏")
                Button { page(1) } label: { Image(systemName: "chevron.down.2") }
                    .buttonStyle(KeyStyle(height: 38))
                    .accessibilityLabel("下一屏")
            }

            Text("滚动的是鼠标所在的窗口 · 滑屏换页")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onTapGesture { focused = true }
        .focusable()
        .focused($focused)
        // 范围不能太大：系统按格分配资源，±100 万格会把内存撑爆被系统杀掉。
        // 用小范围 + 循环，到头后从另一端接着转，下面按跨度修正跳变。
        .digitalCrownRotation($crown, from: -Self.span / 2, through: Self.span / 2, by: 1,
                              sensitivity: .medium, isContinuous: true, isHapticFeedbackEnabled: true)
        .onChange(of: crown) { _, v in
            var delta = v - lastCrown
            lastCrown = v
            if delta > Self.span / 2 { delta -= Self.span } else if delta < -Self.span / 2 { delta += Self.span }
            guard delta != 0 else { return }
            // 转得越快每格滚得越多，长页面也能很快翻到底
            let now = Date()
            let dt = now.timeIntervalSince(lastTick)
            lastTick = now
            let accel = dt < 0.035 ? 3.0 : dt < 0.07 ? 2.0 : 1.0
            store.scroll(pixels: delta * pixelsPerDetent * accel)
            withAnimation(.linear(duration: 0.08)) { wheel += delta }
        }
        .onChange(of: isActive) { _, a in focused = a }
        .onAppear { if isActive { focused = true } }
        .disabled(!store.connected)
        .opacity(store.connected ? 1 : 0.5)
        .navigationTitle("滚轮")
    }

    private func page(_ dir: Double) {
        WKInterfaceDevice.current().play(dir < 0 ? .directionUp : .directionDown)
        store.scroll(pixels: dir * 480)
    }
}

/// 一个鼠标滚轮的示意：滚动时纹路跟着走
private struct WheelGraphic: View {
    let phase: Double
    let active: Bool

    var body: some View {
        let spacing = 11.0
        let shift = (phase * 4).truncatingRemainder(dividingBy: spacing)
        ZStack {
            Capsule().fill(active ? Theme.accent.opacity(0.18) : Theme.surface)
            VStack(spacing: spacing - 3) {
                ForEach(0..<10, id: \.self) { _ in
                    Capsule().fill(active ? Theme.accent : Color.gray).frame(width: 26, height: 3)
                }
            }
            .offset(y: shift)
            .mask(Capsule().padding(6))
            Capsule().strokeBorder(active ? Theme.accent : Color.gray.opacity(0.5), lineWidth: 2)
        }
    }
}
