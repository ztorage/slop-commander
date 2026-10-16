"""Convert cockpits (OBJECTS/*.IFF with FORM CKPT) for the Godot remake.

All art is authored for a 320x200 screen. Output per cockpit (gamedata/cockpits/<NAME>/):
  view_<n>.png        full-screen views from ARTP (0 front, 1 left, 2 right, 3 rear, 4 front/panel low)
  <part>_<n>.png      instrument and MFD shapes, upscaled, transparent background
  eject_<n>.png       ejection sequence frames
  cockpit.json        layout in 320x200 coordinates + upscale factor + shape hotspots
"""
import json, os, struct, sys
import numpy as np
from PIL import Image
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import iff, shape, realspace as rs
import upscale

# In-panel MFD screens and HUD glass are painted into the art rather than described by
# chunks; measured from the F-16 front view (320x200 coordinates, inclusive).
KNOWN_LAYOUT = {
    'F16-CKPT': {'mfd_screens': {'L': [64, 147, 112, 185], 'R': [209, 147, 257, 185]},
                 'hud_glass': [108, 6, 214, 100], 'boresight': [160, 55],
                 # view 4: the same front view zoomed onto the HUD (posts ~1.47x further apart)
                 'hud_glass_zoom': [95, 4, 227, 130], 'boresight_zoom': [160, 64], 'zoom_fov_scale': 0.68},
}
DEFAULT_LAYOUT = {'mfd_screens': {}, 'hud_glass': [100, 10, 220, 100], 'boresight': [160, 55]}


def to_rgba(s, P):
    a = P[s.pixels].copy()
    a[s.pixels == shape.TRANSPARENT] = (0, 0, 0, 0)
    return Image.fromarray(a, 'RGBA')


def save_shapes(shapes, P, out, prefix, factor):
    meta = []
    for i, s in enumerate(shapes):
        upscale.save(to_rgba(s, P), os.path.join(out, f'{prefix}_{i}.png'))
        meta.append({'file': f'{prefix}_{i}.png', 'w': s.w, 'h': s.h, 'hotspot': [s.ox, s.oy]})
    return meta


def i16s(data):
    return list(struct.unpack_from('<%dh' % (len(data) // 2), data))


def convert_one(path, out, P, factor):
    root = iff.load(path)[0]
    name = os.path.splitext(os.path.basename(path))[0]
    os.makedirs(out, exist_ok=True)
    layout = dict(KNOWN_LAYOUT.get(name, DEFAULT_LAYOUT))
    info = {'name': name, 'screen': [320, 200], **layout}

    info['views'] = save_shapes(shape.decode_any(root.first(b'ARTP').data), P, out, 'view', factor)
    if root.first(b'EJEC'):
        info['eject'] = save_shapes(shape.decode_any(root.first(b'EJEC').data), P, out, 'eject', factor)
    for tag in (b'GHUD', b'GUNF'):
        c = root.first(tag)
        if c:
            info[tag.decode().lower()] = save_shapes(shape.decode_any(c.data), P, out, tag.decode().lower(), factor)

    inst = root.first(b'INST')
    info['instruments'] = {}
    if inst:
        for f in inst.children:
            if not f.kind:
                continue
            key = f.name.lower()
            entry = {'info': i16s(f.first(b'INFO').data) if f.first(b'INFO') else []}
            shp = f.first(b'SHAP')
            if shp and shp.kind:  # FORM SHAP with named variants (RAWS: SYMB/ZOOM/NORM)
                for v in shp.children:
                    entry[v.name.lower()] = save_shapes(shape.decode_any(v.data), P, out, f'{key}_{v.name.lower()}', factor)
            elif shp:
                entry['shapes'] = save_shapes(shape.decode_any(shp.data), P, out, key, factor)
            info['instruments'][key] = entry

    moni = root.first(b'MONI')
    if moni:
        m = {'bezel': save_shapes(shape.decode_any(moni.first(b'SHAP').data), P, out, 'mfd_bezel', factor)}
        sp = moni.first(b'SPOT').data if moni.first(b'SPOT') else b''
        m['zoom_spots'] = {chr(sp[k]): list(struct.unpack_from('<hh', sp, k + 1)) for k in range(0, len(sp) - 4, 5)}
        m['modes'] = {}
        mfds = moni.first(b'MFDS')
        for f in (mfds.children if mfds else []):
            if f.kind and f.first(b'SHAP'):
                m['modes'][f.name.lower()] = save_shapes(shape.decode_any(f.first(b'SHAP').data), P, out, 'mfd_' + f.name.lower(), factor)
        info['mfd'] = m

    with open(os.path.join(out, 'cockpit.json'), 'w') as fp:
        json.dump(info, fp, indent=1)
    return name


def convert(objects_dir, out_root, factor=4, log=print):
    pal = rs.load_palette(os.path.join(objects_dir, '..', 'PALETTE', 'PALETTE.IFF'))
    P = np.array([c + (255,) for c in pal], np.uint8)
    done = []
    for fn in sorted(os.listdir(objects_dir)):
        path = os.path.join(objects_dir, fn)
        with open(path, 'rb') as f:
            head = f.read(12)
        if head[8:12] != b'CKPT':
            continue
        done.append(convert_one(path, os.path.join(out_root, fn[:-4]), P, factor))
    log(f'  cockpits: {", ".join(done)}')
    return done


if __name__ == '__main__':
    convert(sys.argv[1], sys.argv[2])
