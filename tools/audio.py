"""Speech, sound effects and music -> gamedata/audio.

speech/<voice>_<msg>.wav   INTEL/SPEECH.PAK: PAK per voice (profile SPCH id) of VOC clips per message
sfx/<id>_<name>.wav        SOUND/DSOUNDFX.PAK: PAK of PAKs of VOC clips (ids below)
music/<set>_<n>.mid        XMIDI songs (COMBAT.MID, GAMEFLOW.MID, MIDGAMES/MMUSIC.PAK) as Standard MIDI;
music/<set>_<n>.mp3        rendered with FluidSynth + a General MIDI SoundFont when available.
"""
import io, json, os, shutil, struct, subprocess, sys, wave
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import pak
from shape import pak_entries

SFX_NAMES = {0: 'mk82_drop', 1: 'mk20_drop', 2: 'explosion_1', 3: 'explosion_2', 4: 'explosion_3',
             5: 'explosion_4', 6: 'aim9_shoot', 7: 'aim120_shoot', 8: 'pod_shoot', 9: 'maverick_shoot',
             10: 'gun_impact_1', 11: 'gun_impact_2', 12: 'gun_impact_3', 13: 'gun_impact_4',
             14: 'gun_impact_5', 15: 'gun_impact_6', 16: 'pass_by_1', 17: 'pass_by_2', 18: 'pass_by_3',
             19: 'gear_up', 20: 'gear_down', 21: 'touch_down', 22: 'unknown_22', 23: 'engine_mil',
             24: 'engine_afb', 25: 'engine_start_mil', 26: 'engine_start_afb', 27: 'engine_shut_down',
             28: 'engine_mil_shut_down', 29: 'engine_afb_shut_down', 30: 'engine_afb_to_mil', 31: 'unknown_31'}


# ---------------------------------------------------------------- Creative Voice
def voc_to_pcm(data):
    """Return (sample_rate, unsigned 8-bit mono PCM bytes) from a Creative Voice File."""
    if not data.startswith(b'Creative Voice File'):
        return None
    p = struct.unpack_from('<H', data, 20)[0]
    rate, pcm = 11025, bytearray()
    while p < len(data):
        btype = data[p]
        if btype == 0:
            break
        size = data[p + 1] | (data[p + 2] << 8) | (data[p + 3] << 16)
        body = data[p + 4:p + 4 + size]
        if btype == 1 and len(body) >= 2:
            rate = int(1000000 / (256 - body[0]))
            if body[1] == 0:       # 8-bit unsigned PCM
                pcm += body[2:]
        elif btype == 2:
            pcm += body
        elif btype == 3 and len(body) >= 3:
            length = struct.unpack_from('<H', body)[0] + 1
            pcm += b'\x80' * length
        elif btype == 9 and len(body) >= 12:
            rate = struct.unpack_from('<I', body)[0]
            bits, channels, codec = body[4], body[5], struct.unpack_from('<H', body, 6)[0]
            if bits == 8 and channels == 1 and codec == 0:
                pcm += body[12:]
        p += 4 + size
    return rate, bytes(pcm)


def write_wav(path, rate, pcm8):
    if len(pcm8) % 2:
        pcm8 += b'\x80'   # RIFF chunks are word-aligned; keep the data chunk even
    with wave.open(path, 'wb') as w:
        w.setnchannels(1)
        w.setsampwidth(1)
        w.setframerate(rate)
        w.writeframes(pcm8)


def pak_tree(blob, depth=0):
    """Leaves of nested PAKs (VOC files or XMIDI forms)."""
    if blob.startswith(b'Creative') or blob.startswith(b'FORM') or blob.startswith(b'CAT ') or depth > 4:
        return [blob]
    try:
        entries = pak.read_pak(blob)
    except Exception:
        return [blob]
    return entries


# ---------------------------------------------------------------- XMIDI -> SMF
def _varlen(n):
    out = [n & 0x7F]
    n >>= 7
    while n:
        out.append((n & 0x7F) | 0x80)
        n >>= 7
    return bytes(reversed(out))


def xmidi_events(form):
    """Find EVNT chunks inside an XMIDI FORM/CAT and return their payloads."""
    out, p = [], 0
    while True:
        p = form.find(b'EVNT', p)
        if p < 0:
            return out
        size = struct.unpack_from('>I', form, p + 4)[0]
        out.append(form[p + 8:p + 8 + size])
        p += 8 + size


