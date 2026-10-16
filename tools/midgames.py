"""In-engine cutscenes ("midgames"), starting with the Strike Commander intro.

The cutscenes are played by OPTTEST.EXE with a small scene engine (decoded from its overlay code,
see FORMATS.md): a scene ticks every N/60 s; objects are sprites placed at (x, y) relative to a
parent, drawing one frame of a shape set, optionally moving by a velocity each tick, and
animations advance one frame per tick. Palettes are patched from OPTPALS / MIDGAMES / MID1.
The choreography itself is code; it is transcribed here as shot builders that emit a tick
timeline, with the conditions the original loops on (animation finished, layer reached a
height) simulated into tick counts.

Output: gamedata/cinematics/<name>/{scenes.json, *.png, *.wav}
"""
import json, os, struct
import numpy as np
from PIL import Image
import shape, pak, realspace, iff, upscale
from audio import voc_to_pcm, write_wav

TICK_HZ = 60
CONV_BAND = 0


class Assets:
    def __init__(self, extracted, out, factor, log):
        M = os.path.join(extracted, 'BIGTRE', 'DATA', 'MIDGAMES')
        G = os.path.join(extracted, 'BIGTRE', 'DATA', 'GAMEFLOW')
        rd = lambda p: shape.pak_entries(open(p, 'rb').read())
        self.paks = {'MID1': rd(os.path.join(M, 'MID1.PAK')), 'MIDGAMES': rd(os.path.join(M, 'MIDGAMES.PAK')),
                     'OPTSHPS': rd(os.path.join(G, 'OPTSHPS.PAK')), 'OPTPALS': rd(os.path.join(G, 'OPTPALS.PAK'))}
        self.voc = [e for _, e in pak.read_pak(open(os.path.join(M, 'MID1VOC.PAK'), 'rb').read())]
        self.base = np.array(realspace.load_palette(os.path.join(extracted, 'BIGTRE', 'DATA', 'PALETTE', 'PALETTE.IFF')), np.uint8)
        texts = {}
        for top in iff.load(os.path.join(M, 'MIDGAMES.IFF')):
            if top.name.startswith('MG'):
                texts[top.name] = {c.name: [t.data.split(b'\0')[0].decode('latin1') for t in c.find(b'TEXT')]
                                   for c in top.children}
        self.texts = texts
        self.out, self.factor, self.log = out, factor, log
        self._frames, self._saved = {}, {}
        os.makedirs(out, exist_ok=True)

    def frames(self, pk, idx):
        key = (pk, idx)
        if key not in self._frames:
            e = self.paks[pk][idx]
            fr = []
            try:
                fr = [shape.decode_shape(b) for _, b in pak.read_pak(e)]
            except Exception:
                fr = []
            if not any(fr):
                fr = shape.decode_any(e)
            self._frames[key] = fr
        return self._frames[key]

    def palette(self, patches):
        P = self.base.copy()
        for pk, idx in patches:
            e = self.paks[pk][idx]
            s, n = struct.unpack_from('<HH', e)
            n = min(n, (len(e) - 4) // 3, 256 - s)
            P[s:s + n] = np.frombuffer(e[4:4 + n * 3], np.uint8).reshape(-1, 3).astype(int) * 255 // 63
        return P

    def image(self, pk, idx, frame, pal_name, P):
        """PNG of one frame under a palette: {file, x, y, w, h} relative to the hotspot."""
        key = (pk, idx, frame, pal_name)
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
            name = f'{pk.lower()}{idx}_{frame}_{pal_name}.png'
            upscale.upscale_rgba(Image.fromarray(rgba, 'RGBA'), self.factor).save(os.path.join(self.out, name), optimize=True)
            out = {'file': name, 'x': int(x0 - s.ox), 'y': int(y0 - s.oy), 'w': int(x1 - x0), 'h': int(y1 - y0)}
        self._saved[key] = out
        return out

    def voice(self, idx):
        name = f'voice_{idx}.wav'
        r = voc_to_pcm(self.voc[idx])
        if r:
            write_wav(os.path.join(self.out, name), r[0], r[1])
            return name
        return None

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


class Scene:
    """Builds a tick timeline for one scene (tick period in 1/60 s) while tracking object
    positions so the original's 'until' conditions can be turned into tick counts."""

    def __init__(self, a, period, palette, pal_name):
        self.a, self.period = a, period
        self.pal, self.pal_name = palette, pal_name
        self.t = 0
        self.events = []
        self.objs = {}          # id -> {x, y, vel, parent, anim, frames}

    def _img(self, pk, idx, frame):
        return self.a.image(pk, idx, frame, self.pal_name, self.pal)

    def add(self, oid, pk, idx, x, y, frame=0, vel=(0, 0), parent=None, anim=False):
        n = len(self.a.frames(pk, idx))
        frames = [self._img(pk, idx, f) for f in range(n)] if anim else [self._img(pk, idx, frame)]
        self.objs[oid] = {'x': x, 'y': y, 'vel': list(vel), 'parent': parent, 'anim': anim, 'n': n,
                          'start': self.t, 'src': (pk, idx, frame)}
        self.events.append({'t': self.t, 'add': {'id': oid, 'x': x, 'y': y, 'vel': list(vel), 'parent': parent,
                                                  'frames': frames, 'anim': anim}})

    def vel(self, oid, v):
        self.objs[oid]['vel'] = list(v)
        self.events.append({'t': self.t, 'vel': {'id': oid, 'v': list(v)}})

    def remove(self, oid):
        self.objs.pop(oid, None)
        self.events.append({'t': self.t, 'remove': oid})

    def voice(self, idx):
        f = self.a.voice(idx)
        if f:
            self.events.append({'t': self.t, 'voice': f})

    def abs_y(self, oid):
        o = self.objs[oid]
        return o['y'] + (self.abs_y(o['parent']) if o['parent'] else 0)

    def tick(self, n=1):
        for _ in range(n):
            for o in self.objs.values():
                o['x'] += o['vel'][0]
                o['y'] += o['vel'][1]
            self.t += 1

    def anim_left(self, oid):
        o = self.objs[oid]
        return max(0, o['n'] - (self.t - o['start']))

    def data(self):
        return {'type': 'scene', 'tick_hz': TICK_HZ / self.period, 'ticks': self.t, 'events': self.events}


# ---------------------------------------------------------------- the intro (MID1)
def intro(a):
    shots = []
    sky = [('OPTPALS', 0x15), ('MIDGAMES', 0x16), ('OPTPALS', 0x18)]
    pal1 = a.palette(sky)
    # shot 1: sky and clouds; an eagle crosses (cries at frames 20 and 35)
    s = Scene(a, 10, pal1, 'sky')
    s.add('sky', 'OPTSHPS', 0x74, 0, 0)
    s.add('clouds', 'MIDGAMES', 0x14, 0, 0)
    s.tick(20)
    s.add('eagle', 'MID1', 3, 0, 0, anim=True)
    s.voice(7)
    while s.anim_left('eagle'):
        if s.t == 35:
            s.voice(7)
        s.tick()
    s.remove('eagle')
    s.tick(20)
    d = s.data()
    d['fade_in_s'] = 1.0
    shots.append(d)
    # shot 2: credit cards over the same sky (text palette MID1 59)
    palt = a.palette(sky + [('MID1', 0x3b)])
    bg = [a.image('OPTSHPS', 0x74, 0, 'sky', pal1), a.image('MIDGAMES', 0x14, 0, 'sky', pal1)]
    cards = []
    for i, txt in enumerate(a.texts['MG01']['DATA'][:4]):
        lines = txt.strip('\n').split('\n')
        img = a.text_card(lines, 35 if i == 1 else 50, palt, f'card_{i}')
        cards.append({'img': img, 'in_s': 16 * 3 / TICK_HZ, 'hold_s': 100 / TICK_HZ, 'out_s': 16 * 3 / TICK_HZ,
                      'after_s': (250 if i == 1 else 100) / TICK_HZ})
    shots.append({'type': 'cards', 'background': bg, 'cards': cards})
    # shot 3: the camera sinks through the clouds (parallax), then a jet streaks past
    pal3 = a.palette(sky + [('MID1', 0x3b), ('MID1', 0x30)])
    s = Scene(a, 10, pal3, 'dive')
    s.add('sky', 'OPTSHPS', 0x74, 0, 0, vel=(0, -1))
    s.add('clouds', 'MIDGAMES', 0x14, 0, 0, vel=(0, -1))
    s.add('far', 'MIDGAMES', 0x13, 0, 150, frame=0, vel=(0, -1))
    s.add('band', 'OPTSHPS', 0x2c, 0, 17, frame=0, vel=(0, -1))
    s.add('mid', 'MIDGAMES', 0x13, 0, 200, frame=1, vel=(0, -1), parent='band')
    s.add('near', 'MIDGAMES', 0x13, 0, 43, frame=2, vel=(0, -1), parent='mid')
    while s.abs_y('near') > 60:
        s.tick()
    for oid in list(s.objs):
        s.vel(oid, (0, 0))
    s.tick()
    s.add('flyby', 'MID1', 13, 0, -70, anim=True)
    start = s.t
    s.voice(8)  # loaded now, played at frame 65 of the fly-by
    s.events[-1]['t'] = start + 65
    while s.anim_left('flyby'):
        s.tick()
    shots.append(s.data())
    return {'name': 'intro', 'music': {'set': 'midgames', 'track': 0}, 'shots': shots}


def convert(extracted, out_root, factor=4, log=print):
    if not os.path.exists(os.path.join(extracted, 'BIGTRE', 'DATA', 'MIDGAMES', 'MID1.PAK')):
        return {}
    out = os.path.join(out_root, 'mid1')
    a = Assets(extracted, out, factor, log)
    data = intro(a)
    with open(os.path.join(out, 'scenes.json'), 'w') as f:
        json.dump(data, f, separators=(',', ':'))
    log(f'  intro cutscene: {len(data["shots"])} shots')
    return {'mid1': 'cinematics/mid1/scenes.json'}


if __name__ == '__main__':
    import sys
    convert(sys.argv[1], sys.argv[2], int(sys.argv[3]) if len(sys.argv) > 3 else 4)
