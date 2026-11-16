import SwiftUI
import UIKit

/// 触控板：照 Mac 触控板的手势来。
/// 单指移动指针、轻点单击、连点双击、按住不动再拖 = 拖拽；双指滚动（带惯性）、双指轻点 = 右键；
/// 三指 / 四指轻扫的动作在设置里选。
struct TrackpadView: View {
    var fullScreen = false
    var onToggleFull: () -> Void

    @Environment(PhoneStore.self) private var store
    @AppStorage("mouseSpeed") private var mouseSpeed = 1.0
    @AppStorage("threeFinger") private var threeFinger = SwipeAction.spaces.rawValue
    @AppStorage("fourFinger") private var fourFinger = SwipeAction.off.rawValue

    /// 双指滚动：手指移动 1pt 滚动多少像素
    private let scrollGain: CGFloat = 1.6

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 22, style: .continuous).fill(P.pad)
            DotGrid().clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(P.padLine)

            VStack(spacing: 6) {
                Image(systemName: "hand.point.up.left")
                    .font(.system(size: 30)).foregroundStyle(P.text3).padding(.bottom, 4)
                Text("单指移动指针 · 轻点点击").font(.subheadline).foregroundStyle(P.textSoft)
                Text("双指滚动 / 捏合缩放 · 双指轻点右键")
                    .font(.footnote).foregroundStyle(P.text3)
                Text("拖拽：按住半秒再移动，或轻点后马上按住拖动").font(.footnote).foregroundStyle(P.text3)
                Text("三指：\(SwipeAction(rawValue: threeFinger)?.title ?? "") · 四指：\(SwipeAction(rawValue: fourFinger)?.title ?? "")")
                    .font(.footnote).foregroundStyle(P.text3)
            }
            .multilineTextAlignment(.center)
            .padding(.horizontal, 12)
            .allowsHitTesting(false)
            .accessibilityHidden(true)

            PadSurface(
                onMove: { d in
                    // 指针加速：慢慢移是精确定位，快速划是大范围移动
                    let speed = hypot(d.x, d.y)
                    let gain: CGFloat = (speed < 1.5 ? 2.2 : speed < 5 ? 4.5 : 8.0) * mouseSpeed
                    store.moveMouse(dx: d.x * gain, dy: d.y * gain)
                },
                // 自然滚动：手指往上推，内容跟着往上走
                onScroll: { d in store.scrollDrag(dx: -d.x * scrollGain, dy: -d.y * scrollGain) },
                onFling: { v in store.scrollFling(dx: -v.x * scrollGain, dy: -v.y * scrollGain) },
                // 两指张开 = 放大，合拢 = 缩小
                onZoom: { d in store.zoom(d * 1.2) },
                onClick: { right, state in store.click(right: right, state: state) },
                onDrag: { down in store.mouseButton(down: down) },
                onSwipe: { fingers, dir in
                    let action = SwipeAction(rawValue: fingers == 3 ? threeFinger : fourFinger) ?? .off
                    guard let key = action.key(for: dir) else { return }
                    if key.hasPrefix("app:") { store.openMacApp(String(key.dropFirst(4))) } else { store.press(key) }
                },
                // 三指轻点 = 查询（和 Mac 的「查询与数据检测器」一样，查指针下的词）
                onLookup: { store.press("ctrl+cmd+d") },
                // 四指张开 = 显示桌面；四指合拢 = 应用程序（原来的启动台）
                onPinch4: { spread in
                    if spread { store.press("f11") } else { store.openMacApp("Apps") }
                }
            )
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
        .overlay(alignment: .topLeading) {
            Text("触控板").font(.caption.weight(.semibold)).foregroundStyle(P.text3)
                .padding(.leading, 14).padding(.top, 12)
                .allowsHitTesting(false)
        }
        .overlay(alignment: .topTrailing) {
            Button(action: onToggleFull) {
                Image(systemName: fullScreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 14, weight: .semibold)).foregroundStyle(P.textSoft)
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(PressStyle(fill: P.card, radius: 22))
            .padding(6)
            .accessibilityLabel(fullScreen ? "退出全屏触控板" : "全屏触控板")
        }
        .disabled(!store.connected)
        .accessibilityLabel("触控板")
        .accessibilityHint("单指移动指针，双指滚动")
        .accessibilityAction(named: "向下滚动") { store.scroll(dx: 0, dy: 400) }
        .accessibilityAction(named: "向上滚动") { store.scroll(dx: 0, dy: -400) }
    }
}

