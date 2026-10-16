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
var side := Side.FRONT
var art_enabled := true
var right_mfd := 0           # 0 weapons, 1 damage
var layout := {}
var _dir := ""
var _views: Array[Texture2D] = []
var _tex := {}               # file -> Texture2D
var _font: Font


static func create(cockpit_name: String) -> Cockpit:
	var c := Cockpit.new()
	c._dir = GameData.path("cockpits/" + cockpit_name)
	c.layout = JSON.parse_string(FileAccess.get_file_as_string(c._dir.path_join("cockpit.json")))
	for v in c.layout.views:
		c._views.append(c._texture(v.file))
	return c


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_font = ThemeDB.fallback_font


func _texture(file: String) -> Texture2D:
	if not _tex.has(file):
		var img := Image.load_from_file(_dir.path_join(file))
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
	return to_screen(Vector2(layout.boresight[0], layout.boresight[1]))


func hud_glass_screen() -> Rect2:
	return rect_to_screen(layout.hud_glass)


func _process(_d: float) -> void:
	queue_redraw()


func _draw() -> void:
	if not art_enabled or aircraft == null:
		return
	var view_index := int(side)
	if view_index < _views.size():
		draw_texture_rect(_views[view_index], Rect2(art_origin(), SCREEN * art_scale()), false)
	if side == Side.FRONT:
		_draw_gauges()
		_draw_mfds()


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
		_mfd_text(r, ["RDR  20", "", "", "", "", "HDG %03d" % _heading()])
	if screens.has("R"):
		var r := rect_to_screen(screens.R)
		draw_rect(r, Color(0.02, 0.12, 0.04))
		if right_mfd == 0 and modes.has("weap"):
			_fit(modes.weap[0], Rect2(r.position + Vector2(0, r.size.y * 0.18), r.size * Vector2(1, 0.55)))
			var stations: Array = aircraft.data.get("weapons", {}).get("stations", [])
			var lines := ["WPNS"]
			for st in stations.slice(0, 2):
				lines.append("%d %s" % [st.count, st.weapon])
			_mfd_text(r, lines)
		elif modes.has("damg"):
			_fit(modes.damg[0], r.grow(-r.size.x * 0.06))
			_mfd_text(r, ["DAMAGE", "", "", "", "", "SYS OK"])


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
