"""In-engine cutscenes ("midgames"), starting with the Strike Commander intro.

The cutscenes are played by OPTTEST.EXE with a small scene engine (decoded from its overlay code,
see FORMATS.md): a scene ticks every N/60 s; on each tick it draws its objects (sprites placed
relative to a parent, children after their parent) into the letterbox band (rows 24-151), then
updates them (animations step one frame, pans move by their velocity, ...). The choreography
itself is code; it is transcribed here shot by shot, and this module runs the same scene engine
to turn it into keyframes: for each tick on which the picture changes, the list of layers drawn
(image, position, clip). A few tables the choreography reads (HUD paths, blink patterns) come
from OPTTEST.EXE on the disc.

Output: gamedata/cinematics/<name>/{scenes.json, *.png, *.wav}
"""
import hashlib, json, os, struct
import numpy as np
from PIL import Image
import shape, pak, realspace, iff, upscale
from audio import voc_to_pcm, write_wav

TICK_HZ = 60
DS = 0x4c250                              # OPTTEST.EXE data segment (offset in its load image)
VIEW = [0, 24, 319, 151]                  # the scenes' viewport: the letterbox band
HUD_CLIP = (0x83, 9, 0xbe, 0x43)
MOUTHS = '06891599098769362999252999'     # lip-sync: letter a-z -> mouth frame - 2


