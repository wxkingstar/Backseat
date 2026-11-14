import Foundation
import WatchConnectivity

/// 手机配对好 Mac 以后，把配对信息（Mac 地址、端口、凭证）传给自己的手表，手表上就不用再输入。
/// 走系统的手表与手机通信，只在手表和它配对的那台 iPhone 之间有效，内容由系统加密传输。
final class DeviceSync: NSObject, WCSessionDelegate, @unchecked Sendable {
    static let shared = DeviceSync()

    /// 手表收到新的配对信息并采用后回调（主线程）
    var onAdopted: (() -> Void)?

    func start() {
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    #if os(iOS)
    /// 手机：把当前的配对信息推给手表。配对成功后、每次启动时都调，已经一样就不会重复传
    func pushToWatch() {
        let s = WCSession.default
        guard s.activationState == .activated, let info = BridgeClient.shared.pairingInfo else { return }
        try? s.updateApplicationContext(info)
    }

    func sessionDidBecomeInactive(_ session: WCSession) {}
    func sessionDidDeactivate(_ session: WCSession) { session.activate() }

    /// 手表主动来要配对信息
    func session(_ session: WCSession, didReceiveMessage message: [String: Any],
                 replyHandler: @escaping ([String: Any]) -> Void) {
        replyHandler(BridgeClient.shared.pairingInfo ?? [:])
    }
    #endif

    func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?) {
        #if os(iOS)
        pushToWatch()
        #else
        adopt(session.receivedApplicationContext)
        #endif
    }

    #if os(watchOS)
    func session(_ session: WCSession, didReceiveApplicationContext context: [String: Any]) {
        adopt(context)
    }

    /// 手表：还没配对时，直接问手机要一次（手机 App 在后台也会被系统唤起来回答）
    func requestFromPhone() {
        let s = WCSession.default
        guard s.activationState == .activated, s.isReachable else { return }
        s.sendMessage(["want": "pairing"], replyHandler: { [weak self] reply in self?.adopt(reply) }, errorHandler: nil)
    }

    private func adopt(_ info: [String: Any]) {
        guard BridgeClient.shared.adopt(info) else { return }
        DispatchQueue.main.async { self.onAdopted?() }
    }
    #endif
}
