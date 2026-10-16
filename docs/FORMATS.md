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

## Not yet examined ⬜
Missions (`MISN-*.IFF`), fonts, gameflow/conversations, FLIC cutscenes (`*.FLX`), XMIDI music,
VOC speech, flight model constants.

## Credits
Terrain overlay/object record layouts and the `RANG` colour formula were confirmed against the
public notes and source of [libRealSpace](https://github.com/remileonard/libRealSpace)
(Fabien Sanglard, Rémi Leonard et al.). That repository has no licence file, so it is used here
only as documentation; no code is copied from it.
