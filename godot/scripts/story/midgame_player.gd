extends Canvas320
## In-engine cutscenes (midgames), from tools/midgames.py, which runs the original's scene
## engine and records what it draws: a "scene" shot ticks at its own rate and has keyframes
## (the layers drawn from that tick on: image, position, optional clip rectangle), speech clips
## and music changes on given ticks, and an optional subtitle. "cards" shots fade text cards in
## and out over a background. Everything is drawn into the scene's viewport (the letterbox
## band) unless a layer has its own clip. Any key or click skips the whole cutscene.

var data := {}
var dir := ""
var shot := -1
var _t := 0.0                    # seconds into the current shot
var _tick := -1                  # current tick of the current scene
var _kf := -1                    # current keyframe
var _voice_i := 0
var _music_i := 0
var _voice: AudioStreamPlayer
var _done := false
var _next_scene := "res://scenes/boot.tscn"
var _test_shots := 0
var _speed := 1.0                # SC_MIDGAME_SPEED (tests)


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
	var start := OS.get_environment("SC_MIDGAME_SHOT")
	shot = int(start) - 2 if start != "" else -1
	if OS.get_environment("SC_MIDGAME_SPEED") != "":
		_speed = float(OS.get_environment("SC_MIDGAME_SPEED"))
	_next_shot()


func _next_shot() -> void:
	shot += 1
	_t = 0.0
	_tick = -1
	_kf = -1
	_voice_i = 0
	_music_i = 0
	if shot >= data.get("shots", []).size():
		_finish()


func _process(delta: float) -> void:
	if _done or data.is_empty() or shot >= data.shots.size():
		return
	delta *= _speed
	_t += delta
	var s: Dictionary = data.shots[shot]
	if String(s.type) == "scene":
		var target := mini(int(_t * float(s.tick_hz)), int(s.ticks))
		while _tick < target:
			_step_tick(s)
		if _tick >= int(s.ticks):
			_next_shot()
	elif String(s.type) == "cards":
		if _t >= _cards_length(s):
			_next_shot()
	queue_redraw()
	if OS.get_environment("SC_MIDGAME_TEST") != "" and int(_t * 2.0) != int((_t - delta) * 2.0) and int(_t * 2.0) % 4 == 1:
		_test_shots += 1
		capture("mid_%02d_%03d" % [shot + 1, _test_shots])


func _step_tick(s: Dictionary) -> void:
	_tick += 1
	var frames: Array = s.frames
	while _kf + 1 < frames.size() and int(frames[_kf + 1][0]) <= _tick:
		_kf += 1
	var voices: Array = s.get("voices", [])
	while _voice_i < voices.size() and int(voices[_voice_i][0]) <= _tick:
		_voice.stop()
		_voice.stream = AudioStreamWAV.load_from_file(GameData.path(dir + String(voices[_voice_i][1])))
		_voice.play()
		_voice_i += 1
	var music: Array = s.get("music", [])
	while _music_i < music.size() and int(music[_music_i][0]) <= _tick:
		var m: Dictionary = music[_music_i][1]
		Audio.music(String(m.set), int(m.track))
		_music_i += 1


func _cards_length(s: Dictionary) -> float:
	var total := 0.0
	for c in s.cards:
		total += float(c.in_s) + float(c.hold_s) + float(c.out_s) + float(c.after_s)
	return total


## Draw an image entry with its hotspot at `at`, clipped to the inclusive rectangle `clip`
## (original pixels).
func _draw_clipped(e: Dictionary, at: Vector2, clip: Rect2, mod: Color) -> void:
	var tex := texture(String(e.file), img_dir)
	if tex == null:
		return
	var r := Rect2(at + Vector2(float(e.x), float(e.y)), Vector2(float(e.w), float(e.h)))
	var c := r.intersection(clip)
	if c.size.x <= 0.0 or c.size.y <= 0.0:
		return
	var k := Vector2(tex.get_width() / r.size.x, tex.get_height() / r.size.y)
	var src := Rect2((c.position - r.position) * k, c.size * k)
	var tl := to_screen(c.position)
	var br := to_screen(c.end)
	draw_texture_rect_region(tex, Rect2(tl, br - tl), src, mod)


func _rect(v: Array, i: int) -> Rect2:
	return Rect2(float(v[i]), float(v[i + 1]), float(v[i + 2]) - float(v[i]) + 1.0, float(v[i + 3]) - float(v[i + 1]) + 1.0)


func _draw() -> void:
	draw_backdrop()
	if data.is_empty() or shot < 0 or shot >= data.shots.size():
		return
	var s: Dictionary = data.shots[shot]
	var fade := 1.0
	if s.has("fade_in_s"):
		fade = clampf(_t / float(s.fade_in_s), 0.0, 1.0)
	var mod := Color(fade, fade, fade)
	var view := _rect(s.view, 0) if s.has("view") else Rect2(0, 0, W, H)
	var images: Array = data.images
	if String(s.type) == "scene":
		if _kf >= 0:
			for l in s.frames[_kf][1]:
				var clip := _rect(l, 3) if l.size() > 3 else view
				_draw_clipped(images[int(l[0])], Vector2(float(l[1]), float(l[2])), clip, mod)
		var sub = s.get("subtitle")
		if sub != null and _tick >= int(sub[0]):
			draw_caption(String(sub[1]), 156.0, Color(0.95, 0.92, 0.8))
	else:
		for b in s.background:
			_draw_clipped(b, Vector2.ZERO, view, Color.WHITE)
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
	# the intro ends on the title music, which carries on into the menu
	var natural_end: bool = shot >= data.get("shots", []).size()
	if natural_end and not data.is_empty() and data.shots[-1].get("keep_music", false):
		GameData.set_meta("music_playing", true)
	else:
		Audio.stop_music(1.0)
	if OS.get_environment("SC_MIDGAME_TEST") != "":
		get_tree().quit()
		return
	get_tree().change_scene_to_file(_next_scene)
