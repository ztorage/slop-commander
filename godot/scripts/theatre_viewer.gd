extends Node3D
## Free-fly viewer for converted theatres.
##   Right-drag or click-to-capture mouse: look    WASD: move    Q/E: down/up
##   Shift: x10 speed    Wheel: change speed    [ / ]: previous/next theatre
##   O: toggle objects   Esc: release mouse / back to menu
## Batch screenshots: SHOT_THEATRES=SANFRAN,ARENA godot --path godot res://scenes/theatre_viewer.tscn

const FT := 0.3048

var _theatres: Array = []
var _index := 0
var _terrain: Terrain
var _cam: Camera3D
var _label: Label
var _yaw := 0.0
var _pitch := -0.25
var _speed := 150.0  # m/s
var _captured := false
var _show_objects := true


func _ready() -> void:
	_theatres = JSON.parse_string(FileAccess.get_file_as_string(GameData.path("terrain/theatres.json")))
	_setup_world()
	_cam = Camera3D.new()
	_cam.far = 120000.0
	_cam.near = 1.0
	_cam.fov = 65.0
	add_child(_cam)
	_cam.make_current()
	var ui := CanvasLayer.new()
	add_child(ui)
	_label = Label.new()
	_label.position = Vector2(16, 12)
	_label.add_theme_font_size_override("font_size", 16)
	_label.add_theme_color_override("font_outline_color", Color.BLACK)
	_label.add_theme_constant_override("outline_size", 6)
	ui.add_child(_label)

	var shots := OS.get_environment("SHOT_THEATRES")
	if shots != "":
		_shoot.call_deferred(shots.split(","))
		return
	_open(_find("SANFRAN"))


func _setup_world() -> void:
	var env := Environment.new()
	var sky_mat := ProceduralSkyMaterial.new()
	sky_mat.sky_top_color = Color(0.22, 0.42, 0.75)
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
	env.fog_depth_end = 100000.0
	env.fog_sky_affect = 0.0
	env.fog_aerial_perspective = 0.6
	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-42, -40, 0)
	sun.light_energy = 1.25
	sun.shadow_enabled = true
	sun.directional_shadow_max_distance = 4000.0
	add_child(sun)


func _find(theatre_name: String) -> int:
	for i in _theatres.size():
		if _theatres[i].name == theatre_name:
			return i
	return 0


func _open(i: int) -> void:
	_index = posmod(i, _theatres.size())
	if _terrain:
		_terrain.queue_free()
	_terrain = Terrain.new()
	add_child(_terrain)
	_terrain.load_theatre(_theatres[_index].name, true)
	_terrain.get_node_or_null("Objects").visible = _show_objects if _terrain.has_node("Objects") else false
	# start near the first placed object (usually an airfield), else map centre
	var start := Vector3.ZERO
	var objs = JSON.parse_string(FileAccess.get_file_as_string(
		GameData.path("terrain/%s/objects.json" % _theatres[_index].name)))
	if objs and objs.size() > 0:
		var p: Array = objs[0].pos_ft
		start = Vector3(p[0] * FT, 0, -p[1] * FT)
	start.y = _terrain.height_at(start.x, start.z)
	_yaw = deg_to_rad(200.0)
	_pitch = -0.22
	_cam.position = start + Vector3(900, 450, 1500)


func _process(delta: float) -> void:
	var b := Basis.from_euler(Vector3(_pitch, _yaw, 0))
	_cam.basis = b
	var mv := Vector3(
		Input.get_axis("ui_left", "ui_right") + float(Input.is_key_pressed(KEY_D)) - float(Input.is_key_pressed(KEY_A)),
		float(Input.is_key_pressed(KEY_E)) - float(Input.is_key_pressed(KEY_Q)),
		float(Input.is_key_pressed(KEY_S)) - float(Input.is_key_pressed(KEY_W)) + Input.get_axis("ui_up", "ui_down"))
	var sp := _speed * (10.0 if Input.is_key_pressed(KEY_SHIFT) else 1.0)
	_cam.position += (b * mv) * sp * delta
	if _terrain:
		var ground := _terrain.height_at(_cam.position.x, _cam.position.z)
		_cam.position.y = maxf(_cam.position.y, ground + 3.0)
		_label.text = "%s   (%d/%d)\nAltitude %d ft MSL, %d ft AGL   speed %d kt\n\n%s" % [
			_theatres[_index].name, _index + 1, _theatres.size(),
			_cam.position.y / FT, (_cam.position.y - ground) / FT, sp * 1.944,
			"Mouse: look (click to capture)   WASD/QE: fly   Shift: fast   Wheel: speed   [ ]: theatre   O: objects   Esc: menu"]


func _unhandled_input(ev: InputEvent) -> void:
	if ev is InputEventMouseButton and ev.pressed:
		match ev.button_index:
			MOUSE_BUTTON_LEFT:
				_captured = true
				Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
			MOUSE_BUTTON_WHEEL_UP:
				_speed = minf(_speed * 1.25, 3000.0)
			MOUSE_BUTTON_WHEEL_DOWN:
				_speed = maxf(_speed / 1.25, 5.0)
	elif ev is InputEventMouseMotion and (_captured or Input.is_mouse_button_pressed(MOUSE_BUTTON_RIGHT)):
		_yaw -= ev.relative.x * 0.003
		_pitch = clampf(_pitch - ev.relative.y * 0.003, -1.5, 1.5)
	elif ev is InputEventKey and ev.pressed and not ev.echo:
		match ev.keycode:
			KEY_BRACKETRIGHT: _open(_index + 1)
			KEY_BRACKETLEFT: _open(_index - 1)
			KEY_O:
				_show_objects = not _show_objects
				if _terrain.has_node("Objects"):
					_terrain.get_node("Objects").visible = _show_objects
			KEY_ESCAPE:
				if _captured:
					_captured = false
					Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
				else:
					get_tree().change_scene_to_file("res://scenes/boot.tscn")


func _shoot(names: PackedStringArray) -> void:
	var out := ProjectSettings.globalize_path("res://").path_join("../shots/terrain")
	DirAccess.make_dir_recursive_absolute(out)
	for n in names:
		_open(_find(n))
		# aim at the first hangar if there is one (airfields), else the first object
		var target := _cam.position - Vector3(900, 450, 1500)
		var objs = JSON.parse_string(FileAccess.get_file_as_string(GameData.path("terrain/%s/objects.json" % n)))
		for o in objs:
			if String(o.model).begins_with("HANG"):
				target = Vector3(o.pos_ft[0] * FT, o.pos_ft[2] * FT, -o.pos_ft[1] * FT)
				break
		for v in [["airfield", Vector3(260, 120, 420)], ["high", Vector3(2000, 9000, 30000)]]:
			_cam.position = target + v[1]
			_cam.look_at(target)
			_yaw = _cam.rotation.y
			_pitch = _cam.rotation.x
			_process(0.0)
			for k in 4:
				await RenderingServer.frame_post_draw
			get_viewport().get_texture().get_image().save_png(out.path_join("%s_%s.png" % [n, v[0]]))
	get_tree().quit()
