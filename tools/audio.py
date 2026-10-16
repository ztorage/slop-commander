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


def evnt_to_smf(evnt):
    """XMIDI EVNT -> single-track Standard MIDI File. XMIDI runs at 120 ticks per second, uses
    7-bit summed delays and note-ons carrying their own duration (no note-offs)."""
    events = []        # (abs_tick, order, bytes)
    t, p, n = 0, 0, len(evnt)
    while p < n:
        b = evnt[p]
        if b < 0x80:   # delay: sum of bytes until one < 0x7F
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
            length, q = 0, p + 1
            while True:
                c = evnt[q]; q += 1
                length = (length << 7) | (c & 0x7F)
                if c < 0x80:
                    break
            meta = evnt[q:q + length]
            p = q + length
            if mtype == 0x2F:
                break
            if mtype == 0x51:
                continue  # XMIDI tempo is fixed; drop tempo changes
            events.append((t, 1, bytes([0xFF, mtype]) + _varlen(len(meta)) + meta))
        elif status in (0xF0, 0xF7):
            length, q = 0, p
            while True:
                c = evnt[q]; q += 1
                length = (length << 7) | (c & 0x7F)
                if c < 0x80:
                    break
            p = q + length
        elif kind == 0x90:
            note, vel = evnt[p], evnt[p + 1]
            p += 2
            dur, shift = 0, 0
            dur_bytes = []
            while True:
                c = evnt[p]; p += 1
                dur_bytes.append(c)
                if c < 0x80:
                    break
            for c in dur_bytes:
                dur = (dur << 7) | (c & 0x7F)
            events.append((t, 1, bytes([status, note, vel])))
            events.append((t + dur, 0, bytes([0x80 | (status & 0x0F), note, 0])))
        elif kind in (0xC0, 0xD0):
            events.append((t, 1, bytes([status, evnt[p]])))
            p += 1
        else:
            events.append((t, 1, bytes([status, evnt[p], evnt[p + 1]])))
            p += 2
    events.sort(key=lambda e: (e[0], e[1]))
    trk = bytearray()
    # 120 Hz ticks: tempo 500000 us/qn with 60 ticks per quarter note
    trk += b'\x00\xFF\x51\x03' + (500000).to_bytes(3, 'big')
    last = 0
    for at, _, data in events:
        trk += _varlen(at - last) + data
        last = at
    trk += b'\x00\xFF\x2F\x00'
    return b'MThd' + struct.pack('>IHHH', 6, 0, 1, 60) + b'MTrk' + struct.pack('>I', len(trk)) + trk


# ---------------------------------------------------------------- rendering
def find_soundfont(explicit=None):
    candidates = [explicit, os.environ.get('SC_SOUNDFONT'),
                  os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), 'soundfonts', 'default.sf2')]
    for c in candidates:
        if c and os.path.exists(c):
            return c
    return None


def render(mid_path, out_path, soundfont):
    fs = shutil.which('fluidsynth')
    if not fs or not soundfont:
        return False
    wav = out_path[:-4] + '.wav'
    r = subprocess.run([fs, '-ni', '-g', '0.8', '-r', '44100', '-F', wav, soundfont, mid_path], capture_output=True)
    if r.returncode != 0 or not os.path.exists(wav):
        return False
    ff = shutil.which('ffmpeg')
    if ff:
        subprocess.run([ff, '-y', '-loglevel', 'error', '-i', wav, '-af', 'silenceremove=stop_periods=1:stop_duration=1.5:stop_threshold=-60dB',
                        '-c:a', 'libmp3lame', '-b:a', '192k', out_path], capture_output=True)
        if os.path.exists(out_path):
            os.remove(wav)
            return True
    os.replace(wav, out_path[:-4] + '.wav')
    return True


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
    # music (General MIDI versions)
    sf = find_soundfont(soundfont)
    sets = {'combat': os.path.join(extracted, 'LILTRE', 'DATA', 'SOUND', 'COMBAT.MID'),
            'gameflow': os.path.join(extracted, 'LILTRE', 'DATA', 'SOUND', 'GAMEFLOW.MID'),
            'midgames': os.path.join(extracted, 'BIGTRE', 'DATA', 'MIDGAMES', 'MMUSIC.PAK')}
    rendered = 0
    for set_name, f in sets.items():
        if not os.path.exists(f):
            continue
        songs = _collect_xmidi(open(f, 'rb').read(), set_name)
        index['music'][set_name] = []
        for i, form in enumerate(songs):
            evs = xmidi_events(form)
            if not evs:
                index['music'][set_name].append(None)
                continue
            mid = os.path.join(out, 'music', f'{set_name}_{i}.mid')
            with open(mid, 'wb') as fh:
                fh.write(evnt_to_smf(evs[0]))
            mp3 = mid[:-4] + '.mp3'
            if os.path.exists(mp3) or render(mid, mp3, sf):
                rendered += 1
                index['music'][set_name].append(os.path.basename(mp3))
            else:
                index['music'][set_name].append(None)
    with open(os.path.join(out, 'audio.json'), 'w') as fh:
        json.dump(index, fh, indent=1)
    log(f"  {len(index['speech'])} speech clips, {len(index['sfx'])} sound effects, "
        f"{sum(len(v) for v in index['music'].values())} songs ({rendered} rendered"
        f"{'' if sf else '; no SoundFont found — set SC_SOUNDFONT or put soundfonts/default.sf2'})")


def _collect_xmidi(blob, set_name):
    """Songs in file order. COMBAT/GAMEFLOW: [set][0] = link-track archive, [1..] main tracks."""
    songs = []

    def walk(b, depth):
        if b.startswith(b'FORM') or b.startswith(b'CAT '):
            songs.append(b)
            return
        if depth > 4 or len(b) < 8:
            return
        try:
            entries = pak.read_pak(b)
        except Exception:
            return
        for k, (_, e) in enumerate(entries):
            if set_name != 'midgames' and depth == 1 and k == 0 and not e.startswith(b'FORM'):
                continue   # transition (link) tracks: skipped for now
            walk(e, depth + 1)
    walk(blob, 0)
    return songs


if __name__ == '__main__':
    convert(sys.argv[1], sys.argv[2])
