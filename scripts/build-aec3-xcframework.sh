#!/bin/bash
# #1225 S1a: standalone packaging; deliberately no SwiftPM/app integration.
set -euo pipefail
ROOT=$(CDPATH='' cd -- "$(/usr/bin/dirname "$0")/.." && pwd -P)
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
# Bash may spool the Python here-document before the driver starts. Validate
# each component before creating the next one, including on the first run.
for dir in "$ROOT/build" "$ROOT/build/aec3" "$ROOT/build/aec3/driver-tmp"; do
  if [[ -L $dir ]]; then
    echo "Symlink in build path: $dir" >&2
    exit 1
  fi
  /bin/mkdir -p "$dir"
done
export TMPDIR="$dir/"
exec /usr/bin/python3 -I -S -B - "$ROOT" "$@" <<'PY'
import ctypes
import hashlib
import json
import os
import plistlib
import pwd
from pathlib import Path
import shutil
import shlex
import signal
import stat
import subprocess
import sys
import tempfile
import time
from urllib.parse import urlsplit
import zipfile

ROOT = Path(sys.argv[1])
GATE_DIR = os.environ.get('AEC3_GATE_DIR')
BASE = ROOT / 'build/aec3'
ARGS = sys.argv[2:]
MODES = {(): 'release', ('--clean',): 'release', ('--resume-local',): 'local', ('--smoke',): 'smoke'}
worker = ARGS[:1] == ['--phase']
MODE = ARGS[1] if worker and len(ARGS) >= 3 else MODES.get(tuple(ARGS))
if MODE not in MODES.values():
    sys.exit('usage: scripts/build-aec3-xcframework.sh [--clean | --resume-local]')
WORK = BASE / ('work-' + MODE)
TARGET_TREES = BASE / 'local-targets' if MODE == 'local' else WORK
DOWNLOADS = BASE / 'downloads'
INPUTS = WORK / 'inputs'
PUBLISHED = BASE / ('local-out' if MODE == 'local' else 'out')
SRC = WORK / 'webrtc-audio-processing-2.1'
SCRIPT = ROOT / 'scripts/build-aec3-xcframework.sh'
SMOKE = ROOT / 'scripts/tests/test-aec3-shim.sh'
PYTHON = '/usr/bin/python3'
MESON = WORK / 'meson-1.8.3/meson.py'
NINJA = WORK / 'ninja-1.13.1/ninja'
PINS = [
    ('webrtc-audio-processing-2.1.tar.xz', 'ae9302824b2038d394f10213cab05312c564a038434269f11dbf68f511f9f9fe', 'https://freedesktop.org/software/pulseaudio/webrtc-audio-processing/webrtc-audio-processing-2.1.tar.xz'),
    ('abseil-cpp-20240722.0.tar.gz', 'f50e5ac311a81382da7fa75b97310e4b9006474f9560ac46f54a9967f07d4ae3', 'https://github.com/abseil/abseil-cpp/releases/download/20240722.0/abseil-cpp-20240722.0.tar.gz'),
    ('abseil-cpp_20240722.0-3_patch.zip', '12dd8df1488a314c53e3751abd2750cf233b830651d168b6a9f15e7d0cf71f7b', 'https://wrapdb.mesonbuild.com/v2/abseil-cpp_20240722.0-3/get_patch'),
    ('meson-1.8.3.tar.gz', 'f118aa910fc0a137cc2dd0122232dbf82153d9a12fb5b0f5bb64896f6a157abf', 'https://github.com/mesonbuild/meson/releases/download/1.8.3/meson-1.8.3.tar.gz'),
    ('ninja-1.13.1.tar.gz', 'f0055ad0369bf2e372955ba55128d000cfcc21777057806015b45e4accbebf23', 'https://github.com/ninja-build/ninja/archive/refs/tags/v1.13.1.tar.gz'),
]
TARGETS = {
    'macos-arm64': ('macosx', 'arm64', 'arm64-apple-macos13.0'),
    'macos-x86_64': ('macosx', 'x86_64', 'x86_64-apple-macos13.0'),
    'ios-arm64': ('iphoneos', 'arm64', 'arm64-apple-ios16.0'),
    'sim-arm64': ('iphonesimulator', 'arm64', 'arm64-apple-ios16.0-simulator'),
    'sim-x86_64': ('iphonesimulator', 'x86_64', 'x86_64-apple-ios16.0-simulator'),
}
# Gates use the login environment. Each work phase starts with only these values.
BUILD_ENV = {
    'PATH': '/usr/bin:/bin:/usr/sbin:/sbin',
    'DEVELOPER_DIR': '/Applications/Xcode.app/Contents/Developer',
    'HOME': str(WORK / 'home'), 'CFFIXED_USER_HOME': str(WORK / 'home'),
    'TMPDIR': str(WORK / 'tmp') + '/',
    'XDG_CACHE_HOME': str(WORK / 'cache'), 'XDG_CONFIG_HOME': str(WORK / 'home/config'),
    'XDG_DATA_HOME': str(WORK / 'home/data'), 'XDG_STATE_HOME': str(WORK / 'home/state'),
    'CLANG_MODULE_CACHE_PATH': str(WORK / 'module-cache'),
    'PYTHONNOUSERSITE': '1', 'PYTHONDONTWRITEBYTECODE': '1', 'PYTHONHASHSEED': '0',
    'PYTHONPYCACHEPREFIX': str(WORK / 'cache/pycache'),
    'LC_ALL': 'C', 'TZ': 'UTC', 'ZERO_AR_DATE': '1', 'SOURCE_DATE_EPOCH': '1577836800',
    'NINJA': str(NINJA),
}


