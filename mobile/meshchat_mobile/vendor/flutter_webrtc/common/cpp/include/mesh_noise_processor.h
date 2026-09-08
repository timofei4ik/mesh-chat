#pragma once
#include <atomic>
#include <cmath>
#include "rtc_audio_processing.h"
#include "rnnoise.h"

namespace flutter_webrtc_plugin {
class MeshNoiseProcessor final : public libwebrtc::RTCAudioProcessing::CustomProcessing {
 public:
  MeshNoiseProcessor() : state_(rnnoise_create(nullptr)) {}
  ~MeshNoiseProcessor() override { rnnoise_destroy(state_); }
  void Initialize(int rate, int channels) override {
    channels_ = channels;
    Reset(rate);
  }
  void Reset(int rate) override {
    rate_ = rate;
    rnnoise_destroy(state_);
    state_ = rnnoise_create(nullptr);
  }
  void Process(int, int frames, int size, float* samples) override {
    if (!enabled.load()) return;
    if (reset_pending.exchange(false)) Reset(rate_);
    if (!state_ || channels_ != 1 || rate_ != 48000 || frames != 480 ||
        size < 480 || !samples) {
      ++bypassed;
      return;
    }
    for (int i = 0; i < frames; ++i)
      if (!std::isfinite(samples[i])) samples[i] = 0;
    rnnoise_process_frame(state_, samples, samples);
    for (int i = 0; i < frames; ++i) {
      const float value = samples[i];
      samples[i] = !std::isfinite(value) ? 0 :
          (value > 32767 ? 32767 : (value < -32768 ? -32768 : value));
    }
    ++processed;
  }
  void Release() override {}
  void SetEnabled(bool value) {
    if (value && !enabled.load()) reset_pending.store(true);
    enabled.store(value);
  }
  std::atomic<bool> enabled{false};
  std::atomic<int64_t> processed{0}, bypassed{0};
 private:
  DenoiseState* state_;
  std::atomic<bool> reset_pending{false};
  int rate_ = 0, channels_ = 0;
};

// The SDK requires a non-null replacement even when detaching a processor.
class MeshNoiseBypass final : public libwebrtc::RTCAudioProcessing::CustomProcessing {
 public:
  void Initialize(int, int) override {}
  void Reset(int) override {}
  void Process(int, int, int, float*) override {}
  void Release() override {}
};
}  // namespace flutter_webrtc_plugin
