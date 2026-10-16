# Strike Commander (CD, 1993) — reverse-engineered formats

Status legend: ✅ decoded & verified · 🟡 partly understood · ⬜ not yet examined

## Disc image ✅
`StrikCoC/cd/StrikeCommanderEAClassics.img` is raw MODE1/2352. Strip the 16-byte sync/header and
keep 2048 bytes per sector (`tools/img2iso.py`) → plain ISO9660. Contents are copied to `extracted/cd/`.

## TRE archives ✅ (`tools/tre_extract.py`)
Little-endian. `u32 count, u32 dataStart`, then `count` × 74-byte entries:
`u8 flag, char path[65] (DOS path, NUL-terminated, "..\..\DATA\..."), u32 offset, u32 size`.
BIGTRE/LILTRE/VOCLIST = base game, TOBIGTRE/TOVOCLST = Tactical Operations add-on.

## IFF ✅ (`tools/iff.py`)
EA-IFF-85, big-endian sizes, `FORM`/`CAT `/`LIST` containers, even padding. Payload fields inside
chunks are little-endian.

## Palette ✅ (`PALETTE/PALETTE.IFF`, `FORM PALT`)
`PALT` chunk = 4-byte header + 256 × RGB, 6-bit VGA (×255/63). 16 ramps of 16 shades.
Also `BLWH`, `SKYC` (sky gradients), `RANG`, `BILD` — 🟡.

## 3D objects ✅ (`OBJECTS/*.IFF`, `FORM REAL`)
- `FORM OBJT` — gameplay data: `JETP` (EXPL, DEBR, DEST, SMOK, CHLD, JINF, DAMG, TOFF, LAND,
  `DYNM` flight model, `WEAP` loadout & hardpoints, `DAMG/SYSM` systems) 🟡
- `FORM APPR / FORM POLY` (also `AFTB` afterburner variant, `ANIM` sprite seqs 🟡):
  - `VERT`: n × `i32 x, y, z`. x=right, y=forward, z=up. ≈157.5 units/ft (≈516.7/m).
  - `FORM DETA / LVLn`: `u32 switchDistance` + `u16` triangle ids. LODs are independent meshes
    that partition the triangle list.
  - `FORM TRIS / VTRI`: 8-byte records `u8 kind, u8 v0, u8 v1, u8 v2, u8 colour, u8 0, u8 flags, u8 ?`.
    Wound clockwise from outside but not consistently → render double-sided.
  - `UVXY`: 8-byte records `u8 triId, u8 texId, u8 u0,v0,u1,v1,u2,v2` (texel coords).
  - `FORM TXMS / TXMP`: `char name[8], u16 w, u16 h`, then either `"LZ"` + GIF-style LZW stream
    (LSB-first, 9→12-bit codes, 256=clear, 257=end) or `w*h` raw bytes. Index 255 = "show the
    triangle's flat colour".  `TXMA` = animated texture 🟡.

## PAK containers ✅ (`tools/pak.py`)
`u32 totalSize`, then `u32` entries `offset | flag<<24` until the first entry's offset. Entries
sharing an offset are empty. Flag `0xE0` normal, `0x20` seen on LZW-compressed terrain blocks.

## Theatres ✅ (`<THEATRE>.PAK` on the CD root, `tools/terrain.py`)
World units are **feet**: x = east, y = north, z = up; map centred on the origin; 18×18 blocks of
20000 ft. Entries:
0. `FORM TERA` header: `BLOX/ELEV` (per LOD: blocks/side, verts/side, block size, file names),
   `ATRI`, `OBJS`, `TXMS/MAPS` (ground tile sets: hi/med/lo start index into TXMPACK + count).
1. / 2. / 3. Hi / med / lo elevation: PAK of 324 blocks, each `u32 rawSize` + LZW (same codec as
   textures). Vertices are 6 bytes: `i16 height (ft), u8 light, u8 landType, u8 upperTile, u8 lowerTile`.
   Hi = 20×20 verts per block → a 360×360 grid, 1000 ft spacing, row 0 = north.
   Quads split top-left → bottom-right; the upper (NE) triangle uses `upperTile`, the lower (SW)
   uses `lowerTile`, 255 = untextured. Vertex colour = `RANG[landType].first +
   ((light * RANG[landType].shades + 128) >> 8)` (palette `RANG` chunk: u16 count, 13-byte records
   `u16 first, u16 shades, u16 fog, u8 r,g,b (6-bit), 4 bytes ?`).
   Land types: 0 sea, 1 desert, 2 ground, 3 savannah, 4 taiga, 5 tundra, 6 snow.
