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
var crippled := false              # fatally hit: falls out of control until it hits the ground
var crippled_time := 0.0
var _spiral_bank := 0.0
var death_reason := ""
var hit_radius := 5.0
var weapons := WeaponSystem.new()
var ai: AIPilot
var last_attacker: Aircraft
var incoming: Array = []           # missiles fired at us (for RWR / AI defence)
var visual_scale := 1.0           # >1 when far from the camera, so aircraft don't shrink to dots
var velocity_world: Vector3:
	get: return fm.velocity
var _damage_smoke: GPUParticles3D
var _afterburner_nodes: Array[Node3D] = []
var _afterburner_mats: Array[StandardMaterial3D] = []
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
			_make_glow(child)
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


## Fatally damaged but not blown apart: engine out, burning, falling until it hits the ground.
func cripple() -> void:
	crippled = true
	if _damage_smoke == null:
		_damage_smoke = Effects.smoke_trail(Color(0.12, 0.12, 0.12), 45.0, 5.0, 6.0)
		_damage_smoke.position = Vector3(0, 0, 3)
		add_child(_damage_smoke)
	var fire := OmniLight3D.new()
	fire.light_color = Color(1.0, 0.55, 0.2)
	fire.light_energy = 4.0
	fire.omni_range = 30.0
	fire.position = Vector3(0, 0, 3)
	add_child(fire)
	var flames := Effects.smoke_trail(Color(1.0, 0.55, 0.15), 40.0, 0.6, 3.5)
	flames.position = Vector3(0, 0, 2.5)
	add_child(flames)
	fm.throttle = 0.0
	fm.afterburner = 0.0
	_spiral_bank = deg_to_rad(randf_range(110.0, 140.0)) * (1.0 if randf() < 0.5 else -1.0)


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
	crippled = false
	crippled_time = 0.0
	ejected = false
	death_reason = ""
	_model.visible = true
	_sync()


func simulate(dt: float, terrain: Terrain) -> void:
	if not alive:
		return
	var gh := func(x: float, z: float) -> float: return maxf(terrain.height_at(x, z), 0.0)
	if crippled:
		# death spiral: rolled past the vertical and pulling, so the nose falls through
		var bank := -fm.basis.get_euler(EULER_ORDER_YXZ).z
		fm.stick = Vector2(clampf((_spiral_bank - bank) * 1.5, -1.0, 1.0), 0.2)
		fm.throttle = 0.0
	fm.step(dt, gh)
	fm.check_terrain(gh)
	_sync()


## Afterburner cones: see-through, additive glow instead of the original's solid polygons.
func _make_glow(root: Node) -> void:
	for mi in root.find_children("*", "MeshInstance3D", true, false):
		var mesh: Mesh = (mi as MeshInstance3D).mesh
		if mesh == null:
			continue
		for i in mesh.get_surface_count():
			var src := mesh.surface_get_material(i) as StandardMaterial3D
			var m := StandardMaterial3D.new()
			if src:
				m.albedo_texture = src.albedo_texture
				m.albedo_color = src.albedo_color
				m.texture_filter = src.texture_filter
			m.albedo_color.a = 0.7
			m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
			m.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
			m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
			m.cull_mode = BaseMaterial3D.CULL_DISABLED
			m.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_DISABLED
			(mi as MeshInstance3D).set_surface_override_material(i, m)
			_afterburner_mats.append(m)
		(mi as MeshInstance3D).cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF


func _sync() -> void:
	transform = Transform3D(fm.basis * Basis.from_scale(Vector3.ONE * visual_scale), fm.position)
	var ab := fm.afterburner > 0.0 and fm.has_afterburner
	for n in _afterburner_nodes:
		n.visible = ab
	if ab:
		var a := clampf(0.45 + 0.35 * fm.afterburner, 0.0, 0.85) * randf_range(0.8, 1.0)   # flicker
		for m in _afterburner_mats:
			m.albedo_color.a = a
	for n in _gear_nodes:
		n.visible = fm.gear_down
