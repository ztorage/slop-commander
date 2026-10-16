# Strike Commander Remake (Godot 4, macOS)

A from-scratch reimplementation of Origin Systems' *Strike Commander* (1993) in Godot 4, with
upscaled textures and modern rendering.

**This repository contains no original game code or assets.** To play you need your own copy of the
Strike Commander CD. The included tools read your disc and convert its data locally; the
converted files are gitignored and are never part of an exported build.

## Setup

```sh
python3 -m venv .venv && .venv/bin/pip install -r tools/requirements.txt
.venv/bin/python tools/extract.py /path/to/StrikeCommander.cue   # .cue, .img/.bin, .iso or a mounted CD folder
godot --path godot
```

Music is rendered from the original General MIDI scores with [FluidSynth](https://www.fluidsynth.org)
(`brew install fluid-synth`) and a General MIDI SoundFont: put one at `soundfonts/default.sf2` (for
example [GeneralUser GS](https://www.schristiancollins.com/generaluser)) or set `SC_SOUNDFONT`. Without
it the game runs without music. Engine sound is muffled to 50% by default (`ENGINE_LEVEL` in
`godot/scripts/audio.gd`).

`extract.py` writes:

| Folder        | Contents                                         | In git? |
|---------------|--------------------------------------------------|---------|
| `extracted/`  | raw files copied/unpacked from your disc         | no      |
| `gamedata/`   | converted assets the game loads at runtime       | no      |

The game looks for `gamedata/` in `$SC_GAMEDATA`, then the app's user-data folder
(`~/Library/Application Support/Godot/app_userdata/Strike Commander Remake/gamedata`), then next to
the `godot/` project. Without it, the game shows instructions and does not start.

## Controls (follows the original reference card)

| Key | Action | Key | Action |
|---|---|---|---|
| Arrows | stick (pitch/roll) | `,` `.` (or Z X) | rudder |
| `1`–`5` | military power 20–100% | `6`–`0` | afterburner 20–100% |
| `+` `-` | throttle up/down (into afterburner) | L | landing gear |
| B | wheel brakes / air brake | Ctrl+E | eject |
| Space | fire selected weapon | W | next weapon |
| G | guns (dogfight) mode | T / Shift+T / Ctrl+T | target farther / closer / none |
| `;` | chaff | `'` | flare |
| F1 | cockpit | F2 | chase camera |
| F3 / F4 / F5 | look left / right / back | F6 | external (orbit, mouse-drag) |
| `[` `]` | cycle views | D | right MFD: weapons / damage |
| Ctrl+I | cockpit art on/off | Ctrl+R / Shift+R | restart / restart airborne |
| N | navigation map | Shift+Tab / Tab (hold) | time compression 1×/2×/4× / 6× |
| Esc | menu | | |

Gamepads: left stick flies, triggers are throttle, A fires, X next weapon, Y target, B decoys.

## Layout

- `tools/` — disc reader, archive/format decoders, asset converters (Python)
- `docs/FORMATS.md` — reverse-engineered file format notes
- `godot/` — the game project

## Legal

Strike Commander is © Origin Systems / Electronic Arts. This project is an unofficial, non-commercial
reimplementation and is not affiliated with or endorsed by them. Do not commit or distribute files
produced by the extraction tools.
