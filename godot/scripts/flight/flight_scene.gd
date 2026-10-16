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
var _training_skill := 0.75
var _wave := 0
var _gauntlet_wait := false
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
var flight_audio: FlightAudio
var autopilot := ""               # "", "takeoff", "cruise", "landing"
var _ap: AIPilot
var _ap_runway := {}
var _ap_nav := -1                 # nav point the cruise autopilot is flying to
var _ap_jumped := false           # the in-air jump to the destination has been made
var _view_before_death := CameraRig.View.CHASE
var mission: MissionRunner
var mission_name := ""
var nav_map: NavMap
var time_scale := 1.0
var _compress := 1.0              # Shift+Tab cycles 1x / 2x / 4x; Tab held = 6x
var _test := ""
var _test_t := 0.0
var _test_shots := {}


## Setting from the environment, else from the menu (GameData.launch), else the default.
func _env(name: String, default: String) -> String:
	if OS.get_environment(name) != "":
		return OS.get_environment(name)
	return str(GameData.launch.get(name, default))


func _ready() -> void:
	if _campaign() and OS.get_environment("SC_STORY_TEST") != "":
		_story_test_flight.call_deferred()
	theatre = _env("SC_THEATRE", theatre)
	aircraft_name = _env("SC_AIRCRAFT", aircraft_name)
	scenario = _env("SC_SCENARIO", scenario)
	bandits = int(_env("SC_BANDITS", str(bandits)))
	_test = "flight" if OS.get_environment("SC_FLIGHT_TEST") != "" else ("combat" if OS.get_environment("SC_COMBAT_TEST") != "" else "")
	if OS.get_environment("SC_MISSION_TEST") != "":
		_test = "mission"
		scenario = "mission"
	if OS.get_environment("SC_ATTACK_TEST") != "":
		_test = "attack"
		scenario = "strike"
	if _test == "combat":
		scenario = "dogfight"
		bandits = int(_env("SC_BANDITS", "1"))
	var mission_data := {}
	if scenario == "mission":
		mission_name = _env("SC_MISSION", "MISN-1A")
		mission_data = JSON.parse_string(FileAccess.get_file_as_string(GameData.path("missions/%s.json" % mission_name)))
		var wf := GameData.path("worlds/%s.json" % String(mission_data.world))
		if not FileAccess.file_exists(wf):
			wf = GameData.path("worlds/TO_%s.json" % String(mission_data.world))
		var w: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(wf)) if FileAccess.file_exists(wf) else {}
		theatre = String(w.get("terrain", mission_data.world))
	_setup_world()
	world = CombatWorld.new()
	terrain = Terrain.new()
	terrain.world = world
	world.terrain = terrain
	add_child(terrain)
	add_child(world)
	terrain.load_theatre(theatre, true)
	_runways = JSON.parse_string(FileAccess.get_file_as_string(GameData.path("terrain/%s/runways.json" % theatre)))
	world.aircraft_destroyed.connect(_on_destroyed)
	world.weapon_released.connect(func(w, by): if by == player: cam.weapon_node = w)
	world.ground_destroyed.connect(func(u): if u.last_attacker == player: cam.victim_node = u)
	world.impact_imminent.connect(_on_impact_imminent)
	world.weapon_outcome.connect(_on_weapon_outcome)
	world.aircraft_crippled.connect(_on_crippled)
	player = Aircraft.create(aircraft_name)
	player.team = 0
	world.add_aircraft(player)
	cam = CameraRig.new()
	cam.target = player
	cam.ground_height = world.ground_height
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
	nav_map = NavMap.new()
	nav_map.visible = false
	ui.add_child(nav_map)
	var fa := FlightAudio.new()
	flight_audio = fa
	add_child(fa)
	cam.doppler_tracking = Camera3D.DOPPLER_TRACKING_PHYSICS_STEP
	if scenario == "mission":
		mission = MissionRunner.new()
		add_child(mission)
		mission.setup(mission_data, world, terrain, player)
		mission.radio.connect(hud.add_radio)
		if _test == "mission":
			mission.radio.connect(func(c, t): print("RADIO %6.1f %s: %s" % [_test_t, c, t.replace("\n", " ")]))
			mission.mission_over.connect(func(w, r): print("OVER %6.1f won=%s %s" % [_test_t, w, r]))
		mission.mission_over.connect(_on_mission_over)
		hud.mission = mission
		nav_map.setup(terrain, mission, player)
		fa.setup(player, world, mission)
		hud.message = String(mission_data.title).to_upper() + "   —   N: navigation map"
		get_tree().create_timer(6.0).timeout.connect(func(): if hud.message.ends_with("map"): hud.message = "")
		return
	fa.setup(player, world, null)
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
	cam.reset_view(_view_before_death)
	if scenario == "strike":
		_setup_strike()
		return
	if scenario == "dogfight" or scenario == "gauntlet":
		# training missions (the front end's wizard) give enemy groups, altitude and skill
		var alt_m := float(GameData.launch.get("altitude_ft", 10000)) * 0.3048
		var p := Vector3(0, alt_m, 20000.0)
		bandits = maxi(bandits, 0)
		player.place(p, 0.0, 230.0, false)
		_power = 0.85
		_training_skill = [0.55, 0.75, 0.95][clampi(int(GameData.launch.get("skill", 1)), 0, 2)]
		var groups: Array = GameData.launch.get("groups", [["MIG29", bandits]])
		if scenario == "gauntlet":
			_wave = 1
			groups = [["MIG21", 1]]
		_spawn_groups(groups, p)
		if _test == "combat":
			player.ai = AIPilot.new(player, 0.9)
		var n := 0
		for g in groups:
			n += int(g[1])
		bandits = n
		if bandits > 0:
			hud.message = "%d BANDIT%s AHEAD — T: target  SPACE: fire  W: weapon  G: guns" % [bandits, "S" if bandits > 1 else ""]
			get_tree().create_timer(5.0).timeout.connect(func(): if hud.message.begins_with(str(bandits)): hud.message = "")
	else:
		reset_on_runway(_runway_index)


