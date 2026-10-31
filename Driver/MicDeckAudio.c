// MicDeck Audio: a Core Audio server plug-in (HAL driver) with two virtual devices.
//
//   "MicDeck Microphone"  (UID MicDeckAudio_Mic)   visible input device that apps record from
//   "MicDeck Feed"        (UID MicDeckAudio_Feed)  hidden output device that MicDeck plays into
//
// Both devices share one clock and one ring buffer: what MicDeck writes to the feed at
// sample time T is what the microphone delivers at sample time T. MicDeck reads the real
// mic, runs the voice chain, and plays the result into the feed. Hidden devices aren't
// listed in kAudioHardwarePropertyDevices; MicDeck finds the feed by UID.
//
// Installed to /Library/Audio/Plug-Ins/HAL/MicDeckAudio.driver (see build-driver.sh).
// The device runs at 48 kHz mono, Float32.

#include <CoreAudio/AudioServerPlugIn.h>
#include <dispatch/dispatch.h>
#include <mach/mach_time.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <string.h>

// MARK: - Objects and constants

enum {
    kObjectID_PlugIn = kAudioObjectPlugInObject,
    kObjectID_Mic = 2,
    kObjectID_MicStream = 3,
    kObjectID_Feed = 4,
    kObjectID_FeedStream = 5,
};

#define kSampleRate 48000.0
#define kChannels 1
#define kRingFrames 16384          // also the zero time stamp period

#define kMicUID "MicDeckAudio_Mic"
#define kFeedUID "MicDeckAudio_Feed"
#define kModelUID "MicDeckAudio_Model"

// MARK: - State

static AudioServerPlugInHostRef gHost = NULL;
static pthread_mutex_t gMutex = PTHREAD_MUTEX_INITIALIZER;
static UInt32 gRefCount = 0;
static UInt32 gMicIOCount = 0;
static UInt32 gFeedIOCount = 0;
static Float64 gTicksPerFrame = 0;
static _Atomic UInt64 gAnchorHostTime = 0;

static Float32 gRing[kRingFrames];
/// Sample time one past the last frame the feed wrote; -1 until the feed writes after a (re)start.
static _Atomic SInt64 gFeedWrittenUntil = -1;
static _Atomic bool gFeedRunning = false;

// MARK: - Interface declarations

static HRESULT MD_QueryInterface(void* inDriver, REFIID inUUID, LPVOID* outInterface);
static ULONG MD_AddRef(void* inDriver);
static ULONG MD_Release(void* inDriver);
static OSStatus MD_Initialize(AudioServerPlugInDriverRef inDriver, AudioServerPlugInHostRef inHost);
static OSStatus MD_CreateDevice(AudioServerPlugInDriverRef inDriver, CFDictionaryRef inDescription,
                                const AudioServerPlugInClientInfo* inClientInfo, AudioObjectID* outDeviceObjectID);
static OSStatus MD_DestroyDevice(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID);
static OSStatus MD_AddDeviceClient(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID,
                                   const AudioServerPlugInClientInfo* inClientInfo);
static OSStatus MD_RemoveDeviceClient(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID,
                                      const AudioServerPlugInClientInfo* inClientInfo);
static OSStatus MD_PerformDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID,
                                                    UInt64 inChangeAction, void* inChangeInfo);
static OSStatus MD_AbortDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID,
                                                  UInt64 inChangeAction, void* inChangeInfo);
static Boolean MD_HasProperty(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID,
                              const AudioObjectPropertyAddress* inAddress);
static OSStatus MD_IsPropertySettable(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID,
                                      const AudioObjectPropertyAddress* inAddress, Boolean* outIsSettable);
static OSStatus MD_GetPropertyDataSize(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID,
                                       const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize,
                                       const void* inQualifierData, UInt32* outDataSize);
static OSStatus MD_GetPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID,
                                   const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize,
                                   const void* inQualifierData, UInt32 inDataSize, UInt32* outDataSize, void* outData);
static OSStatus MD_SetPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID,
                                   const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize,
                                   const void* inQualifierData, UInt32 inDataSize, const void* inData);
static OSStatus MD_StartIO(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID);
static OSStatus MD_StopIO(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID);
static OSStatus MD_GetZeroTimeStamp(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID,
                                    Float64* outSampleTime, UInt64* outHostTime, UInt64* outSeed);
