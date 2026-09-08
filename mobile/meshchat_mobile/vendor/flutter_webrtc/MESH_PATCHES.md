# MeshChat audio patch

Based on flutter_webrtc 1.6.0. Keep the upstream LICENSE and dependency versions.
Windows and iOS expose meshNoiseConfigure / meshNoiseStatus on the existing
FlutterWebRTC.Method channel. The filter processes capture audio after WebRTC's
echo cancellation; render audio is unchanged. Android uses the plugin's existing
ExternalAudioFrameProcessing API from the application bridge.

RNNoise 0.1.1, commit 6cbfd53eb348a8d394e0757b4025c6ded34eb2b6, is bundled with
its compact built-in model and BSD license under ios/.../MeshRNNoise. Windows
compiles the same source. MSVC-only stack allocation shims replace C99 VLAs;
the algorithm and weights are unchanged. No network or API key is involved.

Only 48 kHz mono, 480-frame capture blocks are filtered. Other formats retain
baseline WebRTC processing. Diagnostics distinguish attached, processed and
bypassed frames: attached alone is not proof that audio has been filtered.

Do not commit third_party/downloads, third_party/libwebrtc, or build caches.
