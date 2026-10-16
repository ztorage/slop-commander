"""Read files from a Strike Commander CD in any common dump form, without mounting it.

Supported sources:
  * .cue sheet (points at a .bin/.img data track)
  * raw MODE1/2352 track (.bin / .img), detected by the CD sync pattern
  * cooked 2048-byte ISO9660 image (.iso)
  * a directory: a mounted CD, or a copy of the CD's files
"""
import os, re, struct

SYNC = bytes.fromhex('00ffffffffffffffffffff00')


class SectorImage:
    def __init__(self, path):
        self.f = open(path, 'rb')
        head = self.f.read(16)
        if head[:12] == SYNC:
            self.raw, self.offset = 2352, 16  # MODE1/2352: skip sync + header
        else:
            self.raw, self.offset = 2048, 0

    def read(self, lba, count=1):
        out = bytearray()
        for i in range(count):
            self.f.seek((lba + i) * self.raw + self.offset)
            out += self.f.read(2048)
        return bytes(out)


class Iso9660:
    def __init__(self, img):
        self.img = img
        pvd = img.read(16)
        if pvd[1:6] != b'CD001':
            raise ValueError('not an ISO9660 data track')
        self.root = self._record(pvd[156:190])

    @staticmethod
    def _record(r):
        lba = struct.unpack_from('<I', r, 2)[0]
        size = struct.unpack_from('<I', r, 10)[0]
        flags = r[25]
        nlen = r[32]
        name = r[33:33 + nlen].decode('latin1').split(';')[0].rstrip('.')
        return {'lba': lba, 'size': size, 'dir': bool(flags & 2), 'name': name}

    def listdir(self, rec):
        data = self.img.read(rec['lba'], (rec['size'] + 2047) // 2048)
        out, pos = [], 0
        while pos < rec['size']:
            ln = data[pos]
            if ln == 0:  # records never straddle sectors; skip to next sector
                pos = (pos // 2048 + 1) * 2048
                continue
            r = self._record(data[pos:pos + ln])
            if r['name'] not in ('', '\x00', '\x01'):
                out.append(r)
            pos += ln
        return out

    def walk(self, rec=None, prefix=''):
        for r in self.listdir(rec or self.root):
            path = prefix + r['name']
            if r['dir']:
                yield from self.walk(r, path + '/')
            else:
                yield path, r

    def read_file(self, rec):
        return self.img.read(rec['lba'], (rec['size'] + 2047) // 2048)[:rec['size']]


def _track_from_cue(cue):
    text = open(cue, encoding='latin1').read()
    m = re.search(r'FILE\s+"([^"]+)"', text)
    if not m:
        raise ValueError('no FILE entry in cue sheet')
    return os.path.join(os.path.dirname(cue), m.group(1))


class Disc:
    """Uniform `files()` / `read(name)` access, names upper-case with '/' separators."""

    def __init__(self, source):
        self.source = source
        if os.path.isdir(source):
            self._files = {}
            for root, _, names in os.walk(source):
                for n in names:
                    full = os.path.join(root, n)
                    self._files[os.path.relpath(full, source).replace(os.sep, '/').upper()] = full
            self._iso = None
        else:
            path = _track_from_cue(source) if source.lower().endswith('.cue') else source
            self._iso = Iso9660(SectorImage(path))
            self._files = {p.upper(): r for p, r in self._iso.walk()}

    def files(self):
        return sorted(self._files)

    def size(self, name):
        v = self._files[name.upper()]
        return os.path.getsize(v) if self._iso is None else v['size']

    def read(self, name):
        v = self._files[name.upper()]
        if self._iso is None:
            with open(v, 'rb') as f:
                return f.read()
        return self._iso.read_file(v)