def run(*args, **kwargs):
    return subprocess.run([str(x) for x in args], check=True, **kwargs)


def output(*args):
    return subprocess.check_output([str(x) for x in args], text=True).strip()


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def checked_dir(path, create=False):
    # ROOT is physical (pwd -P). Check ancestors as well as the final entry
    # before making a directory, removing a stale stage, or using an output.
    if path != ROOT / 'build' and path != BASE and BASE not in path.parents:
        raise RuntimeError(f'Directory outside build workspace: {path}')
    if path.resolve() != path or path.is_symlink():
        raise RuntimeError(f'Symlink in build path: {path}')
    if create:
        path.mkdir(mode=0o700, exist_ok=True)
    if not path.is_dir():
        raise RuntimeError(f'Expected directory: {path}')


def check_output_tree(folder):
    checked_dir(folder)
    for p in folder.iterdir():
        if p.is_symlink():
            raise RuntimeError(f'Symlink in output: {p}')
        if p.is_dir():
            check_output_tree(p)
        elif not p.is_file():
            raise RuntimeError(f'Invalid output entry: {p}')


def publish(stage):
    # Both names are on the same volume. Swap a nonempty published directory
    # atomically on Darwin, leaving the previous generation intact on failure.
    check_output_tree(stage)
    if MODE == 'release':
        checksums = 'xcframework zip SHA-256: ' + digest(stage / 'HailAEC3.xcframework.zip')
    else:
        checksums = '\n'.join(f'{t}/libHailAEC3.a SHA-256: {digest(stage / t / "libHailAEC3.a")}'
                              for t in TARGETS)
    replacing = PUBLISHED.exists() or PUBLISHED.is_symlink()
    if replacing:
        check_output_tree(PUBLISHED)
        swap = ctypes.CDLL('/usr/lib/libSystem.B.dylib', use_errno=True).renamex_np
        swap.argtypes = (ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint)
        swap.restype = ctypes.c_int
        if swap(os.fsencode(stage), os.fsencode(PUBLISHED), 0x00000002) != 0:  # RENAME_SWAP
            err = ctypes.get_errno()
            raise OSError(err, os.strerror(err), str(PUBLISHED))
    else:
        stage.rename(PUBLISHED)
    print(f'Published {PUBLISHED}\n{checksums}', flush=True)
    if replacing:
        try:
            shutil.rmtree(stage)  # Now contains only the previous generation.
        except OSError as err:
            print(f'Warning: old generation cleanup incomplete; retained at {stage}: {err}',
                  file=sys.stderr, flush=True)


