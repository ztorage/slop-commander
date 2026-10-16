extends Canvas320
## The original front end (gamedata/frontend, from tools/frontend.py): the CD's game chooser,
## the main menu and the pilot's licence for a new game, drawn from the game's own art with
## its mouse cursor. Buttons show their pressed frame while held and act on release, as in
## the original; disabled main-menu entries keep the panel's engraved look.
## GameData.launch.front picks the screen ("chooser", "main" (default), "licence").
## F12 opens the developer menu.

const DIR := "frontend/"
const LETTERS := "ABCDEFGHIJKLMNOPQRSTUVWXYZ"

var data := {}
var mode := "main"
var scr := {}
var _pressed := -1               # button held down
var _mouse := Vector2(-100, -100)
var _t := 0.0
var _idle := 0.0
var _confirm_quit := false
var _dialog: SaveDialog = null
# licence
var _field := 0
var _text: Array[String] = ["", "", ""]


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	img_dir = DIR
	var path := GameData.path(DIR + "frontend.json")
	if not FileAccess.file_exists(path):
		_dev_menu.call_deferred()
		return
	data = JSON.parse_string(FileAccess.get_file_as_string(path))
	mode = String(GameData.launch.get("front", "main"))
	if OS.get_environment("SC_FRONT") != "":
		mode = OS.get_environment("SC_FRONT")
	if not data.screens.has(mode):
		mode = "main"
	scr = data.screens[mode]
	Input.mouse_mode = Input.MOUSE_MODE_HIDDEN
	if mode == "main":
		if GameData.get_meta("music_playing", false):       # the intro's title music carries on
			GameData.remove_meta("music_playing")
		else:
			Audio.music(String(scr.music.set), int(scr.music.track))
	elif mode == "licence":
		Audio.music("midgames", 0x1a)
	if OS.get_environment("SC_FRONT_TEST") != "":
		_front_test.call_deferred()


func _exit_tree() -> void:
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


func _process(delta: float) -> void:
	_t += delta
	_idle += delta
	if _dialog != null:
		_idle = 0.0
	if mode == "main" and _idle > _attract_after():
		_attract()
	elif mode == "chooser" and _idle > float(scr.get("timeout_s", 120.0)):
		_attract()
	queue_redraw()


## The main menu waits for the title music to end (30 s without music), then shows the intro.
func _attract_after() -> float:
	var tracks: Array = Audio.index.get("music", {}).get(String(scr.music.set), [])
	var t := int(scr.music.track)
	if t < tracks.size() and AudioServer.get_bus_volume_db(AudioServer.get_bus_index("Music")) > -60.0:
		return maxf(float(tracks[t].get("end_s", 30.0)), float(scr.get("idle_s", 30.0)))
	return float(scr.get("idle_s", 30.0))


func _attract() -> void:
	_idle = -1e9
	if mode == "chooser":
		GameData.launch = {"front": "chooser"}
		get_tree().change_scene_to_file("res://scenes/intro.tscn")
	elif FileAccess.file_exists(GameData.path("cinematics/mid1/scenes.json")):
		GameData.launch = {"midgame": "mid1", "after": "res://scenes/front_end.tscn"}
		get_tree().change_scene_to_file("res://scenes/midgame.tscn")


# ---------------------------------------------------------------- buttons
func _enabled(b: Dictionary) -> bool:
	match String(b.action):
		"continue":
			return Campaign.has_save()
		"load":
			return not Campaign.list_saves().is_empty()
	return true


func _button_at(p: Vector2) -> int:
	var bs: Array = scr.get("buttons", [])
	for i in bs.size():
		var r: Array = bs[i].rect
		if _enabled(bs[i]) and Rect2(float(r[0]), float(r[1]), float(r[2]), float(r[3])).has_point(p):
			return i
	return -1


func _gui_input(ev: InputEvent) -> void:
	if ev is InputEventMouseMotion:
		_mouse = to_art(ev.position)
		_idle = 0.0
	elif ev is InputEventMouseButton and ev.button_index == MOUSE_BUTTON_LEFT:
		_idle = 0.0
		_mouse = to_art(ev.position)
		if ev.pressed:
			_pressed = _button_at(_mouse)
		elif _pressed >= 0:
			var hit := _button_at(_mouse) == _pressed
			var b: Dictionary = scr.buttons[_pressed]
			_pressed = -1
			if hit:
				_act(String(b.action))


func _act(action: String) -> void:
	match action:
		"strike":
			if FileAccess.file_exists(GameData.path("cinematics/mid1/scenes.json")):
				GameData.launch = {"midgame": "mid1", "after": "res://scenes/front_end.tscn"}
				get_tree().change_scene_to_file("res://scenes/midgame.tscn")
			else:
				_goto("main")
		"tactical":
			GameData.launch = {}
			get_tree().change_scene_to_file("res://scenes/mission_select.tscn")
		"continue":
			GameData.launch = {"campaign": "continue"}
			get_tree().change_scene_to_file("res://scenes/campaign.tscn")
		"load":
			_dialog = SaveDialog.new().setup(scr.saveload, false, scr.cursor.get("arrow"), DIR)
			add_child(_dialog)
			var r: Dictionary = await _dialog.closed
			_dialog = null
			_idle = 0.0
			if r.action == "ok" and Campaign.load_game(String(r.name)):
				GameData.launch = {"campaign": "loaded"}
				get_tree().change_scene_to_file("res://scenes/campaign.tscn")
		"new":
			_goto("licence")
		"training":
			GameData.launch = {}
			get_tree().change_scene_to_file("res://scenes/mission_select.tscn")
		"objects":
			GameData.launch = {}
			get_tree().change_scene_to_file("res://scenes/model_viewer.tscn")


