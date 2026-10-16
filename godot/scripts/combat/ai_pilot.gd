class_name AIPilot
extends RefCounted
## Computer pilot. Flies the same FlightModel as the player through stick/throttle inputs.
## Priorities: avoid the ground > defend against missiles > mission objective (from the
## mission script, if any) > engage nearby enemies.

const FT := 0.3048
const OP := {"TAKEOFF": 0xA1, "LAND": 0xA2, "FLY_WP": 0xA5, "FLY_AREA": 0xA6, "DESTROY": 0xA7,
	"DEFEND_TGT": 0xA8, "DEFEND_AREA": 0xA9, "FOLLOW": 0xAA, "PATROL": 0xBF}

var me: Aircraft
var skill := 0.7                   # 0..1: pull authority, reaction, accuracy
var target: Aircraft
var mission_actor: MissionActor    # set when flying in a mission
var runner: MissionRunner
var pacified := false
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
	if mission_actor and not mission_actor.active:
		_idle()
		return
	var pos := me.global_position
	var vel := fm.velocity
	var agl := pos.y - world.ground_height(pos)
	var command: int = mission_actor.command if mission_actor else 0

	if fm.on_ground:
		if mission_actor == null or command == OP.TAKEOFF or command == OP.FOLLOW or command == OP.FLY_WP:
			_takeoff_roll()
		else:
			_idle()
		return
	if agl > 60.0:
		fm.gear_down = false

	# 1. ground avoidance: predicted height in 6 s
	var predicted := pos + vel * 6.0
	if command != OP.LAND and (agl < 120.0 or predicted.y < world.ground_height(predicted) + 80.0):
		_state = "climb"
		_fly_toward(pos + Vector3(vel.x, 0, vel.z).normalized() * 1000.0 + Vector3.UP * 600.0, 1.0)
		fm.throttle = 1.0
		fm.afterburner = 1.0 if fm.airspeed < 150.0 else 0.0
		return

	# 2. missile defence
	if defend(world):
		return

	# 3. mission objective
	if mission_actor:
		if _objective(command, world):
			return
	# 4. engage enemies (free hunting, or no mission)
	if target == null or not target.alive:
		target = _pick_target(world, 25000.0 if mission_actor else INF)
	if target and not pacified:
		_attack(dt, world)
	else:
		_state = "patrol"
		_cruise(pos + Vector3(vel.x, 0, vel.z).normalized() * 3000.0 + Vector3.UP * (1500.0 - agl) * 0.3)


## Missile defence: break perpendicular to the threat and dispense decoys. True if defending.
func defend(world: CombatWorld) -> bool:
	var fm := me.fm
	var pos := me.global_position
	var m: Missile = null
	var md := 5000.0
	for t in world.missiles_tracking(me):
		var d: float = t.global_position.distance_to(pos)
		var closing: bool = (t.velocity - fm.velocity).dot(pos - t.global_position) > 0.0
		if d < md and closing:
			md = d
			m = t
	if m == null:
		return false   # only break once a missile is actually close
	_state = "defend"
	var to_m := m.global_position - pos
	var away := to_m.cross(Vector3.UP).normalized()
	if away.dot(fm.velocity) < 0.0:
		away = -away
	var agl := pos.y - world.ground_height(pos)
	var vertical := Vector3.DOWN * 150.0 if agl > 600.0 else Vector3.UP * 200.0
	_fly_toward(pos + away * 1500.0 + vertical, 1.0)
	fm.throttle = 1.0
	fm.afterburner = 1.0
	if _decoy_timer <= 0.0 and md < 3000.0:
		me.weapons.drop_decoy(world, m.infrared)
		_decoy_timer = randf_range(0.6, 1.1)
	return true


