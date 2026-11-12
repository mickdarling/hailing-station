#!/bin/bash
# Local-only lab. No install step, package manager, signing identity, or app build.
set -euo pipefail
cd "$(dirname "$0")"
ROOT=$PWD
TARGET=${1:-macos}
[[ $TARGET == macos || $TARGET == ios ]] || { echo 'usage: build.sh macos|ios' >&2; exit 2; }
MODE=${2:-prepare}
mkdir -p .work/downloads .work/tools .work/artifacts .work/tmp
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
export TMPDIR="$ROOT/.work/tmp/"
BUILD=$ROOT/.work/build-$TARGET
PLAN=$ROOT/.work/batches-$TARGET.json
if [[ ${AEC3_PHASE:-0} != 1 ]]; then
  [[ $MODE == prepare || $MODE == --resume || $MODE == --link-only ]] || { echo 'use macos|ios [--resume|--link-only]' >&2; exit 2; }
  if [[ $MODE == --link-only ]]; then
    exec python3 "$ROOT/make_fixtures.py" phase -- /bin/bash "$ROOT/build.sh" "$TARGET" finish link-only
  fi
  if [[ ! -x .work/tools/ninja ]]; then
    python3 "$ROOT/make_fixtures.py" phase -- /bin/bash "$ROOT/build.sh" "$TARGET" tools
  fi
  python3 "$ROOT/make_fixtures.py" phase -- /bin/bash "$ROOT/build.sh" "$TARGET" "$MODE"
  COUNT=$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))))' "$PLAN")
  INDEX=1
  while [[ $INDEX -lt $COUNT ]]; do
    python3 "$ROOT/make_fixtures.py" phase -- /bin/bash "$ROOT/build.sh" "$TARGET" "objects:$INDEX"
    INDEX=$((INDEX + 1))
  done
  exec python3 "$ROOT/make_fixtures.py" phase -- /bin/bash "$ROOT/build.sh" "$TARGET" finish
fi
JOBS=2
# Retain interrupted objects only inside .work; --resume requires unchanged inputs.
trap 'rm -rf "$ROOT/.work/tool-build"' EXIT
trap 'exit 130' INT TERM
export PATH="$ROOT/.work/tools:$PATH"
if [[ $MODE == objects:* ]]; then
  python3 - "$BUILD" "$PLAN" "${MODE#objects:}" <<'BATCH'
import json, subprocess, sys
build, plan, index = sys.argv[1:]
subprocess.run(['ninja', '-C', build, '-j', '2'] + json.load(open(plan))[int(index)], check=True)
BATCH
  exit 0
fi
fetch() {
  local filename=$1 hash=$2 url=$3
  if [[ ! -f .work/downloads/$filename ]]; then
    curl --fail --location --proto '=https' --tlsv1.2 --max-time 120 "$url" -o ".work/downloads/$filename.part"
    mv ".work/downloads/$filename.part" ".work/downloads/$filename"
  fi
  echo "$hash  .work/downloads/$filename" | shasum -a 256 -c -
}
fetch webrtc-audio-processing-2.1.tar.xz ae9302824b2038d394f10213cab05312c564a038434269f11dbf68f511f9f9fe https://freedesktop.org/software/pulseaudio/webrtc-audio-processing/webrtc-audio-processing-2.1.tar.xz
fetch abseil-cpp-20240722.0.tar.gz f50e5ac311a81382da7fa75b97310e4b9006474f9560ac46f54a9967f07d4ae3 https://github.com/abseil/abseil-cpp/releases/download/20240722.0/abseil-cpp-20240722.0.tar.gz
fetch abseil-cpp_20240722.0-3_patch.zip 12dd8df1488a314c53e3751abd2750cf233b830651d168b6a9f15e7d0cf71f7b https://wrapdb.mesonbuild.com/v2/abseil-cpp_20240722.0-3/get_patch
fetch meson-1.8.3.tar.gz f118aa910fc0a137cc2dd0122232dbf82153d9a12fb5b0f5bb64896f6a157abf https://github.com/mesonbuild/meson/releases/download/1.8.3/meson-1.8.3.tar.gz
fetch ninja-1.13.1.tar.gz f0055ad0369bf2e372955ba55128d000cfcc21777057806015b45e4accbebf23 https://github.com/ninja-build/ninja/archive/refs/tags/v1.13.1.tar.gz
if [[ $MODE != finish ]]; then
  rm -rf .work/meson-1.8.3
  tar -xzf .work/downloads/meson-1.8.3.tar.gz -C .work
fi
if [[ ! -x .work/tools/ninja ]]; then
  mkdir -p .work/tool-build
  tar -xzf .work/downloads/ninja-1.13.1.tar.gz -C .work/tool-build
  # Bootstrap compiles serially; cap the final Ninja rebuild too.
  python3 - "$JOBS" <<'PY'
