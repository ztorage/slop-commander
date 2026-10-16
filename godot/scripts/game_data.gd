extends Node
## Locates and loads game data converted from the player's own Strike Commander CD.
##
## The project ships with no original assets. `tools/extract.py` writes them to a `gamedata/`
## folder which is looked up, in order, at:
##   1. $SC_GAMEDATA
##   2. <user data dir>/gamedata         (for exported builds)
##   3. <repo>/gamedata                  (next to the godot/ project, for development)

const REQUIRED_CONVERTER_VERSION := 9

var root := ""
var manifest := {}
var launch := {}                 # settings passed from the menu to the next scene (e.g. scenario)
var _model_cache := {}


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


func is_ready() -> bool:
	return root != "" and int(manifest.get("converter_version", 0)) >= REQUIRED_CONVERTER_VERSION


func path(rel: String) -> String:
	return root.path_join(rel)


func list_files(rel_dir: String, ext: String) -> PackedStringArray:
	var out := PackedStringArray()
	for f in DirAccess.get_files_at(path(rel_dir)):
		if f.get_extension().to_lower() == ext:
			out.append(f)
	out.sort()
	return out


## Instantiate a converted RealSpace model (e.g. "F-16DES"). Returns null if missing.
func load_model(model_name: String) -> Node3D:
	return load_glb(path("objects/%s.glb" % model_name))


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
		_finish_materials(node)
		scene = PackedScene.new()
		scene.pack(node)
		node.free()
		_model_cache[file] = scene
	return scene.instantiate()


## Runtime glTF loading skips the import pipeline, so build mipmaps and pick filtering here.
func _finish_materials(node: Node) -> void:
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
				else BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC
