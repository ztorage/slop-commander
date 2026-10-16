#!/usr/bin/env python3
"""Extract and convert game data from YOUR OWN Strike Commander CD for the Godot remake.

No original game data ships with this project. Point this tool at a dump of your disc:

    tools/extract.py /path/to/StrikeCommander.cue      # or .img/.bin/.iso, or a mounted CD folder

Steps: read disc -> verify edition -> copy data files to extracted/cd -> unpack TRE archives ->
convert assets into gamedata/ (models, ...) -> write gamedata/manifest.json.

The Godot project never contains game data: it loads gamedata/ at runtime, so an exported
app is free of original content. Use --out to write somewhere else (e.g. the app's user dir).
"""
import argparse, hashlib, json, os, shutil, sys, time

TOOLS = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(TOOLS)
sys.path.insert(0, TOOLS)
import disc, tre_extract

CONVERTER_VERSION = 9

REQUIRED = ['BIGTRE.TRE', 'LILTRE.TRE', 'VOCLIST.TRE']
OPTIONAL = ['TOBIGTRE.TRE', 'TOVOCLST.TRE']  # Tactical Operations add-on
SKIP_PREFIXES = ('DOCS/', 'ACRO', 'PSFONTS')   # Acrobat reader & PDFs are not needed

# SHA-1 of the TRE archives of releases we have verified the converter against.
KNOWN_EDITIONS = {
    'Strike Commander CD-ROM (EA Classics)': {
        'BIGTRE.TRE': 'd5bb6ee9a4f908f9ccf5d25725b1c95890486c40',
        'LILTRE.TRE': '1544a5274c0f8484531a792727e645df7bf7aaec',
        'VOCLIST.TRE': '49c17495d15b2fe582972b8631b64c3495bd820a',
        'TOBIGTRE.TRE': 'ca7d3616f4310d1c5e079fb2b568c0e1bf6d010d',
        'TOVOCLST.TRE': 'ac87d08c71f963b3daea0fb27667d05727d27e2c',
    },
}


def log(msg):
    print(f'[extract] {msg}', flush=True)


def identify(hashes):
    for name, ref in KNOWN_EDITIONS.items():
        if all(hashes.get(k) == v for k, v in ref.items() if k in REQUIRED or k in hashes):
            return name
    return None


def step_disc(src, out_cd):
    d = disc.Disc(src)
    files = d.files()
    missing = [r for r in REQUIRED if r not in files]
    if missing:
        sys.exit(f'error: {src} does not look like a Strike Commander CD (missing {", ".join(missing)})')
    os.makedirs(out_cd, exist_ok=True)
    hashes = {}
    for name in files:
        if name.startswith(SKIP_PREFIXES):
            continue
        data = d.read(name)
        if name in REQUIRED + OPTIONAL:
            hashes[name] = hashlib.sha1(data).hexdigest()
        dst = os.path.join(out_cd, name)
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        with open(dst, 'wb') as f:
            f.write(data)
    edition = identify(hashes)
    if edition:
        log(f'recognised edition: {edition}')
    else:
        log('warning: unrecognised edition (hashes differ from verified releases); continuing')
    return edition, hashes


def step_tre(out_cd, out_root):
    for name in sorted(os.listdir(out_cd)):
        if name.upper().endswith('.TRE'):
            dst = os.path.join(out_root, os.path.splitext(name)[0].upper())
            shutil.rmtree(dst, ignore_errors=True)
            data, entries = tre_extract.read_tre(os.path.join(out_cd, name))
            tre_extract.write_entries(data, entries, dst)
            log(f'unpacked {name}: {len(entries)} files')


def step_models(extracted, assets, upscale):
    import export_glb, realspace
    data = os.path.join(extracted, 'BIGTRE', 'DATA')
    pal = realspace.load_palette(os.path.join(data, 'PALETTE', 'PALETTE.IFF'))
    out = os.path.join(assets, 'objects')
    objs = os.path.join(data, 'OBJECTS')
    n = 0
    for fn in sorted(os.listdir(objs)):
        try:
            if export_glb.export(os.path.join(objs, fn), pal, out, upscale):
                n += 1
        except Exception as e:  # keep going; report at the end
            log(f'  model {fn} failed: {e!r}')
    log(f'converted {n} models')


def step_terrain(extracted, assets, upscale):
    import terrain
    terrain.convert(extracted, os.path.join(assets, 'terrain'), upscale, log)