static OSStatus MD_WillDoIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID,
                                     UInt32 inOperationID, Boolean* outWillDo, Boolean* outWillDoInPlace);
static OSStatus MD_BeginIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID,
                                    UInt32 inOperationID, UInt32 inIOBufferFrameSize,
                                    const AudioServerPlugInIOCycleInfo* inIOCycleInfo);
static OSStatus MD_DoIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, AudioObjectID inStreamObjectID,
                                 UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize,
                                 const AudioServerPlugInIOCycleInfo* inIOCycleInfo, void* ioMainBuffer, void* ioSecondaryBuffer);
static OSStatus MD_EndIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID,
                                  UInt32 inOperationID, UInt32 inIOBufferFrameSize,
                                  const AudioServerPlugInIOCycleInfo* inIOCycleInfo);

static AudioServerPlugInDriverInterface gInterface = {
    NULL,
    MD_QueryInterface, MD_AddRef, MD_Release,
    MD_Initialize, MD_CreateDevice, MD_DestroyDevice,
    MD_AddDeviceClient, MD_RemoveDeviceClient,
    MD_PerformDeviceConfigurationChange, MD_AbortDeviceConfigurationChange,
    MD_HasProperty, MD_IsPropertySettable, MD_GetPropertyDataSize, MD_GetPropertyData, MD_SetPropertyData,
    MD_StartIO, MD_StopIO, MD_GetZeroTimeStamp,
    MD_WillDoIOOperation, MD_BeginIOOperation, MD_DoIOOperation, MD_EndIOOperation,
};
static AudioServerPlugInDriverInterface* gInterfacePtr = &gInterface;
static AudioServerPlugInDriverRef gDriverRef = &gInterfacePtr;

// MARK: - Factory (named in Info.plist)

void* MicDeckAudio_Create(CFAllocatorRef inAllocator, CFUUIDRef inRequestedTypeUUID);
void* MicDeckAudio_Create(CFAllocatorRef inAllocator, CFUUIDRef inRequestedTypeUUID) {
    (void)inAllocator;
    return CFEqual(inRequestedTypeUUID, kAudioServerPlugInTypeUUID) ? gDriverRef : NULL;
}

// MARK: - IUnknown

static HRESULT MD_QueryInterface(void* inDriver, REFIID inUUID, LPVOID* outInterface) {
    if (inDriver != gDriverRef || outInterface == NULL) return kAudioHardwareBadObjectError;
    CFUUIDRef requested = CFUUIDCreateFromUUIDBytes(NULL, inUUID);
    if (requested == NULL) return kAudioHardwareIllegalOperationError;
    HRESULT result = E_NOINTERFACE;
    if (CFEqual(requested, IUnknownUUID) || CFEqual(requested, kAudioServerPlugInDriverInterfaceUUID)) {
        pthread_mutex_lock(&gMutex);
        gRefCount++;
        pthread_mutex_unlock(&gMutex);
        *outInterface = gDriverRef;
        result = S_OK;
    }
    CFRelease(requested);
    return result;
}

static ULONG MD_AddRef(void* inDriver) {
    if (inDriver != gDriverRef) return 0;
    pthread_mutex_lock(&gMutex);
    ULONG r = ++gRefCount;
    pthread_mutex_unlock(&gMutex);
    return r;
}

static ULONG MD_Release(void* inDriver) {
    if (inDriver != gDriverRef) return 0;
    pthread_mutex_lock(&gMutex);
    if (gRefCount > 0) gRefCount--;
    ULONG r = gRefCount;   // the driver is static; nothing to free
    pthread_mutex_unlock(&gMutex);
    return r;
}

// MARK: - Basic operations

static OSStatus MD_Initialize(AudioServerPlugInDriverRef inDriver, AudioServerPlugInHostRef inHost) {
    if (inDriver != gDriverRef) return kAudioHardwareBadObjectError;
    gHost = inHost;
    mach_timebase_info_data_t tb;
    mach_timebase_info(&tb);
    Float64 hostTicksPerSecond = (Float64)tb.denom / (Float64)tb.numer * 1000000000.0;
    gTicksPerFrame = hostTicksPerSecond / kSampleRate;
    return 0;
}

