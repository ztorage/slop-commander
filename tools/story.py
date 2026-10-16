"""Campaign ("gameflow") data: story script, location screens, conversations, their art and speech.

Sources (GAMEFLOW/ in BIGTRE):
  GAMEFLOW.IFF  FORM GAME: per story stage MISS {INFO id, EFCT script, SCEN* {INFO screen id,
                SPRT* {INFO sprite id, EFCT click script, REQU flag conditions}}};
                WRLD (travel maps), LOAD, MLST (mission file names + theatres), WNGS, STAT (CHNG
                state changes: cash / overhead / weapon stock / kill board).
  OPTIONS.IFF   FORM OPTS: SCEN* {INFO id, COLR, TUNE, BACK {PALT, SHAP*}, FORE {PALT, SPRT*
                {SHAP [sprite id, OPTSHPS index or 0xff, ?], LABL, RECT|QUAD, INFO, SEQU, TUNE, CLCK}}}
  OPTSHPS.PAK / OPTPALS.PAK   screen art (shape sets, absolute screen coordinates) and palette
                patches (u16 first colour, u16 count, 6-bit RGB triplets).
  CONV.PAK      256 conversation scripts (frame stream, see parse_conv).
  CONVDATA.IFF  BCKS (set name -> layers: u8 source 0 conv/1 opt, u8 shape, u8 palette, i16 y),
                FACE / FIGR (name -> CONVSHPS set), PFIG (figure palette), FCPL / FGPL palettes.
  VOCLIST.TRE   speech, F_<code>.VOC, referenced by the conversation frames.

Output: gamedata/story/{gameflow,screens,conversations,convart}.json + img/ + voice/.
"""
import json, os, struct
import numpy as np
from PIL import Image
import iff, shape, realspace
import upscale
from audio import voc_to_pcm, write_wav
from upscale import upscale_rgba

U16 = lambda d, p: struct.unpack_from('<H', d, p)[0]


# ---------------------------------------------------------------- gameflow script
def _pairs(data):
    return [[data[i], data[i + 1]] for i in range(0, len(data) - 1, 2)]


def parse_gameflow(path):
    out = {'stages': {}, 'maps': {}, 'changes': {}, 'missions': [], 'theatres': [], 'wings': [], 'loads': []}
    for top in iff.load(path):
        if top.name == 'GAME':
            for m in top.find(b'MISS'):
                st = {'efct': _pairs(m.first(b'EFCT').data) if m.first(b'EFCT') else [], 'scenes': []}
                for sc in m.find(b'SCEN'):
                    scene = {'id': sc.first(b'INFO').data[0], 'sprites': []}
                    for sp in sc.find(b'SPRT'):
                        scene['sprites'].append({
                            'id': sp.first(b'INFO').data[0],
                            'efct': _pairs(sp.first(b'EFCT').data) if sp.first(b'EFCT') else [],
                            'requ': _pairs(sp.first(b'REQU').data) if sp.first(b'REQU') else []})
                    st['scenes'].append(scene)
                out['stages'][m.first(b'INFO').data[0]] = st
        elif top.name == 'WRLD':
            for m in top.find(b'MAPS'):
                d = m.first(b'DATA').data
                pts, p = [], 1
                for _ in range(d[0]):
                    x, y = struct.unpack_from('<HH', d, p); p += 4
                    e = d.index(0, p)
                    pts.append({'x': x, 'y': y, 'name': d[p:e].decode('latin1')}); p = e + 1
                sped = m.first(b'SPED')
                out['maps'][m.first(b'INFO').data[0]] = {
                    'points': pts, 'speed': struct.unpack_from('<I', sped.data)[0] if sped else 0}
        elif top.name == 'STAT':
            for c in top.find(b'CHNG'):
                ch = {}
                for k in ('CASH', 'OVER'):
                    x = c.first(k.encode())
                    if x:
                        ch[k.lower()] = [x.data[0], struct.unpack_from('<I', x.data, 1)[0]]   # op, $1000s
                w = c.first(b'WEAP')
                if w:
                    ch['weapons'] = [[w.data[i], w.data[i + 1], U16(w.data, i + 2)] for i in range(0, len(w.data) - 3, 4)]
                pl = c.first(b'PILT')
                if pl:
                    ch['kills'] = [[pl.data[i], pl.data[i + 1], pl.data[i + 2], U16(pl.data, i + 3)]
                                   for i in range(0, len(pl.data) - 4, 5)]       # op, pilot, kind, value
                out['changes'][c.first(b'INFO').data[0]] = ch
        elif top.name == 'MLST':
            d = top.first(b'DATA').data
            out['missions'] = [d[i:i + 8].split(b'\0')[0].decode('latin1').upper() for i in range(0, len(d) - 7, 8)]
            t = top.first(b'PRTL').data
            out['theatres'] = [[t[i:i + 8].split(b'\0')[0].split(b'\n')[0].decode('latin1'), t[i + 8]]
                               for i in range(0, len(t) - 8, 9)]
        elif top.name == 'WNGS':
            out['wings'] = [list(w.first(b'PILT').data) for w in top.find(b'WING')]
        elif top.name == 'LOAD':
            out['loads'] = [list(x.data) for x in top.find(b'LOAD')]
    return out


