extends Control
## Lists the missions converted from the CD and launches the chosen one.

func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	var bg := ColorRect.new()
	bg.color = Color(0.05, 0.07, 0.1)
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(bg)
	var title := Label.new()
	title.text = "SELECT MISSION"
	title.add_theme_font_size_override("font_size", 26)
	title.position = Vector2(40, 24)
	add_child(title)
	var scroll := ScrollContainer.new()
	scroll.position = Vector2(40, 72)
	scroll.size = get_viewport_rect().size - Vector2(80, 100)
	add_child(scroll)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 6)
	scroll.add_child(box)
	var files := Array(GameData.list_files("missions", "json"))
	files = files.filter(func(f): return f.begins_with("MISN-") or f.begins_with("TO_MISN"))
	files.sort_custom(_mission_order)
	for f in files:
		var m: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(GameData.path("missions/" + String(f))))
		var mission_name: String = String(f).get_basename()
		var objectives: Array = m.messages.map(func(x): return String(x).replace("\n", " "))
		var b := Button.new()
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		b.text = "%-10s  %-14s  %s" % [mission_name.trim_prefix("TO_"), String(m.title), " • ".join(objectives.slice(0, 4))]
		b.add_theme_font_size_override("font_size", 16)
		b.pressed.connect(func():
			GameData.launch = {"SC_SCENARIO": "mission", "SC_MISSION": mission_name}
			get_tree().change_scene_to_file("res://scenes/flight.tscn"))
		box.add_child(b)
	if box.get_child_count() > 0:
		box.get_child(0).grab_focus.call_deferred()
	if OS.get_environment("SC_SELECT_TEST") != "":   # automated check: screenshot, then launch the first mission
		await get_tree().create_timer(1.0).timeout
		var out := ProjectSettings.globalize_path("res://").path_join("../shots/mission_select.png")
		get_viewport().get_texture().get_image().save_png(out)
		(box.get_child(0) as Button).pressed.emit()


func _mission_order(a: String, b: String) -> bool:
	var ka := _key(a)
	var kb := _key(b)
	return ka < kb


func _key(f: String) -> String:
	var base := f.get_basename()
	var to := base.begins_with("TO_")
	var core := base.trim_prefix("TO_").trim_prefix("MISN-")
	var num := core.to_int()
	return "%d%03d%s" % [1 if to else 0, num, core.trim_prefix(str(num))]


func _unhandled_input(ev: InputEvent) -> void:
	if ev is InputEventKey and ev.pressed and ev.keycode == KEY_ESCAPE:
		get_tree().change_scene_to_file("res://scenes/boot.tscn")