static OSStatus MD_CreateDevice(AudioServerPlugInDriverRef d, CFDictionaryRef desc, const AudioServerPlugInClientInfo* c, AudioObjectID* out) {
    (void)d; (void)desc; (void)c; (void)out;
    return kAudioHardwareUnsupportedOperationError;
}
static OSStatus MD_DestroyDevice(AudioServerPlugInDriverRef d, AudioObjectID id) {
    (void)d; (void)id;
    return kAudioHardwareUnsupportedOperationError;
}
static OSStatus MD_AddDeviceClient(AudioServerPlugInDriverRef d, AudioObjectID id, const AudioServerPlugInClientInfo* c) {
    (void)d; (void)id; (void)c;
    return 0;
}
static OSStatus MD_RemoveDeviceClient(AudioServerPlugInDriverRef d, AudioObjectID id, const AudioServerPlugInClientInfo* c) {
    (void)d; (void)id; (void)c;
    return 0;
}
static OSStatus MD_PerformDeviceConfigurationChange(AudioServerPlugInDriverRef d, AudioObjectID id, UInt64 a, void* i) {
    (void)d; (void)id; (void)a; (void)i;
    return 0;
}
static OSStatus MD_AbortDeviceConfigurationChange(AudioServerPlugInDriverRef d, AudioObjectID id, UInt64 a, void* i) {
    (void)d; (void)id; (void)a; (void)i;
    return 0;
}

// MARK: - Object helpers

static bool IsDevice(AudioObjectID id) { return id == kObjectID_Mic || id == kObjectID_Feed; }
static bool IsStream(AudioObjectID id) { return id == kObjectID_MicStream || id == kObjectID_FeedStream; }
static bool DeviceIsInput(AudioObjectID device) { return device == kObjectID_Mic; }
static AudioObjectID StreamOf(AudioObjectID device) { return device == kObjectID_Mic ? kObjectID_MicStream : kObjectID_FeedStream; }
static AudioObjectID DeviceOfStream(AudioObjectID stream) { return stream == kObjectID_MicStream ? kObjectID_Mic : kObjectID_Feed; }

static bool ScopeMatches(AudioObjectID device, AudioObjectPropertyScope scope) {
    if (scope == kAudioObjectPropertyScopeGlobal) return true;
    return DeviceIsInput(device) ? scope == kAudioObjectPropertyScopeInput : scope == kAudioObjectPropertyScopeOutput;
}

static AudioStreamBasicDescription StreamFormat(void) {
    AudioStreamBasicDescription f;
    memset(&f, 0, sizeof(f));
    f.mSampleRate = kSampleRate;
    f.mFormatID = kAudioFormatLinearPCM;
    f.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagsNativeEndian | kAudioFormatFlagIsPacked;
    f.mBytesPerPacket = sizeof(Float32) * kChannels;
    f.mFramesPerPacket = 1;
    f.mBytesPerFrame = sizeof(Float32) * kChannels;
    f.mChannelsPerFrame = kChannels;
    f.mBitsPerChannel = 32;
    return f;
}

static void NotifyRunningChanged(AudioObjectID device) {
    // Off the IO path and out of our lock: the host may call back into the driver.
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
        AudioObjectPropertyAddress addr = {kAudioDevicePropertyDeviceIsRunning, kAudioObjectPropertyScopeGlobal,
                                           kAudioObjectPropertyElementMain};
        if (gHost) gHost->PropertiesChanged(gHost, device, 1, &addr);
    });
}

// MARK: - Properties
//
// One function answers all three questions: with outData == NULL it only reports the
// size, so HasProperty, GetPropertyDataSize and GetPropertyData can't disagree.

#define WRITE(type, value)                                                     \
    do {                                                                       \
        if (outData) {                                                         \
            if (inDataSize < sizeof(type)) return kAudioHardwareBadPropertySizeError; \
            *(type*)outData = (value);                                         \
        }                                                                      \
        *outDataSize = sizeof(type);                                           \
        return 0;                                                              \
    } while (0)

