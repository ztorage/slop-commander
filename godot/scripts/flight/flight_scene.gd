extends Node3D
## Free flight: player aircraft in a theatre, starting on a runway.
## Environment overrides: SC_THEATRE (default SANFRAN), SC_AIRCRAFT (default F-16DES).
## Autopilot test: SC_FLIGHT_TEST=1 runs a scripted takeoff/climb/turn, saving screenshots.

const FT := 0.3048
const PHYSICS_HZ := 120.0

var theatre := "SANFRAN"
var aircraft_name := "F-16DES"
var terrain: Terrain
var player: Aircraft
var cam: CameraRig
var hud: FlightHud
var _runways: Array = []
var _runway_index := 0
var _acc := 0.0
var _test := false
var _test_t := 0.0
var _test_shots := {}


func _ready() -> void:
	theatre = OS.get_environment("SC_THEATRE") if OS.get_environment("SC_THEATRE") != "" else theatre
	aircraft_name = OS.get_environment("SC_AIRCRAFT") if OS.get_environment("SC_AIRCRAFT") != "" else aircraft_name
	_test = OS.get_environment("SC_FLIGHT_TEST") != ""
	_setup_world()
	terrain = Terrain.new()
	add_child(terrain)
	terrain.load_theatre(theatre, true)
	_runways = JSON.parse_string(FileAccess.get_file_as_string(GameData.path("terrain/%s/runways.json" % theatre)))
	player = Aircraft.create(aircraft_name)
	add_child(player)
	cam = CameraRig.new()
	cam.target = player
	add_child(cam)
	cam.make_current()
	var ui := CanvasLayer.new()
	add_child(ui)
	var ckpt_name := "F16-CKPT" if aircraft_name.begins_with("F-16") else ("F22-CKPT" if aircraft_name == "F-22" else "")
	if ckpt_name != "" and DirAccess.dir_exists_absolute(GameData.path("cockpits/" + ckpt_name)):
		var ck := Cockpit.create(ckpt_name)
		ck.aircraft = player
		ui.add_child(ck)
		cam.cockpit = ck
	hud = FlightHud.new()
	hud.aircraft = player
	hud.camera = cam
	hud.cockpit = cam.cockpit
	ui.add_child(hud)
	reset_on_runway(0)


func _setup_world() -> void:
	var env := Environment.new()
	var sky_mat := ProceduralSkyMaterial.new()
	sky_mat.sky_top_color = Color(0.2, 0.4, 0.74)
	sky_mat.sky_horizon_color = Color(0.66, 0.76, 0.88)
	sky_mat.ground_horizon_color = Color(0.66, 0.76, 0.88)
	sky_mat.ground_bottom_color = Color(0.3, 0.32, 0.3)
	var sky := Sky.new()
	sky.sky_material = sky_mat
	env.background_mode = Environment.BG_SKY
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_energy = 0.8
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	env.fog_enabled = true
	env.fog_mode = Environment.FOG_MODE_DEPTH
	env.fog_light_color = Color(0.68, 0.77, 0.88)
	env.fog_depth_begin = 15000.0
	env.fog_depth_end = 110000.0
	env.fog_sky_affect = 0.0
	env.fog_aerial_perspective = 0.6
	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-42, -40, 0)
	sun.light_energy = 1.25
	sun.shadow_enabled = true
	sun.directional_shadow_max_distance = 1500.0
	add_child(sun)


func reset_on_runway(i: int) -> void:
	hud.message = ""
	if _runways.is_empty():
		reset_in_air()
		return
	_runway_index = posmod(i, _runways.size())
	var r: Dictionary = _runways[_runway_index]
	var c: Array = r.center_ft
	var heading: float = r.heading_deg
	var half := float(r.length_ft) * 0.5 * FT - 40.0
	var dir := Vector3(sin(deg_to_rad(heading)), 0, -cos(deg_to_rad(heading)))
	var start := Vector3(c[0] * FT, 0, -c[1] * FT) - dir * half
	start.y = maxf(terrain.height_at(start.x, start.z), 0.0) + player.fm.gear_height
	player.place(start, heading, 0.0, true)
	cam.snap()


func reset_in_air() -> void:
	hud.message = ""
	var p := player.fm.position if not player.fm.crashed else Vector3.ZERO
	p.y = maxf(terrain.height_at(p.x, p.z), 0.0) + 1500.0
	player.place(p, 0.0, 200.0, false)
	cam.snap()


func _physics_process(delta: float) -> void:
	_read_controls(delta)
	if _test:
		_autopilot(delta)
	# fixed sub-steps for a stable integration independent of frame rate
	_acc += delta
	var h := 1.0 / PHYSICS_HZ
	while _acc >= h:
		player.simulate(h, terrain)
		_acc -= h
	if player.fm.crashed and hud.message == "":
		hud.message = "CRASHED: %s   —   R: runway   T: airborne" % player.fm.crash_reason


func _process(delta: float) -> void:
	cam.update_view(delta)


func _read_controls(delta: float) -> void:
	if _test:
		return
	var fm := player.fm
	fm.stick = Vector2(Input.get_axis("roll_left", "roll_right"), Input.get_axis("pitch_down", "pitch_up"))
	fm.rudder = Input.get_axis("yaw_left", "yaw_right")
	fm.throttle = clampf(fm.throttle + Input.get_axis("throttle_down", "throttle_up") * 0.5 * delta, 0.0, 1.0)
	fm.brakes = Input.is_action_pressed("brakes")


func _unhandled_input(ev: InputEvent) -> void:
	cam.handle_input(ev)
	var fm := player.fm
	if ev is InputEventKey and ev.pressed and not ev.echo:
		if ev.keycode >= KEY_1 and ev.keycode <= KEY_9:
			fm.throttle = (ev.keycode - KEY_0) / 10.0
		elif ev.keycode == KEY_0:
			fm.throttle = 1.0
		elif ev.keycode == KEY_I and ev.ctrl_pressed and cam.cockpit:
			cam.cockpit.art_enabled = not cam.cockpit.art_enabled  # original's Ctrl-I: cockpit on/off
		elif ev.keycode == KEY_M and cam.cockpit:
			cam.cockpit.right_mfd = 1 - cam.cockpit.right_mfd
		elif ev.keycode == KEY_F4:
			cam.view = CameraRig.View.COCKPIT_LEFT
		elif ev.keycode == KEY_F5:
			cam.view = CameraRig.View.COCKPIT_RIGHT
		elif ev.keycode == KEY_F6:
			cam.view = CameraRig.View.COCKPIT_REAR
		elif ev.keycode == KEY_BRACKETLEFT:
			cam.cycle(-1)
		elif ev.keycode == KEY_BRACKETRIGHT:
			cam.cycle(1)
		elif ev.keycode == KEY_ESCAPE:
			get_tree().change_scene_to_file("res://scenes/boot.tscn")
	if ev.is_action_pressed("afterburner"):
		fm.afterburner = not fm.afterburner
		if fm.afterburner:
			fm.throttle = 1.0
	elif ev.is_action_pressed("gear") and not fm.on_ground:
		fm.gear_down = not fm.gear_down
	elif ev.is_action_pressed("airbrake"):
		fm.airbrake = not fm.airbrake
	elif ev.is_action_pressed("reset_runway"):
		reset_on_runway(_runway_index + (1 if player.fm.crashed else 0))
	elif ev.is_action_pressed("reset_air"):
		reset_in_air()
	elif ev.is_action_pressed("view_cockpit"):
		cam.view = CameraRig.View.COCKPIT_FRONT
	elif ev.is_action_pressed("view_chase"):
		cam.view = CameraRig.View.CHASE
		cam.snap()
	elif ev.is_action_pressed("view_orbit"):
		cam.view = CameraRig.View.ORBIT


## Scripted flight for automated verification: takeoff roll, rotate, climb, gear up, turn.
func _autopilot(delta: float) -> void:
	_test_t += delta
	var fm := player.fm
	var t := _test_t
	fm.throttle = 1.0
	fm.afterburner = t < 25.0
	fm.stick = Vector2.ZERO
	if fm.on_ground and fm.airspeed > 70.0:
		fm.stick.y = 0.6
	elif not fm.on_ground and t < 20.0:
		fm.stick.y = 0.15 if rad_to_deg(asin(-fm.basis.z.y)) < 15.0 else -0.05
	if not fm.on_ground and fm.position.y > 120.0:
		fm.gear_down = false
	if t > 20.0 and t < 32.0:
		fm.stick.x = 0.35 if rad_to_deg(-fm.basis.get_euler(EULER_ORDER_YXZ).z) < 60.0 else 0.0
		fm.stick.y = 0.55
	elif t >= 32.0:
		var roll := rad_to_deg(-fm.basis.get_euler(EULER_ORDER_YXZ).z)
		fm.stick.x = clampf(-roll / 30.0, -1, 1)
	var plan := {2.0: CameraRig.View.COCKPIT_FRONT, 12.0: CameraRig.View.COCKPIT_FRONT, 16.0: CameraRig.View.COCKPIT_LEFT,
		18.0: CameraRig.View.COCKPIT_RIGHT, 20.0: CameraRig.View.COCKPIT_REAR, 23.0: CameraRig.View.COCKPIT_FRONT, 28.0: CameraRig.View.CHASE}
	for mark in plan:
		if t >= mark - 0.1 and not _test_shots.has(mark - 0.1):
			_test_shots[mark - 0.1] = true
			cam.view = plan[mark]  # switch a moment early so the frame is rendered in that view
		if t >= mark and not _test_shots.has(mark):
			_test_shots[mark] = true
			_shot("t%02d" % int(mark))
	if int(t * 2) != int((t - delta) * 2):
		print("t=%5.1f gnd=%s v=%5.1fkt alt=%6.0fft pitch=%5.1f roll=%5.1f aoa=%4.1f G=%4.1f thr=%.0fN fuel=%.0f %s" % [
			t, fm.on_ground, fm.airspeed / 0.514444, fm.position.y / FT, rad_to_deg(asin(-fm.basis.z.y)),
			rad_to_deg(-fm.basis.get_euler(EULER_ORDER_YXZ).z), rad_to_deg(fm.alpha), fm.load_factor,
			fm.thrust, fm.fuel, fm.crash_reason])
	if t > 30.0 or fm.crashed:
		get_tree().quit()


func _shot(tag: String) -> void:
	await RenderingServer.frame_post_draw
	var out := ProjectSettings.globalize_path("res://").path_join("../shots/flight")
	DirAccess.make_dir_recursive_absolute(out)
	get_viewport().get_texture().get_image().save_png(out.path_join("%s_%s.png" % [aircraft_name, tag]))
