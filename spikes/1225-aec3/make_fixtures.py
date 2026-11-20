#!/usr/bin/env python3
"""Local TTS, synthetic room fixtures, and bounded AEC3 measurement; stdlib only."""
import argparse
from array import array
import hashlib
import json
import math
import os
from pathlib import Path
import random
import signal
import subprocess
import sys
import time
import wave

ROOT = Path(__file__).resolve().parent
WORK = ROOT / '.work'
DURATION = 26
REPLIES = [
    ['The garden path curves past the old apple tree. The morning light falls across the stone wall. I can describe the route while you consider which direction you would like to take.',
     'The story continues beside the river as we discuss the route and choose our next steps.',
     'That completes the example. The rest of the reply continues calmly.'],
    ['The workshop has three wooden shelves beside the window. A small blue box holds the spare parts. We can look through the labels together before choosing the tools for the afternoon project.',
     'We sort the tools by their labels while discussing the project and the next steps.',
     'The example has finished. We can continue with the remaining details.'],
]


def phase(command):
    """One quiet-gated background phase, bounded to 14 minutes after the gate."""
    WORK.mkdir(exist_ok=True)
    lock = WORK / 'phase.lock'
    lock.mkdir()  # Refuse concurrent lab builds/runs; never touch foreign PIDs.
    p = None
    old = {}
    def kill(*_):
        if p is not None and p.returncode is None:
            # An unreaped child still owns its PID/group: no stale-PID signalling.
            try:
                # Ninja creates child groups; TERM lets it forward the signal
                # to its own tracked compiler jobs before the final KILL.
                os.killpg(p.pid, signal.SIGTERM)
                # Do not reap the leader during this grace period: its PID
                # cannot be reused for a foreign group before the KILL.
                time.sleep(2)
                os.killpg(p.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            p.wait()
    def interrupted(*_):
        kill()
        raise KeyboardInterrupt
    try:
        old = {s: signal.signal(s, interrupted) for s in (signal.SIGINT, signal.SIGTERM)}
        quiet = os.environ.get('VOICE_QUIET')
        if not quiet:
            raise ValueError('Set VOICE_QUIET to the owner-provided quiet-gap script')
        if not Path(quiet).is_file() or not Path('/usr/sbin/taskpolicy').is_file():
            raise ValueError('quiet script and taskpolicy must exist before waiting')
        # The voice gate itself waits without consuming build/measurement time.
        p = subprocess.Popen([quiet], start_new_session=True)
        if p.wait():
            raise RuntimeError('voice-quiet gate failed')
        p = subprocess.Popen(['/usr/sbin/taskpolicy', '-b'] + command,
                             env=dict(os.environ, AEC3_PHASE='1'), start_new_session=True)
        try:
            status = p.wait(timeout=840)
        except subprocess.TimeoutExpired:
            kill()
            raise RuntimeError('phase exceeded 14 minutes; own process group killed')
        if status:
            raise subprocess.CalledProcessError(status, command)
    finally:
        kill()  # Only signal a still-unreaped process group created above.
        for sig, handler in old.items():
            signal.signal(sig, handler)
        lock.rmdir()


def bounded(command, seconds, **kwargs):
    # Children inherit the phase's process group, so its deadline covers them.
    subprocess.run(command, timeout=seconds, check=True, **kwargs)


def read_wav(path, rate):
    with wave.open(str(path), 'rb') as f:
        if (f.getnchannels(), f.getsampwidth(), f.getframerate()) != (1, 2, rate):
            raise ValueError('TTS did not produce mono PCM16 at requested rate')
        frames = f.getnframes()
        result = array('h', f.readframes(frames))
        if len(result) != frames:
            raise ValueError('truncated PCM in TTS WAV')
    if sys.byteorder != 'little':
        result.byteswap()
    return array('f', (x / 32768 for x in result))


def write_wav(path, rate, values):
    pcm = array('h', (max(-32768, min(32767, round(x * 32768))) for x in values))
    if sys.byteorder != 'little':
        pcm.byteswap()
    with wave.open(str(path), 'wb') as f:
        f.setnchannels(1)
        f.setsampwidth(2)
        f.setframerate(rate)
        f.writeframes(pcm.tobytes())


def speech(folder, name, text, voice, rate):
    # Cache only completed, validated synthesis; never retry a failed call in
    # the same phase or manipulate the host's shared speech service.
    source_rate = 16000
    params = [text, voice, source_rate, 185]
    key = hashlib.sha256(json.dumps(params).encode()).hexdigest()
    cache = folder / 'tts-cache'
    cache.mkdir(exist_ok=True)
    path, meta = cache / (key+'.wav'), cache / (key+'.json')
    if path.exists() and meta.exists():
        record = json.loads(meta.read_text())
        if record['params'] != params or record['sha256'] != hashlib.sha256(path.read_bytes()).hexdigest():
            raise ValueError('TTS cache digest/parameter mismatch')
        audio = read_wav(path, source_rate)
    else:
        temporary = cache / (key+'.partial.wav')
        if temporary.exists():
            temporary.unlink()
        bounded(['/usr/bin/say', '-v', voice, '-r', '185', '--file-format=WAVE',
                 '--data-format=LEI16@%d' % source_rate, '-o', str(temporary), text], 120)
        audio = read_wav(temporary, source_rate)
        if len(audio) < source_rate//20 or max(abs(x) for x in audio) == 0:
            raise ValueError('empty/silent TTS output')
        temporary.replace(path)
        record = {'params': params, 'sha256': hashlib.sha256(path.read_bytes()).hexdigest()}
        pending = meta.with_suffix('.partial.json')
        pending.write_text(json.dumps(record, indent=2)+'\n')
        pending.replace(meta)
    if rate == 48000:
        # Actual 48 kHz APM input, derived from 16 kHz speech. This is not a
        # native wideband speech-quality test; report that limitation.
        upsampled = array('f')
        for i, value in enumerate(audio):
            following = audio[min(i+1, len(audio)-1)]
            step = (following-value)/3
            upsampled.extend((value, value+step, value+2*step))
        audio = upsampled
    write_wav(folder/(name+'.wav'), rate, audio)
    return audio


def place(destination, source, start, rate, slot_end):
    offset = round(start * rate)
    if offset + len(source) > round(slot_end * rate):
        raise ValueError('TTS exceeds its fixed slot; use a faster speech rate')
    destination[offset:offset + len(source)] = source
    return [start, start + len(source) / rate]


def generate(args):
    folder = Path(args.directory).resolve()
    if WORK not in folder.parents:
        raise ValueError('generated fixtures must be under this spike .work/')
    folder.mkdir(parents=True, exist_ok=True)
    if args.render_voice == args.near_voice:
        raise ValueError('render and near-end require different voices')
    manifest = {'schema': 1, 'duration_seconds': DURATION, 'render_voice': args.render_voice,
                'near_voice': args.near_voice, 'near_gain': .5, 'seed': 1225, 'cases': [],
                'tts_source_rate': 16000, 'resampling': '48 kHz speech is 3x linear interpolation of 16 kHz TTS; not native wideband',
                'room': {'gain': .55, 'softclip': 'tanh(1.15*x)/1.15',
                         'noise_uniform_peak': .0005, 'decay_seconds': .055,
                         'description': 'direct path plus 20 sparse signed taps, exponential amplitude envelope; cutoff 243 ms'}}
    # Finish all service-backed speech requests first, close to the quiet gap.
    # Room convolution/mixing afterwards only reads completed local cache files.
    for rate in (16000, 48000):
        speech(folder, 'near-stop-%d' % rate, 'Stop.', args.near_voice, rate)
        speech(folder, 'near-request-%d' % rate,
               'Which road leads to the river?', args.near_voice, rate)
        for reply, text in enumerate(REPLIES, 1):
            for part, words in zip(('prefix', 'bridge', 'suffix', 'stop', 'cancel'),
                                   text + ['Stop.', 'Cancel.']):
                speech(folder, 'r%d-%s-%d' % (reply, part, rate), words, args.render_voice, rate)
    for rate in (16000, 48000):
        n = DURATION * rate
        near = array('f', [0]) * n
        near_stop = speech(folder, 'near-stop-%d' % rate, 'Stop.', args.near_voice, rate)
        near_request = speech(folder, 'near-request-%d' % rate,
                              'Which road leads to the river?', args.near_voice, rate)
        # With room bounded by .55/1.15, half-scale near-end leaves
        # guaranteed PCM headroom even if TTS reaches full scale.
        near_stop = array('f', (x*.5 for x in near_stop))
        near_request = array('f', (x*.5 for x in near_request))
        double = [place(near, near_stop, 8, rate, 10),
                  place(near, near_request, 17, rate, 20)]
        near_name = 'near-%d.wav' % rate
        write_wav(folder / near_name, rate, near)
        near = read_wav(folder / near_name, rate)  # Mix the exact PCM ground truth.
        for reply, text in enumerate(REPLIES, 1):
            render = array('f', [0]) * n
            render_segments = []
            for part, start, end, words in [('prefix', .5, 12.5, text[0]),
                                           ('bridge', 14, 20, text[1]),
                                           ('suffix', 21, 26, text[2])]:
                audio = speech(folder, 'r%d-%s-%d' % (reply, part, rate), words, args.render_voice, rate)
                render_segments.append(place(render, audio, start, rate, end))
            stop = speech(folder, 'r%d-stop-%d' % (reply, rate), 'Stop.', args.render_voice, rate)
            own_stop = place(render, stop, 13, rate, 14)
            cancel = speech(folder, 'r%d-cancel-%d' % (reply, rate), 'Cancel.', args.render_voice, rate)
            own_cancel = place(render, cancel, 20, rate, 21)
            render_name = 'render-r%d-%d.wav' % (reply, rate)
            write_wav(folder / render_name, rate, render)
            render = read_wav(folder / render_name, rate)
            rng = random.Random(1225)
            taps = [(0, 1.0)]
            for k in range(1, 21):
                seconds = .012*k + rng.uniform(-.003, .003)
                taps.append((round(seconds*rate), rng.choice([-1, 1]) * .32 * math.exp(-seconds/.055)))
            room = array('f', [0]) * n
            for lag, gain in taps:
                for i in range(lag, n):
                    room[i] += gain * render[i-lag]
            room = array('f', (.55 * math.tanh(1.15*x) / 1.15 for x in room))
            for delay in (40, 120, 250):
                for start, end in double:
                    if not any(min(end, b + delay/1000) - max(start, a + delay/1000) > .25
                               for a, b in render_segments):
                        raise ValueError('near-end segment must overlap delayed render speech')
                shift = round(delay*rate/1000)
                rng = random.Random(1225)
                capture = array('f', (near[i] + (room[i-shift] if i >= shift else 0)
                                     + rng.uniform(-.0005, .0005) for i in range(n)))
                if max(abs(x) for x in capture) >= 1:
                    raise ValueError('fixture clipped at PCM conversion')
                name = 'r%d-%d-d%d' % (reply, rate, delay)
                capture_name = 'capture-%s.wav' % name
                write_wav(folder / capture_name, rate, capture)
                # Ignore adaptation and guard all near-end intervals by >=400 ms.
                echo = [[3, 7.5], [10.5, 12.5], [14.5, 16.5], [21.5, 25.5]]
                own = [[own_stop[0] + delay/1000,
                        min(own_stop[1] + delay/1000 + .243, 14 + delay/1000 - .01)]]
                manifest['cases'].append({'id': name, 'rate': rate, 'reply': reply, 'delay_ms': delay,
                    'render': render_name, 'capture': capture_name, 'near': near_name,
                    'echo_only': echo, 'double_talk': double, 'self_stop': own,
                    'render_stop': own_stop, 'render_cancel': own_cancel, 'render_segments': render_segments, 'room_taps': taps})
    inputs = {case[key] for case in manifest['cases'] for key in ('render', 'capture', 'near')}
    manifest['sha256'] = {name: hashlib.sha256((folder/name).read_bytes()).hexdigest()
                          for name in sorted(inputs)}
    (folder / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
    print('generated %d cases in %s' % (len(manifest['cases']), folder))


def measure(args):
    folder = Path(args.directory).resolve()
    if WORK not in folder.parents:
        raise ValueError('measurement outputs must be under this spike .work/')
    manifest = json.loads((folder / 'manifest.json').read_text())
    for filename, digest in manifest['sha256'].items():
        if hashlib.sha256((folder / filename).read_bytes()).hexdigest() != digest:
            raise ValueError('fixture digest mismatch: ' + filename)
    if not args.label.replace('-', '').replace('_', '').isalnum():
        raise ValueError('label must be alphanumeric with optional hyphens/underscores')
    results = []
    for case in manifest['cases']:
        output = folder / ('out-%s-%s.wav' % (args.label, case['id']))
        command = [str(Path(args.executable).resolve()), str(folder/case['render']),
                   str(folder/case['capture']), str(output), '--near', str(folder/case['near'])]
        for key, flag in [('echo_only', '--echo'), ('double_talk', '--double'), ('self_stop', '--stop')]:
            for start, end in case[key]:
                command += [flag, '%s:%s' % (start, end)]
        log = folder / ('result-%s-%s.json' % (args.label, case['id']))
        with log.open('w') as stream:
            bounded(command, 90, stdout=stream)
        result = json.loads(log.read_text())
        with wave.open(str(output), 'rb') as audio:
            expected = (1, 2, case['rate'], round(manifest['duration_seconds']*case['rate']))
            actual = (audio.getnchannels(), audio.getsampwidth(), audio.getframerate(), audio.getnframes())
            if actual != expected or result['frames'] != expected[3]//(case['rate']//100):
                raise ValueError('output format/frame count mismatch')
        if result['ns'] or result['agc2']:
            raise ValueError('baseline measurement must have NS and AGC off')
        result['output_sha256'] = hashlib.sha256(output.read_bytes()).hexdigest()
        result.update({k: case[k] for k in ('id', 'reply', 'delay_ms')})
        results.append(result)
    (folder / ('results-%s.json' % args.label)).write_text(json.dumps(results, indent=2)+'\n')
    print('measured %d cases: %s' % (len(results), folder / ('results-%s.json' % args.label)))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest='mode', required=True)
    p = sub.add_parser('generate')
    p.add_argument('--directory', default=str(WORK/'fixtures'))
    p.add_argument('--render-voice', default='Samantha')
    p.add_argument('--near-voice', default='Daniel')
    p.set_defaults(run=generate)
    p = sub.add_parser('measure')
    p.add_argument('--directory', default=str(WORK/'fixtures'))
    p.add_argument('--executable', default=str(WORK/'artifacts/macos/aec3_lab'))
    p.add_argument('--label', required=True)
    p.set_defaults(run=measure)
    p = sub.add_parser('phase')
    p.add_argument('command', nargs=argparse.REMAINDER)
    args = parser.parse_args()
    if args.mode == 'phase':
        command = args.command[1:] if args.command[:1] == ['--'] else args.command
        if not command:
            parser.error('phase requires a command')
        phase(command)
    elif os.environ.get('AEC3_PHASE') != '1':
        phase([sys.executable, str(Path(__file__).resolve())] + sys.argv[1:])
    else:
        args.run(args)


if __name__ == '__main__':
    main()
