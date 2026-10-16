"""Convert Strike Commander theatre maps (<THEATRE>.PAK) for the Godot remake.

Theatre PAK layout (see docs/FORMATS.md):
  0 TERA IFF header      1/2/3 elevation blocks hi/med/lo (PAK of 18x18 LZW blocks)
  4 overlay meshes (runways, .TRI)   5 object placements (.OBJ)   6 per-block average height

World space: feet. x = east, y = north, z = up, map centred on the origin, 18x18 blocks of
20000 ft, hi-detail vertices every 1000 ft (360x360 grid; row 0 = north edge).

Output (gamedata/terrain/):
  tiles.png                 16x16 atlas of the 255 TXMPACK ground tiles, upscaled, alpha=vertex colour
  <THEATRE>/terrain.bin     grid: heights, palette tones, land types, upper/lower tile ids
  <THEATRE>/objects.json    placed objects (model, destroyed model, position ft, 3x3 basis)
  <THEATRE>/overlays.glb    runway/road overlay meshes, in Godot space (metres)
"""
import json, os, struct, sys
import numpy as np
from PIL import Image
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import iff, lzw, pak, realspace as rs
from upscale import upscale_rgba
from export_glb import GlbBuilder

GRID = 360
BLOCKS = 18
BLOCK_VERTS = 20
SPACING_FT = 1000.0
HALF_FT = BLOCKS * BLOCK_VERTS * SPACING_FT / 2
FT = 0.3048
TILE_PX = 256
NO_TILE = 255


def fixed(b, off):
    return struct.unpack_from('<i', b, off)[0] / 256.0


def ft_to_godot(x, y, z):
    return (x * FT, z * FT, -y * FT)


def load_ranges(palette_iff):
    root = iff.load(palette_iff)[0]
    d = root.first(b'RANG').data
    n = struct.unpack_from('<H', d)[0]
    return [struct.unpack_from('<3H', d, 2 + i * 13) for i in range(n)]


def decode_grid(pak_entry):
    """Hi-detail blocks -> dict of 360x360 arrays."""
    h = np.zeros((GRID, GRID), np.int16)
    light, kind, upper, lower = (np.zeros((GRID, GRID), np.uint8) for _ in range(4))
    for i, (_, blob) in enumerate(pak.read_pak(pak_entry)):
        n = struct.unpack_from('<I', blob)[0]
        raw = np.frombuffer(lzw.decode(blob[4:], n), np.uint8).reshape(BLOCK_VERTS, BLOCK_VERTS, 6)
        by, bx = divmod(i, BLOCKS)
        sl = (slice(by * BLOCK_VERTS, (by + 1) * BLOCK_VERTS), slice(bx * BLOCK_VERTS, (bx + 1) * BLOCK_VERTS))
        h[sl] = raw[..., 0].astype(np.int16) | (raw[..., 1].astype(np.int16) << 8)
        light[sl], kind[sl], upper[sl], lower[sl] = raw[..., 2], raw[..., 3], raw[..., 4], raw[..., 5]
    return h, light, kind, upper, lower


def tones(light, kind, ranges):
    first = np.array([r[0] for r in ranges], np.int32)
    shades = np.array([r[1] for r in ranges], np.int32)
    k = np.clip(kind, 0, len(ranges) - 1)
    return np.clip(first[k] + ((light.astype(np.int32) * shades[k] + 128) >> 8), 0, 255).astype(np.uint8)


def decode_objects(pak_entry):
    out = []
    for blob in (b for _, b in pak.read_pak(pak_entry)):
        if len(blob) < 2:
            continue
        for k in range(struct.unpack_from('<H', blob)[0]):
            r = blob[2 + k * 70:2 + (k + 1) * 70]
            if len(r) < 70:
                break
            out.append({
                'model': r[:8].split(b'\0')[0].decode('latin1'),
                'destroyed': r[13:21].split(b'\0')[0].decode('latin1'),
                'pos_ft': [fixed(r, 22), fixed(r, 26), fixed(r, 30)],
                'basis': [round(fixed(r, 34 + i * 4), 5) for i in range(9)],
            })
    return out