## Enemy groups [[aircraft, count], ...] ahead of `p`, a group per altitude step.
func _spawn_groups(groups: Array, p: Vector3) -> void:
	var k := 0
	for gi in groups.size():
		for i in int(groups[gi][1]):
			var b := Aircraft.create(String(groups[gi][0]))
			b.team = 1
			b.ai = AIPilot.new(b, _training_skill)
			world.add_aircraft(b)
			b.place(p + Vector3(-1500.0 + 3000.0 * (k % 3), 300.0 * gi, -16000.0 - 1500.0 * (k / 3)), 180.0, 220.0, false)
			k += 1


## The gauntlet: when a wave is down, the next comes in, bigger and better flown.
func _gauntlet_step() -> void:
	if world.aircraft.any(func(x): return x.team == 1 and x.alive) or not player.alive or _gauntlet_wait:
		return
	_gauntlet_wait = true
	hud.message = "WAVE %d CLEARED" % _wave
	await get_tree().create_timer(5.0).timeout
	_gauntlet_wait = false
	_wave += 1
	_training_skill = minf(0.5 + 0.08 * _wave, 0.98)
	var types := ["MIG21", "MIG29", "SU27"]
	var fwd := -player.global_transform.basis.z
	_spawn_groups([[types[mini((_wave - 1) / 2, 2)], mini(1 + _wave / 2, 5)]], player.global_position + Vector3(fwd.x, 0, fwd.z).normalized() * 4000.0)
	hud.message = "WAVE %d" % _wave
	get_tree().create_timer(3.0).timeout.connect(func(): if hud.message.begins_with("WAVE"): hud.message = "")


## Strike practice: an armoured position with AAA and SAM cover 10 km ahead.
func _setup_strike() -> void:
	var start_pos := Vector3(0, 0, 25000.0)
	start_pos.y = world.ground_height(start_pos) + 1200.0
	player.place(start_pos, 0.0, 210.0, false)
	_power = 0.8
	var centre := start_pos + Vector3(0, 0, -11000.0)
	var layout := [["T-72", Vector3(0, 0, 0)], ["T-72", Vector3(60, 0, 40)], ["T-72", Vector3(-70, 0, 30)],
		["ZSU-23", Vector3(150, 0, -120)], ["MOBSAMLN", Vector3(-400, 0, -350)], ["STASAMLN", Vector3(500, 0, -600)],
		["HANGB22", Vector3(-200, 0, 260)]]
	for item in layout:
		var u := GroundUnit.create(item[0], 1)
		world.add_ground_unit(u)
		var p: Vector3 = centre + item[1]
		p.y = world.ground_height(p)
		u.global_position = p
		if OS.get_environment("SC_NO_SAMS") != "":
			u.ammo = 0
	hud.message = "STRIKE PRACTICE — W: select AGM-65 / MK82   T: ground target   SPACE: fire / release"
	get_tree().create_timer(6.0).timeout.connect(func(): if hud.message.begins_with("STRIKE"): hud.message = "")


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
	cam.reset_view(_view_before_death)
	var p := player.fm.position if player.alive else Vector3.ZERO
	p.y = maxf(terrain.height_at(p.x, p.z), 0.0) + 1500.0
	player.place(p, 0.0, 200.0, false)
	_power = 0.85


# ---------------------------------------------------------------- simulation
func _physics_process(delta: float) -> void:
	if OS.get_environment("SC_AP_TEST") != "":
		_ap_test(delta)
	if autopilot != "":
		_autopilot_step(delta)
	elif _test == "mission":
		_mission_test(delta)
	elif _test == "attack":
		_attack_test(delta)
	elif OS.get_environment("SC_EJECT_TEST") != "":
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
	time_scale = 6.0 if Input.is_key_pressed(KEY_TAB) and not Input.is_key_pressed(KEY_SHIFT) else _compress
	_acc += delta * time_scale
	var h := 1.0 / PHYSICS_HZ
	while _acc >= h:
		for a in world.aircraft:
			a.simulate(h, terrain)
		world.step(h)
		_acc -= h
	if mission:
		mission.step(delta * time_scale)
	if _chute:
		_chute.global_position += Vector3(player.fm.velocity.x * 0.02, -6.0, player.fm.velocity.z * 0.02) * delta
		if _chute.global_position.y < world.ground_height(_chute.global_position) + 1.0:
			_chute.global_position.y = world.ground_height(_chute.global_position) + 1.0


