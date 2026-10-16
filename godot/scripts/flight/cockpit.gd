class_name Cockpit
extends Control
## 2D cockpit from the original 320x200 art (upscaled), drawn over the 3D view.
## The art is scaled to the window width and anchored to the bottom edge; every layout
## coordinate in cockpit.json is in the original 320x200 space and goes through to_screen().

const SCREEN := Vector2(320, 200)
const MFD_GREEN := Color(0.45, 1.0, 0.5)
const KT := 1.0 / 0.514444
const FT := 3.28084

enum Side { FRONT, LEFT, RIGHT, REAR }

var aircraft: Aircraft
var world: CombatWorld
var side := Side.FRONT
var art_enabled := true
var hud_zoom := false            # front view zoomed onto the HUD (art view 4)
var right_mfd := 0           # 0 weapons, 1 damage
var layout := {}
var _dir := ""
var _rel := ""
var _views: Array[Texture2D] = []
var _tex := {}               # file -> Texture2D
var _font: Font
var _eject_frame := -1


func ejecting() -> bool:
	return _eject_frame >= 0


static func create(cockpit_name: String) -> Cockpit:
	var c := Cockpit.new()
	c._rel = "cockpits/" + cockpit_name
	c._dir = GameData.path(c._rel)
	c.layout = JSON.parse_string(FileAccess.get_file_as_string(c._dir.path_join("cockpit.json")))
	for v in c.layout.views:
		c._views.append(c._texture(v.file))
	return c


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	texture_filter = GameData.art_filter()
	_font = ThemeDB.fallback_font


func _texture(file: String) -> Texture2D:
	if not _tex.has(file):
		var img := GameData.load_art_image(_rel.path_join(file))
		img.generate_mipmaps()
		_tex[file] = ImageTexture.create_from_image(img)
	return _tex[file]


## Pixels per original pixel, and the top-left of the 320x200 art on screen.
func art_scale() -> float:
	return get_viewport_rect().size.x / SCREEN.x


func art_origin() -> Vector2:
	var vp := get_viewport_rect().size
	return Vector2(0, vp.y - SCREEN.y * art_scale())


func to_screen(p: Vector2) -> Vector2:
	return art_origin() + p * art_scale()


func rect_to_screen(r: Array) -> Rect2:
	var a := to_screen(Vector2(r[0], r[1]))
	var b := to_screen(Vector2(r[2] + 1, r[3] + 1))
	return Rect2(a, b - a)


## Where the HUD boresight sits on screen in the front view (camera frustum is offset to match).
func boresight_screen() -> Vector2:
	var b: Array = layout.get("boresight_zoom", layout.boresight) if hud_zoom else layout.boresight
	return to_screen(Vector2(b[0], b[1]))


func hud_glass_screen() -> Rect2:
	return rect_to_screen(layout.get("hud_glass_zoom", layout.hud_glass) if hud_zoom else layout.hud_glass)


func _process(_d: float) -> void:
	queue_redraw()


## Play the original ejection sequence full-screen (15 frames).
func play_eject() -> void:
	var n: int = layout.get("eject", []).size()
	for i in n:
		_eject_frame = i
		await get_tree().create_timer(0.1).timeout
	_eject_frame = -1


func _draw() -> void:
	if _eject_frame >= 0:
		# overlays for the front view: the ejection handle being pulled, then MFDs dropping to static
		var e: Dictionary = layout.eject[_eject_frame]
		var rect := Rect2(art_origin(), SCREEN * art_scale())
		draw_texture_rect(_views[0], rect, false)
		draw_texture_rect(_texture(e.file), rect, false)
		return
	if not art_enabled or aircraft == null:
		return
	var view_index := 4 if hud_zoom and side == Side.FRONT and _views.size() > 4 else int(side)
	if view_index < _views.size():
		draw_texture_rect(_views[view_index], Rect2(art_origin(), SCREEN * art_scale()), false)
	if side == Side.FRONT and not hud_zoom:
		_draw_gauges()
		_draw_mfds()
		_draw_threats()


func _shape(entry: Dictionary) -> Texture2D:
	return _texture(entry.file)