def parse_evnt(evnt):
    """XMIDI EVNT -> list of (tick, order, midi bytes) at 120 ticks/s (note-ons expanded into
    note-on/off pairs), plus markers: tempo / time-signature changes and FOR/NEXT loop points."""
    events, marks = [], {'tempo': [], 'tsig': [], 'for': None, 'next': None, 'end': 0}
    t, p, n = 0, 0, len(evnt)

    def varlen(q):
        v = 0
        while True:
            c = evnt[q]; q += 1
            v = (v << 7) | (c & 0x7F)
            if c < 0x80:
                return v, q
    while p < n:
        b = evnt[p]
        if b < 0x80:   # delay: sum of bytes, a 0x7F continues
            while p < n and evnt[p] < 0x80:
                t += evnt[p]
                if evnt[p] != 0x7F:
                    p += 1
                    break
                p += 1
            continue
        status = b
        p += 1
        kind = status & 0xF0
        if status == 0xFF:
            mtype = evnt[p]
            length, q = varlen(p + 1)
            meta = evnt[q:q + length]
            p = q + length
            if mtype == 0x2F:
                break
            if mtype == 0x51:
                marks['tempo'].append((t, int.from_bytes(meta, 'big')))
                continue  # XMIDI playback is a fixed 120 Hz; tempo only drives beat/bar counting
            if mtype == 0x58:
                marks['tsig'].append((t, meta[0], 2 ** meta[1]))
            events.append((t, 1, bytes([0xFF, mtype]) + _varlen(len(meta)) + meta))
        elif status in (0xF0, 0xF7):
            length, q = varlen(p)
            p = q + length
        elif kind == 0x90:
            note, vel = evnt[p], evnt[p + 1]
            dur, p = varlen(p + 2)
            events.append((t, 2, bytes([status, note, vel])))
            events.append((t + dur, 0, bytes([0x80 | (status & 0x0F), note, 0])))
        elif kind in (0xC0, 0xD0):
            events.append((t, 1, bytes([status, evnt[p]])))
            p += 1
        else:
            ctl, val = evnt[p], evnt[p + 1]
            p += 2
            if kind == 0xB0 and ctl == 116 and marks['for'] is None:
                marks['for'] = t
            elif kind == 0xB0 and ctl == 117 and marks['for'] is not None and marks['next'] is None:
                marks['next'] = t
            if kind == 0xB0 and 110 <= ctl <= 120:
                continue   # AIL/XMIDI control markers, not musical
            events.append((t, 1, bytes([status, ctl, val])))
    marks['end'] = t
    return events, marks


def unroll(events, marks):
    f, nx = marks['for'], marks['next']
    if f is None or nx is None or nx <= f:
        return events, max([e[0] for e in events] + [marks['end']]), None
    body = nx - f
    # pair note-ons with their offs so the second pass keeps each note's own duration
    out = []
    pending = {}
    for e in sorted(events, key=lambda e: (e[0], e[1])):
        out.append(e)
    second = []
    ons = [(i, e) for i, e in enumerate(events) if (e[2][0] & 0xF0) == 0x90]
    for e in events:
        k = e[2][0] & 0xF0
        if f <= e[0] < nx and k != 0x80:
            second.append((e[0] + body, e[1], e[2]))
    # note-offs: each note-on at index i is followed in `events` by its off at index i + 1
    for i, e in enumerate(events):
        if (e[2][0] & 0xF0) == 0x90 and f <= e[0] < nx and i + 1 < len(events):
            off = events[i + 1]
            second.append((off[0] + body, off[1], off[2]))
    keep = [e for e in out if e[0] < nx or (e[2][0] & 0xF0) == 0x80]
    return keep + second, nx + body, nx


def bar_ticks(marks, end_tick, loop_from=None, loop_to=None):
    """Bar start ticks over [0, end_tick] from the tempo (µs per quarter) and time signature
    events, the way the original driver counts measures."""
    tempos = sorted(marks['tempo']) or [(0, 500000)]
    tsigs = sorted(marks['tsig']) or [(0, 4, 4)]
    if loop_from is not None:   # the unrolled second body repeats the body's changes
        body = loop_to - loop_from
        tempos += [(t + body, v) for t, v in marks['tempo'] if loop_from <= t < loop_to]
        tsigs += [(t + body, a, b) for t, a, b in marks['tsig'] if loop_from <= t < loop_to]
        tempos.sort(); tsigs.sort()
    bars, t = [], 0.0
    while t < end_tick:
        bars.append(round(t, 2))
        tempo = [v for tt, v in tempos if tt <= t + 1e-6][-1]
        num, den = [(a, b) for tt, a, b in tsigs if tt <= t + 1e-6][-1]
        bar_len = 120.0 * tempo / 1e6 * 4.0 / den * num
        nxt = t + bar_len
        changes = [tt for tt, *_ in tempos + tsigs if t + 1e-6 < tt < nxt - 1e-6]
        t = min(changes) if changes else nxt   # a change mid-bar starts a new bar
    return bars


