// Backseat Mic：一块回环声卡（Audio Server Plug-in）。
//
// 它有一个输出端和一个输入端：播给输出端的声音，从输入端原样读出来。
// Backseat 把手机 / 手表传来的声音播给它，语音输入法把它当麦克风收音。
// 它是系统级驱动，装在 /Library/Audio/Plug-Ins/HAL/，可以当系统默认麦克风，任何程序都能从它收音
// （免驱动的进程音频 tap 做不到这两点，见 README「语音输入」）。
//
// 结构按 Apple 的 Audio Server Plug-in 示例驱动的常规写法：一个插件对象、一个设备、一进一出两条流。
// 只支持一种格式：48 kHz、双声道、32 位浮点。固定一种格式，就没有「切换采样率时两端对不上」这类问题。

#include <CoreAudio/AudioServerPlugIn.h>
#include <CoreFoundation/CoreFoundation.h>
#include <mach/mach_time.h>
#include <os/lock.h>
#include <stdatomic.h>
#include <string.h>

// MARK: - 常量

#define kPlugIn_BundleID        "dev.backseat.mic-driver"
#define kDevice_Name            "Backseat Mic"
#define kDevice_Manufacturer    "Backseat"
#define kDevice_UID             "BackseatMic_UID"
#define kDevice_ModelUID        "BackseatMic_ModelUID"

enum {
    kObjectID_PlugIn        = kAudioObjectPlugInObject,
    kObjectID_Device        = 2,
    kObjectID_Stream_Input  = 3,
    kObjectID_Stream_Output = 4,
};

#define kSampleRate         48000.0
#define kChannels           2
#define kBytesPerFrame      (kChannels * sizeof(Float32))
// 时间戳周期：每过这么多帧报一次「零点」。和示例驱动一样取 16384
#define kZeroTimeStampPeriod 16384
// 回环缓冲区长度（帧）。要比任何一次读写、以及读写两端的时间差都长得多；65536 帧约 1.4 秒
#define kRingFrames         65536

// MARK: - 状态

static AudioServerPlugInHostRef gHost = NULL;
static atomic_uint gRefCount = 1;

static os_unfair_lock gStateLock = OS_UNFAIR_LOCK_INIT;
static UInt64  gIOClients = 0;              // 有几个程序在做 IO
static Float64 gHostTicksPerFrame = 0;
static UInt64  gAnchorHostTime = 0;
static UInt64  gNumberTimeStamps = 0;
static bool    gInputActive = true;
static bool    gOutputActive = true;

// 回环缓冲区：按设备的采样时间取模存放。gWriteEnd 是已经写到的采样时间（不含），
// 只有 [gWriteEnd - kRingFrames, gWriteEnd) 这段是有效数据，其余读出来都是静音
static os_unfair_lock gRingLock = OS_UNFAIR_LOCK_INIT;
static Float32 gRing[kRingFrames * kChannels];
static SInt64  gWriteEnd = 0;

// MARK: - 接口声明

static HRESULT  Q_QueryInterface(void *inDriver, REFIID inUUID, LPVOID *outInterface);
static ULONG    Q_AddRef(void *inDriver);
static ULONG    Q_Release(void *inDriver);
static OSStatus D_Initialize(AudioServerPlugInDriverRef inDriver, AudioServerPlugInHostRef inHost);
static OSStatus D_CreateDevice(AudioServerPlugInDriverRef, CFDictionaryRef, const AudioServerPlugInClientInfo *, AudioObjectID *);
static OSStatus D_DestroyDevice(AudioServerPlugInDriverRef, AudioObjectID);
static OSStatus D_AddDeviceClient(AudioServerPlugInDriverRef, AudioObjectID, const AudioServerPlugInClientInfo *);
static OSStatus D_RemoveDeviceClient(AudioServerPlugInDriverRef, AudioObjectID, const AudioServerPlugInClientInfo *);
static OSStatus D_PerformDeviceConfigurationChange(AudioServerPlugInDriverRef, AudioObjectID, UInt64, void *);
static OSStatus D_AbortDeviceConfigurationChange(AudioServerPlugInDriverRef, AudioObjectID, UInt64, void *);
static Boolean  D_HasProperty(AudioServerPlugInDriverRef, AudioObjectID, pid_t, const AudioObjectPropertyAddress *);
static OSStatus D_IsPropertySettable(AudioServerPlugInDriverRef, AudioObjectID, pid_t, const AudioObjectPropertyAddress *, Boolean *);
static OSStatus D_GetPropertyDataSize(AudioServerPlugInDriverRef, AudioObjectID, pid_t, const AudioObjectPropertyAddress *, UInt32, const void *, UInt32 *);
static OSStatus D_GetPropertyData(AudioServerPlugInDriverRef, AudioObjectID, pid_t, const AudioObjectPropertyAddress *, UInt32, const void *, UInt32, UInt32 *, void *);
static OSStatus D_SetPropertyData(AudioServerPlugInDriverRef, AudioObjectID, pid_t, const AudioObjectPropertyAddress *, UInt32, const void *, UInt32, const void *);
static OSStatus D_StartIO(AudioServerPlugInDriverRef, AudioObjectID, UInt32);
static OSStatus D_StopIO(AudioServerPlugInDriverRef, AudioObjectID, UInt32);
static OSStatus D_GetZeroTimeStamp(AudioServerPlugInDriverRef, AudioObjectID, UInt32, Float64 *, UInt64 *, UInt64 *);
static OSStatus D_WillDoIOOperation(AudioServerPlugInDriverRef, AudioObjectID, UInt32, UInt32, Boolean *, Boolean *);
static OSStatus D_BeginIOOperation(AudioServerPlugInDriverRef, AudioObjectID, UInt32, UInt32, UInt32, const AudioServerPlugInIOCycleInfo *);
static OSStatus D_DoIOOperation(AudioServerPlugInDriverRef, AudioObjectID, AudioObjectID, UInt32, UInt32, UInt32, const AudioServerPlugInIOCycleInfo *, void *, void *);
static OSStatus D_EndIOOperation(AudioServerPlugInDriverRef, AudioObjectID, UInt32, UInt32, UInt32, const AudioServerPlugInIOCycleInfo *);