## Draw an instrument shape with its hotspot at `pos` (320x200 space), rotated by `angle`.
func _draw_shape_at(entry: Dictionary, pos: Vector2, angle := 0.0) -> void:
	var s := art_scale()
	var hot := Vector2(entry.hotspot[0], entry.hotspot[1])
	draw_set_transform(to_screen(pos), angle, Vector2.ONE)
	draw_texture_rect(_shape(entry), Rect2(-hot * s, Vector2(entry.w, entry.h) * s), false)
	draw_set_transform(Vector2.ZERO, 0, Vector2.ONE)


func _draw_gauges() -> void:
	var fm := aircraft.fm
	var inst: Dictionary = layout.instruments
	if inst.has("airs") and inst.airs.shapes.size() >= 2:
		var r: Array = inst.airs.info
		# dial: 0 kt at 6 o'clock, clockwise, 1000 kt full scale over 340 degrees
		var a := PI + clampf(fm.airspeed * KT / 1000.0, 0.0, 1.0) * deg_to_rad(340.0)
		_draw_shape_at(inst.airs.shapes[1], Vector2(r[4], r[5]), a)
	if inst.has("alti") and inst.alti.shapes.size() >= 3:
		var r: Array = inst.alti.info
		var ft := fm.position.y * FT
		_draw_shape_at(inst.alti.shapes[2], Vector2(r[4], r[5]), TAU * fmod(ft / 10000.0, 1.0))
		_draw_shape_at(inst.alti.shapes[1], Vector2(r[4], r[5]), TAU * fmod(ft / 1000.0, 1.0))


func _draw_mfds() -> void:
	var screens: Dictionary = layout.get("mfd_screens", {})
	var modes: Dictionary = layout.get("mfd", {}).get("modes", {})
	if screens.has("L") and modes.has("aard"):
		var r := rect_to_screen(screens.L)
		draw_rect(r, Color(0.02, 0.12, 0.04))
		_fit(modes.aard[3], r.grow(-r.size.x * 0.04))  # radar range/azimuth grid
		_draw_radar_contacts(r)
		_mfd_text(r, ["GND  10" if aircraft.weapons.air_to_ground() else "RDR  20", "", "", "", "", "HDG %03d" % _heading()])
	if screens.has("R"):
		var r := rect_to_screen(screens.R)
		draw_rect(r, Color(0.02, 0.12, 0.04))
		if right_mfd == 0 and modes.has("weap"):
			_fit(modes.weap[0], Rect2(r.position + Vector2(0, r.size.y * 0.18), r.size * Vector2(1, 0.55)))
			var w := aircraft.weapons
			var lines := ["WPNS"]
			for i in w.stations.size():
				var st: Dictionary = w.stations[i]
				var sel := not w.guns_mode and i == w.selected
				lines.append("%s%d %s" % [">" if sel else " ", st.count, st.weapon])
			lines.append("%sGUN %d" % [">" if w.guns_mode else " ", w.gun_rounds])
			lines.append(" F%d C%d" % [w.flares, w.chaff])
			_mfd_text(r, lines)
		elif modes.has("damg"):
			var frac := clampf(aircraft.hp / maxf(aircraft.max_hp, 1.0), 0.0, 1.0)
			var tint := Color(1, 0.3, 0.2).lerp(Color(1, 1, 1), frac)
			var entry: Dictionary = modes.damg[0]
			var size := Vector2(entry.w, entry.h)
			var rr := r.grow(-r.size.x * 0.06)
			var k := minf(rr.size.x / size.x, rr.size.y / size.y)
			draw_texture_rect(_shape(entry), Rect2(rr.position + (rr.size - size * k) * 0.5, size * k), false, tint)
			_mfd_text(r, ["DAMAGE", "", "", "", "", "HULL %d%%" % int(frac * 100)])


