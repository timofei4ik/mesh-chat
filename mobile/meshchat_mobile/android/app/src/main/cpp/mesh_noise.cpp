#include <jni.h>
#include <cmath>
#include <cstdint>
#include "rnnoise.h"

extern "C" JNIEXPORT jlong JNICALL
Java_com_meshchat_meshchat_1mobile_MeshNoiseProcessor_create(JNIEnv*, jobject) {
  return reinterpret_cast<jlong>(rnnoise_create(nullptr));
}

extern "C" JNIEXPORT void JNICALL
Java_com_meshchat_meshchat_1mobile_MeshNoiseProcessor_destroy(JNIEnv*, jobject, jlong handle) {
  if (handle) rnnoise_destroy(reinterpret_cast<DenoiseState*>(handle));
}

extern "C" JNIEXPORT jboolean JNICALL
Java_com_meshchat_meshchat_1mobile_MeshNoiseProcessor_processFrame(
    JNIEnv* env, jobject, jlong handle, jobject buffer, jint frames) {
  if (!handle || !buffer || frames != 480 || env->GetDirectBufferCapacity(buffer) < 480 * 4)
    return JNI_FALSE;
  auto* samples = static_cast<float*>(env->GetDirectBufferAddress(buffer));
  if (!samples) return JNI_FALSE;
  // WebRTC AudioBuffer and RNNoise both use float samples in the PCM16 range.
  // Never forward a NaN from an audio driver into the recurrent state.
  for (int i = 0; i < 480; ++i) if (!std::isfinite(samples[i])) samples[i] = 0;
  rnnoise_process_frame(reinterpret_cast<DenoiseState*>(handle), samples, samples);
  for (int i = 0; i < 480; ++i) {
    samples[i] = std::isfinite(samples[i]) ? std::fmax(-32768.f, std::fmin(32767.f, samples[i])) : 0.f;
  }
  return JNI_TRUE;
}