4. Overlays (runways/roads, `.TRI`): PAK of 324; each `u16 nVerts, nPolys, gridDim, tableLen`;
   verts 13 bytes (`i32 x, y, z` 24.8 fixed + u8); polys 16 bytes (`u8 ?, u16 v0,v1,v2, u8 kind,
   u16 texture, u8 uv[6]`), then `tableLen` u16 + `gridDim²` u16 spatial index. Textures come from
   `TXM/ACCPACK.PAK` (`u16 w, h` + pixels), names in `TXM/ACC_LIST.IFF`.
5. Objects (`.OBJ`): PAK of 324; `u16 count` + 70-byte records: `char model[8], 5 bytes ?,
   char destroyedModel[8], u8 ?, i32 x, y, z (24.8), i32 basis[9] (24.8, row-major, columns = local axes)`.
6. 324 × `u16` average block height.

Ground tiles: `TXM/TXMPACK.PAK`, 255 entries of `u16 w, h` + pixels (mostly 64×64). Hi-detail tiles
carry an artist guide line (palette 229/232) on the top/bottom rows and main diagonal, which the
converter removes. Index 255 = show vertex colour.

## Aircraft flight data ✅ (`OBJT/JETP`, `tools/aircraft.py`)
Values checked against real aircraft (F-16, F-15, Su-27, MiG-21, A-10, 747, C-130):
- `DYNM/DYNM`: empty mass, kg (24.8). `DYNM/THRS`: max thrust, N (24.8) + 3 × i8 (first = -1
  when there is no afterburner). Some aircraft have a 6-byte THRS.
- `DYNM/JDYN` (73 bytes): `+0` internal fuel kg; `+8/+12` afterburner stage factors; `+24` pitch
  inertia; `+28` pitch gain; `+39` approach speed kt; `+50` drag coefficient; `+58` i8 aileron
  (roll authority); `+59` rudder; `+60` i8 max G; `+61` i16 **top speed, m/s** (A-10 196 = 381 kt).
- `CHLD`: 32-byte records `char model[8], i32 x, y, z` (object units) + 12 bytes; afterburner flame
  (`*AB`), landing gear frames `GEAR0..4`, gun.
- `WEAP/WPNS`: `u16 count, char weapon[8]` per station; `DCOY`: chaff, flares.
The remake uses these as parameters of its own physics model (`godot/scripts/flight/flight_model.gd`).

## Shapes ✅ (`tools/shape.py`)
Origin RLE shapes: `i16 right, left, top, bottom` (extents around a hotspot; w = left+right+1,
h = top+bottom+1), then fragments until `u16 0`: `u16 code, i16 dx, i16 dy` relative to the hotspot.
`code & 1 == 0` → `code >> 1` raw palette bytes; `code & 1 == 1` → `code >> 1` texels as sub-runs
(`u8 sub`: even = `sub >> 1` raw bytes, odd = one byte repeated `sub >> 1` times). Unwritten = transparent.
Containers: `"LZ" + u32 size + LZW`, or a PAK of shapes whose `0x20`-flagged entries are `u32 size + LZW`.

## Cockpits ✅ (`FORM CKPT` in OBJECTS, `tools/cockpit.py`)
All art is for a 320×200 screen. `ARTP` = PAK of full-screen views (0 front, 1 left, 2 right,
3 rear, 4 front with panel lowered); `EJEC` = 15-frame ejection; `GHUD`/`GUNF` overlays.
`INST/<name>/INFO` = `i16 x1, y1, x2, y2, cx, cy` (+ more for RAWS/MWRN) with `SHAP` (dial face,
needles with the pivot as hotspot): AIRS airspeed, ALTI altimeter (long + short needle), MWRN
warning lights, RAWS radar warning (NORM in-panel scope, ZOOM for an MFD, SYMB threat symbols).
`MONI`: MFD bezel `SHAP`, `SPOT` = 5-byte records `char side ('L'/'R'), i16 x, y` for zoomed MFDs;
`MFDS/<mode>` (AARD air radar, AGRD ground radar, GCAM gun camera, WEAP, DAMG, COMM) with `INFO`
(first bytes include the preferred side) and `SHAP` symbology. In-panel MFD screens and the HUD
glass are painted into the art; their rectangles are measured and stored in `tools/cockpit.py`.

