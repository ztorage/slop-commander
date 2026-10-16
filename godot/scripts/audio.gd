extends Node
## Audio: original music (rendered from the CD's General MIDI scores), digitized sound effects
## and radio speech, all loaded at runtime from gamedata/audio.
##
## Buses: Music, SFX, Engine (muffled: low-pass, half volume by default), Radio (band-pass +
## light distortion, like a cockpit radio).

const MENU_TRACK := ["gameflow", 7]
const ENGINE_LEVEL := 0.5          # engine loudness relative to other effects (0.5 = 50%)
const ENGINE_LOWPASS_HZ := 1800.0  # muffling
const COMBAT_TRACK := 4
const CRASH_TRACK := 11
const VICTORY_TRACK := 12

var index := {}
var _cache := {}
var engine: MusicEngine          # adaptive music (sets, loops, bar-synced link phrases)
var _radio: AudioStreamPlayer
var _radio_queue: Array = []
var _gun: AudioStreamWAV


func _ready() -> void:
	_make_bus("Music", -6.0)
	_make_bus("SFX", -2.0)
	_make_bus("Radio", 0.0)
	_make_bus("Engine", -2.0 + linear_to_db(ENGINE_LEVEL))
	var lp := AudioEffectLowPassFilter.new()
	lp.cutoff_hz = ENGINE_LOWPASS_HZ
	AudioServer.add_bus_effect(AudioServer.get_bus_index("Engine"), lp)
	var radio_bus := AudioServer.get_bus_index("Radio")
	var bp := AudioEffectBandPassFilter.new()
	bp.cutoff_hz = 1600.0
	bp.resonance = 0.6
	AudioServer.add_bus_effect(radio_bus, bp)
	var dist := AudioEffectDistortion.new()
	dist.mode = AudioEffectDistortion.MODE_CLIP
	dist.drive = 0.15
	dist.post_gain = -2.0
	AudioServer.add_bus_effect(radio_bus, dist)
	engine = MusicEngine.new()
	add_child(engine)
	engine.setup(_load_music)
	_radio = _player("Radio")
	_radio.finished.connect(_next_radio)
	if GameData.is_ready() and FileAccess.file_exists(GameData.path("audio/audio.json")):
		index = JSON.parse_string(FileAccess.get_file_as_string(GameData.path("audio/audio.json")))
	_gun = _make_gun_loop()


func _make_bus(bus_name: String, db: float) -> void:
	if AudioServer.get_bus_index(bus_name) >= 0:
		return
	AudioServer.add_bus()
	var i := AudioServer.bus_count - 1
	AudioServer.set_bus_name(i, bus_name)
	AudioServer.set_bus_send(i, "Master")
	AudioServer.set_bus_volume_db(i, db)


func _player(bus: String) -> AudioStreamPlayer:
	var p := AudioStreamPlayer.new()
	p.bus = bus
	add_child(p)
	return p


func _load(rel: String) -> AudioStream:
	if _cache.has(rel):
		return _cache[rel]
	var path := GameData.path("audio/" + rel)
	var s: AudioStream = null
	if FileAccess.file_exists(path):
		if rel.ends_with(".wav"):
			s = AudioStreamWAV.load_from_file(path)
		elif rel.ends_with(".mp3"):
			s = AudioStreamMP3.load_from_file(path)
	_cache[rel] = s
	return s


# ---------------------------------------------------------------- music
## Request a song of a music set ("combat", "gameflow", "midgames"). Within a set with a
## transition table the change happens on the next bar, through the original link phrases.
func music(set_name: String, track: int, _fade := 2.0) -> void:
	var tracks: Array = index.get("music", {}).get(set_name, [])
	if tracks.is_empty():
		return
	engine.use_set(set_name, tracks, index.get("music_sets", {}).get(set_name, {}))
	engine.request(track)


func stop_music(fade := 1.5) -> void:
	engine.stop(fade)


func _load_music(rel: String, looped: bool, loop_offset: float) -> AudioStream:
	var key := rel + ("#loop" if looped else "")
	if _cache.has(key):
		return _cache[key]
	var path := GameData.path("audio/" + rel)
	var s: AudioStreamOggVorbis = AudioStreamOggVorbis.load_from_file(path) if FileAccess.file_exists(path) else null
	if s:
		s.loop = looped
		s.loop_offset = loop_offset
	_cache[key] = s
	return s


# ---------------------------------------------------------------- effects
func sfx_stream(sfx_name: String) -> AudioStream:
	var f = index.get("sfx", {}).get(sfx_name)
	return _load("sfx/" + String(f)) if f != null else null


## Play a sound effect; positional when `at` is a Vector3 (needs `parent` in the 3D scene).
func sfx(sfx_name: String, at = null, parent: Node = null, volume_db := 0.0, pitch := 1.0) -> void:
	var s := sfx_stream(sfx_name)
	if s == null:
		return
	if at is Vector3 and parent:
		var p := AudioStreamPlayer3D.new()
		p.stream = s
		p.bus = "SFX"
		p.volume_db = volume_db
		p.pitch_scale = pitch
		p.unit_size = 60.0
		p.max_distance = 12000.0
		p.attenuation_model = AudioStreamPlayer3D.ATTENUATION_INVERSE_DISTANCE
		parent.add_child(p)
		p.global_position = at
		p.finished.connect(p.queue_free)
		p.play()
	else:
		var p := _player("SFX")
		p.stream = s
		p.volume_db = volume_db
		p.pitch_scale = pitch
		p.finished.connect(p.queue_free)
		p.play()


## A looping copy of a sound effect (engine sounds).
func loop_stream(sfx_name: String) -> AudioStream:
	var s := sfx_stream(sfx_name) as AudioStreamWAV
	if s == null:
		return null
	var l := s.duplicate() as AudioStreamWAV
	l.loop_mode = AudioStreamWAV.LOOP_FORWARD
	l.loop_begin = 0
	l.loop_end = l.data.size()   # 8-bit mono: one byte per frame
	return l


func gun_stream() -> AudioStream:
	return _gun


## The cannon's buzz: a short procedurally generated loop (sawtooth at the firing rate + noise).
func _make_gun_loop() -> AudioStreamWAV:
	var rate := 22050
	var n := rate / 10   # 0.1 s = 10 rounds at 100 rounds/s
	var data := PackedByteArray()
	data.resize(n * 2)
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	for i in n:
		var t := float(i) / rate
		var phase := fmod(t * 100.0, 1.0)
		var v := (1.0 - phase) * 0.55 * exp(-phase * 3.0) + rng.randf_range(-0.25, 0.25) * (1.0 - phase)
		data.encode_s16(i * 2, int(clampf(v, -1.0, 1.0) * 26000.0))
	var w := AudioStreamWAV.new()
	w.format = AudioStreamWAV.FORMAT_16_BITS
	w.mix_rate = rate
	w.data = data
	w.loop_mode = AudioStreamWAV.LOOP_FORWARD
	w.loop_end = n
	return w


# ---------------------------------------------------------------- radio speech
## Queue a radio line by voice id (profile SPCH) and message number.
func speech(voice: int, msg: int) -> void:
	var f = index.get("speech", {}).get("%d_%d" % [voice, msg])
	if f == null:
		return
	_radio_queue.append("speech/" + String(f))
	if not _radio.playing:
		_next_radio()


func _next_radio() -> void:
	if _radio_queue.is_empty():
		return
	_radio.stream = _load(_radio_queue.pop_front())
	_radio.play()
