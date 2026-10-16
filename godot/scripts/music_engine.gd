class_name MusicEngine
extends Node
## Adaptive music, following the original sequencer's behaviour:
##  * songs loop forever (their XMIDI FOR/NEXT loop, unrolled into the Ogg's loop region);
##  * a requested change waits for the next bar of the current song;
##  * the transition table (COMBAT.DAT) picks, from the current song, the requested song and the
##    bar position inside the current phrase, either a cut or a link phrase - optionally played
##    over the still-running song (bit 7) - after which the requested song starts.
## Timing is taken from the audio clock (playback position + time since the last mix).

signal track_started(track: int)

const CUT_FADE := 0.06            # s, de-click when a song is cut at a bar line
const TAIL_FADE := 1.2            # s, release of a song after a link takes over

var set_name := ""
var tracks: Array = []            # per song: {file, end_s, loop_start_s, body_s, bars_s}
var tables := {}                  # {track_count, phrase_len, phrase_last, matrix, links, link_tracks}
var current := -1
var requested := -1
var state := 0                    # 0 idle, 1 playing, 2 waiting for the bar line, 3 link playing
var _main: AudioStreamPlayer
var _link: AudioStreamPlayer
var _fading: Array[AudioStreamPlayer] = []
var _loops := 0
var _last_pos := 0.0
var _measure_at_req := 0
var _link_ends_at := 0.0
var _clock := 0.0
var _loader: Callable


func setup(loader: Callable) -> void:
	_loader = loader
	_main = _player()
	_link = _player()


func _player() -> AudioStreamPlayer:
	var p := AudioStreamPlayer.new()
	p.bus = "Music"
	add_child(p)
	return p


## Switch to a music set (from audio.json); stops whatever is playing.
func use_set(new_set: String, set_tracks: Array, set_tables: Dictionary) -> void:
	if new_set == set_name:
		return
	stop(0.8)
	set_name = new_set
	tracks = set_tracks
	tables = set_tables
	current = -1
	requested = -1
	state = 0


func request(track: int) -> void:
	if track < 0 or track >= tracks.size() or tracks[track] == null:
		return
	requested = track
	if state == 0:
		_start(track)


func stop(fade := 1.5) -> void:
	for p in [_main, _link]:
		if p and p.playing:
			_fade_out(p, fade)
	state = 0
	current = -1
	requested = -1


## Song position in seconds counted across loops, from the audio clock.
func _position() -> float:
	if not _main.playing:
		return _last_pos
	var pos := _main.get_playback_position() + AudioServer.get_time_since_last_mix()
	if pos + 0.5 < _last_pos:
		_loops += 1                      # wrapped from the end back to the loop start
	_last_pos = pos
	return pos


## Bar count since the song started (like the driver's measure counter).
func measure() -> int:
	if current < 0:
		return 0
	var t: Dictionary = tracks[current]
	var pos := _position()
	var bars: Array = t.bars_s
	var n := 0
	for b in bars:
		if b <= pos + 1e-4:
			n += 1
	if t.loop_start_s != null and _loops > 0:
		var per_body := 0
		for b in bars:
			if b >= float(t.loop_start_s) - 1e-4:
				per_body += 1
		n += _loops * per_body
	return n


## A song without a loop has played to its musical end.
func finished() -> bool:
	if current < 0:
		return true
	var t: Dictionary = tracks[current]
	return t.loop_start_s == null and (not _main.playing or _position() >= float(t.end_s))


func _process(delta: float) -> void:
	_clock += delta
	match state:
		1:
			if current != requested:
				_measure_at_req = measure()
				state = 2
		2:
			if current == requested:
				state = 1
			elif measure() != _measure_at_req or finished():
				_resolve()
		3:
			if _clock >= _link_ends_at:
				_commit()


func _resolve() -> void:
	var n := int(tables.get("track_count", 0))
	var v := 0
	if n > 0 and current < n and requested < n:
		var a: int = tables.phrase_len[current]
		var r := (_measure_at_req % a) if a > 0 else 0
		var pos: int = r + 1 if r != 0 else int(tables.phrase_last[current])
		var e: int = tables.matrix[current * n + requested]
		if e != 0xFF and e < tables.links.size() and pos < tables.links[e].size():
			v = int(tables.links[e][pos])
	if OS.get_environment("SC_MUSIC_DEBUG") != "":
		print("MUSIC bar %d: %d -> %d  link value %d" % [_measure_at_req, current, requested, v])
	if v == 0:                                   # cut on the bar line
		_fade_out(_main, CUT_FADE)
		_start(requested)
		return
	var keep_main := (v & 0x80) != 0
	v &= 0x7F
	var link_tracks: Array = tables.get("link_tracks", [])
	if v > link_tracks.size() or link_tracks[v - 1] == null:
		requested = current                      # refused, as the original does
		state = 1
		return
	if not keep_main:
		_fade_out(_main, CUT_FADE)
	var lt: Dictionary = link_tracks[v - 1]
	_link.stream = _loader.call("music/" + String(lt.file), false, 0.0)
	_link.volume_db = 0.0
	_link.play()
	_link_ends_at = _clock + float(lt.end_s)
	state = 3


func _commit() -> void:
	if _main.playing:
		_fade_out(_main, TAIL_FADE)
	var old_link := _link                        # let the link's tail ring out
	_link = _player()
	old_link.finished.connect(old_link.queue_free)
	_start(requested)


func _start(track: int) -> void:
	var t: Dictionary = tracks[track]
	var looped: bool = t.loop_start_s != null
	if _main.playing:
		_fade_out(_main, CUT_FADE)
	_main = _player()
	_main.stream = _loader.call("music/" + String(t.file), looped, float(t.loop_start_s) if looped else 0.0)
	_main.volume_db = 0.0
	_main.play()
	_loops = 0
	_last_pos = 0.0
	current = track
	if requested < 0:
		requested = track
	state = 1
	track_started.emit(track)


## Fade a player out and free it (the main/link slots get fresh players).
func _fade_out(p: AudioStreamPlayer, time: float) -> void:
	if p == null or not p.playing:
		return
	if p == _main:
		_main = _player()
	elif p == _link:
		_link = _player()
	var tw := create_tween()
	tw.tween_property(p, "volume_db", -60.0, time)
	tw.tween_callback(p.queue_free)