## Weapons & effects ✅ (`tools/weapons.py`)
`OBJT` sub-forms: `MISS` missiles, `TRCR` gun rounds, `BOMB`, `DECY` flare/chaff (also `GRND`
vehicles, `SWPN` SAM/AAA sites & ships, `ORNT` scenery, `DEBR` debris, `EXPL` explosions, `EJEC`,
`OMOB` parachutes, `RNWY`, `XMIT`).
- `EXPL` (12): `char sprite[8], u16 blastRadiusFt, u16 damage`.
- `WDAT` (22): `u16 damage, u16 ?, u8 guidance[5]` (byte 1: 1 = IR, 9 = radar, 3 = TV),
  `u32 rangeFt, u8 seekerConeDeg, u32 range2Ft`, …
- `DYNM/DYNM`: mass kg (24.8). `DYNM/MISS`: `turnG, maxSpeed m/s, motor` (24.8).
- `DATA` byte 4: 1 = air-to-air.
- Aircraft `JETP`: `DAMG` u16 hit points (F-16 70, MiG-29 29, Su-27 37, F-22 80); `EXPL` explosion;
  `DEST` debris models (14-byte records `char name[8]` + 6 bytes); `DEBR` generic debris list.
- `APPR/ANIM`: sprite animations — `INFO`, `SEQU`, `SHAP` = LZ shape set of frames (explosions,
  `GUNSPARK`, ground explosions `GRNDEX*`, `FLARE`, `CHAFF`).
- Cockpit `EJEC` frames are overlays for the front view (ejection handle pull, MFDs dropping out).

## Ground units ✅ (`tools/ground.py`)
`OBJT` sub-forms `GRND` (vehicles), `SWPN` (SAM/AAA sites, ships), `ORNT` (buildings), `XMIT`:
`DAMG` u16 hit points (T-72 50, ZSU-23 40, SA-2 site 30, SA-6 launcher 20, destroyer 300,
hangar 100); `DEST` destroyed-state models (14-byte records, `SMOKEGEN` = smoke column);
`EXPL` explosion; `DEBR` debris; `TRGT`, `SIGN`, `ALGN`.
`SWPN/DATA` (33): `u32 ammo, u32 rangeFt, u32 minRangeFt, u8 rate, …, char weapon[8] @21`
(ZSU-23: 2500 × 23MM to 10 000 ft; SA-2 site: 4 × SA2 to 20 000 ft; SA-6: 12 × SA6 to 60 000 ft).
Bombs (`BOMB`, `DURD`): `WDAT` damage (Mk 82 350, GBU-15 2000), `EXPL` blast radius (75 / 200 ft),
`guidance[2] == 3` = guided.

## Missions ✅ (`MISSIONS/MISN-*.IFF`, `tools/missions.py`, runtime `godot/scripts/mission/`)
`FORM MISN`: `VERS`, `INFO`/`NAME` (theatre title), `TUNE`, `FORM WRLD/FILE` (world descriptor),
`AREA`, `SPOT`, `NUMS`, `MSGS` (NUL-separated nav-point labels), `FLAG` (initial flags, every
other byte), `CAST` (9-byte actor names → profiles), `PROG` (bytecode), `PART`, `TEAM`,
`FORM PLAY` of `SCNE`, `LOAD`/`CACH` (preload lists).
Coordinates are signed 24-bit feet stored in 4-byte slots.
- `AREA`: `char kind ('S'/'C'/'B'), char name[33], x, y, z, u16 width` + kind-specific tail
  (S 49 bytes total, C 53 with height at +50, B 65 with height at +58).
