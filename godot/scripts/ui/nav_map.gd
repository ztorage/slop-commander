class_name NavMap
extends Control
## Navigation map (N): theatre colour map, mission areas, the player's navigation points with
## their labels, the player and known aircraft.

const COL := Color(0.35, 1.0, 0.45)
const FT := 0.3048

var terrain: Terrain
var mission: MissionRunner
var player: Aircraft
var _map: Texture2D
var _font: Font


func setup(t: Terrain, m: MissionRunner, p: Aircraft) -> void:
	terrain = t
	mission = m
	player = p
	var img := t.color_image.duplicate() as Image
	img.resize(img.get_width() * 3, img.get_height() * 3, Image.INTERPOLATE_BILINEAR)
	_map = ImageTexture.create_from_image(img)


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_font = ThemeDB.fallback_font


func _process(_d: float) -> void:
	if visible:
		queue_redraw()


func _map_rect() -> Rect2:
	var vp := get_viewport_rect().size
	var side := minf(vp.x, vp.y) * 0.9
	return Rect2((vp - Vector2(side, side)) * 0.5, Vector2(side, side))


## World position (metres) -> map pixel.
func _to_map(p: Vector3) -> Vector2:
	var r := _map_rect()
	var half := terrain.grid_size * terrain.spacing_m * 0.5
	return r.position + Vector2((p.x + half) / (half * 2.0), (p.z + half) / (half * 2.0)) * r.size


func _draw() -> void:
	if terrain == null:
		return
	var r := _map_rect()
	draw_rect(Rect2(Vector2.ZERO, get_viewport_rect().size), Color(0, 0, 0, 0.55))
	draw_texture_rect(_map, r, false, Color(0.75, 0.75, 0.75))
	draw_rect(r, COL, false, 2)
	if mission:
		for i in mission.data.areas.size():
			var a: Dictionary = mission.data.areas[i]
			var c := _to_map(mission.area_world(i))
			var w := float(a.width_ft) * FT / (terrain.grid_size * terrain.spacing_m) * r.size.x
			draw_rect(Rect2(c - Vector2(w, w) * 0.5, Vector2(w, w)), Color(1, 1, 1, 0.35), false, 1)
			draw_string(_font, c + Vector2(-w * 0.5 + 3, -w * 0.5 + 13), String(a.name).trim_prefix("."), HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color(1, 1, 1, 0.8))
		var prev := _to_map(player.global_position) if mission.nav_index < mission.nav.size() else Vector2.ZERO
		for i in mission.nav.size():
			var n: Dictionary = mission.nav[i]
			var p := _to_map(n.pos)
			var done := i < mission.nav_index
			var cur := i == mission.nav_index
			var col := Color(0.6, 0.6, 0.6) if done else (Color(1, 1, 0.3) if cur else COL)
			if i > 0:
				draw_line(_to_map(mission.nav[i - 1].pos), p, Color(col, 0.6), 1.5)
			draw_circle(p, 7 if cur else 5, col)
			draw_string(_font, p + Vector2(10, 5), "%d %s" % [i + 1, n.label], HORIZONTAL_ALIGNMENT_LEFT, -1, 14, col)
		for a in mission.actors:
			if a.is_player or not a.spawned or not a.alive() or not (a.node is Aircraft):
				continue
			if a.friendly or a.on_nav_map:
				var p := _to_map(a.position())
				draw_rect(Rect2(p - Vector2(3, 3), Vector2(6, 6)), Color(0.4, 0.7, 1) if a.friendly else Color(1, 0.3, 0.3))
	# player: triangle pointing along the heading
	var pp := _to_map(player.global_position)
	var f := -player.global_basis.z
	var d := Vector2(f.x, f.z).normalized()
	var side := Vector2(-d.y, d.x)
	draw_colored_polygon(PackedVector2Array([pp + d * 11, pp - d * 7 + side * 6, pp - d * 7 - side * 6]), Color(1, 1, 1))
	draw_string(_font, r.position + Vector2(8, r.size.y - 10), "N: close map   Shift+Tab: time compression   Tab (hold): 6x", HORIZONTAL_ALIGNMENT_LEFT, -1, 14, Color(1, 1, 1, 0.8))
