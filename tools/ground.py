"""Ground objects -> gamedata/units/<NAME>.json.

Covers OBJT forms GRND (vehicles), SWPN (SAM/AAA sites, ships), ORNT (buildings, scenery) and
XMIT (radio sites such as STRIBASE): hit points, destroyed-state models, explosion, and for
SWPN the weapon system (`DATA`: u32 ammo, u32 range ft, u32 min range ft, …, char weapon[8] at 21).
"""
import json, os, struct, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import iff

KINDS = (b'GRND', b'SWPN', b'ORNT', b'XMIT')


def cstr(b):
    return b.split(b'\0')[0].decode('latin1')


def parse_unit(name, form):
    out = {'name': name, 'kind': form.name.lower(), 'hit_points': 20, 'destroyed': [], 'explosion': None}
    g = form.first
    if g(b'DAMG'):
        out['hit_points'] = struct.unpack_from('<H', g(b'DAMG').data)[0]
    if g(b'DEST'):
        d = g(b'DEST').data
        out['destroyed'] = [cstr(d[k:k + 8]).upper() for k in range(0, len(d) - 7, 14) if cstr(d[k:k + 8])]
    if g(b'EXPL'):
        d = g(b'EXPL').data
        out['explosion'] = {'sprite': cstr(d[:8]), 'radius_ft': struct.unpack_from('<H', d, 8)[0],
                            'damage': struct.unpack_from('<H', d, 10)[0]}
    if g(b'DATA') and form.name == 'SWPN':
        d = g(b'DATA').data
        ammo, rng, min_rng = struct.unpack_from('<3I', d, 0)
        out['weapon'] = {'name': cstr(d[21:29]).upper(), 'ammo': ammo, 'range_ft': rng, 'min_range_ft': min_rng,
                         'rate': d[12], 'raw': list(d)}
    return out


def convert(objects_dir, out_root, log=print):
    out_dir = os.path.join(out_root, 'units')
    os.makedirs(out_dir, exist_ok=True)
    n = 0
    for fn in sorted(os.listdir(objects_dir)):
        root = iff.load(os.path.join(objects_dir, fn))[0]
        objt = root.first(b'OBJT')
        for c in (objt.children if objt else []):
            if c.kind in KINDS:
                with open(os.path.join(out_dir, fn[:-4].upper() + '.json'), 'w') as f:
                    json.dump(parse_unit(fn[:-4].upper(), c), f, indent=1)
                n += 1
    log(f'  {n} ground units / structures')


if __name__ == '__main__':
    convert(sys.argv[1], sys.argv[2])
