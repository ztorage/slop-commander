"""Decoders for Origin Systems' RealSpace engine assets (Strike Commander, 1993).

Coordinate system (reverse engineered):
  object space: x = right, y = forward, z = up, ~157.5 units per foot (~516.7/m)
  triangles are wound clockwise when seen from the outside.
Godot space: x = right, y = up, -z = forward (metres).
"""
import struct
import iff, lzw

UNITS_PER_METRE = 516.7
TRANSPARENT = 255


# ---------------------------------------------------------------- palette
def load_palette(path, chunk=b'PALT'):
    """Return 256 (r, g, b) 8-bit tuples from a PALETTE.IFF style file."""
    root = iff.load(path)[0]
    d = root.first(chunk).data[4:]
    return [tuple(min(255, c * 255 // 63) for c in d[i * 3:i * 3 + 3]) for i in range(256)]


# ---------------------------------------------------------------- textures
class Texture:
    def __init__(self, name, w, h, pixels):
        self.name, self.w, self.h, self.pixels = name, w, h, pixels

    def to_rgba(self, pal):
        out = bytearray(self.w * self.h * 4)
        for i, p in enumerate(self.pixels):
            if p == TRANSPARENT:
                out[i * 4:i * 4 + 4] = b'\0\0\0\0'
            else:
                r, g, b = pal[p]
                out[i * 4:i * 4 + 4] = bytes((r, g, b, 255))
        return bytes(out)


def decode_txmp(data):
    name = data[:8].split(b'\0')[0].decode('latin1')
    w, h = struct.unpack_from('<HH', data, 8)
    if data[12:14] == b'LZ':
        px = lzw.decode(data[14:], w * h)
    else:
        px = data[12:12 + w * h]
    px = px.ljust(w * h, b'\0')
    return Texture(name, w, h, px)


# ---------------------------------------------------------------- 3D objects
class Triangle:
    __slots__ = ('kind', 'v', 'color', 'flags', 'extra', 'tex', 'uv')

    def __init__(self, rec):
        self.kind = rec[0]
        self.v = (rec[1], rec[2], rec[3])
        self.color = rec[4]
        self.flags = rec[6]
        self.extra = rec[7]
        self.tex = None
        self.uv = None


class Mesh:
    """One POLY/AFTB appearance: shared vertices, triangles, LOD triangle lists, textures."""

    def __init__(self, form):
        v = form.first(b'VERT').data
        self.verts = [struct.unpack_from('<3i', v, i * 12) for i in range(len(v) // 12)]
        tris = form.first(b'TRIS')
        t = tris.first(b'VTRI').data
        self.tris = [Triangle(t[i * 8:i * 8 + 8]) for i in range(len(t) // 8)]
        self.textures = []
        txms = tris.first(b'TXMS') or form.first(b'TXMS')
        if txms:
            for c in txms.children:
                if c.id == b'TXMP':
                    self.textures.append(decode_txmp(c.data))
                elif c.id == b'TXMA':
                    self.textures.append(None)  # animated texture: TODO
        uv = tris.first(b'UVXY')
        if uv:
            u = uv.data
            for i in range(len(u) // 8):
                tid, tex, *coords = u[i * 8:i * 8 + 8]
                if tid < len(self.tris):
                    self.tris[tid].tex = tex
                    self.tris[tid].uv = [(coords[0], coords[1]), (coords[2], coords[3]), (coords[4], coords[5])]
        self.lods = []
        deta = form.first(b'DETA')
        if deta:
            for lvl in deta.children:
                dist = struct.unpack_from('<I', lvl.data)[0]
                n = (len(lvl.data) - 4) // 2
                self.lods.append((dist, list(struct.unpack_from('<%dH' % n, lvl.data, 4))))
        if not self.lods:
            self.lods = [(0, list(range(len(self.tris))))]


class RealObject:
    def __init__(self, path):
        root = iff.load(path)[0]
        self.root = root
        self.name = None
        self.meshes = {}
        appr = root.first(b'APPR')
        if appr:
            for kind in (b'POLY', b'AFTB'):
                f = appr.first(kind)
                if f and f.first(b'VERT'):
                    self.meshes[kind.decode()] = Mesh(f)
        self.objt = root.first(b'OBJT')


def sc_to_godot(p):
    x, y, z = p
    s = 1.0 / UNITS_PER_METRE
    return (x * s, z * s, -y * s)
