class_name ConversationPlayer
extends Canvas320
## Plays one conversation script: wide shots with figures, close-ups (face built from a head,
## clothing, expression, animated mouth and blinks over a set), captions, recorded speech,
## yes/no questions and the wingman pick. Click, Space or Enter skips a line; Esc skips it all.

signal finished

const TEXT_TOP := CONV_Y + 128.0 + 6.0
const MOUTH_FRAMES := [2, 3, 4, 5, 6, 7, 8, 9, 10, 11]
const BLINK_FRAME := 21
const HAIR_FRAME := 1
const CLOTHES := [34, 35, 36]
const WING_PILOTS := ["billy2", "gwen2", "lyle2", "miguel2", "tex3"]
# click zones of the wingman line-up (x ranges, original pixels) and who stands there
const WING_ZONES := [[0, 60, "LYLE"], [64, 110, "MIGUEL"], [120, 170, "GWEN"], [175, 218, "BILLY"], [228, 268, "TEX"]]

var frames: Array = []
var index := -1
var mode := ""                  # "wide", "closeup", "choice", "wingman"
var set_name := ""
var figures: Array = []         # [{who, x, y}]
var talker := ""                # figure speaking in the wide shot
var face := {}                  # {who, expr, x, y}
var text := ""
var text_color := Color.WHITE
var _voice: AudioStreamPlayer
var _line_left := 0.0
var _mouth := -1
var _mouth_t := 0.0
var _blink_t := 3.0
var _blinking := 0.0
var _hover_choice := 0
static var _test_lines := 0


func play(conv_index: int) -> void:
	frames = Campaign.conversations[conv_index] if conv_index >= 0 and conv_index < Campaign.conversations.size() else []
	index = -1
	mode = ""
	set_name = ""
	figures.clear()
	visible = true
	_next()


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	_voice = AudioStreamPlayer.new()
	_voice.bus = "SFX"
	add_child(_voice)


func _next() -> void:
	while true:
		index += 1
		if index >= frames.size():
			_finish()
			return
		var f: Dictionary = frames[index]
		match String(f.type):
			"wide":
				mode = "wide"
				set_name = String(f.set)
				figures.clear()
				talker = ""
				text = ""
			"figure":
				figures.append({"who": String(f.who), "x": float(f.x), "y": float(f.y)})
			"figure_talk":
				mode = "wide"
				talker = String(f.who)
				var known := false
				for g in figures:
					known = known or g.who == talker
				if not known:
					figures.append({"who": talker, "x": float(f.x), "y": float(f.y)})
				_say(f)
				return
			"closeup":
				mode = "closeup"
				set_name = String(f.set)
				face = {"who": String(f.who), "expr": int(f.expr), "x": float(f.x), "y": float(f.y)}
				_say(f)
				return
			"more", "caption":
				_say(f)
				return
			"choice":
				if OS.get_environment("SC_STORY_TEST") != "":
					capture("conv_choice_%d" % index)
					Campaign.accepted = true    # tests accept every contract
					continue
				mode = "choice"
				text = "Accept the contract?"
				text_color = Color.WHITE
				_voice.stop()
				_mouth = -1
				queue_redraw()
				return
			"jump":
				index = int(f.to) - 1
			"wingman":
				if OS.get_environment("SC_STORY_TEST") != "":
					Campaign.wingman = "GWEN"
					continue
				mode = "wingman"
				text = "Choose your wingman"
				_voice.stop()
				queue_redraw()
				return
			_:
				pass


func _say(f: Dictionary) -> void:
	text = Campaign.substitute(String(f.get("text", "")))
	if f.has("color"):
		text_color = _palette_colour(int(f.color))
	var path := Campaign.voice_path(String(f.get("voice", "")))
	if OS.get_environment("SC_STORY_TEST") != "":
		_test_lines += 1
		if _test_lines % 4 == 1:
			capture("conv_%03d_%s" % [_test_lines, String(f.get("voice", "x"))])
		path = ""   # tests run silently and quickly
	_voice.stop()
	if path != "":
		_voice.stream = AudioStreamWAV.load_from_file(path)
		_voice.play()
	_line_left = 1.2 + text.length() * 0.055 if path == "" else 0.0
	if OS.get_environment("SC_STORY_TEST") != "":
		_line_left = 0.3
	queue_redraw()


func _palette_colour(i: int) -> Color:
	var pal: Array = Campaign.convart.get("text_palette", [])
	if i >= 0 and i < pal.size():
		var c := Color.html(String(pal[i]))
		# keep subtitles readable on dark sets
		return c.lightened(0.25) if c.get_luminance() < 0.45 else c
	return Color.WHITE


func _finish() -> void:
	_voice.stop()
	visible = false
	finished.emit()


func _process(delta: float) -> void:
	if not visible or mode in ["choice", "wingman", ""]:
		return
	var talking := _voice.playing
	_mouth_t -= delta
	if talking and _mouth_t <= 0.0:
		_mouth_t = randf_range(0.07, 0.13)
		_mouth = MOUTH_FRAMES[randi() % MOUTH_FRAMES.size()]
	elif not talking:
		_mouth = -1
	_blink_t -= delta
	if _blink_t <= 0.0:
		_blink_t = randf_range(2.5, 5.0)
		_blinking = 0.13
	_blinking = maxf(_blinking - delta, 0.0)
	if not talking:
		if _line_left > 0.0:
			_line_left -= delta
		else:
			_line_left = 0.6   # small pause after the speech ends
			_advance_after_pause()
	queue_redraw()


var _pausing := false


