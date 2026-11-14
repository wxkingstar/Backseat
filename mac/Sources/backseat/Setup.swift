import Foundation

/// 首次启动的自动配置：生成 token、安装 hook 脚本、注册 Claude Code hooks。每次启动都跑，已配好就什么都不改。
enum Setup {
    static let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".backseat")
    static let configURL = dir.appendingPathComponent("config.json")
    static let hookURL = dir.appendingPathComponent("hook.sh")

    /// Claude Code hook → bridge。bridge 没开时立即静默退出，不影响 Claude Code。
    static let hookScript = #"""
    #!/bin/bash
    # Claude Code hook → backseat bridge。bridge 没开时立即静默退出，不影响 Claude Code。
    EVENT="$1"
    TIMEOUT=5
    [ "$EVENT" = "PermissionRequest" ] && TIMEOUT=290
    out=$(curl -s -m "$TIMEOUT" -X POST -H 'Content-Type: application/json' --data-binary @- \
      "http://127.0.0.1:${BACKSEAT_PORT:-8787}/hook/$EVENT" 2>/dev/null) || exit 0
    if [ "$EVENT" = "PermissionRequest" ] && [ -n "$out" ] && [ "$out" != "{}" ]; then
      printf '%s' "$out"
    fi
    exit 0

    """#

    /// 读取配置；第一次运行时生成 token 并写入 ~/.backseat/config.json
    static func config() -> [String: Any] {
        if let data = try? Data(contentsOf: configURL),
           let cfg = try? JSONSerialization.jsonObject(with: data) as? [String: Any], cfg["token"] is String {
            return cfg
        }
        let token = (0..<16).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
        let cfg: [String: Any] = ["token": token, "port": 8787]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? JSONSerialization.data(withJSONObject: cfg).write(to: configURL)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configURL.path)
        return cfg
    }

    /// 安装 hook 脚本并注册到 ~/.claude/settings.json（只增不删，改之前先备份）。返回给日志看的说明。
    static func installHooks() -> String? {
        let fm = FileManager.default
        if (try? String(contentsOf: hookURL, encoding: .utf8)) != hookScript {
            try? hookScript.write(to: hookURL, atomically: true, encoding: .utf8)
            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hookURL.path)
        }

        let settings = fm.homeDirectoryForCurrentUser.appendingPathComponent(".claude/settings.json")
        var cfg: [String: Any] = [:]
        if let data = try? Data(contentsOf: settings) {
            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return "⚠️  读不懂 \(settings.path)，没有注册 Claude Code hooks"
            }
            cfg = obj
        }
        var hooks = cfg["hooks"] as? [String: Any] ?? [:]
        var changed = false
        let spec = ["UserPromptSubmit": 5, "Stop": 5, "Notification": 5, "SessionEnd": 5, "PermissionRequest": 300]
        for (event, timeout) in spec {
            let cmd = "\(hookURL.path) \(event)"
            var groups = hooks[event] as? [[String: Any]] ?? []
            let exists = groups.contains { g in
                (g["hooks"] as? [[String: Any]] ?? []).contains { $0["command"] as? String == cmd }
            }
            if exists { continue }
            groups.append(["hooks": [["type": "command", "command": cmd, "timeout": timeout]]])
            hooks[event] = groups
            changed = true
        }
        guard changed else { return nil }
        cfg["hooks"] = hooks
        if fm.fileExists(atPath: settings.path) {
            let backup = settings.path + ".bak-backseat-\(Int(Date().timeIntervalSince1970))"
            try? fm.copyItem(atPath: settings.path, toPath: backup)
        } else {
            try? fm.createDirectory(at: settings.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        guard let out = try? JSONSerialization.data(withJSONObject: cfg,
                                                    options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
              (try? out.write(to: settings, options: .atomic)) != nil else {
            return "⚠️  写不了 \(settings.path)，没有注册 Claude Code hooks"
        }
        return "已注册 Claude Code hooks：\(settings.path)（原文件已备份）"
    }
}
