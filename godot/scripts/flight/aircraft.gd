class_name Aircraft
extends Node3D
## A flyable aircraft: original RealSpace model + child models (afterburner, gear) + FlightModel.

var fm := FlightModel.new()
var data := {}
# --- combat state ---
var team := 0                      # 0 = player side, 1 = enemy
var hp := 30.0
var max_hp := 30.0
var alive := true
var ejected := false
var death_reason := ""
var hit_radius := 5.0
var weapons := WeaponSystem.new()
var ai: AIPilot
var last_attacker: Aircraft
var incoming: Array = []           # missiles fired at us (for RWR / AI defence)
var velocity_world: Vector3:
	get: return fm.velocity
var _damage_smoke: GPUParticles3D
var _afterburner_nodes: Array[Node3D] = []
var _gear_nodes: Array[Node3D] = []
var _model: Node3D


static func create(aircraft_name: String) -> Aircraft:
	var a := Aircraft.new()
	a.name = aircraft_name
	var json := GameData.path("aircraft/%s.json" % aircraft_name)
	a.data = JSON.parse_string(FileAccess.get_file_as_string(json))
	a.fm.setup(a.data)
	a._build_visuals()
	a.max_hp = float(a.data.get("hit_points", 30))
	a.hp = a.max_hp
	a.weapons.setup(a)
	return a


func _build_visuals() -> void:
	_model = GameData.load_model(data.name)
	add_child(_model)
	_only_lod0(_model)
	var gear_frames: Array[Node3D] = []
	for c in data.children:
		var child := GameData.load_model(String(c.model).to_upper())
		if child == null:
			continue
		_only_lod0(child)
		var o: Array = c.offset_m
		child.position = Vector3(o[0], o[1], o[2])
		add_child(child)
		var n := String(c.model).to_upper()
		if n.ends_with("AB") or n.ends_with("-AB"):
			_afterburner_nodes.append(child)
		elif n.contains("GEAR"):
			gear_frames.append(child)
		else:
			child.visible = false  # guns etc. are attached later
	# GEAR0..4 are retraction frames; show only the fully extended one (last) for now
	for i in gear_frames.size():
		gear_frames[i].visible = i == gear_frames.size() - 1
	if gear_frames.size():
		_gear_nodes.append(gear_frames[-1])
	var box := _aabb(self)
	hit_radius = clampf(box.size.length() * 0.22, 3.0, 25.0)
	fm.gear_height = -box.position.y if _gear_nodes.size() else -box.position.y + 0.9


func _only_lod0(n: Node) -> void:
	for lod in n.find_children("LOD*", "", true, false):
		lod.visible = lod.name == "LOD0"


## Bounding box of visible meshes in this node's local space (works before entering the tree).
func _aabb(n: Node) -> AABB:
	var box := AABB()
	var first := true
	for m in n.find_children("*", "MeshInstance3D", true, false):
		var t := Transform3D.IDENTITY
		var visible_chain := true
		var p: Node = m
		while p and p != self:
			if p is Node3D:
				visible_chain = visible_chain and (p as Node3D).visible
				t = (p as Node3D).transform * t
			p = p.get_parent()
		if not visible_chain:
			continue
		var b: AABB = t * m.get_aabb()
		box = b if first else box.merge(b)
		first = false
	return box


## Hide the external model (e.g. for the cockpit view); afterburner/gear follow normally.
func set_exterior_visible(v: bool) -> void:
	_model.visible = v


## Hide afterburner/gear/children (e.g. once destroyed).
func hide_attachments() -> void:
	for n in _afterburner_nodes + _gear_nodes:
		n.visible = false
	if _damage_smoke:
		_damage_smoke.emitting = false


func on_damaged(by: Aircraft) -> void:
	last_attacker = by
	if hp < max_hp * 0.5 and _damage_smoke == null:
		_damage_smoke = Effects.smoke_trail(Color(0.2, 0.2, 0.2), 35.0, 4.0, 4.0)
		_damage_smoke.position = Vector3(0, 0, 3)
		add_child(_damage_smoke)


func missile_warning(m: Missile) -> void:
	incoming.append(m)


func place(pos: Vector3, heading_deg: float, speed: float, on_ground: bool) -> void:
	fm.position = pos
	fm.basis = Basis(Vector3.UP, deg_to_rad(-heading_deg))
	fm.velocity = -fm.basis.z * speed
	fm.rates = Vector3.ZERO
	fm.crashed = false
	fm.fuel = fm.fuel_capacity
	fm.gear_down = on_ground
	fm.on_ground = on_ground
	fm.throttle = 0.0 if on_ground else 0.85
	fm.afterburner = 0.0
	hp = max_hp
	alive = true
	ejected = false
	death_reason = ""
	_model.visible = true
	_sync()


func simulate(dt: float, terrain: Terrain) -> void:
	if not alive:
		return
	var gh := func(x: float, z: float) -> float: return maxf(terrain.height_at(x, z), 0.0)
	fm.step(dt, gh)
	fm.check_terrain(gh)
	_sync()


func _sync() -> void:
	transform = Transform3D(fm.basis, fm.position)
	var ab := fm.afterburner > 0.0 and fm.has_afterburner
	for n in _afterburner_nodes:
		n.visible = ab
	for n in _gear_nodes:
		n.visible = fm.gear_down
