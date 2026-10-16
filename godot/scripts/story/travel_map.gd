class_name TravelMap
extends Canvas320
## The travel map between locations (OPTTEST.EXE overlay 0xC9; see tools/frontend.py): the
## world map, a red route growing from stop to stop at the route's speed, each stop marked and
## named as it is reached, the view scrolling to keep the head of the route in sight. One step
## every 3 ticks (20 per second), a second at each stop. A key or click skips it.

signal finished

const TICK := 1.0 / 60.0

var spec := {}
var points: Array = []
var speed := 4096
var leg := 0
var t := 0                     # progress along the leg, 0..4096
var step := 0
var scroll := Vector2.ZERO     # where the map's top-left is on screen
var head := Vector2.ZERO       # end of the route drawn so far (map coordinates)
var _wait := 0.0
var _phase := "fly"            # fly, stop, end


func setup(spec_: Dictionary, route: Dictionary) -> TravelMap:
	spec = spec_
	img_dir = "frontend/"
	points = route.get("points", [])
	speed = int(route.get("speed", 4096))
	if points.size() > 0:
		head = _pt(0)
		scroll = Vector2(160, 160) - head
	_start_leg()
	return self


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	if points.size() < 2:
		_done.call_deferred()


func _pt(i: int) -> Vector2:
	return Vector2(float(points[i].x), float(points[i].y))


func _start_leg() -> void:
	t = 0
	if leg + 1 >= points.size():
		return
	var d := (_pt(leg + 1) - _pt(leg)).abs()
	var a := int(maxf(d.x, d.y))
	var b := int(minf(d.x, d.y))
	var dist := maxi(a + (b * 11 >> 5), 1)
	step = maxi(speed / dist, 1)


func _clamp_scroll() -> void:
	var mn: Array = spec.scroll_min
	scroll.x = clampf(scroll.x, float(mn[0]), 0.0)
	scroll.y = clampf(scroll.y, float(mn[1]), 0.0)
	if scroll.x < -183.0 and scroll.y > -37.0:     # the map has no top right corner
		scroll.y = -37.0


func _process(delta: float) -> void:
	_wait -= delta
	while _wait <= 0.0 and _phase != "done":
		match _phase:
			"fly":
				_fly_step()
				_wait += float(spec.step_ticks) * TICK
			"stop":
				leg += 1
				if leg + 1 >= points.size():
					_phase = "end"
					_wait += float(spec.end_ticks) * TICK
				else:
					_phase = "fly"
					_start_leg()
			"end":
				_done()
				return
	queue_redraw()


func _fly_step() -> void:
	t = mini(t + step, 4096)
	_clamp_scroll()
	var prev := head
	head = _pt(leg).lerp(_pt(leg + 1), t / 4096.0).round()
	var s := head + scroll
	var b: Array = spec.box
	if t < 4096:
		var move := head - prev
		if not (s.x > float(b[0]) and s.x < float(b[2])):
			scroll.x -= move.x
		if not (s.y > float(b[1]) and s.y < float(b[3])):
			scroll.y -= move.y
	else:
		_phase = "stop"
		_wait += float(spec.stop_ticks) * TICK - float(spec.step_ticks) * TICK


func _done() -> void:
	if _phase == "done":
		return
	_phase = "done"
	finished.emit()
	queue_free()


func _gui_input(ev: InputEvent) -> void:
	if ev is InputEventMouseButton and ev.pressed:
		_done()
	accept_event()


func _unhandled_key_input(ev: InputEvent) -> void:
	if ev is InputEventKey and ev.pressed:
		get_viewport().set_input_as_handled()
		_done()


func _draw() -> void:
	draw_backdrop()
	if spec.is_empty():
		return
	var m: Dictionary = spec.map
	var tex := texture(String(m.file), img_dir)
	if tex:
		# the visible 320 x 200 window of the map
		var k := tex.get_width() / float(m.w)
		var src := Rect2(-scroll * k, Vector2(W, H) * k)
		draw_texture_rect_region(tex, frame_rect(), src)
	var col := Color.html(String(spec.colour))
	var wpx := float(spec.width) * px()
	for i in mini(leg + 1, points.size() - 1):
		var a := to_screen(_pt(i) + scroll)
		var e := to_screen((head if i == leg else _pt(i + 1)) + scroll)
		draw_line(a, e, col, wpx)
	var reached := leg + (1 if _phase != "fly" else 0)
	for i in mini(reached + 1, points.size()):
		var p := _pt(i) + scroll
		draw_rect(Rect2(to_screen(p), Vector2(2, 2) * px()), col)
		draw_font_text(spec.font, String(points[i].name), p + Vector2(0, 5))
