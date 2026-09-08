#import "MeshNoiseProcessor.h"
#include "MeshRNNoise/include/rnnoise.h"
#include <atomic>
#include <cmath>

@implementation MeshNoiseProcessor {
  DenoiseState* _state;
  std::atomic<uint64_t> _processed;
  std::atomic<uint64_t> _bypassed;
}
- (instancetype)init {
  self = [super init];
  if (self) {
    _state = rnnoise_create(nullptr);
    _processed = 0;
    _bypassed = 0;
  }
  return self;
}
- (void)audioProcessingInitializeWithSampleRate:(size_t)rate channels:(size_t)channels {
  rnnoise_destroy(_state);
  _state = rnnoise_create(nullptr);
}
- (void)audioProcessingProcess:(RTC_OBJC_TYPE(RTCAudioBuffer)*)buffer {
  if (!_state || buffer.frames != 480 || buffer.channels != 1) {
    ++_bypassed;
    return;
  }
  float* samples = [buffer rawBufferForChannel:0];
  if (!samples) { ++_bypassed; return; }
  for (int i = 0; i < 480; ++i)
    if (!std::isfinite(samples[i])) samples[i] = 0;
  rnnoise_process_frame(_state, samples, samples);
  for (int i = 0; i < 480; ++i) {
    const float value = samples[i];
    samples[i] = !std::isfinite(value) ? 0 :
        (value > 32767 ? 32767 : (value < -32768 ? -32768 : value));
  }
  ++_processed;
}
- (void)audioProcessingRelease {
  rnnoise_destroy(_state);
  _state = nullptr;
}
- (NSDictionary*)status {
  return @{@"supported": @YES, @"attached": @YES,
           @"processed_frames": @(_processed.load()),
           @"bypassed_frames": @(_bypassed.load())};
}
- (void)dealloc { rnnoise_destroy(_state); }
@end
