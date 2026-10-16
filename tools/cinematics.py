"""The CD intro movie: FLIC/THEFLIC.FLX (frames) and FLIC/FLIC.PAK (music and sound clips).

THEFLIC.FLX is an Origin "Flex" container: 0x50 bytes of title padding, u32 0x1A1A0000-ish
marker, u32 entry count at 0x54, then (u32 offset, u32 size) pairs from 0x80. Entries in order:
  size 1         scene marker (screen cleared)
  size 772       palette: u16 first, u16 count, 6-bit RGB
  frames         16-byte header: u8 1, u8 compression (0 raw, 1 LZW), u8 codec, u8 margin
                 (picture rows margin..200-margin), 12 zero bytes; then the data.
Codecs (from MENU.EXE, "PLAYFLIC 1.0b"):
  1  full picture, 320 x (200 - 2*margin) bytes
  2  4x4 blocks, 80 per row: first byte is an escape value that toggles coded/raw mode;
     coded: c0 c1 (c0 == c1: solid) else c0 c1 + 16-bit mask (MSB first, rows 0-1 in the first
     byte, 2-3 in the second; bit set = c1); raw: 16 bytes
  0  transparent overlay: u16 flags (bit 0 = run-length), u16 w, h, i16 x0, y0, u16 row offsets
     (relative to each entry), rows of (skip, count[, pixels]) runs; RLE counts are count>>1
     with bit 0 = fill with the next byte
Playback: 11.6 frames/s against the General MIDI score (FLIC.PAK entry 17; 15/16
are the other sound cards' versions, 18-20 a shorter looping score for slow machines). Sound
clips (FLIC.PAK 0-14, Creative Voice) play on one channel at fixed frames, a new one cutting the
previous; the last frame is held for a moment.

Output: gamedata/cinematics/intro/{intro.json, f0000.webp..., music.ogg, clip_N.wav}.
"""
import json, os, struct
import numpy as np
from PIL import Image
import lzw, pak, upscale
from audio import voc_to_pcm, write_wav, xmidi_events, parse_evnt, write_smf, render, find_soundfont

# frame -> sound clip (FLIC.PAK entry), from MENU.EXE's cue table
CUES = [(1, 0), (128, 10), (151, 1), (165, 2), (215, 3), (230, 12), (265, 11), (305, 4), (360, 5),
        (385, 11), (415, 11), (550, 6), (680, 7), (705, 8), (760, 9), (830, 13)]
MUSIC_ENTRY = 17
FPS = 11.6          # the movie runs ahead of the score; the last frame is held until it ends
HOLD_S = 2.5


def flex_entries(data):
    count = struct.unpack_from('<I', data, 0x54)[0]
    for i in range(count):
        off, size = struct.unpack_from('<II', data, 0x80 + i * 8)
        yield data[off:off + size]


def _blocks(screen, src, top):
    esc, p, coded = src[0], 1, True
    rows = (200 - 2 * top) // 4
    for by in range(rows):
        y = top + by * 4
        for bx in range(80):
            if src[p] == esc:
                coded = not coded
                p += 1
            x = bx * 4
            if coded:
                c0, c1 = src[p], src[p + 1]
                if c0 == c1:
                    screen[y:y + 4, x:x + 4] = c0
                    p += 2
                else:
                    m = (src[p + 2] << 8) | src[p + 3]          # bit 15 = top-left
                    bits = (m >> np.arange(15, -1, -1)) & 1
                    screen[y:y + 4, x:x + 4] = np.where(bits.reshape(4, 4), c1, c0)
                    p += 4
            else:
                screen[y:y + 4, x:x + 4] = np.frombuffer(src[p:p + 16], np.uint8).reshape(4, 4)
                p += 16


def _overlay(screen, src):
    flags, w, h, ox, oy = struct.unpack_from('<HHHhh', src)
    for row in range(h):
        tp = 10 + row * 2
        q = tp + struct.unpack_from('<H', src, tp)[0]
        y, x, left = row - oy, -ox, w
        while left > 0:
            skip = src[q]; q += 1
            left -= skip
            if left <= 0:
                break
            x += skip
            c = src[q]; q += 1
            if flags & 1:
                n = c >> 1
                if c & 1:
                    px = np.full(n, src[q], np.uint8); q += 1
                else:
                    px = np.frombuffer(src[q:q + n], np.uint8); q += n
            else:
                n = c
                px = np.frombuffer(src[q:q + n], np.uint8); q += n
            if 0 <= y < 200 and x < 320:
                k = min(n, 320 - x)
                screen[y, x:x + k] = px[:k]
            x += n
            left -= n


def decode(flx):
    """Yield RGB frames (200x320x3 uint8) of the movie."""
    screen = np.zeros((200, 320), np.uint8)
    pal = np.zeros((256, 3), np.uint8)
    for e in flex_entries(flx):
        if len(e) == 1:
            screen[:] = 0
            continue
        if len(e) == 772 and e[0] == 0 and e[1] == 0:
            first, n = struct.unpack_from('<HH', e)
            pal[first:first + n] = np.frombuffer(e[4:4 + n * 3], np.uint8).reshape(-1, 3).astype(int) * 255 // 63
            continue
        if len(e) < 16:
            continue
        comp, codec, top = e[1], e[2], e[3]
        data = lzw.decode(e[16:]) if comp == 1 else e[16:]
        if codec == 1:
            h = 200 - 2 * top
            screen[top:top + h] = np.frombuffer(data[:320 * h], np.uint8).reshape(h, 320)
        elif codec == 2:
            _blocks(screen, data, top)
        elif codec == 0:
            _overlay(screen, data)
        yield pal[screen]


def convert(extracted, out_root, log=print):
    base = os.path.join(extracted, 'BIGTRE', 'DATA', 'FLIC')
    flx_path = os.path.join(base, 'THEFLIC.FLX')
    if not os.path.exists(flx_path):
        log('  no intro movie on this disc')
        return {}
    out = os.path.join(out_root, 'intro')
    os.makedirs(out, exist_ok=True)
    frames = 0
    for rgb in decode(open(flx_path, 'rb').read()):
        upscale.save(Image.fromarray(rgb), os.path.join(out, f'f{frames:04d}.webp'), quality=88, method=4)
        frames += 1
    # sound: clips and the General MIDI score
    entries = [e for _, e in pak.read_pak(open(os.path.join(base, 'FLIC.PAK'), 'rb').read())]
    clips = set()
    for _, c in CUES:
        r = voc_to_pcm(entries[c])
        if r:
            write_wav(os.path.join(out, f'clip_{c}.wav'), r[0], r[1])
            clips.add(c)
    music = None
    sf = find_soundfont()
    evs = xmidi_events(entries[MUSIC_ENTRY])
    if evs:
        events, marks = parse_evnt(evs[0])
        end = max([x[0] for x in events] + [marks['end']])
        mid = os.path.join(out, 'music.mid')
        write_smf(events, mid, end)
        if sf and render(mid, os.path.join(out, 'music.ogg'), sf, end / 120.0):
            music = {'file': 'music.ogg', 'length_s': round(end / 120.0, 3)}
    info = {'frames': frames, 'fps': FPS, 'hold_s': HOLD_S,
            'cues': [{'frame': f, 'clip': f'clip_{c}.wav'} for f, c in CUES if c in clips], 'music': music}
    with open(os.path.join(out, 'intro.json'), 'w') as f:
        json.dump(info, f, indent=1)
    log(f'  intro: {frames} frames at {info["fps"]} fps, {len(info["cues"])} sound cues, music {"yes" if music else "no (no SoundFont)"}')
    return {'intro': 'cinematics/intro/intro.json'}
