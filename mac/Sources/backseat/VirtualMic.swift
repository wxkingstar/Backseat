import CoreAudio
import Foundation

/// 回环声卡：往它的输出端播声音，它的输入端原样送出来，语音输入法把它当麦克风收音。
/// 用随 Backseat 一起安装的「Backseat Mic」驱动（源码在 mac/Driver）；没装的话，系统里有 BlackHole 也能用。
/// 说话期间把它设成系统默认麦克风，说完还原，所以输入法的麦克风保持「自动检测 / 跟随系统」就行。
///
/// 为什么非要装驱动：系统也可以不装驱动造一个虚拟麦克风（进程音频 tap），以前的版本就是这么做的。
/// 但它不能当默认麦克风，而且从它收音的程序自己要有「系统音频录制」权限，
/// 没声明这项权限的程序（豆包输入法就是）读到的全是静音，所以行不通。
final class VirtualMic {
    private static let system = AudioObjectID(kAudioObjectSystemObject)

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    private static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String {
        var addr = address(selector)
        var value: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        return AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value) == noErr ? value as String : ""
    }

    private static func objects(_ selector: AudioObjectPropertySelector) -> [AudioObjectID] {
        var addr = address(selector)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var list = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &list) == noErr else { return [] }
        return list
    }

    /// 清掉免驱动时代留下的东西：聚合设备和进程音频 tap（当时的进程被直接结束时它们不会自己消失）
    static func removeLegacy() {
        for device in objects(kAudioHardwarePropertyDevices) where string(device, kAudioDevicePropertyDeviceUID) == "dev.backseat.mic" {
            AudioHardwareDestroyAggregateDevice(device)
        }
        for tap in objects(kAudioHardwarePropertyTapList)
        where ["Backseat Mic", "VibeWatch Mic"].contains(string(tap, kAudioObjectPropertyName)) {
            AudioHardwareDestroyProcessTap(tap)
        }
    }

    /// 回环声卡；系统里没有就是 nil，这时退回 Mac 内置识别
    let deviceID: AudioDeviceID?
    /// 它叫什么（记日志用）
    let deviceName: String
    private var savedInput: AudioDeviceID?

    init() {
        Self.removeLegacy()
        let uids = Self.objects(kAudioHardwarePropertyDevices).map { ($0, Self.string($0, kAudioDevicePropertyDeviceUID)) }
        // 自己的驱动优先，其次是 BlackHole
        let found = uids.first { $0.1 == "BackseatMic_UID" } ?? uids.first { $0.1.hasPrefix("BlackHole") }
        deviceID = found?.0
        deviceName = found.map { Self.string($0.0, kAudioObjectPropertyName) } ?? ""
    }

    /// 说话期间把系统默认输入切到回环声卡。返回切成了没有
    @discardableResult
    func takeOverInput() -> Bool {
        guard let deviceID else { return false }
        var addr = Self.address(kAudioHardwarePropertyDefaultInputDevice)
        var current = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        AudioObjectGetPropertyData(Self.system, &addr, 0, nil, &size, &current)
        guard current != deviceID else { return true }
        var target = deviceID
        guard AudioObjectSetPropertyData(Self.system, &addr, 0, nil, size, &target) == noErr else { return false }
        var now = AudioDeviceID(kAudioObjectUnknown)
        AudioObjectGetPropertyData(Self.system, &addr, 0, nil, &size, &now)
        guard now == deviceID else { return false }
        if savedInput == nil { savedInput = current }
        return true
    }

    /// 说完后把系统默认输入还原
    func releaseInput() {
        guard var previous = savedInput else { return }
        savedInput = nil
        var addr = Self.address(kAudioHardwarePropertyDefaultInputDevice)
        AudioObjectSetPropertyData(Self.system, &addr, 0, nil, UInt32(MemoryLayout<AudioDeviceID>.size), &previous)
    }

    /// 有没有程序正在从回环声卡收音（输入法开麦后为 true）
    var isInUse: Bool {
        guard let deviceID else { return false }
        var addr = Self.address(kAudioDevicePropertyDeviceIsRunningSomewhere)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, &value)
        return value != 0
    }
}
