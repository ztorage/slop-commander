class_name CombatWorld
extends Node3D
## Owns everything that fights: aircraft, gun rounds, missiles, decoys and wreckage.
## Stepped from the flight scene's fixed physics loop.

signal aircraft_destroyed(a: Aircraft)

const FT := 0.3048
const BULLET_LIFE := 2.5

var terrain: Terrain
var aircraft: Array[Aircraft] = []
var missiles: Array[Missile] = []
var decoys: Array[Decoy] = []
var _wrecks: Array = []          # [{node, vel, spin}]
# gun rounds, structure-of-arrays
var _b_pos := PackedVector3Array()
var _b_vel := PackedVector3Array()
var _b_life := PackedFloat32Array()
var _b_owner: Array = []
var _b_damage := PackedFloat32Array()
var _tracers: MeshInstance3D
var _tracer_mesh := ImmediateMesh.new()


func _ready() -> void:
	_tracers = MeshInstance3D.new()
	_tracers.mesh = _tracer_mesh
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.albedo_color = Color(1.0, 0.85, 0.35)
	m.emission_enabled = true
	m.emission = Color(1.0, 0.7, 0.2)
	m.emission_energy_multiplier = 4.0
	_tracers.material_override = m
	_tracers.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_tracers)


func add_aircraft(a: Aircraft) -> void:
	aircraft.append(a)
	if a.get_parent() == null:
		add_child(a)


func ground_height(p: Vector3) -> float:
	return maxf(terrain.height_at(p.x, p.z), 0.0) if terrain else 0.0


func step(dt: float) -> void:
	for a in aircraft:
		if not a.alive:
			continue
		if a.ai:
			a.ai.update(dt, self)
		a.weapons.update(dt, self)
		if a.fm.crashed:
			destroy(a, "crashed")
	_step_bullets(dt)
	_step_missiles(dt)
	_step_decoys(dt)
	_step_wrecks(dt)


# ---------------------------------------------------------------- gun
func fire_bullet(from: Aircraft, gun: Dictionary) -> void:
	var muzzle := float(gun.get("muzzle_velocity_ms", 1000.0))
	var b := from.global_basis
	var dispersion := Vector3(randf_range(-1, 1), randf_range(-1, 1), 0) * 0.0035
	var dir := (-b.z + b * dispersion).normalized()
	_b_pos.append(from.global_transform * Vector3(0.6, 0.3, -5.0))
	_b_vel.append(from.fm.velocity + dir * muzzle)
	_b_life.append(BULLET_LIFE)
	_b_owner.append(from)
	_b_damage.append(float(gun.get("damage", 3)))


func _step_bullets(dt: float) -> void:
	var i := 0
	while i < _b_pos.size():
		var p := _b_pos[i]
		var v := _b_vel[i] + Vector3.DOWN * 9.8 * dt
		var q := p + v * dt
		var hit: Aircraft = null
		for a in aircraft:
			if a == _b_owner[i] or not a.alive:
				continue
			if _segment_sphere(p, q, a.global_position, a.hit_radius):
				hit = a
				break
		_b_life[i] -= dt
		if hit or _b_life[i] <= 0.0 or q.y < ground_height(q):
			if hit:
				Effects.explosion(self, "GUNSPARK", q, 6.0)
				damage(hit, _b_damage[i], _b_owner[i])
			_b_pos.remove_at(i); _b_vel.remove_at(i); _b_life.remove_at(i)
			_b_owner.remove_at(i); _b_damage.remove_at(i)
			continue
		_b_pos[i] = q
		_b_vel[i] = v
		i += 1


func _segment_sphere(p: Vector3, q: Vector3, c: Vector3, r: float) -> bool:
	var d := q - p
	var t := clampf((c - p).dot(d) / maxf(d.length_squared(), 1e-6), 0.0, 1.0)
	return (p + d * t).distance_squared_to(c) <= r * r


func _process(_d: float) -> void:
	_tracer_mesh.clear_surfaces()
	if _b_pos.is_empty():
		return
	_tracer_mesh.surface_begin(Mesh.PRIMITIVE_LINES)
	for i in _b_pos.size():
		if i % 3 != 0:
			continue  # every third round is a tracer
		var p := _b_pos[i]
		_tracer_mesh.surface_add_vertex(p)
		_tracer_mesh.surface_add_vertex(p - _b_vel[i].normalized() * 18.0)
	_tracer_mesh.surface_end()


