extends Node
## Campaign state (autoload "Campaign"): the converted story data and the player's progress
## through it. Survives the switch to the flight scene and back.

const SAVE_PATH := "user://campaign.json"

var gameflow := {}      # story stages, maps, state changes, mission list (gamedata/story/gameflow.json)
var screens := {}       # location screens (screens.json)
var conversations: Array = []
var convart := {}       # conversation sets, faces, figures, establishing shots

# progress
var stage := 0                    # current story stage (gameflow MISS id)
var scene_id := -1                # location screen being shown
var flags := {}                   # story flags (int -> bool)
var cash := 0                     # dollars
var projected := 0
var overhead := 0
var next_stage_id := 0            # set by MIS2, used by GO / END_MISS
var accepted := false             # last yes/no answer in a conversation
var flown := {}                   # mission index -> success
var last_flown := -1
var tune_modifier := 0
var weapons := {}                 # stock: weapon id -> count
var kills := {}                   # "pilot:kind" -> count
var wingman := ""

# hand-over to and from the flight scene
var pending_mission := -1         # mission list index to fly after the current script
var advance_after_mission := 0    # stage to enter when the mission is over (0: stay)
var returning := false
var last_result := {}

var first_name := "Commander"
var last_name := "Commander"
var callsign := "Commander"


func load_data() -> bool:
	if not gameflow.is_empty():
		return true
	var dir := GameData.path("story")
	if not FileAccess.file_exists(dir.path_join("gameflow.json")):
		return false
	gameflow = JSON.parse_string(FileAccess.get_file_as_string(dir.path_join("gameflow.json")))
	screens = JSON.parse_string(FileAccess.get_file_as_string(dir.path_join("screens.json")))
	conversations = JSON.parse_string(FileAccess.get_file_as_string(dir.path_join("conversations.json")))
	convart = JSON.parse_string(FileAccess.get_file_as_string(dir.path_join("convart.json")))
	return true


func new_game() -> void:
	stage = 0
	scene_id = -1
	flags.clear()
	cash = 0
	projected = 0
	overhead = 0
	next_stage_id = 0
	accepted = false
	flown.clear()
	last_flown = -1
	tune_modifier = 0
	weapons.clear()
	kills.clear()
	wingman = ""
	pending_mission = -1
	advance_after_mission = 0
	returning = false


func stage_data(id := -1) -> Dictionary:
	return gameflow.get("stages", {}).get(str(stage if id < 0 else id), {})


func mission_name(index: int) -> String:
	var list: Array = gameflow.get("missions", [])
	return String(list[index]) if index >= 0 and index < list.size() else ""


## Speech file for a conversation line, or "" (lines without recorded speech).
func voice_path(code: String) -> String:
	if code == "":
		return ""
	var p := GameData.path("story/voice/%s.wav" % code.to_lower())
	return p if FileAccess.file_exists(p) else ""


func substitute(text: String) -> String:
	return text.replace("$N", first_name).replace("$S", last_name).replace("$C", callsign) \
		.replace("$W", wingman.capitalize() if wingman != "" else "my wingman")


## Apply a STAT change record (cash / overhead / weapon stock / kill board).
func apply_change(id: int) -> void:
	var ch: Dictionary = gameflow.get("changes", {}).get(str(id), {})
	if ch.has("cash"):
		projected = _op(projected, int(ch.cash[0]), int(ch.cash[1]) * 1000)
		if cash == 0:
			cash = projected
	if ch.has("over"):
		overhead = _op(overhead, int(ch.over[0]), int(ch.over[1]) * 1000)
	for w in ch.get("weapons", []):
		weapons[int(w[1])] = _op(int(weapons.get(int(w[1]), 0)), int(w[0]), int(w[2]))
	for k in ch.get("kills", []):
		var key := "%d:%d" % [int(k[1]), int(k[2])]
		kills[key] = _op(int(kills.get(key, 0)), int(k[0]), int(k[3]))


func _op(v: int, op: int, amount: int) -> int:
	match op:
		0: return v + amount
		1: return v - amount
		_: return amount


func save_game() -> void:
	var f := FileAccess.open(SAVE_PATH, FileAccess.WRITE)
	if f == null:
		return
	f.store_string(JSON.stringify({"stage": stage, "scene": scene_id, "flags": flags, "cash": cash,
		"projected": projected, "overhead": overhead, "next": next_stage_id, "flown": flown,
		"last_flown": last_flown, "tune": tune_modifier, "weapons": weapons, "kills": kills,
		"wingman": wingman}))


func has_save() -> bool:
	return FileAccess.file_exists(SAVE_PATH)


func load_game() -> bool:
	if not has_save():
		return false
	var d = JSON.parse_string(FileAccess.get_file_as_string(SAVE_PATH))
	if not d is Dictionary:
		return false
	new_game()
	stage = int(d.stage)
	scene_id = int(d.scene)
	for k in d.flags:
		flags[int(k)] = bool(d.flags[k])
	cash = int(d.cash)
	projected = int(d.projected)
	overhead = int(d.overhead)
	next_stage_id = int(d.next)
	for k in d.flown:
		flown[int(k)] = bool(d.flown[k])
	last_flown = int(d.last_flown)
	tune_modifier = int(d.tune)
	for k in d.weapons:
		weapons[int(k)] = int(d.weapons[k])
	kills = d.kills
	wingman = String(d.wingman)
	return true