enum SwipeDirection { case left, right, up, down }

/// 三指 / 四指轻扫能做的事
enum SwipeAction: String, CaseIterable, Identifiable {
    case pages, spaces, off
    var id: String { rawValue }

    var title: String {
        switch self {
        case .pages: return "前进 / 后退"
        case .spaces: return "切换桌面与调度中心"
        case .off: return "关闭"
        }
    }

    /// 方向是手指移动的方向，和 Mac 触控板一致
    func key(for dir: SwipeDirection) -> String? {
        switch (self, dir) {
        case (.pages, .right): return "cmd+["      // 手指往右扫 = 后退
        case (.pages, .left): return "cmd+]"       // 手指往左扫 = 前进
        case (.spaces, .left): return "ctrl+right" // 下一个桌面 / 全屏应用
        case (.spaces, .right): return "ctrl+left"
        case (.spaces, .up): return "app:Mission Control"   // 调度中心（直接打开，不依赖快捷键设置）
        case (.spaces, .down): return "ctrl+down"  // 应用程序窗口
        default: return nil
        }
    }
}

struct DotGrid: View {
    var body: some View {
        Canvas { ctx, size in
            let step: CGFloat = 18
            var y: CGFloat = step / 2
            while y < size.height {
                var x: CGFloat = step / 2
                while x < size.width {
                    ctx.fill(Path(ellipseIn: CGRect(x: x - 1, y: y - 1, width: 2, height: 2)), with: .color(P.padDot))
                    x += step
                }
                y += step
            }
        }
        .accessibilityHidden(true)
    }
}

// MARK: - 多指触摸层（UIKit：SwiftUI 的手势拿不到每根手指）

struct PadSurface: UIViewRepresentable {
    var onMove: (CGPoint) -> Void
    var onScroll: (CGPoint) -> Void
    var onFling: (CGPoint) -> Void
    var onZoom: (CGFloat) -> Void
    var onClick: (_ right: Bool, _ state: Int) -> Void
    var onDrag: (_ down: Bool) -> Void
    var onSwipe: (_ fingers: Int, _ dir: SwipeDirection) -> Void
    var onLookup: () -> Void
    var onPinch4: (_ spread: Bool) -> Void

    func makeUIView(context: Context) -> PadTouchView {
        let v = PadTouchView()
        v.isMultipleTouchEnabled = true
        v.backgroundColor = .clear
        return v
    }

    func updateUIView(_ v: PadTouchView, context: Context) { v.handlers = self }
}

final class PadTouchView: UIView {
    var handlers: PadSurface?

    private var active = Set<UITouch>()
    private var dots: [UITouch: CALayer] = [:]
    private var peak = 0                  // 这一轮手势里最多同时有几根手指
    private var startTime = 0.0
    private var travel: CGFloat = 0       // 累计移动距离，区分轻点和滑动
    private var swipeTotal = CGPoint.zero
    private var swipeFired = false
    private var dragging = false
    private var holdTimer: DispatchWorkItem?
    private var velocity = CGPoint.zero   // 双指滚动速度（pt/s），算惯性
    private var lastMoveTime = 0.0
    private var lastTapTime = 0.0
    private var tapCount = 0              // 连续轻点次数：1 单击、2 双击（选词）、3 三击（选整段）
    private var tapDragArmed = false      // 轻点后马上又按下：这次移动算拖拽
    private var spread0: CGFloat = 0      // 四指手势开始时，手指到中心的平均距离

