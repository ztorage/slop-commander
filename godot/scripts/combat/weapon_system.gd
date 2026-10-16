class_name WeaponSystem
extends RefCounted
## Stores, selection, targeting and lock logic for one aircraft (player or AI).
## Mirrors the original controls: W next weapon, G guns, T/Shift-T/Ctrl-T targets, Space fire.
## Stations are air-to-air missiles ("aa"), air-to-ground missiles ("ag") and bombs ("bomb");
## the selected station decides whether T cycles air or ground targets.

const FT := 0.3048
const GUN_RATE := 100.0           # rounds per second (M61 ~6000 rpm)
const LOCK_TIME := 1.0
const RADAR_RANGE := 20.0 * 1852.0
const RADAR_AZIMUTH := deg_to_rad(60.0)
const GROUND_RANGE := 10.0 * 1852.0
const BOMB_INTERVAL := 0.25

var owner_aircraft: Aircraft
var stations: Array = []          # [{weapon, count, data, kind}]
var selected := 0
var guns_mode := false
var gun_data := {}
var gun_rounds := 0
var chaff := 0
var flares := 0
var target: Node3D                # Aircraft or GroundUnit
var lock_progress := 0.0
var _gun_accum := 0.0
var _cooldown := 0.0


func setup(a: Aircraft) -> void:
	owner_aircraft = a
	var w: Dictionary = a.data.get("weapons", {})
	chaff = int(w.get("chaff", 0))
	flares = int(w.get("flares", 0))
	for st in w.get("stations", []):
		var file := GameData.path("weapons/%s.json" % String(st.weapon).to_upper())
		if not FileAccess.file_exists(file):
			continue
		var d: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(file))
		var kind := ""
		match String(d.kind):
			"trcr":
				gun_data = d
				gun_rounds = int(st.count)
			"miss":
				kind = "aa" if int(d.get("data", [0, 0, 0, 0, 0])[4]) == 1 else "ag"
			"bomb", "durd":
				kind = "bomb"
		if kind != "":
			stations.append({"weapon": String(st.weapon).to_upper(), "count": int(st.count), "data": d, "kind": kind})
	# air-to-air first, then air-to-ground, then bombs
	var order := {"aa": 0, "ag": 1, "bomb": 2}
	stations.sort_custom(func(x, y): return order[x.kind] < order[y.kind])
	if gun_data.is_empty():
		gun_data = {"name": "20MM", "damage": 3, "muzzle_velocity_ms": 1000.0, "range_ft": 10000}
		gun_rounds = 500
	selected = 0
	guns_mode = stations.is_empty()


func selected_name() -> String:
	if guns_mode or stations.is_empty():
		return "GUN"
	return String(stations[selected].weapon)


func selected_count() -> int:
	if guns_mode or stations.is_empty():
		return gun_rounds
	return int(stations[selected].count)


func selected_data() -> Dictionary:
	return gun_data if guns_mode or stations.is_empty() else stations[selected].data


func selected_kind() -> String:
	return "gun" if guns_mode or stations.is_empty() else String(stations[selected].kind)


func air_to_ground() -> bool:
	return selected_kind() in ["ag", "bomb"]


## Select the first station of a kind with ammunition left; returns false if none.
func select_kind(kind: String) -> bool:
	for i in stations.size():
		if stations[i].kind == kind and int(stations[i].count) > 0:
			if selected != i or guns_mode:
				selected = i
				guns_mode = false
				lock_progress = 0.0
			return true
	return false


func next_weapon() -> void:
	if stations.is_empty():
		return
	if guns_mode:
		guns_mode = false
	else:
		for k in stations.size():
			selected = (selected + 1) % stations.size()
			if int(stations[selected].count) > 0:
				break
	lock_progress = 0.0
	if target and (target is GroundUnit) != air_to_ground():
		target = null


func toggle_guns() -> void:
	guns_mode = not guns_mode or stations.is_empty()
	lock_progress = 0.0


