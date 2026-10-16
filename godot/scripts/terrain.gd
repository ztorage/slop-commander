class_name Terrain
extends Node3D
## Builds a theatre from gamedata/terrain/<NAME>: chunked height mesh, draped ground tiles,
## runway overlays and placed ground objects. World units are metres; x east, y up, -z north.

const FT := 0.3048
const CHUNKS := 18
const CHUNK_QUADS := 20

static var _tiles_cache: Texture2DArray

var theatre := ""
var grid_size := 0
var spacing_m := 0.0
var heights: PackedInt32Array   # feet
var color_image: Image           # grid colours (for the nav map)
var _palette: Image


var world: CombatWorld          # when set, theatre objects become destructible GroundUnits


func load_theatre(theatre_name: String, with_objects := true) -> bool:
	theatre = theatre_name
	var dir := GameData.path("terrain".path_join(theatre_name))
	var f := FileAccess.open(dir.path_join("terrain.bin"), FileAccess.READ)
	if f == null or f.get_buffer(4).get_string_from_ascii() != "SCTR":
		push_error("Terrain: missing or bad terrain.bin for " + theatre_name)
		return false
	f.get_32()  # version
	grid_size = f.get_16()
	f.get_16()
	spacing_m = f.get_float() * FT
	var n := grid_size * grid_size
	var raw_h := f.get_buffer(n * 2)
	var tone := f.get_buffer(n)
	f.get_buffer(n)  # land type
	var upper := f.get_buffer(n)
	var lower := f.get_buffer(n)

	heights.resize(n)
	for i in n:
		heights[i] = raw_h.decode_s16(i * 2)

	_palette = Image.load_from_file(GameData.path("terrain/palette.png"))
	var color_img := Image.create(grid_size, grid_size, false, Image.FORMAT_RGB8)
	var ids := PackedByteArray()
	ids.resize(n * 2)
	for i in n:
		var t := tone[i]
		color_img.set_pixel(i % grid_size, i / grid_size, _palette.get_pixel(t % 16, t / 16))
		ids[i * 2] = upper[i]
		ids[i * 2 + 1] = lower[i]
	var id_img := Image.create_from_data(grid_size, grid_size, false, Image.FORMAT_RG8, ids)
	color_image = color_img

	var mat := ShaderMaterial.new()
	mat.shader = load("res://shaders/terrain.gdshader")
	mat.set_shader_parameter("color_map", ImageTexture.create_from_image(color_img))
	mat.set_shader_parameter("tile_ids", ImageTexture.create_from_image(id_img))
	mat.set_shader_parameter("tiles", _tile_array())
	mat.set_shader_parameter("grid_size", float(grid_size))
	mat.set_shader_parameter("spacing_m", spacing_m)
	_build_chunks(mat)
	_build_skirt(color_img)

	var overlays := GameData.load_glb(dir.path_join("overlays.glb"))
	if overlays:
		add_child(overlays)
	if with_objects:
		_place_objects(dir.path_join("objects.json"))
	return true


## Height in metres at a world position (bilinear over the 1000 ft grid).
func height_at(x_m: float, z_m: float) -> float:
	var gx := x_m / spacing_m + grid_size * 0.5
	var gz := z_m / spacing_m + grid_size * 0.5
	var x0 := clampi(int(floor(gx)), 0, grid_size - 1)
	var z0 := clampi(int(floor(gz)), 0, grid_size - 1)
	var x1 := mini(x0 + 1, grid_size - 1)
	var z1 := mini(z0 + 1, grid_size - 1)
	var fx := clampf(gx - x0, 0, 1)
	var fz := clampf(gz - z0, 0, 1)
	var h := lerpf(lerpf(heights[z0 * grid_size + x0], heights[z0 * grid_size + x1], fx),
		lerpf(heights[z1 * grid_size + x0], heights[z1 * grid_size + x1], fx), fz)
	return h * FT


func _h(col: int, row: int) -> float:
	col = clampi(col, 0, grid_size - 1)
	row = clampi(row, 0, grid_size - 1)
	return heights[row * grid_size + col] * FT