from pathlib import Path
import sys
p = Path('.work/tool-build/ninja-1.13.1/configure.py')
s = p.read_text().replace('subprocess.check_call(rebuild_args)',
                         "subprocess.check_call(rebuild_args + ['-j', '%s'])" % sys.argv[1])
p.write_text(s)
PY
  (cd .work/tool-build/ninja-1.13.1; MACOSX_DEPLOYMENT_TARGET=13.0 python3 configure.py --bootstrap)
  cp .work/tool-build/ninja-1.13.1/ninja .work/tools/ninja
  rm -rf .work/tool-build
fi
[[ $MODE != tools ]] || exit 0
SRC=$ROOT/.work/webrtc-audio-processing-2.1
if [[ $MODE == prepare ]]; then
  rm -rf "$SRC"
  tar -xJf .work/downloads/webrtc-audio-processing-2.1.tar.xz -C .work
  mkdir -p "$SRC/subprojects/packagecache"
  cp .work/downloads/abseil* "$SRC/subprojects/packagecache/"
fi
FLAGS=(-arch arm64 -Os -DNDEBUG -ffunction-sections -fdata-sections)
MESON=(python3 "$ROOT/.work/meson-1.8.3/meson.py" setup "$BUILD" "$SRC")
if [[ $TARGET == ios ]]; then
  SDK=$(xcrun --sdk iphoneos --show-sdk-path)
  CC=$(xcrun --sdk iphoneos --find clang)
  CXX=$(xcrun --sdk iphoneos --find clang++)
  FLAGS+=(-isysroot "$SDK" -miphoneos-version-min=16.0)
  python3 - "$CC" "$CXX" "$SDK" "$ROOT/.work/ios-arm64.ini" <<'PY'
import sys
cc, cpp, sdk, path = sys.argv[1:]
args = ['-arch', 'arm64', '-isysroot', sdk, '-miphoneos-version-min=16.0', '-Os', '-ffunction-sections', '-fdata-sections']
with open(path, 'w') as f:
    f.write("[binaries]\nc = %r\ncpp = %r\nar = '/usr/bin/ar'\nstrip = '/usr/bin/strip'\n" % (cc, cpp))
    f.write("[host_machine]\nsystem = 'darwin'\ncpu_family = 'aarch64'\ncpu = 'arm64'\nendian = 'little'\n")
    f.write("[properties]\nneeds_exe_wrapper = true\n[built-in options]\nc_args = %r\ncpp_args = %r\nc_link_args = %r\ncpp_link_args = %r\n" % (args, args, args, args))
PY
  MESON+=(--cross-file "$ROOT/.work/ios-arm64.ini")
else
  CC=$(xcrun --find clang)
  CXX=$(xcrun --find clang++)
  SDK=$(xcrun --sdk macosx --show-sdk-path)
  FLAGS+=(-isysroot "$SDK" -mmacosx-version-min=13.0)
fi
export CC CXX
# Cross-file supplies SDK flags on iOS; native flags are supplied explicitly.
if [[ $TARGET == macos ]]; then
  export CFLAGS="-arch arm64 -Os -ffunction-sections -fdata-sections -isysroot $SDK -mmacosx-version-min=13.0"
  export CXXFLAGS="$CFLAGS" LDFLAGS="-arch arm64 -isysroot $SDK -mmacosx-version-min=13.0"
else
  unset CFLAGS CXXFLAGS LDFLAGS || true
fi
if [[ $MODE == prepare ]]; then
  rm -rf "$BUILD"
  "${MESON[@]}" --wrap-mode=nodownload --force-fallback-for=absl_base,absl_flags,absl_strings,absl_numeric,absl_synchronization,absl_bad_optional_access -Ddefault_library=static -Dbuildtype=release -Doptimization=s -Db_ndebug=true
fi
if [[ $MODE == prepare || $MODE == --resume ]]; then
  python3 - "$BUILD" "$PLAN" <<'BATCH'
import json, os, subprocess, sys
from pathlib import Path
build, plan = sys.argv[1:]
options = {x['name']: x['value'] for x in json.loads((Path(build)/'meson-info/intro-buildoptions.json').read_text())}
for key, expected in [('default_library', 'static'), ('buildtype', 'release'), ('optimization', 's'), ('b_ndebug', 'true')]:
    if options[key] != expected:
        raise RuntimeError('resume/build configuration mismatch: ' + key)
# Explicit object targets bound each compilation phase. Final archiving/linking
# follows only after every object batch succeeds. Existing objects may be reused
# ONLY for an interrupted run with unchanged verified sources and flags.
listing = subprocess.check_output(['ninja', '-C', build, '-t', 'targets', 'all'], text=True)
objects = [line.rsplit(': ', 1)[0] for line in listing.splitlines()
           if line.rsplit(': ', 1)[0].endswith('.o')]
