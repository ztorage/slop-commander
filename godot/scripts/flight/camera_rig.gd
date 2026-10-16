class_name CameraRig
extends Camera3D
## Camera views, following the original's set:
##   cockpit front (F1; press again for the view zoomed onto the HUD), left/right/back (F3-F5),
##   chase (F2), external orbit (F6), victim camera (F9), weapon camera (F10).
## In the cockpit: Y tracks (padlocks) the selected target; dragging with the right mouse button
## looks around freely and snaps back on release. Special views return to the previous view when
## toggled again or when their subject is gone.

enum View { COCKPIT_FRONT, COCKPIT_LEFT, COCKPIT_RIGHT, COCKPIT_REAR, CHASE, ORBIT, VICTIM, WEAPON }

const EYE := Vector3(0, 1.1, -4.2)
const COCKPIT_FOV := 58.0
const EXTERNAL_FOV := 70.0
const ART_LOOK_LIMIT := deg_to_rad(25.0)  # beyond this the painted cockpit can't follow the gaze
# look direction (yaw left +, pitch up +) for each cockpit view, degrees
const LOOK := {
	View.COCKPIT_FRONT: Vector2(0, 0), View.COCKPIT_LEFT: Vector2(80, -18),
	View.COCKPIT_RIGHT: Vector2(-80, -18), View.COCKPIT_REAR: Vector2(155, 8),
}
const CYCLE := [View.COCKPIT_FRONT, View.COCKPIT_LEFT, View.COCKPIT_RIGHT, View.COCKPIT_REAR, View.CHASE, View.ORBIT]

var target: Aircraft
var cockpit: Cockpit
var view := View.CHASE
var hud_zoom := false              # front view zoomed onto the HUD (original's alternate view)
var padlock := false               # Y: the cockpit view tracks the selected target
var free_look := Vector2.ZERO      # radians (yaw, pitch) added by right-drag
var orbit_node: Node3D             # optional orbit centre (e.g. the parachute after ejecting)
var weapon_node: Node3D            # F10 subject
var victim_node: Node3D            # F9 subject
var _prev_view := View.CHASE
var _orbit_yaw := 0.6
var _orbit_pitch := -0.25
var _orbit_dist := 25.0
var _special_timeout := 0.0
var _gaze_off := 0.0               # angle between gaze and the painted view's direction


func _ready() -> void:
	near = 0.3
	far = 140000.0
	fov = EXTERNAL_FOV


func snap() -> void:
	pass


## Choose a view. Selecting the front view again toggles the HUD zoom; selecting a special view
## (victim / weapon) again returns to the view it replaced.
func set_view(v: View) -> void:
	if v == View.COCKPIT_FRONT and view == View.COCKPIT_FRONT:
		hud_zoom = not hud_zoom
		return
	if v == view and v in [View.VICTIM, View.WEAPON]:
		view = _prev_view
		return
	if v in [View.VICTIM, View.WEAPON]:
		if view not in [View.VICTIM, View.WEAPON]:
			_prev_view = view
		_special_timeout = 0.0
	view = v
	free_look = Vector2.ZERO


## Z: toggle the front cockpit view's zoom onto the HUD (switching to the cockpit if needed).
func toggle_zoom() -> void:
	if view != View.COCKPIT_FRONT:
		view = View.COCKPIT_FRONT
		hud_zoom = true
	else:
		hud_zoom = not hud_zoom
	free_look = Vector2.ZERO


## Back to a normal view (after a restart, or when a special view's subject is gone).
func reset_view(v := View.CHASE) -> void:
	view = v
	orbit_node = null
	padlock = false
	free_look = Vector2.ZERO


## Step to the previous (-1) or next (+1) regular view.
func cycle(step: int) -> void:
	var i := CYCLE.find(view)
	view = CYCLE[posmod((i if i >= 0 else 0) + step, CYCLE.size())]
	free_look = Vector2.ZERO


func is_cockpit() -> bool:
	return view <= View.COCKPIT_REAR


## True when the painted cockpit (and HUD) can be shown for the current gaze.
func art_visible() -> bool:
	return is_cockpit() and _gaze_off < ART_LOOK_LIMIT


