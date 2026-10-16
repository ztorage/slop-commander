extends Control
## Entry point: refuses to continue unless game data extracted from a real CD is present.

const MENU := [
	["Dogfight  (F-16 vs 2 MiG-29s)", "res://scenes/flight.tscn", {"SC_SCENARIO": "dogfight", "SC_BANDITS": "2"}],
	["Free flight  (F-16 from the runway, San Francisco)", "res://scenes/flight.tscn", {"SC_SCENARIO": "free"}],
	["Theatre viewer  (fly over the maps)", "res://scenes/theatre_viewer.tscn"],
	["Model viewer  (aircraft, vehicles, buildings)", "res://scenes/model_viewer.tscn"],
]


func _ready() -> void:
	if GameData.is_ready():
		_show_menu()
		return
	var bg := ColorRect.new()
	bg.color = Color(0.05, 0.07, 0.1)
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(bg)
	var label := Label.new()
	label.set_anchors_preset(Control.PRESET_FULL_RECT)
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.add_theme_font_size_override("font_size", 20)
	var why := "No game data found." if GameData.root == "" \
		else "Game data at %s is from an older converter; please re-run the extractor." % GameData.root
	label.text = why + "\n\nThis remake needs files from your own Strike Commander CD.\n" \
		+ "From the project folder run:\n\n    tools/extract.py /path/to/your/StrikeCommander.cue\n\n" \
		+ "(a .cue, .img/.bin, .iso or a mounted CD folder all work)\n\n" \
		+ "Data is searched in $SC_GAMEDATA, %s and <repo>/gamedata." % OS.get_user_data_dir().path_join("gamedata")
	add_child(label)


func _show_menu() -> void:
	var bg := ColorRect.new()
	bg.color = Color(0.05, 0.07, 0.1)
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(bg)
	var box := VBoxContainer.new()
	box.set_anchors_preset(Control.PRESET_CENTER)
	box.add_theme_constant_override("separation", 14)
	add_child(box)
	var title := Label.new()
	title.text = "STRIKE COMMANDER — remake (development build)"
	title.add_theme_font_size_override("font_size", 26)
	box.add_child(title)
	var ed := Label.new()
	ed.text = "Game data: %s" % GameData.manifest.get("edition", "unrecognised edition")
	ed.modulate = Color(0.7, 0.75, 0.8)
	box.add_child(ed)
	for item in MENU:
		var b := Button.new()
		b.text = item[0]
		b.add_theme_font_size_override("font_size", 20)
		b.pressed.connect(func():
			GameData.launch = item[2] if item.size() > 2 else {}
			get_tree().change_scene_to_file(item[1]))
		box.add_child(b)
	box.get_child(2).grab_focus.call_deferred()
	box.position -= box.get_combined_minimum_size() * 0.5


func _unhandled_input(ev: InputEvent) -> void:
	if ev is InputEventKey and ev.pressed and ev.keycode == KEY_ESCAPE:
		get_tree().quit()