    /// 所有手指到它们中心点的平均距离，判断四指是张开还是合拢
    private var spread: CGFloat {
        let pts = active.map { $0.location(in: self) }
        guard !pts.isEmpty else { return 0 }
        let cx = pts.map(\.x).reduce(0, +) / CGFloat(pts.count), cy = pts.map(\.y).reduce(0, +) / CGFloat(pts.count)
        return pts.map { hypot($0.x - cx, $0.y - cy) }.reduce(0, +) / CGFloat(pts.count)
    }
    // 双指：先判断这次是滚动还是捏合，判定后整个手势不再变
    private enum TwoMode { case undecided, scroll, pinch }
    private var twoMode = TwoMode.undecided
    private var lastDist: CGFloat = 0     // 两指间距
    private var pinchAcc: CGFloat = 0
    private var panAcc: CGFloat = 0
    private var maxSep: CGFloat = 0       // 两指最大间距，用来排除「一根手指被识别成两个触点」
    private var secondDelay = 0.0         // 第二根手指比第一根晚多久落下

    private var twoDist: CGFloat {
        let ts = Array(active)
        guard ts.count == 2 else { return 0 }
        let a = ts[0].location(in: self), b = ts[1].location(in: self)
        return hypot(a.x - b.x, a.y - b.y)
    }

    private var moved: Bool { travel > 6 }

    /// 关掉 iOS 自带的三指手势（三指轻扫撤销、三指轻点弹编辑菜单），否则会和触控板的三指轻扫打架
    override var editingInteractionConfiguration: UIEditingInteractionConfiguration { .none }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        let now = CACurrentMediaTime()
        if active.isEmpty {
            peak = 0; travel = 0; swipeTotal = .zero; swipeFired = false
            velocity = .zero; startTime = now; lastMoveTime = now
            twoMode = .undecided; pinchAcc = 0; panAcc = 0; maxSep = 0; secondDelay = 0
            tapDragArmed = now - lastTapTime < 0.3
        }
        for t in touches { active.insert(t); addDot(t) }
        peak = max(peak, active.count)
        if active.count >= 4 { spread0 = spread }
        if active.count == 2 {
            lastDist = twoDist
            maxSep = max(maxSep, lastDist)
            if secondDelay == 0 { secondDelay = now - startTime }
        }

