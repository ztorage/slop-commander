extends Node3D
## Flight and combat. Scenarios (SC_SCENARIO): "free" (runway start) or "dogfight" (airborne vs
## SC_BANDITS MiG-29s). Other overrides: SC_THEATRE, SC_AIRCRAFT.
## Tests: SC_FLIGHT_TEST=1 scripted takeoff/turn; SC_COMBAT_TEST=1 the player is flown by the AI
## against one bandit, logging events and saving screenshots.

const FT := 0.3048
const PHYSICS_HZ := 120.0

var theatre := "SANFRAN"
var aircraft_name := "F-16DES"
var scenario := "free"
var bandits := 2
var terrain: Terrain
var world: CombatWorld
var player: Aircraft
var cam: CameraRig
var hud: FlightHud
var _runways: Array = []
var _runway_index := 0
var _acc := 0.0
var _power := 0.0                 # 0..1 military throttle, 1..2 afterburner stages
var _chute: Node3D
var _test := ""
var _test_t := 0.0
var _test_shots := {}


## Setting from the environment, else from the menu (GameData.launch), else the default.
func _env(name: String, default: String) -> String:
	if OS.get_environment(name) != "":
		return OS.get_environment(name)
	return str(GameData.launch.get(name, default))


func _ready() -> void:
	theatre = _env("SC_THEATRE", theatre)
	aircraft_name = _env("SC_AIRCRAFT", aircraft_name)
	scenario = _env("SC_SCENARIO", scenario)
	bandits = int(_env("SC_BANDITS", str(bandits)))
	_test = "flight" if OS.get_environment("SC_FLIGHT_TEST") != "" else ("combat" if OS.get_environment("SC_COMBAT_TEST") != "" else "")
	if _test == "combat":
		scenario = "dogfight"
		bandits = 1
	_setup_world()
	terrain = Terrain.new()
	add_child(terrain)
	terrain.load_theatre(theatre, true)
	_runways = JSON.parse_string(FileAccess.get_file_as_string(GameData.path("terrain/%s/runways.json" % theatre)))
	world = CombatWorld.new()
	world.terrain = terrain
	add_child(world)
	world.aircraft_destroyed.connect(_on_destroyed)
	player = Aircraft.create(aircraft_name)
	player.team = 0
	world.add_aircraft(player)
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
		ck.world = world
		ui.add_child(ck)
		cam.cockpit = ck
	hud = FlightHud.new()
	hud.aircraft = player
	hud.camera = cam
	hud.cockpit = cam.cockpit
	hud.world = world
	ui.add_child(hud)
	start()


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
	env.glow_enabled = true
	env.glow_intensity = 0.6
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


# ---------------------------------------------------------------- scenario setup
func start() -> void:
	hud.message = ""
	_clear_combat()
	if _chute:
		_chute.queue_free()
		_chute = null
	cam.target = player
	cam.orbit_node = null
	if scenario == "dogfight":
		var p := Vector3(0, 3000.0, 20000.0)
		bandits = maxi(bandits, 0)
		player.place(p, 0.0, 230.0, false)
		_power = 0.85
		for i in bandits:
			var b := Aircraft.create("MIG29")
			b.team = 1
			b.ai = AIPilot.new(b, 0.75)
			world.add_aircraft(b)
			b.place(p + Vector3(-1500.0 + 3000.0 * i, 300.0 * i, -16000.0), 180.0, 220.0, false)
		if _test == "combat":
			player.ai = AIPilot.new(player, 0.9)
		if bandits > 0:
			hud.message = "%d BANDIT%s AHEAD — T: target  SPACE: fire  W: weapon  G: guns" % [bandits, "S" if bandits > 1 else ""]
			get_tree().create_timer(5.0).timeout.connect(func(): if hud.message.begins_with(str(bandits)): hud.message = "")
	else:
		reset_on_runway(_runway_index)


