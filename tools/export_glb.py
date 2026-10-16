"""Export RealSpace object IFFs to glTF binary (.glb) for Godot.

Each LOD becomes a separate node "LOD<n>" whose extras carry the original switch distance.
Flat-coloured faces sample a 16x16 palette texture; textured faces get one material per texture.

usage: export_glb.py PALETTE.IFF OUT_DIR OBJECT.IFF [...]   (--upscale N, default 4)
"""
import io, json, os, struct, sys
import numpy as np
from PIL import Image
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import realspace as rs
from upscale import upscale_rgba
import overlap

DECAL_OFFSET = 0.002  # metres: lifts same-facing coplanar duplicates above the face they cover


def png_bytes(img):
    b = io.BytesIO(); img.save(b, 'PNG', optimize=True); return b.getvalue()


def palette_image(pal):
    img = Image.new('RGBA', (16, 16))
    img.putdata([pal[i] + (255,) for i in range(256)])
    return img


class GlbBuilder:
    def __init__(self):
        self.bin = bytearray()
        self.j = {'asset': {'version': '2.0', 'generator': 'sc-remake realspace exporter'},
                  'scene': 0, 'scenes': [{'nodes': []}], 'nodes': [], 'meshes': [], 'materials': [],
                  'textures': [], 'images': [], 'samplers': [], 'accessors': [], 'bufferViews': [],
                  'buffers': [{'byteLength': 0}]}

    def _view(self, data, target=None):
        while len(self.bin) % 4: self.bin.append(0)
        v = {'buffer': 0, 'byteOffset': len(self.bin), 'byteLength': len(data)}
        if target: v['target'] = target
        self.bin += data
        self.j['bufferViews'].append(v)
        return len(self.j['bufferViews']) - 1

    def accessor(self, arr, typ, minmax=False):
        arr = np.ascontiguousarray(arr, dtype=np.float32)
        view = self._view(arr.tobytes(), 34962)
        a = {'bufferView': view, 'componentType': 5126, 'count': int(arr.shape[0]), 'type': typ}
        if minmax:
            a['min'] = arr.min(0).tolist(); a['max'] = arr.max(0).tolist()
        self.j['accessors'].append(a)
        return len(self.j['accessors']) - 1

    def image_material(self, name, img, nearest, alpha, double_sided=True):
        if not hasattr(self, '_images'): self._images = {}
        key = id(img)
        if key not in self._images:
            view = self._view(png_bytes(img))
            self.j['images'].append({'bufferView': view, 'mimeType': 'image/png', 'name': name})
            self._images[key] = len(self.j['images']) - 1
        filt = 9728 if nearest else 9729
        self.j['samplers'].append({'magFilter': filt, 'minFilter': 9728 if nearest else 9987})
        self.j['textures'].append({'source': self._images[key], 'sampler': len(self.j['samplers']) - 1})
        m = {'name': name, 'pbrMetallicRoughness': {
            'baseColorTexture': {'index': len(self.j['textures']) - 1},
            'metallicFactor': 0.0, 'roughnessFactor': 0.85}, 'doubleSided': double_sided}
        if alpha:
            m['alphaMode'] = 'MASK'; m['alphaCutoff'] = 0.5; m['doubleSided'] = True
        self.j['materials'].append(m)
        return len(self.j['materials']) - 1

    def save(self, path):
        for k in [k for k, v in self.j.items() if v == []]:
            del self.j[k]
        while len(self.bin) % 4: self.bin.append(0)
        self.j['buffers'][0]['byteLength'] = len(self.bin)
        js = json.dumps(self.j, separators=(',', ':')).encode()
        js += b' ' * (-len(js) % 4)
        with open(path, 'wb') as f:
            f.write(struct.pack('<III', 0x46546C67, 2, 12 + 8 + len(js) + 8 + len(self.bin)))
            f.write(struct.pack('<II', len(js), 0x4E4F534A)); f.write(js)
            f.write(struct.pack('<II', len(self.bin), 0x004E4942)); f.write(self.bin)


