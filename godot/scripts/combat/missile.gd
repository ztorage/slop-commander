class_name Missile
extends Node3D
## Guided missile using the original weapon data (speed, turn G, seeker cone, range, damage,
## blast radius). Proportional navigation; IR seekers can be decoyed by flares, radar seekers
## by chaff.

const G := 9.80665
const NAV_GAIN := 4.0
const BOOST_TIME := 2.5
const MAX_LIFE := 30.0
const FT := 0.3048
const DECOY_CHANCE := 0.12        # per flare/chaff the seeker sees

var data := {}
var shooter: Aircraft
var target: Node3D          # Aircraft or decoy
var velocity := Vector3.ZERO
var speed := 0.0
var life := 0.0
var alive := true
var infrared := true
var max_speed := 800.0
var max_accel := 200.0
var cone := deg_to_rad(45.0)
var blast_radius := 9.0
var damage := 60.0
var decoys_seen := {}
var end_reason := ""
var closest := INF
var _prev_dist := INF


func setup(weapon: Dictionary, from: Aircraft, tgt: Node3D) -> void:
	data = weapon
	shooter = from
	target = tgt
	infrared = int(weapon.get("guidance", [0, 1])[1]) == 1
	max_speed = float(weapon.get("max_speed_ms", 800.0))
	max_accel = float(weapon.get("turn_g", 20.0)) * G * 1.6
	cone = deg_to_rad(float(weapon.get("seeker_cone_deg", 45)))
	blast_radius = maxf(float(weapon.get("blast_radius_ft", 30)) * FT, 8.0)
	damage = float(weapon.get("damage", 60))
	var model := GameData.load_model(weapon.name)
	if model:
		for lod in model.find_children("LOD*", "", true, false):
			lod.visible = lod.name == "LOD0"
		add_child(model)
	var trail := Effects.smoke_trail(Color(0.9, 0.9, 0.88), 240.0, 3.5, 4.0)
	trail.position = Vector3(0, 0, 1.5)
	add_child(trail)


func launch(pos: Vector3, basis_: Basis, initial_velocity: Vector3) -> void:
	global_transform = Transform3D(basis_, pos)
	velocity = initial_velocity
	speed = velocity.length()


## Returns true when the missile should detonate this step.
func step(dt: float, world: CombatWorld) -> bool:
	life += dt
	if life > MAX_LIFE:
		alive = false
		end_reason = "timeout (closest %.0f m)" % closest
		return false
	var pos := global_position
	var fwd := velocity.normalized() if speed > 1.0 else -global_basis.z
	# decoys: each flare/chaff inside the seeker cone gets one chance to steal the lock
	for d in world.decoys:
		if decoys_seen.has(d) or d.infrared != infrared:
			continue
		var to := d.global_position - pos
		if to.length() < 3000.0 and fwd.angle_to(to) < cone:
			decoys_seen[d] = true
			if randf() < 0.3:
				target = d
				end_reason = "decoyed"
	var accel := Vector3.ZERO
	if is_instance_valid(target) and _target_alive():
		var r: Vector3 = target.global_position - pos
		var dist := r.length()
		closest = minf(closest, dist)
		if fwd.angle_to(r) > cone * 1.6:
			target = null  # seeker gimbal limit: lock lost
			end_reason = "gimbal limit at %.0f m" % dist
		else:
			var tv: Vector3 = target.get("velocity_world") if target.get("velocity_world") != null else Vector3.ZERO
			var vrel := tv - velocity
			var omega := r.cross(vrel) / maxf(dist * dist, 1.0)
			accel = NAV_GAIN * omega.cross(velocity)
			if accel.length() > max_accel:
				accel = accel.normalized() * max_accel
			# proximity fuse: inside blast radius, or the miss distance just started growing
			if dist < blast_radius or (dist > _prev_dist and _prev_dist < blast_radius * 2.0):
				end_reason = "detonated at %.0f m from %s" % [dist, "aircraft" if target is Aircraft else "decoy"]
				return true
			_prev_dist = dist
	# motor then drag
	if life < BOOST_TIME:
		speed = minf(speed + (max_speed / BOOST_TIME) * dt * 1.2, max_speed)
	else:
		speed = maxf(speed - speed * 0.03 * dt, 150.0)
	velocity = (velocity + accel * dt).normalized() * speed + Vector3.DOWN * G * dt * 0.2
	speed = velocity.length()
	global_position = pos + velocity * dt
	if speed > 1.0:
		look_at(global_position + velocity, Vector3.UP if absf(velocity.normalized().y) < 0.99 else Vector3.FORWARD)
	if global_position.y < world.ground_height(global_position):
		alive = false
		end_reason = "hit ground"
		world.ground_explosion(global_position, "GRNDEX1")
	return false


func _target_alive() -> bool:
	if target is Aircraft:
		return (target as Aircraft).alive
	return true
