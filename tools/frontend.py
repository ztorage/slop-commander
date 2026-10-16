"""The front end: the CD's game chooser (MENU.EXE, TOMENU.PAK), the main menu (OPTTEST.EXE,
MAINMENU.PAK), the pilot's licence where a new game's names are entered, the mouse cursors
(MOUSE.SHP) and the fonts they use.

Layouts are from the code (see FORMATS.md, "Front end"):
  chooser    OPTSHPS 0x2c hills over black, TOMENU 0 panel at (45, 24), buttons TOMENU 1 frames
             0/1 (up) and 2/3 (pressed) at panel + (44, 9) and (45, 47), 166 x 26; palette
             OPTPALS 0x15 + 0x18 + MID1 0x3b + TOMENU 2.
  main menu  OPTSHPS 0x74 sky, MIDGAMES 0x14 clouds, OPTSHPS 0x2c hills; MAINMENU 1 panel at
             (45, 24) whose engraved labels are the disabled look; a button draws MAINMENU 0
             frame i (up) or 5 + i (pressed) at panel + (11, 10 + 17 i), 210 x 14; palette
             OPTPALS 0x15 + 0x18 + MID1 0x3b + MAINMENU 2.
  licence    OPTSHPS 0xa0 under OPTPALS 0x1e; FORMFONT text fields (last name, first name,
             callsign) at (91, 97), (174, 97), (124, 103), at most 15 letters and 57/50/98 px.

Output: gamedata/frontend/{frontend.json, *.png}
"""
import json, os, struct
import numpy as np
from PIL import Image
import shape, pak, realspace, upscale


class Art:
    def __init__(self, extracted, out, factor):
        D = os.path.join(extracted, 'BIGTRE', 'DATA')
        rd = lambda *p: shape.pak_entries(open(os.path.join(D, *p), 'rb').read())
        self.paks = {'OPTSHPS': rd('GAMEFLOW', 'OPTSHPS.PAK'), 'OPTPALS': rd('GAMEFLOW', 'OPTPALS.PAK'),
                     'MAINMENU': rd('GAMEFLOW', 'MAINMENU.PAK'), 'TOMENU': rd('GAMEFLOW', 'TOMENU.PAK'),
                     'MID1': rd('MIDGAMES', 'MID1.PAK'), 'MIDGAMES': rd('MIDGAMES', 'MIDGAMES.PAK')}
        self.files = {'MOUSE': open(os.path.join(D, 'MOUSE.SHP'), 'rb').read(),
                      'FORMFONT': open(os.path.join(D, 'FONTS', 'FORMFONT.SHP'), 'rb').read()}
        self.base = np.array(realspace.load_palette(os.path.join(D, 'PALETTE', 'PALETTE.IFF')), np.uint8)
        self.out, self.factor = out, factor
        self._frames = {}
        os.makedirs(out, exist_ok=True)

    def frames(self, pk, idx=None):
        key = (pk, idx)
        if key not in self._frames:
            blob = self.paks[pk][idx] if idx is not None else self.files[pk]
            fr = []
            try:
                fr = [shape.decode_shape(b) for _, b in pak.read_pak(blob)]
            except Exception:
                fr = []
            if not any(f is not None for f in fr):
                fr = shape.decode_any(blob)
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

    def save(self, px, P, name, x=0, y=0):
        """Save palette indices (TRANSPARENT = clear) as an upscaled PNG cropped to its pixels;
        {file, x, y, w, h} with (x, y) the top-left in original pixels."""
        m = px != shape.TRANSPARENT
        if not m.any():
            return None
        ys, xs = np.nonzero(m)
        y0, y1, x0, x1 = ys.min(), ys.max() + 1, xs.min(), xs.max() + 1
        px = px[y0:y1, x0:x1]
        rgba = np.zeros(px.shape + (4,), np.uint8)
        rgba[..., :3] = P[px]
        rgba[..., 3] = np.where(px == shape.TRANSPARENT, 0, 255)
        upscale.upscale_rgba(Image.fromarray(rgba, 'RGBA'), self.factor).save(os.path.join(self.out, name + '.png'), optimize=True)
        return {'file': name + '.png', 'x': int(x + x0), 'y': int(y + y0), 'w': int(x1 - x0), 'h': int(y1 - y0)}

    def shape(self, s, P, name, x=0, y=0):
        """A shape drawn with its hotspot at (x, y)."""
        if s is None:
            return None
        return self.save(s.pixels, P, name, x - s.ox, y - s.oy)

    def screen(self, layers, P, name, opaque=True):
        """Composite full-screen layers [(shape, x, y)] into one picture (one image to upscale)."""
        px = np.full((200, 320), 0 if opaque else shape.TRANSPARENT, np.uint8)
        for s, x, y in layers:
            m = s.pixels != shape.TRANSPARENT
            ys, xs = np.nonzero(m)
            ty, tx = ys + y - s.oy, xs + x - s.ox
            ok = (ty >= 0) & (ty < 200) & (tx >= 0) & (tx < 320)
            px[ty[ok], tx[ok]] = s.pixels[ys[ok], xs[ok]]
        return self.save(px, P, name)