func _process(delta: float) -> void:
	cam.update_view(delta)
	if scenario == "gauntlet":
		_gauntlet_step()
	# the original drew distant aircraft larger than life so they stay visible; same here
	for a in world.aircraft:
		if a != player:
			var d := a.global_position.distance_to(cam.global_position)
			a.visual_scale = clampf(pow(d / 800.0, 0.6), 1.0, 6.0)


func _on_mission_over(success: bool, reason: String) -> void:
	hud.result = {"won": success, "reason": reason}
	if _campaign():
		Campaign.last_result = {"won": success, "reason": reason}
		get_tree().create_timer(5.0).timeout.connect(_back_to_campaign)


## Flown from the campaign: the result goes back to the story when the mission ends.
func _campaign() -> bool:
	return GameData.launch.get("campaign", "") != "" and Campaign.returning


## SC_STORY_TEST: a campaign mission "flown" by the test ends as won after a few seconds.
func _story_test_flight() -> void:
	await get_tree().create_timer(4.0).timeout
	print("STORY flew %s" % mission_name)
	Campaign.last_result = {"won": true, "reason": "test"}
	_back_to_campaign()


func _back_to_campaign() -> void:
	if is_inside_tree():
		get_tree().change_scene_to_file("res://scenes/campaign.tscn")
	_compress = 1.0


# ---------------------------------------------------------------- victim camera
## F9 toggles it. When on, the view cuts to the target as the player's missile or bomb arrives
## (or when the gun cripples/kills an aircraft): a hit, miss or outright kill cuts back after a
## few seconds; a crippled aircraft is followed down until it blows up on the ground, and the
## view cuts back a couple of seconds after that.
var victim_cam := true
var _victim_weapon: Node3D


func _victim_ok() -> bool:
	return victim_cam and player.alive and not player.ejected and autopilot == "" \
			and cam.view not in [CameraRig.View.WEAPON, CameraRig.View.ORBIT]


func _on_impact_imminent(weapon: Node3D, target: Node3D) -> void:
	if weapon.get("shooter") != player or not _victim_ok() or not is_instance_valid(target):
		return
	if not (target is Aircraft or target is GroundUnit or target == weapon):
		return   # chasing a decoy
	if cam.view == CameraRig.View.VICTIM and cam.victim_node != target and cam.victim_node.get("crippled") == true:
		return   # already following a falling jet down
	_victim_weapon = weapon
	cam.show_victim(target)


func _on_weapon_outcome(weapon: Node3D, target: Node3D, result: String) -> void:
	if _test == "combat" and weapon.get("shooter") == player:
		print("VICTIM %.1f outcome %s view=%d" % [_test_t, result, cam.view])
	if weapon != _victim_weapon or cam.view != CameraRig.View.VICTIM:
		return
	_victim_weapon = null
	match result:
		"miss":
			cam.victim_done(1.5)
		"hit", "killed":
			cam.victim_done(3.0)
		"crippled":
			pass       # followed until it hits the ground (_on_destroyed)


func _on_crippled(a: Aircraft, by: Node3D) -> void:
	if by == player and cam.view != CameraRig.View.VICTIM and _victim_ok():
		cam.show_victim(a)


func _on_destroyed(a: Aircraft) -> void:
	if a != player and a.last_attacker == player:
		if cam.view == CameraRig.View.VICTIM and cam.victim_node == a:
			cam.victim_done(2.0 if a.fm.crashed else 3.0)   # down on the ground / blown apart
		elif _victim_ok() and cam.view != CameraRig.View.VICTIM and _victim_weapon == null:
			cam.show_victim(a)                               # e.g. a gun kill
			cam.victim_done(3.0)
		cam.victim_node = a
	if _test == "combat" and a == player:
		print("EVENT %.1f: player destroyed (%s)" % [_test_t, a.death_reason])
		cam.orbit_node = a
		for delay in [0.25, 0.8]:
			get_tree().create_timer(delay).timeout.connect(func(): _shot("kill_%.2f" % delay))
	if a == player:
		if player.ejected:
			return
		hud.message = "%s   —   Ctrl+R: restart on runway   Shift+R: restart airborne" % ("SHOT DOWN" if a.death_reason == "shot down" else "CRASHED: " + player.fm.crash_reason.to_upper())
		_remember_view()
		cam.view = CameraRig.View.ORBIT
		return
	if mission:
		var who := mission.actor_for(a)
		if who and not who.friendly:
			hud.add_radio("", "Splash one!")
		return
	if _test == "combat":
		print("EVENT %.1f: %s destroyed (%s)" % [_test_t, a.data.name, a.death_reason])
		for delay in [0.25, 0.8]:
			get_tree().create_timer(delay).timeout.connect(func(): _shot("kill_%.2f" % delay))
	var left := world.aircraft.filter(func(x): return x.team == 1 and x.alive).size()
	hud.message = "SPLASH ONE!" if left > 0 else "ALL BANDITS DESTROYED   —   Ctrl+R: runway   Shift+R: airborne"
	if left > 0:
		get_tree().create_timer(3.0).timeout.connect(func(): if hud.message == "SPLASH ONE!": hud.message = "")