/// Writes up to `count` object IDs (fewer when the caller's buffer is smaller).
static OSStatus WriteIDs(const AudioObjectID* ids, UInt32 count, UInt32 inDataSize, UInt32* outDataSize, void* outData) {
    if (outData) {
        UInt32 n = inDataSize / sizeof(AudioObjectID);
        if (n > count) n = count;
        memcpy(outData, ids, n * sizeof(AudioObjectID));
        *outDataSize = n * sizeof(AudioObjectID);
    } else {
        *outDataSize = count * sizeof(AudioObjectID);
    }
    return 0;
}

static OSStatus PlugInProperty(const AudioObjectPropertyAddress* a, UInt32 qSize, const void* q, UInt32 inDataSize,
                               UInt32* outDataSize, void* outData) {
    static const AudioObjectID devices[] = {kObjectID_Mic, kObjectID_Feed};
    switch (a->mSelector) {
    case kAudioObjectPropertyBaseClass: WRITE(AudioClassID, kAudioObjectClassID);
    case kAudioObjectPropertyClass: WRITE(AudioClassID, kAudioPlugInClassID);
    case kAudioObjectPropertyOwner: WRITE(AudioObjectID, kAudioObjectUnknown);
    case kAudioObjectPropertyManufacturer: WRITE(CFStringRef, CFSTR("MicDeck"));
    case kAudioObjectPropertyOwnedObjects:
    case kAudioPlugInPropertyDeviceList: {
        // The qualifier, when given, is a list of class IDs to filter by.
        bool want = true;
        if (a->mSelector == kAudioObjectPropertyOwnedObjects && qSize >= sizeof(AudioClassID) && q != NULL) {
            want = false;
            const AudioClassID* classes = q;
            for (UInt32 i = 0; i < qSize / sizeof(AudioClassID); i++)
                if (classes[i] == kAudioDeviceClassID || classes[i] == kAudioObjectClassID) want = true;
        }
        return WriteIDs(devices, want ? 2 : 0, inDataSize, outDataSize, outData);
    }
    case kAudioPlugInPropertyTranslateUIDToDevice: {
        AudioObjectID found = kAudioObjectUnknown;
        if (outData) {
            if (qSize != sizeof(CFStringRef) || q == NULL) return kAudioHardwareBadPropertySizeError;
            CFStringRef uid = *(const CFStringRef*)q;
            if (uid && CFStringCompare(uid, CFSTR(kMicUID), 0) == kCFCompareEqualTo) found = kObjectID_Mic;
            if (uid && CFStringCompare(uid, CFSTR(kFeedUID), 0) == kCFCompareEqualTo) found = kObjectID_Feed;
        }
        WRITE(AudioObjectID, found);
    }
    case kAudioPlugInPropertyResourceBundle: WRITE(CFStringRef, CFSTR(""));
    default: return kAudioHardwareUnknownPropertyError;
    }
}

