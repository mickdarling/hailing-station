// #1225: offline AEC3 feasibility harness. No audio device or network APIs.
#include "api/audio/audio_processing.h"
#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <limits>
#include <stdexcept>
#include <string>
#include <time.h>
#include <vector>

using Samples = std::vector<int16_t>;
struct Wave { int rate; Samples pcm; };
struct Segment { double start, end; };
static void require(bool ok, const std::string& message) {
  if (!ok) throw std::runtime_error(message);
}
static uint32_t le(const uint8_t* p, int n) {
  uint32_t x = 0;
  for (int i = 0; i < n; ++i) x |= uint32_t(p[i]) << (8*i);
  return x;
}
static Wave read_wave(const std::string& path) {
  std::ifstream f(path, std::ios::binary | std::ios::ate);
  require(bool(f), "cannot open " + path);
  auto size = f.tellg();
  require(size >= 44 && size <= 100*1024*1024, "invalid/big WAV: " + path);
  std::vector<uint8_t> b(static_cast<size_t>(size));
  f.seekg(0); f.read(reinterpret_cast<char*>(b.data()), b.size());
  require(bool(f) && !memcmp(b.data(), "RIFF", 4) && !memcmp(b.data()+8, "WAVE", 4), "expected RIFF WAV");
  require(le(b.data()+4, 4) == b.size()-8, "RIFF length mismatch");
  int rate = 0; bool format = false, data = false; Samples pcm;
  for (size_t p = 12; p + 8 <= b.size();) {
    auto n = le(b.data()+p+4, 4); auto q = p+8;
    require(n <= b.size()-q, "truncated WAV chunk");
    if (!memcmp(b.data()+p, "fmt ", 4)) {
      require(!format && n >= 16 && le(b.data()+q, 2) == 1 && le(b.data()+q+2, 2) == 1 && le(b.data()+q+14, 2) == 16, "requires mono PCM16");
      rate = int(le(b.data()+q+4, 4));
      require((rate == 16000 || rate == 48000) && le(b.data()+q+12, 2) == 2 && le(b.data()+q+8, 4) == unsigned(rate*2), "requires 16/48 kHz PCM16");
      format = true;
    } else if (!memcmp(b.data()+p, "data", 4)) {
      require(!data && n % 2 == 0, "invalid/duplicate data");
      pcm.resize(n/2);
      for (size_t i = 0; i < pcm.size(); ++i) pcm[i] = static_cast<int16_t>(le(b.data()+q+2*i, 2));
      data = true;
    }
    p = q+n+(n%2);
  }
  require(format && data && !pcm.empty(), "missing format/audio");
  require(pcm.size() % (rate/100) == 0, "WAV must contain whole 10 ms frames");
  return {rate, std::move(pcm)};
}
static void put(std::ofstream& f, uint32_t x, int n) {
  for (int i = 0; i < n; ++i) f.put(char((x >> (8*i)) & 255));
}
static void write_wave(const std::string& path, const Wave& w) {
  std::ofstream f(path, std::ios::binary);
  require(bool(f), "cannot write " + path);
  f.write("RIFF", 4); put(f, 36+w.pcm.size()*2, 4); f.write("WAVEfmt ", 8);
  put(f, 16, 4); put(f, 1, 2); put(f, 1, 2); put(f, w.rate, 4);
  put(f, w.rate*2, 4); put(f, 2, 2); put(f, 16, 2); f.write("data", 4);
  put(f, w.pcm.size()*2, 4);
  for (int16_t x: w.pcm) put(f, uint16_t(x), 2);
  require(bool(f), "WAV write failed");
}
static double cpu_seconds() {
  timespec t{};
  require(clock_gettime(CLOCK_THREAD_CPUTIME_ID, &t) == 0, "thread CPU clock unavailable");
  return t.tv_sec + t.tv_nsec*1e-9;
}
static Segment parse_segment(const std::string& s) {
  auto colon = s.find(':');
  require(colon != std::string::npos, "segment syntax is seconds:seconds");
  size_t a = 0, b = 0;
  double start = std::stod(s.substr(0, colon), &a), end = std::stod(s.substr(colon+1), &b);
  require(a == colon && b == s.size()-colon-1 && std::isfinite(start) && std::isfinite(end) && start >= 0 && end > start, "invalid segment");
  return {start, end};
}
struct Moments {
  double xx=0, yy=0, xy=0, sx=0, sy=0, error=0; size_t n=0;
  void add(double x, double y) { xx+=x*x; yy+=y*y; xy+=x*y; sx+=x; sy+=y; error+=(x-y)*(x-y); ++n; }
  double corr() const {
    double v = (xx-sx*sx/n)*(yy-sy*sy/n);
    return v > 0 ? (xy-sx*sy/n)/std::sqrt(v) : 0;
  }
};
static Moments compare(const Samples& clean, const Samples& out, int rate,
                       const std::vector<Segment>& segs, int lag=0) {
  Moments m;
  for (auto s: segs) for (size_t i=size_t(std::llround(s.start*rate)); i<size_t(std::llround(s.end*rate)); ++i) {
    auto j = int64_t(i)+lag;
    if (j >= 0 && j < int64_t(out.size())) m.add(clean[i]/32768.0, out[j]/32768.0);
  }
  return m;
}
static void number(double x) {
  if (std::isfinite(x)) std::cout << x; else std::cout << "null";
}
static void preservation(const Moments& m) {
  std::cout << "{\"correlation\":"; number(m.corr());
  std::cout << ",\"snr_db\":"; number(10*std::log10(m.xx/std::max(m.error, 1e-30)));
  std::cout << ",\"output_to_clean_db\":"; number(10*std::log10(m.yy/std::max(m.xx, 1e-30))); std::cout << "}";
}
static void energy_metric(const Samples& in, const Samples& out, int rate, const std::vector<Segment>& segments) {
  if (segments.empty()) { std::cout << "null"; return; }
  auto m=compare(in, out, rate, segments);
  std::cout << "{\"suppression_db\":"; number(10*std::log10(m.xx/std::max(m.yy, 1e-30)));
  std::cout << ",\"input_dbfs\":"; number(10*std::log10(m.xx/m.n));
  std::cout << ",\"residual_dbfs\":"; number(10*std::log10(std::max(m.yy/m.n, 1e-30)));
  std::cout << ",\"samples\":" << m.n << "}";
}
int main(int argc, char** argv) try {
  require(argc >= 4, "usage: aec3_lab render.wav capture.wav out.wav [--near clean.wav] [--echo start:end] [--double start:end] [--stop start:end] [--ns] [--agc2]");
  std::string near_path; bool ns=false, agc=false;
  std::vector<Segment> echo, dt, stop;
  for (int i=4; i<argc; ++i) {
    std::string k=argv[i];
    if (k == "--ns") ns=true;
    else if (k == "--agc2") agc=true;
    else {
      require(i+1<argc, "missing option value"); std::string v=argv[++i];
      if (k == "--near") near_path=v;
      else if (k == "--echo") echo.push_back(parse_segment(v));
      else if (k == "--double") dt.push_back(parse_segment(v));
      else if (k == "--stop") stop.push_back(parse_segment(v));
      else throw std::runtime_error("unknown option " + k);
    }
  }
  require(std::string(argv[3]) != argv[1] && std::string(argv[3]) != argv[2] && std::string(argv[3]) != near_path, "output must differ from inputs");
  auto render=read_wave(argv[1]), capture=read_wave(argv[2]);
  require(render.rate == capture.rate && render.pcm.size() == capture.pcm.size(), "input length/rate mismatch");
  Wave near{};
  if (!near_path.empty()) {
    near=read_wave(near_path);
    require(near.rate == capture.rate && near.pcm.size() == capture.pcm.size(), "ground truth length/rate mismatch");
  }
  require(dt.empty() || !near_path.empty(), "double-talk metrics require clean near-end");
  for (const auto* segs: {&echo, &dt, &stop}) for (auto s: *segs)
    require(s.end*capture.rate <= capture.pcm.size(), "segment beyond audio");
  auto apm=webrtc::AudioProcessingBuilder().Create();
  require(bool(apm), "APM creation failed");
  webrtc::AudioProcessing::Config config;
  config.echo_canceller.enabled=true;
  config.echo_canceller.mobile_mode=false; // AEC3, with its default internal delay estimator.
  config.echo_canceller.enforce_high_pass_filtering=false;
  config.high_pass_filter.enabled=false;
  config.noise_suppression.enabled=ns;
  config.gain_controller1.enabled=false;
  config.gain_controller2.enabled=agc;
  config.gain_controller2.adaptive_digital.enabled=agc;
  apm->ApplyConfig(config);
  webrtc::StreamConfig stream(capture.rate, 1);
  Wave out{capture.rate, Samples(capture.pcm.size())};
  const int frame=capture.rate/100;
  Samples reverse(frame);
  std::vector<double> timings; timings.reserve(out.pcm.size()/frame);
  std::vector<int> delays;
  for (size_t p=0; p<out.pcm.size(); p+=frame) {
    double begin=cpu_seconds();
    int r=apm->ProcessReverseStream(render.pcm.data()+p, stream, stream, reverse.data());
    int c=apm->ProcessStream(capture.pcm.data()+p, stream, stream, out.pcm.data()+p);
    double elapsed=cpu_seconds()-begin;
    require(r == 0 && c == 0, "APM processing error");
    timings.push_back(elapsed*1e6);
    if (timings.size()%100 == 0) { auto s=apm->GetStatistics(); if (s.delay_ms) delays.push_back(*s.delay_ms); }
  }
  write_wave(argv[3], out);
  double sum=0; for (auto t: timings) sum+=t;
  std::sort(timings.begin(), timings.end());
  auto percentile=[&](double p){ return timings[size_t(std::ceil(p*timings.size()))-1]; };
  std::cout << std::setprecision(9) << "{\"rate\":" << capture.rate << ",\"frames\":" << timings.size()
            << ",\"ns\":" << (ns?"true":"false") << ",\"agc2\":" << (agc?"true":"false")
            << ",\"cpu_us\":{\"mean\":" << sum/timings.size() << ",\"p50\":" << percentile(.5)
            << ",\"p95\":" << percentile(.95) << ",\"max\":" << timings.back()
            << ",\"real_time_factor\":" << sum/(timings.size()*10000.0) << "},\"echo_only\":";
  energy_metric(capture.pcm, out.pcm, capture.rate, echo);
  std::cout << ",\"self_stop\":"; energy_metric(capture.pcm, out.pcm, capture.rate, stop);
  std::cout << ",\"near_zero_lag\":";
  if (dt.empty()) std::cout << "null";
  else preservation(compare(near.pcm, out.pcm, capture.rate, dt));
  int alignment_lag=0;
  std::cout << ",\"near_aligned\":";
  if (dt.empty()) std::cout << "null";
  else {
    // Report both raw and latency-compensated metrics; never fit output gain.
    // Search only positive algorithmic latency, at most 20 ms.
    double best=-2; int lag=0;
    for (int l=0; l<=capture.rate/50; ++l) {
      auto m=compare(near.pcm, out.pcm, capture.rate, dt, l);
      if (m.corr()>best) { best=m.corr(); lag=l; }
    }
    alignment_lag=lag;
    std::cout << "{\"lag_samples\":" << lag << ",\"metrics\":";
    preservation(compare(near.pcm, out.pcm, capture.rate, dt, lag)); std::cout << "}";
  }
  std::cout << ",\"near_segments_aligned\":[";
  for (size_t i=0; i<dt.size(); ++i) {
    if (i) std::cout << ",";
    std::cout << "{\"start\":" << dt[i].start << ",\"end\":" << dt[i].end << ",\"metrics\":";
    preservation(compare(near.pcm, out.pcm, capture.rate, {dt[i]}, alignment_lag));
    std::cout << "}";
  }
  std::cout << "],\"delay_estimates_ms\":[";
  for (size_t i=0; i<delays.size(); ++i) {
    if (i) std::cout << ",";
    std::cout << delays[i];
  }
  std::cout << "],\"delay_estimate_ms\":";
  if (delays.empty()) std::cout << "null"; else std::cout << delays.back();
  std::cout << "}\n";
  return 0;
} catch (const std::exception& e) { std::cerr << e.what() << '\n'; return 1; }