func _clear_combat() -> void:
	for a in world.aircraft.duplicate():
		if a != player:
			world.aircraft.erase(a)
			a.queue_free()
	player.weapons = WeaponSystem.new()
	player.weapons.setup(player)


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
	var start_pos := Vector3(c[0] * FT, 0, -c[1] * FT) - dir * half
	start_pos.y = maxf(terrain.height_at(start_pos.x, start_pos.z), 0.0) + player.fm.gear_height
	player.place(start_pos, heading, 0.0, true)
	_power = 0.0


func reset_in_air() -> void:
	hud.message = ""
	var p := player.fm.position if player.alive else Vector3.ZERO
	p.y = maxf(terrain.height_at(p.x, p.z), 0.0) + 1500.0
	player.place(p, 0.0, 200.0, false)
	_power = 0.85


# ---------------------------------------------------------------- simulation
func _physics_process(delta: float) -> void:
	if OS.get_environment("SC_EJECT_TEST") != "":
		_test_t += delta
		if _test_t > 2.0 and not player.ejected:
			cam.view = CameraRig.View.COCKPIT_FRONT
			eject()
		for mark in [2.3, 2.9, 5.0]:
			if _test_t >= mark and not _test_shots.has(mark):
				_test_shots[mark] = true
				_shot("eject_%.1f" % mark)
		if _test_t > 5.5:
			get_tree().quit()
	elif _test == "flight":
		_flight_autopilot(delta)
	elif _test == "combat":
		_combat_test(delta)
	else:
		_read_controls(delta)
	_acc += delta
	var h := 1.0 / PHYSICS_HZ
	while _acc >= h:
		for a in world.aircraft:
			a.simulate(h, terrain)
		world.step(h)
		_acc -= h
	if _chute:
		_chute.global_position += Vector3(player.fm.velocity.x * 0.02, -6.0, player.fm.velocity.z * 0.02) * delta
		if _chute.global_position.y < world.ground_height(_chute.global_position) + 1.0:
			_chute.global_position.y = world.ground_height(_chute.global_position) + 1.0


func _process(delta: float) -> void:
	cam.update_view(delta)


func _on_destroyed(a: Aircraft) -> void:
	if _test == "combat" and a == player:
		print("EVENT %.1f: player destroyed (%s)" % [_test_t, a.death_reason])
		cam.orbit_node = a
		for delay in [0.25, 0.8]:
			get_tree().create_timer(delay).timeout.connect(func(): _shot("kill_%.2f" % delay))
	if a == player:
		if player.ejected:
			return
		hud.message = "%s   —   Ctrl+R: restart on runway   Shift+R: restart airborne" % ("SHOT DOWN" if a.death_reason == "shot down" else "CRASHED: " + player.fm.crash_reason.to_upper())
		cam.view = CameraRig.View.ORBIT
		return
	if _test == "combat":
		print("EVENT %.1f: %s destroyed (%s)" % [_test_t, a.data.name, a.death_reason])
		cam.orbit_node = a          # watch the kill from outside
		cam.view = CameraRig.View.ORBIT
		for delay in [0.25, 0.8]:
			get_tree().create_timer(delay).timeout.connect(func(): _shot("kill_%.2f" % delay))
	var left := world.aircraft.filter(func(x): return x.team == 1 and x.alive).size()
	hud.message = "SPLASH ONE!" if left > 0 else "ALL BANDITS DESTROYED   —   Ctrl+R: runway   Shift+R: airborne"
	if left > 0:
		get_tree().create_timer(3.0).timeout.connect(func(): if hud.message == "SPLASH ONE!": hud.message = "")


func eject() -> void:
	if player.ejected or not player.alive:
		return
	player.ejected = true
	player.fm.stick = Vector2(0, 0.3)
	player.fm.throttle = 0.0
	player.fm.afterburner = 0.0
	if cam.cockpit:
		cam.view = CameraRig.View.COCKPIT_FRONT
		cam.cockpit.play_eject()
	await get_tree().create_timer(1.6).timeout
	_chute = GameData.load_model("CHUTE")
	if _chute:
		add_child(_chute)
		_chute.global_position = player.global_position + Vector3.UP * 20.0
		cam.orbit_node = _chute
	cam.view = CameraRig.View.ORBIT
	hud.message = "EJECTED   —   Ctrl+R: restart on runway   Shift+R: restart airborne"


