"""Origin Systems RealSpace .TRE archives (Strike Commander 1993).

Little-endian: u32 count, u32 dataStart, then count x 74-byte entries:
u8 flag, char path[65] (DOS path, NUL-terminated), u32 offset, u32 size.
"""
import os, struct, sys


def read_tre(path):
    with open(path, 'rb') as f:
        data = f.read()
    count, _ = struct.unpack_from('<II', data, 0)
    entries = []
    for i in range(count):
        off = 8 + i * 74
        name = data[off + 1:off + 66].split(b'\0')[0].decode('ascii')
        foff, fsize = struct.unpack_from('<II', data, off + 66)
        entries.append((name, foff, fsize))
    return data, entries


def write_entries(data, entries, out):
    for name, foff, fsize in entries:
        rel = name.replace('..\\', '').replace('\\', '/').replace(':', '_')
        dst = os.path.join(out, rel)
        os.makedirs(os.path.dirname(dst) or out, exist_ok=True)
        with open(dst, 'wb') as o:
            o.write(data[foff:foff + fsize])


if __name__ == '__main__':
    data, entries = read_tre(sys.argv[1])
    write_entries(data, entries, sys.argv[2])
    print(f'{sys.argv[1]}: {len(entries)} files')
