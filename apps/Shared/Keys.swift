import Foundation

/// 手机和手表共用的按键目录。每个键一张图标（Keys.xcassets 里的 key-<名字>）。
/// 手机：iPhone Duo 右侧栏放哪些、什么顺序在设置里调；手表：按键页放哪些在手表设置里选。
/// 没放出来的都收在「所有按键」里。
enum SideKeyKind: String, Codable, CaseIterable, Identifiable {
    case more, cmdEnter, backspace, comma, newline, enter, esc, tab, space, up, down, left, right, period, one, two, three

    var id: String { rawValue }

    var title: String {
        switch self {
        case .more: "所有按键"
        case .cmdEnter: "⌘ 回车"
        case .backspace: "退格"
        case .comma: "逗号"
        case .newline: "换行（⇧ 回车）"
        case .enter: "回车"
        case .esc: "Esc"
        case .tab: "Tab"
        case .space: "空格"
        case .up: "方向键 上"
        case .down: "方向键 下"
        case .left: "方向键 左"
        case .right: "方向键 右"
        case .period: "句号"
        case .one: "数字 1"
        case .two: "数字 2"
        case .three: "数字 3"
        }
    }

    /// 发给 Mac 的按键名；逗号、句号是直接输入文字，「所有按键」只是展开面板，都没有按键名
    var key: String? {
        switch self {
        case .more, .comma, .period: nil
        case .cmdEnter: "cmd+enter"
        case .newline: "shift+enter"
        case .one: "1"
        case .two: "2"
        case .three: "3"
        default: rawValue
        }
    }

    /// 直接输入到 Mac 的文字
    var text: String? {
        switch self {
        case .comma: "，"
        case .period: "。"
        default: nil
        }
    }

    /// 手机右侧栏默认的几个，从上到下；越常用越靠下，离拇指越近
    static let defaults: [SideKeyKind] = [.more, .cmdEnter, .backspace, .comma, .newline]
    /// 右侧栏从系统状态图标下面到屏幕底，最多排得下这么多（状态图标被实时活动挤下来时也不重叠）
    static let limit = 7
    /// 手表按键页默认的几个
    static let watchDefaults: [SideKeyKind] = [.esc, .tab, .one, .two, .three, .up, .down, .enter]

    static func load(_ storeKey: String, fallback: [SideKeyKind]) -> [SideKeyKind] {
        guard let raw = UserDefaults.standard.stringArray(forKey: storeKey) else { return fallback }
        return raw.compactMap(SideKeyKind.init(rawValue:))
    }

    static func save(_ list: [SideKeyKind], _ storeKey: String) {
        UserDefaults.standard.set(list.map(\.rawValue), forKey: storeKey)
    }
}