# ---------------------------------------------------------------- missiles & decoys
func fire_missile(from: Aircraft, weapon: Dictionary, target: Aircraft) -> void:
	var m := Missile.new()
	add_child(m)
	m.setup(weapon, from, target)
	var b := from.global_basis
	m.launch(from.global_transform * Vector3(0, -1.2, -1.0), b, from.fm.velocity + (-b.z) * 15.0)
	missiles.append(m)
	if target:
		target.missile_warning(m)


func _step_missiles(dt: float) -> void:
	for m in missiles.duplicate():
		var boom: bool = m.step(dt, self)
		if boom:
			_detonate(m)
		if boom or not m.alive:
			if OS.get_environment("SC_COMBAT_TEST") != "":
				print("MISSILE %s from %s: %s" % [m.data.name, m.shooter.data.name, m.end_reason])
			missiles.erase(m)
			_retire_missile(m)


func _retire_missile(m: Missile) -> void:
	# keep the smoke trail visible for a moment after the missile is gone
	for c in m.get_children():
		if c is GPUParticles3D:
			c.emitting = false
		elif c is Node3D:
			c.visible = false
	var t := get_tree().create_timer(4.0)
	t.timeout.connect(m.queue_free)


func _detonate(m: Missile) -> void:
	Effects.explosion(self, String(m.data.get("explosion", "EXPLODE2")), m.global_position, 30.0)
	for a in aircraft:
		if not a.alive or a == m.shooter:
			continue
		var d := a.global_position.distance_to(m.global_position)
		if d < m.blast_radius * 2.0:
			damage(a, m.damage * clampf(1.4 - d / (m.blast_radius * 2.0), 0.3, 1.0), m.shooter)


func drop_decoy(from: Aircraft, is_flare: bool) -> void:
	var d := Decoy.new()
	d.setup(is_flare, from.global_transform * Vector3(0, -1, 4), from.fm.velocity * 0.9)
	add_child(d)
	decoys.append(d)


func _step_decoys(dt: float) -> void:
	for d in decoys.duplicate():
		if not d.step(dt):
			decoys.erase(d)
			d.queue_free()


## Missiles currently guiding on `a` (for the radar-warning receiver / AI defence).
func missiles_tracking(a: Aircraft) -> Array:
	return missiles.filter(func(m): return m.alive and m.target == a)


# ---------------------------------------------------------------- damage
func damage(a: Aircraft, amount: float, by: Aircraft) -> void:
	if not a.alive:
		return
	a.hp -= amount
	a.on_damaged(by)
	if a.hp <= 0.0:
		destroy(a, "shot down")


func destroy(a: Aircraft, reason: String) -> void:
	if not a.alive:
		return
	a.alive = false
	a.death_reason = reason
	var pos := a.global_position
	var expl: Dictionary = a.data.get("explosion", {}) if a.data.get("explosion") != null else {}
	Effects.explosion(self, String(expl.get("sprite", "FUELEXP1")), pos, 45.0)
	a.set_exterior_visible(false)
	a.hide_attachments()
	# tumbling wreckage using the original debris models
	var debris: Array = a.data.get("debris", [])
	for i in mini(debris.size(), 3):
		var w := GameData.load_model(String(debris[i]))
		if w == null:
			continue
		add_child(w)
		w.global_transform = a.global_transform
		var smoke := Effects.smoke_trail(Color(0.15, 0.15, 0.15), 40.0, 4.0, 5.0)
		w.add_child(smoke)
		_wrecks.append({"node": w, "vel": a.fm.velocity * 0.7 + Vector3(randf_range(-20, 20), randf_range(0, 25), randf_range(-20, 20)),
			"spin": Vector3(randf_range(-3, 3), randf_range(-3, 3), randf_range(-3, 3))})
	if a.fm.crashed:
		Effects.explosion(self, "GRNDEX2", pos, 60.0)
	aircraft_destroyed.emit(a)


func ground_explosion(p: Vector3, sprite: String) -> void:
	Effects.explosion(self, sprite, Vector3(p.x, ground_height(p) + 10.0, p.z), 50.0)


func _step_wrecks(dt: float) -> void:
	for w in _wrecks.duplicate():
		var n: Node3D = w.node
		w.vel += Vector3.DOWN * 9.8 * dt
		w.vel *= 1.0 - 0.15 * dt
		n.global_position += w.vel * dt
		n.rotate_object_local(Vector3.RIGHT, w.spin.x * dt)
		n.rotate_object_local(Vector3.FORWARD, w.spin.z * dt)
		if n.global_position.y < ground_height(n.global_position):
			ground_explosion(n.global_position, "GRNDEX2")
			_wrecks.erase(w)
			n.queue_free()
