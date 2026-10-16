class_name GroundUnit
extends Node3D
## A ground vehicle, building, SAM/AAA site or ship (gamedata/units/<NAME>.json).
## Destroyed units swap to their original wreck model and smoke; SWPN units engage enemy aircraft
## with their own missiles (SA-2, SA-6, …) or guns (23 mm, 40 mm …).

const FT := 0.3048

var unit_name := ""
var data := {}
var team := -1                    # -1 neutral scenery, 0 player side, 1 enemy
var hp := 20.0
var max_hp := 20.0
var alive := true
var hit_radius := 8.0
var velocity_world := Vector3.ZERO
var weapon := {}                  # {name, ammo, range_ft, min_range_ft}
var weapon_data := {}             # gamedata/weapons/<weapon>.json
var ammo := 0
var _cooldown := 0.0
var _burst := 0.0
var _model: Node3D


static func create(model_name: String, side: int) -> GroundUnit:
	var u := GroundUnit.new()
	u.unit_name = model_name
	u.name = model_name
	u.team = side
	var f := GameData.path("units/%s.json" % model_name)
	if FileAccess.file_exists(f):
		u.data = JSON.parse_string(FileAccess.get_file_as_string(f))
	u.max_hp = float(u.data.get("hit_points", 20))
	u.hp = u.max_hp
	u._model = GameData.load_model(model_name)
	if u._model:
		for lod in u._model.find_children("LOD*", "", true, false):
			lod.visible = lod.name == "LOD0"
		u.add_child(u._model)
		var box := AABB()
		var first := true
		for m in u._model.find_children("*", "MeshInstance3D", true, false):
			if m.visible:
				box = m.get_aabb() if first else box.merge(m.get_aabb())
				first = false
		u.hit_radius = clampf(box.size.length() * 0.35, 4.0, 60.0)
	if u.data.has("weapon"):
		u.weapon = u.data.weapon
		u.ammo = int(u.weapon.get("ammo", 0))
		var wf := GameData.path("weapons/%s.json" % String(u.weapon.name))
		if FileAccess.file_exists(wf):
			u.weapon_data = JSON.parse_string(FileAccess.get_file_as_string(wf))
		u._cooldown = randf_range(2.0, 6.0)
	return u


func is_sam() -> bool:
	return String(weapon_data.get("kind", "")) == "miss"


func is_gun() -> bool:
	return not weapon.is_empty() and not is_sam()


## Fire control for SAM and AAA sites (called from CombatWorld.step).
func update(dt: float, world: CombatWorld) -> void:
	if not alive or weapon.is_empty() or ammo <= 0 or team < 0:
		return
	_cooldown -= dt
	var max_r := float(weapon.get("range_ft", 10000)) * FT
	var min_r := minf(float(weapon.get("min_range_ft", 0)) * FT, max_r * 0.3)
	var best: Aircraft = null
	var bd := max_r
	for a in world.aircraft:
		if a.alive and a.team != team and not a.ejected:
			var d := a.global_position.distance_to(global_position)
			if d < bd and d > min_r and not a.fm.on_ground:
				bd = d
				best = a
	if best == null:
		_burst = 0.0
		return
	if is_sam():
		if _cooldown <= 0.0:
			world.fire_missile_from(self, weapon_data, best)
			ammo -= 1
			_cooldown = randf_range(8.0, 14.0)
	elif _cooldown <= 0.0:
		# AAA: bursts of ~1.5 s aimed at a lead point with heavy dispersion
		_burst += dt
		var shots_per_s := 12.0
		var accum := dt * shots_per_s
		while accum > randf():
			accum -= 1.0
			var muzzle := float(weapon_data.get("muzzle_velocity_ms", 900.0))
			var tof := bd / muzzle
			var lead := best.global_position + best.fm.velocity * tof + Vector3.UP * 4.9 * tof * tof
			var dir := (lead - global_position).normalized()
			dir = (dir + Vector3(randf_range(-1, 1), randf_range(-1, 1), randf_range(-1, 1)) * 0.012).normalized()
			world.fire_round(self, global_position + Vector3.UP * 4.0, dir * muzzle, float(weapon_data.get("damage", 3)))
			ammo -= 1
		if _burst > 1.5:
			_burst = 0.0
			_cooldown = randf_range(2.0, 4.0)


## Called by CombatWorld when hit points reach zero.
func on_destroyed(world: CombatWorld) -> void:
	alive = false
	var expl: Dictionary = data.get("explosion") if data.get("explosion") != null else {}
	Effects.explosion(world, String(expl.get("sprite", "GRNDEX2")), global_position + Vector3.UP * 6.0,
		clampf(float(expl.get("radius_ft", 40)) * FT * 2.5, 20.0, 90.0))
	Audio.sfx("explosion_3", global_position, world, 8.0)
	var wreck_shown := false
	for w in data.get("destroyed", []):
		if String(w) == "SMOKEGEN":
			var smoke := Effects.smoke_trail(Color(0.18, 0.18, 0.18), 25.0, 9.0, 18.0)
			(smoke.process_material as ParticleProcessMaterial).direction = Vector3.UP
			(smoke.process_material as ParticleProcessMaterial).initial_velocity_min = 8.0
			(smoke.process_material as ParticleProcessMaterial).initial_velocity_max = 14.0
			add_child(smoke)
		elif not wreck_shown:
			var m := GameData.load_model(String(w))
			if m:
				for lod in m.find_children("LOD*", "", true, false):
					lod.visible = lod.name == "LOD0"
				add_child(m)
				wreck_shown = true
	if _model and wreck_shown:
		_model.visible = false
	elif _model:
		_model.scale = Vector3(1, 0.35, 1)   # flattened rubble when there is no wreck model
