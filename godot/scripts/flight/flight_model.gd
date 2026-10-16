class_name FlightModel
extends RefCounted
## Fly-by-wire style flight model driven by each aircraft's original data
## (mass, fuel, thrust, afterburner, top speed, approach speed, G limit, roll/pitch gains).
##
## Units: SI, Godot axes (body forward = -Z, up = +Y, right = +X).
## Pitch stick commands load factor (neutral = 1 g), with an AoA limiter; roll stick commands
## roll rate; rudder commands a small yaw rate. Lift/drag/thrust/gravity are integrated for real,
## so energy, stalls and climb performance emerge from the numbers.

const G := 9.80665
const RHO0 := 1.225
const KT := 0.514444
const CL_ALPHA := 4.6            # per radian
const ALPHA_STALL := deg_to_rad(24.0)
const INDUCED_K := 0.12
const GROUND_FRICTION := 0.025
const BRAKE_FRICTION := 0.55
const MAX_SINK_LANDING := 4.5    # m/s; harder than this on the gear is a crash

# --- aircraft constants (derived in setup) ---
var aircraft_name := ""
var empty_mass := 8000.0
var fuel_capacity := 3000.0
var thrust_max := 100000.0       # N, full afterburner (or full power if no afterburner)
var thrust_mil := 65000.0        # N, 100% throttle without afterburner
var has_afterburner := true
var wing_area := 28.0            # m^2, from approach speed
var cd0_area := 1.0              # CD0 * S, from top speed
var max_g := 9.0
var max_roll_rate := deg_to_rad(240.0)
var max_pitch_rate := deg_to_rad(25.0)
var max_yaw_rate := deg_to_rad(12.0)
var gear_height := 1.6           # metres from origin to ground contact with gear down

# --- state ---
var position := Vector3.ZERO
var basis := Basis.IDENTITY
var velocity := Vector3.ZERO
var rates := Vector3.ZERO        # body rates: x = pitch (nose up +), y = yaw (nose left +), z = roll (left +)
var fuel := 0.0
var on_ground := false
var crashed := false
var crash_reason := ""

# --- controls ---
var stick := Vector2.ZERO        # x = roll right +, y = pull back +
var rudder := 0.0                # right +
var throttle := 0.7              # 0..1
var afterburner := false
var airbrake := false
var gear_down := true
var brakes := false

# --- telemetry for HUD ---
var airspeed := 0.0
var alpha := 0.0
var beta := 0.0
var load_factor := 1.0
var thrust := 0.0
var stalled := false
var _accel := Vector3.ZERO


func setup(data: Dictionary) -> void:
	var j: Dictionary = data.jdyn
	aircraft_name = data.name
	empty_mass = data.empty_mass_kg
	fuel_capacity = j.fuel_kg
	fuel = fuel_capacity
	has_afterburner = data.has_afterburner
	thrust_max = data.max_thrust_n
	thrust_mil = thrust_max * (0.62 if has_afterburner else 1.0)
	max_g = maxf(3.0, j.max_g)
	max_roll_rate = deg_to_rad(clampf(j.aileron * 8.0, 40.0, 320.0))
	max_pitch_rate = deg_to_rad(clampf(j.pitch_gain / 10.0, 4.0, 28.0))
	# Wing area so that the aircraft is at CLmax at ~approach speed / 1.25 with half fuel.
	var stall_speed := float(j.approach_speed_kt) * KT / 1.25
	if stall_speed < 40.0 or stall_speed > 120.0:
		stall_speed = 70.0
	var m_ref := empty_mass + fuel_capacity * 0.5
	var cl_max := CL_ALPHA * ALPHA_STALL * 0.9
	wing_area = 2.0 * m_ref * G / (RHO0 * stall_speed * stall_speed * cl_max)
	# Parasitic drag so that full thrust balances drag at top speed (jets at ~30 kft).
	var vmax := float(j.max_speed_ms)
	var h := 9000.0 if vmax > 300.0 else 1000.0
	var rho := _density(h)
	cd0_area = 2.0 * _thrust_at(thrust_max, rho) / (rho * vmax * vmax)


func mass() -> float:
	return empty_mass + fuel


func _density(h: float) -> float:
	return RHO0 * exp(-maxf(h, 0.0) / 8500.0)


func _thrust_at(t: float, rho: float) -> float:
	return t * pow(rho / RHO0, 0.7)


