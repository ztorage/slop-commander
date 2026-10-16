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
  save/load  SAVELOAD.SHP: three skins of 21 frames (0: most screens, 21: screen 29, 42: the main
             menu), each drawn under its screen's palette; dialog at (80, 30), see `saveload()`.
  licence    OPTSHPS 0xa0 under OPTPALS 0x1e; FORMFONT text fields (last name, first name,
             callsign) at (91, 97), (174, 97), (124, 103), at most 15 letters and 57/50/98 px.

Output: gamedata/frontend/{frontend.json, *.png}
"""
import json, os, struct
import numpy as np
from PIL import Image
import shape, pak, realspace, upscale, iff


class Art:
    def __init__(self, extracted, out, factor):
        D = os.path.join(extracted, 'BIGTRE', 'DATA')
        rd = lambda *p: shape.pak_entries(open(os.path.join(D, *p), 'rb').read())
        self.paks = {'OBJVIEW': rd('GAMEFLOW', 'OBJVIEW.PAK'), 'OPTSHPS': rd('GAMEFLOW', 'OPTSHPS.PAK'), 'OPTPALS': rd('GAMEFLOW', 'OPTPALS.PAK'),
                     'MAINMENU': rd('GAMEFLOW', 'MAINMENU.PAK'), 'TOMENU': rd('GAMEFLOW', 'TOMENU.PAK'),
                     'MID1': rd('MIDGAMES', 'MID1.PAK'), 'MIDGAMES': rd('MIDGAMES', 'MIDGAMES.PAK')}
        self.files = {'MOUSE': open(os.path.join(D, 'MOUSE.SHP'), 'rb').read(),
                      'FORMFONT': open(os.path.join(D, 'FONTS', 'FORMFONT.SHP'), 'rb').read(),
                      'OPTFONT': open(os.path.join(D, 'FONTS', 'OPTFONT.SHP'), 'rb').read(),
                      'SAVELOAD': open(os.path.join(D, 'GAMEFLOW', 'SAVELOAD.SHP'), 'rb').read(),
                      'TM': open(os.path.join(D, 'GAMEFLOW', 'TM.SHP'), 'rb').read(),
                      'GAUNTMEN': open(os.path.join(D, 'GAMEFLOW', 'GAUNTMEN.SHP'), 'rb').read(),
                      'BWFONT': open(os.path.join(D, 'GAMEFLOW', 'BWFONT.SHP'), 'rb').read()}
        self.options = os.path.join(D, 'GAMEFLOW', 'OPTIONS.IFF')
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


def screen_palette(art, sid):
    """The palette of an OPTIONS.IFF location screen: base + BACK and FORE patches."""
    for sc in iff.load(art.options)[0].find(b'SCEN'):
        if sc.first(b'INFO').data[0] == sid:
            return art.palette([('OPTPALS', sc.first(b'BACK').first(b'PALT').data[0]),
                                ('OPTPALS', sc.first(b'FORE').first(b'PALT').data[0])])
    return art.palette([])


def saveload(art, P, skin, name):
    """The save/load dialog (OPTTEST.EXE overlay 0xC5): frames of one skin and the layout.
    Frame k of a skin: 0 dialog ("SAVE GAME"), 1 "LOAD GAME" title, 2/3 save, 4/5 load,
    6/7 cancel, 8/9 quit to DOS, 10/11 up, 12/13 down, 14 slider, 15 "are you sure" box,
    16 "overwrite", 17/18 yes, 19/20 no (odd/even = up/pressed)."""
    fr = art.frames('SAVELOAD')
    f = lambda k: fr[skin + k]
    dx, dy = 80, 30
    def button(action, k, x, y, w, h, ox=dx, oy=dy):
        return {'action': action, 'rect': [ox + x, oy + y, w, h],
                'up': art.shape(f(k), P, f'{name}_{k}', ox + x, oy + y),
                'down': art.shape(f(k + 1), P, f'{name}_{k + 1}', ox + x, oy + y)}
    cx, cy = 0x65, 0x55
    return {
        'body': art.shape(f(0), P, f'{name}_0', dx, dy),
        'load_title': art.shape(f(1), P, f'{name}_1', 0x72, 0x24),
        'save': button('ok', 2, 0x36, 0x61, 0x4b, 0xc), 'load': button('ok', 4, 0x36, 0x61, 0x4b, 0xc),
        'buttons': [button('cancel', 6, 0xa, 0x70, 0x50, 0xc), button('quit', 8, 0x5e, 0x70, 0x50, 0xc),
                    button('up', 10, 9, 0x29, 0x14, 0xb), button('down', 12, 9, 0x53, 0x14, 0xb)],
        'slider': art.shape(f(14), P, f'{name}_14', 0, 0), 'slider_x': 0x5d, 'slider_y': 0x52, 'slider_range': 25,
        'name_at': [0x71, 0x3a], 'name_rect': [0x6e, 0x38, 0xe9, 0x42], 'max_len': 8,
        'list_rect': [0x6e, 0x47, 0xe9, 0x79], 'rows': 5, 'row_h': 10,
        'confirm': {'box': art.shape(f(15), P, f'{name}_15', cx, cy),
                    'overwrite': art.shape(f(16), P, f'{name}_16', 0x77, 0x60),
                    'buttons': [button('yes', 17, 0x12, 0x19, 0x2e, 0xc, cx, cy), button('no', 19, 0x45, 0x19, 0x2c, 0xc, cx, cy)]},
        'font': font(art, 'OPTFONT', P, f'{name}_font')}


# The training missions (OPTTEST.EXE overlay 0xCA): a wizard of button bars over the OBJVIEW
# painting. Per page: TM.SHP panel frame, panel position, buttons (x, y, w, h relative to the
# panel, up frame, code; the pressed frame follows the up frame). Codes -1 back up, -2 cancel.
TRAINING_PAGES = {
    'type': (0, 153, [(0x10, 9, 0x88, 0xc, 1, 2), (0x9b, 9, 0x88, 0xc, 3, 1), ('gauntlet', 0x10, 0x18, 0x87, 0xb, 0, 3),
                      (0x9b, 0x18, 0x41, 0xc, 5, -1)]),
    'count': (7, 153, [(0x71 + 17 * i, 9, 0xe, 0xc, 8 + 2 * i, i + 1) for i in range(5)]
                      + [(0x57, 0x18, 0x41, 0xc, 0x12, -1), (0x9b, 0x18, 0x41, 0xc, 0x14, -2)]),
    'aircraft': (22, 116, [(x, y, 0x41, 0xc, 0x17 + 2 * (4 * c + r), 4 * c + r + 1)
                           for c, x in enumerate((9, 0x4d, 0x91, 0xeb)) for r, y in enumerate((7, 0x14, 0x21, 0x2e))]
                          + [(0x57, 0x3d, 0x41, 0xc, 0x37, -1), (0x9b, 0x3d, 0x41, 0xc, 0x39, -2)]),
    'more': (59, 153, [(0x57, 9, 0x41, 0xc, 0x3c, 1), (0x9b, 9, 0x41, 0xc, 0x3e, 2),
                       (0x57, 0x18, 0x41, 0xc, 0x40, -1), (0x9b, 0x18, 0x41, 0xc, 0x42, -2)]),
    'altitude': (68, 153, [(x, 9, 0x41, 0xc, 0x45 + 2 * i, i + 1) for i, x in enumerate((0x13, 0x57, 0x9b, 0xdf))]
                          + [(0x57, 0x18, 0x41, 0xc, 0x4d, -1), (0x9b, 0x18, 0x41, 0xc, 0x4f, -2)]),
    'skill': (81, 153, [(x, 9, 0x41, 0xc, 0x52 + 2 * i, i + 1) for i, x in enumerate((0x36, 0x7a, 0xbe))]
                       + [(0x57, 0x18, 0x41, 0xc, 0x58, -1), (0x9b, 0x18, 0x41, 0xc, 0x5a, -2)]),
    'accept': (92, 153, [(0x79, 9, 0x41, 0xc, 0x5d, 1), (0x57, 0x18, 0x41, 0xc, 0x5f, -1), (0x9b, 0x18, 0x41, 0xc, 0x61, -2)]),
}
# the aircraft list (DS 0x116D, 15-byte records: name, object, loadout, ...), with the remake's ids
TRAINING_AIRCRAFT = [('F-15', 'F-15'), ('F-16', 'F-16GRAY'), ('F/A-18', 'F-18'), ('C-130', 'C130DES'), ('F-22', 'F-22'),
                     ('YF-23', 'YF23'), ('A-10', 'A-10'), ('E-3', 'AWACS'), ('Tornado', 'TORNCG'), ('Mirage 2000', 'MIRAGE'),
                     ('Lear Jet', 'LEARJET'), ('747', '747'), ('MiG-21', 'MIG21'), ('MiG-29', 'MIG29'), ('Su-27', 'SU27'),
                     ('TU-95', 'TU-20')]


def training(art, P):
    tm, gm = art.frames('TM'), art.frames('GAUNTMEN')
    pages = {}
    for name, (frame, py, buttons) in TRAINING_PAGES.items():
        bs = []
        for b in buttons:
            shp = tm
            if b[0] == 'gauntlet':
                shp, b = gm, b[1:]
            x, y, w, h, up, code = b
            ax, ay = 6 + x, py + y
            bs.append({'action': code, 'rect': [ax, ay, w, h],
                       'up': art.shape(shp[up], P, f'tm_{name}_{up}', ax, ay),
                       'down': art.shape(shp[up + 1], P, f'tm_{name}_{up}_down', ax, ay)})
        pages[name] = {'panel': art.shape(tm[frame], P, f'tm_{name}', 6, py), 'buttons': bs}
    return {'background': [art.screen([(art.frames('OBJVIEW', 6)[0], 0, 0), (art.frames('OBJVIEW', 1)[0], 4, 3)], P, 'tm_bg')],
            'pages': pages, 'font': font(art, 'BWFONT', P, 'bwfont'), 'cursor': cursors(art, P, 'tm'),
            'aircraft': [{'name': n, 'id': i} for n, i in TRAINING_AIRCRAFT], 'skills': ['rookie', 'veteran', 'ace'],
            'text': {'df_title': 'Mission Briefing: Air Superiority', 'df_brief': 'Intercept and engage inbound bogeys:',
                     'sd': ['Mission Briefing: Ground Attack', 'Search and destroy enemy targets at',
                            "pilot's discretion.  Refer to area", 'map for enemy positions.']}}


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
    # the save/load dialog: the main menu's skin, and the two location screens that save
    screens['main']['saveload'] = saveload(a, P, 42, 'sl_main')
    dialogs = {'14': saveload(a, screen_palette(a, 14), 0, 'sl_14'),
               '29': saveload(a, screen_palette(a, 29), 21, 'sl_29')}
    screens['training'] = training(a, a.palette([('OBJVIEW', 7)]))
    # the licence for a new pilot
    P = a.palette([('OPTPALS', 0x1e)])
    screens['licence'] = {
        'background': [a.screen([(a.frames('OPTSHPS', 0xa0)[0], 0, 0)], P, 'licence_bg')],
        'fields': [{'key': 'last_name', 'x': 91, 'y': 97, 'max_w': 57},
                   {'key': 'first_name', 'x': 174, 'y': 97, 'max_w': 50},
                   {'key': 'callsign', 'x': 124, 'y': 103, 'max_w': 98}],
        'max_len': 15, 'font': font(a, 'FORMFONT', P, 'formfont'), 'cursor': cursors(a, P, 'licence')}
    with open(os.path.join(out, 'frontend.json'), 'w') as f:
        json.dump({'screens': screens, 'saveload': dialogs}, f, separators=(',', ':'))
    log(f'  front end: {", ".join(screens)}')
    return {'frontend': 'frontend/frontend.json'}


if __name__ == '__main__':
    import sys
    convert(sys.argv[1], sys.argv[2], int(sys.argv[3]) if len(sys.argv) > 3 else 4)
