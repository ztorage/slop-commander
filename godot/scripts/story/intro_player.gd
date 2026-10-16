extends Canvas320
## The CD intro movie: frames from gamedata/cinematics/intro (decoded from THEFLIC.FLX), the
## General MIDI score as the clock, and the original's sound clips at their frames.
## Any key or click skips it.

const DIR := "cinematics/intro/"

var info := {}
var _music: AudioStreamPlayer
var _voice: AudioStreamPlayer
var _tex: Texture2D
var _shown := -1
var _cue := 0
var _t := 0.0
var _done := false
var _next_scene := "res://scenes/boot.tscn"


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	var path := GameData.path(DIR + "intro.json")
	if not FileAccess.file_exists(path):
		_finish.call_deferred()
		return
	info = JSON.parse_string(FileAccess.get_file_as_string(path))
	Audio.stop_music(0.3)
	_voice = AudioStreamPlayer.new()
	_voice.bus = "SFX"
	add_child(_voice)
	_music = AudioStreamPlayer.new()
	_music.bus = "Music"
	add_child(_music)
	if info.get("music") != null:
		_music.stream = AudioStreamOggVorbis.load_from_file(GameData.path(DIR + String(info.music.file)))
		_music.play()


## Time in the movie: the music's playback position while it plays (keeps the sync), else the clock.
func _time(delta: float) -> float:
	if _music and _music.playing:
		return _music.get_playback_position() + AudioServer.get_time_since_last_mix()
	return _t + delta


func _process(delta: float) -> void:
	if _done or info.is_empty():
		return
	_t = _time(delta)
	var frames := int(info.frames)
	var f := mini(int(_t * float(info.fps)), frames - 1)
	var cues: Array = info.get("cues", [])
	while _cue < cues.size() and int(cues[_cue].frame) <= f + 1:
		_voice.stop()
		_voice.stream = AudioStreamWAV.load_from_file(GameData.path(DIR + String(cues[_cue].clip)))
		_voice.play()
		_cue += 1
	if f != _shown:
		_shown = f
		var img := Image.load_from_file(GameData.path(DIR + "f%04d.webp" % f))
		if img:
			_tex = ImageTexture.create_from_image(img)
		queue_redraw()
		if OS.get_environment("SC_INTRO_TEST") != "" and f % 150 == 0:
			capture("intro_%04d" % f)
	# hold the last frame until the score has finished
	var end := frames / float(info.fps) + float(info.get("hold_s", 2.0))
	if info.get("music") != null:
		end = maxf(end, float(info.music.length_s))
	if _t > end:
		_finish()


func _draw() -> void:
	draw_backdrop()
	if _tex:
		draw_texture_rect(_tex, frame_rect(), false)


func _gui_input(ev: InputEvent) -> void:
	if OS.get_environment("SC_INTRO_TEST") != "":
		return
	if ev is InputEventMouseButton and ev.pressed:
		_finish()


func _unhandled_key_input(ev: InputEvent) -> void:
	if ev.pressed and OS.get_environment("SC_INTRO_TEST") == "":
		_finish()


func _finish() -> void:
	if _done:
		return
	if OS.get_environment("SC_INTRO_TEST") != "":
		print("INTRO finished at t=%.2f, frame %d, %d cues played" % [_t, _shown, _cue])
	_done = true
	if _music:
		_music.stop()
	if _voice:
		_voice.stop()
	GameData.set_meta("intro_seen", true)
	if OS.get_environment("SC_INTRO_TEST") != "":
		get_tree().quit()
		return
	# the game's own intro (in-engine cutscene) follows the CD movie, as in the original
	if FileAccess.file_exists(GameData.path("cinematics/mid1/scenes.json")):
		GameData.launch = {"midgame": "mid1", "after": _next_scene}
		get_tree().change_scene_to_file("res://scenes/midgame.tscn")
		return
	get_tree().change_scene_to_file(_next_scene)