- `SPOT` (14): `i16 area (−1 = absolute), u8 ?, x, y, i16 altitude, u8 ?` — relative to its area.
- `PART` (62): `u16 id, char model[8], char destroyed[8], char loadout[8], u8 area, u8 ?,
  u16 relative, x, y, i16 alt, u8 ?, u16 heading°, u8 extra[11]` (extra[2] team: 255 = enemy;
  extra[3] leader; extra[5..10] formation slot `i16 side, ahead, up`), then 4 × (`u8 prog`, pad):
  on-activated, on-update, on-destroyed, on-init (255 = none). Positions are relative to
  `area` when it isn't 255. CAST index = PART id.
- `SCNE`: `u8 active, i16 area (−1 = always), i16 prog on-activated, on-leaving, on-update,
  u8 coordOnArea, 14 bytes, then u16 cast entries` — **cast entries index the PART list**.
- `PROG`: `(u8 opcode, u8 arg)` pairs, programs separated by `00 00`. Each actor's update program
  re-runs every AI tick; objective opcodes (0xA1 take-off, 0xA2 land [+0x09 touchdown spot],
  0xA5 fly to spot, 0xA6 fly to area, 0xA7 destroy, 0xA8 defend target, 0xA9 defend area,
  0xAA follow, 0xBF patrol) report "in progress" until complete and 0x46 skips ahead while busy.
  Flags/registers: 0x10 work=arg, 0x11 work=flag, 0x50 flag=work, 0x52/0x53 set/clear,
  0x55/0x56 ±1, 0x23 flag+=work, 0x14 save work to a game-flow register, 0x2E work×=arg.
  Tests: 0x40/0x41 compare, 0x45 flag≠0, 0x92 in same area, 0x93 destroyed?, 0x98 active?,
  0x95/0x97 distance in thousands of feet. Branches: 0x48 eq, 0x49 ne, 0x4A lt, 0x4B gt, 0x4F to
  label in work, 0x08 label. Actors: 0x90/0x91 activate/deactivate, 0x94 destroy, 0x80/0x81
  scene on/off (by index), 0xA0 wait seconds, 0xAB radio message (profile line; Strike Base
  20 = mission won, 21/22 = lost), 0xB6/0xB7 nav map, 0xB8/0xB9 join/leave the player's flight,
  0xBE pacify. Provisional (scoring only): 0x20 +arg, 0x21 +flag, 0x24 −flag, 0x25 −arg,
  0x2F ÷arg, 0x4C branch ≤, 0x4E branch always.
- The player's nav points are the objective opcodes of the player's init program, each labelled
  by the following 0xAB (index into `MSGS`).

## Profiles, loadouts, worlds ✅
- `INTEL/*.IFF` `FORM PROF`: `RADI/INFO` (`u16 id, name\0, callsign\0`), `SPCH` voice id, `MSGS`
  (`u8 id, text\0`…), `_AI_/ATRB` 9 skills 0–16 (trigger-happy, confidence, verbosity, loyalty,
  flying, air-to-ground, air-to-air, showmanship, aggressiveness), `GOAL`, `MVRS`.
- `OBJECTS/*LOAD*.IFF` `FORM WEAP`: `WPNS` (`u16 count, char weapon[8]`…), `DCOY` chaff, flares.
- `MISSIONS/<world>.IFF` `FORM WRLD`: `TERA` theatre PAK, `PALT`, `SKYS`, `LGHT`, `CAMR` cameras.

## Sound & music ✅ (`tools/audio.py`, runtime `godot/scripts/audio.gd`)
- Speech: `LILTRE INTEL/SPEECH.PAK` = PAK (index = profile `SPCH` voice id) of PAKs (index = radio
  message number) of Creative Voice files; entries are `0x20` LZW-compressed. 283 clips.
- Digital effects: `SOUND/DSOUNDFX.PAK` = PAK of PAKs of VOC clips: 0 Mk 82 drop, 1 Mk 20 drop,
  2–5 explosions, 6 AIM-9, 7 AIM-120, 8 rocket pod, 9 Maverick, 10–15 gun impacts, 16–18 fly-bys,
  19/20 gear up/down, 21 touchdown, 23 engine (military), 24 afterburner, 25–30 engine start /
  shutdown / transitions.
- VOC: `"Creative Voice File\x1a"`, header size at +20; blocks `u8 type, u24 size`: 1 = sound
  (`u8 timeConstant` → rate = 1e6 / (256 − tc), `u8 codec`), 2 continuation, 3 silence, 9 extended.