func _remember_view() -> void:
	if cam.view in CameraRig.CYCLE and cam.view != CameraRig.View.ORBIT:
		_view_before_death = cam.view


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
	_remember_view()
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
			if mission:
				get_tree().reload_current_scene()
			else:
				start()
		elif k == KEY_N:
			nav_map.visible = not nav_map.visible
		elif k == KEY_TAB and ev.shift_pressed:
			_compress = {1.0: 2.0, 2.0: 4.0, 4.0: 1.0}.get(_compress, 1.0)
			hud.add_radio("", "Time compression %dx" % int(_compress))
		elif k == KEY_R and ev.shift_pressed and mission == null:
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
			cam.set_view(CameraRig.View.COCKPIT_FRONT)   # again: zoom onto the HUD
		elif k == KEY_F2:
			cam.set_view(CameraRig.View.CHASE)
		elif k == KEY_F3:
			cam.set_view(CameraRig.View.COCKPIT_LEFT)
		elif k == KEY_F4:
			cam.set_view(CameraRig.View.COCKPIT_RIGHT)
		elif k == KEY_F5:
			cam.set_view(CameraRig.View.COCKPIT_REAR)
		elif k == KEY_F6:
			cam.set_view(CameraRig.View.ORBIT)
		elif k == KEY_F9:   # victim camera on/off
			victim_cam = not victim_cam
			if not victim_cam and cam.view == CameraRig.View.VICTIM:
				cam.victim_done(0.0)
			hud.add_radio("", "VICTIM CAMERA " + ("ON" if victim_cam else "OFF"))
		elif k == KEY_Z:
			cam.toggle_zoom()
		elif k == KEY_A:
			if autopilot != "":
				_autopilot_off("AUTOPILOT OFF")
			else:
				_autopilot_on()
		elif k == KEY_F10:
			cam.set_view(CameraRig.View.WEAPON)
		elif k == KEY_Y:
			if not cam.is_cockpit():
				cam.set_view(CameraRig.View.COCKPIT_FRONT)
			cam.padlock = not cam.padlock and w.target != null
		elif k == KEY_BRACKETLEFT:
			cam.cycle(-1)
		elif k == KEY_BRACKETRIGHT:
			cam.cycle(1)
		elif k == KEY_ESCAPE:
			if _campaign():
				if Campaign.last_result.is_empty() or not (mission and mission.over):
					Campaign.last_result = {"won": false, "reason": "Mission aborted."}
				_back_to_campaign()
			else:
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
		cam.set_view(CameraRig.View.COCKPIT_FRONT)
	elif ev.is_action_pressed("view_chase"):
		cam.set_view(CameraRig.View.CHASE)
	elif ev.is_action_pressed("view_orbit"):
		cam.set_view(CameraRig.View.ORBIT)


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


# ---------------------------------------------------------------- autopilot
## A: auto take-off on the runway; in the air, one fly-by shot and then the jet emerges at the
## current nav point (or wherever enemies would be met on the way, wingmen coming along); for a
## landing nav point the jump goes to the approach, which is then flown down to the runway.
## The music is left to the director (it changes only for enemies and the mission's end).
## Refused when enemies are near; any stick or throttle input takes control back.
const AP_THREAT_RANGE := 8.0 * 1852.0


func _autopilot_on() -> void:
	if not player.alive or player.ejected:
		return
	if _enemies_near(AP_THREAT_RANGE):
		hud.add_radio("", "AUTOPILOT UNAVAILABLE — ENEMIES NEARBY")
		return
	_ap = AIPilot.new(player, 0.8)
	_ap_jumped = false
	var n: Dictionary = mission.current_nav() if mission else {}
	if player.fm.on_ground:
		autopilot = "takeoff"
	elif not n.is_empty() and int(n.op) == MissionRunner.OP_LAND or n.is_empty() and not _runways.is_empty():
		autopilot = "landing"
		_ap_runway = _nearest_runway(n.pos if not n.is_empty() else player.global_position)
	elif not n.is_empty():
		autopilot = "cruise"
		_ap_nav = mission.nav_index
	else:
		hud.add_radio("", "AUTOPILOT: NO NAVIGATION POINT")
		return
	hud.add_radio("", "AUTOPILOT: " + {"takeoff": "TAKE-OFF", "cruise": "TO " + String(n.get("label", "")).to_upper(), "landing": "APPROACH"}[autopilot])
	cam.start_flyby()


func _autopilot_off(reason: String) -> void:
	if autopilot == "":
		return
	autopilot = ""
	_compress = 1.0
	cam.end_flyby()
	if OS.get_environment("SC_AP_TEST") != "":
		print("AP off: ", reason)
	player.fm.brakes = false
	if reason != "":
		hud.add_radio("", reason)


func _enemies_near(radius: float) -> bool:
	return _enemies_near_point(player.global_position, radius)


