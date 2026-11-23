#ifndef HAIL_AEC3_H
#define HAIL_AEC3_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#if defined(__GNUC__)
#define HAIL_AEC3_API __attribute__((visibility("default")))
#else
#define HAIL_AEC3_API
#endif

typedef struct hail_aec3 hail_aec3;
enum {
  HAIL_AEC3_OK = 0,
  HAIL_AEC3_INVALID_ARGUMENT = -1,
  HAIL_AEC3_INVALID_FRAME = -2,
  HAIL_AEC3_PROCESSING_ERROR = -3,
  HAIL_AEC3_DELAY_UNAVAILABLE = -4
};
enum {
  HAIL_AEC3_SUPPRESSOR_DEFAULT = 0,
  HAIL_AEC3_SUPPRESSOR_CONSERVATIVE = 1
};

/* NULL config selects upstream suppressor defaults, NS off, HPF off.
 * Set struct_size to sizeof(hail_aec3_config). Booleans must be 0 or 1.
 * Conservative reduces suppression in BOTH normal and nearend tuning; it is
 * an experimental near-end-preservation preset, not a validated S0 result. */
typedef struct hail_aec3_config {
  uint32_t struct_size;
  uint32_t suppressor_preset;
  uint32_t noise_suppression;
  uint32_t high_pass_filter;
} hail_aec3_config;
#define HAIL_AEC3_CONFIG_INIT { sizeof(hail_aec3_config), 0, 0, 0 }

/* 16/32/48 kHz, 1 or 2 channels, interleaved PCM16. NULL on invalid config or
 * creation/initialization failure. No exceptions cross this boundary.
 * One owner must serialize ALL calls on a handle, including delay/destroy.
 * Creation and first processing may allocate; no real-time guarantee is made. */
HAIL_AEC3_API hail_aec3* hail_aec3_create(int sample_rate_hz, int channels,
                            const hail_aec3_config* config);
/* Exactly 10 ms: samples = sample_rate_hz / 100 * channels (total, not per
 * channel). Feed the actually played render before the corresponding capture.
 * Render input is never modified. Capture is replaced only on success. */
HAIL_AEC3_API int hail_aec3_process_render(hail_aec3* h, const int16_t* frame, size_t samples);
HAIL_AEC3_API int hail_aec3_process_capture(hail_aec3* h, int16_t* frame_inout, size_t samples);
/* Internal AEC3 delay estimate, not physical route latency. Nonnegative ms,
 * DELAY_UNAVAILABLE until available, INVALID_ARGUMENT for NULL. */
HAIL_AEC3_API int hail_aec3_delay_ms(hail_aec3* h);
/* Pass the address of the sole owner's handle. Destruction clears it to NULL.
 * Both a NULL address and a NULL handle are safe, including repeated calls
 * through the same owner. All borrowed pointers expire on destruction. */
HAIL_AEC3_API void hail_aec3_destroy(hail_aec3** handle);

#ifdef __cplusplus
}
#endif
#endif