func _build_chunks(mat: Material) -> void:
	var half := grid_size * 0.5 * spacing_m
	for cy in CHUNKS:
		for cx in CHUNKS:
			var st := SurfaceTool.new()
			st.begin(Mesh.PRIMITIVE_TRIANGLES)
			var c0 := cx * CHUNK_QUADS
			var r0 := cy * CHUNK_QUADS
			for r in CHUNK_QUADS + 1:
				for c in CHUNK_QUADS + 1:
					var col := c0 + c
					var row := r0 + r
					var nrm := Vector3(_h(col - 1, row) - _h(col + 1, row), 2.0 * spacing_m,
						_h(col, row + 1) - _h(col, row - 1)).normalized()
					st.set_normal(nrm)
					st.add_vertex(Vector3(col * spacing_m - half, _h(col, row), row * spacing_m - half))
			var w := CHUNK_QUADS + 1
			for r in CHUNK_QUADS:
				for c in CHUNK_QUADS:
					var a := r * w + c       # top-left
					var b := a + 1           # top-right
					var d := a + w           # bottom-left
					var e := d + 1           # bottom-right
					# split along top-left -> bottom-right, matching the tile layout
					st.add_index(a); st.add_index(b); st.add_index(e)
					st.add_index(a); st.add_index(e); st.add_index(d)
			var mi := MeshInstance3D.new()
			mi.mesh = st.commit()
			mi.material_override = mat
			mi.name = "Chunk_%d_%d" % [cx, cy]
			add_child(mi)


## A large flat apron around the map so the world doesn't end at a cliff: sea if most of the
## map edge is at sea level, otherwise the average edge colour slightly below the lowest edge.
func _build_skirt(color_img: Image) -> void:
	var sum := Color(0, 0, 0)
	var count := 0
	var sea := 0
	var low := 1e9
	for i in grid_size:
		for p in [Vector2i(i, 0), Vector2i(i, grid_size - 1), Vector2i(0, i), Vector2i(grid_size - 1, i)]:
			sum += color_img.get_pixelv(p)
			count += 1
			var h := heights[p.y * grid_size + p.x]
			sea += int(h <= 0)
			low = minf(low, h * FT)
	var col := sum / count
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(col.r, col.g, col.b)
	mat.roughness = 0.4 if sea > count / 2 else 0.95
	var plane := PlaneMesh.new()
	var size := grid_size * spacing_m
	plane.size = Vector2(size * 12, size * 12)
	var mi := MeshInstance3D.new()
	mi.mesh = plane
	mi.material_override = mat
	mi.position.y = -1.0 if sea > count / 2 else low - 30.0
	mi.name = "Skirt"
	add_child(mi)


func _tile_array() -> Texture2DArray:
	if _tiles_cache:
		return _tiles_cache
	var atlas := Image.load_from_file(GameData.path("terrain/tiles.png"))
	var px := atlas.get_width() / 16
	var layers: Array[Image] = []
	for i in 256:
		var img := atlas.get_region(Rect2i((i % 16) * px, (i / 16) * px, px, px))
		img.generate_mipmaps()
		layers.append(img)
	_tiles_cache = Texture2DArray.new()
	_tiles_cache.create_from_images(layers)
	return _tiles_cache


func _place_objects(json_path: String) -> void:
	var objs = JSON.parse_string(FileAccess.get_file_as_string(json_path))
	if objs == null:
		return
	var root := Node3D.new()
	root.name = "Objects"
	add_child(root)
	for o in objs:
		var inst: Node3D = GroundUnit.create(String(o.model), -1) if world else GameData.load_model(o.model)
		if inst == null:
			continue
		var p: Array = o.pos_ft
		var m: Array = o.basis
		# 3x3 basis (row-major, column = local axis) in SC world axes (x east, y north, z up).
		# Godot = C * M * C^-1 with C(v) = (v.x, v.z, -v.y).
		var bx := Vector3(m[0], m[6], -m[3])
		var by := Vector3(m[2], m[8], -m[5])
		var bz := -Vector3(m[1], m[7], -m[4])
		inst.transform = Transform3D(Basis(bx, by, bz), Vector3(p[0] * FT, p[2] * FT, -p[1] * FT))
		for lod in inst.find_children("LOD*", "", true, false):
			lod.visible = lod.name == "LOD0"
		root.add_child(inst)
		if world and inst is GroundUnit:
			world.ground_units.append(inst)
