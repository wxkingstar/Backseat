import AVFoundation
import Foundation
import Observation

/// 按住说话：手表麦克风实时采集，转成 16kHz 单声道 Int16，每 200ms 推一段给 Mac。
/// Mac 端把声音灌进虚拟麦克风给语音输入法识别（或整段交给内置识别）。
@MainActor @Observable
final class Recorder {
    private(set) var level: Double = 0          // 0...1，用来画声波
    private(set) var elapsed: TimeInterval = 0

    static let maxDuration: TimeInterval = 60

    private var formatNote = ""
    /// 排查用：麦克风权限、输入格式、转换前的最大音量
    var diagnostics: String {
        let perm: String
        switch permission {
        case .granted: perm = "已授权"
        case .denied: perm = "被拒绝"
        default: perm = "未决定"
        }
        let raw = pipe.rawPeak
        let db = raw > 0 ? 20 * log10(Double(raw)) : -120
        let route = AVAudioSession.sharedInstance().currentRoute.inputs.first
        return "麦克风\(perm) 采集 \(formatNote) 原始最大音量 \(Int(db))dB 设备 \(route?.portName ?? "无")"
    }

    private var engine: AVAudioEngine?
    private var startedAt = Date()
    private var clock: Task<Void, Never>?
    private let pipe = ChunkPipe()

    var permission: AVAudioApplication.recordPermission { AVAudioApplication.shared.recordPermission }

    func requestPermission() async -> Bool {
        await AVAudioApplication.requestRecordPermission()
    }

    /// 开始采集。onChunk 在后台线程回调 (seq, pcm)。
    /// background：由快捷操作在后台触发（手机侧键、控制中心）。
    func start(background: Bool = false, onChunk: @escaping @Sendable (Int, Data) -> Void) throws {
        // 上一次的采集没收干净就先停掉，避免重复装 tap 触发系统断言崩溃
        if engine != nil || recording { _ = stop() }
        try pipe.prepare(onChunk: onChunk) { [weak self] lvl in
            Task { @MainActor in self?.level = lvl }
        }
        #if os(iOS)
        if background {
            // App 在后台时 AVCaptureSession 拿不到麦克风（没有输入设备，录到的全是静音）。
            // 后台录音要自己把音频会话激活成录音，再用 AVAudioEngine 采集
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .default)
            try session.setActive(true)
            try startEngine()
        } else {
            // 前台用 AVCaptureSession 采集：部分 iPhone（如 iPhone Duo）上 AVAudioEngine 的输入
            // 授权正常、不报错，但给的全是 0（Apple 论坛有多起同类报告，无官方修复）
            // 启动麦克风要几十到上百毫秒，放到后台线程做，按下的瞬间界面先响应
            recording = true
            capQueue.async { [capture] in try? capture.start() }
            formatNote = "AVCapture"
        }
        #else
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .default)
        try session.setActive(true)
        try startEngine()
        #endif
        startedAt = Date()
        elapsed = 0
        clock = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                guard let self else { return }
                self.elapsed = Date().timeIntervalSince(self.startedAt)
            }
        }
    }

    @ObservationIgnored private var recording = false
    #if os(iOS)
    @ObservationIgnored private lazy var capture = CaptureInput(pipe: pipe)
    @ObservationIgnored private let capQueue = DispatchQueue(label: "backseat.capture.control", qos: .userInteractive)

    /// 提前把采集会话配置好（不开麦克风），按下说话时只需要启动，响应更快
    func prewarm() {
        guard permission == .granted else { return }
        capQueue.async { [capture] in try? capture.configure() }
    }
    #endif

    /// 手表：AVAudioEngine 采集接到 pipe 上
    private func startEngine() throws {
        let e = AVAudioEngine()
        let input = e.inputNode
        let inFmt = input.outputFormat(forBus: 0)
        // 麦克风还没就绪时格式是 0Hz，直接装 tap 会被系统 abort
        guard inFmt.sampleRate > 0, inFmt.channelCount > 0 else {
            throw NSError(domain: "rec", code: 3, userInfo: [NSLocalizedDescriptionKey: "麦克风还没就绪"])
        }
        formatNote = "\(Int(inFmt.sampleRate))Hz \(inFmt.channelCount)ch"
        try pipe.retarget(from: inFmt)
        input.installTap(onBus: 0, bufferSize: 2048, format: inFmt) { [pipe] buf, _ in
            pipe.feed(buf)
        }
        e.prepare()
        try e.start()
        engine = e
    }

    /// 停止采集，推出最后一段，返回最后一段的 seq（没有任何数据时为 -1）
    func stop() -> Int {
        clock?.cancel()
        clock = nil
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        #if os(iOS)
        if recording { capQueue.async { [capture] in capture.stop() } }
        #endif
        recording = false
        level = 0
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        return pipe.flush()
    }
}

