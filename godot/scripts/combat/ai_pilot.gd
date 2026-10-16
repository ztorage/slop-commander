class_name AIPilot
extends RefCounted
## Enemy pilot. Flies the same FlightModel as the player through stick/throttle inputs.
## Priorities: avoid the ground > defend against missiles > attack (missiles, then guns).

const FT := 0.3048

var me: Aircraft
var skill := 0.7                   # 0..1: pull authority, reaction, accuracy
var target: Aircraft
var _decoy_timer := 0.0
var _missile_timer := 4.0
var _state := "attack"


func _init(a: Aircraft, skill_level := 0.7) -> void:
	me = a
	skill = skill_level


func update(dt: float, world: CombatWorld) -> void:
	var fm := me.fm
	_decoy_timer -= dt
	_missile_timer -= dt
	if target == null or not target.alive:
		target = _pick_target(world)
	var pos := me.global_position
	var vel := fm.velocity
	var agl := pos.y - world.ground_height(pos)
	fm.gear_down = false
	fm.throttle = 1.0

	# 1. ground avoidance: predicted height in 6 s
	var predicted := pos + vel * 6.0
	if agl < 400.0 or predicted.y < world.ground_height(predicted) + 250.0:
		_state = "climb"
		_fly_toward(pos + Vector3(vel.x, 0, vel.z).normalized() * 1000.0 + Vector3.UP * 600.0, 1.0)
		fm.afterburner = 1.0
		return

	# 2. missile defence: break perpendicular to the threat, dispense decoys
	var threats := world.missiles_tracking(me)
	if threats.size() > 0:
		_state = "defend"
		var m: Missile = threats[0]
		var to_m := m.global_position - pos
		var away := to_m.cross(Vector3.UP).normalized()
		if away.dot(vel) < 0.0:
			away = -away
		_fly_toward(pos + away * 1500.0 + Vector3.DOWN * 150.0, 1.0)
		fm.afterburner = 1.0
		if _decoy_timer <= 0.0 and to_m.length() < 3000.0:
			me.weapons.drop_decoy(world, m.infrared)
			_decoy_timer = randf_range(0.8, 1.4)
		return

	if target == null:
		_state = "patrol"
		_fly_toward(pos + Vector3(vel.x, 0, vel.z).normalized() * 3000.0, 0.4)
		fm.afterburner = 0.0
		return

	# 3. attack
	_state = "attack"
	var w := me.weapons
	var tpos := target.global_position
	var dist := pos.distance_to(tpos)
	var tof := dist / maxf(vel.length() + 600.0, 1.0)
	var aim := tpos + target.fm.velocity * tof * (0.9 if dist < 1500.0 else 0.4)
	_fly_toward(aim, skill)
	fm.afterburner = 1.0 if fm.airspeed < 220.0 or dist > 8000.0 else 0.0
	w.target = target
	var off_nose := (-me.global_basis.z).angle_to(tpos - pos)
	# missiles inside the weapon's envelope
	if _missile_timer <= 0.0 and not w.stations.is_empty():
		w.guns_mode = false
		var d: Dictionary = w.selected_data()
		var max_r := float(d.get("range_ft", 17700)) * FT
		if dist < max_r * 0.75 and dist > 900.0 and off_nose < deg_to_rad(12.0) and w.locked():
			w.fire(dt, world, true)
			_missile_timer = randf_range(8.0, 14.0) / maxf(skill, 0.3)
	# guns when close and nearly on target
	if dist < 900.0 and off_nose < deg_to_rad(3.0 + (1.0 - skill) * 3.0):
		w.guns_mode = true
		w.fire(dt, world, true)
	else:
		if w.guns_mode:
			w.fire(dt, world, false)
		w.guns_mode = w.stations.is_empty()


func _pick_target(world: CombatWorld) -> Aircraft:
	var best: Aircraft = null
	var bd := INF
	for a in world.aircraft:
		if a.alive and a.team != me.team and not a.ejected:
			var d := a.global_position.distance_to(me.global_position)
			if d < bd:
				bd = d
				best = a
	return best


## Roll the lift vector onto the target, then pull. `authority` scales the pull (0..1).
func _fly_toward(point: Vector3, authority: float) -> void:
	var fm := me.fm
	var local := me.global_transform.affine_inverse() * point   # x right, y up, -z forward
	var d := local.normalized()
	var angle_off := Vector3.FORWARD.angle_to(d)
	# roll so the target lies "above" the canopy (in the lift plane)
	var roll_err := atan2(d.x, d.y) if Vector2(d.x, d.y).length() > 0.05 else 0.0
	if angle_off < deg_to_rad(4.0):
		roll_err = atan2(d.x, 1.0) * 2.0   # nearly on the nose: small corrections only
	fm.stick.x = clampf(roll_err * 1.8, -1.0, 1.0)
	var pull := clampf(angle_off * 2.5, -0.3, 1.0)
	if absf(roll_err) > deg_to_rad(70.0) and angle_off > deg_to_rad(20.0):
		pull *= 0.3      # roll first, then pull
	if d.y < -0.2 and absf(roll_err) < deg_to_rad(30.0) and angle_off < deg_to_rad(25.0):
		pull = -0.2      # slightly below the nose and wings level: push
	fm.stick.y = pull * authority
	fm.rudder = clampf(d.x * 2.0, -1.0, 1.0) * 0.3 if angle_off < deg_to_rad(10.0) else 0.0