def step_aircraft(extracted, assets, upscale):
    import aircraft
    aircraft.convert(os.path.join(extracted, 'BIGTRE', 'DATA', 'OBJECTS'), os.path.join(assets, 'aircraft'), log)


def step_cockpits(extracted, assets, upscale):
    import cockpit
    cockpit.convert(os.path.join(extracted, 'BIGTRE', 'DATA', 'OBJECTS'), os.path.join(assets, 'cockpits'), upscale, log)


def step_weapons(extracted, assets, upscale):
    import weapons
    weapons.convert(os.path.join(extracted, 'BIGTRE', 'DATA', 'OBJECTS'), assets, upscale, log)


def step_missions(extracted, assets, upscale):
    import missions
    missions.convert(extracted, assets, log)


def step_ground(extracted, assets, upscale):
    import ground
    ground.convert(os.path.join(extracted, 'BIGTRE', 'DATA', 'OBJECTS'), assets, log)


def step_audio(extracted, assets, upscale):
    import audio
    audio.convert(extracted, assets, None, log)


def step_cinematics(extracted, assets, upscale):
    import cinematics
    manifest_extra = cinematics.convert(extracted, os.path.join(assets, 'cinematics'), log)
    return manifest_extra


def step_midgames(extracted, assets, upscale):
    import midgames
    midgames.convert(extracted, os.path.join(assets, 'cinematics'), upscale, log)


def step_frontend(extracted, assets, upscale):
    import frontend
    return frontend.convert(extracted, assets, upscale, log)


def step_story(extracted, assets, upscale):
    import story
    story.convert(extracted, os.path.join(assets, 'story'), upscale, log)


STEPS = [('models', step_models), ('terrain', step_terrain), ('aircraft', step_aircraft),
         ('cockpits', step_cockpits), ('weapons', step_weapons), ('missions', step_missions),
         ('ground', step_ground), ('audio', step_audio), ('story', step_story), ('cinematics', step_cinematics), ('midgames', step_midgames),
         ('frontend', step_frontend)]


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('source', nargs='?', help='.cue/.img/.bin/.iso or folder of your Strike Commander CD')
    ap.add_argument('--skip-disc', action='store_true', help='reuse extracted/ instead of re-reading the disc')
    ap.add_argument('--only', help='comma-separated conversion steps: ' + ','.join(s for s, _ in STEPS))
    ap.add_argument('--upscale', type=int, default=4, help='texture upscale factor (1, 2 or 4)')
    ap.add_argument('--ai', action='store_true',
                    help='AI-upscale the 2D story art (de-dither + 4x model, local; needs tools/requirements-ai.txt)')
    ap.add_argument('--out', default=os.path.join(ROOT, 'gamedata'), help='converted asset folder (default: gamedata/)')
    a = ap.parse_args()

    extracted = os.path.join(ROOT, 'extracted')
    assets = os.path.abspath(a.out)
    manifest_path = os.path.join(assets, 'manifest.json')
    t0 = time.time()

    if a.skip_disc:
        if not os.path.exists(manifest_path):
            sys.exit('error: --skip-disc needs a previous full extraction')
        manifest = json.load(open(manifest_path))
    else:
        if not a.source:
            ap.error('source is required (path to your CD image or folder)')
        edition, hashes = step_disc(a.source, os.path.join(extracted, 'cd'))
        step_tre(os.path.join(extracted, 'cd'), extracted)
        manifest = {'edition': edition, 'tre_sha1': hashes}

    if a.ai:
        import ai_upscale, upscale
        if not ai_upscale.available():
            sys.exit('error: --ai needs PyTorch and spandrel: pip install -r tools/requirements-ai.txt')
        if a.upscale != 4:
            sys.exit('error: --ai upscales 4x; use --upscale 4')
        upscale.AI = True
        manifest['upscaler'] = 'ai:' + ai_upscale.PIPELINE
    only = set(a.only.split(',')) if a.only else None
    for name, fn in STEPS:
        if only is None or name in only:
            log(f'step: {name}')
            fn(extracted, assets, a.upscale)

    manifest.update({'converter_version': CONVERTER_VERSION, 'generated': time.strftime('%Y-%m-%d %H:%M:%S')})
    os.makedirs(assets, exist_ok=True)
    with open(manifest_path, 'w') as f:
        json.dump(manifest, f, indent=2)

    log(f'done in {time.time() - t0:.0f}s')


if __name__ == '__main__':
    main()