## Returns true when the objective fully controlled the aircraft this tick.
func _objective(command: int, world: CombatWorld) -> bool:
	var a := mission_actor
	var pos := me.global_position
	match command:
		OP.TAKEOFF:
			_state = "takeoff"
			var ahead := -me.global_basis.z
			_cruise(pos + Vector3(ahead.x, 0, ahead.z).normalized() * 3000.0 + Vector3.UP * 500.0, 1.0)
			return true
		OP.FLY_WP:
			_state = "waypoint"
			var p := runner.spot_world(a.command_arg)
			p.y = maxf(p.y, world.ground_height(p) + 300.0)
			if _hostiles_near(world, 8000.0):
				return false
			_cruise(p)
			return true
		OP.FLY_AREA, OP.DEFEND_AREA, OP.PATROL, 0xAC:
			var c := runner.area_world(a.command_arg) if command != OP.PATROL else pos
			c.y = maxf(world.ground_height(c) + 1200.0, c.y)
			if _hostiles_near(world, 15000.0):
				return false
			if (c - pos).length() < 4000.0:
				c += me.global_basis.x * 3000.0   # orbit
			_state = "patrol"
			_cruise(c)
			return true
		OP.LAND:
			return _land(world)
		OP.DESTROY:
			if a.target and a.target.alive() and a.target.node is Aircraft:
				target = a.target.node
				_attack(0.1, world)
				return true
			return false
		OP.DEFEND_TGT:
			if _hostiles_near(world, 12000.0):
				return false
			if a.target and a.target.node:
				_formation(a.target.node, Vector3(600, 150, 600) * FT * 3.0)
				return true
			return false
		OP.FOLLOW:
			var leader := runner.actor_by_id(a.command_arg)
			if leader and leader.node and leader.alive():
				if _hostiles_near(world, 6000.0) and not pacified:
					return false
				var f: Array = a.part.get("formation_ft", [300, -300, 0])
				_formation(leader.node, Vector3(f[0], f[2], -f[1]) * FT)
				return true
			return false
	return false


func _idle() -> void:
	var fm := me.fm
	fm.throttle = 0.0
	fm.afterburner = 0.0
	fm.stick = Vector2.ZERO
	fm.brakes = true


func _takeoff_roll() -> void:
	var fm := me.fm
	_state = "takeoff"
	fm.brakes = false
	fm.throttle = 1.0
	fm.afterburner = 0.0
	fm.stick = Vector2(0, 0.6 if fm.airspeed > 75.0 else 0.0)
	fm.rudder = 0.0


## Steer to a point at cruise power.
func _cruise(point: Vector3, power := 0.8) -> void:
	me.fm.throttle = power
	me.fm.afterburner = 0.0
	_steer(point)


## Navigation autopilot: bank toward the point's bearing (max `max_bank`), and command load
## factor from the flight-path-angle error plus turn compensation. Never goes inverted.
func _steer(point: Vector3, max_bank := deg_to_rad(55.0), climb_limit := 0.25) -> void:
	var fm := me.fm
	var pos := me.global_position
	var to := point - pos
	var fwd := -fm.basis.z
	var herr := wrapf(atan2(to.x, -to.z) - atan2(fwd.x, -fwd.z), -PI, PI)   # + = point to the right
	var bank_cmd := clampf(herr * 2.5, -max_bank, max_bank)
	var bank := -fm.basis.get_euler(EULER_ORDER_YXZ).z                       # right wing down +
	fm.stick.x = clampf((bank_cmd - bank) * 2.0, -1.0, 1.0)
	var horiz := maxf(Vector2(to.x, to.z).length(), 1.0)
	var gamma_cmd := clampf(atan2(to.y, horiz), -climb_limit, climb_limit)
	var vdir := fm.velocity.normalized() if fm.airspeed > 1.0 else fwd
	var gamma := asin(clampf(vdir.y, -1.0, 1.0))
	var n_des := 1.0 / cos(clampf(bank, -1.2, 1.2)) + (gamma_cmd - gamma) * fm.airspeed / 9.81 * 1.2
	fm.stick.y = clampf((n_des - 1.0) / maxf(fm.max_g - 1.0, 1.0), -0.3, 0.8)
	fm.rudder = 0.0