func _read_controls(delta: float) -> void:
	var fm := player.fm
	if player.ejected or not player.alive:
		return
	fm.stick = Vector2(Input.get_axis("roll_left", "roll_right"), Input.get_axis("pitch_down", "pitch_up"))
	fm.rudder = Input.get_axis("yaw_left", "yaw_right")
	_power = clampf(_power + Input.get_axis("throttle_down", "throttle_up") * 0.5 * delta, 0.0, 2.0 if fm.has_afterburner else 1.0)
	fm.throttle = minf(_power, 1.0)
	fm.afterburner = clampf(_power - 1.0, 0.0, 1.0)
	player.weapons.fire(delta, world, Input.is_action_pressed("fire"))


func _unhandled_input(ev: InputEvent) -> void:
	cam.handle_input(ev)
	var fm := player.fm
	var w := player.weapons
	if ev is InputEventKey and ev.pressed and not ev.echo:
		var k: int = ev.keycode
		if k >= KEY_1 and k <= KEY_5:            # military power 20%..100%
			_power = (k - KEY_0) * 0.2
		elif k >= KEY_6 and k <= KEY_9 or k == KEY_0:   # afterburner 20%..100%
			_power = 1.0 + (5 if k == KEY_0 else k - KEY_5) * 0.2
		elif k == KEY_E and ev.ctrl_pressed:
			eject()
		elif k == KEY_R and ev.ctrl_pressed:
			scenario = "free" if scenario == "free" else scenario
			start()
		elif k == KEY_R and ev.shift_pressed:
			reset_in_air()
		elif k == KEY_T:
			if ev.ctrl_pressed:
				w.target = null
			else:
				w.cycle_target(world, -1 if ev.shift_pressed else 1)
		elif k == KEY_W and ev.shift_pressed:
			pass  # jettison: not modelled yet
		elif k == KEY_W:
			w.next_weapon()
		elif k == KEY_G:
			w.toggle_guns()
		elif k == KEY_SEMICOLON:
			w.drop_decoy(world, false)
		elif k == KEY_APOSTROPHE:
			w.drop_decoy(world, true)
		elif k == KEY_L and not fm.on_ground:
			fm.gear_down = not fm.gear_down
		elif k == KEY_B:
			if fm.on_ground:
				fm.brakes = not fm.brakes
			else:
				fm.airbrake = not fm.airbrake
		elif k == KEY_D and cam.cockpit:
			cam.cockpit.right_mfd = 1 - cam.cockpit.right_mfd
		elif k == KEY_I and ev.ctrl_pressed and cam.cockpit:
			cam.cockpit.art_enabled = not cam.cockpit.art_enabled
		elif k == KEY_F1:
			cam.view = CameraRig.View.COCKPIT_FRONT
		elif k == KEY_F2:
			cam.view = CameraRig.View.CHASE
		elif k == KEY_F3:
			cam.view = CameraRig.View.COCKPIT_LEFT
		elif k == KEY_F4:
			cam.view = CameraRig.View.COCKPIT_RIGHT
		elif k == KEY_F5:
			cam.view = CameraRig.View.COCKPIT_REAR
		elif k == KEY_F6:
			cam.view = CameraRig.View.ORBIT
		elif k == KEY_BRACKETLEFT:
			cam.cycle(-1)
		elif k == KEY_BRACKETRIGHT:
			cam.cycle(1)
		elif k == KEY_ESCAPE:
			get_tree().change_scene_to_file("res://scenes/boot.tscn")
	if ev.is_action_pressed("next_weapon"):
		w.next_weapon()
	elif ev.is_action_pressed("target_next"):
		w.cycle_target(world, 1)
	elif ev.is_action_pressed("decoys"):
		w.drop_decoy(world, true)
		w.drop_decoy(world, false)
	elif ev.is_action_pressed("gear") and not fm.on_ground:
		fm.gear_down = not fm.gear_down
	elif ev.is_action_pressed("brakes"):
		if fm.on_ground:
			fm.brakes = not fm.brakes
		else:
			fm.airbrake = not fm.airbrake
	elif ev.is_action_pressed("reset_runway"):
		start()
	elif ev.is_action_pressed("view_cockpit"):
		cam.view = CameraRig.View.COCKPIT_FRONT
	elif ev.is_action_pressed("view_chase"):
		cam.view = CameraRig.View.CHASE
	elif ev.is_action_pressed("view_orbit"):
		cam.view = CameraRig.View.ORBIT