func _nearest_runway(p: Vector3) -> Dictionary:
	var best := {}
	var bd := INF
	for r in _runways:
		var c: Array = r.center_ft
		var d := Vector2(c[0] * FT - p.x, -c[1] * FT - p.z).length()
		if d < bd:
			bd = d
			best = r
	return best


func _autopilot_step(delta: float) -> void:
	var fm := player.fm
	# any pilot input disengages
	if absf(Input.get_axis("roll_left", "roll_right")) > 0.3 or absf(Input.get_axis("pitch_down", "pitch_up")) > 0.3 \
			or Input.is_action_pressed("throttle_up") or Input.is_action_pressed("throttle_down"):
		if OS.get_environment("SC_AP_TEST") != "":
			print("AP input: roll %.2f pitch %.2f" % [Input.get_axis("roll_left", "roll_right"), Input.get_axis("pitch_down", "pitch_up")])
		_autopilot_off("AUTOPILOT OFF")
		return
	if autopilot != "takeoff" and _enemies_near(AP_THREAT_RANGE):
		_autopilot_off("AUTOPILOT DISENGAGED — ENEMIES NEARBY")
		return
	_ap._decoy_timer -= delta
	match autopilot:
		"takeoff":
			if fm.on_ground:
				_ap._takeoff_roll()
			else:
				var ahead := -player.global_basis.z
				_ap._cruise(player.global_position + Vector3(ahead.x, 0, ahead.z).normalized() * 3000.0 + Vector3.UP * 600.0, 1.0)
				if player.global_position.y - world.ground_height(player.global_position) > 60.0:
					fm.gear_down = false
				if player.global_position.y - world.ground_height(player.global_position) > 450.0:
					_autopilot_off("AUTOPILOT: TAKE-OFF COMPLETE")
		"cruise":
			var n: Dictionary = mission.current_nav() if mission else {}
			if n.is_empty():
				_autopilot_off("AUTOPILOT OFF")
				return
			var target: Vector3 = n.pos
			target.y = maxf(player.global_position.y, world.ground_height(target) + 900.0)
			_ap._cruise(target, 0.85)
			fm.gear_down = false
			if cam.flyby_passes >= 1 and not _ap_jumped:
				_ap_jumped = true
				var label := String(n.get("label", "")).to_upper()
				if _ap_jump(target, 600.0):
					_autopilot_off("AUTOPILOT DISENGAGED — ENEMIES AHEAD")
				else:
					_autopilot_off("AUTOPILOT: ARRIVED AT " + label)
		"landing":
			if _ap_runway.is_empty():
				_autopilot_off("AUTOPILOT: NO RUNWAY")
				return
			var c: Array = _ap_runway.center_ft
			var heading: float = _ap_runway.heading_deg
			var dir := Vector3(sin(deg_to_rad(heading)), 0, -cos(deg_to_rad(heading)))
			var centre := Vector3(c[0] * FT, 0, -c[1] * FT)
			var half := float(_ap_runway.length_ft) * 0.5 * FT
			# land toward the runway end that faces us
			if dir.dot(centre - player.global_position) < 0.0:
				dir = -dir
			var touchdown := centre - dir * (half - 60.0)
			var approach := touchdown - dir * 6000.0
			approach.y = world.ground_height(touchdown) + 6000.0 * tan(deg_to_rad(3.0)) + 30.0
			if not _ap_jumped:
				var lined_up := player.global_position.distance_to(approach) < 2500.0 \
						and (-player.global_basis.z).angle_to(dir) < deg_to_rad(20.0)
				if not lined_up and cam.flyby_passes < 1:
					_ap._cruise(approach + Vector3.UP * 300.0, 0.85)
					fm.gear_down = false
					return
				_ap_jumped = true
				if not lined_up:
					# emerge on final, gear down at approach speed, lined up with the runway
					if _ap_jump(approach, 0.0, dir, 85.0):
						_autopilot_off("AUTOPILOT DISENGAGED — ENEMIES AHEAD")
						return
					fm.gear_down = true
					fm.throttle = 0.3
					_ap._approach_passed = true
			_ap.land_to(world, approach, touchdown, true)
			if fm.on_ground and fm.airspeed < 5.0:
				_autopilot_off("AUTOPILOT: LANDED")


