class_name ShotPlayer
extends Canvas320
## Establishing shot: layered art over the 24-pixel band, animated layers cycle through their
## frames once (e.g. a jeep driving up). A click or key skips it.

signal finished

const FPS := 10.0
const MIN_TIME := 3.0

var layers: Array = []
var _t := 0.0
var _length := MIN_TIME


func play(shot_id: int) -> void:
	layers = Campaign.convart.get("shots", {}).get(str(shot_id), [])
	_t = 0.0
	_length = MIN_TIME
	for l in layers:
		if l.anim:
			_length = maxf(_length, l.frames.size() / FPS + 0.8)
	visible = true
	if layers.is_empty():
		_finish.call_deferred()


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP


func _process(delta: float) -> void:
	if not visible:
		return
	_t += delta
	if _t >= _length:
		_finish()
	queue_redraw()


func _finish() -> void:
	if visible:
		visible = false
		finished.emit()


func _gui_input(ev: InputEvent) -> void:
	if ev is InputEventMouseButton and ev.pressed:
		_finish()
		accept_event()


func _unhandled_key_input(ev: InputEvent) -> void:
	if visible and ev.pressed:
		_finish()
		get_viewport().set_input_as_handled()


func _draw() -> void:
	draw_backdrop()
	for l in layers:
		var fr: Array = l.frames
		if fr.is_empty():
			continue
		var i := mini(int(_t * FPS), fr.size() - 1) if l.anim else 0
		draw_entry(fr[i], Vector2(float(l.x), float(l.y) + CONV_Y))
