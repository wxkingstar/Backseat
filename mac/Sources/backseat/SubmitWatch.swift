import AppKit

/// 盯着电脑上的回车：在任何应用里按回车把输入框里的内容发出去后，告诉手机收起「清空 / 发送」两个键。
/// 用的是「辅助功能」权限下的事件拦截（只看不改，事件原样放行），不需要另外开「输入监控」。
enum SubmitWatch {
    private static var tap: CFMachPort?
    private static var onSubmit: (() -> Void)?

    /// 在主线程调用。还没有辅助功能权限时建不起来，隔几秒再试，权限给了就能用
    static func start(_ handler: @escaping () -> Void) {
        onSubmit = handler
        install()
    }

    private static func install() {
        guard tap == nil else { return }
        guard let t = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .tailAppendEventTap, options: .defaultTap,
                                        eventsOfInterest: CGEventMask(1 << CGEventType.keyDown.rawValue),
                                        callback: { _, type, event, _ in
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let t = SubmitWatch.tap { CGEvent.tapEnable(tap: t, enable: true) }
                return Unmanaged.passUnretained(event)
            }
            let code = event.getIntegerValueField(.keyboardEventKeycode)
            // 回车 / 小键盘回车；Shift、Option + 回车是换行，不算发送
            if type == .keyDown, code == 36 || code == 76,
               event.getIntegerValueField(.keyboardEventAutorepeat) == 0,
               event.flags.isDisjoint(with: [.maskShift, .maskAlternate]) {
                // 回调里不能做慢事，等应用处理完回车再去看输入框
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { SubmitWatch.check() }
            }
            return Unmanaged.passUnretained(event)
        }, userInfo: nil) else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { install() }
            return
        }
        tap = t
        CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, t, 0), .commonModes)
        CGEvent.tapEnable(tap: t, enable: true)
    }

    /// 回车之后输入框空了才算发出去。输入框里还有字，说明这个回车是输入法上屏或换行。
    /// 读不到输入框的应用（终端里的 Claude Code 等）按发送算
    private static func check() {
        let text = Focus.focusedText()?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if text.isEmpty { onSubmit?() }
    }
}