static AudioServerPlugInDriverInterface gInterface = {
    NULL,
    Q_QueryInterface, Q_AddRef, Q_Release,
    D_Initialize, D_CreateDevice, D_DestroyDevice,
    D_AddDeviceClient, D_RemoveDeviceClient,
    D_PerformDeviceConfigurationChange, D_AbortDeviceConfigurationChange,
    D_HasProperty, D_IsPropertySettable, D_GetPropertyDataSize, D_GetPropertyData, D_SetPropertyData,
    D_StartIO, D_StopIO, D_GetZeroTimeStamp,
    D_WillDoIOOperation, D_BeginIOOperation, D_DoIOOperation, D_EndIOOperation,
};
static AudioServerPlugInDriverInterface *gInterfacePtr = &gInterface;
static AudioServerPlugInDriverRef gDriverRef = &gInterfacePtr;

// MARK: - 工厂

// Info.plist 的 CFPlugInFactories 指向这个函数
void *BackseatMic_Create(CFAllocatorRef inAllocator, CFUUIDRef inRequestedTypeUUID) {
    (void)inAllocator;
    return CFEqual(inRequestedTypeUUID, kAudioServerPlugInTypeUUID) ? gDriverRef : NULL;
}

// MARK: - COM 样板

static HRESULT Q_QueryInterface(void *inDriver, REFIID inUUID, LPVOID *outInterface) {
    if (inDriver != gDriverRef || outInterface == NULL) return kAudioHardwareBadObjectError;
    CFUUIDRef requested = CFUUIDCreateFromUUIDBytes(NULL, inUUID);
    HRESULT result = E_NOINTERFACE;
    if (requested != NULL) {
        if (CFEqual(requested, IUnknownUUID) || CFEqual(requested, kAudioServerPlugInDriverInterfaceUUID)) {
            atomic_fetch_add(&gRefCount, 1);
            *outInterface = gDriverRef;
            result = S_OK;
        }
        CFRelease(requested);
    }
    return result;
}

static ULONG Q_AddRef(void *inDriver) {
    if (inDriver != gDriverRef) return 0;
    return atomic_fetch_add(&gRefCount, 1) + 1;
}

static ULONG Q_Release(void *inDriver) {
    if (inDriver != gDriverRef) return 0;
    UInt32 current = atomic_load(&gRefCount);
    // 驱动是静态的，不会真的释放；计数只是不让它减到 0 以下
    while (current > 0 && !atomic_compare_exchange_weak(&gRefCount, &current, current - 1)) {}
    return current > 0 ? current - 1 : 0;
}

// MARK: - 基本操作

static OSStatus D_Initialize(AudioServerPlugInDriverRef inDriver, AudioServerPlugInHostRef inHost) {
    if (inDriver != gDriverRef) return kAudioHardwareBadObjectError;
    gHost = inHost;
    struct mach_timebase_info timebase;
    mach_timebase_info(&timebase);
    Float64 hostClockFrequency = ((Float64)timebase.denom / (Float64)timebase.numer) * 1000000000.0;
    gHostTicksPerFrame = hostClockFrequency / kSampleRate;
    return kAudioHardwareNoError;
}

static OSStatus D_CreateDevice(AudioServerPlugInDriverRef d, CFDictionaryRef desc, const AudioServerPlugInClientInfo *c, AudioObjectID *out) {
    (void)d; (void)desc; (void)c; (void)out;
    return kAudioHardwareUnsupportedOperationError;
}