class Assets:
    def __init__(self, extracted, out, factor, log):
        M = os.path.join(extracted, 'BIGTRE', 'DATA', 'MIDGAMES')
        G = os.path.join(extracted, 'BIGTRE', 'DATA', 'GAMEFLOW')
        rd = lambda p: shape.pak_entries(open(p, 'rb').read())
        self.paks = {'MID1': rd(os.path.join(M, 'MID1.PAK')), 'MIDGAMES': rd(os.path.join(M, 'MIDGAMES.PAK')),
                     'OPTSHPS': rd(os.path.join(G, 'OPTSHPS.PAK')), 'OPTPALS': rd(os.path.join(G, 'OPTPALS.PAK')),
                     'CONV': rd(os.path.join(G, 'CONVSHPS.PAK')), 'CONVPALS': rd(os.path.join(G, 'CONVPALS.PAK'))}
        self.voc = [e for _, e in pak.read_pak(open(os.path.join(M, 'MID1VOC.PAK'), 'rb').read())]
        self.base = np.array(realspace.load_palette(os.path.join(extracted, 'BIGTRE', 'DATA', 'PALETTE', 'PALETTE.IFF')), np.uint8)
        texts = {}
        for top in iff.load(os.path.join(M, 'MIDGAMES.IFF')):
            if top.name.startswith('MG'):
                texts[top.name] = {c.name: [t.data.split(b'\0')[0].decode('latin1') for t in c.find(b'TEXT')]
                                   for c in top.children}
        self.texts = texts
        conv = {c.name: c for c in iff.load(os.path.join(G, 'CONVDATA.IFF'))}
        nm = lambda d: d[:8].split(b'\0')[0].decode('latin1')
        self.faces = {nm(c.data): c.data[8] for c in conv['FACE'].children}
        self.face_pals = {nm(c.data): c.data[8] for c in conv['FCPL'].children}
        exe = open(os.path.join(extracted, 'cd', 'OPTTEST.EXE'), 'rb').read()
        self.exe_image = exe[struct.unpack_from('<H', exe, 8)[0] * 16:]
        self.out, self.factor, self.log = out, factor, log
        self._frames, self._saved, self.images, self._voice = {}, {}, [], {}
        os.makedirs(out, exist_ok=True)

    def ds(self, fmt, off):
        """Values from OPTTEST.EXE's data segment."""
        return struct.unpack_from('<' + fmt, self.exe_image, DS + off)

    def frames(self, pk, idx):
        key = (pk, idx)
        if key not in self._frames:
            e = self.paks[pk][idx]
            fr = []
            try:
                fr = [shape.decode_shape(b) for _, b in pak.read_pak(shape.unwrap(e) if pk == 'CONV' else e)]
            except Exception:
                fr = []
            if not any(f is not None for f in fr):
                fr = shape.decode_any(e)
            self._frames[key] = fr
        return self._frames[key]

    def count(self, pk, idx):
        return len(self.frames(pk, idx))

    def patch(self, P, pk, idx):
        e = self.paks[pk][idx]
        s, n = struct.unpack_from('<HH', e)
        n = min(n, (len(e) - 4) // 3, 256 - s)
        P = P.copy()
        P[s:s + n] = np.frombuffer(e[4:4 + n * 3], np.uint8).reshape(-1, 3).astype(int) * 255 // 63
        return P

    def palette(self, patches):
        P = self.base.copy()
        for pk, idx in patches:
            P = self.patch(P, pk, idx)
        return P

    def image(self, pk, idx, frame, P):
        """Index in self.images ({file, x, y, w, h}, x/y relative to the hotspot) of one frame
        under a palette, or None when the frame is empty."""
        pal_key = hashlib.sha1(P.tobytes()).hexdigest()[:8]
        key = (pk, idx, frame, pal_key)
        if key in self._saved:
            return self._saved[key]
        fr = self.frames(pk, idx)
        s = fr[frame] if 0 <= frame < len(fr) else None
        out = None
        if s is not None and (s.pixels != shape.TRANSPARENT).any():
            m = s.pixels != shape.TRANSPARENT
            ys, xs = np.nonzero(m)
            y0, y1, x0, x1 = ys.min(), ys.max() + 1, xs.min(), xs.max() + 1
            px = s.pixels[y0:y1, x0:x1]
            rgba = np.zeros(px.shape + (4,), np.uint8)
            rgba[..., :3] = P[px]
            rgba[..., 3] = np.where(px == shape.TRANSPARENT, 0, 255)
            name = f'{pk.lower()}{idx}_{frame}_{pal_key}.png'
            upscale.upscale_rgba(Image.fromarray(rgba, 'RGBA'), self.factor).save(os.path.join(self.out, name), optimize=True)
            self.images.append({'file': name, 'x': int(x0 - s.ox), 'y': int(y0 - s.oy), 'w': int(x1 - x0), 'h': int(y1 - y0)})
            out = len(self.images) - 1
        self._saved[key] = out
        return out

    def voice(self, idx):
        """(file, seconds) of a MID1VOC clip."""
        if idx not in self._voice:
            name, dur = None, 0.0
            r = voc_to_pcm(self.voc[idx])
            if r:
                rate, pcm = (r[0], r[1]) if isinstance(r[0], int) else (r[1], r[0])
                name = f'voice_{idx}.wav'
                write_wav(os.path.join(self.out, name), r[0], r[1])
                dur = len(pcm) / rate
            self._voice[idx] = (name, dur)
        return self._voice[idx]

    def text_card(self, lines, y, P, name):
        """Render text with the cutscene font (MID1 27: 128 glyphs) centred, like '%J'."""
        glyphs = self.frames('MID1', 27)
        canvas = np.full((200, 320), shape.TRANSPARENT, np.uint8)
        line_h = max((g.h for g in glyphs if g is not None), default=10) + 2
        for li, line in enumerate(lines):
            def adv(c):
                g = glyphs[ord(c)] if ord(c) < len(glyphs) else None
                if c == ' ' or g is None or not (g.pixels != shape.TRANSPARENT).any():
                    return 7
                return int(np.nonzero((g.pixels != shape.TRANSPARENT).any(0))[0].max()) + 2
            ws = [adv(c) for c in line]
            x = (320 - sum(ws)) // 2
            for c, w in zip(line, ws):
                g = glyphs[ord(c)] if ord(c) < len(glyphs) else None
                if g is not None:
                    m = g.pixels != shape.TRANSPARENT
                    yy, xx = np.nonzero(m)
                    ty, tx = y + li * line_h + yy, x + xx
                    ok = (ty >= 0) & (ty < 200) & (tx >= 0) & (tx < 320)
                    canvas[ty[ok], tx[ok]] = g.pixels[yy[ok], xx[ok]]
                x += w
        m = canvas != shape.TRANSPARENT
        if not m.any():
            return None
        ys, xs = np.nonzero(m)
        y0, y1, x0, x1 = ys.min(), ys.max() + 1, xs.min(), xs.max() + 1
        px = canvas[y0:y1, x0:x1]
        rgba = np.zeros(px.shape + (4,), np.uint8)
        rgba[..., :3] = P[px]
        rgba[..., 3] = np.where(px == shape.TRANSPARENT, 0, 255)
        upscale.upscale_rgba(Image.fromarray(rgba, 'RGBA'), self.factor).save(os.path.join(self.out, name + '.png'), optimize=True)
        return {'file': name + '.png', 'x': int(x0), 'y': int(y0), 'w': int(x1 - x0), 'h': int(y1 - y0)}


# ---------------------------------------------------------------- the scene engine
class Obj:
    """A scene object; `kind` is the behaviour of the original's object classes:
    static     one frame
    anim       frame + 1 each tick, done after the last
    trail      an anim over nothing else: the original doesn't clear its drawing surface, so
               the frames (deltas after the first) build up
    loop       frame + 1 each tick, wrapping
    pan        moves by (vx, vy) each tick
    jitter     random walk of up to a pixel each tick (the cockpit shaking)
    overlay    frame 0 with the current frame over it (heads)
    grow       overlay whose frame climbs to the last and stays
    clamp      frame climbs to the last and stays
    clip       one frame at its own position, clipped to a rectangle (HUD symbols)
    face       a conversation face: frame 0, eyes, a mouth from lip-sync text, helmet (35, 38)
    visor      the helmet-visor sequence of MIDGAMES 0 (frame 0 / 13 under the moving frames)"""

    def __init__(self, a, kind, pk, idx, x=0, y=0, frame=0, **kw):
        self.kind, self.pk, self.idx = kind, pk, idx
        self.x, self.y, self.frame = x, y, frame
        self.n = a.count(pk, idx)
        self.vx = self.vy = 0
        self.children, self.parent = [], None
        self.clip = None
        self.eyes = self.base_eyes = self.mouth = -1
        self.lip = ''
        self.__dict__.update(kw)

    def done(self):
        return self.frame >= self.n


class Rand:
    """Borland C's rand()."""
    def __init__(self, seed=1):
        self.s = seed

    def __call__(self):
        self.s = (self.s * 0x015A4E35 + 1) & 0xFFFFFFFF
        return (self.s >> 16) & 0x7FFF


class Scene:
    """One scene: objects, a tick period in 1/60 s and the palette, simulated tick by tick into
    keyframes of drawn layers [image, x, y(, clip x0, y0, x1, y1)]."""

    def __init__(self, a, P, period, rand):
        self.a, self.P, self.period, self.rand = a, P, period, rand
        self.roots = []
        self.t = 0              # the scene's frame counter (the choreography resets it at times)
        self.T = 0              # ticks since the scene began
        self.frames, self.voices, self.music = [], [], []
        self.last = None
        self._voice_start, self._voice_dur = 0, 0.0

    def add(self, o, parent=None):
        o.parent = parent
        (parent.children if parent else self.roots).append(o)
        return o

    def remove(self, o):
        lst = o.parent.children if o.parent else self.roots
        if o in lst:
            lst.remove(o)

    def obj(self, kind, pk, idx, x=0, y=0, frame=0, parent=None, **kw):
        return self.add(Obj(self.a, kind, pk, idx, x, y, frame, **kw), parent)

    def voice(self, idx):
        f, dur = self.a.voice(idx)
        if f:
            self.voices.append([self.T, f])
        self._voice_start, self._voice_dur = self.T, dur

    def playing(self):
        """The original polls the sound driver once per tick."""
        return (self.T - self._voice_start) * self.period / TICK_HZ < self._voice_dur

    def _draw(self, o, px, py, out):
        x, y = (o.x, o.y) if o.kind == 'clip' else (px + o.x, py + o.y)
        k, f = o.kind, o.frame
        if k in ('overlay', 'grow'):
            frames = [0, f]
        elif k == 'face':
            frames = [0] + [i for i in (o.eyes, o.mouth) if i >= 0]
        elif k == 'trail':
            frames = list(range(min(f + 1, o.n)))
        elif k == 'visor':
            frames = ([0] if f < 4 else []) + ([13] if f > 8 else []) + [1 if f == 12 else f]
        else:
            frames = [f] if f < o.n else []
        for fr in frames:
            i = self.a.image(o.pk, o.idx, fr, self.P)
            if i is not None:
                out.append([i, x, y] + (list(o.clip) if o.clip else []))
        for c in o.children:
            self._draw(c, x, y, out)
        if k == 'face':                     # the pilot's helmet goes over the face
            for fr in (35, 38):
                i = self.a.image(o.pk, o.idx, fr, self.P)
                if i is not None:
                    out.append([i, x, y])

    def _update(self, o):
        k = o.kind
        if k in ('anim', 'trail'):
            o.frame += 1
        elif k == 'loop' and o.n:
            o.frame = (o.frame + 1) % o.n
        elif k == 'pan':
            o.x += o.vx
            o.y += o.vy
        elif k == 'jitter':
            r = self.rand
            if r() & 1:
                o.y += (r() & 1) if r() & 1 else -(r() & 1)
            if r() & 1:
                o.x += (r() & 1) if r() & 1 else -(r() & 1)
        elif k in ('grow', 'clamp'):
            if o.frame < o.n - 1:
                o.frame += 1
        elif k == 'visor':
            o.frame = min(o.frame + 1, 13)
        elif k == 'face':
            self._face(o)
        for c in list(o.children):
            self._update(c)

    def _face(self, o):
        """Blinks, and one character of the lip-sync text per tick."""
        o.mouth = -1
        blink = (self.rand() * 30) // 0x8000 == 0
        o.eyes = 0xc if blink and o.base_eyes <= 0x14 else o.base_eyes
        if not o.lip:
            return
        c, rest = o.lip[0], o.lip[1:]
        nxt = rest[:1]
        if c == 'h':
            rest = rest[1:]
        elif c == 'e':
            if not ('a' <= nxt <= 'z'):               # a silent e: the next character counts
                c, rest = nxt, rest[1:]
            elif nxt == 'r':
                o.mouth, rest = 6, rest[1:]
        elif c in 'tc' and nxt == 'h':
            o.mouth, rest = (9 if c == 't' else 6), rest[1:]
        if o.mouth == -1 and len(c) == 1 and 'a' <= c <= 'z':
            o.mouth = int(MOUTHS[ord(c) - 97]) + 2
        o.lip = rest

    def tick(self, n=1):
        for _ in range(n):
            layers = []
            for o in self.roots:
                self._draw(o, 0, 0, layers)
            if layers != self.last:
                self.frames.append([self.T, layers])
                self.last = layers
            for o in list(self.roots):
                self._update(o)
            self.t += 1
            self.T += 1

    def data(self, **extra):
        d = {'type': 'scene', 'tick_hz': TICK_HZ / self.period, 'ticks': self.T, 'view': VIEW,
             'frames': self.frames, 'voices': self.voices}
        if self.music:
            d['music'] = self.music
        d.update(extra)
        return d


class Pal:
    """The palette in use: patches accumulate over the whole cutscene, as in the original."""
    def __init__(self, a, patches):
        self.a, self.P = a, a.palette(patches)

    def add(self, *patches):
        for pk, idx in patches:
            self.P = self.a.patch(self.P, pk, idx)
        return self.P


# ---------------------------------------------------------------- the intro (MID1)
def cockpit(a, P, rand, variant):
    """The view over the nose with the HUD tracking a MiG. The HUD symbols move along tables in
    OPTTEST.EXE; three variants (the last one locks on)."""
    path_off, off_off, ftab_off, glob, loop_idx, voice, clipped = {
        'A': (0x22aa, 0x234e, 0x2352, 0x23a4, 0x14, 9, True),
        'B': (0x23b0, 0x2454, 0x2458, 0x24aa, 0x17, 9, True),
        'C': (0x259e, 0x2642, 0x2646, 0x2698, 0x14, 10, False)}[variant]
    path = a.ds('82h', path_off)
    ox, oy = a.ds('2h', off_off)
    ftab = a.ds('41h', ftab_off)
    gx, gy, gvx, gvy, gdf, gf = a.ds('6h', glob)
    s = Scene(a, P, 20, rand)
    s.obj('static', 'OPTSHPS', 0x74, 0, -24)
    s.obj('loop', 'MID1', loop_idx, 0, -40)
    s.obj('static', 'MID1', 6, 0, -24)
    o172 = s.obj('clip' if clipped else 'static', 'MID1', 11, 0x9f, 0x28, clip=HUD_CLIP if clipped else None)
    o174 = s.obj('static', 'MID1', 12, 0x63, 0x6c)
    o176 = s.obj('static', 'MID1', 12, 0xc3, 0x6b, 3)
    o178 = s.obj('static', 'MID1', 11, 0x87, 0x16, 7)
    o17a = s.obj('static', 'MID1', 11, 0xb9, 0x16, 0x10)
    o17c = s.obj('static', 'MID1', 11, 0xa0, 0x26, 0x15)
    o17e = s.obj('clip', 'MID1', 11, 0xa9, 0x6d, 0x16, clip=HUD_CLIP)
    o180 = s.obj('clip', 'MID1', 11, 0xa9, 0x6d, 0x17, clip=HUD_CLIP)
    for f, x, y in ((0x18, 0x9f, 0x28), (0x1a, 0x8a, 0x11), (0x1b, 0x8c, 0x3f), (0x1c, 0xb2, 0x3f)):
        s.obj('static', 'MID1', 11, x, y, f)
    c1, c2 = 0x10, 7
    s.voice(voice)
    while s.t < 40:
        f = s.t
        if variant == 'B':
            c1 = 20 if c1 - 1 == 15 else c1 - 1
            c2 = 7 if c2 + 1 == 16 else c2 + 1
            o17a.frame, o178.frame = c1, c2
        elif f & 1:
            c1 = 16 if c1 + 1 == 21 else c1 + 1
            c2 = (15 if c2 - 1 == 6 else c2 - 1) if variant == 'A' else (7 if c2 + 1 == 16 else c2 + 1)
            o17a.frame, o178.frame = c1, c2
        tx, ty = path[2 * f] + ox, path[2 * f + 1] + oy
        o17e.x, o17e.y = tx, ty
        if variant == 'C':
            if f < 8:                                     # the pipper wanders...
                if not (0x88 < gx < 0xb9):
                    gvx = -gvx
                if not (0xe < gy < 0x3e):
                    gvy = -gvy
            else:                                         # ...then closes on the target
                gvx, gvy = tx - gx, ty - gy
                if f < 18:
                    gvx, gvy = int(gvx / 2), int(gvy / 2)
                elif f & 1:                               # locked: the symbols flash
                    o180.frame, o17e.frame, o17c.frame = 0x17, 0x16, 0x15
                else:
                    o180.frame = o17e.frame = o17c.frame = 0x19
            gx, gy = gx + gvx, gy + gvy
        else:
            gx, gy = gx + gvx, gy + gvy
            if not (0x88 < gx < 0xb9):
                gvx = -gvx
            if not (0xe < gy < 0x3e):
                gvy = -gvy
        o180.x, o180.y = gx, gy
        o172.frame = ftab[f]
        o174.frame = 1 if ftab[f] > 3 else 2 if ftab[f] != 0 else 0
        gf += gdf
        if not (3 < gf < 5):
            gdf = -gdf
        o176.frame = gf
        s.tick()
    return s


def player_cockpit(s, y=-40):
    """Our pilot in his cockpit (MID1 1 head over MID1 6), the picture shaking slightly."""
    s.obj('static', 'OPTSHPS', 0x74, 0, -24)
    j = s.obj('jitter', 'MID1', 6, 0, y, 2)
    s.obj('static', 'MID1', 26, -5, 0, 2, parent=j)
    s.obj('static', 'MID1', 26, 6, 0, 3, parent=j)
    return s.obj('overlay', 'MID1', 1, 0, 24, 3, parent=j)


def tex_cockpit(s, y=-40, head='overlay'):
    """Tex in his (MID1 0 head)."""
    s.obj('static', 'OPTSHPS', 0x74, 0, 0)
    j = s.obj('jitter', 'MID1', 6, 1, y, 3)
    s.obj('static', 'MID1', 26, -7, 0, 0, parent=j)
    s.obj('static', 'MID1', 26, 7, 0, 1, parent=j)
    return s.obj(head, 'MID1', 0, 0, 14, 1 if head == 'grow' else 0, parent=j)


def talk(s, head, voice, base=0, before=0, after=0):
    """A line of speech: the head alternates between two frames while the clip plays."""
    head.frame = base
    while s.t < before:
        s.tick()
    s.voice(voice)
    start = s.T
    while s.playing():
        s.tick()
        head.frame = base + (s.t & 1)
    head.frame = base
    while s.t < after:
        s.tick()
    return start


def intro(a):
    shots = []
    rand = Rand()
    spok = a.texts['MG01']['SPOK']
    pal = Pal(a, [('OPTPALS', 0x15), ('MIDGAMES', 0x16), ('OPTPALS', 0x18)])
    # 1: sky and clouds; an eagle crosses (cries at frames 20 and 35)
    s = Scene(a, pal.P, 10, rand)
    s.obj('static', 'OPTSHPS', 0x74)
    s.obj('static', 'MIDGAMES', 0x14)
    s.tick(20)
    eagle = s.obj('anim', 'MID1', 3)
    s.voice(7)
    while not eagle.done():
        if s.t == 35:
            s.voice(7)
        s.tick()
    s.remove(eagle)
    s.tick(20)
    shots.append(s.data(fade_in_s=1.0, music=[[0, {'set': 'midgames', 'track': 0}]]))
    # 2: credit cards over the same sky (text palette MID1 59)
    bg = [a.images[i] for i in (a.image('OPTSHPS', 0x74, 0, pal.P), a.image('MIDGAMES', 0x14, 0, pal.P)) if i is not None]
    palt = pal.add(('MID1', 0x3b))
    cards = []
    for i, txt in enumerate(a.texts['MG01']['DATA'][:4]):
        lines = txt.strip('\n').split('\n')
        img = a.text_card(lines, 35 if i == 1 else 50, palt, f'card_{i}')
        cards.append({'img': img, 'in_s': 16 * 3 / TICK_HZ, 'hold_s': 100 / TICK_HZ, 'out_s': 16 * 3 / TICK_HZ,
                      'after_s': (250 if i == 1 else 100) / TICK_HZ})
    shots.append({'type': 'cards', 'view': VIEW, 'background': bg, 'cards': cards})
    # 3: the camera sinks through the clouds (parallax), then a jet streaks past
    s = Scene(a, pal.add(('MID1', 0x30)), 10, rand)
    layers = [s.obj('pan', 'OPTSHPS', 0x74), s.obj('pan', 'MIDGAMES', 0x14), s.obj('pan', 'MIDGAMES', 0x13, 0, 150, 0)]
    band = s.obj('pan', 'OPTSHPS', 0x2c, 0, 17)
    mid = s.obj('pan', 'MIDGAMES', 0x13, 0, 200, 1, parent=band)
    near = s.obj('pan', 'MIDGAMES', 0x13, 0, 43, 2, parent=mid)
    for o in layers + [band, mid, near]:
        o.vy = -1
    while band.y + mid.y + near.y > 60:
        s.tick()
    for o in layers + [band, mid, near]:
        o.vy = 0
    s.tick()
    jet = s.obj('anim', 'MID1', 13, 0, -70)
    start = s.t
    while not jet.done():
        if s.t == start + 65:
            s.voice(8)
        s.tick()
    shots.append(s.data())
    # 4: over the nose, the HUD tracks a MiG
    shots.append(cockpit(a, pal.add(('MID1', 0x36), ('MID1', 0x2a)), rand, 'A').data())
    # 5: our pilot
    s = Scene(a, pal.add(('MID1', 0x2c), ('MID1', 0x26)), 20, rand)
    player_cockpit(s)
    s.tick(20)
    shots.append(s.data())
    # 6: Tex's jet comes alongside
    s = Scene(a, pal.add(('MID1', 0x38), ('OPTPALS', 0x18), ('MIDGAMES', 0x16)), 20, rand)
    s.voice(8)
    sk = s.obj('static', 'OPTSHPS', 0x74)
    s.obj('static', 'MIDGAMES', 0x15, parent=sk)
    s.obj('static', 'OPTSHPS', 0x2c, 0, -40)
    s.obj('static', 'MIDGAMES', 0x13, 0, 0x5a, 1)
    s.obj('static', 'MIDGAMES', 0x13, 0, 0x46, 2)
    o = s.obj('anim', 'MID1', 0x16)
    while not o.done():
        s.tick()
    shots.append(s.data())
    # 7: the HUD again
    shots.append(cockpit(a, pal.add(('MID1', 0x39), ('MID1', 0x2a)), rand, 'B').data())
    # 8: Tex: "Dammit! You take him out or I will!"
    s = Scene(a, pal.add(('MID1', 0x2d), ('MID1', 0x27)), 10, rand)
    t0 = talk(s, tex_cockpit(s), 0, after=5)
    shots.append(s.data(subtitle=[t0, spok[0]]))
    # 9: the MiG pilot: "Back off! I've almost got tone!"
    normal = ('CONVPALS', a.face_pals['normal'])
    s = Scene(a, pal.add(('MID1', 0x2b), normal), 10, rand)
    s.obj('static', 'OPTSHPS', 0x74)
    s.obj('static', 'MID1', 6, 0, 0, 1)
    air = a.faces['air']
    s.obj('face', 'CONV', air, 0xa0, 0x80, base_eyes=0x1f, eyes=0x1f, lip='Back off, almost got tone. Blah blah blah')
    s.obj('static', 'CONV', air, 0xa0, 0x7f, 0x27)
    s.voice(4)
    while s.playing():
        s.tick()
    shots.append(s.data(subtitle=[0, spok[1]]))
    # 10: the HUD locks on
    shots.append(cockpit(a, pal.add(('MID1', 0x36), ('MID1', 0x2a)), rand, 'C').data())
    # 11: the missile's view
    s = Scene(a, pal.add(('MID1', 0x3a)), 15, rand)
    o = s.obj('trail', 'MID1', 0x18)
    while not o.done():
        s.tick()
    shots.append(s.data())
    # 12: the missile chases the MiG
    s = Scene(a, pal.add(('OPTPALS', 0x15), ('MIDGAMES', 0x16), ('MID1', 0x31)), 20, rand)
    s.obj('static', 'OPTSHPS', 0x74)
    o1, o2 = s.obj('anim', 'MID1', 0x10), Obj(a, 'anim', 'MID1', 0x12)
    while s.t < 41:
        if s.t == 20:
            s.remove(o1)
            s.add(o2)
        if s.t == 15:
            s.voice(11)
        s.tick()
    shots.append(s.data())
    # 13: the hit
    s = Scene(a, pal.P, 20, rand)
    s.obj('static', 'OPTSHPS', 0x74)
    o = s.obj('anim', 'MID1', 0xf)
    while not o.done():
        if s.t == 22:
            s.voice(12)
        s.tick()
    shots.append(s.data())
    # 14: panning with the burning MiG
    s = Scene(a, pal.add(('MID1', 0x33)), 20, rand)
    for pk, idx, y, v in (('OPTSHPS', 0x74, -40, 1), ('MIDGAMES', 0x15, -40, 1), ('MID1', 7, 40, 2)):
        for x in (0, -320):
            s.obj('pan', pk, idx, x, y, vx=v)
    seq = [Obj(a, 'anim', 'MID1', i) for i in (0x15, 0x1d, 0x23)]
    s.add(seq[0])
    while s.t < 41:
        if s.t == 14:
            s.remove(seq[0]); s.add(seq[1])
        if s.t == 27:
            s.remove(seq[1]); s.add(seq[2])
        s.tick()
    shots.append(s.data())
    # 15: the MiG pilot ejects
    s = Scene(a, pal.P, 20, rand)
    sk = s.obj('static', 'OPTSHPS', 0x74, 0, -10)
    s.obj('static', 'MIDGAMES', 0x14, parent=sk)
    mig = s.obj('anim', 'MID1', 0x11)
    chute = [Obj(a, 'anim', 'MID1', i) for i in (0x1e, 0x1f, 0x20)]
    s.add(chute[0], mig)
    s.obj('static', 'MIDGAMES', 0x13, 0, 0x55, 1)
    s.obj('static', 'MIDGAMES', 0x13, 0, 0x37, 2)
    while s.t < 81:
        if s.t == 50:
            s.remove(chute[0]); s.add(chute[1], mig)
        if s.t == 65:
            s.remove(chute[1]); s.add(chute[2], mig)
        if s.t == 48:
            s.voice(13)
        s.tick()
    shots.append(s.data())
    # 16: Tex: "Nice kill, hot shot." (his head turns)
    s = Scene(a, pal.add(('MID1', 0x2d), ('MID1', 0x27)), 10, rand)
    tex_cockpit(s, -35, 'grow')
    s.voice(1)
    while s.playing():
        s.tick()
    while s.t < 10:
        s.tick()
    shots.append(s.data(subtitle=[0, spok[2]]))
    # 17: our pilot
    s = Scene(a, pal.add(('MID1', 0x2c), ('MID1', 0x26)), 20, rand)
    player_cockpit(s)
    s.tick(20)
    shots.append(s.data())
    # 18: the MiG pilot under his parachute lifts his visor
    s = Scene(a, pal.add(('MID1', 0x2b), normal), 10, rand)
    s.obj('static', 'OPTSHPS', 0x74)
    s.obj('static', 'MID1', 6, 0, 0, 1)
    s.obj('face', 'CONV', air, 0xa0, 0x80, base_eyes=0x1b, eyes=0x1b)
    s.obj('visor', 'MIDGAMES', 0, 0xa0, 0x80)
    s.tick(20)
    shots.append(s.data())
    # 19: ...and comes down in the jungle
    s = Scene(a, pal.add(('MIDGAMES', 0x16), ('OPTPALS', 0x18), ('MID1', 0x2f)), 10, rand)
    sk = s.obj('static', 'OPTSHPS', 0x74, 0, -64)
    s.obj('static', 'MIDGAMES', 0x14, parent=sk)
    s.obj('static', 'OPTSHPS', 0x2c)
    s.obj('static', 'MIDGAMES', 0x13, 0, 0x5a, 1)
    s.obj('static', 'MIDGAMES', 0x13, 0, 0x32, 2)
    o = s.obj('grow', 'MID1', 10, 0, 10, 1)
    while s.t < 20:
        if s.t > 8:
            o.frame = 9
        s.tick()
    shots.append(s.data())
    # 20: on the ground, he watches the jets
    s = Scene(a, pal.add(('MIDGAMES', 0x17)), 20, rand)
    sk = s.obj('static', 'OPTSHPS', 0x74)
    s.obj('static', 'MIDGAMES', 0x14, parent=sk)
    s.obj('static', 'MIDGAMES', 0x18, 0, -20)
    s.obj('overlay', 'MID1', 2, 0, -25, 1)
    s.obj('anim', 'MID1', 0x13, 0, -40)
    s.tick(30)
    shots.append(s.data())
    # 21: Tex: "Well, are you gonna finish him off?"
    s = Scene(a, pal.add(('MID1', 0x2d), ('MID1', 0x27)), 10, rand)
    t0 = talk(s, tex_cockpit(s), 2, base=13)
    shots.append(s.data(subtitle=[t0, spok[3]]))
    # 22: "Forget it. The airspace is clear."
    s = Scene(a, pal.add(('MID1', 0x2c), ('MID1', 0x26)), 20, rand)
    t0 = talk(s, player_cockpit(s, -35), 5, before=5)
    shots.append(s.data(subtitle=[t0, spok[4]]))
    # 23: Tex: "Yeah, but what about the price on his head?"
    s = Scene(a, pal.add(('MID1', 0x2d), ('MID1', 0x27)), 10, rand)
    t0 = talk(s, tex_cockpit(s), 3, base=13, after=5)
    shots.append(s.data(subtitle=[t0, spok[5]]))
    # 24: "I'm a fighter pilot, not a murderer, Tex. Returning to base."
    s = Scene(a, pal.add(('MID1', 0x2c), ('MID1', 0x26)), 20, rand)
    t0 = talk(s, player_cockpit(s, -36), 6, before=5)
    shots.append(s.data(subtitle=[t0, spok[6]]))
    # 25: the jets leave the MiG pilot behind; the title
    s = Scene(a, pal.add(('MIDGAMES', 0x16), ('OPTPALS', 0x18), ('MIDGAMES', 0x17)), 20, rand)
    sk = s.obj('pan', 'OPTSHPS', 0x74)
    s.obj('static', 'MIDGAMES', 0x14, parent=sk)
    hills = s.obj('pan', 'OPTSHPS', 0x2c, parent=sk)
    far = s.obj('pan', 'MIDGAMES', 0x13, 0, 0x82, 1, parent=hills)
    near = s.obj('pan', 'MIDGAMES', 0x13, 0, -4, 2, parent=far)
    s.obj('clamp', 'MID1', 0x19, 0, -0x4f, parent=near)
    jets = [Obj(a, 'anim', 'MID1', 0x21, 0, 10), Obj(a, 'anim', 'MID1', 0x22, 0, 10)]
    s.add(jets[0], sk)
    s.tick(20)
    s.t = 0
    far.vy = 1
    for _ in range(26):
        if s.t == 10:
            s.remove(jets[0]); s.add(jets[1], sk)
        s.tick()
    far.vy = 0
    while not jets[1].done():
        s.tick()
    s.remove(jets[1])
    s.tick()
    s.t = 0
    logo = [Obj(a, 'anim', 'MID1', 9), Obj(a, 'anim', 'MID1', 0xe)]
    s.add(logo[0], sk)
    s.P = pal.add(('MID1', 0x2e))
    s.voice(13)
    while s.t < 31:
        if s.t == 20:
            s.remove(logo[0]); s.add(logo[1], sk)
        s.tick()
    final = s.last
    shots.append(s.data())
    # the title music starts; 2 s later the picture opens out from the band to the full screen
    s = Scene(a, pal.P, 1, rand)
    s.music.append([0, {'set': 'midgames', 'track': 0x17}])
    s.frames.append([0, final])
    s.T = 120
    bg = [i for i in (a.image(pk, idx, 0, pal.P) for pk, idx in (('OPTSHPS', 0x74), ('MIDGAMES', 0x14), ('OPTSHPS', 0x2c)))
          if i is not None]
    for i in range(25):
        top, bottom = 23 - i, 153 + 2 * i
        s.frames.append([s.T, final + [[b, 0, 0, 0, top, 319, 23] for b in bg] + [[b, 0, 0, 0, 152, 319, bottom] for b in bg]])
        s.T += 1
    s.T += 30
    shots.append(s.data(keep_music=True))
    return {'name': 'intro', 'images': a.images, 'shots': shots}


def convert(extracted, out_root, factor=4, log=print):
    if not os.path.exists(os.path.join(extracted, 'BIGTRE', 'DATA', 'MIDGAMES', 'MID1.PAK')):
        return {}
    out = os.path.join(out_root, 'mid1')
    a = Assets(extracted, out, factor, log)
    data = intro(a)
    with open(os.path.join(out, 'scenes.json'), 'w') as f:
        json.dump(data, f, separators=(',', ':'))
    secs = sum(s['ticks'] / s['tick_hz'] for s in data['shots'] if s['type'] == 'scene')
    log(f'  intro cutscene: {len(data["shots"])} shots, {len(a.images)} images, {secs:.0f} s of scenes')
    return {'mid1': 'cinematics/mid1/scenes.json'}


if __name__ == '__main__':
    import sys
    convert(sys.argv[1], sys.argv[2], int(sys.argv[3]) if len(sys.argv) > 3 else 4)
