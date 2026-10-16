class_name Effects
extends RefCounted
## Visual effects: original sprite animations (explosions, sparks) as billboards, and particle
## smoke trails for missiles and damaged aircraft.

const FPS := 15.0

static var _frames := {}       # sprite name -> {textures: Array[Texture2D], meta}
static var _puff: Texture2D


static func _load(sprite_name: String) -> Dictionary:
	if _frames.has(sprite_name):
		return _frames[sprite_name]
	var dir := GameData.path("sprites/" + sprite_name)
	var out := {}
	if FileAccess.file_exists(dir.path_join("sprite.json")):
		var meta: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(dir.path_join("sprite.json")))
		var tex: Array[Texture2D] = []
		for i in meta.frames.size():
			var img := Image.load_from_file(dir.path_join("frame_%d.png" % i))
			tex.append(ImageTexture.create_from_image(img))
		out = {"textures": tex, "meta": meta}
	_frames[sprite_name] = out
	return out


## Play a sprite animation at `pos`. `size_m` is the world size of the largest frame.
static func explosion(parent: Node, sprite_name: String, pos: Vector3, size_m: float) -> void:
	var data := _load(sprite_name)
	if data.is_empty():
		return
	var spr := Sprite3D.new()
	spr.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	spr.shaded = false
	spr.double_sided = true
	spr.alpha_cut = SpriteBase3D.ALPHA_CUT_DISABLED
	spr.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	var max_px := 1.0
	for t in data.textures:
		max_px = maxf(max_px, maxf(t.get_width(), t.get_height()))
	spr.pixel_size = size_m / max_px
	parent.add_child(spr)
	spr.global_position = pos
	var tw := spr.create_tween()
	for t in data.textures:
		tw.tween_callback(func(): spr.texture = t)
		tw.tween_interval(1.0 / FPS)
	tw.tween_callback(spr.queue_free)


static func _puff_texture() -> Texture2D:
	if _puff == null:
		var g := Gradient.new()
		g.set_color(0, Color(1, 1, 1, 0.9))
		g.set_color(1, Color(1, 1, 1, 0.0))
		var t := GradientTexture2D.new()
		t.gradient = g
		t.fill = GradientTexture2D.FILL_RADIAL
		t.fill_from = Vector2(0.5, 0.5)
		t.fill_to = Vector2(1.0, 0.5)
		t.width = 64
		t.height = 64
		_puff = t
	return _puff


## A world-space smoke trail emitter to attach to a moving node.
static func smoke_trail(color := Color(0.85, 0.85, 0.85), rate := 50.0, lifetime := 3.0, size := 2.5) -> GPUParticles3D:
	var p := GPUParticles3D.new()
	p.amount = int(rate * lifetime)
	p.lifetime = lifetime
	p.local_coords = false
	p.fixed_fps = 60
	var m := ParticleProcessMaterial.new()
	m.direction = Vector3(0, 0, 1)
	m.spread = 8.0
	m.initial_velocity_min = 1.0
	m.initial_velocity_max = 3.0
	m.gravity = Vector3(0, 0.6, 0)
	m.damping_min = 0.5
	m.damping_max = 1.0
	m.scale_min = 0.8
	m.scale_max = 1.2
	var sc := CurveTexture.new()
	var c := Curve.new()
	c.add_point(Vector2(0, 0.4))
	c.add_point(Vector2(1, 3.0))
	c.max_value = 3.0
	sc.curve = c
	m.scale_curve = sc
	var ramp := GradientTexture1D.new()
	var g := Gradient.new()
	g.set_color(0, Color(color, 0.7))
	g.set_color(1, Color(color, 0.0))
	ramp.gradient = g
	m.color_ramp = ramp
	p.process_material = m
	var quad := QuadMesh.new()
	quad.size = Vector2(size, size)
	var mat := StandardMaterial3D.new()
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	mat.vertex_color_use_as_albedo = true
	mat.albedo_texture = _puff_texture()
	quad.material = mat
	p.draw_pass_1 = quad
	p.visibility_aabb = AABB(Vector3(-5000, -5000, -5000), Vector3(10000, 10000, 10000))
	return p
