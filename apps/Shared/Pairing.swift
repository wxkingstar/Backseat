import Foundation
import Observation
import Security

/// 钥匙串里的一个字符串。锁屏后也要能读（后台收审批、快捷指令），所以用 AfterFirstUnlock。
enum Keychain {
    private static func query(_ key: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "backseat",
         kSecAttrAccount as String: key]
    }

    static func get(_ key: String) -> String? {
        var q = query(key)
        q[kSecReturnData as String] = true
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func set(_ key: String, _ value: String?) {
        SecItemDelete(query(key) as CFDictionary)
        guard let value else { return }
        var q = query(key)
        q[kSecValueData as String] = Data(value.utf8)
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(q as CFDictionary, nil)
    }
}

/// 和 Mac 的配对状态。没配对时界面只显示配对页。
@MainActor @Observable
final class Pairing {
    static let shared = Pairing()

    private(set) var isPaired = !BridgeClient.shared.token.isEmpty

    /// address：Mac 的 IP 或主机名，可以带「:端口」。code：Mac 上显示的 6 位配对码。
    func pair(address: String, code: String) async throws {
        let parts = address.trimmingCharacters(in: .whitespaces).split(separator: ":")
        guard let host = parts.first.map(String.init) else { throw BridgeError.noHost }
        try await BridgeClient.shared.pair(host: host, port: parts.count > 1 ? String(parts[1]) : "8787",
                                           code: code.trimmingCharacters(in: .whitespaces))
        isPaired = true
    }

    func unpair() {
        BridgeClient.shared.unpair()
        isPaired = false
    }
}