        holdTimer?.cancel()
        if active.count == 1 && peak == 1 {
            // 单指按住不动 0.45 秒 = 按下左键，之后移动就是拖拽
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.active.count == 1, self.peak == 1, !self.moved else { return }
                self.dragging = true
                Haptics.medium()
                self.handlers?.onDrag(true)
            }
            holdTimer = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: work)
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard !active.isEmpty else { return }
        var d = CGPoint.zero
        for t in touches where active.contains(t) {
            let a = t.location(in: self), b = t.previousLocation(in: self)
            d.x += a.x - b.x
            d.y += a.y - b.y
            moveDot(t)
        }
        // 多根手指取平均，得到这组手指整体移动了多少
        d.x /= CGFloat(active.count)
        d.y /= CGFloat(active.count)
        travel += hypot(d.x, d.y)
        if moved && !dragging { holdTimer?.cancel() }

        let now = CACurrentMediaTime()
        let dt = max(now - lastMoveTime, 0.001)
        lastMoveTime = now

        switch active.count {
        case 1:
            // 多指手势里剩下的最后一根手指不算指针移动，避免抬手时指针跳一下
            guard peak == 1, moved || dragging else { return }
            if tapDragArmed && !dragging {
                // 轻点后马上按住拖动（Mac 上「轻点来点按」时的拖拽手法）
                dragging = true
                holdTimer?.cancel()
                Haptics.medium()
                handlers?.onDrag(true)
            }
            handlers?.onMove(d)
        case 2:
            let dist = twoDist
            let dd = dist - lastDist
            lastDist = dist
            maxSep = max(maxSep, dist)
            if twoMode == .undecided {
                // 间距变化明显大于整体平移 = 捏合；否则是滚动
                pinchAcc += abs(dd)
                panAcc += hypot(d.x, d.y)
                if max(pinchAcc, panAcc) > 10 { twoMode = pinchAcc > panAcc * 1.3 ? .pinch : .scroll }
                travel += abs(dd)
                return
            }
            if twoMode == .pinch {
                handlers?.onZoom(dd)
                return
            }
            handlers?.onScroll(d)
            let v = CGPoint(x: d.x / dt, y: d.y / dt)
            velocity = CGPoint(x: velocity.x * 0.6 + v.x * 0.4, y: velocity.y * 0.6 + v.y * 0.4)
        default:
            swipeTotal.x += d.x
            swipeTotal.y += d.y
            guard !swipeFired else { return }
            // 四指张开 / 合拢：手指散开或收拢了 35pt 以上，而整体没怎么平移
            if active.count >= 4, abs(spread - spread0) > 35, hypot(swipeTotal.x, swipeTotal.y) < 30 {
                swipeFired = true
                Haptics.medium()
                handlers?.onPinch4(spread > spread0)
                return
            }
            guard max(abs(swipeTotal.x), abs(swipeTotal.y)) > 45 else { return }
            swipeFired = true
            let dir: SwipeDirection = abs(swipeTotal.x) > abs(swipeTotal.y)
                ? (swipeTotal.x > 0 ? .right : .left) : (swipeTotal.y > 0 ? .down : .up)
            Haptics.medium()
            handlers?.onSwipe(min(active.count, 4), dir)
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { lift(touches, cancelled: false) }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { lift(touches, cancelled: true) }

    private func lift(_ touches: Set<UITouch>, cancelled: Bool) {
        for t in touches { active.remove(t); removeDot(t) }
        guard active.isEmpty else { return }
        holdTimer?.cancel()
        let now = CACurrentMediaTime()

        if dragging {
            dragging = false
            handlers?.onDrag(false)
        } else if !cancelled, !moved, now - startTime < 0.3 {
            if peak == 1 {
                // 0.35 秒内连点：双击选词，三击选整段
                tapCount = now - lastTapTime < 0.35 ? min(tapCount + 1, 3) : 1
                lastTapTime = now
                Haptics.press()
                handlers?.onClick(false, tapCount)
            } else if peak == 2 {
                // 右键要求是真的两根手指：几乎同时落下，而且分开一定距离。
                // 一根手指的指腹偶尔会被屏幕识别成两个挨着的触点，那种情况按普通单击处理
                let real = secondDelay < 0.15 && maxSep >= 36
                Haptics.press()
                handlers?.onClick(real, 1)
            } else if peak == 3 {
                Haptics.press()
                handlers?.onLookup()
            }
        } else if peak == 2, twoMode == .scroll {
            // 松手时还在动才有惯性；停住再抬手就原地停下。都要发一次，让 Mac 结束这次滚动手势
            let live = now - lastMoveTime < 0.08
            handlers?.onFling(live ? CGPoint(x: velocity.x * 0.3, y: velocity.y * 0.3) : .zero)
        }
    }

    // MARK: - 手指位置的光圈

    private func addDot(_ t: UITouch) {
        let l = CALayer()
        l.bounds = CGRect(x: 0, y: 0, width: 56, height: 56)
        l.cornerRadius = 28
        l.backgroundColor = UIColor(P.accent).withAlphaComponent(0.22).cgColor
        l.borderColor = UIColor(P.accent).withAlphaComponent(0.6).cgColor
        l.borderWidth = 1.5
        l.position = t.location(in: self)
        layer.addSublayer(l)
        dots[t] = l
    }

    private func moveDot(_ t: UITouch) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        dots[t]?.position = t.location(in: self)
        CATransaction.commit()
    }

    private func removeDot(_ t: UITouch) {
        dots[t]?.removeFromSuperlayer()
        dots[t] = nil
    }
}
