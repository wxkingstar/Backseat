import Foundation

/// 一次按住说话的上传会话。
/// 录音一按下就开始，Mac 端 start 返回前产生的分片先缓存，start 成功后按顺序补发。
actor MicSession {
    let id = UUID().uuidString
    private var opened = false
    private var failed = false
    private var buffered: [(Int, Data)] = []
    /// 这一轮的完整录音。连不上 Mac 时，手机用它存进灵感收件箱
    private(set) var recorded = Data()
    private var inflight: [Task<Void, Never>] = []
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private let client = BridgeClient.shared

    func push(_ seq: Int, _ data: Data) {
        recorded.append(data)
        guard !failed else { return }
        if opened { send(seq, data) } else { buffered.append((seq, data)) }
    }

    func open() {
        opened = true
        for (s, d) in buffered { send(s, d) }
        buffered = []
        resume()
    }

    func fail() {
        failed = true
        buffered = []
        resume()
    }

    /// 等 start 有结果、且所有分片都发出去。返回 start 是否成功。
    func drain() async -> Bool {
        if !opened && !failed {
            await withCheckedContinuation { waiters.append($0) }
        }
        for t in inflight { await t.value }
        inflight = []
        return opened && !failed
    }

    private func send(_ seq: Int, _ data: Data) {
        let id = self.id
        let client = self.client
        inflight.append(Task { try? await client.micChunk(id: id, seq: seq, pcm: data) })
    }

    private func resume() {
        waiters.forEach { $0.resume() }
        waiters = []
    }
}