/// 音频线程上的转换与分片（不在主线程上做）
final class ChunkPipe: @unchecked Sendable {
    private let lock = NSLock()
    private var converter: AVAudioConverter?
    private let outFmt = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000,
                                       channels: 1, interleaved: true)!
    private var buffer = Data()
    private var seq = 0
    private var onChunk: (@Sendable (Int, Data) -> Void)?
    private var onLevel: ((Double) -> Void)?
    private let chunkBytes = 6_400 // 200ms
    /// 转换前的最大振幅（0...1），排查静音用
    private(set) var rawPeak: Float = 0
    /// prepare 之后、flush 之前才接收数据（采集会话会复用，停下后迟到的数据要丢掉）
    private var active = false

    /// 新的一轮：清空缓存和序号
    func prepare(onChunk: @escaping @Sendable (Int, Data) -> Void, onLevel: @escaping (Double) -> Void) throws {
        lock.lock(); defer { lock.unlock() }
        rawPeak = 0
        buffer = Data()
        seq = 0
        active = true
        self.onChunk = onChunk
        self.onLevel = onLevel
    }

    /// 接到新的输入格式（首次或换麦克风后），序号和缓存保留
    func retarget(from inFmt: AVAudioFormat) throws {
        lock.lock(); defer { lock.unlock() }
        guard let c = AVAudioConverter(from: inFmt, to: outFmt) else { throw NSError(domain: "rec", code: 2) }
        converter = c
    }

    func feed(_ buf: AVAudioPCMBuffer) {
        lock.lock(); defer { lock.unlock() }
        guard active, let converter else { return }
        if let ch = buf.floatChannelData?[0] {
            for i in 0..<Int(buf.frameLength) { rawPeak = max(rawPeak, abs(ch[i])) }
        } else if let ch = buf.int16ChannelData?[0] {
            let stride = buf.format.isInterleaved ? Int(buf.format.channelCount) : 1
            for i in 0..<Int(buf.frameLength) { rawPeak = max(rawPeak, abs(Float(ch[i * stride])) / 32768) }
        }
        let ratio = outFmt.sampleRate / buf.format.sampleRate
        let cap = AVAudioFrameCount(Double(buf.frameLength) * ratio) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: outFmt, frameCapacity: cap) else { return }
        var fed = false
        var err: NSError?
        converter.convert(to: out, error: &err) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true
            status.pointee = .haveData
            return buf
        }
        let n = Int(out.frameLength)
        guard n > 0, let p = out.int16ChannelData?[0] else { return }

        // 音量：RMS 转 dB，-50dB 以下当静音
        var sum = 0.0
        for i in 0..<n { let v = Double(p[i]) / 32768; sum += v * v }
        let db = 10 * log10(max(sum / Double(n), 1e-10))
        onLevel?(max(0, min(1, (db + 50) / 50)))

        buffer.append(Data(bytes: p, count: n * 2))
        while buffer.count >= chunkBytes {
            emit(buffer.prefix(chunkBytes))
            buffer.removeFirst(chunkBytes)
        }
    }

    func flush() -> Int {
        lock.lock(); defer { lock.unlock() }
        if !buffer.isEmpty { emit(buffer); buffer = Data() }
        active = false
        return seq - 1
    }

    private func emit(_ d: Data) {
        let s = seq
        seq += 1
        onChunk?(s, Data(d))
    }
}

#if os(iOS)
/// iPhone 采集：AVCaptureSession + AVCaptureAudioDataOutput，拿到的样本转成 PCM 交给 pipe
final class CaptureInput: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let session = AVCaptureSession()
    private let output = AVCaptureAudioDataOutput()
    private let queue = DispatchQueue(label: "backseat.capture")
    private let pipe: ChunkPipe
    private var lastFormat: AVAudioFormat?

    init(pipe: ChunkPipe) { self.pipe = pipe }

    private var configured = false

    func start() throws {
        try configure()
        session.startRunning()
    }

    /// 只配置、不启动（不会亮麦克风指示灯）。可重复调用
    func configure() throws {
        guard !configured else { return }
        guard let mic = AVCaptureDevice.default(for: .audio) else {
            throw NSError(domain: "rec", code: 4, userInfo: [NSLocalizedDescriptionKey: "找不到麦克风"])
        }
        let input = try AVCaptureDeviceInput(device: mic)
        session.beginConfiguration()
        guard session.canAddInput(input), session.canAddOutput(output) else {
            session.commitConfiguration()
            throw NSError(domain: "rec", code: 5, userInfo: [NSLocalizedDescriptionKey: "麦克风被占用"])
        }
        session.addInput(input)
        session.addOutput(output)
        output.setSampleBufferDelegate(self, queue: queue)
        session.commitConfiguration()
        configured = true
    }

    func stop() {
        session.stopRunning()
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let desc = CMSampleBufferGetFormatDescription(sampleBuffer) else { return }
        let fmt = AVAudioFormat(cmAudioFormatDescription: desc)
        let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard frames > 0, let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: frames) else { return }
        buf.frameLength = frames
        let st = CMSampleBufferCopyPCMDataIntoAudioBufferList(sampleBuffer, at: 0, frameCount: Int32(frames),
                                                              into: buf.mutableAudioBufferList)
        guard st == noErr else { return }
        if lastFormat != fmt {
            lastFormat = fmt
            try? pipe.retarget(from: fmt)
        }
        pipe.feed(buf)
    }
}
#endif
