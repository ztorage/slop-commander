class_name CameraRig
extends Camera3D
## Views: four cockpit directions (original art), CHASE (rigidly attached), ORBIT (mouse-drag).
## In the front cockpit view the projection is shifted so the line of sight passes through the
## art's HUD boresight instead of the screen centre.

enum View { COCKPIT_FRONT, COCKPIT_LEFT, COCKPIT_RIGHT, COCKPIT_REAR, CHASE, ORBIT }

const EYE := Vector3(0, 1.1, -4.2)
const COCKPIT_FOV := 58.0
const EXTERNAL_FOV := 70.0
# look direction (yaw left +, pitch up +) for each cockpit view, degrees
const LOOK := {
	View.COCKPIT_FRONT: Vector2(0, 0), View.COCKPIT_LEFT: Vector2(80, -18),
	View.COCKPIT_RIGHT: Vector2(-80, -18), View.COCKPIT_REAR: Vector2(155, 8),
}

var target: Aircraft
var cockpit: Cockpit
var view := View.CHASE
var _orbit_yaw := 0.6
var _orbit_pitch := -0.25
var _orbit_dist := 25.0


func _ready() -> void:
	near = 0.3
	far = 140000.0
	fov = EXTERNAL_FOV


func snap() -> void:
	pass


## Step to the previous (-1) or next (+1) view.
func cycle(step: int) -> void:
	view = posmod(view + step, View.size()) as View


func is_cockpit() -> bool:
	return view <= View.COCKPIT_REAR


func update_view(_dt: float) -> void:
	if target == null:
		return
	var t := target.global_transform
	target.set_exterior_visible(not is_cockpit())
	if cockpit:
		cockpit.visible = is_cockpit()
		cockpit.side = (view as int) as Cockpit.Side if is_cockpit() else Cockpit.Side.FRONT
	if is_cockpit():
		var look: Vector2 = LOOK[view]
		var b := t.basis * Basis.from_euler(Vector3(deg_to_rad(look.y), deg_to_rad(look.x), 0))
		global_transform = Transform3D(b, t * EYE)
		_set_projection(view == View.COCKPIT_FRONT)
		return
	_set_projection(false)
	match view:
		View.CHASE:
			# rigidly attached behind and above the jet: no lag, so the view never trails a turn
			global_transform = Transform3D(t.basis, t * Vector3(0, 4.0, 20.0))
			look_at(t * Vector3(0, 1.2, -30.0), t.basis.y)
		View.ORBIT:
			var dir := Vector3(cos(_orbit_pitch) * sin(_orbit_yaw), -sin(_orbit_pitch), cos(_orbit_pitch) * cos(_orbit_yaw))
			global_position = t.origin + dir * _orbit_dist
			look_at(t.origin)


func _set_projection(boresight_offset: bool) -> void:
	if not boresight_offset or cockpit == null or not cockpit.art_enabled:
		projection = PROJECTION_PERSPECTIVE
		fov = COCKPIT_FOV if is_cockpit() else EXTERNAL_FOV
		return
	# Frustum whose optical axis lands on the art's boresight (fraction measured from the bottom).
	var vp := get_viewport().get_visible_rect().size
	var from_bottom := 1.0 - cockpit.boresight_screen().y / vp.y
	fov = COCKPIT_FOV  # kept in sync for the HUD's angle-to-pixel scale
	var size := 2.0 * near * tan(deg_to_rad(COCKPIT_FOV) * 0.5)
	set_frustum(size, Vector2(0, size * (0.5 - from_bottom)), near, far)


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
