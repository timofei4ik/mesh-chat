#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <time.h>
#include "rnnoise.h"

int main(void) {
  float frame[480] = {0};
  double input_energy = 0, output_energy = 0;
  uint32_t seed = 12345;
  DenoiseState *state = rnnoise_create(NULL);
  if (!state) return 1;
  for (int block = 0; block < 200; ++block) {
    rnnoise_process_frame(state, frame, frame);
    for (int i = 0; i < 480; ++i) if (!isfinite(frame[i]) || fabsf(frame[i]) > .01f) return 2;
  }
  const clock_t start = clock();
  for (int block = 0; block < 2000; ++block) {
    for (int i = 0; i < 480; ++i) {
      seed = 1664525u * seed + 1013904223u;
      frame[i] = ((int)(seed >> 16) - 32768) * .03f;
      if (block >= 200) input_energy += frame[i] * frame[i];
    }
    rnnoise_process_frame(state, frame, frame);
    for (int i = 0; i < 480; ++i) {
      if (!isfinite(frame[i]) || fabsf(frame[i]) > 32768.f) return 3;
      if (block >= 200) output_energy += frame[i] * frame[i];
    }
  }
  const double ms = 1000. * (clock() - start) / CLOCKS_PER_SEC / 2000;
  const double reduction = 10 * log10(input_energy / fmax(output_energy, 1e-12));
  printf("silence=ok finite_pcm=ok noise_reduction_db=%.2f ms_per_10ms_frame=%.3f\n", reduction, ms);
  rnnoise_destroy(state);
  return reduction > 3 ? 0 : 4;
}
