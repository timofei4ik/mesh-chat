# Local call noise suppression

Noise suppression is available to every account in the ordinary privacy/call
settings, enabled by default on Android, Windows and iOS. Its local preference
is independent of legacy MeshPro subscription preferences. Basic WebRTC echo cancellation, noise suppression,
gain control and high-pass filtering remain the baseline. No microphone audio
is uploaded to a transcription/AI service for noise filtering.

Android uses its native capture-post-processing adapter and JNI. Windows and
iOS use the checked-in flutter_webrtc 1.6.0 patch, selected by pubspec's local
override. This override is also required in staging and Codemagic checkouts.
Windows and iOS share the compact RNNoise reference implementation and model;
Android bundles the same upstream algorithm. Licenses are shown by Flutter's
license registry. See vendor/flutter_webrtc/MESH_PATCHES.md for provenance.

Capture blocks must be 48 kHz mono (480 samples / 10 ms). Unsupported routes
keep WebRTC processing and bypass RNNoise instead of muting or corrupting audio.
CallNoiseSuppression.status() reports attachment and processed/bypassed frame
counts. Attachment is not a claim of successfully filtered audio. Bluetooth
routes must be checked for their negotiated format on real devices.

Each peer connection owns a separate filter lease. The final enhanced call
releases the process-wide filter. Windows resets recurrent state on a new
enable cycle; Android/iOS remove and release their processors under the SDK's
audio-processor lock. Only capture audio is filtered, never the remote render
stream. This does not replace acoustic echo cancellation or promise Krisp's
performance on keyboard noise, music, clipping or poor speaker placement.

## Verification

- Flutter unit tests cover constraints, all three native dispatch paths,
  multiple concurrent owners, duplicate acquisition and unavailable plugins.
- test/native_noise contains a deterministic C noise/silence benchmark and a
  Windows C++ adapter test (bypass, mono, rate, non-finite samples, call reset).
- Windows and Android native compilation must pass before distributing builds.
- iOS requires CocoaPods/SPM compilation on macOS/Codemagic, then an iPhone call.

Before release, compare enabled/disabled audio with speech plus fan/keyboard
noise on a physical Android phone, Windows computer and iPhone. Include quiet
speech, long sentences, speakerphone, headphones, Bluetooth, input-device
changes, repeated calls, a group call and a final hang-up. Verify that speech is
not clipped, echo cancellation remains effective and no prior-call audio leaks.