- Music: `SOUND/COMBAT.*`, `GAMEFLOW.*` (`.MID` General MIDI, `.ROL` MT-32, `.ADL` AdLib) and
  `MIDGAMES/{A,R,M}MUSIC.PAK`: PAKs whose first entry is an archive of transition tracks followed by
  XMIDI songs (`FORM XDIR` / `CAT XMID` / `EVNT`, 120 Hz ticks, note-ons carry durations).
  Songs loop with XMIDI controllers 116 (FOR, value 0 = forever) / 117 (NEXT); stingers have no loop.
  `COMBAT.DAT` (PAK, record 0): `u8 N; N × (phraseLen bars, phraseLast); N×N matrix (0xFF = none);
  u8 E; E × (u8 L, L+1 values)`. A requested change waits for the next bar; position in the phrase =
  `bar % phraseLen` (+1, or phraseLast when 0) indexes `links[matrix[cur][req]]`: 0 = cut, n = play
  link track n−1 (bit 7: over the still-running song), then start the requested song.
  Combat set tracks chosen by the flight code (from STRIKE.EXE): mission `TUNE` (0–3) cruising;
  with an enemy aircraft or armed ground site within 18 520 ft: 9 missile guiding on you, 5 on an
  enemy's tail (≤ 3 500 ft, within 45° of the nose, behind it), 7 / 6 at ≥ 75 % / ≥ 35 % damage,
  else 4 (air) or 19 (ground only); 13 when the area is clear after a fight, 12 mission complete;
  stingers 16 / 17 / 18 for the player's aircraft / vehicle / other kills, 14 / 15 friendly losses,
  11 crash, 20 death, 8 / 21 autopilot.
- `VOCLIST.IFF`: `LIST` of 20-byte VOC file names (`f:3mi061.voc`) for the cutscene speech in
  `VOCLIST.TRE`.

## Campaign: story script, screens, conversations 🟡 (`tools/story.py`, runtime `godot/scripts/story/`)
All in `BIGTRE/DATA/GAMEFLOW`.
- `GAMEFLOW.IFF` `FORM GAME`: one `FORM MISS` per story stage: `INFO` id, `EFCT` script (u8 opcode,
  u8 value pairs), `FORM SCEN`* (`INFO` = OPTIONS screen id) with `FORM SPRT`* (`INFO` = sprite id,
  `EFCT` click script, `REQU` (op, flag) pairs: 0 flag clear, 1 flag set, 2 clear-or-next).
  Opcodes: 0 conversation, 1 screen, 2 cutscene, 3/12 fly mission (index into `MLST`), 6/7 flag
  on/off, 8 establishing shot, 9/10 if (not) flag, 13 next stage id, 15 go to it, 16/17 save/load,
  18 travel map, 19 kill board, 20/21 if contract accepted/rejected, 22 end stage, 23 catalogue,
  25 ledger, 29 check balance, 30 else, 31 endif, 32 if mission n won, 34 apply `STAT` change,
  37 if last mission won, 38 music modifier. Unknown: 4, 11, 14, 24, 26, 27, 35, 36, 40.
  `WRLD/MAPS`: travel maps (u8 count, then u16 x, u16 y, name). `STAT/CHNG`: `CASH`/`OVER` (u8 op
  0 add/1 subtract/2 set, u32 thousands of dollars), `WEAP` (op, weapon, u16), `PILT` (op, pilot,
  kind, u16). `MLST`: `DATA` 8-byte mission names, `PRTL` 9-byte (theatre name, id).
- `OPTIONS.IFF` `FORM OPTS/SCEN`: `INFO` id, `COLR`, `TUNE` (gameflow music), `BACK` (`PALT`,
  `SHAP`* OPTSHPS indices), `FORE` (`PALT`, `SPRT`*: `SHAP` = [sprite id, OPTSHPS index or 0xff,
  ?], `LABL`, `RECT` x0 y0 x1 y1 or `QUAD`, `SEQU` animation frame list, `INFO`, `TUNE`, `CLCK`).
  Sprite frame 0 is the still image, the others animate over it. `ESTB/SHOT`: establishing shots,
  `PALS` patches then `SHPS` layers (`SHAP` static / `MOBL` animated: u16 shape, i16 x, i16 y).