objects = [x for x in dict.fromkeys(objects) if not (Path(build)/x).exists()]
batches = [objects[i:i+150] for i in range(0, len(objects), 150)] or [[]]
Path(plan).write_text(json.dumps(batches, indent=2)+'\n')
print('Object batches:', [len(x) for x in batches], flush=True)
if batches[0]:
    subprocess.run(['ninja', '-C', build, '-j', '2'] + batches[0], check=True)
BATCH
  exit 0
fi
[[ $MODE == finish ]] || { echo "unknown build mode: $MODE" >&2; exit 2; }
if [[ ${3:-} == link-only ]]; then
  [[ -f "$BUILD/webrtc/modules/audio_processing/libwebrtc-audio-processing-2.a" ]] || { echo 'link-only requires completed libraries' >&2; exit 2; }
else
  ninja -C "$BUILD" -j "$JOBS"
fi
OUT=$ROOT/.work/artifacts/$TARGET
rm -rf "$OUT"
mkdir -p "$OUT/libs"
find "$BUILD" -name '*.a' -exec cp {} "$OUT/libs/" \;
cat > .work/probe.cc <<'CPP'
#include <cstdint>
#ifdef AEC3
#include "api/audio/audio_processing.h"
#endif
extern "C" __attribute__((visibility("default"))) int aec3_probe(int16_t* render, int16_t* capture, int rate) {
#ifdef AEC3
  auto apm = webrtc::AudioProcessingBuilder().Create();
  webrtc::AudioProcessing::Config c;
  c.echo_canceller.enabled = true;
  c.echo_canceller.mobile_mode = false;
  c.echo_canceller.enforce_high_pass_filtering = false;
  c.high_pass_filter.enabled = false;
  c.noise_suppression.enabled = false;
  c.gain_controller1.enabled = false;
  c.gain_controller2.enabled = false;
  apm->ApplyConfig(c);
  webrtc::StreamConfig s(rate, 1);
  int r = apm->ProcessReverseStream(render, s, s, render);
  return r + apm->ProcessStream(capture, s, s, capture);
#else
  return render[0] + capture[0] + rate;
#endif
}
CPP
INC=(-I "$SRC/webrtc" -I "$SRC/subprojects/abseil-cpp-20240722.0" -DWEBRTC_POSIX -DWEBRTC_MAC -std=c++17)
[[ $TARGET != ios ]] || INC+=(-DWEBRTC_IOS)
LIBS=("$OUT"/libs/*.a -framework CoreFoundation)
# Repeat each stripped, dead-stripped link pair inside this bounded phase.
for RUN in 1 2; do
  "$CXX" "${FLAGS[@]}" -std=c++17 -dynamiclib -Wl,-install_name,@rpath/aec3-lab-probe.dylib -Wl,-dead_strip -Wl,-exported_symbol,_aec3_probe .work/probe.cc -o "$OUT/baseline-$RUN.dylib"
  "$CXX" "${FLAGS[@]}" "${INC[@]}" -DAEC3 -dynamiclib -Wl,-install_name,@rpath/aec3-lab-probe.dylib -Wl,-dead_strip -Wl,-exported_symbol,_aec3_probe .work/probe.cc "${LIBS[@]}" -o "$OUT/aec3-$RUN.dylib"
  strip -x "$OUT/baseline-$RUN.dylib" "$OUT/aec3-$RUN.dylib"
done
if [[ $TARGET == macos ]]; then
  "$CXX" "${FLAGS[@]}" "${INC[@]}" -Wl,-dead_strip aec3_lab.cc "${LIBS[@]}" -o "$OUT/aec3_lab"
  strip -x "$OUT/aec3_lab"
fi
python3 - "$OUT" <<'PY'
from pathlib import Path
import json, sys
p = Path(sys.argv[1])
static = [{x.name: x.stat().st_size for x in sorted((p/'libs').glob('*.a'))} for _ in range(2)]
assert static[0] == static[1], 'archive size changed between measurements'
r = {'target': p.name, 'static_bytes': static[0], 'static_bytes_repeat': static[1],
     'links': [{'baseline': (p/('baseline-%d.dylib'%n)).stat().st_size,
                'aec3': (p/('aec3-%d.dylib'%n)).stat().st_size,
                'delta': (p/('aec3-%d.dylib'%n)).stat().st_size-(p/('baseline-%d.dylib'%n)).stat().st_size} for n in (1, 2)]}
(p/'sizes.json').write_text(json.dumps(r, indent=2)+'\n')
print(json.dumps(r, indent=2))
PY
