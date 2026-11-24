import AVFoundation
import Carbon
import Foundation

/// 把手表当作 Mac 的麦克风：手表 / 手机实时推来的 PCM 播放进回环声卡（VirtualMic），
/// 同时模拟长按语音快捷键触发语音输入法（默认豆包，长按 Fn），输入法从虚拟麦克风收音、识别并上屏。
/// 没装语音输入法或虚拟麦克风创建失败时，退回 Mac 内置识别（整段转写后粘贴）。
final class MicStream: @unchecked Sendable {
    static let sampleRate = 16_000.0
    /// 语音输入法：输入源 ID + 它「长按说话」的快捷键
    struct VoiceIME {
        let sourceID: String
        let holdKey: String
    }
    /// 没有配置时自动识别的输入法
    static let knownIMEs = [VoiceIME(sourceID: "com.bytedance.inputmethod.doubaoime.pinyin", holdKey: "fn")]
    /// 实际使用的语音输入法：config.json 的 voiceIME 优先，否则取第一个已安装的
    static var voiceIME: VoiceIME? = knownIMEs.first { inputSource($0.sourceID) != nil }

    enum Engine: String { case ime, apple }

    private let queue = DispatchQueue(label: "backseat.mic")
    private let virtualMic = VirtualMic()
    private let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                                       channels: 1, interleaved: false)!
    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var sessionID: String?
    private var mode: Engine = .apple
    private var nextSeq = 0
    private var pendingChunks: [Int: Data] = [:]
    private var collected = Data()        // apple 模式：整段收集
    private var scheduledFrames: AVAudioFramePosition = 0
    /// 被语音输入法顶掉的原输入法，说完后切回去。只在主线程访问
    private var previousSource: TISInputSource?
    /// 第几轮说话（主线程访问）：延迟切回输入法前据此判断期间有没有开始新的一轮
    private var round = 0
    /// 正在收尾的轮数（queue 上访问）：新一轮开始前要等它归零
    private var finishing = 0
    /// 最近一次开麦时的焦点处理结果（给日志用）
    private(set) var focusNote = ""
    /// 最近一次取消的处理结果（给日志用）
    private(set) var cancelNote = ""
    /// 这一轮收到的音频统计（排查「说了没字」用）
    private var statChunks = 0
    private var statBytes = 0
    private var statPeak: Int16 = 0
    private var statLate = 0
    private(set) var audioNote = ""
    private var baseline: String?

    // MARK: - 环境检测

    static func inputSource(_ id: String) -> TISInputSource? {
        let filter = [kTISPropertyInputSourceID as String: id] as CFDictionary
        let list = TISCreateInputSourceList(filter, false)?.takeRetainedValue() as? [TISInputSource]
        return list?.first
    }

    /// 语音输入法的显示名（给日志用）
    static var imeName: String {
        guard let ime = voiceIME, let src = inputSource(ime.sourceID),
              let p = TISGetInputSourceProperty(src, kTISPropertyLocalizedName) else { return "语音输入法" }
        return Unmanaged<CFString>.fromOpaque(p).takeUnretainedValue() as String
    }

    /// 启动时记一行日志：语音走哪条路
    var setupNote: String {
        guard Self.voiceIME.flatMap({ Self.inputSource($0.sourceID) }) != nil else { return "语音：Mac 内置识别（没有装语音输入法）" }
        return virtualMic.deviceID != nil
            ? "语音：\(Self.imeName)，声音经「\(virtualMic.deviceName)」送给它"
            : "语音：Mac 内置识别。系统里没有 Backseat Mic 声卡，\(Self.imeName)听不到手机的声音；用安装包安装 Backseat 会一并装上"
    }

    var preferredEngine: Engine {
        virtualMic.deviceID != nil && Self.voiceIME.flatMap({ Self.inputSource($0.sourceID) }) != nil ? .ime : .apple
    }

    // MARK: - 会话

    /// 等上一轮收尾（松快捷键、停播放、还麦克风、退格 / 回车）做完，最多等 4 秒（手机开麦请求 5 秒超时）。
    /// 不等的话，上一轮晚到的松键和停播放会落在新一轮上，新一轮一个字也进不去
    func waitUntilIdle() async {
        for _ in 0..<80 {
            if queue.sync(execute: { finishing == 0 }) { return }
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    /// 开始一段说话。返回实际使用的引擎。
    func start(id: String) throws -> Engine {
        try queue.sync { () throws -> Engine in
            stopEngine()
            sessionID = id
            nextSeq = 0
            statChunks = 0; statBytes = 0; statPeak = 0; statLate = 0
            pendingChunks = [:]
            collected = Data()
            scheduledFrames = 0
            mode = preferredEngine
            guard mode == .ime, let ime = Self.voiceIME, let loopback = virtualMic.deviceID else { return mode }

            // 先把系统默认麦克风切过去，再建播放引擎。顺序不能反：
            // 默认设备一变，系统会让已经在跑的引擎重新配置，把它的输出设备重置回扬声器，声音就播不进回环声卡了
            virtualMic.takeOverInput()
            // 后面任何一步失败都要把默认麦克风还回去
            var started = false
            defer { if !started { virtualMic.releaseInput() } }
            let e = AVAudioEngine()
            // 把声音播给回环声卡，它的输入端就是输入法听到的麦克风
            try e.outputNode.auAudioUnit.setDeviceID(loopback)
            let p = AVAudioPlayerNode()
            e.attach(p)
            e.connect(p, to: e.mainMixerNode, format: format)
            try e.start()
            started = true
            p.play()
            engine = e
            player = p
            // 先垫 150ms 静音，让输入法开麦时不吃掉第一个字
            schedule(Data(count: Int(Self.sampleRate * 0.15) * 2))

            DispatchQueue.main.sync {
                focusNote = Focus.ensureInput()
                // 记下开说前输入框里的内容，取消时据此删掉这一轮说进去的字
                baseline = Focus.focusedText()
                round += 1
                Self.activateIME(ime, saving: &previousSource)
                Keyboard.hold(ime.holdKey, down: true)
            }
            return mode
        }
    }

    /// 收到一段 PCM（16kHz 单声道 Int16 小端）。按 seq 排序后按顺序播放。
    func append(id: String, seq: Int, pcm: Data) {
        queue.async {
            guard id == self.sessionID else { self.statLate += 1; return }
            self.statChunks += 1
            self.statBytes += pcm.count
            pcm.withUnsafeBytes { raw in
                for v in raw.bindMemory(to: Int16.self) {
                    let a = Int16(littleEndian: v)
                    let m = a == .min ? Int16.max : abs(a)
                    if m > self.statPeak { self.statPeak = m }
                }
            }
            self.pendingChunks[seq] = pcm
            while let chunk = self.pendingChunks.removeValue(forKey: self.nextSeq) {
                self.nextSeq += 1
                if self.mode == .ime { self.schedule(chunk) } else { self.collected.append(chunk) }
            }
        }
    }

    /// 结束说话。ime 模式：等音频播完再松开快捷键，由输入法上屏；apple 模式：转写后粘贴。
    /// 返回识别出的文字（ime 模式拿不到文字，返回 nil）。
    func finish(id: String, lastSeq: Int, submit: Bool, cancel: Bool) async -> (Engine, String?) {
        queue.sync { finishing += 1 }
        defer { queue.sync { finishing -= 1 } }
        // 等迟到的分片（最多 1.5 秒）
        for _ in 0..<30 {
            let done = queue.sync { nextSeq > lastSeq || sessionID != id }
            if done { break }
            try? await Task.sleep(for: .milliseconds(50))
        }
        audioNote = queue.sync {
            let secs = Double(statBytes) / 2 / Self.sampleRate
            let peakDb = statPeak > 0 ? 20 * log10(Double(statPeak) / 32768) : -120
            var note = String(format: "收到 %d 段 %.1f 秒，最大音量 %.0f dB", statChunks, secs, peakDb)
            if statLate > 0 { note += "，\(statLate) 段对不上会话被丢弃" }
            if statChunks == 0 { note += "（没收到任何音频）" } else if peakDb < -45 { note += "（几乎是静音）" }
            return note
        }
        let blocked = await MainActor.run { Keyboard.blockedReleases }
        if blocked > 0 { audioNote += "，拦下 \(blocked) 次外部对快捷键的松开" }
        // 这时快捷键还按着，输入法如果在用虚拟麦克风，设备应该正被占用
        if mode == .ime, !virtualMic.isInUse {
            audioNote += "；输入法没有从 \(virtualMic.deviceName) 收音，请把输入法的麦克风设成「自动检测 / 跟随系统」"
        }
        let (m, pcm, remaining) = queue.sync { () -> (Engine, Data, Double) in
            let played = player?.lastRenderTime.flatMap { player?.playerTime(forNodeTime: $0)?.sampleTime } ?? 0
            let remain = Double(max(0, scheduledFrames - played)) / Self.sampleRate
            return (mode, collected, remain)
        }

        if m == .ime, let ime = Self.voiceIME {
            if !cancel {
                // 尾部再补 300ms 静音，确保最后一个字被输入法听完整
                queue.sync { schedule(Data(count: Int(Self.sampleRate * 0.3) * 2)) }
                try? await Task.sleep(for: .seconds(remaining + 0.35))
            }
            // 新一轮等收尾超时后已经开始了：快捷键、播放和麦克风都归它，这一轮不能再动
            guard queue.sync(execute: { sessionID == id }) else { return (.ime, nil) }
            await MainActor.run { Keyboard.hold(ime.holdKey, down: false) }
            queue.sync { stopEngine() }
            virtualMic.releaseInput()
            if cancel {
                // 输入法松开后还会把识别结果补上屏，等它写完再按字数退格删掉
                // （不能按 Esc：Claude 里 Esc 会中断正在运行的任务）
                try? await Task.sleep(for: .seconds(0.9))
                cancelNote = await MainActor.run { () -> String in
                    guard let before = baseline, let after = Focus.focusedText() else {
                        return "读不到输入框内容，未删除"
                    }
                    // 有的输入框（Claude）空的时候读出来是一个换行符，不能算成原有的字
                    let n = after.count - (before == "\n" ? 0 : before.count)
                    guard n > 0 else { return "这一轮没有输入文字" }
                    for _ in 0..<n { _ = Keyboard.press("backspace") }
                    return "已删除这一轮的 \(n) 个字"
                }
            } else if submit {
                // 输入法松开后还要一点时间出最终结果
                try? await Task.sleep(for: .seconds(1.2))
                await MainActor.run { _ = Keyboard.press("enter") }
            }
            restoreSource()
            return (.ime, nil)
        }

        queue.sync { sessionID = nil }
        guard !cancel, pcm.count > 3200 else { return (.apple, nil) }
        let text = try? await Transcriber.transcribe(Self.wav(pcm), ext: "wav")
        guard let text, !text.isEmpty else { return (.apple, "") }
        await MainActor.run { Focus.ensureInput(); Keyboard.paste(text, submit: submit) }
        return (.apple, text)
    }

    // MARK: - 内部

    private func schedule(_ pcm: Data) {
        guard let player else { return }
        let frames = pcm.count / 2
        guard frames > 0, let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))
        else { return }
        buf.frameLength = AVAudioFrameCount(frames)
        let out = buf.floatChannelData![0]
        pcm.withUnsafeBytes { raw in
            let src = raw.bindMemory(to: Int16.self)
            for i in 0..<frames { out[i] = Float(Int16(littleEndian: src[i])) / 32768 }
        }
        player.scheduleBuffer(buf)
        scheduledFrames += AVAudioFramePosition(frames)
    }

    private func stopEngine() {
        player?.stop()
        engine?.stop()
        player = nil
        engine = nil
        sessionID = nil
    }

    private static func activateIME(_ ime: VoiceIME, saving prev: inout TISInputSource?) {
        guard let target = inputSource(ime.sourceID) else { return }
        let cur = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
        let curID = TISGetInputSourceProperty(cur, kTISPropertyInputSourceID)
            .map { Unmanaged<CFString>.fromOpaque($0).takeUnretainedValue() as String }
        // 已经是语音输入法时不动 prev：上一轮还没来得及切回的原输入法留给这一轮说完再切
        if curID != ime.sourceID {
            prev = cur
            TISSelectInputSource(target)
        }
    }

    private func restoreSource() {
        DispatchQueue.main.async {
            let r = self.round
            // 立即切回会打断输入法上屏，等它出完最终结果再切；
            // 期间开始了新的一轮就不切（否则会在新一轮说话中途把语音输入法切走），由那一轮说完再切
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                guard r == self.round, let prev = self.previousSource else { return }
                self.previousSource = nil
                TISSelectInputSource(prev)
            }
        }
    }

    /// 给 Int16 PCM 加 WAV 头，交给内置识别
    static func wav(_ pcm: Data) -> Data {
        var d = Data()
        func u32(_ v: UInt32) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 4)) }
        func u16(_ v: UInt16) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 2)) }
        let rate = UInt32(sampleRate)
        d.append(Data("RIFF".utf8)); u32(36 + UInt32(pcm.count)); d.append(Data("WAVE".utf8))
        d.append(Data("fmt ".utf8)); u32(16); u16(1); u16(1); u32(rate); u32(rate * 2); u16(2); u16(16)
        d.append(Data("data".utf8)); u32(UInt32(pcm.count)); d.append(pcm)
        return d
    }
}
