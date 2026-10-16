extends Node
## Locates and loads game data converted from the player's own Strike Commander CD.
##
## The project ships with no original assets. `tools/extract.py` writes them to a `gamedata/`
## folder which is looked up, in order, at:
##   1. $SC_GAMEDATA
##   2. <user data dir>/gamedata         (for exported builds)
##   3. <repo>/gamedata                  (next to the godot/ project, for development)

const REQUIRED_CONVERTER_VERSION := 10
const SETTINGS := "user://settings.cfg"

var root := ""
var manifest := {}
var launch := {}                 # settings passed from the menu to the next scene (e.g. scenario)
var _model_cache := {}
## Upscaled graphics (gamedata/hd, written when extracting with upscaling) or the original
## sprites and textures. Anything without an upscaled copy uses the original. Saved in
## user://settings.cfg; $SC_GRAPHICS=original|upscaled overrides.
var upscaled := true


func _init() -> void:
	var candidates := [
		OS.get_environment("SC_GAMEDATA"),
		OS.get_user_data_dir().path_join("gamedata"),
		ProjectSettings.globalize_path("res://").path_join("../gamedata").simplify_path(),
	]
	for c in candidates:
		if c != "" and FileAccess.file_exists(c.path_join("manifest.json")):
			root = c
			manifest = JSON.parse_string(FileAccess.get_file_as_string(c.path_join("manifest.json")))
			break
	var cfg := ConfigFile.new()
	if cfg.load(SETTINGS) == OK:
		upscaled = bool(cfg.get_value("graphics", "upscaled", true))
	if OS.get_environment("SC_GRAPHICS") != "":
		upscaled = OS.get_environment("SC_GRAPHICS") != "original"


func is_ready() -> bool:
	return root != "" and int(manifest.get("converter_version", 0)) >= REQUIRED_CONVERTER_VERSION


func path(rel: String) -> String:
	return root.path_join(rel)


## Whether converted data has an upscaled set at all.
func has_upscaled() -> bool:
	return DirAccess.dir_exists_absolute(path("hd"))


func set_upscaled(on: bool) -> void:
	upscaled = on
	var cfg := ConfigFile.new()
	cfg.load(SETTINGS)
	cfg.set_value("graphics", "upscaled", on)
	cfg.save(SETTINGS)
	_model_cache.clear()
	Canvas320.clear_cache()
	Terrain._tiles_cache = null
	Effects._frames.clear()


## The file to use for a piece of art: its upscaled copy when wanted and present, else the
## original.
func art(rel: String) -> String:
	if upscaled:
		var hd := root.path_join("hd").path_join(rel)
		if FileAccess.file_exists(hd):
			return hd
	return path(rel)


func is_upscaled_file(file: String) -> bool:
	return file.begins_with(root.path_join("hd") + "/")


## Load art as an Image. With upscaled graphics on, an original without an upscaled copy is
## enlarged 4x with hard pixel edges so it matches its neighbours instead of blurring.
func load_art_image(rel: String) -> Image:
	var f := art(rel)
	var img := Image.load_from_file(f) if FileAccess.file_exists(f) else null
	if img and upscaled and not is_upscaled_file(f):
		img.resize(img.get_width() * 4, img.get_height() * 4, Image.INTERPOLATE_NEAREST)
	return img


## Texture filtering for 2D art: smooth for upscaled art, hard pixels for the originals.
func art_filter() -> CanvasItem.TextureFilter:
	return CanvasItem.TEXTURE_FILTER_LINEAR if upscaled else CanvasItem.TEXTURE_FILTER_NEAREST


func list_files(rel_dir: String, ext: String) -> PackedStringArray:
	var out := PackedStringArray()
	for f in DirAccess.get_files_at(path(rel_dir)):
		if f.get_extension().to_lower() == ext:
			out.append(f)
	out.sort()
	return out


## Instantiate a converted RealSpace model (e.g. "F-16DES"). Returns null if missing.
func load_model(model_name: String) -> Node3D:
	return load_glb(art("objects/%s.glb" % model_name))


## Instantiate any converted .glb (cached per file). Returns null if missing.
func load_glb(file: String) -> Node3D:
	var scene: PackedScene = _model_cache.get(file)
	if scene == null:
		if not FileAccess.file_exists(file):
			return null
		var doc := GLTFDocument.new()
		var state := GLTFState.new()
		if doc.append_from_file(file, state) != OK:
			push_error("GameData: failed to read " + file)
			return null
		var node := doc.generate_scene(state)
		_finish_materials(node, is_upscaled_file(file))
		scene = PackedScene.new()
		scene.pack(node)
		node.free()
		_model_cache[file] = scene
	return scene.instantiate()


## Runtime glTF loading skips the import pipeline, so build mipmaps and pick filtering here.
func _finish_materials(node: Node, smooth := true) -> void:
	var done := {}
	for mi in node.find_children("*", "MeshInstance3D", true, false):
		var mesh: Mesh = mi.mesh
		for s in mesh.get_surface_count():
			var mat := mesh.surface_get_material(s) as BaseMaterial3D
			if mat == null or done.has(mat):
				continue
			done[mat] = true
			var is_palette := mat.resource_name.begins_with("palette")
			var tex := mat.albedo_texture
			if tex and not is_palette:
				var img := tex.get_image()
				if img and not img.has_mipmaps():
					img.generate_mipmaps()
					mat.albedo_texture = ImageTexture.create_from_image(img)
			mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST if is_palette \
				else (BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC if smooth
					else BaseMaterial3D.TEXTURE_FILTER_NEAREST_WITH_MIPMAPS_ANISOTROPIC)