static OSStatus D_DestroyDevice(AudioServerPlugInDriverRef d, AudioObjectID dev) {
    (void)d; (void)dev;
    return kAudioHardwareUnsupportedOperationError;
}

static OSStatus D_AddDeviceClient(AudioServerPlugInDriverRef d, AudioObjectID dev, const AudioServerPlugInClientInfo *c) {
    (void)c;
    return (d == gDriverRef && dev == kObjectID_Device) ? kAudioHardwareNoError : kAudioHardwareBadObjectError;
}

static OSStatus D_RemoveDeviceClient(AudioServerPlugInDriverRef d, AudioObjectID dev, const AudioServerPlugInClientInfo *c) {
    (void)c;
    return (d == gDriverRef && dev == kObjectID_Device) ? kAudioHardwareNoError : kAudioHardwareBadObjectError;
}

// 格式是固定的，没有需要走「配置变更」流程的属性
static OSStatus D_PerformDeviceConfigurationChange(AudioServerPlugInDriverRef d, AudioObjectID dev, UInt64 action, void *info) {
    (void)action; (void)info;
    return (d == gDriverRef && dev == kObjectID_Device) ? kAudioHardwareNoError : kAudioHardwareBadObjectError;
}

static OSStatus D_AbortDeviceConfigurationChange(AudioServerPlugInDriverRef d, AudioObjectID dev, UInt64 action, void *info) {
    (void)action; (void)info;
    return (d == gDriverRef && dev == kObjectID_Device) ? kAudioHardwareNoError : kAudioHardwareBadObjectError;
}

// MARK: - 属性

static AudioStreamBasicDescription StreamFormat(void) {
    AudioStreamBasicDescription f = {0};
    f.mSampleRate = kSampleRate;
    f.mFormatID = kAudioFormatLinearPCM;
    f.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagsNativeEndian | kAudioFormatFlagIsPacked;
    f.mBytesPerPacket = kBytesPerFrame;
    f.mFramesPerPacket = 1;
    f.mBytesPerFrame = kBytesPerFrame;
    f.mChannelsPerFrame = kChannels;
    f.mBitsPerChannel = 32;
    return f;
}

static bool IsStream(AudioObjectID id) { return id == kObjectID_Stream_Input || id == kObjectID_Stream_Output; }

static Boolean D_HasProperty(AudioServerPlugInDriverRef d, AudioObjectID obj, pid_t pid, const AudioObjectPropertyAddress *a) {
    (void)pid;
    if (d != gDriverRef || a == NULL) return false;
    switch (obj) {
    case kObjectID_PlugIn:
        switch (a->mSelector) {
        case kAudioObjectPropertyBaseClass: case kAudioObjectPropertyClass: case kAudioObjectPropertyOwner:
        case kAudioObjectPropertyManufacturer: case kAudioObjectPropertyOwnedObjects:
        case kAudioPlugInPropertyDeviceList: case kAudioPlugInPropertyTranslateUIDToDevice:
        case kAudioPlugInPropertyResourceBundle:
            return true;
        }
        return false;
    case kObjectID_Device:
        switch (a->mSelector) {
        case kAudioObjectPropertyBaseClass: case kAudioObjectPropertyClass: case kAudioObjectPropertyOwner:
        case kAudioObjectPropertyName: case kAudioObjectPropertyManufacturer: case kAudioObjectPropertyOwnedObjects:
        case kAudioDevicePropertyDeviceUID: case kAudioDevicePropertyModelUID: case kAudioDevicePropertyTransportType:
        case kAudioDevicePropertyRelatedDevices: case kAudioDevicePropertyClockDomain:
        case kAudioDevicePropertyDeviceIsAlive: case kAudioDevicePropertyDeviceIsRunning:
        case kAudioObjectPropertyControlList: case kAudioDevicePropertyNominalSampleRate:
        case kAudioDevicePropertyAvailableNominalSampleRates: case kAudioDevicePropertyIsHidden:
        case kAudioDevicePropertyZeroTimeStampPeriod: case kAudioDevicePropertyStreams:
            return true;
        case kAudioDevicePropertyDeviceCanBeDefaultDevice: case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:
        case kAudioDevicePropertyLatency: case kAudioDevicePropertySafetyOffset:
        case kAudioDevicePropertyPreferredChannelsForStereo: case kAudioDevicePropertyPreferredChannelLayout:
            return a->mScope == kAudioObjectPropertyScopeInput || a->mScope == kAudioObjectPropertyScopeOutput;
        }
        return false;
    case kObjectID_Stream_Input: case kObjectID_Stream_Output:
        switch (a->mSelector) {
        case kAudioObjectPropertyBaseClass: case kAudioObjectPropertyClass: case kAudioObjectPropertyOwner:
        case kAudioObjectPropertyOwnedObjects: case kAudioStreamPropertyIsActive: case kAudioStreamPropertyDirection:
        case kAudioStreamPropertyTerminalType: case kAudioStreamPropertyStartingChannel: case kAudioStreamPropertyLatency:
        case kAudioStreamPropertyVirtualFormat: case kAudioStreamPropertyPhysicalFormat:
        case kAudioStreamPropertyAvailableVirtualFormats: case kAudioStreamPropertyAvailablePhysicalFormats:
            return true;
        }
        return false;
    }
    return false;
}