## The autopilot's jump: the jet (and wingmen near it) reappear `short` metres before `dest`,
## heading along `along` (default: the travel direction), or where enemies would first be met
## on the way. Returns true when stopped short by enemies.
func _ap_jump(dest: Vector3, short: float, along := Vector3.ZERO, new_speed := -1.0) -> bool:
	var from := player.global_position
	var flat := Vector3(dest.x - from.x, 0, dest.z - from.z)
	var dir := flat.normalized() if flat.length() > 1.0 else -player.global_basis.z
	var to := dest - dir * short
	var stopped := false
	# walk the route: stop where an enemy would come within autopilot range
	var dist := Vector2(to.x - from.x, to.z - from.z).length()
	var step := 500.0
	var d := 0.0
	while d < dist:
		var p := from + dir * d
		p.y = to.y
		if _enemies_near_point(p, AP_THREAT_RANGE * 1.15):
			to = from + dir * maxf(d - 1500.0, 0.0)
			to.y = maxf(from.y, world.ground_height(to) + 600.0)
			stopped = true
			break
		d += step
	var heading_dir := along if along != Vector3.ZERO and not stopped else dir
	var heading := rad_to_deg(atan2(heading_dir.x, -heading_dir.z))
	to.y = maxf(to.y, world.ground_height(to) + 300.0)
	var speed := player.fm.velocity.length() if new_speed < 0.0 or stopped else new_speed
	var old_basis := player.fm.basis
	var old_pos := from
	player.fm.position = to
	player.fm.basis = Basis(Vector3.UP, deg_to_rad(-heading))
	player.fm.velocity = -player.fm.basis.z * speed
	player.fm.rates = Vector3.ZERO
	var turn := Basis(Vector3.UP, deg_to_rad(-heading)) * old_basis.inverse()
	turn = Basis(Vector3.UP, turn.get_euler().y)
	for a in world.aircraft:
		if a == player or not a.alive or a.team != player.team or a.global_position.distance_to(old_pos) > 6000.0:
			continue
		var rel := turn * (a.fm.position - old_pos)
		a.fm.position = to + rel
		a.fm.position.y = maxf(a.fm.position.y, world.ground_height(a.fm.position) + 200.0)
		a.fm.basis = turn * a.fm.basis
		a.fm.velocity = turn * a.fm.velocity.normalized() * speed if new_speed >= 0.0 else turn * a.fm.velocity
	_acc = 0.0
	return stopped


func _enemies_near_point(p: Vector3, radius: float) -> bool:
	for a in world.aircraft:
		if a.alive and a.team != player.team and a.global_position.distance_to(p) < radius:
			return true
	for u in world.ground_units:
		if u.alive and u.team >= 0 and u.team != player.team and not u.weapon.is_empty() \
				and u.global_position.distance_to(p) < float(u.weapon.get("range_ft", 0)) * FT:
			return true
	return false


## Autopilot test: engages A whenever the autopilot is idle, logs phases, saves fly-by frames.
var _ap_t := 0.0
var _ap_log := 0.0


func _ap_test(delta: float) -> void:
	_ap_t += delta * time_scale
	if _ap_t < 1.0:
		return
	if autopilot == "" and not _test_shots.has("ap_done") and int(_ap_t) % 3 == 0:
		if player.fm.on_ground and _ap_t > 5.0 and _test_shots.has("ap_engaged"):
			_test_shots["ap_done"] = true
			print("AP finished on the ground at t=%.0f" % _ap_t)
			get_tree().create_timer(1.0).timeout.connect(get_tree().quit)
			return
		_autopilot_on()
		_test_shots["ap_engaged"] = true
		print("AP engage t=%.0f -> %s" % [_ap_t, autopilot])
	if _ap_t - _ap_log > 10.0:
		_ap_log = _ap_t
		var gp := world.ground_height(player.global_position)
		print("AP t=%5.0f mode=%s agl=%5.0fm spd=%3.0fkt gear=%s nav=%s music=%d crashed=%s" % [_ap_t, autopilot,
			player.global_position.y - gp, player.fm.airspeed / 0.5144, player.fm.gear_down,
			mission.current_nav().get("label", "-") if mission else "-", Audio.engine.current, player.fm.crashed])
		if not _test_shots.has("flyby_to") and autopilot == "takeoff":
			_test_shots["flyby_to"] = true
			_shot("ap_flyby_takeoff")
		if not _test_shots.has("flyby") and autopilot == "cruise":
			_test_shots["flyby"] = true
			_shot("ap_flyby")
	if _ap_t > float(_env("SC_TEST_SECONDS", "400")) or player.fm.crashed:
		print("AP end t=%.0f crashed=%s (%s) on_ground=%s" % [_ap_t, player.fm.crashed, player.fm.crash_reason, player.fm.on_ground])
		get_tree().quit()


## Mission smoke test: a simple autopilot flies the player along the navigation points at 4x.
var _last_nav := -1
var _test_pilot: AIPilot


