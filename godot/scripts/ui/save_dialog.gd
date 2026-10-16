class_name SaveDialog
extends Canvas320
## The original save/load dialog (SAVELOAD.SHP, layout from OPTTEST.EXE; see tools/frontend.py):
## a name field (up to 8 characters, as DOS file names), the list of saves with scroll arrows
## and a slider, Save or Load, Cancel and Quit to DOS; overwriting and quitting ask "are you
## sure". Shown over another screen; `closed` gives {action: "ok"/"cancel", name}.

signal closed(result: Dictionary)

const NAME_CHARS := "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_"
const REPEAT_S := 0.15

var spec := {}
var saving := false
var cursor = null
var names := PackedStringArray()
var scroll := 0
var text := ""
var confirm := ""                # "", "overwrite" or "quit"
var _pressed := ""
var _mouse := Vector2(-100, -100)
var _repeat := 0.0
var _t := 0.0


func setup(spec_: Dictionary, save_mode: bool, cursor_ = null, dir := "frontend/") -> SaveDialog:
	spec = spec_
	saving = save_mode
	cursor = cursor_
	img_dir = dir
	names = Campaign.list_saves()
	return self


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP


func _buttons() -> Array:
	if confirm != "":
		return spec.confirm.buttons
	return [spec.save if saving else spec.load] + spec.buttons


func _button_at(p: Vector2) -> String:
	for b in _buttons():
		var r: Array = b.rect
		if Rect2(float(r[0]), float(r[1]), float(r[2]), float(r[3])).has_point(p):
			return String(b.action)
	return ""


func _max_scroll() -> int:
	return maxi(names.size() - int(spec.rows), 0)


func _process(delta: float) -> void:
	_t += delta
	if _pressed in ["up", "down"] and _button_at(_mouse) == _pressed:
		_repeat -= delta
		if _repeat <= 0.0:
			_repeat = REPEAT_S
			scroll = clampi(scroll + (1 if _pressed == "down" else -1), 0, _max_scroll())
	queue_redraw()


func _gui_input(ev: InputEvent) -> void:
	if ev is InputEventMouseMotion:
		_mouse = to_art(ev.position)
	elif ev is InputEventMouseButton and ev.button_index == MOUSE_BUTTON_LEFT:
		_mouse = to_art(ev.position)
		if ev.pressed:
			_pressed = _button_at(_mouse)
			_repeat = 0.0
			if _pressed == "" and confirm == "":
				_click_list(_mouse)
		elif _pressed != "":
			var a := _pressed
			_pressed = ""
			if _button_at(_mouse) == a:
				_act(a)
	elif ev is InputEventMouseButton and ev.pressed and confirm == "":
		if ev.button_index == MOUSE_BUTTON_WHEEL_UP:
			scroll = maxi(scroll - 1, 0)
		elif ev.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			scroll = mini(scroll + 1, _max_scroll())
	accept_event()


func _click_list(p: Vector2) -> void:
	var r: Array = spec.list_rect
	if Rect2(float(r[0]), float(r[1]), float(r[2]) - float(r[0]), float(r[3]) - float(r[1])).has_point(p):
		var i := scroll + int((p.y - float(r[1])) / float(spec.row_h))
		if i < names.size():
			text = names[i]


func _act(a: String) -> void:
	match a:
		"ok":
			if text == "":
				return
			if saving and text in names:
				confirm = "overwrite"
			elif saving or text in names:
				_close("ok")
		"cancel":
			_close("cancel")
		"quit":
			confirm = "quit"
		"up":
			pass
		"down":
			pass
		"yes":
			if confirm == "quit":
				get_tree().quit()
			else:
				_close("ok")
		"no":
			confirm = ""


func _close(action: String) -> void:
	closed.emit({"action": action, "name": text})
	queue_free()


func _unhandled_key_input(ev: InputEvent) -> void:
	if not (ev is InputEventKey and ev.pressed):
		return
	var k := ev as InputEventKey
	get_viewport().set_input_as_handled()
	if confirm != "":
		if k.keycode == KEY_Y or k.keycode == KEY_ENTER:
			_act("yes")
		elif k.keycode == KEY_N or k.keycode == KEY_ESCAPE:
			_act("no")
		return
	match k.keycode:
		KEY_ESCAPE:
			_close("cancel")
		KEY_ENTER, KEY_KP_ENTER:
			_act("ok")
		KEY_BACKSPACE:
			text = text.substr(0, maxi(text.length() - 1, 0))
		KEY_UP:
			scroll = maxi(scroll - 1, 0)
		KEY_DOWN:
			scroll = mini(scroll + 1, _max_scroll())
		_:
			var c := char(k.unicode).to_upper() if k.unicode > 0 else ""
			if c != "" and c in NAME_CHARS and text.length() < int(spec.max_len):
				text += c


func _draw_button(b: Dictionary) -> void:
	var held := _pressed == String(b.action) and _button_at(_mouse) == _pressed
	draw_entry(b.down if held else b.up)


func _draw() -> void:
	draw_entry(spec.body)
	if not saving:
		draw_entry(spec.load_title)
	for b in [spec.save if saving else spec.load] + spec.buttons:
		_draw_button(b)
	var y := float(spec.slider_y)
	if _max_scroll() > 0:
		y += float(scroll * int(spec.slider_range) / _max_scroll())
	draw_entry(spec.slider, Vector2(float(spec.slider_x), y))
	var fnt: Dictionary = spec.font
	var shown := text + ("_" if confirm == "" and int(_t * 2.0) % 2 == 0 else "")
	draw_font_text(fnt, shown, Vector2(float(spec.name_at[0]), float(spec.name_at[1])))
	var r: Array = spec.list_rect
	for i in int(spec.rows):
		var n := scroll + i
		if n < names.size():
			draw_font_text(fnt, names[n], Vector2(float(r[0]) + 3.0, float(r[1]) + 1.0 + i * float(spec.row_h)))
	if confirm != "":
		draw_entry(spec.confirm.box)
		if confirm == "overwrite":
			draw_entry(spec.confirm.overwrite)
		for b in spec.confirm.buttons:
			_draw_button(b)
	if cursor != null and Rect2(0, 0, W, H).has_point(_mouse):
		draw_entry(cursor, _mouse.floor())