def decode_overlays(pak_entry):
    """Runway/road meshes: header u16 nverts, npolys, gridDim, tableLen; 13-byte verts
    (24.8 x, y, z + u8); 16-byte polys (u8, 3 x u16 idx, u8 kind, u16 tex, 3 x u8 uv)."""
    out = []
    for blob in (b for _, b in pak.read_pak(pak_entry)):
        if len(blob) < 8:
            continue
        nv, npoly, _, _ = struct.unpack_from('<4H', blob)
        verts = [(fixed(blob, 8 + i * 13), fixed(blob, 12 + i * 13), fixed(blob, 16 + i * 13)) for i in range(nv)]
        p = 8 + nv * 13
        polys = []
        for i in range(npoly):
            r = blob[p + i * 16:p + i * 16 + 16]
            idx = struct.unpack_from('<3H', r, 1)
            if max(idx) >= nv:
                continue
            polys.append({'v': idx, 'kind': r[7], 'tex': struct.unpack_from('<H', r, 8)[0],
                          'uv': [(r[10], r[11]), (r[12], r[13]), (r[14], r[15])]})
        out.append((verts, polys))
    return out


def load_tile_images(txmpack):
    imgs = []
    for _, blob in pak.read_pak(open(txmpack, 'rb').read()):
        if len(blob) < 4:
            imgs.append(None); continue
        w, h = struct.unpack_from('<HH', blob)
        imgs.append(np.frombuffer(blob[4:4 + w * h], np.uint8).reshape(h, w) if w * h and 4 + w * h <= len(blob) else None)
    return imgs


def indexed_to_rgba(px, pal):
    P = np.array([c + (255,) for c in pal], np.uint8)
    rgba = P[px]
    rgba[px == rs.TRANSPARENT] = (0, 0, 0, 0)
    return Image.fromarray(rgba, 'RGBA')


SPLIT_GUIDE = (229, 232)  # artists' red/orange diagonal guide line baked into hi-detail tiles


def remove_split_guide(px):
    """Replace guide-line texels (top/bottom rows and main diagonal) with adjacent texels."""
    px = px.copy()
    for row, src in ((0, 1), (px.shape[0] - 1, px.shape[0] - 2)):
        m = np.isin(px[row], SPLIT_GUIDE)
        px[row, m] = px[src, m]
    n = min(px.shape)
    for i in range(n):
        for j in (i - 1, i, i + 1):
            if 0 <= j < px.shape[1] and px[i, j] in SPLIT_GUIDE:
                k = j + 2 if j + 2 < px.shape[1] else j - 2
                px[i, j] = px[i, k]
    return px