static OSStatus D_IsPropertySettable(AudioServerPlugInDriverRef d, AudioObjectID obj, pid_t pid, const AudioObjectPropertyAddress *a, Boolean *out) {
    if (out == NULL) return kAudioHardwareIllegalOperationError;
    if (!D_HasProperty(d, obj, pid, a)) return kAudioHardwareUnknownPropertyError;
    *out = false;
    if (obj == kObjectID_Device && a->mSelector == kAudioDevicePropertyNominalSampleRate) *out = true;
    if (IsStream(obj)) {
        switch (a->mSelector) {
        case kAudioStreamPropertyIsActive: case kAudioStreamPropertyVirtualFormat: case kAudioStreamPropertyPhysicalFormat:
            *out = true;
        }
    }
    return kAudioHardwareNoError;
}

/// 设备在某个方向上有几条流
static UInt32 StreamCount(AudioObjectPropertyScope scope) {
    return (scope == kAudioObjectPropertyScopeGlobal) ? 2 : 1;
}

static OSStatus D_GetPropertyDataSize(AudioServerPlugInDriverRef d, AudioObjectID obj, pid_t pid, const AudioObjectPropertyAddress *a,
                                      UInt32 qualifierSize, const void *qualifier, UInt32 *outSize) {
    (void)qualifierSize; (void)qualifier;
    if (outSize == NULL) return kAudioHardwareIllegalOperationError;
    if (!D_HasProperty(d, obj, pid, a)) return kAudioHardwareUnknownPropertyError;
    switch (a->mSelector) {
    case kAudioObjectPropertyBaseClass: case kAudioObjectPropertyClass:
        *outSize = sizeof(AudioClassID); break;
    case kAudioObjectPropertyOwner:
        *outSize = sizeof(AudioObjectID); break;
    case kAudioObjectPropertyName: case kAudioObjectPropertyManufacturer:
    case kAudioDevicePropertyDeviceUID: case kAudioDevicePropertyModelUID: case kAudioPlugInPropertyResourceBundle:
        *outSize = sizeof(CFStringRef); break;
    case kAudioObjectPropertyOwnedObjects:
        if (obj == kObjectID_PlugIn) *outSize = sizeof(AudioObjectID);
        else if (obj == kObjectID_Device) *outSize = StreamCount(a->mScope) * sizeof(AudioObjectID);
        else *outSize = 0;
        break;
    case kAudioPlugInPropertyDeviceList: case kAudioPlugInPropertyTranslateUIDToDevice:
        *outSize = sizeof(AudioObjectID); break;
    case kAudioDevicePropertyStreams:
        *outSize = StreamCount(a->mScope) * sizeof(AudioObjectID); break;
    case kAudioDevicePropertyRelatedDevices:
        *outSize = sizeof(AudioObjectID); break;
    case kAudioObjectPropertyControlList:
        *outSize = 0; break;
    case kAudioDevicePropertyNominalSampleRate:
        *outSize = sizeof(Float64); break;
    case kAudioDevicePropertyAvailableNominalSampleRates:
        *outSize = sizeof(AudioValueRange); break;
    case kAudioDevicePropertyPreferredChannelsForStereo:
        *outSize = 2 * sizeof(UInt32); break;
    case kAudioDevicePropertyPreferredChannelLayout:
        *outSize = (UInt32)(offsetof(AudioChannelLayout, mChannelDescriptions) + kChannels * sizeof(AudioChannelDescription)); break;
    case kAudioStreamPropertyVirtualFormat: case kAudioStreamPropertyPhysicalFormat:
        *outSize = sizeof(AudioStreamBasicDescription); break;
    case kAudioStreamPropertyAvailableVirtualFormats: case kAudioStreamPropertyAvailablePhysicalFormats:
        *outSize = sizeof(AudioStreamRangedDescription); break;
    default:
        // 其余都是一个 UInt32
        *outSize = sizeof(UInt32); break;
    }
    return kAudioHardwareNoError;
}

#define RETURN_VALUE(type, value) do { \
        if (inDataSize < sizeof(type)) return kAudioHardwareBadPropertySizeError; \
        *((type *)outData) = (value); *outDataSize = sizeof(type); return kAudioHardwareNoError; \
    } while (0)