## Plan view of radar contacts: own ship at the bottom centre, 20 nm at the top edge.
func _draw_radar_contacts(r: Rect2) -> void:
	if world == null:
		return
	var w := aircraft.weapons
	var origin := Vector2(r.get_center().x, r.end.y - r.size.y * 0.08)
	var scale := (r.size.y * 0.85) / WeaponSystem.RADAR_RANGE
	var inv := aircraft.global_transform.affine_inverse()
	if w.air_to_ground():
		scale = (r.size.y * 0.85) / WeaponSystem.GROUND_RANGE
	for a in w.contacts(world):
		var l: Vector3 = inv * a.global_position          # x right, -z ahead
		var p := origin + Vector2(l.x, l.z) * scale
		if not r.has_point(p):
			continue
		var col := Color(1, 1, 0.4) if a == w.target else MFD_GREEN
		if a is GroundUnit:
			draw_polyline(PackedVector2Array([p + Vector2(0, -4), p + Vector2(4, 0), p + Vector2(0, 4), p + Vector2(-4, 0), p + Vector2(0, -4)]), col, 1.5)
		else:
			draw_rect(Rect2(p - Vector2(3, 3), Vector2(6, 6)), col, a == w.target, -1.0 if a == w.target else 1.5)
	for m in world.missiles:
		var l: Vector3 = inv * m.global_position
		var p := origin + Vector2(l.x, l.z) * scale
		if r.has_point(p):
			draw_circle(p, 1.8, Color(1, 0.4, 0.3))


## Radar-warning scope (bearing of enemies and missiles) and the IR / RADAR launch lamps.
func _draw_threats() -> void:
	if world == null:
		return
	var inst: Dictionary = layout.instruments
	if inst.has("raws"):
		var info: Array = inst.raws.info
		var centre := to_screen(Vector2(info[14], info[15]))
		var radius := art_scale() * 12.0
		var inv := aircraft.global_transform.affine_inverse()
		for a in world.aircraft:
			if a.team == aircraft.team or not a.alive:
				continue
			var l: Vector3 = inv * a.global_position
			var dir := Vector2(l.x, l.z).normalized()
			draw_circle(centre + dir * radius, art_scale() * 1.3, Color(1, 0.85, 0.3))
		for u in world.ground_units:   # SAM / AAA sites that have us inside their envelope
			if u.alive and u.team >= 0 and u.team != aircraft.team and not u.weapon.is_empty():
				if u.global_position.distance_to(aircraft.global_position) < float(u.weapon.get("range_ft", 0)) * 0.3048:
					var l: Vector3 = inv * u.global_position
					var dir := Vector2(l.x, l.z).normalized()
					draw_rect(Rect2(centre + dir * radius - Vector2(1.5, 1.5) * art_scale(), Vector2(3, 3) * art_scale()), Color(1, 0.5, 0.2))
		for m in world.missiles_tracking(aircraft):
			var l: Vector3 = inv * m.global_position
			var dir := Vector2(l.x, l.z).normalized()
			if int(Time.get_ticks_msec() / 150) % 2 == 0:
				draw_circle(centre + dir * radius * 0.6, art_scale() * 1.8, Color(1, 0.25, 0.2))
	# warning lamps painted at (82..111, 100..109): IR on the left, RADAR on the right
	var tracking := world.missiles_tracking(aircraft)
	var ir := tracking.any(func(m): return m.infrared)
	var radar := tracking.any(func(m): return not m.infrared)
	var blink := int(Time.get_ticks_msec() / 200) % 2 == 0
	if ir and blink:
		draw_circle(to_screen(Vector2(87.5, 103.5)), art_scale() * 2.6, Color(1.0, 0.7, 0.2, 0.9))
	if radar and blink:
		draw_circle(to_screen(Vector2(104.5, 103.5)), art_scale() * 2.6, Color(1.0, 0.2, 0.15, 0.9))


func _fit(entry: Dictionary, r: Rect2) -> void:
	var size := Vector2(entry.w, entry.h)
	var k := minf(r.size.x / size.x, r.size.y / size.y)
	var dst := Rect2(r.position + (r.size - size * k) * 0.5, size * k)
	draw_texture_rect(_shape(entry), dst, false)


func _mfd_text(r: Rect2, lines: Array) -> void:
	var fs := int(clampf(r.size.y / 9.0, 7, 22))
	for i in lines.size():
		draw_string(_font, r.position + Vector2(4, fs * (i + 1)), lines[i], HORIZONTAL_ALIGNMENT_LEFT, r.size.x - 8, fs, MFD_GREEN)


func _heading() -> int:
	var f := -aircraft.fm.basis.z
	return int(fposmod(rad_to_deg(atan2(f.x, -f.z)), 360.0))
