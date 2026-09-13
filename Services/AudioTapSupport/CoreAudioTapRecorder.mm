#import "CoreAudioTapRecorder.h"
#import <AudioToolbox/ExtendedAudioFile.h>
#include <atomic>
#include <algorithm>
#include <chrono>
#include <cmath>
#include <mach/mach_time.h>
#include <memory>
#include <thread>

static OSStatus QAPiaAudioIOProc(AudioObjectID,
                                 const AudioTimeStamp *,
                                 const AudioBufferList *inputData,
                                 const AudioTimeStamp *,
                                 AudioBufferList *,
                                 const AudioTimeStamp *,
                                 void *clientData) noexcept;

static void QAPiaStoreFirstError(std::atomic<OSStatus> &destination, OSStatus status) noexcept {
    if (status == noErr) { return; }
    OSStatus expected = noErr;
    destination.compare_exchange_strong(
        expected,
        status,
        std::memory_order_release,
        std::memory_order_relaxed
    );
}

static constexpr uint64_t QAPiaCallbackAcceptingBit = uint64_t{1} << 63;
static constexpr uint64_t QAPiaCallbackCountMask = ~QAPiaCallbackAcceptingBit;

class QAPiaCallbackGuard final {
public:
    explicit QAPiaCallbackGuard(std::atomic<uint64_t> &callbackState) noexcept
        : _callbackState(callbackState), _isAcquired(false) {
        uint64_t state = _callbackState.load(std::memory_order_acquire);
        while ((state & QAPiaCallbackAcceptingBit) != 0) {
            if ((state & QAPiaCallbackCountMask) == QAPiaCallbackCountMask) { return; }
            if (_callbackState.compare_exchange_weak(
                    state,
                    state + 1,
                    std::memory_order_acq_rel,
                    std::memory_order_acquire)) {
                _isAcquired = true;
                return;
            }
        }
    }

    ~QAPiaCallbackGuard() noexcept {
        if (_isAcquired) {
            _callbackState.fetch_sub(1, std::memory_order_release);
        }
    }

    bool isAcquired() const noexcept { return _isAcquired; }

    QAPiaCallbackGuard(const QAPiaCallbackGuard &) = delete;
    QAPiaCallbackGuard &operator=(const QAPiaCallbackGuard &) = delete;

private:
    std::atomic<uint64_t> &_callbackState;
    bool _isAcquired;
};