def build_tile_atlas(tiles, pal, out_path, factor):
    atlas = Image.new('RGBA', (16 * TILE_PX, 16 * TILE_PX), (0, 0, 0, 0))
    for i, px in enumerate(tiles[:255]):
        if px is None:
            continue
        px = remove_split_guide(px)
        img = upscale_rgba(indexed_to_rgba(px, pal), factor)
        if img.size != (TILE_PX, TILE_PX):
            img = img.resize((TILE_PX, TILE_PX), Image.LANCZOS)
        atlas.paste(img, ((i % 16) * TILE_PX, (i // 16) * TILE_PX))
    atlas.save(out_path, optimize=True)


def build_overlays_glb(overlays, acc_imgs, pal, out_path, factor):
    g = GlbBuilder()
    mats = {}

    def mat_for(tex, kind):
        key = ('t', tex) if tex < len(acc_imgs) and acc_imgs[tex] is not None and kind == 0xFF else ('c', kind)
        if key not in mats:
            if key[0] == 't':
                img = upscale_rgba(indexed_to_rgba(acc_imgs[tex], pal), factor)
                mats[key] = (g.image_material(f'acc{tex}', img, False, True, True), acc_imgs[tex].shape)
            else:
                c = pal[kind] if kind < 256 else (128, 128, 128)
                mats[key] = (g.image_material(f'col{kind}', Image.new('RGBA', (4, 4), c + (255,)), True, False, True), None)
        return key

    groups = {}
    for verts, polys in overlays:
        for p in polys:
            groups.setdefault(mat_for(p['tex'], p['kind']), []).append((verts, p))
    prims = []
    for key, items in groups.items():
        pos, nrm, uv = [], [], []
        shape = mats[key][1]
        for verts, p in items:
            pts = [np.array(ft_to_godot(*verts[i]), np.float32) for i in p['v']]
            pts = [q + np.array([0, 0.05, 0], np.float32) for q in pts]  # sit just above the ground
            pos += pts; nrm += [np.array([0, 1, 0], np.float32)] * 3
            if shape:
                h, w = shape
                uv += [((u + 0.5) / w, (v + 0.5) / h) for u, v in p['uv']]
            else:
                uv += [(0.5, 0.5)] * 3
        prims.append({'attributes': {'POSITION': g.accessor(np.array(pos), 'VEC3', True),
                                     'NORMAL': g.accessor(np.array(nrm), 'VEC3'),
                                     'TEXCOORD_0': g.accessor(np.array(uv), 'VEC2')},
                      'material': mats[key][0]})
    if not prims:
        return False
    g.j['meshes'].append({'name': 'overlays', 'primitives': prims})
    g.j['nodes'].append({'name': 'Overlays', 'mesh': 0})
    g.j['scenes'][0]['nodes'] = [0]
    g.save(out_path)
    return True


def write_grid(path, h, tone, kind, upper, lower):
    with open(path, 'wb') as f:
        f.write(b'SCTR' + struct.pack('<IHHf', 1, GRID, 0, SPACING_FT))
        for a in (h.astype('<i2'), tone, kind, upper, lower):
            f.write(np.ascontiguousarray(a).tobytes())


def convert(extracted, out_root, factor=4, log=print):
    data = os.path.join(extracted, 'BIGTRE', 'DATA')
    pal = rs.load_palette(os.path.join(data, 'PALETTE', 'PALETTE.IFF'))
    ranges = load_ranges(os.path.join(data, 'PALETTE', 'PALETTE.IFF'))
    txm = os.path.join(extracted, 'LILTRE', 'DATA', 'TXM')
    os.makedirs(out_root, exist_ok=True)
    build_tile_atlas(load_tile_images(os.path.join(txm, 'TXMPACK.PAK')), pal, os.path.join(out_root, 'tiles.png'), factor)
    acc = load_tile_images(os.path.join(txm, 'ACCPACK.PAK'))
    pal_img = Image.new('RGB', (16, 16)); pal_img.putdata(pal); pal_img.save(os.path.join(out_root, 'palette.png'))
    theatres = []
    cd = os.path.join(extracted, 'cd')
    for fn in sorted(os.listdir(cd)):
        if not fn.upper().endswith('.PAK'):
            continue
        name = fn[:-4].upper()
        entries = pak.read_pak(open(os.path.join(cd, fn), 'rb').read())
        if len(entries) != 7 or entries[0][1][8:12] != b'TERA':
            continue
        out = os.path.join(out_root, name)
        os.makedirs(out, exist_ok=True)
        h, light, kind, upper, lower = decode_grid(entries[1][1])
        write_grid(os.path.join(out, 'terrain.bin'), h, tones(light, kind, ranges), kind, upper, lower)
        objs = decode_objects(entries[5][1])
        with open(os.path.join(out, 'objects.json'), 'w') as f:
            json.dump(objs, f, indent=0)
        has_overlays = build_overlays_glb(decode_overlays(entries[4][1]), acc, pal, os.path.join(out, 'overlays.glb'), factor)
        theatres.append({'name': name, 'objects': len(objs), 'overlays': has_overlays,
                         'min_ft': int(h.min()), 'max_ft': int(h.max())})
        log(f'  terrain {name}: {int(h.min())}..{int(h.max())} ft, {len(objs)} objects')
    with open(os.path.join(out_root, 'theatres.json'), 'w') as f:
        json.dump(theatres, f, indent=1)
    return theatres


if __name__ == '__main__':
    convert(sys.argv[1], sys.argv[2])