## Contacts the radar can see: enemies inside range and azimuth, nearest first.
func radar_contacts(world: CombatWorld) -> Array:
	var me := owner_aircraft
	var fwd := -me.global_basis.z
	var out := []
	for a in world.aircraft:
		if a == me or not a.alive or a.team == me.team:
			continue
		var to: Vector3 = a.global_position - me.global_position
		if to.length() < RADAR_RANGE and fwd.angle_to(to) < RADAR_AZIMUTH:
			out.append(a)
	out.sort_custom(func(x, y): return x.global_position.distance_to(me.global_position) < y.global_position.distance_to(me.global_position))
	return out


## Ground targets ahead: hostile units first, then anything else destructible.
func ground_contacts(world: CombatWorld) -> Array:
	var me := owner_aircraft
	var fwd := -me.global_basis.z
	var flat_fwd := Vector3(fwd.x, 0, fwd.z).normalized()
	var out := []
	for u in world.ground_units:
		if not u.alive or u.team == me.team or u.team < 0:
			continue
		var to: Vector3 = u.global_position - me.global_position
		if to.length() < GROUND_RANGE and flat_fwd.angle_to(Vector3(to.x, 0, to.z)) < deg_to_rad(70.0):
			out.append(u)
	out.sort_custom(func(x, y): return x.global_position.distance_to(me.global_position) < y.global_position.distance_to(me.global_position))
	return out


func contacts(world: CombatWorld) -> Array:
	return ground_contacts(world) if air_to_ground() else radar_contacts(world)


func cycle_target(world: CombatWorld, step: int) -> void:
	var c := contacts(world)
	if c.is_empty():
		target = null
		return
	var i := c.find(target)
	target = c[posmod(i + step, c.size())] if i >= 0 else c[0 if step > 0 else c.size() - 1]
	lock_progress = 0.0


func _target_alive() -> bool:
	return is_instance_valid(target) and target.get("alive") == true


## Lock: the selected missile's seeker must see the target (cone, range) for LOCK_TIME.
func update(dt: float, world: CombatWorld) -> void:
	_cooldown = maxf(_cooldown - dt, 0.0)
	if target and (not _target_alive() or not contacts(world).has(target)):
		target = null
	var kind := selected_kind()
	if target == null or kind == "gun" or kind == "bomb" or selected_count() <= 0:
		lock_progress = 0.0
		return
	var d: Dictionary = stations[selected].data
	var to := target.global_position - owner_aircraft.global_position
	var in_cone := (-owner_aircraft.global_basis.z).angle_to(to) < deg_to_rad(float(d.get("seeker_cone_deg", 45)) * 0.5)
	var max_r := maxf(float(d.get("range_ft", 17700)), float(d.get("range2_ft", 0))) * FT
	var in_range := to.length() < max_r
	lock_progress = minf(lock_progress + dt, LOCK_TIME) if in_cone and in_range else 0.0


func locked() -> bool:
	return lock_progress >= LOCK_TIME


## Fire the selected weapon. Gun and bombs fire continuously while held (call every physics step).
func fire(dt: float, world: CombatWorld, held: bool) -> void:
	var kind := selected_kind()
	if kind == "gun":
		if not held or gun_rounds <= 0:
			_gun_accum = 0.0
			return
		_gun_accum += dt * GUN_RATE
		while _gun_accum >= 1.0 and gun_rounds > 0:
			_gun_accum -= 1.0
			gun_rounds -= 1
			world.fire_bullet(owner_aircraft, gun_data)
		return
	if not held or _cooldown > 0.0:
		return
	var st: Dictionary = stations[selected]
	if int(st.count) <= 0:
		return
	st.count = int(st.count) - 1
	if kind == "bomb":
		_cooldown = BOMB_INTERVAL
		world.drop_bomb(owner_aircraft, st.data, target)
	else:
		_cooldown = 1.0
		world.fire_missile(owner_aircraft, st.data, target if locked() else null)
		lock_progress = 0.0
	if int(st.count) == 0:
		next_weapon()


func drop_decoy(world: CombatWorld, is_flare: bool) -> void:
	if is_flare and flares > 0:
		flares -= 1
	elif not is_flare and chaff > 0:
		chaff -= 1
	else:
		return
	world.drop_decoy(owner_aircraft, is_flare)
