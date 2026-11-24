#!/bin/bash
set -euo pipefail
ROOT=$(CDPATH='' cd -- "$(/usr/bin/dirname "$0")/../.." && pwd -P)
if [[ $# == 0 ]]; then
  # Use the same host gates, deadline and clean compiler environment as packaging.
  exec /bin/bash "$ROOT/scripts/build-aec3-xcframework.sh" --smoke
fi
if [[ $# != 1 || $1 != --emit-c ]]; then
  echo 'usage: scripts/tests/test-aec3-shim.sh' >&2
  exit 2
fi
# The driver builds this consumer in a fresh directory for either smoke phase.
/bin/cat <<'C'
#include <hail_aec3.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define CHECK(x) do { if (!(x)) { \
  fprintf(stderr, "FAIL line %d: %s\n", __LINE__, #x); exit(1); } } while (0)
static const double pi = 3.14159265358979323846;

static void run_signal(int rate, unsigned preset) {
  const int count = rate * 14, frame = rate / 100, delay = rate * 80 / 1000;
  int16_t* render = calloc((size_t)count, sizeof(*render));
  int16_t* capture = calloc((size_t)count, sizeof(*capture));
  int16_t* out = calloc((size_t)count, sizeof(*out));
  CHECK(render && capture && out);
  uint32_t rng = 0x1225abcd;
  double filtered = 0;
  for (int i = 0; i < count; ++i) {
    rng = 1664525u * rng + 1013904223u;
    filtered = .65 * filtered + .35 * ((double)(rng >> 16) - 32768);
    render[i] = (int16_t)(.45 * filtered);
    const double near = (i >= rate * 10 && i < rate * 12)
        ? 10000 * sin(2 * pi * 997 * i / rate) : 0;
    capture[i] = (int16_t)((i >= delay ? .5 * render[i-delay] : 0) + near);
  }
  memcpy(out, capture, (size_t)count * sizeof(*out));
  hail_aec3_config config = HAIL_AEC3_CONFIG_INIT;
  config.suppressor_preset = preset;
  hail_aec3* h = hail_aec3_create(rate, 1, &config);
  CHECK(h);
  CHECK(hail_aec3_delay_ms(h) == HAIL_AEC3_DELAY_UNAVAILABLE);
  CHECK(hail_aec3_process_render(h, NULL, (size_t)frame) == HAIL_AEC3_INVALID_ARGUMENT);
  CHECK(hail_aec3_process_capture(h, out, (size_t)frame-1) == HAIL_AEC3_INVALID_FRAME);
  CHECK(hail_aec3_process_render(h, render, (size_t)frame+1) == HAIL_AEC3_INVALID_FRAME);
  CHECK(memcmp(out, capture, (size_t)count * sizeof(*out)) == 0);
  for (int pos = 0; pos < count; pos += frame) {
    int16_t before[480];
    memcpy(before, render + pos, (size_t)frame * sizeof(*before));
    CHECK(hail_aec3_process_render(h, render + pos, (size_t)frame) == HAIL_AEC3_OK);
    CHECK(memcmp(before, render + pos, (size_t)frame * sizeof(*before)) == 0);
    CHECK(hail_aec3_process_capture(h, out + pos, (size_t)frame) == HAIL_AEC3_OK);
  }
  double in_power = 0, out_power = 0, sine = 0, cosine = 0;
  for (int i = rate * 6; i < rate * 9; ++i) {
    in_power += (double)capture[i] * capture[i];
    out_power += (double)out[i] * out[i];
  }
  // Project onto the distinct near-end frequency. Phase-independent amplitude
  // tolerates APM's block latency without fitting a gain or counting echo as near.
  const int begin = rate * 10 + rate / 4, end = rate * 12 - rate / 4;
  double render_power = 0, echo_power = 0;
  for (int i = begin; i < end; ++i) {
    const double near_sine = sin(2 * pi * 997 * i / rate);
    const double input_echo = capture[i] - 10000 * near_sine;
    render_power += (double)render[i] * render[i];
    echo_power += input_echo * input_echo;
    sine += out[i] * near_sine;
    cosine += out[i] * cos(2 * pi * 997 * i / rate);
  }
  const double erle = 10 * log10(in_power / fmax(out_power, 1));
  const double near_gain = 2 * hypot(sine, cosine) / (end - begin) / 10000;
  const double render_rms = sqrt(render_power / (end - begin));
  const double echo_rms = sqrt(echo_power / (end - begin));
  // Verify both ongoing playout and actual echo in the capture mixture during the burst.
  CHECK(render_rms > 100 && echo_rms > 100);
  printf("rate=%d preset=%u echo-only ERLE=%.2f dB double-talk near-tone gain=%.4f (%.2f dB) delay=%d ms\n",
         rate, preset, erle, near_gain, 20 * log10(fmax(near_gain, 1e-10)),
         hail_aec3_delay_ms(h));
  printf("  double-talk input RMS (PCM16): render=%.1f echo=%.1f\n", render_rms, echo_rms);
  CHECK(isfinite(erle) && erle > 20);
  CHECK(isfinite(near_gain) && near_gain > .25 && near_gain < 1.5);
  CHECK(abs(hail_aec3_delay_ms(h) - 80) <= 20);
  hail_aec3_destroy(&h);
  free(render); free(capture); free(out);
}

int main(void) {
  hail_aec3_config c = HAIL_AEC3_CONFIG_INIT;
  int16_t zero[960] = {0};
  CHECK(!hail_aec3_create(44100, 1, NULL));
  CHECK(!hail_aec3_create(16000, 0, NULL));
  CHECK(!hail_aec3_create(16000, 3, NULL));
  c.struct_size = 0; CHECK(!hail_aec3_create(16000, 1, &c));
  c.struct_size = sizeof(c);
  c.suppressor_preset = 2; CHECK(!hail_aec3_create(16000, 1, &c));
  c.suppressor_preset = 0;
  c.noise_suppression = 2; CHECK(!hail_aec3_create(16000, 1, &c));
  c.noise_suppression = 0;
  c.high_pass_filter = 2; CHECK(!hail_aec3_create(16000, 1, &c));
  CHECK(hail_aec3_delay_ms(NULL) == HAIL_AEC3_INVALID_ARGUMENT);
  CHECK(hail_aec3_process_render(NULL, zero, 160) == HAIL_AEC3_INVALID_ARGUMENT);
  CHECK(hail_aec3_process_capture(NULL, zero, 160) == HAIL_AEC3_INVALID_ARGUMENT);
  hail_aec3_destroy(NULL);
  // All supported rates/channel counts, optional processors enabled, exact and
  // invalid total sample counts. These are API checks, not acoustic validation.
  for (int rate = 16000; rate <= 48000; rate += 16000) {
    for (int channels = 1; channels <= 2; ++channels) {
      c.high_pass_filter = c.noise_suppression = 1;
      hail_aec3* h = hail_aec3_create(rate, channels, &c);
      CHECK(h);
      size_t n = (size_t)(rate / 100 * channels);
      CHECK(hail_aec3_process_capture(h, NULL, n) == HAIL_AEC3_INVALID_ARGUMENT);
      CHECK(hail_aec3_process_render(h, zero, n) == HAIL_AEC3_OK);
      CHECK(hail_aec3_process_capture(h, zero, n) == HAIL_AEC3_OK);
      CHECK(hail_aec3_process_capture(h, zero, n+1) == HAIL_AEC3_INVALID_FRAME);
      hail_aec3_destroy(&h);
      CHECK(h == NULL);
      hail_aec3_destroy(&h);
      CHECK(h == NULL);
    }
  }
  hail_aec3* defaults = hail_aec3_create(16000, 1, NULL);
  CHECK(defaults); hail_aec3_destroy(&defaults);
  for (unsigned preset = 0; preset <= 1; ++preset) {
    run_signal(16000, preset);
    run_signal(48000, preset);
  }
  puts("AEC3 C ABI synthetic smoke passed");
  return 0;
}
C