def write_smf(events, path, end_tick=None):
    events = sorted(events, key=lambda e: (e[0], e[1]))
    trk = bytearray()
    trk += b'\x00\xFF\x51\x03' + (500000).to_bytes(3, 'big')   # 60 ticks per quarter at 120 Hz
    last = 0
    for at, _, data in events:
        trk += _varlen(at - last) + data
        last = at
    trk += _varlen(max(0, (end_tick or last) - last)) + b'\xFF\x2F\x00'
    with open(path, 'wb') as fh:
        fh.write(b'MThd' + struct.pack('>IHHH', 6, 0, 1, 60) + b'MTrk' + struct.pack('>I', len(trk)) + trk)


def evnt_to_smf(evnt):
    events, marks = parse_evnt(evnt)
    import tempfile
    with tempfile.NamedTemporaryFile(suffix='.mid', delete=False) as tf:
        write_smf(events, tf.name, marks['end'])
        data = open(tf.name, 'rb').read()
    os.remove(tf.name)
    return data


# ---------------------------------------------------------------- rendering
def find_soundfont(explicit=None):
    candidates = [explicit, os.environ.get('SC_SOUNDFONT'),
                  os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), 'soundfonts', 'default.sf2')]
    for c in candidates:
        if c and os.path.exists(c):
            return c
    return None


def render(mid_path, out_path, soundfont, trim_s=None):
    """MIDI -> Ogg Vorbis via FluidSynth. `trim_s` cuts the audio at an exact time (loop end)."""
    fs = shutil.which('fluidsynth')
    ff = shutil.which('ffmpeg')
    if not fs or not soundfont or not ff:
        return False
    wav = out_path[:-4] + '.tmp.wav'
    r = subprocess.run([fs, '-ni', '-g', '0.8', '-r', '44100', '-F', wav, soundfont, mid_path], capture_output=True)
    if r.returncode != 0 or not os.path.exists(wav):
        return False
    af = ['-af', 'atrim=end=%.4f' % trim_s] if trim_s else ['-af', 'silenceremove=stop_periods=1:stop_duration=1.5:stop_threshold=-60dB']
    subprocess.run([ff, '-y', '-loglevel', 'error', '-i', wav] + af + ['-c:a', 'vorbis', '-strict', '-2', '-q:a', '7', out_path],
                   capture_output=True)
    os.remove(wav)
    return os.path.exists(out_path)


def parse_dat(dat):
    """Transition tables (record 0 of COMBAT.DAT / GAMEFLOW.DAT): u8 N; N x (phraseLen, phraseLast);
    N x N matrix (0xFF = none); u8 E; E x (u8 L, L + 1 link values: 0 = cut, n = link track n-1,
    bit 7 = the current track keeps playing under the link)."""
    rec = [b for _, b in pak.read_pak(dat)][0]
    p = 0
    n = rec[p]; p += 1
    plen = [rec[p + 2 * i] for i in range(n)]
    plast = [rec[p + 2 * i + 1] for i in range(n)]
    p += 2 * n
    matrix = list(rec[p:p + n * n]); p += n * n
    e = rec[p]; p += 1
    links = []
    for _ in range(e):
        L = rec[p] + 1; p += 1
        links.append(list(rec[p:p + L])); p += L
    return {'track_count': n, 'phrase_len': plen, 'phrase_last': plast, 'matrix': matrix, 'links': links}