static OSStatus D_GetPropertyData(AudioServerPlugInDriverRef d, AudioObjectID obj, pid_t pid, const AudioObjectPropertyAddress *a,
                                  UInt32 qualifierSize, const void *qualifier, UInt32 inDataSize, UInt32 *outDataSize, void *outData) {
    if (outDataSize == NULL || outData == NULL) return kAudioHardwareIllegalOperationError;
    if (!D_HasProperty(d, obj, pid, a)) return kAudioHardwareUnknownPropertyError;

    // 列表类属性：调用方给的空间可能放不下全部，放得下几个就给几个
    #define RETURN_LIST(...) do { \
            AudioObjectID items[] = { __VA_ARGS__ }; \
            UInt32 n = (UInt32)(sizeof(items) / sizeof(AudioObjectID)); \
            UInt32 room = inDataSize / sizeof(AudioObjectID); \
            if (n > room) n = room; \
            memcpy(outData, items, n * sizeof(AudioObjectID)); \
            *outDataSize = n * sizeof(AudioObjectID); return kAudioHardwareNoError; \
        } while (0)

    if (obj == kObjectID_PlugIn) {
        switch (a->mSelector) {
        case kAudioObjectPropertyBaseClass: RETURN_VALUE(AudioClassID, kAudioObjectClassID);
        case kAudioObjectPropertyClass:     RETURN_VALUE(AudioClassID, kAudioPlugInClassID);
        case kAudioObjectPropertyOwner:     RETURN_VALUE(AudioObjectID, kAudioObjectUnknown);
        case kAudioObjectPropertyManufacturer: RETURN_VALUE(CFStringRef, CFSTR(kDevice_Manufacturer));
        case kAudioObjectPropertyOwnedObjects: case kAudioPlugInPropertyDeviceList:
            RETURN_LIST(kObjectID_Device);
        case kAudioPlugInPropertyTranslateUIDToDevice: {
            if (qualifierSize != sizeof(CFStringRef) || qualifier == NULL) return kAudioHardwareBadPropertySizeError;
            CFStringRef uid = *((CFStringRef *)qualifier);
            Boolean match = uid != NULL && CFStringCompare(uid, CFSTR(kDevice_UID), 0) == kCFCompareEqualTo;
            RETURN_VALUE(AudioObjectID, match ? kObjectID_Device : kAudioObjectUnknown);
        }
        case kAudioPlugInPropertyResourceBundle: RETURN_VALUE(CFStringRef, CFSTR(""));
        }
    }

    if (obj == kObjectID_Device) {
        switch (a->mSelector) {
        case kAudioObjectPropertyBaseClass: RETURN_VALUE(AudioClassID, kAudioObjectClassID);
        case kAudioObjectPropertyClass:     RETURN_VALUE(AudioClassID, kAudioDeviceClassID);
        case kAudioObjectPropertyOwner:     RETURN_VALUE(AudioObjectID, kObjectID_PlugIn);
        case kAudioObjectPropertyName:      RETURN_VALUE(CFStringRef, CFSTR(kDevice_Name));
        case kAudioObjectPropertyManufacturer: RETURN_VALUE(CFStringRef, CFSTR(kDevice_Manufacturer));
        case kAudioDevicePropertyDeviceUID: RETURN_VALUE(CFStringRef, CFSTR(kDevice_UID));
        case kAudioDevicePropertyModelUID:  RETURN_VALUE(CFStringRef, CFSTR(kDevice_ModelUID));
        case kAudioDevicePropertyTransportType: RETURN_VALUE(UInt32, kAudioDeviceTransportTypeVirtual);
        case kAudioDevicePropertyRelatedDevices: RETURN_LIST(kObjectID_Device);
        case kAudioDevicePropertyClockDomain: RETURN_VALUE(UInt32, 0);
        case kAudioDevicePropertyDeviceIsAlive: RETURN_VALUE(UInt32, 1);
        case kAudioDevicePropertyDeviceIsRunning: {
            os_unfair_lock_lock(&gStateLock);
            UInt32 running = gIOClients > 0 ? 1 : 0;
            os_unfair_lock_unlock(&gStateLock);
            RETURN_VALUE(UInt32, running);
        }
        // 只让输入端当默认设备：它是给别的程序当麦克风用的。
        // 输出端不出现在「默认输出」的候选里，免得用户不小心把系统声音切进来，变成没声音
        case kAudioDevicePropertyDeviceCanBeDefaultDevice:
            RETURN_VALUE(UInt32, a->mScope == kAudioObjectPropertyScopeInput ? 1 : 0);
        case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice: RETURN_VALUE(UInt32, 0);
        case kAudioDevicePropertyLatency: RETURN_VALUE(UInt32, 0);
        case kAudioDevicePropertySafetyOffset: RETURN_VALUE(UInt32, 0);
        case kAudioDevicePropertyNominalSampleRate: RETURN_VALUE(Float64, kSampleRate);
        case kAudioDevicePropertyAvailableNominalSampleRates: {
            if (inDataSize < sizeof(AudioValueRange)) { *outDataSize = 0; return kAudioHardwareNoError; }
            AudioValueRange range = { kSampleRate, kSampleRate };
            *((AudioValueRange *)outData) = range; *outDataSize = sizeof(AudioValueRange);
            return kAudioHardwareNoError;
        }
        case kAudioDevicePropertyIsHidden: RETURN_VALUE(UInt32, 0);
        case kAudioDevicePropertyZeroTimeStampPeriod: RETURN_VALUE(UInt32, kZeroTimeStampPeriod);
        case kAudioObjectPropertyControlList: *outDataSize = 0; return kAudioHardwareNoError;
        case kAudioObjectPropertyOwnedObjects: case kAudioDevicePropertyStreams:
            if (a->mScope == kAudioObjectPropertyScopeInput) RETURN_LIST(kObjectID_Stream_Input);
            if (a->mScope == kAudioObjectPropertyScopeOutput) RETURN_LIST(kObjectID_Stream_Output);
            RETURN_LIST(kObjectID_Stream_Input, kObjectID_Stream_Output);
        case kAudioDevicePropertyPreferredChannelsForStereo: {
            if (inDataSize < 2 * sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
            ((UInt32 *)outData)[0] = 1; ((UInt32 *)outData)[1] = 2;
            *outDataSize = 2 * sizeof(UInt32);
            return kAudioHardwareNoError;
        }
        case kAudioDevicePropertyPreferredChannelLayout: {
            UInt32 size = (UInt32)(offsetof(AudioChannelLayout, mChannelDescriptions) + kChannels * sizeof(AudioChannelDescription));
            if (inDataSize < size) return kAudioHardwareBadPropertySizeError;
            AudioChannelLayout *layout = (AudioChannelLayout *)outData;
            memset(layout, 0, size);
            layout->mChannelLayoutTag = kAudioChannelLayoutTag_UseChannelDescriptions;
            layout->mNumberChannelDescriptions = kChannels;
            layout->mChannelDescriptions[0].mChannelLabel = kAudioChannelLabel_Left;
            layout->mChannelDescriptions[1].mChannelLabel = kAudioChannelLabel_Right;
            *outDataSize = size;
            return kAudioHardwareNoError;
        }
        }
    }

    if (IsStream(obj)) {
        bool isInput = obj == kObjectID_Stream_Input;
        switch (a->mSelector) {
        case kAudioObjectPropertyBaseClass: RETURN_VALUE(AudioClassID, kAudioObjectClassID);
        case kAudioObjectPropertyClass:     RETURN_VALUE(AudioClassID, kAudioStreamClassID);
        case kAudioObjectPropertyOwner:     RETURN_VALUE(AudioObjectID, kObjectID_Device);
        case kAudioObjectPropertyOwnedObjects: *outDataSize = 0; return kAudioHardwareNoError;
        case kAudioStreamPropertyIsActive: {
            os_unfair_lock_lock(&gStateLock);
            UInt32 active = (isInput ? gInputActive : gOutputActive) ? 1 : 0;
            os_unfair_lock_unlock(&gStateLock);
            RETURN_VALUE(UInt32, active);
        }
        case kAudioStreamPropertyDirection: RETURN_VALUE(UInt32, isInput ? 1 : 0);
        case kAudioStreamPropertyTerminalType:
            RETURN_VALUE(UInt32, isInput ? kAudioStreamTerminalTypeMicrophone : kAudioStreamTerminalTypeSpeaker);
        case kAudioStreamPropertyStartingChannel: RETURN_VALUE(UInt32, 1);
        case kAudioStreamPropertyLatency: RETURN_VALUE(UInt32, 0);
        case kAudioStreamPropertyVirtualFormat: case kAudioStreamPropertyPhysicalFormat:
            RETURN_VALUE(AudioStreamBasicDescription, StreamFormat());
        case kAudioStreamPropertyAvailableVirtualFormats: case kAudioStreamPropertyAvailablePhysicalFormats: {
            if (inDataSize < sizeof(AudioStreamRangedDescription)) { *outDataSize = 0; return kAudioHardwareNoError; }
            AudioStreamRangedDescription *r = (AudioStreamRangedDescription *)outData;
            r->mFormat = StreamFormat();
            r->mSampleRateRange.mMinimum = kSampleRate;
            r->mSampleRateRange.mMaximum = kSampleRate;
            *outDataSize = sizeof(AudioStreamRangedDescription);
            return kAudioHardwareNoError;
        }
        }
    }
    return kAudioHardwareUnknownPropertyError;
}

