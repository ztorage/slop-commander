extends Node3D
## Interactive viewer for exported RealSpace models.
##   Left-drag: orbit   Wheel: zoom   Left/Right: prev/next model   Space: auto-spin
##   L: cycle LOD       R: reset view
## Pass `-- --shots` to batch-render every model to re/shots/ and quit.

var _cam: Camera3D
var _label: Label
var _files: PackedStringArray = []
var _index := 0
var _inst: Node3D
var _lods: Array = []
var _lod := 0
var _center := Vector3.ZERO
var _radius := 1.0
var _yaw := 2.4
var _pitch := -0.35
var _dist_scale := 2.1
var _spin := true
var _dragging := false


func _ready() -> void:
	var env := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = Color(0.38, 0.52, 0.72)
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(0.55, 0.58, 0.65)
	e.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	env.environment = e
	add_child(env)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-50, -35, 0)
	sun.light_energy = 1.4
	add_child(sun)
	_cam = Camera3D.new()
	add_child(_cam)
	_cam.make_current()

	for f in GameData.list_files("objects", "glb"):
		_files.append(f.get_basename())

	if "--shots" in OS.get_cmdline_user_args():
		_shoot_all.call_deferred()
		return

	var ui := CanvasLayer.new()
	add_child(ui)
	_label = Label.new()
	_label.position = Vector2(16, 12)
	_label.add_theme_font_size_override("font_size", 18)
	_label.add_theme_color_override("font_outline_color", Color.BLACK)
	_label.add_theme_constant_override("outline_size", 6)
	ui.add_child(_label)
	var start := _files.find("F-16DES")
	_show(start if start >= 0 else 0)


func _show(i: int) -> void:
	if _files.is_empty():
		return
	_index = posmod(i, _files.size())
	if _inst:
		_inst.queue_free()
	_inst = GameData.load_model(_files[_index])
	add_child(_inst)
	_lods = _inst.find_children("LOD*", "", true, false)
	_lods.sort_custom(func(a, b): return String(a.name) < String(b.name))
	_set_lod(0)
	var aabb := _aabb(_inst)
	_center = aabb.get_center()
	_radius = max(aabb.size.length() * 0.5, 0.1)
	_cam.near = _radius * 0.01
	_cam.far = _radius * 50.0
	_update_label()


func _set_lod(l: int) -> void:
	_lod = posmod(l, max(_lods.size(), 1))
	for n in _lods:
		n.visible = n == _lods[_lod]
	_update_label()


func _update_label() -> void:
	if not _label or _files.is_empty():
		return
	var tris := 0
	if _lods.size() > _lod:
		var mi := _lods[_lod] as MeshInstance3D
		if mi and mi.mesh:
			for s in mi.mesh.get_surface_count():
				tris += mi.mesh.surface_get_array_len(s) / 3
	_label.text = "%s   (%d / %d)\nLOD%d of %d   %d triangles   %.1f m across\n\n" % [
		_files[_index], _index + 1, _files.size(), _lod, _lods.size(), tris, _radius * 2.0] \
		+ "Drag: orbit   Wheel: zoom   ←/→: model   Space: spin   L: LOD   R: reset"


func _process(delta: float) -> void:
	if _spin and not _dragging:
		_yaw += delta * 0.5
	_pitch = clamp(_pitch, -1.5, 1.5)
	var dir := Vector3(cos(_pitch) * sin(_yaw), -sin(_pitch), cos(_pitch) * cos(_yaw))
	_cam.position = _center + dir * _radius * _dist_scale
	_cam.look_at(_center)


func _unhandled_input(ev: InputEvent) -> void:
	if ev is InputEventMouseButton:
		match ev.button_index:
			MOUSE_BUTTON_LEFT:
				_dragging = ev.pressed
			MOUSE_BUTTON_WHEEL_UP:
				_dist_scale = max(0.6, _dist_scale * 0.9)
			MOUSE_BUTTON_WHEEL_DOWN:
				_dist_scale = min(12.0, _dist_scale * 1.1)
	elif ev is InputEventMouseMotion and _dragging:
		_yaw -= ev.relative.x * 0.008
		_pitch += ev.relative.y * 0.008
	elif ev is InputEventMagnifyGesture:
		_dist_scale = clamp(_dist_scale / ev.factor, 0.6, 12.0)
	elif ev is InputEventPanGesture:
		_yaw -= ev.delta.x * 0.05
		_pitch += ev.delta.y * 0.05
	elif ev is InputEventKey and ev.pressed and not ev.echo:
		match ev.keycode:
			KEY_RIGHT: _show(_index + 1)
			KEY_LEFT: _show(_index - 1)
			KEY_SPACE: _spin = not _spin
			KEY_L: _set_lod(_lod + 1)
			KEY_R:
				_yaw = 2.4; _pitch = -0.35; _dist_scale = 2.1
			KEY_ESCAPE: get_tree().quit()


func _shoot_all() -> void:
	var out := ProjectSettings.globalize_path("res://").path_join("../shots")
	DirAccess.make_dir_recursive_absolute(out)
	var only := OS.get_environment("SHOT_ONLY").split(",", false)
	if OS.get_environment("SHOT_PITCH") != "":
		_pitch = float(OS.get_environment("SHOT_PITCH"))
	for i in _files.size():
		if only.size() and not _files[i] in only:
			continue
		_show(i)
		_process(0.0)
		await RenderingServer.frame_post_draw
		await RenderingServer.frame_post_draw
		get_viewport().get_texture().get_image().save_png(out.path_join(_files[i] + ".png"))
	get_tree().quit()


func _aabb(n: Node) -> AABB:
	var box := AABB()
	var first := true
	for m in n.find_children("*", "MeshInstance3D", true, false):
		if not m.visible:
			continue
		var b: AABB = m.global_transform * m.get_aabb()
		box = b if first else box.merge(b)
		first = false
	return box
