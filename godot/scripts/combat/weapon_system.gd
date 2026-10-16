class_name WeaponSystem
extends RefCounted
## Stores, selection, targeting and lock logic for one aircraft (player or AI).
## Mirrors the original controls: W next weapon, G guns, T/Shift-T/Ctrl-T targets, Space fire.

const FT := 0.3048
const GUN_RATE := 100.0           # rounds per second (M61 ~6000 rpm)
const LOCK_TIME := 1.0
const RADAR_RANGE := 20.0 * 1852.0
const RADAR_AZIMUTH := deg_to_rad(60.0)

var owner_aircraft: Aircraft
var stations: Array = []          # [{weapon, count, data}] air-to-air first
var selected := 0
var guns_mode := false
var gun_data := {}
var gun_rounds := 0
var chaff := 0
var flares := 0
var target: Aircraft
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
		if d.kind == "trcr":
			gun_data = d
			gun_rounds = int(st.count)
		elif d.kind == "miss" and int(d.get("data", [0, 0, 0, 0, 0])[4]) == 1:  # air-to-air
			stations.append({"weapon": st.weapon, "count": int(st.count), "data": d})
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


func next_weapon() -> void:
	if stations.is_empty():
		return
	if guns_mode:
		guns_mode = false
	else:
		selected = (selected + 1) % stations.size()
	lock_progress = 0.0


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


func cycle_target(world: CombatWorld, step: int) -> void:
	var c := radar_contacts(world)
	if c.is_empty():
		target = null
		return
	var i := c.find(target)
	target = c[posmod(i + step, c.size())] if i >= 0 else c[0 if step > 0 else c.size() - 1]
	lock_progress = 0.0


## Lock: the selected missile's seeker must see the target (cone, range) for LOCK_TIME.
func update(dt: float, world: CombatWorld) -> void:
	_cooldown = maxf(_cooldown - dt, 0.0)
	if target and (not target.alive or not radar_contacts(world).has(target)):
		target = null
	if target == null or guns_mode or stations.is_empty() or selected_count() <= 0:
		lock_progress = 0.0
		return
	var d: Dictionary = stations[selected].data
	var to := target.global_position - owner_aircraft.global_position
	var in_cone := (-owner_aircraft.global_basis.z).angle_to(to) < deg_to_rad(float(d.get("seeker_cone_deg", 45)) * 0.5)
	var in_range := to.length() < float(d.get("range_ft", 17700)) * FT
	lock_progress = minf(lock_progress + dt, LOCK_TIME) if in_cone and in_range else 0.0


func locked() -> bool:
	return lock_progress >= LOCK_TIME


## Fire the selected weapon. Gun fire is continuous while held (call every physics step).
func fire(dt: float, world: CombatWorld, held: bool) -> void:
	if guns_mode or stations.is_empty():
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
