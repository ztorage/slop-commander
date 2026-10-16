"""Origin/EA IFF (big-endian, FORM/CAT/LIST containers) parser + tree dumper."""
import struct, sys

CONTAINERS = (b'FORM', b'CAT ', b'LIST')

class Chunk:
    def __init__(self, cid, data, kind=None, children=None):
        self.id, self.data, self.kind, self.children = cid, data, kind, children or []
    def find(self, cid):
        return [c for c in self.children if (c.kind or c.id) == cid or c.id == cid]
    def first(self, cid):
        r = self.find(cid); return r[0] if r else None
    @property
    def name(self):
        return (self.kind or self.id).decode('latin1')

def parse(buf, off=0, end=None):
    end = len(buf) if end is None else end
    out = []
    while off + 8 <= end:
        cid = buf[off:off+4]
        size = struct.unpack_from('>I', buf, off+4)[0]
        body = buf[off+8:off+8+size]
        if cid in CONTAINERS:
            out.append(Chunk(cid, body, body[:4], parse(buf, off+12, off+8+size)))
        else:
            out.append(Chunk(cid, body))
        off += 8 + size + (size & 1)
    return out

def load(path):
    with open(path, 'rb') as f:
        return parse(f.read())

def dump(chunks, depth=0, maxdata=24):
    for c in chunks:
        if c.kind:
            print('  '*depth + f'{c.id.decode()} {c.name} ({len(c.data)})')
            dump(c.children, depth+1, maxdata)
        else:
            print('  '*depth + f'{c.name} ({len(c.data)}) {c.data[:maxdata].hex(" ")}')

if __name__ == '__main__':
    dump(load(sys.argv[1]), maxdata=int(sys.argv[2]) if len(sys.argv) > 2 else 24)
