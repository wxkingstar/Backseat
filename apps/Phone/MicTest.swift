import AVFoundation
import UIKit

/// 麦克风自检：用多种录音方式和会话配置各录 0.7 秒，把拿到的峰值和系统音频状态发到 Mac 日志。
/// 正常的麦克风在安静环境里也不会是绝对的 0，所以不需要说话。
/// 启动参数带 -micTest 时自动运行，设置页里也能手动触发。
@MainActor
enum MicTest {
    static func run() async {
        let s = AVAudioSession.sharedInstance()
        await send("===== 麦克风自检 \(UIDevice.current.model) iOS \(UIDevice.current.systemVersion) =====")
        await send("权限 session=\(AVAudioApplication.shared.recordPermission == .granted) capture=\(AVCaptureDevice.authorizationStatus(for: .audio).rawValue)(3=已授权) "
                   + "输入静音=\(AVAudioApplication.shared.isInputMuted) 有输入=\(s.isInputAvailable) "
                   + "其他音频在播=\(s.isOtherAudioPlaying) 屏幕被采集=\(UIScreen.main.isCaptured) "
                   + "App状态=\(UIApplication.shared.applicationState.rawValue)(0=前台)")
        let inputs = (s.availableInputs ?? []).map { "\($0.portName)[\($0.portType.rawValue)]" }.joined(separator: ", ")
        await send("可用输入：\(inputs)")

        let configs: [(String, AVAudioSession.Category, AVAudioSession.Mode, AVAudioSession.CategoryOptions)] = [
            ("record/default", .record, .default, []),
            ("record/measurement", .record, .measurement, []),
            ("playAndRecord/default", .playAndRecord, .default, [.defaultToSpeaker]),
            ("playAndRecord/voiceChat", .playAndRecord, .voiceChat, []),
            ("playAndRecord/videoRecording", .playAndRecord, .videoRecording, []),
        ]
        for (name, cat, mode, opts) in configs {
            do {
                try s.setCategory(cat, mode: mode, options: opts)
                try s.setActive(true)
            } catch {
                await send("\(name)：会话启动失败 \(error.localizedDescription)")
                continue
            }
            let route = s.currentRoute
            let rin = route.inputs.map { "\($0.portName)/\($0.selectedDataSource?.dataSourceName ?? "-")" }.joined(separator: ",")
            let rout = route.outputs.map { $0.portName }.joined(separator: ",")
            let eng = await enginePeak()
            let rec = await recorderPeak()
            await send("\(name)：引擎=\(eng) 录音机=\(rec) | 输入[\(rin)] 输出[\(rout)] \(Int(s.sampleRate))Hz 增益=\(s.inputGain)")
            try? s.setActive(false, options: .notifyOthersOnDeactivation)
        }

        await send("AVCapture：\(await capturePeak())")
        await send("===== 自检结束 =====")
    }

    private static func send(_ text: String) async {
        _ = try? await BridgeClient.shared.call("POST", "/api/log", body: ["text": text], timeout: 4)
    }

    private static func db(_ peak: Float) -> String {
        peak > 0 ? "\(Int(20 * log10(Double(peak))))dB" : "全零"
    }

    private final class Peak: @unchecked Sendable {
        private let lock = NSLock()
        private var v: Float = 0
        private var n = 0
        func feed(_ buf: AVAudioPCMBuffer) {
            guard let ch = buf.floatChannelData?[0] else { return }
            var m: Float = 0
            for i in 0..<Int(buf.frameLength) { m = max(m, abs(ch[i])) }
            lock.lock(); v = max(v, m); n += 1; lock.unlock()
        }
        var result: (Float, Int) { lock.lock(); defer { lock.unlock() }; return (v, n) }
    }

    private static func enginePeak() async -> String {
        let e = AVAudioEngine()
        let fmt = e.inputNode.outputFormat(forBus: 0)
        guard fmt.sampleRate > 0 else { return "无格式" }
        let peak = Peak()
        e.inputNode.installTap(onBus: 0, bufferSize: 2048, format: fmt) { buf, _ in peak.feed(buf) }
        do { try e.start() } catch { return "启动失败" }
        try? await Task.sleep(for: .milliseconds(700))
        e.inputNode.removeTap(onBus: 0)
        e.stop()
        let (v, n) = peak.result
        return n == 0 ? "没有回调" : db(v)
    }

    private static func recorderPeak() async -> String {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mictest.wav")
        try? FileManager.default.removeItem(at: url)
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16_000,
                                       AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16]
        guard let r = try? AVAudioRecorder(url: url, settings: settings) else { return "创建失败" }
        r.isMeteringEnabled = true
        guard r.record() else { return "启动失败" }
        try? await Task.sleep(for: .milliseconds(700))
        r.updateMeters()
        let p = r.peakPower(forChannel: 0)
        r.stop()
        return p <= -159 ? "全零" : "\(Int(p))dB"
    }

    private static func capturePeak() async -> String {
        let pipe = ChunkPipe()
        try? pipe.prepare(onChunk: { _, _ in }, onLevel: { _ in })
        let cap = CaptureInput(pipe: pipe)
        do { try cap.start() } catch { return "启动失败 \(error.localizedDescription)" }
        try? await Task.sleep(for: .milliseconds(900))
        cap.stop()
        return db(pipe.rawPeak)
    }
}
