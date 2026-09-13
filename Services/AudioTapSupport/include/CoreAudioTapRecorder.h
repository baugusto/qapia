#import <Foundation/Foundation.h>
#import <CoreAudio/CoreAudio.h>

NS_ASSUME_NONNULL_BEGIN

/// Ponte Objective-C++ mínima para executar o IOProc em tempo real com segurança.
@interface CoreAudioTapRecorder : NSObject

- (instancetype)initWithURL:(NSURL *)url;
- (BOOL)startWithDeviceID:(AudioObjectID)deviceID error:(NSError **)error;
- (void)stop;

@property(nonatomic, readonly) float audioLevel;
/// Frames aceitos pelo escritor na sessão atual. O valor é zerado no próximo início.
@property(nonatomic, readonly) uint64_t recordedFrameCount;
/// Primeiro erro de escrita/finalização da sessão atual. `noErr` quando não houve erro.
/// O valor permanece disponível depois de `stop` e é zerado no próximo `startWithDeviceID`.
@property(nonatomic, readonly) OSStatus lastWriteError;

@end

NS_ASSUME_NONNULL_END
