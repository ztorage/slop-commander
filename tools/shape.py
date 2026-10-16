"""Origin RLE shapes (.SHP / cockpit art) and the containers they come in.

Shape: i16 right, left, top, bottom (extents around a hotspot; width = left + right + 1,
height = top + bottom + 1), then fragments until a u16 0:
  u16 code, i16 dx, i16 dy  (position relative to the hotspot)
  code & 1 == 0: (code >> 1) raw palette bytes
  code & 1 == 1: (code >> 1) texels made of sub-runs: u8 sub; sub & 1 == 0 -> (sub >> 1) raw
                 bytes follow, sub & 1 == 1 -> one byte repeated (sub >> 1) times
Unwritten texels are transparent (255).

Wrappers: "LZ" + u32 size + LZW stream; PAK entries flagged 0x20 are u32 size + LZW.
"""
import struct
import numpy as np
import lzw, pak

TRANSPARENT = 255


def unwrap(blob):
    """Strip "LZ" compression if present."""
    if blob[:2] == b'LZ':
        n = struct.unpack_from('<I', blob, 2)[0]
        return lzw.decode(blob[6:], n)
    return blob


def pak_entries(blob):
    """Entries of a PAK, decompressing those flagged 0x20."""
    out = []
    for flag, data in pak.read_pak(blob):
        if flag == 0x20 and len(data) >= 4:
            n = struct.unpack_from('<I', data)[0]
            data = lzw.decode(data[4:], n)
        out.append(data)
    return out


class Shape:
    def __init__(self, w, h, ox, oy, pixels):
        self.w, self.h, self.ox, self.oy, self.pixels = w, h, ox, oy, pixels  # (ox, oy) = hotspot


def decode_shape(data):
    if len(data) < 8:
        return None
    right, left, top, bottom = struct.unpack_from('<4h', data)
    w, h = left + right + 1, top + bottom + 1
    if not (0 < w <= 1024 and 0 < h <= 1024):
        return None
    px = np.full((h, w), TRANSPARENT, np.uint8)
    p = 8
    try:
        while p + 2 <= len(data):
            code = struct.unpack_from('<H', data, p)[0]
            p += 2
            if code == 0:
                break
            dx, dy = struct.unpack_from('<hh', data, p)
            p += 4
            x, y, n = left + dx, top + dy, code >> 1
            row = []
            if code & 1 == 0:
                row = list(data[p:p + n]); p += n
            else:
                while len(row) < n:
                    sub = data[p]; p += 1
                    cnt = sub >> 1
                    if sub & 1 == 0:
                        row += list(data[p:p + cnt]); p += cnt
                    else:
                        row += [data[p]] * cnt; p += 1
            if 0 <= y < h:
                x0, x1 = max(x, 0), min(x + len(row), w)
                if x1 > x0:
                    px[y, x0:x1] = row[x0 - x:x1 - x]
    except (IndexError, struct.error):
        return None
    return Shape(w, h, left, top, px)


def is_shape_set(data):
    """A shape set is a PAK of shapes: u32 size then 0xE0-flagged offsets."""
    if len(data) < 8:
        return False
    total, first = struct.unpack_from('<II', data)
    return abs(total - len(data)) <= 4 and (first >> 24) in (0xE0, 0x20, 0x00) and 8 <= (first & 0xFFFFFF) < len(data)


def decode_any(blob):
    """Return a flat list of Shapes from a shape, shape set, or LZ-wrapped either."""
    data = unwrap(blob)
    if is_shape_set(data):
        out = []
        for e in pak_entries(data):
            out += decode_any(e) if is_shape_set(e) else [s for s in [decode_shape(e)] if s]
        return out
    s = decode_shape(data)
    return [s] if s else []
