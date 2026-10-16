"""Weapons, decoys and sprite effects.

weapons/<NAME>.json  for OBJT forms MISS (missiles), TRCR (gun rounds), BOMB, DECY (flare/chaff)
sprites/<NAME>/      for objects whose appearance is an ANIM (explosions, sparks, smoke):
                     frame_<n>.png + sprite.json (frame order, hotspots)

Field meanings were inferred by comparing weapons with real-world figures (AIM-9M mass 85 kg,
AIM-120 152 kg, AGM-65D 210 kg; see docs/FORMATS.md).
"""
import json, os, struct, sys
import numpy as np
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import iff, shape, realspace as rs
from upscale import upscale_rgba
from cockpit import to_rgba

KINDS = (b'MISS', b'TRCR', b'BOMB', b'DECY', b'DURD')


def fx(b, o):
    return struct.unpack_from('<i', b, o)[0] / 256.0


def parse_weapon(name, form):
    out = {'name': name, 'kind': form.name.lower()}
    e = form.first(b'EXPL')
    if e:
        d = e.data
        out['explosion'] = d[:8].split(b'\0')[0].decode('latin1')
        out['blast_radius_ft'], out['explosion_damage'] = struct.unpack_from('<2H', d, 8)
    w = form.first(b'WDAT')
    if w:
        d = w.data
        out['damage'] = struct.unpack_from('<H', d, 0)[0]
        out['guidance'] = list(d[4:9])
        out['range_ft'] = struct.unpack_from('<I', d, 9)[0]
        out['seeker_cone_deg'] = d[13]
        out['range2_ft'] = struct.unpack_from('<I', d, 14)[0]
    dyn = form.first(b'DYNM')
    if dyn:
        if dyn.first(b'DYNM'):
            out['mass_kg'] = fx(dyn.first(b'DYNM').data, 0)
        m = dyn.first(b'MISS')
        if m:
            out['turn_g'], out['max_speed_ms'], out['motor'] = fx(m.data, 0), fx(m.data, 4), fx(m.data, 8)
    info = form.first(b'INFO')
    if form.name == 'TRCR' and info and len(info.data) >= 8:
        out['muzzle_velocity_ms'] = fx(info.data, 0)
    d = form.first(b'DATA')
    if d:
        out['data'] = list(d.data)
    return out


def convert(objects_dir, out_root, factor=4, log=print):
    pal = rs.load_palette(os.path.join(objects_dir, '..', 'PALETTE', 'PALETTE.IFF'))
    P = np.array([c + (255,) for c in pal], np.uint8)
    wdir, sdir = os.path.join(out_root, 'weapons'), os.path.join(out_root, 'sprites')
    os.makedirs(wdir, exist_ok=True)
    os.makedirs(sdir, exist_ok=True)
    nw = ns = 0
    for fn in sorted(os.listdir(objects_dir)):
        name = fn[:-4]
        root = iff.load(os.path.join(objects_dir, fn))[0]
        objt = root.first(b'OBJT')
        for c in (objt.children if objt else []):
            if c.kind in KINDS:
                with open(os.path.join(wdir, name + '.json'), 'w') as f:
                    json.dump(parse_weapon(name, c), f, indent=1)
                nw += 1
        appr = root.first(b'APPR')
        anim = appr.first(b'ANIM') if appr else None
        if anim and anim.first(b'SHAP'):
            frames = shape.decode_any(anim.first(b'SHAP').data)
            if not frames:
                continue
            out = os.path.join(sdir, name)
            os.makedirs(out, exist_ok=True)
            meta = {'name': name, 'frames': []}
            for i, s in enumerate(frames):
                upscale_rgba(to_rgba(s, P), factor).save(os.path.join(out, f'frame_{i}.png'), optimize=True)
                meta['frames'].append({'w': s.w, 'h': s.h, 'hotspot': [s.ox, s.oy]})
            if anim.first(b'INFO'):
                meta['info'] = list(struct.unpack_from('<2H', anim.first(b'INFO').data))
            if anim.first(b'SEQU'):
                meta['sequence'] = list(anim.first(b'SEQU').data)
            with open(os.path.join(out, 'sprite.json'), 'w') as f:
                json.dump(meta, f)
            ns += 1
    log(f'  {nw} weapons/decoys, {ns} sprite animations')


if __name__ == '__main__':
    convert(sys.argv[1], sys.argv[2])