func _goto(m: String) -> void:
	GameData.launch = {"front": m}
	get_tree().change_scene_to_file("res://scenes/front_end.tscn")


# ---------------------------------------------------------------- keys
func _unhandled_key_input(ev: InputEvent) -> void:
	if not (ev is InputEventKey and ev.pressed):
		return
	_idle = 0.0
	var k := (ev as InputEventKey)
	if k.keycode == KEY_F12:
		_dev_menu()
		return
	if mode == "licence":
		_licence_key(k)
		return
	if _confirm_quit:
		if k.keycode == KEY_Y:
			get_tree().quit()
		_confirm_quit = false
		return
	if k.keycode == KEY_ESCAPE:
		_confirm_quit = true


func _licence_key(k: InputEventKey) -> void:
	var f: Array = scr.fields
	match k.keycode:
		KEY_ESCAPE:
			_goto("main")
		KEY_BACKSPACE:
			_text[_field] = _text[_field].substr(0, maxi(_text[_field].length() - 1, 0))
		KEY_ENTER, KEY_KP_ENTER, KEY_TAB:
			if _field < f.size() - 1:
				_field += 1
			elif k.keycode != KEY_TAB and _text[0].strip_edges() != "" and _text[1].strip_edges() != "" \
					and _text[2].strip_edges() != "":
				_licence_done()
		_:
			var c := char(k.unicode) if k.unicode > 0 else ""
			if c == "" or not (c.to_upper() in LETTERS or c == " "):
				return
			if _text[_field] == "":
				c = c.to_upper()
			var t: String = _text[_field] + c
			if t.length() > int(scr.max_len) or font_width(scr.font, t) > float(f[_field].max_w):
				return
			_text[_field] = t


func _licence_done() -> void:
	Campaign.new_game()
	Campaign.last_name = _text[0].strip_edges()
	Campaign.first_name = _text[1].strip_edges()
	Campaign.callsign = _text[2].strip_edges()
	GameData.launch = {"campaign": "new"}
	get_tree().change_scene_to_file("res://scenes/campaign.tscn")


func _dev_menu() -> void:
	GameData.set_meta("dev_menu", true)
	GameData.launch = {}
	get_tree().change_scene_to_file("res://scenes/boot.tscn")


# ---------------------------------------------------------------- drawing
func _draw() -> void:
	draw_backdrop()
	if data.is_empty():
		return
	var fade := clampf(_t / 0.6, 0.0, 1.0)
	var mod := Color(fade, fade, fade)
	for e in scr.background:
		draw_entry(e, Vector2.ZERO, mod)
	var bs: Array = scr.get("buttons", [])
	for i in bs.size():
		if _enabled(bs[i]):
			var held := i == _pressed and _button_at(_mouse) == i
			draw_entry(bs[i].down if held else bs[i].up, Vector2.ZERO, mod)
	if mode == "licence":
		for i in scr.fields.size():
			var f: Dictionary = scr.fields[i]
			var s: String = _text[i] + ("_" if i == _field and int(_t * 2.0) % 2 == 0 else "")
			draw_font_text(scr.font, s, Vector2(float(f.x), float(f.y)))
	if _confirm_quit:
		draw_caption("Exit Strike Commander? (Y/N)", 176.0, Color(0.95, 0.92, 0.8))
	var cur = scr.cursor.get("arrow")
	if cur != null and _dialog == null and Rect2(0, 0, W, H).has_point(_mouse):
		draw_entry(cur, _mouse.floor())


# ---------------------------------------------------------------- tests
func _front_test() -> void:
	await get_tree().create_timer(0.8).timeout
	_mouse = Vector2(160, 70)
	capture("front_%s" % mode)
	if mode == "main":
		for saving in [false, true]:
			var d := SaveDialog.new().setup(scr.saveload, saving, scr.cursor.get("arrow"), DIR)
			d.names = PackedStringArray(["ANKARA", "BETA", "CAIRO", "DELTA", "ECHO", "FOXTROT", "GOLF"])
			d.text = "CAIRO"
			add_child(d)
			d._mouse = Vector2(150, 140)
			await get_tree().create_timer(0.3).timeout
			await capture("front_dialog_%s" % ("save" if saving else "load"))
			if saving:
				d.confirm = "overwrite"
				await get_tree().create_timer(0.3).timeout
				await capture("front_dialog_overwrite")
			d.queue_free()
	if mode == "licence":
		_text = ["Stern", "Ken", "Wolfman"] as Array[String]
		await get_tree().create_timer(0.3).timeout
		capture("front_licence_filled")
	get_tree().quit()