static OSStatus DeviceProperty(AudioObjectID device, const AudioObjectPropertyAddress* a, UInt32 inDataSize,
                               UInt32* outDataSize, void* outData) {
    bool input = DeviceIsInput(device);
    AudioObjectID stream = StreamOf(device);
    switch (a->mSelector) {
    case kAudioObjectPropertyBaseClass: WRITE(AudioClassID, kAudioObjectClassID);
    case kAudioObjectPropertyClass: WRITE(AudioClassID, kAudioDeviceClassID);
    case kAudioObjectPropertyOwner: WRITE(AudioObjectID, kObjectID_PlugIn);
    case kAudioObjectPropertyName: WRITE(CFStringRef, input ? CFSTR("MicDeck Microphone") : CFSTR("MicDeck Feed"));
    case kAudioObjectPropertyManufacturer: WRITE(CFStringRef, CFSTR("MicDeck"));
    case kAudioDevicePropertyDeviceUID: WRITE(CFStringRef, input ? CFSTR(kMicUID) : CFSTR(kFeedUID));
    case kAudioDevicePropertyModelUID: WRITE(CFStringRef, CFSTR(kModelUID));
    case kAudioDevicePropertyTransportType: WRITE(UInt32, kAudioDeviceTransportTypeVirtual);
    case kAudioDevicePropertyClockDomain: WRITE(UInt32, 0);
    case kAudioDevicePropertyDeviceIsAlive: WRITE(UInt32, 1);
    case kAudioDevicePropertyDeviceIsRunning: {
        pthread_mutex_lock(&gMutex);
        UInt32 running = (input ? gMicIOCount : gFeedIOCount) > 0;
        pthread_mutex_unlock(&gMutex);
        WRITE(UInt32, running);
    }
    case kAudioDevicePropertyDeviceCanBeDefaultDevice:
        WRITE(UInt32, input && a->mScope == kAudioObjectPropertyScopeInput);
    case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice: WRITE(UInt32, 0);
    case kAudioDevicePropertyLatency: WRITE(UInt32, 0);
    case kAudioDevicePropertySafetyOffset: WRITE(UInt32, 0);
    case kAudioDevicePropertyIsHidden: WRITE(UInt32, input ? 0 : 1);
    case kAudioDevicePropertyZeroTimeStampPeriod: WRITE(UInt32, kRingFrames);
    case kAudioDevicePropertyClockIsStable: WRITE(UInt32, 1);
    case kAudioDevicePropertyNominalSampleRate: WRITE(Float64, kSampleRate);
    case kAudioDevicePropertyAvailableNominalSampleRates: {
        AudioValueRange r = {kSampleRate, kSampleRate};
        WRITE(AudioValueRange, r);
    }
    case kAudioDevicePropertyRelatedDevices: return WriteIDs(&device, 1, inDataSize, outDataSize, outData);
    case kAudioObjectPropertyOwnedObjects:
    case kAudioDevicePropertyStreams:
        return WriteIDs(&stream, ScopeMatches(device, a->mScope) ? 1 : 0, inDataSize, outDataSize, outData);
    case kAudioObjectPropertyControlList: return WriteIDs(NULL, 0, inDataSize, outDataSize, outData);
    case kAudioDevicePropertyPreferredChannelsForStereo: {
        if (outData) {
            if (inDataSize < 2 * sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
            ((UInt32*)outData)[0] = 1;
            ((UInt32*)outData)[1] = 1;
        }
        *outDataSize = 2 * sizeof(UInt32);
        return 0;
    }
    default: return kAudioHardwareUnknownPropertyError;
    }
}

static OSStatus StreamProperty(AudioObjectID stream, const AudioObjectPropertyAddress* a, UInt32 inDataSize,
                               UInt32* outDataSize, void* outData) {
    bool input = stream == kObjectID_MicStream;
    switch (a->mSelector) {
    case kAudioObjectPropertyBaseClass: WRITE(AudioClassID, kAudioObjectClassID);
    case kAudioObjectPropertyClass: WRITE(AudioClassID, kAudioStreamClassID);
    case kAudioObjectPropertyOwner: WRITE(AudioObjectID, DeviceOfStream(stream));
    case kAudioObjectPropertyOwnedObjects: return WriteIDs(NULL, 0, inDataSize, outDataSize, outData);
    case kAudioStreamPropertyIsActive: WRITE(UInt32, 1);
    case kAudioStreamPropertyDirection: WRITE(UInt32, input ? 1 : 0);
    case kAudioStreamPropertyTerminalType:
        WRITE(UInt32, input ? kAudioStreamTerminalTypeMicrophone : kAudioStreamTerminalTypeSpeaker);
    case kAudioStreamPropertyStartingChannel: WRITE(UInt32, 1);
    case kAudioStreamPropertyLatency: WRITE(UInt32, 0);
    case kAudioStreamPropertyVirtualFormat:
    case kAudioStreamPropertyPhysicalFormat: WRITE(AudioStreamBasicDescription, StreamFormat());
    case kAudioStreamPropertyAvailableVirtualFormats:
    case kAudioStreamPropertyAvailablePhysicalFormats: {
        AudioStreamRangedDescription r;
        r.mFormat = StreamFormat();
        r.mSampleRateRange.mMinimum = kSampleRate;
        r.mSampleRateRange.mMaximum = kSampleRate;
        WRITE(AudioStreamRangedDescription, r);
    }
    default: return kAudioHardwareUnknownPropertyError;
    }
}

static OSStatus Property(AudioObjectID obj, const AudioObjectPropertyAddress* a, UInt32 qSize, const void* q,
                         UInt32 inDataSize, UInt32* outDataSize, void* outData) {
    if (a == NULL || outDataSize == NULL) return kAudioHardwareIllegalOperationError;
    if (obj == kObjectID_PlugIn) return PlugInProperty(a, qSize, q, inDataSize, outDataSize, outData);
    if (IsDevice(obj)) return DeviceProperty(obj, a, inDataSize, outDataSize, outData);
    if (IsStream(obj)) return StreamProperty(obj, a, inDataSize, outDataSize, outData);
    return kAudioHardwareBadObjectError;
}

static Boolean MD_HasProperty(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID,
                              const AudioObjectPropertyAddress* inAddress) {
    (void)inClientProcessID;
    if (inDriver != gDriverRef) return false;
    UInt32 size = 0;
    return Property(inObjectID, inAddress, 0, NULL, 0, &size, NULL) == 0;
}

static OSStatus MD_IsPropertySettable(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID,
                                      const AudioObjectPropertyAddress* inAddress, Boolean* outIsSettable) {
    (void)inClientProcessID;
    if (inDriver != gDriverRef || outIsSettable == NULL) return kAudioHardwareBadObjectError;
    UInt32 size = 0;
    OSStatus err = Property(inObjectID, inAddress, 0, NULL, 0, &size, NULL);
    if (err) return err;
    *outIsSettable = false;   // fixed format, no controls
    return 0;
}

static OSStatus MD_GetPropertyDataSize(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID,
                                       const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize,
                                       const void* inQualifierData, UInt32* outDataSize) {
    (void)inClientProcessID;
    if (inDriver != gDriverRef) return kAudioHardwareBadObjectError;
    return Property(inObjectID, inAddress, inQualifierDataSize, inQualifierData, 0, outDataSize, NULL);
}

static OSStatus MD_GetPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID,
                                   const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize,
                                   const void* inQualifierData, UInt32 inDataSize, UInt32* outDataSize, void* outData) {
    (void)inClientProcessID;
    if (inDriver != gDriverRef) return kAudioHardwareBadObjectError;
    if (outData == NULL) return kAudioHardwareIllegalOperationError;
    return Property(inObjectID, inAddress, inQualifierDataSize, inQualifierData, inDataSize, outDataSize, outData);
}