# ---------------------------------------------------------------- conversations
def _cstr(d, p):
    e = d.index(0, p)
    return d[p:e].decode('latin1'), e + 1


def _name(d, p):
    return d[p:p + 9].split(b'\0')[0].decode('latin1'), p + 9


def parse_conv(d):
    """Frames of one conversation script. Byte offsets are kept for the choice jumps."""
    p, out = 0, []
    while p < len(d):
        at, t = p, d[p]
        p += 1
        if t == 0x00:                                   # wide shot of a set
            st, p = _name(d, p)
            f = {'type': 'wide', 'set': st}
        elif t == 0x01:                                 # figure placed in the wide shot
            who, p = _name(d, p)
            x, y = struct.unpack_from('<HH', d, p); p += 4
            f = {'type': 'figure', 'who': who, 'x': x, 'y': y}
        elif t == 0x02:                                 # a figure in the wide shot speaks
            who, p = _name(d, p)
            x, y = struct.unpack_from('<HH', d, p); p += 4
            col = d[p]; p += 1
            snd, p = _cstr(d, p); txt, p = _cstr(d, p)
            f = {'type': 'figure_talk', 'who': who, 'x': x, 'y': y, 'color': col, 'voice': snd, 'text': txt}
        elif t == 0x03:                                 # close-up: face (hotspot at x, y) on a set
            who, p = _name(d, p)
            expr = d[p]; p += 1
            st, p = _name(d, p)
            x, y = struct.unpack_from('<HH', d, p); p += 4
            snd, p = _cstr(d, p); txt, p = _cstr(d, p)
            col = d[p]; p += 1
            f = {'type': 'closeup', 'who': who, 'expr': expr, 'set': st, 'x': x, 'y': y,
                 'voice': snd, 'text': txt, 'color': col}
        elif t == 0x04:                                 # the same speaker carries on
            snd, p = _cstr(d, p); txt, p = _cstr(d, p)
            f = {'type': 'more', 'voice': snd, 'text': txt}
        elif t == 0x0A:                                 # caption
            col = d[p]; p += 1
            snd, p = _cstr(d, p); txt, p = _cstr(d, p)
            f = {'type': 'caption', 'color': col, 'voice': snd, 'text': txt}
        elif t == 0x0B:                                 # yes/no: "no" jumps forward
            f = {'type': 'choice', 'skip': U16(d, p)}; p += 2
        elif t == 0x0C:                                 # end of the "yes" branch: jump over "no"
            f = {'type': 'jump', 'skip': U16(d, p)}; p += 2
        elif t == 0x0E:
            f = {'type': 'op0e', 'value': U16(d, p)}; p += 2
        elif t == 0x0F:                                 # pick a wingman ($W)
            f = {'type': 'wingman'}
        else:
            f = {'type': 'unknown', 'code': t}
            out.append(dict(f, at=at, end=p))
            break
        out.append(dict(f, at=at, end=p))
    # resolve byte jumps to frame indices
    by_at = {f['at']: i for i, f in enumerate(out)}
    for f in out:
        if 'skip' in f:
            f['to'] = by_at.get(f['end'] + f['skip'], len(out))
    for f in out:
        f.pop('at'); f.pop('end'); f.pop('skip', None)
    return out


