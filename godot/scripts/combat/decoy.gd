class_name Decoy
extends Node3D
## Flare (IR) or chaff (radar) cloud ejected from an aircraft; it drifts, falls and expires.

var velocity_world := Vector3.ZERO
var infrared := true
var life := 0.0
var max_life := 5.0


func setup(is_flare: bool, pos: Vector3, vel: Vector3) -> void:
	infrared = is_flare
	velocity_world = vel + Vector3(randf_range(-15, 15), -10, randf_range(-15, 15))
	position = pos
	if is_flare:
		var light := OmniLight3D.new()
		light.light_color = Color(1.0, 0.85, 0.6)
		light.light_energy = 6.0
		light.omni_range = 40.0
		add_child(light)
		var trail := Effects.smoke_trail(Color(1, 1, 1), 40.0, 2.0, 2.0)
		add_child(trail)
	else:
		var trail := Effects.smoke_trail(Color(0.75, 0.75, 0.8), 30.0, 2.5, 6.0)
		add_child(trail)


func step(dt: float) -> bool:
	life += dt
	velocity_world = velocity_world.lerp(Vector3(0, -15, 0), 1.0 - exp(-dt * 1.5))
	position += velocity_world * dt
	return life < max_life
