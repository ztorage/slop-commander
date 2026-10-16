"""Missions, pilot profiles, loadouts and world descriptors -> gamedata JSON.

missions/<NAME>.json   FORM MISN: theatre, areas, spots, messages, flags, cast, programs, parts,
                       teams, scenes (layouts in docs/FORMATS.md)
profiles/<NAME>.json   FORM PROF (INTEL/*.IFF): name, callsign, voice, radio lines, skills
loadouts/<NAME>.json   FORM WEAP (OBJECTS/*LOAD*.IFF): weapon counts, decoys
worlds/<NAME>.json     FORM WRLD (MISSIONS/*.IFF): terrain PAK name, palette, sky, light
Coordinates are converted to feet (x east, y north, z up) like the terrain data.
"""
import json, os, struct, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import iff


def cstr(b):
    return b.split(b'\0')[0].decode('latin1')


def i24(b, o):
    """Signed 24-bit little-endian integer (stored in a 4-byte slot), feet."""
    v = b[o] | (b[o + 1] << 8) | (b[o + 2] << 16)
    return v - (1 << 24) if v & 0x800000 else v


def parse_areas(d):
    out, p, n = [], 0, 0
    while p < len(d):
        kind = chr(d[p]); p += 1
        if kind not in 'SCB':
            break
        n += 1
        # kind, name[33], x/y/z int24 in 4-byte slots, width; S = 49 bytes, C = 53, B = 65
        a = {'id': n, 'type': kind, 'name': cstr(d[p:p + 33]).upper(),
             'pos_ft': [i24(d, p + 33), i24(d, p + 37), i24(d, p + 41)],
             'width_ft': struct.unpack_from('<H', d, p + 45)[0]}
        if kind == 'S':
            a['height_ft'] = a['width_ft']; p += 48
        elif kind == 'C':
            a['height_ft'] = struct.unpack_from('<H', d, p + 49)[0]; p += 52
        else:
            a['height_ft'] = struct.unpack_from('<H', d, p + 57)[0]; p += 64
        out.append(a)
    return out