static OSStatus D_SetPropertyData(AudioServerPlugInDriverRef d, AudioObjectID obj, pid_t pid, const AudioObjectPropertyAddress *a,
                                  UInt32 qualifierSize, const void *qualifier, UInt32 inDataSize, const void *inData) {
    (void)qualifierSize; (void)qualifier;
    if (inData == NULL) return kAudioHardwareIllegalOperationError;
    if (!D_HasProperty(d, obj, pid, a)) return kAudioHardwareUnknownPropertyError;

    if (obj == kObjectID_Device && a->mSelector == kAudioDevicePropertyNominalSampleRate) {
        // 只有 48 kHz 一种，设成它就是什么都不用做
        if (inDataSize != sizeof(Float64)) return kAudioHardwareBadPropertySizeError;
        return *((const Float64 *)inData) == kSampleRate ? kAudioHardwareNoError : kAudioHardwareIllegalOperationError;
    }
    if (IsStream(obj)) {
        switch (a->mSelector) {
        case kAudioStreamPropertyIsActive: {
            if (inDataSize != sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
            bool active = *((const UInt32 *)inData) != 0;
            os_unfair_lock_lock(&gStateLock);
            if (obj == kObjectID_Stream_Input) gInputActive = active; else gOutputActive = active;
            os_unfair_lock_unlock(&gStateLock);
            return kAudioHardwareNoError;
        }
        case kAudioStreamPropertyVirtualFormat: case kAudioStreamPropertyPhysicalFormat: {
            if (inDataSize != sizeof(AudioStreamBasicDescription)) return kAudioHardwareBadPropertySizeError;
            const AudioStreamBasicDescription *f = (const AudioStreamBasicDescription *)inData;
            AudioStreamBasicDescription ours = StreamFormat();
            bool same = f->mFormatID == ours.mFormatID && f->mSampleRate == ours.mSampleRate
                && f->mChannelsPerFrame == ours.mChannelsPerFrame && f->mBitsPerChannel == ours.mBitsPerChannel;
            return same ? kAudioHardwareNoError : kAudioDeviceUnsupportedFormatError;
        }
        }
    }
    return kAudioHardwareUnsupportedOperationError;
}

// MARK: - IO

static OSStatus D_StartIO(AudioServerPlugInDriverRef d, AudioObjectID dev, UInt32 clientID) {
    (void)clientID;
    if (d != gDriverRef || dev != kObjectID_Device) return kAudioHardwareBadObjectError;
    os_unfair_lock_lock(&gStateLock);
    if (gIOClients == 0) {
        // 第一个程序开始 IO：时钟从现在起算，回环缓冲区清空
        gNumberTimeStamps = 0;
        gAnchorHostTime = mach_absolute_time();
        os_unfair_lock_lock(&gRingLock);
        memset(gRing, 0, sizeof(gRing));
        gWriteEnd = 0;
        os_unfair_lock_unlock(&gRingLock);
    }
    gIOClients += 1;
    os_unfair_lock_unlock(&gStateLock);
    return kAudioHardwareNoError;
}

static OSStatus D_StopIO(AudioServerPlugInDriverRef d, AudioObjectID dev, UInt32 clientID) {
    (void)clientID;
    if (d != gDriverRef || dev != kObjectID_Device) return kAudioHardwareBadObjectError;
    os_unfair_lock_lock(&gStateLock);
    if (gIOClients > 0) gIOClients -= 1;
    os_unfair_lock_unlock(&gStateLock);
    return kAudioHardwareNoError;
}

// 设备没有真实硬件，时钟就是主机时钟：每过一个周期（kZeroTimeStampPeriod 帧）报一个新的零点
static OSStatus D_GetZeroTimeStamp(AudioServerPlugInDriverRef d, AudioObjectID dev, UInt32 clientID,
                                   Float64 *outSampleTime, UInt64 *outHostTime, UInt64 *outSeed) {
    (void)clientID;
    if (d != gDriverRef || dev != kObjectID_Device) return kAudioHardwareBadObjectError;
    os_unfair_lock_lock(&gStateLock);
    UInt64 now = mach_absolute_time();
    Float64 ticksPerPeriod = gHostTicksPerFrame * (Float64)kZeroTimeStampPeriod;
    UInt64 next = gAnchorHostTime + (UInt64)((Float64)(gNumberTimeStamps + 1) * ticksPerPeriod);
    if (next <= now) gNumberTimeStamps += 1;
    *outSampleTime = (Float64)(gNumberTimeStamps * kZeroTimeStampPeriod);
    *outHostTime = gAnchorHostTime + (UInt64)((Float64)gNumberTimeStamps * ticksPerPeriod);
    *outSeed = 1;
    os_unfair_lock_unlock(&gStateLock);
    return kAudioHardwareNoError;
}

static OSStatus D_WillDoIOOperation(AudioServerPlugInDriverRef d, AudioObjectID dev, UInt32 clientID, UInt32 operation,
                                    Boolean *outWillDo, Boolean *outInPlace) {
    (void)clientID;
    if (d != gDriverRef || dev != kObjectID_Device) return kAudioHardwareBadObjectError;
    bool will = operation == kAudioServerPlugInIOOperationReadInput || operation == kAudioServerPlugInIOOperationWriteMix;
    if (outWillDo) *outWillDo = will;
    if (outInPlace) *outInPlace = true;
    return kAudioHardwareNoError;
}

static OSStatus D_BeginIOOperation(AudioServerPlugInDriverRef d, AudioObjectID dev, UInt32 clientID, UInt32 operation,
                                   UInt32 frames, const AudioServerPlugInIOCycleInfo *info) {
    (void)clientID; (void)operation; (void)frames; (void)info;
    return (d == gDriverRef && dev == kObjectID_Device) ? kAudioHardwareNoError : kAudioHardwareBadObjectError;
}

/// 把 [from, to) 这段采样时间在缓冲区里对应的位置清零
static void RingZero(SInt64 from, SInt64 to) {
    if (to - from >= kRingFrames) { memset(gRing, 0, sizeof(gRing)); return; }
    for (SInt64 t = from; t < to; ) {
        SInt64 pos = ((t % kRingFrames) + kRingFrames) % kRingFrames;
        SInt64 run = kRingFrames - pos;
        if (run > to - t) run = to - t;
        memset(&gRing[pos * kChannels], 0, (size_t)run * kBytesPerFrame);
        t += run;
    }
}

static OSStatus D_DoIOOperation(AudioServerPlugInDriverRef d, AudioObjectID dev, AudioObjectID stream, UInt32 clientID,
                                UInt32 operation, UInt32 frames, const AudioServerPlugInIOCycleInfo *info,
                                void *ioMainBuffer, void *ioSecondaryBuffer) {
    (void)stream; (void)clientID; (void)ioSecondaryBuffer;
    if (d != gDriverRef || dev != kObjectID_Device) return kAudioHardwareBadObjectError;
    if (ioMainBuffer == NULL || info == NULL || frames == 0 || frames > kRingFrames) return kAudioHardwareNoError;
    Float32 *buffer = (Float32 *)ioMainBuffer;

    if (operation == kAudioServerPlugInIOOperationWriteMix) {
        // 播给输出端的声音：按它的采样时间放进缓冲区
        SInt64 start = (SInt64)info->mOutputTime.mSampleTime;
        SInt64 end = start + frames;
        os_unfair_lock_lock(&gRingLock);
        // 和上次写的不连着（中间停过）：把没写到的那段清零，免得读到上一圈留下的旧声音
        if (start > gWriteEnd) RingZero(gWriteEnd, start);
        for (UInt32 done = 0; done < frames; ) {
            SInt64 pos = (((start + done) % kRingFrames) + kRingFrames) % kRingFrames;
            UInt32 run = (UInt32)(kRingFrames - pos);
            if (run > frames - done) run = frames - done;
            memcpy(&gRing[pos * kChannels], &buffer[done * kChannels], run * kBytesPerFrame);
            done += run;
        }
        if (end > gWriteEnd) gWriteEnd = end;
        os_unfair_lock_unlock(&gRingLock);
    } else if (operation == kAudioServerPlugInIOOperationReadInput) {
        // 输入端：把同一段采样时间的声音读出来。没人写过的部分是静音
        SInt64 start = (SInt64)info->mInputTime.mSampleTime;
        os_unfair_lock_lock(&gRingLock);
        SInt64 validFrom = gWriteEnd - kRingFrames;
        for (UInt32 i = 0; i < frames; i++) {
            SInt64 t = start + i;
            if (t >= validFrom && t < gWriteEnd) {
                SInt64 pos = ((t % kRingFrames) + kRingFrames) % kRingFrames;
                buffer[i * kChannels] = gRing[pos * kChannels];
                buffer[i * kChannels + 1] = gRing[pos * kChannels + 1];
            } else {
                buffer[i * kChannels] = 0;
                buffer[i * kChannels + 1] = 0;
            }
        }
        os_unfair_lock_unlock(&gRingLock);
    }
    return kAudioHardwareNoError;
}

static OSStatus D_EndIOOperation(AudioServerPlugInDriverRef d, AudioObjectID dev, UInt32 clientID, UInt32 operation,
                                 UInt32 frames, const AudioServerPlugInIOCycleInfo *info) {
    (void)clientID; (void)operation; (void)frames; (void)info;
    return (d == gDriverRef && dev == kObjectID_Device) ? kAudioHardwareNoError : kAudioHardwareBadObjectError;
}