static OSStatus MD_SetPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID,
                                   const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize,
                                   const void* inQualifierData, UInt32 inDataSize, const void* inData) {
    (void)inDriver; (void)inObjectID; (void)inClientProcessID; (void)inAddress;
    (void)inQualifierDataSize; (void)inQualifierData; (void)inDataSize; (void)inData;
    return kAudioHardwareUnsupportedOperationError;
}

// MARK: - IO

static OSStatus MD_StartIO(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID) {
    (void)inClientID;
    if (inDriver != gDriverRef || !IsDevice(inDeviceObjectID)) return kAudioHardwareBadObjectError;
    bool becameRunning;
    pthread_mutex_lock(&gMutex);
    if (gMicIOCount + gFeedIOCount == 0) {
        // First IO on either device: start the shared clock with an empty ring.
        memset(gRing, 0, sizeof(gRing));
        atomic_store(&gFeedWrittenUntil, -1);
        atomic_store(&gAnchorHostTime, mach_absolute_time());
    }
    UInt32* count = DeviceIsInput(inDeviceObjectID) ? &gMicIOCount : &gFeedIOCount;
    becameRunning = (*count)++ == 0;
    if (inDeviceObjectID == kObjectID_Feed) atomic_store(&gFeedRunning, true);
    pthread_mutex_unlock(&gMutex);
    if (becameRunning) NotifyRunningChanged(inDeviceObjectID);
    return 0;
}

static OSStatus MD_StopIO(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID) {
    (void)inClientID;
    if (inDriver != gDriverRef || !IsDevice(inDeviceObjectID)) return kAudioHardwareBadObjectError;
    bool stopped = false;
    pthread_mutex_lock(&gMutex);
    UInt32* count = DeviceIsInput(inDeviceObjectID) ? &gMicIOCount : &gFeedIOCount;
    if (*count > 0) {
        (*count)--;
        stopped = *count == 0;
    }
    if (inDeviceObjectID == kObjectID_Feed && gFeedIOCount == 0) {
        atomic_store(&gFeedRunning, false);
        atomic_store(&gFeedWrittenUntil, -1);
    }
    pthread_mutex_unlock(&gMutex);
    if (stopped) NotifyRunningChanged(inDeviceObjectID);
    return 0;
}