# ---------------------------------------------------------------- art
class Art:
    def __init__(self, gameflow_dir, base_palette, out_img, factor, log):
        pk = lambda n: shape.pak_entries(open(os.path.join(gameflow_dir, n), 'rb').read())
        self.opt_shapes, self.opt_pals = pk('OPTSHPS.PAK'), pk('OPTPALS.PAK')
        self.conv_shapes, self.conv_pals = pk('CONVSHPS.PAK'), pk('CONVPALS.PAK')
        self.base = np.array(base_palette, np.uint8)
        self.out, self.factor, self.log = out_img, factor, log
        self._shape_cache = {}
        os.makedirs(out_img, exist_ok=True)

    def patch(self, P, pals, i):
        d = pals[i] if 0 <= i < len(pals) else b''
        if len(d) < 4:
            return P
        s, n = struct.unpack_from('<HH', d)
        n = min(n, (len(d) - 4) // 3, 256 - s)
        P = P.copy()
        P[s:s + n] = np.frombuffer(d[4:4 + n * 3], np.uint8).reshape(-1, 3).astype(int) * 255 // 63
        return P

    def frames(self, src, idx):
        """All shapes of an entry (nested shape sets flattened), cached."""
        key = (src, idx)
        if key not in self._shape_cache:
            entries = self.opt_shapes if src == 'opt' else self.conv_shapes
            blob = entries[idx] if 0 <= idx < len(entries) else b''
            shapes = shape.decode_any(blob)
            if not shapes and len(blob) > 8:
                try:      # a PAK of shapes whose size word doesn't match (face sets)
                    shapes = [shape.decode_shape(e) for _, e in __import__('pak').read_pak(shape.unwrap(blob))]
                except Exception:
                    shapes = []
            self._shape_cache[key] = shapes
        return self._shape_cache[key]

    def save(self, s, P, name, under=()):
        """Save a shape as an RGBA PNG cropped to its pixels; return {file, x, y, w, h} where (x, y)
        is the top-left relative to the shape's hotspot, in original 320x200 pixels.
        `under`: (shape, dx, dy) layers drawn beneath it (their hotspot at dx, dy from this one's);
        the AI upscaler sees the layer over them, so overlays (mouths, heads) match their base."""
        if s is None:
            return None
        mask = s.pixels != shape.TRANSPARENT
        if not mask.any():
            return None
        ys, xs = np.nonzero(mask)
        y0, y1, x0, x1 = ys.min(), ys.max() + 1, xs.min(), xs.max() + 1
        entry = {'file': name + '.png', 'x': int(x0 - s.ox), 'y': int(y0 - s.oy), 'w': int(x1 - x0), 'h': int(y1 - y0)}
        if upscale.AI and self.factor == 4:
            self._save_ai(s, P, name, (x0, y0, x1, y1), under)
            return entry
        px = s.pixels[y0:y1, x0:x1]
        rgba = np.zeros(px.shape + (4,), np.uint8)
        rgba[..., :3] = P[px]
        rgba[..., 3] = np.where(px == shape.TRANSPARENT, 0, 255)
        img = upscale_rgba(Image.fromarray(rgba, 'RGBA'), self.factor)
        img.save(os.path.join(self.out, name + '.png'), optimize=True)
        return entry

    MARGIN = 6   # context pixels around a layer for the AI upscaler

    def _save_ai(self, s, P, name, box, under):
        import ai_upscale
        x0, y0, x1, y1 = box
        m = self.MARGIN
        # region in this shape's hotspot coordinates, with a margin of context
        hx, hy = x0 - s.ox - m, y0 - s.oy - m
        w, h = x1 - x0 + 2 * m, y1 - y0 + 2 * m
        idx = np.full((h, w), -1, np.int16)

        def blit(src, dx, dy):
            # src pixel (u, v) sits at hotspot coords (u - src.ox + dx, v - src.oy + dy)
            ox, oy = -src.ox + dx - hx, -src.oy + dy - hy
            sx0, sy0 = max(0, -ox), max(0, -oy)
            sx1, sy1 = min(src.w, w - ox), min(src.h, h - oy)
            if sx1 <= sx0 or sy1 <= sy0:
                return
            part = src.pixels[sy0:sy1, sx0:sx1]
            dst = idx[sy0 + oy:sy1 + oy, sx0 + ox:sx1 + ox]
            opaque = part != shape.TRANSPARENT
            dst[opaque] = part[opaque]

        fade = np.zeros((h, w), bool)
        for entry_ in under:
            u, dx, dy = entry_[:3]
            if u is not None:
                before = idx >= 0
                blit(u, dx, dy)
                if len(entry_) > 3 and entry_[3]:
                    fade |= (idx >= 0) & ~before
        beneath = np.where(fade, 255, 0).astype(np.uint8)
        blit(s, 0, 0)
        own = np.zeros((h, w), np.uint8)
        own[m:m + y1 - y0, m:m + x1 - x0] = np.where(s.pixels[y0:y1, x0:x1] != shape.TRANSPARENT, 255, 0)
        rgba = np.zeros((h, w, 4), np.uint8)
        rgba[..., :3] = P[np.clip(idx, 0, 255)]
        rgba[..., 3] = np.where(idx >= 0, 255, 0)
        rgba = upscale._bleed(rgba)
        out = ai_upscale.upscale_rgba(rgba, own, beneath)
        f = self.factor
        Image.fromarray(out[m * f:(h - m) * f, m * f:(w - m) * f], 'RGBA').save(os.path.join(self.out, name + '.png'), optimize=True)


def convert_screens(opts_path, art):
    screens = {}
    for sc in iff.load(opts_path)[0].find(b'SCEN'):
        sid = sc.first(b'INFO').data[0]
        back, fore = sc.first(b'BACK'), sc.first(b'FORE')
        P = art.patch(art.patch(art.base, art.opt_pals, back.first(b'PALT').data[0]), art.opt_pals, fore.first(b'PALT').data[0])
        scr = {'id': sid, 'color': sc.first(b'COLR').data[0] if sc.first(b'COLR') else 0,
               'tune': sc.first(b'TUNE').data[0] if sc.first(b'TUNE') else None, 'layers': [], 'sprites': []}
        below = []        # what lies beneath the next layer (first frames, screen coordinates)
        for li, c in enumerate(back.find(b'SHAP')):
            shapes = art.frames('opt', c.data[0])
            fr = [art.save(s, P, f'scr{sid}_bg{li}_{fi}', below) for fi, s in enumerate(shapes)]
            scr['layers'].append([f for f in fr if f])
            if shapes:
                below = below + [(shapes[0], 0, 0)]
        for sp in fore.find(b'SPRT'):
            sh = sp.first(b'SHAP').data
            spr = {'id': sh[0], 'label': sp.first(b'LABL').data.split(b'\0')[0].decode('latin1').replace('\\', ''),
                   'frames': []}
            r = sp.first(b'RECT')
            if r:
                spr['rect'] = list(struct.unpack_from('<4H', r.data))            # x0, y0, x1, y1
            q = sp.first(b'QUAD')
            if q:
                spr['quad'] = list(struct.unpack_from('<%dH' % (len(q.data) // 2), q.data))
            for k in ('INFO', 'SEQU'):
                x = sp.first(k.encode())
                if x:
                    spr[k.lower()] = list(struct.unpack_from('<%dH' % (len(x.data) // 2), x.data))
            if sp.first(b'TUNE'):
                spr['tune'] = sp.first(b'TUNE').data[0]
            if sp.first(b'CLCK'):
                spr['click'] = 1
            if sh[1] != 0xFF:
                shapes = art.frames('opt', sh[1])
                base = shapes[0] if shapes else None
                spr['frames'] = [art.save(s, P, f'scr{sid}_s{sh[0]}_{fi}', below + ([(base, 0, 0, True)] if fi > 0 and base else []))
                                 for fi, s in enumerate(shapes)]
            scr['sprites'].append(spr)
        screens[sid] = scr
    return screens


def convert_shots(opts_path, art):
    """Establishing shots (OPTIONS.IFF ESTB): palette patches applied in order, then layers
    (SHAP static, MOBL animated) of OPTSHPS art at (x, y) in conversation coordinates."""
    shots = {}
    for top in iff.load(opts_path):
        if top.name != 'ESTB':
            continue
        for s in top.find(b'SHOT'):
            sid = s.first(b'INFO').data[0]
            P = art.base
            for p in s.first(b'PALS').find(b'PALT'):
                P = art.patch(P, art.opt_pals, p.data[0])
            layers, below = [], []
            for li, c in enumerate(s.first(b'SHPS').children):
                shp, x, y = struct.unpack_from('<Hhh', c.data)
                fr = art.frames('opt', shp)
                if c.name == 'SHAP':
                    fr = fr[:1]
                ctx = [(u, ux - x, uy - y) for u, ux, uy in below]
                saved = [art.save(f, P, f'shot{sid}_{li}_{fi}', ctx) for fi, f in enumerate(fr)]
                if fr and c.name == 'SHAP':
                    below.append((fr[0], x, y))
                layers.append({'x': x, 'y': y, 'anim': c.name == 'MOBL', 'frames': [f for f in saved if f]})
            shots[sid] = layers
    return shots


HAIR = 1                # face set frames (see FORMATS.md): 1 hair, 34-36 clothing
CLOTHES = (34, 35, 36)  # the conversation player shows the first one a face has


def _has_pixels(s):
    return s is not None and (s.pixels != shape.TRANSPARENT).any()


def merge_shapes(shapes):
    """Flatten shapes sharing a hotspot (later ones on top) into one shape."""
    left = max(s.ox for s in shapes); top = max(s.oy for s in shapes)
    right = max(s.w - s.ox for s in shapes); bottom = max(s.h - s.oy for s in shapes)
    px = np.full((top + bottom, left + right), shape.TRANSPARENT, np.uint8)
    for s in shapes:
        x0, y0 = left - s.ox, top - s.oy
        dst = px[y0:y0 + s.h, x0:x0 + s.w]
        opaque = s.pixels != shape.TRANSPARENT
        dst[opaque] = s.pixels[opaque]
    return shape.Shape(left + right, top + bottom, left, top, px)


def convert_convart(convdata_path, art):
    root = {c.name: c for c in iff.load(convdata_path)}
    out = {'sets': {}, 'faces': {}, 'figures': {}}
    nm = lambda d: d[:8].split(b'\0')[0].decode('latin1')
    face_pal = {nm(c.data): c.data[8] for c in root['FCPL'].children} if 'FCPL' in root else {}
    fig_pal = {nm(c.data): c.data[8] for c in root['PFIG'].children} if 'PFIG' in root else {}
    for b in root['BCKS'].find(b'BACK'):
        name = nm(b.first(b'INFO').data)
        d = b.first(b'DATA').data
        layers = [(d[i], d[i + 1], d[i + 2], struct.unpack_from('<h', d, i + 3)[0]) for i in range(0, len(d) - 4, 5)]
        P = art.base
        for src, shp, pal, _ in layers:          # the set's palette: patches applied in layer order
            P = art.patch(P, art.opt_pals if src == 1 else art.conv_pals, pal)
        imgs, below = [], []
        for li, (src, shp, pal, dy) in enumerate(layers):
            fr = art.frames('opt' if src == 1 else 'conv', shp)
            f = art.save(fr[0], P, f'set_{name}_{li}', [(u, 0, udy - dy) for u, udy in below]) if fr else None
            if fr:
                below.append((fr[0], dy))
            if f:
                f['y'] += dy
                imgs.append(f)
        out['sets'][name] = imgs
    normal = art.patch(art.base, art.conv_pals, face_pal.get('normal', 0x2E))
    out['text_palette'] = ['%02x%02x%02x' % tuple(int(v) for v in c) for c in normal]   # subtitle colours
    for c in root['FACE'].children:
        name = nm(c.data)
        fr = list(art.frames('conv', c.data[8]))
        merged = [i for i in [0, HAIR] if i < len(fr) and _has_pixels(fr[i])]
        clothes = next((i for i in CLOTHES if i < len(fr) and _has_pixels(fr[i])), None)
        if clothes is not None:
            merged.append(clothes)
        if merged and merged[0] == 0:
            fr[0] = merge_shapes([fr[i] for i in merged])      # drawn as one picture: no seams
            for i in [HAIR, *CLOTHES]:      # now part of the base (unused clothing goes too)
                if i < len(fr):
                    fr[i] = None
        base = [(fr[0], 0, 0, True)] if fr and fr[0] is not None else []
        out['faces'][name] = [art.save(s, normal, f'face_{name}_{i}', base if i > 0 else ()) for i, s in enumerate(fr)]
    for c in root['FIGR'].children:
        name = nm(c.data)
        P = art.patch(art.base, art.conv_pals, fig_pal.get(name, 0x30))
        fr = art.frames('conv', c.data[8])
        base = [(fr[0], 0, 0, True)] if fr and fr[0] is not None else []
        out['figures'][name] = [art.save(s, P, f'fig_{name}_{i}', base if i > 0 else ()) for i, s in enumerate(fr)]
    return out


# ---------------------------------------------------------------- speech
def convert_voices(voc_dirs, convs, out_dir, log):
    os.makedirs(out_dir, exist_ok=True)
    files = {}
    for d in voc_dirs:
        if os.path.isdir(d):
            for fn in os.listdir(d):
                if fn.upper().startswith('F_') and fn.upper().endswith('.VOC'):
                    files.setdefault(fn[2:-4].lower(), os.path.join(d, fn))
    wanted = {f['voice'].lower() for c in convs for f in c if f.get('voice')}
    done = 0
    for code in sorted(wanted):
        src = files.get(code)
        if not src:
            continue
        r = voc_to_pcm(open(src, 'rb').read())
        if r:
            write_wav(os.path.join(out_dir, code + '.wav'), r[0], r[1])
            done += 1
    log(f'  {done}/{len(wanted)} speech clips')
    return done


def convert(extracted, out_root, factor=4, log=print):
    gf = os.path.join(extracted, 'BIGTRE', 'DATA', 'GAMEFLOW')
    os.makedirs(out_root, exist_ok=True)
    flow = parse_gameflow(os.path.join(gf, 'GAMEFLOW.IFF'))
    convs = [parse_conv(e) for e in shape.pak_entries(open(os.path.join(gf, 'CONV.PAK'), 'rb').read())]
    pal = realspace.load_palette(os.path.join(extracted, 'BIGTRE', 'DATA', 'PALETTE', 'PALETTE.IFF'))
    art = Art(gf, pal, os.path.join(out_root, 'img'), factor, log)
    screens = convert_screens(os.path.join(gf, 'OPTIONS.IFF'), art)
    convart = convert_convart(os.path.join(gf, 'CONVDATA.IFF'), art)
    convart['shots'] = convert_shots(os.path.join(gf, 'OPTIONS.IFF'), art)
    convert_voices([os.path.join(extracted, 'VOCLIST'), os.path.join(extracted, 'TOVOCLST')], convs,
                   os.path.join(out_root, 'voice'), log)
    for name, obj in (('gameflow', flow), ('screens', screens), ('conversations', convs), ('convart', convart)):
        with open(os.path.join(out_root, name + '.json'), 'w') as f:
            json.dump(obj, f, separators=(',', ':'))
    log(f'  {len(flow["stages"])} story stages, {len(screens)} screens, {len(convs)} conversations, '
        f'{len(convart["faces"])} faces, {len(convart["sets"])} sets, {len(convart["shots"])} shots')
    return {'story': 'story/gameflow.json'}


if __name__ == '__main__':
    import sys
    convert(sys.argv[1], sys.argv[2], int(sys.argv[3]) if len(sys.argv) > 3 else 4)
