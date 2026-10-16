"""Extract flight data for every aircraft object (FORM OBJT/JETP) into gamedata/aircraft/*.json.

Field meanings come from comparing values across aircraft with real-world figures and from the
public libRealSpace notes (see docs/FORMATS.md). Raw values are kept alongside derived ones.
"""
import json, os, struct, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import iff, realspace as rs


def fx(b, o):
    return struct.unpack_from('<i', b, o)[0] / 256.0


def parse_jdyn(jd):
    return {
        'fuel_kg': fx(jd, 0),
        'afterburner_boost': [fx(jd, 8), fx(jd, 12)],
        'drag_mod': [fx(jd, 16), fx(jd, 20)],
        'pitch_inertia': fx(jd, 24),
        'pitch_gain': fx(jd, 28),
        'rate_threshold': jd[32],
        'envelope_vs_limit': fx(jd, 35),
        'approach_speed_kt': fx(jd, 39),
        'envelope_bank_deg': jd[43],
        'envelope_pitch_deg': jd[44],
        'min_airspeed': fx(jd, 46),
        'drag_coefficient': fx(jd, 50),
        'response_scale': fx(jd, 54),
        'aileron': struct.unpack_from('b', jd, 58)[0],
        'rudder': jd[59],
        'max_g': struct.unpack_from('b', jd, 60)[0],
        'max_speed_ms': struct.unpack_from('<h', jd, 61)[0],
        'unknown': list(struct.unpack_from('<2hib b', jd, 63)),
    }


def parse_expl(c):
    if c is None:
        return None
    return {'sprite': c.data[:8].split(b'\0')[0].decode('latin1'),
            'radius_ft': struct.unpack_from('<H', c.data, 8)[0], 'damage': struct.unpack_from('<H', c.data, 10)[0]}


def parse_children(chld):
    out = []
    for k in range(0, len(chld) - 31, 32):
        name = chld[k:k + 8].split(b'\0')[0].decode('latin1')
        x, y, z = struct.unpack_from('<3i', chld, k + 8)
        out.append({'model': name, 'offset_m': list(rs.sc_to_godot((x, y, z)))})
    return out


def parse_weapons(weap):
    out = {'stations': []}
    if weap is None:
        return out
    w = weap.first(b'WPNS')
    if w:
        d = w.data
        # records: u16 count, char name[8]
        for k in range(0, len(d) - 9, 10):
            n, name = struct.unpack_from('<H', d, k)[0], d[k + 2:k + 10].split(b'\0')[0].decode('latin1')
            if name:
                out['stations'].append({'weapon': name, 'count': n})
    dc = weap.first(b'DCOY')
    if dc:
        out['chaff'], out['flares'] = struct.unpack_from('<2H', dc.data)
    return out


def convert(objects_dir, out_dir, log=print):
    os.makedirs(out_dir, exist_ok=True)
    n = 0
    for fn in sorted(os.listdir(objects_dir)):
        root = iff.load(os.path.join(objects_dir, fn))[0]
        objt = root.first(b'OBJT')
        jetp = objt.first(b'JETP') if objt else None
        dynm = jetp.first(b'DYNM') if jetp else None
        if not dynm or not dynm.first(b'JDYN'):
            continue
        thrs = dynm.first(b'THRS').data
        flags = struct.unpack_from('3b', thrs.ljust(7, b'\xff'), 4)
        info = {
            'name': fn[:-4],
            'empty_mass_kg': fx(dynm.first(b'DYNM').data, 0),
            'max_thrust_n': fx(thrs, 0),
            'has_afterburner': flags[0] != -1,
            'thrs_flags': list(flags),
            'stability': fx(dynm.first(b'STBL').data, 0) if dynm.first(b'STBL') else None,
            'atmo': fx(dynm.first(b'ATMO').data, 0) if dynm.first(b'ATMO') else None,
            'jdyn': parse_jdyn(dynm.first(b'JDYN').data),
            'children': parse_children(jetp.first(b'CHLD').data) if jetp.first(b'CHLD') else [],
            'weapons': parse_weapons(jetp.first(b'WEAP')),
            'hit_points': struct.unpack_from('<H', jetp.first(b'DAMG').data)[0] if jetp.first(b'DAMG') else 30,
            'explosion': parse_expl(jetp.first(b'EXPL')),
            'debris': [jetp.first(b'DEST').data[k:k + 8].split(b'\0')[0].decode('latin1')
                       for k in range(0, len(jetp.first(b'DEST').data) - 7, 14)] if jetp.first(b'DEST') else [],
            'ejection_seat': jetp.first(b'EJEC').data.split(b'\0')[0].decode('latin1') if jetp.first(b'EJEC') else None,
        }
        with open(os.path.join(out_dir, info['name'] + '.json'), 'w') as f:
            json.dump(info, f, indent=1)
        n += 1
    log(f'  {n} aircraft flight models')
    return n


if __name__ == '__main__':
    convert(sys.argv[1], sys.argv[2])