- Screen art is in absolute 320x200 coordinates. Palettes (`OPTPALS`/`CONVPALS`) are patches:
  u16 first colour, u16 count, 6-bit RGB; a screen's palette is the base palette with its patches.
- `CONV.PAK`: conversation scripts. Frames: `00` wide shot (set name[9]); `01` figure (name[9],
  u16 x, y); `02` figure speaks (name[9], x, y, u8 colour, voice\0, text\0); `03` close-up
  (name[9], u8 expression, set[9], u16 x, y = face hotspot, voice\0, text\0, u8 colour); `04`
  continue (voice\0, text\0); `0A` caption (colour, voice\0, text\0); `0B` u16 yes/no question
  ("no" skips that many bytes); `0C` u16 end of "yes" branch (skip); `0E` u16 (unknown); `0F` pick a
  wingman. Text uses `$N` first name, `$S` surname, `$C` callsign, `$W` wingman. Conversation art
  sits below a 24-pixel band.
- `CONVDATA.IFF`: `BCKS/BACK` sets (layers of u8 source 0 CONV/1 OPT, u8 shape, u8 palette, i16 y),
  `FACE`/`FIGR` (name -> CONVSHPS set), `PFIG`/`FCPL`/`FGPL` palettes. Face sets: 0 face, 1 hair,
  2-11 mouth shapes, 12-33 eyes/brows/expressions (the close-up's expression byte is a frame), 21
  blink, 34-36 clothing, 37 sunglasses, 38/39 helmet and visor.
- Speech: `VOCLIST.TRE` `F_<voice code>.VOC`.

## Intro movie ✅ (`FLIC/THEFLIC.FLX`, `FLIC/FLIC.PAK`, `tools/cinematics.py`)
Decoded from the CD's player (`MENU.EXE`, "PLAYFLIC 1.0b"), disassembled for the frame codecs.
- `THEFLIC.FLX`: Origin Flex container; u32 entry count at 0x54, (u32 offset, u32 size) table at
  0x80. Entries: 1 byte = scene marker; 772 bytes = palette (u16 first, u16 count, 6-bit RGB);
  frames = 16-byte header [1, compression (0 raw / 1 LZW), codec, margin, 12 x 0] + data, the
  picture covering rows margin .. 200-margin.
- Codec 1: full picture. Codec 2: 4x4 blocks, 80 per row; the first data byte is an escape that
  toggles coded/raw; coded = c0 c1 (equal: solid) or c0 c1 + 16-bit mask (MSB first, set = c1);
  raw = 16 bytes. Codec 0: transparent run-length overlay (u16 flags, w, h, i16 x0, y0, u16
  row offsets, rows of skip/count runs; flag bit 0: count>>1 with bit 0 = fill).
- `FLIC.PAK`: entries 0-14 sound clips (Creative Voice), 15-17 the score for three sound cards
  (17 = General MIDI, 16 channels), 18-20 a shorter looping score for slow machines. Played at
  11.6 frames/s (tuned by eye against the 93.7 s score), the last frame held until the score
  ends; clips start at frames 1, 128, 151, 165, 215, 230, 265, 305, 360, 385, 415, 550, 680, 705,
  760, 830 (one channel, each cuts the previous).

## Cutscenes ("midgames") 🟢 intro (`MIDGAMES/*`, `tools/midgames.py`, runtime `midgame_player.gd`)
The art is data, the choreography is code in `OPTTEST.EXE` (Borland C++, VROOMM overlays: far calls
in overlay code use segment = 8 x index into the segment table at file offset 0x50570, entries
(u16 paragraph, size, flags, ?); overlay entries point at stubs `CD 3F, u16, u32 file offset
(from FBOV), u16 code size, u16 reloc size, u16 entry count`, then 5-byte `CD 3F u16 offset 00`
entries). The intro is two overlay functions: image offset 0x671A0 (shots 1-8) which calls
0x6E910 (shots 9-25) with all its loaded resources. DS = 0x4C25 (image 0x4C250).
- `MIDn.PAK` (LZW entries): shape sets (320x128 cutscene frames, hotspot conventions as
  conversations) and palette patches; `MIDGAMES.PAK`: shared backgrounds, clouds, palettes;
  `MIDnVOC.PAK`: speech; `MIDGAMES.IFF`: per cutscene `MGnn/DATA` (cards) and `SPOK` (the floppy
  version's subtitles; the CD version plays speech instead and shows no text).
- Scene engine: a scene ticks every N/60 s (60 Hz AIL timer; intro scenes use N = 10, 15, 20).
  TICK draws every object (parent first, then children at the parent's position + their own)
  into the viewport rows 24-151 without clearing it, then updates them. Object classes: plain
  sprite; animation (frame + 1, done after the last); looping animation; pan (adds vx, vy);
  jitter (random walk of up to 1 px per tick); overlay (frame 0 under the current frame); growing
  overlay (frame climbs to the last); clipped sprite (own position, clip rectangle at +0x21);
  conversation face (frame 0, eyes, mouth, children; the pilot subclass adds frames 35, 38);
  visor (MIDGAMES 0: frame 0 while < 4, 13 while > 8, 1 at 12, else the frame, climbing to 13).
- Lip-sync: the face consumes one character of a text per tick: letters map through
  `06891599098769362999252999` (a-z, + 2 = mouth frame), "th" -> 9, "ch"/"er" -> 6, an 'e' before
  a non-letter is silent, 'h' skips the next character. Blinks (frame 12) are random 1 in 30
  unless the eye frame is above 20.
- Speech loops poll the driver once per tick; palettes accumulate patches over the whole intro.
  The HUD shots read pipper paths (41 x/y), offsets, blink tables and bouncing-symbol state from
  DS 0x22AA/0x23B0/0x259E onwards. The intro ends with MMUSIC track 23 (title), a 2 s hold and
  the picture opening out from the band to the full screen (25 steps).

## Front end 🟡 (`tools/frontend.py`, runtime `godot/scripts/ui/front_end.gd`)
- CD game chooser (MENU.EXE, DS paragraph 0x22CA): OPTSHPS 0x2c hills over black, `TOMENU.PAK`
  0 panel at (45, 24), 1 buttons (frames 0/1 up, 2/3 pressed) at panel + (44, 9) / (45, 47),
  166 x 26, 2 = full palette; OPTPALS 0x15 + 0x18 + MID1 0x3b first. No input for 2 minutes ends it.
- Main menu (OPTTEST.EXE overlay 0xC6 at image 0x57A50, entry 0xB87): sky OPTSHPS 0x74, clouds
  MIDGAMES 0x14, hills OPTSHPS 0x2c; `MAINMENU.PAK` 1 = panel at (45, 24) with engraved
  (disabled) labels, 0 = buttons (frame i up, 5 + i pressed) at panel + (11, 10 + 17 i), 210 x 14,
  2 = palette patch. Buttons return 1 continue (only if `gensave` exists), 2 load (only if `*.sav`
  exist; opens the SAVELOAD dialog), 0 new game, 3 training mission, 4 view objects. The title
  music is MMUSIC 23; with music on the menu returns to the intro when the track ends, without
  music after 30 s.
- Widgets: a button draws frame `[+0x28]` (or `[+0x2e]` while pressed: flags `[+0x10]` bit 5) of
  shape `[+0x1e]` at its absolute position, and on release stores `[+0x2c]` at `*[+0x2a]`.
- Pilot licence (same overlay, entry 0): OPTSHPS 0xa0 under OPTPALS 0x1e, music MMUSIC 26,
  FORMFONT fields last name (91, 97), first name (174, 97), callsign (124, 103): letters and
  space, at most 15 characters and 57 / 50 / 98 pixels, Enter/Tab to the next, "_" marks the
  active field. Glyph pixels are palette indices (colour 2).
- `MOUSE.SHP`: crosshair (11 x 11, hotspot 5, 5) and arrow, each with a highlighted copy.

## Not yet examined ⬜
Fonts (other than the cutscene font), flight model constants.

## Credits
Terrain overlay/object record layouts and the `RANG` colour formula were confirmed against the
public notes and source of [libRealSpace](https://github.com/remileonard/libRealSpace)
(Fabien Sanglard, Rémi Leonard et al.). That repository has no licence file, so it is used here
only as documentation; no code is copied from it. Its notes were also the starting point for the
gameflow opcode meanings and conversation frame types listed above.