func update_view(delta: float) -> void:
	if target == null:
		return
	var t := target.global_transform
	target.set_exterior_visible(not is_cockpit())
	if cockpit:
		cockpit.visible = art_visible()
		cockpit.hud_zoom = hud_zoom and view == View.COCKPIT_FRONT
		cockpit.side = (view as int) as Cockpit.Side if is_cockpit() else Cockpit.Side.FRONT
	match view:
		View.CHASE:
			# rigidly attached behind and above the jet: no lag, so the view never trails a turn
			_set_projection(false)
			global_transform = Transform3D(t.basis, t * Vector3(0, 4.0, 20.0))
			look_at(t * Vector3(0, 1.2, -30.0), t.basis.y)
			return
		View.ORBIT:
			_set_projection(false)
			var centre := orbit_node.global_position if is_instance_valid(orbit_node) else t.origin
			_orbit_at(centre, _orbit_dist)
			return
		View.VICTIM:
			_set_projection(false)
			if not is_instance_valid(victim_node):
				view = _prev_view
				return
			_orbit_yaw += delta * 0.25
			_orbit_at(victim_node.global_position, maxf(_orbit_dist, 45.0))
			return
		View.WEAPON:
			_set_projection(false)
			if is_instance_valid(weapon_node) and weapon_node.is_inside_tree() and weapon_node.get("alive") != false:
				var vel: Vector3 = weapon_node.get("velocity") if weapon_node.get("velocity") != null else -weapon_node.global_basis.z
				var dir := vel.normalized() if vel.length() > 1.0 else -weapon_node.global_basis.z
				var up := Vector3.UP if absf(dir.y) < 0.97 else Vector3.FORWARD
				global_position = weapon_node.global_position - dir * 9.0 + up * 1.5
				look_at(weapon_node.global_position + dir * 40.0, up)
				_special_timeout = 2.0
			else:
				_special_timeout -= delta     # hold on the impact for a moment, then go back
				if _special_timeout <= 0.0:
					view = _prev_view
			return
	# cockpit views
	var look: Vector2 = LOOK[view]
	var b := t.basis * Basis.from_euler(Vector3(deg_to_rad(look.y), deg_to_rad(look.x), 0))
	var gaze := b
	var tgt: Node3D = target.weapons.target
	if padlock and is_instance_valid(tgt) and tgt.get("alive") == true:
		var to := (tgt.global_position - t * EYE).normalized()
		gaze = Basis.looking_at(to, t.basis.y)
	elif free_look != Vector2.ZERO:
		gaze = b * Basis.from_euler(Vector3(free_look.y, free_look.x, 0))
	_gaze_off = (-b.z).angle_to(-gaze.z)
	global_transform = Transform3D(gaze, t * EYE)
	_set_projection(view == View.COCKPIT_FRONT and art_visible())


func _orbit_at(centre: Vector3, dist: float) -> void:
	var dir := Vector3(cos(_orbit_pitch) * sin(_orbit_yaw), -sin(_orbit_pitch), cos(_orbit_pitch) * cos(_orbit_yaw))
	global_position = centre + dir * dist
	look_at(centre)


func _set_projection(boresight_offset: bool) -> void:
	var zoomed := cockpit != null and hud_zoom and view == View.COCKPIT_FRONT
	var cockpit_fov := COCKPIT_FOV * (float(cockpit.layout.get("zoom_fov_scale", 0.68)) if zoomed else 1.0)
	if not boresight_offset or cockpit == null or not cockpit.art_enabled:
		projection = PROJECTION_PERSPECTIVE
		fov = cockpit_fov if is_cockpit() else EXTERNAL_FOV
		return
	# Frustum whose optical axis lands on the art's boresight (fraction measured from the bottom).
	var vp := get_viewport().get_visible_rect().size
	var from_bottom := 1.0 - cockpit.boresight_screen().y / vp.y
	fov = cockpit_fov  # kept in sync for the HUD's angle-to-pixel scale
	var size := 2.0 * near * tan(deg_to_rad(cockpit_fov) * 0.5)
	set_frustum(size, Vector2(0, size * (0.5 - from_bottom)), near, far)


func handle_input(ev: InputEvent) -> void:
	if ev is InputEventMouseMotion and Input.is_mouse_button_pressed(MOUSE_BUTTON_RIGHT) and is_cockpit():
		free_look.x = clampf(free_look.x - ev.relative.x * 0.006, -PI * 0.9, PI * 0.9)
		free_look.y = clampf(free_look.y - ev.relative.y * 0.006, -1.2, 1.3)
		padlock = false
		return
	if ev is InputEventMouseButton and ev.button_index == MOUSE_BUTTON_RIGHT and not ev.pressed:
		free_look = Vector2.ZERO
		return
	if view not in [View.ORBIT, View.VICTIM]:
		return
	if ev is InputEventMouseMotion and Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
		_orbit_yaw -= ev.relative.x * 0.008
		_orbit_pitch = clampf(_orbit_pitch + ev.relative.y * 0.008, -1.4, 1.4)
	elif ev is InputEventMouseButton and ev.pressed:
		if ev.button_index == MOUSE_BUTTON_WHEEL_UP:
			_orbit_dist = maxf(8.0, _orbit_dist * 0.9)
		elif ev.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_orbit_dist = minf(400.0, _orbit_dist * 1.1)