## Hold a slot (in the leader's frame: x right, y up, -z ahead) by steering ahead of it.
func _formation(leader: Node3D, slot: Vector3) -> void:
	_state = "formation"
	var lb := leader.global_basis
	var lv: Vector3 = leader.get("velocity_world") if leader.get("velocity_world") != null else Vector3.ZERO
	var want := leader.global_position + lb * slot
	var aim := want + lv * 2.0
	var err := want - me.global_position
	var along := err.dot(lv.normalized()) if lv.length() > 1.0 else 0.0
	_steer(aim, deg_to_rad(65.0), 0.35)
	var speed_err := lv.length() + clampf(along * 0.15, -40.0, 40.0) - me.fm.airspeed
	me.fm.throttle = clampf(0.6 + speed_err * 0.03, 0.0, 1.0)
	me.fm.afterburner = 0.4 if speed_err > 40.0 else 0.0
	me.fm.airbrake = speed_err < -30.0


## Landing: fly to the approach spot, then down a 3-degree glide path to the touchdown spot
## (second operand of the LAND opcode) along the runway, flare and roll out.
var _approach_passed := false


func _land(world: CombatWorld) -> bool:
	_state = "landing"
	var a := mission_actor
	var fm := me.fm
	var pos := me.global_position
	var approach := runner.spot_world(a.command_arg)
	var touchdown := runner.spot_world(a.command_arg2) if a.command_arg2 != 255 else approach
	touchdown.y = world.ground_height(touchdown)
	if fm.on_ground:
		fm.throttle = 0.0
		fm.afterburner = 0.0
		fm.brakes = true
		fm.stick = Vector2.ZERO
		return true
	var to_app := Vector2(approach.x - pos.x, approach.z - pos.z).length()
	if not _approach_passed and to_app > 1500.0 and a.command_arg2 != 255:
		approach.y = maxf(approach.y, world.ground_height(approach) + 250.0)
		_steer(approach, deg_to_rad(40.0), 0.15)
		fm.throttle = 0.55
		fm.gear_down = to_app < 6000.0
		return true
	_approach_passed = true
	var runway_dir := Vector3(touchdown.x - approach.x, 0, touchdown.z - approach.z).normalized()
	var flat := Vector2(touchdown.x - pos.x, touchdown.z - pos.z).length()
	var agl := pos.y - world.ground_height(pos)
	var glide_alt := touchdown.y + flat * tan(deg_to_rad(3.0))
	var aim := touchdown + runway_dir * 400.0
	aim.y = glide_alt - 20.0
	_steer(aim, deg_to_rad(25.0), 0.1)
	fm.gear_down = true
	fm.throttle = 0.3 if agl > 40.0 else 0.0
	fm.airbrake = fm.airspeed > fm.wing_area * 0.0 + 90.0
	if agl < 12.0:
		fm.stick = Vector2(0, 0.25)   # flare
	return true


func _hostiles_near(world: CombatWorld, radius: float) -> bool:
	if pacified:
		return false
	var t := _pick_target(world, radius)
	if t:
		target = t
		return true
	return false


func _attack(dt: float, world: CombatWorld) -> void:
	_state = "attack"
	var fm := me.fm
	var w := me.weapons
	var pos := me.global_position
	var vel := fm.velocity
	var tpos := target.global_position
	var dist := pos.distance_to(tpos)
	var tof := dist / maxf(vel.length() + 600.0, 1.0)
	var aim := tpos + target.fm.velocity * tof * (0.9 if dist < 1500.0 else 0.4)
	_fly_toward(aim, skill)
	fm.throttle = 1.0
	fm.afterburner = 1.0 if fm.airspeed < 220.0 or dist > 8000.0 else 0.0
	w.target = target
	var off_nose := (-me.global_basis.z).angle_to(tpos - pos)
	if _missile_timer <= 0.0 and w.select_kind("aa"):
		var d: Dictionary = w.selected_data()
		var max_r := float(d.get("range_ft", 17700)) * FT
		if dist < max_r * 0.75 and dist > 900.0 and off_nose < deg_to_rad(12.0) and w.locked():
			w.fire(dt, world, true)
			_missile_timer = randf_range(8.0, 14.0) / maxf(skill, 0.3)
	if dist < 900.0 and off_nose < deg_to_rad(3.0 + (1.0 - skill) * 3.0):
		w.guns_mode = true
		w.fire(dt, world, true)
	else:
		if w.guns_mode:
			w.fire(dt, world, false)
		w.guns_mode = not w.select_kind("aa")


func _pick_target(world: CombatWorld, radius := INF) -> Aircraft:
	var best: Aircraft = null
	var bd := radius
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