## Advance the simulation. `ground_height` gives terrain height (m) at an (x, z) position.
func step(dt: float, ground_height: Callable) -> void:
	if crashed:
		return
	var fwd := -basis.z
	var up := basis.y
	var right := basis.x
	var rho := _density(position.y)
	airspeed = velocity.length()
	var q := 0.5 * rho * airspeed * airspeed
	var m := mass()

	# --- aerodynamic angles ---
	var vb := basis.inverse() * velocity
	alpha = atan2(-vb.y, maxf(-vb.z, 0.1)) if airspeed > 1.0 else 0.0
	beta = atan2(vb.x, maxf(-vb.z, 0.1)) if airspeed > 1.0 else 0.0

	# --- lift with stall ---
	var cl := CL_ALPHA * alpha
	var a_abs := absf(alpha)
	stalled = a_abs > ALPHA_STALL
	if stalled:  # lift falls off past the stall, to ~55% at 40 degrees
		var post := clampf((a_abs - ALPHA_STALL) / deg_to_rad(16.0), 0.0, 1.0)
		cl = signf(alpha) * CL_ALPHA * ALPHA_STALL * lerpf(1.0, 0.55, post)
	var flaps := 1.0 + (0.25 if gear_down and airspeed < 110.0 else 0.0)
	var lift := cl * flaps * q * wing_area
	var vdir := velocity / airspeed if airspeed > 0.5 else fwd
	var lift_dir := right.cross(vdir).normalized() if airspeed > 0.5 else up

	# --- drag ---
	var cd_area := cd0_area + INDUCED_K * cl * cl * wing_area
	if gear_down: cd_area += 0.015 * wing_area
	if airbrake: cd_area += 0.06 * wing_area
	var mach := airspeed / 300.0
	if mach > 0.85:  # transonic drag rise, mostly cancelled again by Mach 1.3
		cd_area += cd0_area * 1.6 * clampf((mach - 0.85) / 0.2, 0.0, 1.0) * clampf(1.0 - (mach - 1.05) / 0.6, 0.35, 1.0)
	var drag := q * cd_area

	# --- thrust & fuel ---
	var ab_on := afterburner and has_afterburner and throttle > 0.95 and fuel > 0.0
	var t_static := throttle * thrust_mil + ((thrust_max - thrust_mil) if ab_on else 0.0)
	thrust = _thrust_at(t_static, rho) if fuel > 0.0 else 0.0
	var flow := (throttle * thrust_mil * 0.000022) + ((thrust_max - thrust_mil) * 0.000085 if ab_on else 0.0)
	fuel = maxf(fuel - flow * dt, 0.0)

	# --- side force (weathervane) ---
	var side := -right * beta * q * wing_area * 0.9

	var force := lift_dir * lift - vdir * drag + fwd * thrust + side + Vector3.DOWN * m * G
	_accel = force / m
	load_factor = lift / (m * G)

	# --- control laws ---
	var n_cmd := 1.0 + (stick.y * (max_g - 1.0) if stick.y >= 0.0 else stick.y * (1.0 + max_g * 0.35))
	var alpha_cmd := 0.0
	if q > 1.0:
		alpha_cmd = n_cmd * m * G / (CL_ALPHA * flaps * q * wing_area)
	alpha_cmd = clampf(alpha_cmd, -ALPHA_STALL * 0.5, ALPHA_STALL * 0.92)
	# rotation rate of the velocity vector about the wing axis, so the nose follows the path
	var path_rate := 0.0
	if airspeed > 5.0:
		var a_perp := _accel - vdir * _accel.dot(vdir)
		path_rate = vdir.cross(a_perp).dot(right) / airspeed
	var authority := clampf(q / 6000.0, 0.15, 1.0)
	var pitch_cmd := clampf(path_rate + (alpha_cmd - alpha) * 4.0, -max_pitch_rate, max_pitch_rate)
	if on_ground:  # nose wheel holds the nose down until the pilot rotates
		pitch_cmd = stick.y * max_pitch_rate * 0.6 * authority if stick.y > 0.05 else deg_to_rad(-3.0)
	var roll_cmd := -stick.x * max_roll_rate * authority
	var yaw_cmd := -rudder * max_yaw_rate * authority - beta * 1.5
	if on_ground:
		roll_cmd = 0.0
		yaw_cmd = -rudder * clampf(airspeed / 15.0, 0.0, 1.0) * deg_to_rad(25.0)
	rates.x = move_toward(rates.x, pitch_cmd, deg_to_rad(120.0) * dt)
	rates.y = move_toward(rates.y, yaw_cmd, deg_to_rad(60.0) * dt)
	rates.z = move_toward(rates.z, roll_cmd, max_roll_rate * 5.0 * dt)

	# --- integrate ---
	velocity += _accel * dt
	position += velocity * dt
	basis = basis * Basis(Vector3.RIGHT, rates.x * dt) * Basis(Vector3.UP, rates.y * dt) * Basis(Vector3.BACK, rates.z * dt)
	basis = basis.orthonormalized()

	_ground(dt, ground_height)


func _ground(dt: float, ground_height: Callable) -> void:
	var gh: float = ground_height.call(position.x, position.z)
	var clearance := gear_height if gear_down else gear_height * 0.45
	on_ground = position.y <= gh + clearance + 0.05
	if not on_ground:
		return
	if position.y < gh + clearance:
		var sink := -velocity.y
		var bank := absf(basis.get_euler().z)
		if not gear_down:
			return _crash("belly landing")
		if sink > MAX_SINK_LANDING:
			return _crash("hard landing (%.1f m/s)" % sink)
		if bank > deg_to_rad(20.0):
			return _crash("wingtip strike")
		position.y = gh + clearance
		velocity.y = maxf(velocity.y, 0.0)
	# level the wings and stop the nose digging in
	var e := basis.get_euler(EULER_ORDER_YXZ)
	e.z = 0.0
	e.x = clampf(e.x, deg_to_rad(-1.0), deg_to_rad(16.0))
	basis = Basis.from_euler(e, EULER_ORDER_YXZ)
	# wheels: rolling resistance / brakes along track, no sideways skid
	var fwd_flat := Vector3(-basis.z.x, 0, -basis.z.z).normalized()
	var v_fwd := velocity.dot(fwd_flat)
	var mu := BRAKE_FRICTION if brakes else GROUND_FRICTION
	v_fwd = move_toward(v_fwd, 0.0, mu * G * dt)
	velocity = fwd_flat * v_fwd + Vector3.UP * velocity.y


func _crash(reason: String) -> void:
	crashed = true
	crash_reason = reason
	velocity = Vector3.ZERO


## Called each step after `step` when not on the gear: terrain/sea impact.
func check_terrain(ground_height: Callable) -> void:
	if crashed or on_ground:
		return
	var gh: float = ground_height.call(position.x, position.z)
	if position.y < gh + 0.5:
		_crash("terrain impact")
