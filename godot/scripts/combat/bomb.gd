class_name Bomb
extends Node3D
## Free-fall (Mk 82, Mk 20, Durandal) or guided (GBU-15) bomb. Explodes on ground impact with
## the original blast radius and damage.

const FT := 0.3048
const DRAG := 0.012          # 1/m — retardation applied to airspeed (simple ballistic model)

var data := {}
var shooter: Node3D
var target: Node3D            # guided bombs only
var velocity := Vector3.ZERO
var guided := false
var life := 0.0


func setup(weapon: Dictionary, from: Node3D, tgt: Node3D) -> void:
	data = weapon
	shooter = from
	guided = int(weapon.get("guidance", [0, 0, 0])[2]) == 3 or String(weapon.name).begins_with("GBU")
	target = tgt if guided else null
	var model := GameData.load_model(String(weapon.name))
	if model:
		for lod in model.find_children("LOD*", "", true, false):
			lod.visible = lod.name == "LOD0"
		add_child(model)


## Ballistic step shared with the HUD impact predictor.
static func integrate(pos: Vector3, vel: Vector3, dt: float) -> Array:
	var v := vel + Vector3.DOWN * 9.80665 * dt
	v -= v * minf(DRAG * v.length() * dt * 0.05, 0.5)
	return [pos + v * dt, v]


## Where a bomb released now would hit (or the last point if it doesn't land within 60 s).
static func predict_impact(pos: Vector3, vel: Vector3, world: CombatWorld) -> Vector3:
	var p := pos
	var v := vel
	for i in 600:
		var r := integrate(p, v, 0.1)
		p = r[0]
		v = r[1]
		if p.y <= world.ground_height(p):
			return Vector3(p.x, world.ground_height(p), p.z)
	return p


## Returns true when the bomb hit the ground this step.
func step(dt: float, world: CombatWorld) -> bool:
	life += dt
	if guided and is_instance_valid(target) and target.get("alive") != false:
		# glide toward the target: steer the velocity vector, limited to ~3 g
		var to: Vector3 = target.global_position - global_position
		var want := to.normalized() * velocity.length()
		var dv := (want - velocity).limit_length(30.0 * dt)
		velocity += dv
		velocity += Vector3.DOWN * 2.0 * dt
		global_position += velocity * dt
	else:
		var r := integrate(global_position, velocity, dt)
		global_position = r[0]
		velocity = r[1]
	if velocity.length() > 1.0:
		look_at(global_position + velocity, Vector3.UP if absf(velocity.normalized().y) < 0.99 else Vector3.FORWARD)
	return global_position.y <= world.ground_height(global_position) or life > 90.0
