import CoreAudio
import Foundation
import os

/// 把 16kHz 单声道 Int16 PCM 直接写进回环声卡（Backseat Mic）的输出端，输入法从它的输入端收音。
/// 不用 AVAudioEngine：引擎把输出设到非默认设备、启动后约 0.2 秒，系统会发一次配置变更把引擎停掉，
/// 之后排进去的声音一个都播不出去（第一轮碰巧赶在通知前播上了，后面几轮就全没声）。
/// 直接挂 IOProc 不受默认设备和配置变更的影响。
final class LoopbackPlayer: @unchecked Sendable {
    private struct State {
        var samples: [Float] = []   // 设备采样率的单声道样本
        var read = 0
        var prev: Float = 0         // 上一个输入样本，线性插值用
        var phase: Double = 0
    }

    private let device: AudioDeviceID
    private let rate: Double
    private let state = OSAllocatedUnfairLock(initialState: State())
    private var procID: AudioDeviceIOProcID?

    init(device: AudioDeviceID) {
        self.device = device
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var r: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &r)
        rate = r > 0 ? r : 48_000
    }

    func start() throws {
        var id: AudioDeviceIOProcID?
        let st = AudioDeviceCreateIOProcIDWithBlock(&id, device, nil) { [state] _, _, _, output, _ in
            let list = UnsafeMutableAudioBufferListPointer(output)
            state.withLock { s in
                for buf in list {
                    guard let data = buf.mData else { continue }
                    let ch = max(1, Int(buf.mNumberChannels))
                    let out = data.assumingMemoryBound(to: Float.self)
                    let frames = Int(buf.mDataByteSize) / (4 * ch)
                    for f in 0..<frames {
                        var v: Float = 0
                        if s.read < s.samples.count { v = s.samples[s.read]; s.read += 1 }
                        for c in 0..<ch { out[f * ch + c] = v }
                    }
                }
            }
        }
        guard st == noErr, let id else { throw NSError(domain: "loopback", code: Int(st)) }
        guard AudioDeviceStart(device, id) == noErr else {
            AudioDeviceDestroyIOProcID(device, id)
            throw NSError(domain: "loopback", code: 1, userInfo: [NSLocalizedDescriptionKey: "回环声卡启动失败"])
        }
        procID = id
    }

    func stop() {
        guard let id = procID else { return }
        procID = nil
        AudioDeviceStop(device, id)
        AudioDeviceDestroyIOProcID(device, id)
    }

    /// 排一段 16kHz 单声道 Int16 小端 PCM，线性插值到设备采样率
    func schedule(_ pcm: Data) {
        let step = 16_000 / rate
        state.withLock { s in
            if s.read > 0 {
                s.samples.removeFirst(s.read)
                s.read = 0
            }
            pcm.withUnsafeBytes { raw in
                for v in raw.bindMemory(to: Int16.self) {
                    let x = Float(Int16(littleEndian: v)) / 32768
                    while s.phase < 1 {
                        s.samples.append(s.prev + (x - s.prev) * Float(s.phase))
                        s.phase += step
                    }
                    s.phase -= 1
                    s.prev = x
                }
            }
        }
    }

    /// 还没播出去的秒数
    var remaining: Double {
        state.withLock { Double($0.samples.count - $0.read) / rate }
    }
}
