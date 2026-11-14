import CoreAudio
import Foundation

/// 自带的虚拟麦克风，不需要安装任何音频驱动。
/// 用系统的进程音频 tap 截住本进程播放的声音（截住后不再从扬声器出声），
/// 再包成一个所有 App 可见的输入设备「Backseat Mic」，语音输入法从它收音。
final class VirtualMic {
    static let name = "Backseat Mic"
    static let uid = "dev.backseat.mic"

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private(set) var deviceID: AudioDeviceID?
    private var savedInput: AudioDeviceID?

    private static let system = AudioObjectID(kAudioObjectSystemObject)

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    /// 删掉系统里已有的「Backseat Mic」。进程异常退出时设备会残留，启动和退出时都清一次。
    static func removeDevice() {
        var addr = address(kAudioHardwarePropertyTranslateUIDToDevice)
        var uid = Self.uid as CFString
        var device = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &addr, UInt32(MemoryLayout<CFString>.size), &uid,
                                         &size, &device) == noErr,
              device != kAudioObjectUnknown else { return }
        AudioHardwareDestroyAggregateDevice(device)
    }

    /// 创建虚拟麦克风。失败时 deviceID 为 nil，调用方退回内置识别。
    init() {
        Self.removeDevice()
        var pid = getpid()
        var addr = Self.address(kAudioHardwarePropertyTranslatePIDToProcessObject)
        var process = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(Self.system, &addr, UInt32(MemoryLayout<pid_t>.size), &pid,
                                         &size, &process) == noErr,
              process != kAudioObjectUnknown else { return }

        let tap = CATapDescription(stereoMixdownOfProcesses: [process])
        tap.uuid = UUID()
        tap.name = Self.name
        tap.muteBehavior = .muted
        tap.isPrivate = false
        guard AudioHardwareCreateProcessTap(tap, &tapID) == noErr else { return }

        let desc: [String: Any] = [
            kAudioAggregateDeviceNameKey: Self.name,
            kAudioAggregateDeviceUIDKey: Self.uid,
            kAudioAggregateDeviceIsPrivateKey: false,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: tap.uuid.uuidString,
                                               kAudioSubTapDriftCompensationKey: true]],
        ]
        var device = AudioObjectID(kAudioObjectUnknown)
        guard AudioHardwareCreateAggregateDevice(desc as CFDictionary, &device) == noErr else {
            AudioHardwareDestroyProcessTap(tapID)
            return
        }
        deviceID = device
    }

    /// 说话期间把系统默认输入切到虚拟麦克风，这样输入法的麦克风选「跟随系统」就能用。
    func takeOverInput() {
        guard let deviceID, savedInput == nil else { return }
        var addr = Self.address(kAudioHardwarePropertyDefaultInputDevice)
        var current = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        AudioObjectGetPropertyData(Self.system, &addr, 0, nil, &size, &current)
        guard current != deviceID else { return }
        var target = deviceID
        if AudioObjectSetPropertyData(Self.system, &addr, 0, nil, size, &target) == noErr {
            savedInput = current
        }
    }

    /// 说完后把系统默认输入还原
    func releaseInput() {
        guard var previous = savedInput else { return }
        savedInput = nil
        var addr = Self.address(kAudioHardwarePropertyDefaultInputDevice)
        AudioObjectSetPropertyData(Self.system, &addr, 0, nil, UInt32(MemoryLayout<AudioDeviceID>.size), &previous)
    }
}
