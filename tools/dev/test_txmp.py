import sys, os, struct
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
import iff, lzw
def walk(cs):
    for c in cs:
        if c.id == b'TXMP' or c.id == b'TXMA':
            yield c
        yield from walk(c.children)
ok = bad = 0
for fn in sorted(os.listdir(sys.argv[1])):
    for c in walk(iff.load(os.path.join(sys.argv[1], fn))):
        d = c.data
        name = d[:8].split(b'\0')[0].decode('latin1'); w, h = struct.unpack_from('<HH', d, 8)
        tag = d[12:14]
        if tag == b'LZ':
            px = lzw.decode(d[14:], w*h)
            if len(px) == w*h: ok += 1
            else: bad += 1; print('BAD', fn, name, w, h, len(px), len(d))
        else:
            print('RAW?', fn, c.id, name, w, h, tag, len(d), len(d)-12-w*h)
print('ok', ok, 'bad', bad)