def parse_spots(d):
    out = []
    for i in range(len(d) // 14):
        r = d[i * 14:i * 14 + 14]
        out.append({'id': i, 'area': struct.unpack_from('<h', r)[0],
                    'pos_ft': [i24(r, 3), i24(r, 7), struct.unpack_from('<h', r, 11)[0]]})
    return out


def parse_progs(d):
    progs, cur = [], []
    for i in range(0, len(d) - 1, 2):
        op, arg = d[i], d[i + 1]
        if op == 0 and arg == 0:
            progs.append(cur); cur = []
        else:
            cur.append([op, arg])
    if cur:
        progs.append(cur)
    return progs


def parse_parts(d, cast):
    out = []
    for i in range(len(d) // 62):
        r = d[i * 62:(i + 1) * 62]
        pid = struct.unpack_from('<H', r)[0]
        extra = list(r[43:54])
        progs = [r[54 + k * 2] for k in range(4)]
        out.append({
            'id': pid, 'actor': cast[pid] if pid < len(cast) else '',
            'model': cstr(r[2:10]).upper(), 'destroyed': cstr(r[10:18]).upper(), 'loadout': cstr(r[18:26]).upper(),
            'area': r[26], 'flags': r[27], 'relative': struct.unpack_from('<H', r, 28)[0],
            'pos_ft': [i24(r, 30), i24(r, 34), struct.unpack_from('<h', r, 38)[0]],
            'heading': struct.unpack_from('<H', r, 41)[0], 'extra': extra,
            'team': extra[2], 'leader': extra[3],
            'formation_ft': list(struct.unpack_from('<3h', bytes(extra[5:11]))),
            'prog_activated': progs[0], 'prog_update': progs[1], 'prog_destroyed': progs[2], 'prog_init': progs[3],
        })
    return out


def parse_scene(d):
    s = {'active': d[0], 'area': struct.unpack_from('<h', d, 1)[0],
         'prog_activated': struct.unpack_from('<h', d, 3)[0], 'prog_leaving': struct.unpack_from('<h', d, 5)[0],
         'prog_update': struct.unpack_from('<h', d, 7)[0], 'coord_on_area': d[9], 'cast': []}
    for p in range(24, len(d) - 1, 2):
        s['cast'].append(d[p])
    return s


def parse_mission(path):
    root = iff.load(path)[0]
    g = lambda t: root.first(t)
    cast = [cstr(g(b'CAST').data[k:k + 8]).upper() for k in range(0, len(g(b'CAST').data) - 8, 9)] if g(b'CAST') else []
    msgs = [m.decode('latin1') for m in g(b'MSGS').data.split(b'\0')[:-1]] if g(b'MSGS') else []
    flags = list(g(b'FLAG').data[1::2]) if g(b'FLAG') else []
    wrld = root.first(b'WRLD')
    m = {
        'name': os.path.splitext(os.path.basename(path))[0],
        'version': struct.unpack_from('>H', g(b'VERS').data)[0] if g(b'VERS') else 0,
        'info': cstr(g(b'INFO').data) if g(b'INFO') else '',
        'title': cstr(g(b'NAME').data) if g(b'NAME') else '',
        'tune': g(b'TUNE').data[0] if g(b'TUNE') else 0,
        'world': cstr(wrld.first(b'FILE').data).upper() if wrld and wrld.first(b'FILE') else '',
        'areas': parse_areas(g(b'AREA').data) if g(b'AREA') else [],
        'spots': parse_spots(g(b'SPOT').data) if g(b'SPOT') else [],
        'messages': msgs, 'flags': flags, 'cast': cast,
        'nums': list(g(b'NUMS').data) if g(b'NUMS') else [],
        'progs': parse_progs(g(b'PROG').data) if g(b'PROG') else [],
        'parts': parse_parts(g(b'PART').data, cast) if g(b'PART') else [],
        'teams': list(struct.unpack_from('<%dh' % (len(g(b'TEAM').data) // 2), g(b'TEAM').data)) if g(b'TEAM') else [],
        'scenes': [parse_scene(c.data) for c in (root.first(b'PLAY').children if root.first(b'PLAY') else []) if c.id == b'SCNE'],
    }
    return m


def parse_profile(path):
    root = iff.load(path)[0]
    out = {'name': os.path.splitext(os.path.basename(path))[0]}
    radi = root.first(b'RADI')
    if radi:
        if radi.first(b'INFO'):
            d = radi.first(b'INFO').data
            parts = d[2:].split(b'\0')
            out.update(id=struct.unpack_from('<H', d)[0], full_name=parts[0].decode('latin1'),
                       callsign=parts[1].decode('latin1') if len(parts) > 1 else '')
        if radi.first(b'SPCH'):
            out['voice'] = radi.first(b'SPCH').data[0]
        msgs = {}
        if radi.first(b'MSGS'):
            d = radi.first(b'MSGS').data
            p = 0
            while p < len(d):
                k = d[p]; e = d.index(b'\0', p + 1) if b'\0' in d[p + 1:] else len(d)
                msgs[k] = d[p + 1:e].decode('latin1'); p = e + 1
        out['messages'] = msgs
    ai = root.first(b'_AI_')
    if ai:
        a = ai.first(b'ATRB')
        if a:
            keys = ['trigger_happy', 'confidence', 'verbosity', 'loyalty', 'flying', 'air_to_ground', 'air_to_air', 'showmanship', 'aggressiveness']
            out['skills'] = dict(zip(keys, a.data))
        if ai.first(b'GOAL'):
            out['goals'] = list(ai.first(b'GOAL').data)
    return out


def parse_loadout(path):
    root = iff.load(path)[0]
    out = {'name': os.path.splitext(os.path.basename(path))[0], 'stations': []}
    w = root.first(b'WPNS')
    if w:
        d = w.data
        for k in range(0, len(d) - 9, 10):
            out['stations'].append({'count': struct.unpack_from('<H', d, k)[0], 'weapon': cstr(d[k + 2:k + 10]).upper()})
    if root.first(b'DCOY'):
        out['chaff'], out['flares'] = struct.unpack_from('<2H', root.first(b'DCOY').data)
    return out


def parse_world(path):
    root = iff.load(path)[0]
    g = lambda t: root.first(t)
    out = {'name': os.path.splitext(os.path.basename(path))[0]}
    if g(b'TERA'): out['terrain'] = cstr(g(b'TERA').data).upper()
    if g(b'PALT'): out['palette'] = cstr(g(b'PALT').data).upper()
    if g(b'SKYS'): out['sky'] = cstr(g(b'SKYS').data[:8]).upper()
    if g(b'LGHT'): out['light'] = list(struct.unpack_from('<7h', g(b'LGHT').data))
    return out


def form_of(path):
    with open(path, 'rb') as f:
        h = f.read(12)
    return h[8:12] if h[:4] == b'FORM' else b''


def convert(extracted, out_root, log=print):
    counts = {}
    for tre in ('BIGTRE', 'TOBIGTRE'):
        data = os.path.join(extracted, tre, 'DATA')
        for sub in ('MISSIONS', 'INTEL', 'OBJECTS'):
            d = os.path.join(data, sub)
            if not os.path.isdir(d):
                continue
            for fn in sorted(os.listdir(d)):
                path = os.path.join(d, fn)
                kind = form_of(path)
                handler = {b'MISN': ('missions', parse_mission), b'PROF': ('profiles', parse_profile),
                           b'WRLD': ('worlds', parse_world), b'WEAP': ('loadouts', parse_loadout)}.get(kind)
                if not handler:
                    continue
                folder, fn_parse = handler
                prefix = 'TO_' if tre == 'TOBIGTRE' else ''   # Tactical Operations add-on
                try:
                    obj = fn_parse(path)
                except Exception as e:
                    log(f'  {fn}: {e!r}'); continue
                os.makedirs(os.path.join(out_root, folder), exist_ok=True)
                with open(os.path.join(out_root, folder, prefix + fn[:-4].upper() + '.json'), 'w') as f:
                    json.dump(obj, f, indent=1)
                counts[folder] = counts.get(folder, 0) + 1
    log('  ' + ', '.join(f'{v} {k}' for k, v in sorted(counts.items())))


if __name__ == '__main__':
    convert(sys.argv[1], sys.argv[2])