# ---------------------------------------------------------------- conversion
def convert(extracted, out_root, soundfont=None, log=print):
    out = os.path.join(out_root, 'audio')
    for sub in ('speech', 'sfx', 'music'):
        os.makedirs(os.path.join(out, sub), exist_ok=True)
    index = {'speech': {}, 'sfx': {}, 'music': {}}
    # speech
    for tre, prefix in (('LILTRE', ''), ('TOBIGTRE', 'to_')):
        f = os.path.join(extracted, tre, 'DATA', 'INTEL', 'SPEECH.PAK')
        if not os.path.exists(f):
            continue
        for v, vblob in enumerate(pak_entries(open(f, 'rb').read())):
            for m, mblob in enumerate(pak_entries(vblob) if len(vblob) > 8 else []):
                r = voc_to_pcm(mblob)
                if r and r[1]:
                    name = f'{prefix}{v}_{m}.wav'
                    write_wav(os.path.join(out, 'speech', name), r[0], r[1])
                    index['speech'][f'{prefix}{v}_{m}'] = name
    # sound effects
    f = os.path.join(extracted, 'LILTRE', 'DATA', 'SOUND', 'DSOUNDFX.PAK')
    if os.path.exists(f):
        sounds = []
        for blob in pak_entries(open(f, 'rb').read()):
            sounds += pak_entries(blob)
        for i, b in enumerate(sounds):
            r = voc_to_pcm(b)
            if r and r[1]:
                name = f'{i}_{SFX_NAMES.get(i, "sfx")}.wav'
                write_wav(os.path.join(out, 'sfx', name), r[0], r[1])
                index['sfx'][SFX_NAMES.get(i, str(i))] = name
    # music (General MIDI versions): each song loops itself with XMIDI FOR/NEXT markers; it is
    # unrolled once (intro + body + body) so the Ogg loops seamlessly from the second body.
    sf = find_soundfont(soundfont)
    snd = os.path.join(extracted, 'LILTRE', 'DATA', 'SOUND')
    sets = {'combat': (os.path.join(snd, 'COMBAT.MID'), os.path.join(snd, 'COMBAT.DAT')),
            'gameflow': (os.path.join(snd, 'GAMEFLOW.MID'), os.path.join(snd, 'GAMEFLOW.DAT')),
            'midgames': (os.path.join(extracted, 'BIGTRE', 'DATA', 'MIDGAMES', 'MMUSIC.PAK'), None)}
    rendered = 0
    index['music'] = {}
    index['music_sets'] = {}
    for set_name, (f, dat) in sets.items():
        if not os.path.exists(f):
            continue
        songs, link_songs = _collect_xmidi(open(f, 'rb').read(), set_name)
        entries = []
        for i, form in enumerate(songs):
            entry = _render_song(form, os.path.join(out, 'music', f'{set_name}_{i}'), sf, loop=True)
            rendered += 1 if entry else 0
            entries.append(entry)
        links = [_render_song(form, os.path.join(out, 'music', f'{set_name}_link_{k}'), sf, loop=False)
                 for k, form in enumerate(link_songs)]
        index['music'][set_name] = entries
        info = {'link_tracks': links}
        if dat and os.path.exists(dat):
            info.update(parse_dat(open(dat, 'rb').read()))
        index['music_sets'][set_name] = info
    with open(os.path.join(out, 'audio.json'), 'w') as fh:
        json.dump(index, fh, indent=1)
    log(f"  {len(index['speech'])} speech clips, {len(index['sfx'])} sound effects, "
        f"{sum(len(v) for v in index['music'].values())} songs + {sum(len(v['link_tracks']) for v in index['music_sets'].values())} links ({rendered} rendered"
        f"{'' if sf else '; no SoundFont found — set SC_SOUNDFONT or put soundfonts/default.sf2'})")


def _collect_xmidi(blob, set_name):
    """(songs, link songs). COMBAT/GAMEFLOW: one set = PAK whose entry 0 is an archive of link
    (transition) tracks and entries 1.. are the songs. MMUSIC.PAK: a flat list of songs."""
    def forms(b, depth=0):
        if b.startswith(b'FORM') or b.startswith(b'CAT '):
            return [b]
        if depth > 4 or len(b) < 8:
            return []
        try:
            return [x for _, e in pak.read_pak(b) for x in forms(e, depth + 1)]
        except Exception:
            return []
    if set_name == 'midgames':
        return forms(blob), []
    songs, links = [], []
    for _, set_blob in pak.read_pak(blob):
        entries = pak.read_pak(set_blob)
        if entries and not entries[0][1].startswith(b'FORM'):
            links += forms(entries[0][1])
            entries = entries[1:]
        for _, e in entries:
            songs += forms(e)
    return songs, links


def _render_song(form, base, sf, loop):
    evs = xmidi_events(form)
    if not evs:
        return None
    events, marks = parse_evnt(evs[0])
    loop_start = None
    end_tick = max([e[0] for e in events] + [marks['end']])
    if loop and marks['for'] is not None and marks['next'] is not None and marks['next'] > marks['for']:
        events, end_tick, loop_start = unroll(events, marks)
        bars = bar_ticks(marks, end_tick, marks['for'], marks['next'])
    else:
        bars = bar_ticks(marks, end_tick)
    write_smf(events, base + '.mid', end_tick)
    ogg = base + '.ogg'
    trim = end_tick / 120.0 if loop_start is not None else None
    if not (os.path.exists(ogg) or render(base + '.mid', ogg, sf, trim)):
        return None
    return {'file': os.path.basename(ogg), 'end_s': round(end_tick / 120.0, 4),
            'loop_start_s': round(loop_start / 120.0, 4) if loop_start is not None else None,
            'body_s': round((marks['next'] - marks['for']) / 120.0, 4) if loop_start is not None else None,
            'bars_s': [round(b / 120.0, 4) for b in bars]}


if __name__ == '__main__':
    convert(sys.argv[1], sys.argv[2])
