#include "hail_aec3.h"

#include "api/audio/audio_processing.h"
#include "api/audio/echo_canceller3_config.h"
#include "api/audio/echo_control.h"
#include "modules/audio_processing/aec3/echo_canceller3.h"

#include <array>
#include <cstring>
#include <memory>
#include <optional>

namespace {
class Factory final : public webrtc::EchoControlFactory {
 public:
  explicit Factory(bool conservative) {
    if (conservative) {
      // Higher echo/near-end masking thresholds mean less suppression. Change
      // both operating modes, leaving upstream delay/filter/detection intact.
      for (auto* tuning : {&config_.suppressor.normal_tuning,
                           &config_.suppressor.nearend_tuning}) {
        tuning->mask_lf.enr_transparent *= 2.f;
        tuning->mask_lf.enr_suppress *= 2.f;
        tuning->mask_hf.enr_transparent *= 2.f;
        tuning->mask_hf.enr_suppress *= 2.f;
      }
    }
  }
  std::unique_ptr<webrtc::EchoControl> Create(int rate, int render,
                                            int capture) override {
    return std::make_unique<webrtc::EchoCanceller3>(
        config_, std::nullopt, rate, render, capture);
  }
 private:
  webrtc::EchoCanceller3Config config_;
};
}  // namespace

struct hail_aec3 {
  rtc::scoped_refptr<webrtc::AudioProcessing> apm;
  webrtc::StreamConfig stream;
  size_t samples;
  int delay = HAIL_AEC3_DELAY_UNAVAILABLE;
  std::array<int16_t, 960> scratch{};
};

extern "C" hail_aec3* hail_aec3_create(int rate, int channels,
                                       const hail_aec3_config* config) {
  if ((rate != 16000 && rate != 32000 && rate != 48000) ||
      (channels != 1 && channels != 2)) return nullptr;
  const hail_aec3_config defaults = HAIL_AEC3_CONFIG_INIT;
  const auto& c = config ? *config : defaults;
  if (c.struct_size != sizeof(c) || c.suppressor_preset > 1 ||
      c.noise_suppression > 1 || c.high_pass_filter > 1) return nullptr;
  try {
    auto h = std::make_unique<hail_aec3>();
    h->stream = webrtc::StreamConfig(rate, channels);
    h->samples = static_cast<size_t>(rate / 100 * channels);
    h->apm = webrtc::AudioProcessingBuilder()
        .SetEchoControlFactory(std::make_unique<Factory>(
            c.suppressor_preset == HAIL_AEC3_SUPPRESSOR_CONSERVATIVE))
        .Create();
    if (!h->apm) return nullptr;
    webrtc::AudioProcessing::Config apm_config;
    apm_config.pipeline.multi_channel_render = channels == 2;
    apm_config.pipeline.multi_channel_capture = channels == 2;
    apm_config.echo_canceller.enabled = true;
    apm_config.echo_canceller.mobile_mode = false;
    apm_config.echo_canceller.enforce_high_pass_filtering = false;
    apm_config.high_pass_filter.enabled = c.high_pass_filter != 0;
    apm_config.noise_suppression.enabled = c.noise_suppression != 0;
    apm_config.gain_controller1.enabled = false;
    apm_config.gain_controller2.enabled = false;
    h->apm->ApplyConfig(apm_config);
    webrtc::ProcessingConfig streams;
    streams.input_stream() = streams.output_stream() = h->stream;
    streams.reverse_input_stream() = streams.reverse_output_stream() = h->stream;
    if (h->apm->Initialize(streams) != 0) return nullptr;
    return h.release();
  } catch (...) { return nullptr; }
}

extern "C" int hail_aec3_process_render(hail_aec3* h, const int16_t* frame,
                                         size_t samples) {
  if (!h || !frame) return HAIL_AEC3_INVALID_ARGUMENT;
  if (samples != h->samples) return HAIL_AEC3_INVALID_FRAME;
  try {
    return h->apm->ProcessReverseStream(frame, h->stream, h->stream,
                                        h->scratch.data()) == 0
        ? HAIL_AEC3_OK : HAIL_AEC3_PROCESSING_ERROR;
  } catch (...) { return HAIL_AEC3_PROCESSING_ERROR; }
}

extern "C" int hail_aec3_process_capture(hail_aec3* h, int16_t* frame,
                                          size_t samples) {
  if (!h || !frame) return HAIL_AEC3_INVALID_ARGUMENT;
  if (samples != h->samples) return HAIL_AEC3_INVALID_FRAME;
  try {
    if (h->apm->ProcessStream(frame, h->stream, h->stream,
                              h->scratch.data()) != 0)
      return HAIL_AEC3_PROCESSING_ERROR;
    // APM has a single-entry statistics queue. Drain every capture frame so
    // delay_ms reports the latest estimate, even when clients query rarely.
    h->delay = h->apm->GetStatistics().delay_ms.value_or(HAIL_AEC3_DELAY_UNAVAILABLE);
    std::memcpy(frame, h->scratch.data(), samples * sizeof(*frame));
    return HAIL_AEC3_OK;
  } catch (...) { return HAIL_AEC3_PROCESSING_ERROR; }
}

extern "C" int hail_aec3_delay_ms(hail_aec3* h) {
  return h ? h->delay : HAIL_AEC3_INVALID_ARGUMENT;
}

extern "C" void hail_aec3_destroy(hail_aec3** handle) {
  if (!handle) return;
  delete *handle;
  *handle = nullptr;
}
