class_name Canvas320
extends Control
## Base for the campaign's 2D screens: the original 320x200 art, shown at 4:3 (as on a 1993 VGA
## monitor) and letterboxed to the window. Images come from gamedata/story/img, upscaled; their
## JSON entries give the original pixel position and size.

const W := 320.0
const H := 200.0
const ASPECT := 4.0 / 3.0
const CONV_Y := 24.0              # conversation / shot art is placed below a 24-pixel band

static var _textures := {}

var img_dir := "story/img/"        # where this canvas's image entries live (under gamedata)


static func texture(file: String, folder := "story/img/") -> Texture2D:
	var key := folder + file
	if _textures.has(key):
		return _textures[key]
	var img := Image.load_from_file(GameData.path(key))
	var tex: Texture2D = ImageTexture.create_from_image(img) if img else null
	_textures[key] = tex
	return tex


## Save a screenshot to shots/story (automated checks).
func capture(tag: String) -> void:
	await RenderingServer.frame_post_draw
	var dir := ProjectSettings.globalize_path("res://").path_join("../shots/story")
	DirAccess.make_dir_recursive_absolute(dir)
	get_viewport().get_texture().get_image().save_png(dir.path_join(tag + ".png"))


## The rectangle on screen that shows the 320x200 picture.
func frame_rect() -> Rect2:
	var s := size
	var w := minf(s.x, s.y * ASPECT)
	var h := w / ASPECT
	return Rect2((s.x - w) * 0.5, (s.y - h) * 0.5, w, h)


func to_screen(p: Vector2) -> Vector2:
	var r := frame_rect()
	return r.position + Vector2(p.x / W * r.size.x, p.y / H * r.size.y)


func to_art(p: Vector2) -> Vector2:
	var r := frame_rect()
	return Vector2((p.x - r.position.x) / r.size.x * W, (p.y - r.position.y) / r.size.y * H)


func px() -> float:
	return frame_rect().size.y / H


## Draw an image entry ({file, x, y, w, h}) with its origin at `at` (original pixels).
func draw_entry(e, at := Vector2.ZERO, modulate_ := Color.WHITE) -> void:
	if e == null or not e is Dictionary:
		return
	var tex := texture(String(e.file), img_dir)
	if tex == null:
		return
	var tl := to_screen(at + Vector2(float(e.x), float(e.y)))
	var br := to_screen(at + Vector2(float(e.x) + float(e.w), float(e.y) + float(e.h)))
	draw_texture_rect(tex, Rect2(tl, br - tl), false, modulate_)


func draw_backdrop() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), Color.BLACK)


## Text in the original's subtitle style: centred, wrapped, with a dark outline.
func draw_caption(text: String, top: float, colour: Color, max_lines := 4) -> void:
	var font := get_theme_default_font()
	var fs := int(clampf(px() * 8.0, 12.0, 40.0))
	var r := frame_rect()
	var width := r.size.x * 0.9
	var lines := _wrap(font, text, fs, width)
	var y := to_screen(Vector2(0, top)).y + fs
	for i in mini(lines.size(), max_lines):
		var w := font.get_string_size(lines[i], HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
		var pos := Vector2(r.position.x + (r.size.x - w) * 0.5, y)
		draw_string_outline(font, pos, lines[i], HORIZONTAL_ALIGNMENT_LEFT, -1, fs, maxi(2, fs / 6), Color(0, 0, 0, 0.9))
		draw_string(font, pos, lines[i], HORIZONTAL_ALIGNMENT_LEFT, -1, fs, colour)
		y += fs * 1.25


func _wrap(font: Font, text: String, fs: int, width: float) -> PackedStringArray:
	var out := PackedStringArray()
	var line := ""
	for word in text.split(" ", false):
		var t := word if line == "" else line + " " + word
		if font.get_string_size(t, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x > width and line != "":
			out.append(line)
			line = word
		else:
			line = t
	if line != "":
		out.append(line)
	return out
