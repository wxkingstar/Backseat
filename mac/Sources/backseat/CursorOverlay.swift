import AppKit

/// 手机操控指针时，在屏幕上叠一个绿色的指针。
/// 远程桌面（RustDesk 等）传回来的画面里不带这台 Mac 的真实指针，只画操控端自己的；
/// 这个指针是画在屏幕内容里的，远程画面里看得到。手机停止操控几秒后自动隐藏。
enum CursorOverlay {
    private static let size = NSSize(width: 26, height: 30)
    private static var window: NSWindow?
    private static var hideWork: DispatchWorkItem?

    /// p：指针位置，全局坐标（左上角为原点，和 CGEvent 一致）。任意线程可调
    static func show(at p: CGPoint) {
        DispatchQueue.main.async {
            let w = window ?? make()
            window = w
            // AppKit 的原点在主屏左下角；指针尖在图形左上角。
            // 窗口整体放在指针位置的右下方 1pt：指针正下方那个点不能被这个窗口盖住，
            // 否则手机发来的点击会落在这个窗口上，下面的应用收不到
            let top = NSScreen.screens.first?.frame.height ?? 0
            w.setFrameOrigin(NSPoint(x: p.x + 1, y: top - p.y - size.height - 1))
            if !w.isVisible { w.orderFrontRegardless() }
            hideWork?.cancel()
            let work = DispatchWorkItem { w.orderOut(nil) }
            hideWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: work)
        }
    }

    private static func make() -> NSWindow {
        let w = NSPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = false
        w.ignoresMouseEvents = true
        // 盖在所有窗口、菜单和全屏应用上面；每个桌面都有
        w.level = .screenSaver
        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        w.contentView = ArrowView(frame: NSRect(origin: .zero, size: size))
        return w
    }

    /// 箭头形状的指针：绿色填充、白色描边，在深浅背景上都看得清
    private final class ArrowView: NSView {
        override var isFlipped: Bool { true }

        override func draw(_ dirtyRect: NSRect) {
            let path = NSBezierPath()
            let pts: [(CGFloat, CGFloat)] = [(1.5, 1.5), (1.5, 23.5), (7.5, 18), (12, 27.5), (16, 25.5), (11.5, 16.5), (19.5, 16.5)]
            path.move(to: NSPoint(x: pts[0].0, y: pts[0].1))
            pts.dropFirst().forEach { path.line(to: NSPoint(x: $0.0, y: $0.1)) }
            path.close()
            path.lineJoinStyle = .round
            path.lineWidth = 2.5
            NSColor.white.setStroke()
            path.stroke()
            NSColor(red: 0.16, green: 0.80, blue: 0.36, alpha: 1).setFill()
            path.fill()
        }
    }
}
