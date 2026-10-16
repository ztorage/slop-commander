class_name FlightAudio
extends Node
## In-flight sound: the player's engine (military + afterburner loops following the throttle),
## cannon, gear and touchdown cues, positional engine noise on other aircraft, and the music
## state machine of the original (mission tune, combat track, crash, victory).

const COMBAT_RANGE := 15000.0

var player: Aircraft
var world: CombatWorld
var mission: MissionRunner
var cruise_track := 1
var _mil: AudioStreamPlayer
var _afb: AudioStreamPlayer
var _gun: AudioStreamPlayer
var _was_gear := true
var _was_ground := true
var _ai_engines := {}            # Aircraft -> AudioStreamPlayer3D


func setup(p: Aircraft, w: CombatWorld, m: MissionRunner) -> void:
	player = p
	world = w
	mission = m
	if m:
		cruise_track = clampi(int(m.data.get("tune", 1)), 0, 3)
	_mil = _loop("engine_mil")
	_afb = _loop("engine_afb")
	_gun = AudioStreamPlayer.new()
	_gun.bus = "SFX"
	_gun.stream = Audio.gun_stream()
	_gun.volume_db = -6.0
	add_child(_gun)
	_was_gear = p.fm.gear_down
	_was_ground = p.fm.on_ground


func _loop(sfx_name: String) -> AudioStreamPlayer:
	var a := AudioStreamPlayer.new()
	a.bus = "Engine"
	a.stream = Audio.loop_stream(sfx_name)
	a.volume_db = -60.0
	add_child(a)
	if a.stream:
		a.play()
	return a


func _process(delta: float) -> void:
	if player == null:
		return
	var fm := player.fm
	var running := player.alive and not player.ejected and fm.fuel > 0.0
	var thr := fm.throttle if running else 0.0
	var ab := fm.afterburner if running and fm.has_afterburner else 0.0
	_mil.volume_db = lerpf(_mil.volume_db, linear_to_db(clampf(0.25 + thr * 0.6, 0.001, 1.0)) if running else -60.0, delta * 3.0)
	_mil.pitch_scale = lerpf(_mil.pitch_scale, 0.75 + thr * 0.45, delta * 2.0)
	_afb.volume_db = lerpf(_afb.volume_db, linear_to_db(maxf(ab, 0.001)) if ab > 0.0 else -60.0, delta * 4.0)
	var firing := running and player.weapons.selected_kind() == "gun" and Input.is_action_pressed("fire") and player.weapons.gun_rounds > 0
	if firing and not _gun.playing:
		_gun.play()
	elif not firing and _gun.playing:
		_gun.stop()
	if fm.gear_down != _was_gear:
		Audio.sfx("gear_down" if fm.gear_down else "gear_up")
		_was_gear = fm.gear_down
	if fm.on_ground and not _was_ground and player.alive:
		Audio.sfx("touch_down")
	_was_ground = fm.on_ground
	_update_ai_engines()
	_update_music()


## Engine noise on other aircraft, positional with Doppler (fly-bys).
func _update_ai_engines() -> void:
	for a in world.aircraft:
		if a == player:
			continue
		if a.alive and not _ai_engines.has(a):
			var p := AudioStreamPlayer3D.new()
			p.stream = Audio.loop_stream("engine_mil")
			p.bus = "Engine"
			p.unit_size = 40.0
			p.max_distance = 6000.0
			p.doppler_tracking = AudioStreamPlayer3D.DOPPLER_TRACKING_PHYSICS_STEP
			p.volume_db = -4.0
			a.add_child(p)
			if p.stream:
				p.play()
			_ai_engines[a] = p
		elif not a.alive and _ai_engines.has(a):
			(_ai_engines[a] as AudioStreamPlayer3D).stop()
			_ai_engines.erase(a)


func _update_music() -> void:
	if mission and mission.over:
		Audio.music("combat", Audio.VICTORY_TRACK if mission.won else Audio.CRASH_TRACK)
	elif not player.alive or player.ejected:
		Audio.music("combat", Audio.CRASH_TRACK)
	elif _in_combat():
		Audio.music("combat", Audio.COMBAT_TRACK)
	else:
		Audio.music("combat", cruise_track, 4.0)


func _in_combat() -> bool:
	if world.missiles_tracking(player).size() > 0:
		return true
	for a in world.aircraft:
		if a.alive and a.team != player.team and a.global_position.distance_to(player.global_position) < COMBAT_RANGE:
			return true
	return false
