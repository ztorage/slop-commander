extends Canvas320
## In-engine cutscenes (midgames), played from a timeline written by tools/midgames.py from the
## original's scene engine: each scene ticks at its own rate; objects are sprites placed relative
## to a parent, moving by a velocity each tick, animations advance one frame per tick; speech
## clips start on given ticks. "cards" shots fade text cards in and out over a background.
## Any key or click skips the whole cutscene.

var data := {}
var dir := ""
var shot := -1
var _t := 0.0                    # seconds into the current shot
var _tick := -1                  # last applied tick of the current scene
var _objs := {}                  # id -> {x, y, vel, parent, frames, anim, start}
var _order: Array = []           # draw order of ids
var _events: Array = []
var _ev := 0
var _voice: AudioStreamPlayer
var _done := false
var _next_scene := "res://scenes/boot.tscn"
var _test_shots := 0


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	var name_ := String(GameData.launch.get("midgame", "mid1"))
	_next_scene = String(GameData.launch.get("after", _next_scene))
	dir = "cinematics/%s/" % name_
	img_dir = dir
	var path := GameData.path(dir + "scenes.json")
	if not FileAccess.file_exists(path):
		_finish.call_deferred()
		return
	data = JSON.parse_string(FileAccess.get_file_as_string(path))
	_voice = AudioStreamPlayer.new()
	_voice.bus = "SFX"
	add_child(_voice)
	var m = data.get("music")
	if m != null:
		Audio.music(String(m.set), int(m.track))
	_next_shot()


func _next_shot() -> void:
	shot += 1
	_t = 0.0
	_tick = -1
	_objs.clear()
	_order.clear()
	_ev = 0
	if shot >= data.get("shots", []).size():
		_finish()
		return
	_events = data.shots[shot].get("events", [])


func _process(delta: float) -> void:
	if _done or data.is_empty() or shot >= data.shots.size():
		return
	_t += delta
	var s: Dictionary = data.shots[shot]
	if String(s.type) == "scene":
		var target := int(_t * float(s.tick_hz))
		while _tick < target and _tick < int(s.ticks):
			_step_tick()
		if _tick >= int(s.ticks):
			_next_shot()
	elif String(s.type) == "cards":
		if _t >= _cards_length(s):
			_next_shot()
	queue_redraw()
	if OS.get_environment("SC_MIDGAME_TEST") != "" and int(_t * 2.0) != int((_t - delta) * 2.0) and int(_t * 2.0) % 6 == 1:
		_test_shots += 1
		capture("mid_%02d_%02d" % [shot, _test_shots])


## One scene tick: the original moves objects after drawing; the events of a tick come first.
func _step_tick() -> void:
	# move (the previous tick's update)
	if _tick >= 0:
		for id in _objs:
			var o: Dictionary = _objs[id]
			o.x += float(o.vel[0])
			o.y += float(o.vel[1])
	_tick += 1
	while _ev < _events.size() and int(_events[_ev].t) <= _tick:
		var e: Dictionary = _events[_ev]
		if e.has("add"):
			var a: Dictionary = e.add
			_objs[a.id] = {"x": float(a.x), "y": float(a.y), "vel": a.vel, "parent": a.parent,
				"frames": a.frames, "anim": a.anim, "start": _tick}
			_order.append(a.id)
		elif e.has("vel"):
			if _objs.has(e.vel.id):
				_objs[e.vel.id].vel = e.vel.v
		elif e.has("remove"):
			_objs.erase(e.remove)
			_order.erase(e.remove)
		elif e.has("voice"):
			_voice.stop()
			_voice.stream = AudioStreamWAV.load_from_file(GameData.path(dir + String(e.voice)))
			_voice.play()
		_ev += 1


func _abs(id) -> Vector2:
	var o: Dictionary = _objs[id]
	var p := Vector2(o.x, o.y)
	if o.parent != null and _objs.has(o.parent):
		p += _abs(o.parent)
	return p


func _cards_length(s: Dictionary) -> float:
	var total := 0.0
	for c in s.cards:
		total += float(c.in_s) + float(c.hold_s) + float(c.out_s) + float(c.after_s)
	return total


func _draw() -> void:
	draw_backdrop()
	if data.is_empty() or shot < 0 or shot >= data.shots.size():
		return
	var s: Dictionary = data.shots[shot]
	var fade := 1.0
	if s.has("fade_in_s"):
		fade = clampf(_t / float(s.fade_in_s), 0.0, 1.0)
	var mod := Color(fade, fade, fade)
	if String(s.type) == "scene":
		for id in _order:
			var o: Dictionary = _objs[id]
			var fr: Array = o.frames
			if fr.is_empty():
				continue
			var i := 0
			if o.anim:
				i = clampi(_tick - int(o.start), 0, fr.size() - 1)
			draw_entry(fr[i], _abs(id), mod)
	else:
		for b in s.background:
			draw_entry(b)
		var t := _t
		for c in s.cards:
			var span := float(c.in_s) + float(c.hold_s) + float(c.out_s)
			if t < span:
				var a := 1.0
				if t < float(c.in_s):
					a = t / float(c.in_s)
				elif t > float(c.in_s) + float(c.hold_s):
					a = 1.0 - (t - float(c.in_s) - float(c.hold_s)) / float(c.out_s)
				draw_entry(c.img, Vector2.ZERO, Color(1, 1, 1, clampf(a, 0.0, 1.0)))
				break
			t -= span + float(c.after_s)
			if t < 0.0:
				break


func _gui_input(ev: InputEvent) -> void:
	if OS.get_environment("SC_MIDGAME_TEST") == "" and ev is InputEventMouseButton and ev.pressed:
		_finish()


func _unhandled_key_input(ev: InputEvent) -> void:
	if ev.pressed and OS.get_environment("SC_MIDGAME_TEST") == "":
		_finish()


func _finish() -> void:
	if _done:
		return
	_done = true
	if _voice:
		_voice.stop()
	Audio.stop_music(1.0)
	if OS.get_environment("SC_MIDGAME_TEST") != "":
		get_tree().quit()
		return
	get_tree().change_scene_to_file(_next_scene)
