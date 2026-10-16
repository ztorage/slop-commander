"""RealSpace .PAK containers: u32 total size, then u32 entries (24-bit offset | flag<<24) up to
the first entry's offset. Flag 0xE0 = normal entry; other flag values are noted but kept."""
import struct, sys


def read_pak(data):
    total = struct.unpack_from('<I', data, 0)[0]
    entries, pos, first = [], 4, None
    while first is None or pos < first:
        v = struct.unpack_from('<I', data, pos)[0]
        off, flag = v & 0xFFFFFF, v >> 24
        if first is None:
            first = off
        entries.append((off, flag))
        pos += 4
    ends = [o for o, _ in entries[1:]] + [min(total, len(data))]
    return [(flag, data[off:max(off, end)]) for (off, flag), end in zip(entries, ends)]

if __name__ == '__main__':
    d = open(sys.argv[1], 'rb').read()
    for i, (flag, blob) in enumerate(read_pak(d)):
        print(i, hex(flag), len(blob), blob[:16].hex(' '), blob[:12])