def export(obj_path, pal, out_dir, factor=4):
    obj = rs.RealObject(obj_path)
    if not obj.meshes:
        return None
    name = os.path.splitext(os.path.basename(obj_path))[0]
    g = GlbBuilder()
    pal_img = palette_image(pal)
    pal_mats = {True: g.image_material('palette', pal_img, True, False, True),
                False: g.image_material('palette_1sided', pal_img, True, False, False)}
    mesh = obj.meshes.get('POLY') or next(iter(obj.meshes.values()))
    # Transparent texels (index 255) let the triangle's own flat colour show through, so each
    # (texture, colour) pair that is actually used gets its own baked, upscaled, opaque image.
    tex_mats, tex_imgs = {}, {}

    def material_for(tri):
        tex = mesh.textures[tri.tex] if tri.tex is not None and tri.tex < len(mesh.textures) else None
        if tex is None or tex.w == 0 or tex.h == 0:
            return None
        has_alpha = rs.TRANSPARENT in tex.pixels
        key = (tri.tex, tri.color if has_alpha else -1)
        if key not in tex_imgs:
            under = pal[tri.color] if has_alpha else (0, 0, 0)
            img = Image.frombytes('RGBA', (tex.w, tex.h), tex.to_rgba(pal))
            base = Image.new('RGBA', img.size, under + (255,))
            base.alpha_composite(img)
            label = (tex.name or f'tex{tri.tex}') + (f'_c{tri.color}' if has_alpha else '')
            tex_imgs[key] = (label, upscale_rgba(base, factor), tex)
        return key

    def tex_material(key, double_sided):
        mk = (key, double_sided)
        if mk not in tex_mats:
            label, img, tex = tex_imgs[key]
            tex_mats[mk] = (g.image_material(label + ('' if double_sided else '_1s'), img, False, False, double_sided), tex)
        return tex_mats[mk]

    verts = np.array([rs.sc_to_godot(v) for v in mesh.verts], np.float32)
    root_children = []
    for li, (dist, tri_ids) in enumerate(mesh.lods):
        # Coplanar overlaps: opposite-facing pairs are top/bottom skins (the original engine
        # back-face culled them) -> single-sided. Same-facing pairs are decals -> lift the winner.
        valid = [t for t in tri_ids if t < len(mesh.tris) and all(i < len(verts) for i in mesh.tris[t].v)]
        single_sided, lifted = set(), set()
        for a, b, same in overlap.find_overlaps(np.array(mesh.verts, float), mesh.tris, valid):
            if same:
                ta, tb = mesh.tris[a], mesh.tris[b]
                lifted.add(a if (ta.tex is not None and tb.tex is None) else b)
            else:
                single_sided.update((a, b))
        groups = {}
        for tid in tri_ids:
            if tid >= len(mesh.tris):
                continue
            tri = mesh.tris[tid]
            if any(i >= len(verts) for i in tri.v):
                continue
            key = (material_for(tri), tid not in single_sided)
            groups.setdefault(key, []).append((tid, tri))
        prims = []
        for (key, double_sided), tris in groups.items():
            pos, nrm, uv = [], [], []
            for tid, tri in tris:
                order = (0, 2, 1)  # CW (SC) -> CCW (glTF)
                p = [verts[tri.v[k]] for k in order]
                n = np.cross(p[1] - p[0], p[2] - p[0]); ln = np.linalg.norm(n)
                n = n / ln if ln > 1e-9 else np.array([0, 1, 0], np.float32)
                if tid in lifted:
                    p = [q + n * DECAL_OFFSET for q in p]
                pos += p; nrm += [n] * 3
                if key is None:
                    c = tri.color
                    uv += [((c % 16 + 0.5) / 16, (c // 16 + 0.5) / 16)] * 3
                else:
                    t = tex_imgs[key][2]
                    uv += [((tri.uv[k][0] + 0.5) / t.w, (tri.uv[k][1] + 0.5) / t.h) for k in order]
            attrs = {'POSITION': g.accessor(np.array(pos), 'VEC3', True),
                     'NORMAL': g.accessor(np.array(nrm), 'VEC3'),
                     'TEXCOORD_0': g.accessor(np.array(uv), 'VEC2')}
            mat = pal_mats[double_sided] if key is None else tex_material(key, double_sided)[0]
            prims.append({'attributes': attrs, 'material': mat})
        if not prims:
            continue
        g.j['meshes'].append({'name': f'{name}_LOD{li}', 'primitives': prims})
        g.j['nodes'].append({'name': f'LOD{li}', 'mesh': len(g.j['meshes']) - 1,
                             'extras': {'lod_distance': dist}})
        root_children.append(len(g.j['nodes']) - 1)
    g.j['nodes'].append({'name': name, 'children': root_children})
    g.j['scenes'][0]['nodes'] = [len(g.j['nodes']) - 1]
    os.makedirs(out_dir, exist_ok=True)
    out = os.path.join(out_dir, name + '.glb')
    g.save(out)
    return out


if __name__ == '__main__':
    args = sys.argv[1:]
    factor = 4
    if '--upscale' in args:
        i = args.index('--upscale'); factor = int(args[i + 1]); del args[i:i + 2]
    pal = rs.load_palette(args[0])
    for p in args[2:]:
        try:
            r = export(p, pal, args[1], factor)
            print('ok ' if r else 'skip', p)
        except Exception as e:
            print('ERR', p, repr(e))
