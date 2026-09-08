#include "mesh_noise_processor.h"
#include <array>
#include <cstdio>
#include <cstdlib>
#include <limits>

static void check(bool ok) { if (!ok) std::abort(); }
int main() {
  using flutter_webrtc_plugin::MeshNoiseProcessor;
  MeshNoiseProcessor processor;
  std::array<float, 480> samples;
  samples.fill(100);
  processor.Initialize(48000, 1);
  processor.Process(3, 480, 480, samples.data());
  check(samples[0] == 100 && processor.processed == 0);
  processor.SetEnabled(true);
  processor.Process(3, 480, 480, samples.data());
  check(processor.processed == 1);
  processor.Initialize(16000, 1);
  samples.fill(100);
  processor.Process(1, 160, 160, samples.data());
  check(samples[0] == 100 && processor.bypassed == 1);
  processor.Initialize(48000, 2);
  processor.Process(3, 480, 480, samples.data());
  check(samples[0] == 100 && processor.bypassed == 2);
  processor.Initialize(48000, 1);
  samples.fill(std::numeric_limits<float>::quiet_NaN());
  processor.Process(3, 480, 480, samples.data());
  for (float value : samples) check(std::isfinite(value));
  processor.SetEnabled(false);
  processor.SetEnabled(true);
  samples.fill(0);
  processor.Process(3, 480, 480, samples.data());
  for (float value : samples) check(std::abs(value) < 0.001f);
  std::puts("adapter: bypass, mono, frame format, finite PCM and call reset passed");
}