static bool QAPiaDeriveFrameCount(const AudioBufferList *inputData,
                                  const AudioStreamBasicDescription &format,
                                  UInt32 &frameCount) noexcept {
    frameCount = 0;
    if (inputData == nullptr ||
        inputData->mNumberBuffers == 0 ||
        format.mBytesPerFrame == 0 ||
        format.mChannelsPerFrame == 0) {
        return false;
    }

    const bool nonInterleaved =
        (format.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0;
    if (nonInterleaved) {
        if (inputData->mNumberBuffers != format.mChannelsPerFrame) { return false; }
    } else if (inputData->mNumberBuffers != 1 ||
               inputData->mBuffers[0].mNumberChannels != format.mChannelsPerFrame) {
        return false;
    }

    UInt32 resolvedFrameCount = 0;
    for (UInt32 index = 0; index < inputData->mNumberBuffers; ++index) {
        const AudioBuffer &buffer = inputData->mBuffers[index];
        if (buffer.mData == nullptr ||
            buffer.mDataByteSize == 0 ||
            buffer.mNumberChannels == 0 ||
            (nonInterleaved && buffer.mNumberChannels != 1) ||
            buffer.mDataByteSize % format.mBytesPerFrame != 0) {
            return false;
        }

        const UInt32 bufferFrameCount = buffer.mDataByteSize / format.mBytesPerFrame;
        if (bufferFrameCount == 0 ||
            (resolvedFrameCount != 0 && bufferFrameCount != resolvedFrameCount)) {
            return false;
        }
        resolvedFrameCount = bufferFrameCount;
    }

    frameCount = resolvedFrameCount;
    return frameCount > 0;
}

static bool QAPiaSupportsFloat32RMS(const AudioStreamBasicDescription &format) noexcept {
    if (format.mFormatID != kAudioFormatLinearPCM ||
        (format.mFormatFlags & kAudioFormatFlagIsFloat) == 0 ||
        (format.mFormatFlags & kAudioFormatFlagIsBigEndian) != 0 ||
        format.mBitsPerChannel != sizeof(Float32) * 8) {
        return false;
    }

    const bool nonInterleaved =
        (format.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0;
    const UInt32 expectedBytesPerFrame = nonInterleaved
        ? UInt32(sizeof(Float32))
        : UInt32(sizeof(Float32)) * format.mChannelsPerFrame;
    return format.mBytesPerFrame == expectedBytesPerFrame;
}

static float QAPiaFloat32RMS(const AudioBufferList *inputData) noexcept {
    double sum = 0;
    uint64_t sampleCount = 0;
    for (UInt32 bufferIndex = 0; bufferIndex < inputData->mNumberBuffers; ++bufferIndex) {
        const AudioBuffer &buffer = inputData->mBuffers[bufferIndex];
        const auto *samples = static_cast<const Float32 *>(buffer.mData);
        const UInt32 bufferSampleCount = buffer.mDataByteSize / sizeof(Float32);
        for (UInt32 sampleIndex = 0; sampleIndex < bufferSampleCount; ++sampleIndex) {
            const float sample = samples[sampleIndex];
            if (!std::isfinite(sample)) { continue; }
            sum += static_cast<double>(sample) * sample;
            ++sampleCount;
        }
    }
    return sampleCount > 0
        ? static_cast<float>(std::sqrt(sum / static_cast<double>(sampleCount)))
        : 0;
}

@interface CoreAudioTapRecorder () {
    NSURL *_url;
    AudioObjectID _deviceID;
    AudioDeviceIOProcID _ioProcID;
    ExtAudioFileRef _file;
    AudioStreamBasicDescription _streamFormat;
    std::atomic<float> _audioLevel;
    std::atomic<uint64_t> _recordedFrameCount;
    std::atomic<uint64_t> _lastAudioCallbackTime;
    std::atomic<OSStatus> _lastWriteError;
    // The high bit gates new callbacks; the remaining bits count callbacks in flight.
    // Keeping both values in one atomic closes the check/increment race during stop.
    std::atomic<uint64_t> _callbackState;
}
- (void)processInputData:(const AudioBufferList *)inputData;
@end

@implementation CoreAudioTapRecorder

- (instancetype)initWithURL:(NSURL *)url {
    self = [super init];
    if (self) {
        _url = url;
        _deviceID = kAudioObjectUnknown;
        _ioProcID = nullptr;
        _file = nullptr;
        _streamFormat = {};
        _audioLevel.store(0);
        _recordedFrameCount.store(0);
        _lastAudioCallbackTime.store(0);
        _lastWriteError.store(noErr);
        _callbackState.store(0);
    }
    return self;
}

- (uint64_t)recordedFrameCount {
    return _recordedFrameCount.load(std::memory_order_relaxed);
}

- (OSStatus)lastWriteError {
    return _lastWriteError.load(std::memory_order_acquire);
}

- (float)audioLevel {
    const uint64_t updatedAt = _lastAudioCallbackTime.load(std::memory_order_relaxed);
    if (updatedAt == 0) { return 0; }
    mach_timebase_info_data_t timebase = {};
    mach_timebase_info(&timebase);
    const uint64_t elapsedTicks = mach_continuous_time() - updatedAt;
    const long double elapsedNanoseconds =
        static_cast<long double>(elapsedTicks) * timebase.numer / timebase.denom;
    if (elapsedNanoseconds > 350000000.0L) { return 0; }
    return _audioLevel.load(std::memory_order_relaxed);
}

- (BOOL)startWithDeviceID:(AudioObjectID)deviceID error:(NSError **)error {
    [self stop];
    _streamFormat = {};
    _audioLevel.store(0, std::memory_order_relaxed);
    _recordedFrameCount.store(0, std::memory_order_relaxed);
    _lastAudioCallbackTime.store(0, std::memory_order_relaxed);
    _lastWriteError.store(noErr, std::memory_order_release);
    _callbackState.store(0, std::memory_order_relaxed);
    _deviceID = deviceID;

    AudioObjectPropertyAddress streamsAddress = {
        kAudioDevicePropertyStreams,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain
    };
    AudioStreamBasicDescription format = {};
    BOOL foundInput = NO;
    OSStatus status = noErr;
    for (UInt32 attempt = 0; attempt < 100 && !foundInput; ++attempt) {
        UInt32 streamListSize = 0;
        status = AudioObjectGetPropertyDataSize(deviceID, &streamsAddress, 0, nullptr, &streamListSize);
        if (status == noErr && streamListSize > 0) {
            const UInt32 streamCount = streamListSize / sizeof(AudioObjectID);
            auto streams = std::make_unique<AudioObjectID[]>(streamCount);
            status = AudioObjectGetPropertyData(deviceID, &streamsAddress, 0, nullptr, &streamListSize, streams.get());
            if (status == noErr) {
                for (UInt32 index = 0; index < streamCount; ++index) {
                    AudioObjectPropertyAddress directionAddress = {
                        kAudioStreamPropertyDirection,
                        kAudioObjectPropertyScopeGlobal,
                        kAudioObjectPropertyElementMain
                    };
                    UInt32 direction = 0;
                    UInt32 directionSize = sizeof(direction);
                    status = AudioObjectGetPropertyData(
                        streams[index],
                        &directionAddress,
                        0,
                        nullptr,
                        &directionSize,
                        &direction
                    );
                    if (status != noErr || direction == 0) { continue; }

                    AudioObjectPropertyAddress formatAddress = {
                        kAudioStreamPropertyVirtualFormat,
                        kAudioObjectPropertyScopeGlobal,
                        kAudioObjectPropertyElementMain
                    };
                    UInt32 formatSize = sizeof(format);
                    status = AudioObjectGetPropertyData(
                        streams[index],
                        &formatAddress,
                        0,
                        nullptr,
                        &formatSize,
                        &format
                    );
                    if (status == noErr) {
                        foundInput = YES;
                        break;
                    }
                }
            }
        }

        if (!foundInput) {
            std::this_thread::sleep_for(std::chrono::milliseconds(10));
        }
    }
    if (!foundInput) {
        const OSStatus reportedStatus = status == noErr ? kAudioHardwareNotReadyError : status;
        return [self failWithStatus:reportedStatus message:@"O tap de áudio não disponibilizou um stream de entrada." error:error];
    }
    _streamFormat = format;

    status = ExtAudioFileCreateWithURL((__bridge CFURLRef)_url,
                                       kAudioFileCAFType,
                                       &format,
                                       nullptr,
                                       kAudioFileFlags_EraseFile,
                                       &_file);
    if (status != noErr) {
        return [self failWithStatus:status message:@"Não foi possível preparar o arquivo de áudio do sistema." error:error];
    }
    status = ExtAudioFileWriteAsync(_file, 0, nullptr);
    if (status != noErr) {
        QAPiaStoreFirstError(_lastWriteError, status);
        [self stop];
        return [self failWithStatus:status message:@"Não foi possível inicializar a gravação do áudio do sistema." error:error];
    }

    status = AudioDeviceCreateIOProcID(deviceID, QAPiaAudioIOProc, (__bridge void *)self, &_ioProcID);
    if (status != noErr) {
        [self stop];
        return [self failWithStatus:status message:@"Não foi possível preparar a captura do áudio do sistema." error:error];
    }
    _callbackState.store(QAPiaCallbackAcceptingBit, std::memory_order_release);
    status = AudioDeviceStart(deviceID, _ioProcID);
    if (status != noErr) {
        [self stop];
        return [self failWithStatus:status message:@"A captura do áudio do sistema não pôde ser iniciada." error:error];
    }
    return YES;
}

- (void)stop {
    _callbackState.fetch_and(QAPiaCallbackCountMask, std::memory_order_acq_rel);
    if (_deviceID != kAudioObjectUnknown && _ioProcID != nullptr) {
        AudioDeviceStop(_deviceID, _ioProcID);
        AudioDeviceDestroyIOProcID(_deviceID, _ioProcID);
    }
    _ioProcID = nullptr;
    _deviceID = kAudioObjectUnknown;
    while ((_callbackState.load(std::memory_order_acquire) & QAPiaCallbackCountMask) != 0) {
        std::this_thread::yield();
    }
    if (_file != nullptr) {
        const OSStatus pendingWriteStatus = ExtAudioFileWriteAsync(_file, 0, nullptr);
        QAPiaStoreFirstError(_lastWriteError, pendingWriteStatus);
        const OSStatus disposeStatus = ExtAudioFileDispose(_file);
        QAPiaStoreFirstError(_lastWriteError, disposeStatus);
        _file = nullptr;
    }
    _streamFormat = {};
    _audioLevel.store(0, std::memory_order_relaxed);
    _lastAudioCallbackTime.store(0, std::memory_order_relaxed);
}

- (BOOL)failWithStatus:(OSStatus)status message:(NSString *)message error:(NSError **)error {
    if (error) {
        *error = [NSError errorWithDomain:@"br.com.qapia.audio-tap"
                                     code:status
                                 userInfo:@{NSLocalizedDescriptionKey: message}];
    }
    return NO;
}

- (void)dealloc {
    [self stop];
}

- (void)processInputData:(const AudioBufferList *)inputData {
    QAPiaCallbackGuard callbackGuard(_callbackState);
    if (!callbackGuard.isAcquired()) { return; }

    UInt32 frameCount = 0;
    if (!QAPiaDeriveFrameCount(inputData, _streamFormat, frameCount)) {
        QAPiaStoreFirstError(_lastWriteError, kAudio_ParamError);
        _audioLevel.store(0, std::memory_order_relaxed);
        _lastAudioCallbackTime.store(mach_continuous_time(), std::memory_order_relaxed);
        return;
    }

    if (_file == nullptr) {
        QAPiaStoreFirstError(_lastWriteError, kAudio_ParamError);
        return;
    }
    const OSStatus writeStatus = ExtAudioFileWriteAsync(_file, frameCount, inputData);
    if (writeStatus != noErr) {
        QAPiaStoreFirstError(_lastWriteError, writeStatus);
        _audioLevel.store(0, std::memory_order_relaxed);
        _lastAudioCallbackTime.store(mach_continuous_time(), std::memory_order_relaxed);
        return;
    }
    _recordedFrameCount.fetch_add(frameCount, std::memory_order_relaxed);

    const float rms = QAPiaSupportsFloat32RMS(_streamFormat)
        ? QAPiaFloat32RMS(inputData)
        : 0;
    const float rawLevel = (20.0f * std::log10(std::max(rms, 0.000001f)) + 60.0f) / 60.0f;
    const float normalized = std::fmin(std::fmax(rawLevel, 0.0f), 1.0f);
    _audioLevel.store(normalized, std::memory_order_relaxed);
    _lastAudioCallbackTime.store(mach_continuous_time(), std::memory_order_relaxed);
}

@end

static OSStatus QAPiaAudioIOProc(AudioObjectID,
                                 const AudioTimeStamp *,
                                 const AudioBufferList *inputData,
                                 const AudioTimeStamp *,
                                 AudioBufferList *,
                                 const AudioTimeStamp *,
                                 void *clientData) noexcept {
    // The serialized owner keeps the recorder alive through stop; avoid retain/release on the RT thread.
    CoreAudioTapRecorder *__unsafe_unretained recorder =
        (__bridge CoreAudioTapRecorder *)clientData;
    if (recorder == nil) { return noErr; }
    [recorder processInputData:inputData];
    return noErr;
}
