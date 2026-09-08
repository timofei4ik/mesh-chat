# RNNoise

Unmodified runtime C sources and embedded compact model from Xiph RNNoise v0.1.1,
commit 6cbfd53eb348a8d394e0757b4025c6ded34eb2b6.

Source: https://github.com/xiph/rnnoise/tree/6cbfd53eb348a8d394e0757b4025c6ded34eb2b6
License: COPYING (BSD-3-Clause), also shipped in assets/licenses/rnnoise.txt.

The compact reference model was chosen for mobile CPU/memory cost. It is not
Krisp or the newer, substantially larger RNNoise v0.2 model. No runtime model
download, external inference service, voice upload or Dart PCM processing.

The Android adapter processes full-band mono PCM16-range float samples in 480
sample blocks (10 ms at 48 kHz). WebRTC capturePostProcessing runs after its APM;
AEC remains enabled. Other formats bypass RNNoise and keep WebRTC suppression.
No VAD hard gate or speech-probability threshold is used, to avoid chopping words.
