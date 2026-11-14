import Foundation
import HealthKit

/// 遥控模式下用一个不保存的「体能训练」会话让 App 保持运行：
/// 放下手腕后仍能收消息、震动；抬腕直接回到本 App。
final class RemoteSession: NSObject, HKWorkoutSessionDelegate, @unchecked Sendable {
    private let health = HKHealthStore()
    private var session: HKWorkoutSession?

    var isRunning: Bool { session?.state == .running }

    func start() async throws {
        guard session == nil else { return }
        try await health.requestAuthorization(toShare: [HKObjectType.workoutType()], read: [])
        let cfg = HKWorkoutConfiguration()
        cfg.activityType = .mindAndBody
        cfg.locationType = .indoor
        let s = try HKWorkoutSession(healthStore: health, configuration: cfg)
        s.delegate = self
        s.startActivity(with: Date())
        session = s
    }

    func stop() {
        session?.end() // 没有 builder，不会写入任何体能训练记录
        session = nil
    }

    func workoutSession(_ s: HKWorkoutSession, didChangeTo toState: HKWorkoutSessionState,
                        from fromState: HKWorkoutSessionState, date: Date) {}

    func workoutSession(_ s: HKWorkoutSession, didFailWithError error: Error) {
        session = nil
    }
}