def font(art, key, P, name):
    """A font's glyphs (index = character code) and advances."""
    glyphs = {}
    for c, s in enumerate(art.frames(key)):
        if s is None or not (s.pixels != shape.TRANSPARENT).any():
            continue
        e = art.shape(s, P, f'{name}_{c}')
        e['advance'] = int(s.w) + 1
        glyphs[str(c)] = e
    return {'glyphs': glyphs, 'space': 3, 'height': max((g['h'] for g in glyphs.values()), default=6)}


def cursors(art, P, name):
    fr = art.frames('MOUSE')
    names = ['cross', 'arrow', 'cross_hot', 'arrow_hot']
    return {n: art.shape(s, P, f'{name}_cursor_{n}') for n, s in zip(names, fr)}


def convert(extracted, out_root, factor=4, log=print):
    if not os.path.exists(os.path.join(extracted, 'BIGTRE', 'DATA', 'GAMEFLOW', 'MAINMENU.PAK')):
        return {}
    out = os.path.join(out_root, 'frontend')
    a = Art(extracted, out, factor)
    sky, clouds, hills = a.frames('OPTSHPS', 0x74)[0], a.frames('MIDGAMES', 0x14)[0], a.frames('OPTSHPS', 0x2c)[0]
    screens = {}
    # the CD's game chooser
    P = a.palette([('OPTPALS', 0x15), ('OPTPALS', 0x18), ('MID1', 0x3b), ('TOMENU', 2)])
    px, py = 45, 24
    b = a.frames('TOMENU', 1)
    screens['chooser'] = {
        'background': [a.screen([(hills, 0, 0)], P, 'chooser_bg'), a.shape(a.frames('TOMENU', 0)[0], P, 'chooser_panel', px, py)],
        'buttons': [{'action': act, 'rect': [px + bx, py + by, 166, 26],
                     'up': a.shape(b[i], P, f'chooser_{i}', px + bx, py + by),
                     'down': a.shape(b[i + 2], P, f'chooser_{i}_down', px + bx, py + by)}
                    for i, (act, bx, by) in enumerate((('strike', 44, 9), ('tactical', 45, 47)))],
        'cursor': cursors(a, P, 'chooser'), 'timeout_s': 120.0}
    # the main menu
    P = a.palette([('OPTPALS', 0x15), ('OPTPALS', 0x18), ('MID1', 0x3b), ('MAINMENU', 2)])
    b = a.frames('MAINMENU', 0)
    acts = ['continue', 'load', 'new', 'training', 'objects']
    screens['main'] = {
        'background': [a.screen([(sky, 0, 0), (clouds, 0, 0), (hills, 0, 0)], P, 'main_bg'),
                       a.shape(a.frames('MAINMENU', 1)[0], P, 'main_panel', px, py)],
        'buttons': [{'action': act, 'rect': [px + 11, py + 10 + 17 * i, 210, 14],
                     'up': a.shape(b[i], P, f'main_{i}', px + 11, py + 10 + 17 * i),
                     'down': a.shape(b[5 + i], P, f'main_{i}_down', px + 11, py + 10 + 17 * i)}
                    for i, act in enumerate(acts)],
        'cursor': cursors(a, P, 'main'), 'music': {'set': 'midgames', 'track': 0x17}, 'idle_s': 30.0}
    # the licence for a new pilot
    P = a.palette([('OPTPALS', 0x1e)])
    screens['licence'] = {
        'background': [a.screen([(a.frames('OPTSHPS', 0xa0)[0], 0, 0)], P, 'licence_bg')],
        'fields': [{'key': 'last_name', 'x': 91, 'y': 97, 'max_w': 57},
                   {'key': 'first_name', 'x': 174, 'y': 97, 'max_w': 50},
                   {'key': 'callsign', 'x': 124, 'y': 103, 'max_w': 98}],
        'max_len': 15, 'font': font(a, 'FORMFONT', P, 'formfont'), 'cursor': cursors(a, P, 'licence')}
    with open(os.path.join(out, 'frontend.json'), 'w') as f:
        json.dump({'screens': screens}, f, separators=(',', ':'))
    log(f'  front end: {", ".join(screens)}')
    return {'frontend': 'frontend/frontend.json'}


if __name__ == '__main__':
    import sys
    convert(sys.argv[1], sys.argv[2], int(sys.argv[3]) if len(sys.argv) > 3 else 4)