static OSStatus MD_GetZeroTimeStamp(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID,
                                    Float64* outSampleTime, UInt64* outHostTime, UInt64* outSeed) {
    (void)inClientID;
    if (inDriver != gDriverRef || !IsDevice(inDeviceObjectID)) return kAudioHardwareBadObjectError;
    // Both devices derive their time stamps from the same anchor, so their sample times line up.
    UInt64 anchor = atomic_load(&gAnchorHostTime);
    UInt64 now = mach_absolute_time();
    Float64 ticksPerRing = gTicksPerFrame * kRingFrames;
    UInt64 cycles = now > anchor ? (UInt64)((Float64)(now - anchor) / ticksPerRing) : 0;
    *outSampleTime = (Float64)(cycles * kRingFrames);
    *outHostTime = anchor + (UInt64)((Float64)cycles * ticksPerRing);
    *outSeed = 1;
    return 0;
}

static OSStatus MD_WillDoIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID,
                                     UInt32 inOperationID, Boolean* outWillDo, Boolean* outWillDoInPlace) {
    (void)inClientID;
    if (inDriver != gDriverRef || !IsDevice(inDeviceObjectID)) return kAudioHardwareBadObjectError;
    bool will = DeviceIsInput(inDeviceObjectID) ? inOperationID == kAudioServerPlugInIOOperationReadInput
                                                : inOperationID == kAudioServerPlugInIOOperationWriteMix;
    if (outWillDo) *outWillDo = will;
    if (outWillDoInPlace) *outWillDoInPlace = true;
    return 0;
}

static OSStatus MD_BeginIOOperation(AudioServerPlugInDriverRef d, AudioObjectID id, UInt32 c, UInt32 op, UInt32 n,
                                    const AudioServerPlugInIOCycleInfo* info) {
    (void)d; (void)id; (void)c; (void)op; (void)n; (void)info;
    return 0;
}
static OSStatus MD_EndIOOperation(AudioServerPlugInDriverRef d, AudioObjectID id, UInt32 c, UInt32 op, UInt32 n,
                                  const AudioServerPlugInIOCycleInfo* info) {
    (void)d; (void)id; (void)c; (void)op; (void)n; (void)info;
    return 0;
}

static OSStatus MD_DoIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, AudioObjectID inStreamObjectID,
                                 UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize,
                                 const AudioServerPlugInIOCycleInfo* inIOCycleInfo, void* ioMainBuffer, void* ioSecondaryBuffer) {
    (void)inClientID; (void)inStreamObjectID; (void)ioSecondaryBuffer;
    if (inDriver != gDriverRef || ioMainBuffer == NULL || inIOCycleInfo == NULL) return kAudioHardwareBadObjectError;
    Float32* buf = ioMainBuffer;
    UInt32 frames = inIOBufferFrameSize;
    if (frames > kRingFrames) frames = kRingFrames;

    if (inDeviceObjectID == kObjectID_Feed && inOperationID == kAudioServerPlugInIOOperationWriteMix) {
        SInt64 t = (SInt64)inIOCycleInfo->mOutputTime.mSampleTime;
        if (t < 0) return 0;
        for (UInt32 i = 0; i < frames; i++) gRing[(UInt64)(t + i) % kRingFrames] = buf[i];
        atomic_store(&gFeedWrittenUntil, t + frames);
        return 0;
    }

    if (inDeviceObjectID == kObjectID_Mic && inOperationID == kAudioServerPlugInIOOperationReadInput) {
        SInt64 s = (SInt64)inIOCycleInfo->mInputTime.mSampleTime;
        SInt64 written = atomic_load(&gFeedWrittenUntil);
        // Silence unless MicDeck has written this span and hasn't lapped it: never replay stale audio.
        if (!atomic_load(&gFeedRunning) || s < 0 || written < s + frames || written - s > kRingFrames) {
            memset(buf, 0, frames * sizeof(Float32));
            return 0;
        }
        for (UInt32 i = 0; i < frames; i++) buf[i] = gRing[(UInt64)(s + i) % kRingFrames];
        return 0;
    }
    return 0;
}
