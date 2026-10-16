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

`extract.py` writes:

| Folder        | Contents                                         | In git? |
|---------------|--------------------------------------------------|---------|
| `extracted/`  | raw files copied/unpacked from your disc         | no      |
| `gamedata/`   | converted assets the game loads at runtime       | no      |

The game looks for `gamedata/` in `$SC_GAMEDATA`, then the app's user-data folder
(`~/Library/Application Support/Godot/app_userdata/Strike Commander Remake/gamedata`), then next to
the `godot/` project. Without it, the game shows instructions and does not start.

## Flight controls

| Key | Action | Key | Action |
|---|---|---|---|
| Arrows | stick (pitch/roll) | `,` `.` (or Z X) | rudder |
| `+` `-` / `1`–`0` | throttle | Backspace / Tab | afterburner |
| G | landing gear | B | air brake |
| W | wheel brakes | R / T | restart on runway / in the air |
| F1 / F2 / F3 | cockpit / chase / orbit view | Esc | menu |

Gamepads work too (left stick, triggers for throttle, shoulders for afterburner/air brake).

## Layout

- `tools/` — disc reader, archive/format decoders, asset converters (Python)
- `docs/FORMATS.md` — reverse-engineered file format notes
- `godot/` — the game project

## Legal

Strike Commander is © Origin Systems / Electronic Arts. This project is an unofficial, non-commercial
reimplementation and is not affiliated with or endorsed by them. Do not commit or distribute files
produced by the extraction tools.
