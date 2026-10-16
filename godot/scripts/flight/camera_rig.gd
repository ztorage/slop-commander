class_name CameraRig
extends Camera3D
## Views: COCKPIT (canopy eye point), CHASE (smoothed, behind and above), ORBIT (mouse-drag).

enum View { COCKPIT, CHASE, ORBIT }

var target: Aircraft
var view := View.CHASE
var _orbit_yaw := 0.6
var _orbit_pitch := -0.25
var _orbit_dist := 25.0
var _chase_rot := Quaternion.IDENTITY


func _ready() -> void:
	near = 0.3
	far = 140000.0
	fov = 70.0


func snap() -> void:
	if target:
		_chase_rot = target.global_basis.get_rotation_quaternion()


func update_view(dt: float) -> void:
	if target == null:
		return
	var t := target.global_transform
	target.set_exterior_visible(view != View.COCKPIT)
	match view:
		View.COCKPIT:
			global_transform = Transform3D(t.basis, t * Vector3(0, 1.1, -4.2))
		View.CHASE:
			# fixed distance; only the viewing direction lags, so manoeuvres read clearly
			_chase_rot = _chase_rot.slerp(t.basis.get_rotation_quaternion(), 1.0 - exp(-dt * 4.0))
			var b := Basis(_chase_rot)
			global_position = t.origin + b * Vector3(0, 4.0, 20.0)
			look_at(t.origin + b * Vector3(0, 1.2, -30.0), b.y.lerp(Vector3.UP, 0.35).normalized())
		View.ORBIT:
			var dir := Vector3(cos(_orbit_pitch) * sin(_orbit_yaw), -sin(_orbit_pitch), cos(_orbit_pitch) * cos(_orbit_yaw))
			global_position = t.origin + dir * _orbit_dist
			look_at(t.origin)


func handle_input(ev: InputEvent) -> void:
	if view != View.ORBIT:
		return
	if ev is InputEventMouseMotion and Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
		_orbit_yaw -= ev.relative.x * 0.008
		_orbit_pitch = clampf(_orbit_pitch + ev.relative.y * 0.008, -1.4, 1.4)
	elif ev is InputEventMouseButton and ev.pressed:
		if ev.button_index == MOUSE_BUTTON_WHEEL_UP:
			_orbit_dist = maxf(8.0, _orbit_dist * 0.9)
		elif ev.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_orbit_dist = minf(400.0, _orbit_dist * 1.1)
