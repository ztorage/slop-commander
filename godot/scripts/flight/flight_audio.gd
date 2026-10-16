class_name FlightAudio
extends Node
## In-flight sound: the player's engine (military + afterburner loops following the throttle),
## cannon, gear and touchdown cues, positional engine noise on other aircraft, and the music
## state machine of the original (mission tune, combat track, crash, victory).


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


# ---------------------------------------------------------------- music director
## Track numbers of the combat set and the rules for choosing them, as in the original:
const T_MISSILE := 9          # a missile is guiding on the player
const T_ON_TAIL := 5          # player sitting on an enemy's tail
const T_DAMAGE_HEAVY := 7     # >= 75% damage
const T_DAMAGE_MEDIUM := 6    # >= 35% damage
const T_AIR_COMBAT := 4
const T_GROUND_THREAT := 19
const T_ALL_CLEAR := 13       # enemies gone after a fight
const T_VICTORY := 12
const T_FRIEND_LOST := 15
const T_KILL_AIR := 16
const T_KILL_VEHICLE := 17
const T_KILL_OTHER := 18
const T_CRASH := 11
const T_DEAD := 20
const THREAT_RANGE := 18520.0 * 0.3048
const TAIL_RANGE := 3500.0 * 0.3048
const STINGERS := [14, 15, 16, 17, 18]

var _director_timer := 0.0
var _fought := false               # "combat happened" flag (cleared by the all-clear track)
var _started := false
var _end_music := false


func _connect_events() -> void:
	if world.aircraft_destroyed.is_connected(_on_aircraft_destroyed):
		return
	world.aircraft_destroyed.connect(_on_aircraft_destroyed)
	world.ground_destroyed.connect(_on_ground_destroyed)


func _update_music() -> void:
	var eng := Audio.engine
	if not _started:
		_started = true
		_connect_events()
		Audio.music("combat", cruise_track)
		return
	if _end_music:
		return
	if mission and mission.over:
		_end_music = true
		Audio.music("combat", T_VICTORY if mission.won else T_DEAD)
		return
	if not player.alive or player.ejected:
		_end_music = true
		Audio.music("combat", T_CRASH if player.fm.crashed and not player.ejected else T_DEAD)
		return
	_director_timer -= get_process_delta_time()
	if _director_timer > 0.0:
		return
	_director_timer = 0.25
	if eng.current != eng.requested:
		return                                    # a transition is pending
	if eng.current in STINGERS and not eng.finished():
		return                                    # let a punctuation play out
	var threat := _threats()
	if threat != 0:
		_fought = true
		var damage := 100.0 * (1.0 - player.hp / maxf(player.max_hp, 1.0))
		var t := T_AIR_COMBAT if threat & 1 else T_GROUND_THREAT
		if world.missiles_tracking(player).size() > 0:
			t = T_MISSILE
		elif _on_enemy_tail():
			t = T_ON_TAIL
		elif damage >= 75.0:
			t = T_DAMAGE_HEAVY
		elif damage >= 35.0:
			t = T_DAMAGE_MEDIUM
		Audio.music("combat", t)
	elif _fought:
		_fought = false
		Audio.music("combat", T_ALL_CLEAR)        # enemies gone after a fight
	elif eng.current in STINGERS:
		Audio.music("combat", cruise_track)       # resume after a punctuation


## Bit 1: an enemy aircraft within ~3 nm; bit 2: an armed enemy ground site within ~3 nm.
func _threats() -> int:
	var bits := 0
	var p := player.global_position
	for a in world.aircraft:
		if a.alive and a.team != player.team and a.global_position.distance_to(p) < THREAT_RANGE:
			bits |= 1
	for u in world.ground_units:
		if u.alive and u.team >= 0 and u.team != player.team and not u.weapon.is_empty() \
				and u.global_position.distance_to(p) < THREAT_RANGE:
			bits |= 2
	return bits


## An enemy aircraft close ahead of the player's nose, with the player behind it.
func _on_enemy_tail() -> bool:
	var p := player.global_position
	var fwd := -player.global_basis.z
	for a in world.aircraft:
		if not a.alive or a.team == player.team:
			continue
		var rel := a.global_position - p
		if rel.length() > TAIL_RANGE or fwd.angle_to(rel) > deg_to_rad(45.0):
			continue
		if rel.dot(-a.global_basis.z) > 0.0:      # the enemy points away from us
			return true
	return false


func _on_aircraft_destroyed(a: Aircraft) -> void:
	if a == player:
		return
	if a.team == player.team:
		Audio.music("combat", T_FRIEND_LOST)
	elif a.last_attacker == player:
		Audio.music("combat", T_KILL_AIR)


func _on_ground_destroyed(u: GroundUnit) -> void:
	if u.team < 0 or u.team == player.team or u.last_attacker != player:
		return
	Audio.music("combat", T_KILL_VEHICLE if String(u.data.get("kind", "")) == "grnd" else T_KILL_OTHER)