# ---------------------------------------------------------------- automated tests
## Scripted flight: takeoff roll, rotate, climb, gear up, turn; screenshots in each view.
func _flight_autopilot(delta: float) -> void:
	_test_t += delta
	var fm := player.fm
	var t := _test_t
	fm.throttle = 1.0
	fm.afterburner = 1.0 if t < 25.0 else 0.0
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
		fm.stick.x = clampf(rad_to_deg(fm.basis.get_euler(EULER_ORDER_YXZ).z) / 30.0, -1, 1)
	var plan := {2.0: CameraRig.View.COCKPIT_FRONT, 12.0: CameraRig.View.COCKPIT_FRONT, 16.0: CameraRig.View.COCKPIT_LEFT,
		18.0: CameraRig.View.COCKPIT_RIGHT, 20.0: CameraRig.View.COCKPIT_REAR, 23.0: CameraRig.View.COCKPIT_FRONT, 28.0: CameraRig.View.CHASE}
	_test_views(plan)
	if t > 30.0 or player.fm.crashed:
		get_tree().quit()


## AI vs AI: the player's jet is flown by an AIPilot against one MiG-29.
func _combat_test(delta: float) -> void:
	_test_t += delta
	var t := _test_t
	if int(t) != int(t - delta):
		var b: Aircraft = world.aircraft[1] if world.aircraft.size() > 1 else null
		print("t=%3d  player hp=%3d wpn=%s lock=%.1f tgt=%s %s | bandit hp=%s dist=%s state=%s | missiles=%d" % [
			int(t), player.hp, player.weapons.selected_name(), player.weapons.lock_progress,
			player.weapons.target != null, player.ai._state,
			str(int(b.hp)) if b else "-", str(int(b.global_position.distance_to(player.global_position))) if b else "-",
			b.ai._state if b and b.ai else "-", world.missiles.size()])
	var plan := {5.0: CameraRig.View.CHASE, 20.0: CameraRig.View.COCKPIT_FRONT, 35.0: CameraRig.View.CHASE,
		50.0: CameraRig.View.COCKPIT_FRONT, 65.0: CameraRig.View.ORBIT}
	if world.aircraft.filter(func(x): return x.team == 1 and not x.alive).is_empty():
		_test_views(plan)
	var bandits_alive := world.aircraft.filter(func(x): return x.team == 1 and x.alive).size()
	if t > 90.0 or not player.alive or (bandits_alive == 0 and not _test_shots.has("end")):
		if not _test_shots.has("end"):
			_test_shots["end"] = true
			print("RESULT t=%.1f player_alive=%s bandits_alive=%d" % [t, player.alive, bandits_alive])
			get_tree().create_timer(2.0).timeout.connect(get_tree().quit)


func _test_views(plan: Dictionary) -> void:
	for mark in plan:
		if _test_t >= mark - 0.1 and not _test_shots.has(mark - 0.1):
			_test_shots[mark - 0.1] = true
			cam.view = plan[mark]
		if _test_t >= mark and not _test_shots.has(mark):
			_test_shots[mark] = true
			_shot("t%02d" % int(mark))


func _shot(tag: String) -> void:
	await RenderingServer.frame_post_draw
	var out := ProjectSettings.globalize_path("res://").path_join("../shots/flight")
	DirAccess.make_dir_recursive_absolute(out)
	get_viewport().get_texture().get_image().save_png(out.path_join("%s_%s_%s.png" % [_test if _test != "" else "play", aircraft_name, tag]))