func _mission_test(delta: float) -> void:
	if mission == null:
		print("MISSION FAILED TO LOAD")
		get_tree().quit()
		return
	_compress = 6.0
	_test_t += delta * time_scale
	var fm := player.fm
	var n := mission.current_nav()
	if mission.nav_index != _last_nav:
		_last_nav = mission.nav_index
		print("NAV %6.1f -> %d/%d %s" % [_test_t, mission.nav_index + 1, mission.nav.size(), n.get("label", "(done)")])
	if fm.on_ground and not n.is_empty() and int(n.op) != MissionRunner.OP_LAND:
		fm.throttle = 1.0
		fm.brakes = false
		fm.stick = Vector2(0, 0.5 if fm.airspeed > 80.0 else 0.0)
	elif not n.is_empty():
		var cargo := mission.actor_by_id(8)
		var target: Vector3 = n.pos
		if cargo and cargo.spawned and cargo.alive() and mission.nav_index >= 2 and mission.flags[12] == 0:
			target = cargo.position() + Vector3.UP * 300.0   # escort the cargo plane until it lands
		target.y = maxf(target.y, world.ground_height(target) + 900.0)
		if _test_pilot == null:
			_test_pilot = AIPilot.new(player, 0.8)
		_test_pilot._cruise(target, 0.9)
		if fm.position.y - world.ground_height(fm.position) > 100.0:
			fm.gear_down = false
	if int(_test_t) % 4 == 0 and int(_test_t - delta * time_scale) % 4 != 0:
		var gp := world.ground_height(player.global_position)
		print("  P %6.1f alt=%5.0fft gnd=%5.0fft spd=%3.0fkt pitch=%5.1f roll=%5.1f tgt_alt=%5.0fft" % [_test_t, player.global_position.y / FT, gp / FT,
			fm.airspeed / 0.5144, rad_to_deg(asin(-fm.basis.z.y)), rad_to_deg(fm.basis.get_euler(EULER_ORDER_YXZ).z), (n.pos.y if not n.is_empty() else 0.0) / FT])
	if int(_test_t) % 20 == 0 and int(_test_t - delta * time_scale) % 20 != 0:
		var b := []
		for a in mission.actors:
			if a.spawned and not a.is_player:
				b.append("%s[%s%s cmd=%x%s]" % [a.name, "A" if a.active else "-", "" if a.alive() else "X", a.command,
					(" " + (a.node as Aircraft).ai._state) if a.node is Aircraft and (a.node as Aircraft).ai else ""])
		print("T %6.1f area=%d flags=%s | %s" % [_test_t, mission.player_area, Array(mission.flags.slice(0, 16)), " ".join(b)])
	for mark in [3.0, 120.0, 240.0, 360.0]:
		if _test_t >= mark and not _test_shots.has(mark):
			_test_shots[mark] = true
			cam.view = CameraRig.View.CHASE
			nav_map.visible = mark == 120.0
			_shot("t%03d" % int(mark))
	if _test_t > float(_env("SC_TEST_SECONDS", "1500")) or mission.over:
		if not _test_shots.has("end"):
			_test_shots["end"] = true
			print("UNKNOWN OPS ", mission.unknown_ops)
			_shot("end")
			get_tree().create_timer(1.0).timeout.connect(get_tree().quit)


func _strike_centre() -> Vector3:
	for u in world.ground_units:
		if u.team == 1 and u.alive:
			return u.global_position
	return player.global_position


## Scripted strike: Maverick on the nearest target, then a Mk 82 pass using the CCIP solution.
var _attack_phase := 0


func _attack_test(delta: float) -> void:
	_test_t += delta
	var fm := player.fm
	var w := player.weapons
	if _test_pilot == null:
		_test_pilot = AIPilot.new(player, 0.8)
		world.ground_destroyed.connect(func(u): print("EVENT %.1f: %s destroyed" % [_test_t, u.unit_name]))
	if int(_test_t * 2) != int((_test_t - delta) * 2):
		var geo := ""
		if w.target:
			var to: Vector3 = w.target.global_position - player.global_position
			geo = "off=%.1f dist=%.0f" % [rad_to_deg((-player.global_basis.z).angle_to(to)), to.length()]
		print(geo, " t=%5.1f phase=%d wpn=%s tgt=%s lock=%.1f hp=%d alt=%.0fm missiles=%d bombs=%d" % [_test_t, _attack_phase, w.selected_name(),
			w.target.name if w.target else "-", w.lock_progress, player.hp, fm.position.y - world.ground_height(fm.position), world.missiles.size(), world.bombs.size()])
	_test_pilot._decoy_timer -= delta
	if _test_pilot.defend(world):
		return
	match _attack_phase:
		0:  # Maverick
			w.select_kind("ag")
			if w.target == null:
				w.cycle_target(world, 1)
			var aim_at := _strike_centre()
			if w.target:
				aim_at = w.target.global_position
			_test_pilot._cruise(aim_at + Vector3.UP * (250.0 if w.target else 500.0), 0.8)
			if w.locked():
				w.fire(delta, world, true)
				_shot("maverick")
				_attack_phase = 1
		1:  # bomb run on the next target: level at ~300 m AGL, release on the CCIP
			w.select_kind("bomb")
			if w.target == null or w.target.get("alive") != true:
				w.cycle_target(world, 1)
			if w.target == null:
				_test_pilot._cruise(_strike_centre() + Vector3.UP * 400.0, 0.8)
			if w.target:
				var tp: Vector3 = w.target.global_position
				var aim := Vector3(tp.x, world.ground_height(tp) + 350.0, tp.z)
				_test_pilot._cruise(aim, 0.8)
				var impact := Bomb.predict_impact(player.global_transform * Vector3(0, -1.5, 0), fm.velocity, world)
				var flat := Vector2(impact.x - tp.x, impact.z - tp.z).length()
				if flat < 35.0:
					for i in 3:
						w.fire(delta, world, true)
						w._cooldown = 0.0
					_shot("release")
					_attack_phase = 2
		2:  # egress
			_test_pilot._cruise(player.global_position + Vector3(0, 400, 3000), 1.0)
	if _test_t > 12.0 and not _test_shots.has("cam"):
		_test_shots["cam"] = true
		cam.view = CameraRig.View.COCKPIT_FRONT
	if _attack_phase == 2 and not _test_shots.has("aftermath") and world.bombs.is_empty():
		_test_shots["aftermath"] = true
		var wt: Node3D = null
		for u in world.ground_units:
			if u.team == 1:
				wt = u
				break
		cam.orbit_node = wt
		cam.view = CameraRig.View.ORBIT
		get_tree().create_timer(1.0).timeout.connect(func(): _shot("aftermath"))
		get_tree().create_timer(3.0).timeout.connect(func():
			var left := world.ground_units.filter(func(u): return u.team == 1 and u.alive).size()
			print("RESULT player_hp=%d enemies_left=%d" % [player.hp, left])
			get_tree().quit())
	if _test_t > 120.0 or not player.alive:
		print("RESULT timeout/dead player_alive=%s" % player.alive)
		get_tree().quit()