def snapshot_input(cached, dest, sha):
    # Open the shared name once. A cache refresh may rename or modify the
    # entry while copying; only the bytes in our private file establish trust.
    try:
        fd = os.open(cached, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    except OSError as err:
        raise RuntimeError(f'Cannot open cached input ({err.strerror}). Check or remove: {cached}') from err
    with os.fdopen(fd, 'rb') as src:
        if not stat.S_ISREG(os.fstat(src.fileno()).st_mode):
            raise RuntimeError(f'Invalid cached input. Remove: {cached}')
        with dest.open('xb') as dst:
            shutil.copyfileobj(src, dst)
    if digest(dest) != sha:
        raise RuntimeError(f'Private copy failed SHA-256 verification. Remove: {cached}')


def fetch(dest, sha, url):
    # curl resolves Location to redirect_url but never follows it. Check the
    # entire authority (no credentials or custom ports) before every request.
    allowed = {
        'freedesktop.org': {'freedesktop.org', 'www.freedesktop.org'},
        'wrapdb.mesonbuild.com': {'wrapdb.mesonbuild.com', 'github.com', 'release-assets.githubusercontent.com'},
        'github.com': {'github.com', 'release-assets.githubusercontent.com', 'codeload.github.com'},
    }[urlsplit(url).netloc]
    part = dest.with_name(dest.name + '.part')
    if part.is_symlink():
        raise RuntimeError(f'Symlink at download path: {part}')
    part.unlink(missing_ok=True)
    try:
        for _ in range(8):
            parts = urlsplit(url)
            if (parts.scheme != 'https' or parts.netloc not in allowed or '\\' in url
                    or any(ord(c) <= 32 or ord(c) >= 127 for c in url)):
                raise RuntimeError(f'Refused download destination for {dest.name}')
            reply = run('curl', '-q', '--silent', '--show-error', '--fail', '--globoff',
                        '--proto', '=https', '--tlsv1.2', '--max-time', '120', '-o', part,
                        '--write-out', '%{http_code}\n%{redirect_url}', '--', url,
                        stdout=subprocess.PIPE, text=True).stdout
            status, url = reply.split('\n', 1)
            if status == '200':
                if digest(part) != sha:
                    raise RuntimeError(f'Download SHA-256 mismatch for {dest}. Discarding: {part}')
                part.replace(dest)
                return
            if status not in ('301', '302', '303', '307', '308') or not url:
                raise RuntimeError(f'Unexpected HTTP {status} for {dest.name}')
        raise RuntimeError(f'Too many redirects for {dest.name}')
    finally:
        part.unlink(missing_ok=True)


def tools():
    checked_dir(DOWNLOADS)
    INPUTS.mkdir(mode=0o700)
    for name, sha, url in PINS:
        cached = DOWNLOADS / name
        if not cached.exists() and not cached.is_symlink():
            fetch(cached, sha, url)
        snapshot_input(cached, INPUTS / name, sha)
    print('All five private input copies match their pinned SHA-256 hashes', flush=True)
    pycache = Path(BUILD_ENV['PYTHONPYCACHEPREFIX'])
    if pycache.exists():
        shutil.rmtree(pycache)
    for folder, tarball in [('meson-1.8.3', PINS[3][0]),
                             ('ninja-1.13.1', PINS[4][0]),
                             ('webrtc-audio-processing-2.1', PINS[0][0])]:
        if (WORK / folder).exists():
            shutil.rmtree(WORK / folder)
        run('tar', '-xf', INPUTS / tarball, '-C', WORK)
    cache = SRC / 'subprojects/packagecache'
    cache.mkdir(parents=True, exist_ok=True)
    for name, _, _ in PINS[1:3]:
        shutil.copyfile(INPUTS / name, cache / name)
    # Always bootstrap, including on resume. Nothing under tools/ is executed.
    config = NINJA.parent / 'configure.py'
    config.write_text(config.read_text().replace(
        'subprocess.check_call(rebuild_args)',
        "subprocess.check_call([os.path.abspath(rebuild_args[0]), *rebuild_args[1:], '-j', '2'])"))
    run(PYTHON, config, '--bootstrap', '--with-python', PYTHON, cwd=NINJA.parent)


def settings(target):
    sdk_name, arch, triple = TARGETS[target]
    sdk = output('xcrun', '--sdk', sdk_name, '--show-sdk-path')
    cc = output('xcrun', '--sdk', sdk_name, '--find', 'clang')
    cpp = output('xcrun', '--sdk', sdk_name, '--find', 'clang++')
    flags = ['-target', triple, '-isysroot', sdk, '-Os', '-DNDEBUG',
             '-ffunction-sections', '-fdata-sections',
             '-ffile-prefix-map=' + str(ROOT) + '=.']
    return arch, cc, cpp, flags


def configure(target):
    arch, cc, cpp, flags = settings(target)
    build = TARGET_TREES / ('build-' + target)
    cross = WORK / (target + '.ini')
    cross.write_text(
        "[binaries]\nc = %r\ncpp = %r\nar = '/usr/bin/ar'\nstrip = '/usr/bin/strip'\n" % (cc, cpp) +
        "[host_machine]\nsystem = 'darwin'\ncpu_family = %r\ncpu = %r\nendian = 'little'\n" %
        ('aarch64' if arch == 'arm64' else 'x86_64', arch) +
        "[properties]\nneeds_exe_wrapper = true\n[built-in options]\nc_args = %r\ncpp_args = %r\nc_link_args = %r\ncpp_link_args = %r\n" %
        (flags, flags, flags, flags))
    # Only the explicit local mode can consume a retained Meson tree.
    inputs = [cross.read_text(), PINS, output(cc, '--version'), BUILD_ENV, sys.version]
    identity = json.dumps(inputs, sort_keys=True)
    marker = build / 'hail-build-identity'
    if MODE == 'release' and (build.exists() or build.is_symlink()):
        raise RuntimeError(f'Release requires a fresh target tree: {build}')
    if MODE != 'local' or not marker.is_file() or marker.read_text() != identity:
        if build.exists():
            shutil.rmtree(build)
        run(PYTHON, MESON, 'setup', build, SRC,
            '--cross-file', cross, '--wrap-mode=nodownload',
            '--force-fallback-for=absl_base,absl_flags,absl_strings,absl_numeric,absl_synchronization,absl_bad_optional_access',
            '-Ddefault_library=static', '-Dbuildtype=release', '-Doptimization=s',
            '-Db_ndebug=true')
    else:
        # tools refreshed the verified source tree; restore the wrap subproject
        # before resuming objects, retaining the archives' original mtimes.
        run(PYTHON, MESON, 'setup', '--reconfigure',
            build, SRC, '--wrap-mode=nodownload')
    options = {x['name']: x['value'] for x in json.loads(
        (build / 'meson-info/intro-buildoptions.json').read_text())}
    for key, expected in [('default_library', 'static'), ('buildtype', 'release'),
                          ('optimization', 's'), ('b_ndebug', 'true'),
                          ('c_args', flags), ('cpp_args', flags)]:
        if options[key] != expected:
            raise RuntimeError('build configuration mismatch: ' + key)
    if MODE == 'local':
        marker.write_text(identity)
    listing = output(NINJA, '-C', build, '-t', 'targets', 'all')
    objects = list(dict.fromkeys(line.rsplit(': ', 1)[0] for line in listing.splitlines()
                                if line.rsplit(': ', 1)[0].endswith('.o')))
    batches = [objects[i:i+150] for i in range(0, len(objects), 150)]
    (WORK / (target + '-batches.json')).write_text(json.dumps(batches))
    print(target, 'object batches:', [len(b) for b in batches], flush=True)
    run(NINJA, '-C', build, '-j', '2', *batches[0])


def finish(target):
    arch, _, cpp, flags = settings(target)
    build = TARGET_TREES / ('build-' + target)
    run(NINJA, '-C', build, '-j', '2')
    dest = WORK / 'out' / target
    dest.mkdir()
    includes = ['-I' + str(ROOT / 'Native/HailAEC3/include'),
                '-I' + str(SRC / 'webrtc'),
                '-I' + str(SRC / 'subprojects/abseil-cpp-20240722.0'),
                '-std=c++17']
    commands = json.loads((build / 'compile_commands.json').read_text())
    aec_command = next(c['command'] for c in commands
                       if c['file'].endswith('/aec3/echo_canceller3.cc'))
    # Internal AEC3 headers require the exact APM debug/architecture defines.
    includes += [a for a in shlex.split(aec_command) if a.startswith('-D')]
    run(cpp, *flags, *includes, '-fvisibility=hidden', '-c',
        ROOT / 'Native/HailAEC3/hail_aec3.cc', '-o', dest / 'shim.o')
    # Meson embeds many convenience-library objects in the main APM archive.
    # Merge each original object once, avoiding duplicate archive members; omit
    # the upstream example executable's main(). Use the exact Ninja inventory.
    batches = json.loads((WORK / (target + '-batches.json')).read_text())
    objects = sorted(build / obj for batch in batches for obj in batch
                     if not obj.startswith('examples/'))
    run('xcrun', 'libtool', '-static', '-D', '-o', dest / 'libHailAEC3.a',
        dest / 'shim.o', *objects)
    # Same stripped dylib proxy as the spike, now reaching APM via the C shim.
    probe = WORK / (target + '-probe.cc')
    probe.write_text('''#include <hail_aec3.h>
extern "C" int aec3_probe(int16_t* r, int16_t* c, int rate) {
#ifdef AEC3
  hail_aec3* h = hail_aec3_create(rate, 1, nullptr);
  if (!h) return -1;
  int e = hail_aec3_process_render(h, r, rate/100);
  e += hail_aec3_process_capture(h, c, rate/100);
  e += hail_aec3_delay_ms(h);
  hail_aec3_destroy(&h); return e;
#else
  return r[0] + c[0] + rate;
#endif
}
''')
    for name in ('baseline', 'aec3'):
        extra = [] if name == 'baseline' else ['-DAEC3', dest / 'libHailAEC3.a',
                                                '-framework', 'CoreFoundation']
        run(cpp, *flags, *includes, '-dynamiclib', '-Wl,-no_uuid',
            '-Wl,-install_name,@rpath/aec3-package-probe.dylib',
            '-Wl,-dead_strip', '-Wl,-exported_symbol,_aec3_probe',
            probe, *extra, '-o', dest / (name + '.dylib'))
        run('xcrun', 'strip', '-x', dest / (name + '.dylib'))
    sizes = {name: (dest / file).stat().st_size for name, file in
             [('static', 'libHailAEC3.a'), ('baseline', 'baseline.dylib'), ('aec3', 'aec3.dylib')]}
    sizes['linked_delta'] = sizes['aec3'] - sizes['baseline']
    (dest / 'sizes.json').write_text(json.dumps(sizes, indent=2) + '\n')
    print(target, json.dumps(sizes), flush=True)
    if target == 'macos-' + output('uname', '-m'):
        # Fail on native signal/ABI regressions before the other cross-builds.
        # This is inside the already gated, timed finish phase, under taskpolicy.
        smoke(dest / 'libHailAEC3.a', ROOT / 'Native/HailAEC3/include')


def smoke(archive, headers):
    if not archive.is_file() or not (headers / 'hail_aec3.h').is_file():
        raise RuntimeError(f'Missing smoke input: {archive} or {headers}/hail_aec3.h')
    sdk = output('xcrun', '--sdk', 'macosx', '--show-sdk-path')
    cc = output('xcrun', '--sdk', 'macosx', '--find', 'clang')
    cpp = output('xcrun', '--sdk', 'macosx', '--find', 'clang++')
    flags = ['-mmacosx-version-min=13.0', '-isysroot', sdk]
    with tempfile.TemporaryDirectory(prefix='smoke-', dir=WORK) as tmp:
        test = Path(tmp)
        with (test / 'smoke.c').open('x') as source:
            run('/bin/bash', SMOKE, '--emit-c', stdout=source)
        run(cc, '-std=c11', '-Os', '-Wall', '-Wextra', '-Werror', *flags,
            '-I', headers, '-c', test / 'smoke.c', '-o', test / 'smoke.o')
        run(cpp, *flags, '-Wl,-dead_strip', test / 'smoke.o', archive,
            '-framework', 'CoreFoundation', '-o', test / 'smoke')
        run(test / 'smoke')


def check_inventory(folder, files):
    expected_files = {Path(f) for f in files}
    expected_dirs = {d for f in expected_files for d in f.parents if d != Path('.')}
    if folder.is_symlink() or not folder.is_dir():
        raise RuntimeError(f'Invalid package directory: {folder}')
    if {p.relative_to(folder) for p in folder.rglob('*')} != expected_files | expected_dirs:
        raise RuntimeError(f'Unexpected package inventory: {folder}')
    for rel in expected_files | expected_dirs:
        p = folder / rel
        if p.is_symlink() or not (p.is_file() if rel in expected_files else p.is_dir()):
            raise RuntimeError(f'Invalid package entry: {p}')


def package():
    if MODE != 'release':
        raise RuntimeError('Packaging requires a fresh release build')
    out = WORK / 'out'
    headers = out / 'include'
    headers.mkdir()
    public_headers = {'hail_aec3.h', 'module.modulemap'}
    shutil.copyfile(ROOT / 'Native/HailAEC3/include/hail_aec3.h', headers / 'hail_aec3.h')
    (headers / 'module.modulemap').write_text(
        'module HailAEC3 {\n  header "hail_aec3.h"\n  export *\n  link "c++"\n  link framework "CoreFoundation"\n}\n')
    groups = {'macos': ['macos-arm64', 'macos-x86_64'], 'ios': ['ios-arm64'],
              'simulator': ['sim-arm64', 'sim-x86_64']}
    args = []
    for name, targets in groups.items():
        folder = out / name
        folder.mkdir()
        lib = folder / 'libHailAEC3.a'
        inputs = [out / t / 'libHailAEC3.a' for t in targets]
        if len(inputs) == 1:
            shutil.copyfile(inputs[0], lib)
        else:
            run('xcrun', 'lipo', '-create', *inputs, '-output', lib)
        args += ['-library', lib, '-headers', headers]
        print(name, 'slice bytes:', lib.stat().st_size, 'SHA-256:', digest(lib), flush=True)
    xc = out / 'HailAEC3.xcframework'
    check_inventory(headers, public_headers)
    run('xcodebuild', '-create-xcframework', *args, '-output', xc)
    # Xcode owns the slice metadata. Normalize unordered lists before archiving.
    manifest = xc / 'Info.plist'
    info = plistlib.loads(manifest.read_bytes())
    info['AvailableLibraries'].sort(key=lambda entry: entry['LibraryIdentifier'])
    for entry in info['AvailableLibraries']:
        entry['SupportedArchitectures'].sort()
    manifest.write_bytes(plistlib.dumps(info))
    # Copy exact upstream legal text out of verified archives, including the
    # embedded third-party notices retained by the static dependency bundle.
    notices = [(SRC / 'COPYING', 'webrtc-audio-processing COPYING'),
               (SRC / 'webrtc/LICENSE', 'WebRTC LICENSE'),
               (SRC / 'webrtc/PATENTS', 'WebRTC PATENTS'),
               (SRC / 'subprojects/abseil-cpp-20240722.0/LICENSE', 'Abseil Apache-2.0')]
    notices += [(p, str(p.relative_to(SRC))) for p in sorted((SRC / 'webrtc').rglob('*'))
                if p.name in ('LICENSE', 'COPYING') and p != SRC / 'webrtc/LICENSE']
    notice = ''.join('\n===== ' + name + ' =====\n' + p.read_text() for p, name in notices)
    (xc / 'NOTICE').write_text(notice)
    # A directory has no SwiftPM checksum. Zip with fixed timestamps, order and
    # permissions; print the SHA-256 of this actual future binaryTarget artifact.
    archive = out / 'HailAEC3.xcframework.zip'
    expected = {'Info.plist', 'NOTICE'}
    for slice_id in ('macos-arm64_x86_64', 'ios-arm64', 'ios-arm64_x86_64-simulator'):
        expected.add(slice_id + '/libHailAEC3.a')
        expected.update(slice_id + '/Headers/' + h for h in public_headers)
    check_inventory(headers, public_headers)
    check_inventory(xc, expected)
    with zipfile.ZipFile(archive, 'x', compression=zipfile.ZIP_DEFLATED, compresslevel=9) as z:
        for filename in sorted(expected):
            info = zipfile.ZipInfo(f'{xc.name}/{filename}', (2020, 1, 1, 0, 0, 0))
            info.compress_type = zipfile.ZIP_DEFLATED
            info.external_attr = 0o100644 << 16
            z.writestr(info, (xc / filename).read_bytes())
    for target in TARGETS:
        print(target, (out / target / 'sizes.json').read_text().strip(), flush=True)


def phase(args):
    # Gates wait outside the 14-minute CPU-work deadline. Never inspect/change
    # another process's priority or signal a PID that this driver did not start.
    if GATE_DIR is not None:
        gate_dir = Path(GATE_DIR).absolute()
        for gate in ('hostslot-wait.sh', 'voice-quiet.sh'):
            run('/usr/sbin/taskpolicy', '-b', gate_dir / gate)
    print('PHASE', ' '.join(args), flush=True)
    child = subprocess.Popen(['/usr/sbin/taskpolicy', '-b', '/bin/bash',
                              str(SCRIPT), '--phase', MODE, *args], cwd=WORK,
                             env=BUILD_ENV, start_new_session=True)
    def stop(*_):
        if child.returncode is None:
            # Keep the leader unreaped until signals finish, avoiding PID reuse.
            try:
                os.killpg(child.pid, signal.SIGTERM)
                time.sleep(2)  # Ninja forwards TERM to its own compiler groups.
                os.killpg(child.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            child.wait()
    old = {s: signal.signal(s, lambda *_: (stop(), sys.exit(130)))
           for s in (signal.SIGINT, signal.SIGTERM)}
    try:
        try:
            status = child.wait(timeout=840)
        except subprocess.TimeoutExpired:
            stop()
            raise RuntimeError('14-minute phase deadline exceeded')
        if status:
            raise RuntimeError('phase failed: ' + ' '.join(args))
    finally:
        stop()
        for s, handler in old.items():
            signal.signal(s, handler)


def main():
    lock = BASE / 'build.lock'
    if worker:
        checked_dir(lock)
        checked_dir(WORK)
        if Path.cwd() != WORK:
            raise RuntimeError('Internal phases require the active driver workspace')
        os.environ.clear()
        os.environ.update(BUILD_ENV)
        action, *args = ARGS[2:]
        if MODE == 'smoke':
            if action != 'smoke' or args:
                raise ValueError('Packaged smoke takes no arguments')
            check_output_tree(PUBLISHED)
            mac = PUBLISHED / 'HailAEC3.xcframework/macos-arm64_x86_64'
            smoke(mac / 'libHailAEC3.a', mac / 'Headers')
            return
        check_output_tree(WORK / 'out')
        if action in ('configure', 'objects', 'finish') and (not args or args[0] not in TARGETS):
            raise ValueError('Unknown build target')
        if action == 'tools' and not args:
            tools()
        elif action == 'configure':
            configure(*args)
        elif action == 'objects':
            target, index = args
            batches = json.loads((WORK / (target + '-batches.json')).read_text())
            run(NINJA, '-C', TARGET_TREES / ('build-' + target), '-j', '2', *batches[int(index)])
        elif action == 'finish':
            finish(*args)
        elif action == 'package' and not args:
            package()
        else:
            raise ValueError('unknown phase')
        return
    if GATE_DIR is None:
        print('host gates: none (AEC3_GATE_DIR unset)', flush=True)
    elif not GATE_DIR:
        raise ValueError('AEC3_GATE_DIR must name a hook directory when set')
    elif Path.home() != Path(pwd.getpwuid(os.getuid()).pw_dir):
        raise RuntimeError('Configured host gates require the login HOME')
    checked_dir(ROOT / 'build', create=True)
    checked_dir(BASE, create=True)
    lock.mkdir()  # Refuse concurrent drivers in this worktree.
    published = False
    try:
        if PUBLISHED.exists() or PUBLISHED.is_symlink():
            check_output_tree(PUBLISHED)
        if WORK.exists() or WORK.is_symlink():
            checked_dir(WORK)
            shutil.rmtree(WORK)
        WORK.mkdir(mode=0o700)
        for child in ('home', 'tmp', 'out'):
            (WORK / child).mkdir()
        if MODE == 'smoke':
            phase(['smoke'])
            return
        checked_dir(DOWNLOADS, create=True)
        if MODE == 'local':
            checked_dir(TARGET_TREES, create=True)
            check_output_tree(TARGET_TREES)
        phase(['tools'])
        for target in TARGETS:
            phase(['configure', target])
            batches = json.loads((WORK / (target + '-batches.json')).read_text())
            # Configure includes the first batch; finish builds the last batch
            # and archives. Only intervening batches need separate phases.
            for i in range(1, len(batches) - 1):
                phase(['objects', target, str(i)])
            phase(['finish', target])
        if MODE == 'release':
            phase(['package'])
        publish(WORK / 'out')
        published = True
    finally:
        try:
            lock.rmdir()
        except OSError as err:
            if not published:
                raise
            print(f'Warning: build lock cleanup incomplete; retained at {lock}: {err}',
                  file=sys.stderr, flush=True)


main()
PY