func _advance_after_pause() -> void:
	if _pausing:
		return
	_pausing = true
	await get_tree().create_timer(0.45).timeout
	_pausing = false
	if visible and not _voice.playing and mode not in ["choice", "wingman"]:
		_next()


func _gui_input(ev: InputEvent) -> void:
	if ev is InputEventMouseMotion and mode == "choice":
		var a := to_art(ev.position)
		_hover_choice = 1 if a.x < 160 else 2
		queue_redraw()
	if ev is InputEventMouseButton and ev.pressed and ev.button_index == MOUSE_BUTTON_LEFT:
		var a := to_art(ev.position)
		if mode == "choice":
			_choose(a.x < 160)
		elif mode == "wingman":
			for z in WING_ZONES:
				if a.x >= z[0] and a.x <= z[1]:
					Campaign.wingman = z[2]
					mode = "wide"
					_next()
					return
		else:
			_skip_line()
		accept_event()


func _unhandled_key_input(ev: InputEvent) -> void:
	if not visible or not ev.pressed:
		return
	var k: int = ev.keycode
	if mode == "choice" and k in [KEY_Y, KEY_N]:
		_choose(k == KEY_Y)
	elif k == KEY_ESCAPE and mode not in ["choice", "wingman"]:
		# skip to the next decision point (or the end)
		while index + 1 < frames.size() and String(frames[index + 1].type) not in ["choice", "wingman"]:
			index += 1
		_voice.stop()
		_next()
	elif k in [KEY_SPACE, KEY_ENTER, KEY_KP_ENTER] and mode not in ["choice", "wingman"]:
		_skip_line()
	get_viewport().set_input_as_handled()


func _skip_line() -> void:
	_voice.stop()
	_next()


func _choose(yes: bool) -> void:
	Campaign.accepted = yes
	var f: Dictionary = frames[index]
	mode = "closeup" if not face.is_empty() else "wide"
	if not yes:
		index = int(f.to) - 1
	_next()


# ---------------------------------------------------------------- drawing
func _draw() -> void:
	draw_backdrop()
	if mode == "wingman":
		_draw_set("s_wing")
		var row := 0
		for who in ["red1"] + WING_PILOTS:
			var fr: Array = Campaign.convart.get("figures", {}).get(who, [])
			if fr.size() > 0:
				draw_entry(fr[0], Vector2(0, CONV_Y))
			row += 1
		for z in WING_ZONES:
			var c := to_screen(Vector2((z[0] + z[1]) * 0.5, CONV_Y + 168))
			_label(String(z[2]).capitalize(), c, Color(1, 0.9, 0.5))
		draw_caption(text, TEXT_TOP + 16, Color.WHITE)
		return
	_draw_set(set_name)
	if mode == "wide" or (mode == "choice" and face.is_empty()):
		for g in figures:
			var fr: Array = Campaign.convart.get("figures", {}).get(g.who, [])
			var at := Vector2(g.x, g.y + CONV_Y)
			if fr.size() > 0:
				draw_entry(fr[0], at)
			if g.who == talker and _voice.playing and fr.size() > 1:
				draw_entry(fr[1 + (Time.get_ticks_msec() / 110) % (fr.size() - 1)], at)
	elif not face.is_empty():
		_draw_face()
	if mode == "choice":
		_draw_choice()
	elif text != "":
		draw_caption(text, TEXT_TOP, text_color)


func _draw_set(name_: String) -> void:
	for l in Campaign.convart.get("sets", {}).get(name_, []):
		draw_entry(l, Vector2(0, CONV_Y))


func _draw_face() -> void:
	var fr: Array = Campaign.convart.get("faces", {}).get(face.who, [])
	if fr.is_empty():
		return
	var at := Vector2(face.x, face.y + CONV_Y)
	var at_frame := func(i: int):
		if i >= 0 and i < fr.size() and fr[i] != null:
			draw_entry(fr[i], at)
			return true
		return false
	at_frame.call(0)            # face
	at_frame.call(HAIR_FRAME)   # hair, for the heads drawn without it
	for c in CLOTHES:
		if at_frame.call(c):
			break
	if int(face.expr) != 255:
		at_frame.call(int(face.expr))
	if _mouth >= 0:
		at_frame.call(_mouth)
	if _blinking > 0.0:
		at_frame.call(BLINK_FRAME)


func _draw_choice() -> void:
	draw_caption(text, TEXT_TOP, Color.WHITE, 1)
	for i in 2:
		var x0 := 40.0 if i == 0 else 200.0
		var tl := to_screen(Vector2(x0, TEXT_TOP + 18))
		var br := to_screen(Vector2(x0 + 80, TEXT_TOP + 36))
		var hot := _hover_choice == i + 1
		draw_rect(Rect2(tl, br - tl), Color(0.15, 0.2, 0.15, 0.9) if hot else Color(0.08, 0.08, 0.08, 0.9))
		draw_rect(Rect2(tl, br - tl), Color(0.8, 0.9, 0.6) if hot else Color(0.5, 0.5, 0.5), false, 2.0)
		_label("YES  (Y)" if i == 0 else "NO  (N)", (tl + br) * 0.5, Color.WHITE)


func _label(s: String, centre: Vector2, colour: Color) -> void:
	var font := get_theme_default_font()
	var fs := int(clampf(px() * 7.0, 12.0, 32.0))
	var w := font.get_string_size(s, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
	var pos := centre + Vector2(-w * 0.5, fs * 0.35)
	draw_string_outline(font, pos, s, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, 3, Color(0, 0, 0, 0.9))
	draw_string(font, pos, s, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, colour)