## AI vs AI: the player's jet is flown by an AIPilot against one MiG-29.
var _test_last_view := -1


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
	if OS.get_environment("SC_CAM_TEST") != "":
		_camera_tour()
		return
	if cam.view != _test_last_view:
		print("VIEW %.1f: %d -> %d%s" % [t, _test_last_view, cam.view, " (victim crippled=%s)" % cam.victim_node.get("crippled") if cam.view == CameraRig.View.VICTIM else ""])
		_test_last_view = cam.view
		if cam.view == CameraRig.View.VICTIM:
			var n := _test_shots.size()
			for delay in [0.3, 2.0]:
				get_tree().create_timer(delay).timeout.connect(func(): _shot("victim_%d_%.1f" % [n, delay]))
	var plan := {5.0: CameraRig.View.CHASE, 20.0: CameraRig.View.COCKPIT_FRONT, 35.0: CameraRig.View.CHASE,
		50.0: CameraRig.View.COCKPIT_FRONT, 65.0: CameraRig.View.ORBIT}
	if world.aircraft.filter(func(x): return x.team == 1 and not x.alive).is_empty():
		_test_views(plan)
	var bandits_alive := world.aircraft.filter(func(x): return x.team == 1 and x.alive).size()
	var linger := float(_env("SC_TEST_LINGER", "2"))
	if t > float(_env("SC_TEST_SECONDS", "90")) or not player.alive or (bandits_alive == 0 and not _test_shots.has("end")):
		if not _test_shots.has("end"):
			_test_shots["end"] = true
			print("RESULT t=%.1f player_alive=%s bandits_alive=%d" % [t, player.alive, bandits_alive])
			get_tree().create_timer(linger).timeout.connect(get_tree().quit)


## Camera checks: far-aircraft scale, HUD zoom, padlock, off-screen target box, weapon/victim cams.
func _camera_tour() -> void:
	var steps := [
		[2.0, "far_chase", func(): cam.set_view(CameraRig.View.CHASE)],
		[4.0, "hud_zoom", func():
			cam.set_view(CameraRig.View.COCKPIT_FRONT)
			cam.set_view(CameraRig.View.COCKPIT_FRONT)],
		[6.0, "front_target", func(): cam.set_view(CameraRig.View.COCKPIT_FRONT)],
		[16.0, "padlock", func(): cam.padlock = player.weapons.target != null],
		[18.0, "edge_box", func():
			cam.padlock = false
			cam.free_look = Vector2(1.3, 0.1)],
		[19.0, "edge_box_hud", func():
			cam.free_look = Vector2.ZERO
			cam.set_view(CameraRig.View.CHASE)],
		[21.0, "weapon_cam", func(): cam.set_view(CameraRig.View.WEAPON)],
		[30.0, "victim_cam", func():
			cam.victim_node = world.aircraft[1] if world.aircraft.size() > 1 and world.aircraft[1].alive else cam.victim_node
			cam.set_view(CameraRig.View.VICTIM)],
	]
	for st in steps:
		if _test_t >= st[0] - 0.15 and not _test_shots.has(st[1] + "_set"):
			_test_shots[st[1] + "_set"] = true
			st[2].call()
		if _test_t >= st[0] and not _test_shots.has(st[1]):
			_test_shots[st[1]] = true
			print("CAM %s view=%d zoom=%s padlock=%s target=%s weapon=%s victim=%s" % [st[1], cam.view, cam.hud_zoom, cam.padlock,
				player.weapons.target != null, is_instance_valid(cam.weapon_node), is_instance_valid(cam.victim_node)])
			_shot("cam_" + st[1])


func _test_views(plan: Dictionary) -> void:
	for mark in plan:
		if _test_t >= mark - 0.1 and not _test_shots.has(mark - 0.1):
			_test_shots[mark - 0.1] = true
			if cam.view != CameraRig.View.VICTIM:
				cam.view = plan[mark]
		if _test_t >= mark and not _test_shots.has(mark):
			_test_shots[mark] = true
			_shot("t%02d" % int(mark))


func _shot(tag: String) -> void:
	await RenderingServer.frame_post_draw
	var out := ProjectSettings.globalize_path("res://").path_join("../shots/flight")
	DirAccess.make_dir_recursive_absolute(out)
	get_viewport().get_texture().get_image().save_png(out.path_join("%s_%s_%s.png" % [_test if _test != "" else "play", aircraft_name, tag]))
