extends Canvas320
## The campaign between missions: runs the story script of the current stage (gameflow EFCT
## opcodes), shows the location screen with its clickable people and exits, plays
## conversations and establishing shots, and hands over to the flight scene for missions.

enum Op {
	CONV = 0, SCEN = 1, MIDGAME = 2, FLYM2 = 3, FLAG_ON = 6, FLAG_OFF = 7, SHOT = 8, IF_NOT_FLAG = 9,
	IF_FLAG = 10, FLYM = 12, MIS2 = 13, GO = 15, SAVE = 16, LOAD = 17, SHOW_MAP = 18, KILLBOARD = 19,
	IF_ACCEPTED = 20, IF_REJECTED = 21, END_MISS = 22, CATALOG = 23, LEDGER = 25, CHECK_BALANCE = 29,
	ELSE = 30, ENDIF = 31, IF_MISSION_WON = 32, APPLY_CHANGE = 34, IF_LAST_WON = 37, TUNE_MODIFIER = 38,
}
const IF_OPS := [Op.IF_NOT_FLAG, Op.IF_FLAG, Op.IF_ACCEPTED, Op.IF_REJECTED, Op.IF_MISSION_WON, Op.IF_LAST_WON]

var conv: ConversationPlayer
var shot: ShotPlayer
var _busy := false               # a script is running: clicks are ignored
var _next_stage := 0
var _hover := {}                 # sprite under the mouse
var _notice := ""
var _notice_left := 0.0
var _anim_t := 0.0
var _warned := {}


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	if not Campaign.load_data():
		_notice = "No story data: re-run tools/extract.py"
		_notice_left = 1e9
		return
	conv = ConversationPlayer.new()
	conv.visible = false
	add_child(conv)
	shot = ShotPlayer.new()
	shot.visible = false
	add_child(shot)
	if Campaign.returning:
		_after_mission.call_deferred()
	elif String(GameData.launch.get("campaign", "new")) == "loaded":
		_show_screen()
	elif String(GameData.launch.get("campaign", "new")) == "continue" and Campaign.load_game():
		_show_screen()
	else:
		Campaign.new_game()
		_enter_stage.call_deferred(0)


# ---------------------------------------------------------------- story flow
func _enter_stage(id: int) -> void:
	Campaign.stage = id
	var st := Campaign.stage_data()
	var scenes: Array = st.get("scenes", [])
	Campaign.scene_id = int(scenes[0].id) if scenes.size() > 0 else -1
	_log("stage %d" % id)
	await _run(st.get("efct", []), {})
	_settle()


## After a script: fly a pending mission, move on to the next stage, or show the screen.
func _settle() -> void:
	if Campaign.pending_mission >= 0:
		_fly()
	elif _next_stage > 0:
		var n := _next_stage
		_next_stage = 0
		_enter_stage(n)
	else:
		_show_screen()


func _run(efct: Array, sprite: Dictionary) -> void:
	_busy = true
	var exec: Array[bool] = [true]
	var seen_else: Array[bool] = [false]
	for ins in efct:
		var op := int(ins[0])
		var v := int(ins[1])
		var active := not exec.has(false)
		if op in IF_OPS:
			exec.append(_condition(op, v) if active else false)
			seen_else.append(false)
			continue
		if op == Op.ELSE:
			if exec.size() > 1 and not seen_else[-1]:
				var parent_active := not exec.slice(0, exec.size() - 1).has(false)
				exec[-1] = parent_active and not exec[-1]
				seen_else[-1] = true
			continue
		if op == Op.ENDIF:
			if exec.size() > 1:
				exec.pop_back()
				seen_else.pop_back()
			continue
		if not active:
			continue
		match op:
			Op.CONV:
				Audio.stop_music(1.0)
				conv.play(v)
				await conv.finished
			Op.SCEN:
				Campaign.scene_id = v
			Op.SHOT:
				shot.play(v)
				await shot.finished
			Op.FLAG_ON:
				Campaign.flags[v] = true
			Op.FLAG_OFF:
				Campaign.flags[v] = false
			Op.FLYM, Op.FLYM2:
				Campaign.pending_mission = v
			Op.MIS2:
				Campaign.next_stage_id = v
			Op.GO:
				_next_stage = Campaign.next_stage_id
			Op.END_MISS:
				var direct: bool = sprite.get("requ", []).is_empty()
				for r in sprite.get("requ", []):
					direct = direct or int(r[0]) == 1
				if direct or sprite.is_empty():
					_next_stage = Campaign.next_stage_id
			Op.APPLY_CHANGE:
				Campaign.apply_change(v)
			Op.TUNE_MODIFIER:
				Campaign.tune_modifier = v
			Op.SAVE:
				var r := await _save_dialog(true)
				if r.get("action") == "ok":
					Campaign.save_game(String(r.name))
			Op.LOAD:
				var r := await _save_dialog(false)
				if r.get("action") == "ok" and Campaign.load_game(String(r.name)):
					_next_stage = 0
			Op.SHOW_MAP:
				await _travel_map(v)
			Op.CHECK_BALANCE:
				if Campaign.cash < 0:
					await _show_notice("The Wildcats are bankrupt.", 3.0)
			Op.LEDGER:
				await _show_notice("Ledger: cash $%s, monthly overhead $%s" % [_money(Campaign.cash), _money(Campaign.overhead)], 3.0)
			Op.KILLBOARD, Op.CATALOG, Op.MIDGAME:
				await _show_notice("(%s not implemented yet)" % {Op.KILLBOARD: "kill board", Op.CATALOG: "weapons catalogue", Op.MIDGAME: "cutscene %d" % v}[op], 1.5)
			_:
				if not _warned.has(op):
					_warned[op] = true
					_log("unhandled story opcode %d (%d)" % [op, v])
	_busy = false


## The travel map for route `id` (GAMEFLOW.IFF WRLD/MAPS).
func _travel_map(id: int) -> void:
	var route: Dictionary = Campaign.gameflow.get("maps", {}).get(str(id), {})
	var path := GameData.path("frontend/frontend.json")
	if route.get("points", []).size() < 2 or not FileAccess.file_exists(path) or OS.get_environment("SC_STORY_TEST") != "":
		return
	var spec: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(path)).screens.travel
	var m := TravelMap.new().setup(spec, route)
	add_child(m)
	await m.finished


## The original save/load dialog, in the skin and palette of the screen it is opened from.
func _save_dialog(saving: bool) -> Dictionary:
	var path := GameData.path("frontend/frontend.json")
	if OS.get_environment("SC_STORY_TEST") != "":       # the automated walk-through doesn't stop here
		return {}
	if not FileAccess.file_exists(path):
		if saving:
			Campaign.save_game()
			return {}
		return {"action": "ok", "name": ""} if Campaign.has_save() else {}
	var dialogs: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(path)).get("saveload", {})
	var spec = dialogs.get(str(Campaign.scene_id), dialogs.get("14"))
	var d := SaveDialog.new().setup(spec, saving, null, "frontend/")
	add_child(d)
	return await d.closed


func _condition(op: int, v: int) -> bool:
	match op:
		Op.IF_FLAG: return bool(Campaign.flags.get(v, false))
		Op.IF_NOT_FLAG: return not bool(Campaign.flags.get(v, false))
		Op.IF_ACCEPTED: return Campaign.accepted
		Op.IF_REJECTED: return not Campaign.accepted
		Op.IF_MISSION_WON: return bool(Campaign.flown.get(v, false))
		Op.IF_LAST_WON: return bool(Campaign.flown.get(Campaign.last_flown, false))
	return false


func _fly() -> void:
	var idx := Campaign.pending_mission
	var name := Campaign.mission_name(idx)
	Campaign.advance_after_mission = _next_stage
	_next_stage = 0
	_log("fly mission %d %s" % [idx, name])
	if not FileAccess.file_exists(GameData.path("missions/%s.json" % name)):
		# not convertible yet: count it as flown successfully so the story can go on
		Campaign.pending_mission = -1
		Campaign.flown[idx] = true
		Campaign.last_flown = idx
		await _show_notice("Mission %s is not available yet - skipped." % name, 2.5)
		_after_mission_continue()
		return
	Campaign.returning = true
	Campaign.last_result = {}
	Audio.stop_music(1.0)
	GameData.launch = {"SC_SCENARIO": "mission", "SC_MISSION": name, "campaign": "1"}
	get_tree().change_scene_to_file("res://scenes/flight.tscn")


func _after_mission() -> void:
	Campaign.returning = false
	var idx := Campaign.pending_mission
	Campaign.pending_mission = -1
	if idx >= 0:
		Campaign.flown[idx] = bool(Campaign.last_result.get("won", false))
		Campaign.last_flown = idx
	_after_mission_continue()


func _after_mission_continue() -> void:
	var n := Campaign.advance_after_mission
	Campaign.advance_after_mission = 0
	if n > 0:
		_enter_stage(n)
	else:
		_show_screen()


# ---------------------------------------------------------------- location screen
func _screen() -> Dictionary:
	return Campaign.screens.get(str(Campaign.scene_id), {})


## Sprites of the current screen that the story places there in this stage, with their scripts.
func _sprites() -> Array:
	var out := []
	var scr := _screen()
	for sc in Campaign.stage_data().get("scenes", []):
		if int(sc.id) != Campaign.scene_id:
			continue
		for sp in sc.sprites:
			for opt in scr.get("sprites", []):
				if int(opt.id) == int(sp.id):
					out.append({"opt": opt, "story": sp, "active": _requirements_met(sp.get("requ", []))})
					break
	return out


func _requirements_met(requ: Array) -> bool:
	var ok := true
	var first := true
	var or_next := false
	for r in requ:
		var flag := bool(Campaign.flags.get(int(r[1]), false))
		var term := flag if int(r[0]) == 1 else not flag
		ok = term if first else (ok or term if or_next else ok and term)
		first = false
		or_next = int(r[0]) == 2
	return ok


func _show_screen() -> void:
	queue_redraw()
	var scr := _screen()
	if scr.get("tune") != null:
		Audio.music("gameflow", int(scr.tune))
	if OS.get_environment("SC_STORY_TEST") != "" and not _test_running:
		_test_running = true
		_story_test.call_deferred()


func _process(delta: float) -> void:
	_anim_t += delta
	if _notice_left > 0.0:
		_notice_left -= delta
	queue_redraw()


func _gui_input(ev: InputEvent) -> void:
	if _busy or conv.visible or shot.visible:
		return
	if ev is InputEventMouseMotion:
		_hover = _sprite_at(to_art(ev.position))
		mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND if not _hover.is_empty() and _hover.active else Control.CURSOR_ARROW
	elif ev is InputEventMouseButton and ev.pressed and ev.button_index == MOUSE_BUTTON_LEFT:
		var s := _sprite_at(to_art(ev.position))
		if not s.is_empty() and s.active:
			_click(s)


func _unhandled_key_input(ev: InputEvent) -> void:
	if ev.pressed and ev.keycode == KEY_ESCAPE and not _busy and not conv.visible and not shot.visible:
		Audio.stop_music(1.0)
		get_tree().change_scene_to_file("res://scenes/boot.tscn")


func _click(s: Dictionary) -> void:
	_hover = {}
	_log("click %s" % s.opt.label)
	if s.opt.has("tune"):
		Audio.music("gameflow", int(s.opt.tune))
	await _run(s.story.get("efct", []), s.story)
	_settle()


func _sprite_at(p: Vector2) -> Dictionary:
	var hit := {}
	for s in _sprites():
		var o: Dictionary = s.opt
		if o.has("rect"):
			var r: Array = o.rect
			if p.x >= r[0] and p.x <= r[2] and p.y >= r[1] and p.y <= r[3]:
				hit = s
		elif o.has("quad") and o.quad.size() >= 8:
			var q: Array = o.quad
			var poly := PackedVector2Array([Vector2(q[0], q[1]), Vector2(q[2], q[3]), Vector2(q[6], q[7]), Vector2(q[4], q[5])])
			if Geometry2D.is_point_in_polygon(p, poly):
				hit = s
	return hit


func _draw() -> void:
	draw_backdrop()
	var scr := _screen()
	for layer in scr.get("layers", []):
		if layer.size() > 0:
			draw_entry(layer[int(_anim_t * 8.0) % layer.size()] if layer.size() > 1 else layer[0])
	for s in _sprites():
		# frame 0 is the still picture; the others animate over it, in SEQU order or in a loop
		var fr: Array = s.opt.get("frames", [])
		if fr.is_empty():
			continue
		draw_entry(fr[0])
		var seq: Array = s.opt.get("sequ", [])
		var f := 0
		if seq.size() > 0:
			f = int(seq[int(_anim_t * 6.0) % seq.size()])
		elif fr.size() > 1:
			f = 1 + int(_anim_t * 8.0) % (fr.size() - 1)
		if f > 0 and f < fr.size():
			draw_entry(fr[f])
	if not _hover.is_empty() and not _busy and _hover.active:
		draw_caption(String(_hover.opt.label), 182, Color(1.0, 0.95, 0.6), 1)
	if _notice_left > 0.0:
		draw_rect(Rect2(to_screen(Vector2(20, 80)), to_screen(Vector2(300, 118)) - to_screen(Vector2(20, 80))), Color(0, 0, 0, 0.8))
		draw_caption(_notice, 84, Color.WHITE, 2)


func _show_notice(text: String, seconds: float) -> void:
	_notice = text
	_notice_left = seconds
	await get_tree().create_timer(seconds).timeout


func _money(v: int) -> String:
	var s := str(absi(v))
	var out := ""
	while s.length() > 3:
		out = "," + s.substr(s.length() - 3) + out
		s = s.substr(0, s.length() - 3)
	return ("-" if v < 0 else "") + s + out


func _log(s: String) -> void:
	if OS.get_environment("SC_STORY_TEST") != "" or OS.is_debug_build():
		print("STORY ", s)


# ---------------------------------------------------------------- automated check
static var _test_step := 0


## SC_STORY_TEST: screenshot the screen, click the first active sprite, repeat a few times.
func _story_test() -> void:
	_test_step += 1
	await get_tree().create_timer(0.8).timeout
	await capture("story_%02d_scene%d" % [_test_step, Campaign.scene_id])
	var sprites := _sprites().filter(func(s): return s.active)
	print("STORY screen %d: %s" % [Campaign.scene_id, ", ".join(sprites.map(func(s): return s.opt.label))])
	if _test_step >= int(OS.get_environment("SC_STORY_TEST")) or sprites.is_empty():
		get_tree().quit()
		return
	# SC_STORY_PATH: labels to click, in order, when they appear
	var pick: Dictionary = {}
	var path := OS.get_environment("SC_STORY_PATH").split(",", false)
	while _test_path_i < path.size() and pick.is_empty():
		for s in sprites:
			if String(s.opt.label) == path[_test_path_i]:
				pick = s
		if pick.is_empty():
			break
		_test_path_i += 1
	if not pick.is_empty():
		_test_running = false
		_click(pick)
		return
	# conversations first, then anything new, story-advancing exits last
	for pass_ in 3:
		for s in sprites:
			var key := "%d:%s" % [Campaign.stage, s.opt.label]
			if _test_clicked.has(key):
				continue
			var l := String(s.opt.label)
			var talk := l.begins_with("Talk")
			var exit_ := l.begins_with("Return") or l.contains("DOS") or l.contains("Load") or l.contains("Save")
			if (pass_ == 0 and talk) or (pass_ == 1 and not exit_ and not l.begins_with("Fly")) or pass_ == 2:
				pick = s
				break
		if not pick.is_empty():
			break
	if pick.is_empty():
		pick = sprites[0]
	_test_clicked["%d:%s" % [Campaign.stage, pick.opt.label]] = true
	_test_running = false
	_click(pick)


var _test_clicked := {}
var _test_running := false
static var _test_path_i := 0


func _shot(tag: String) -> void:
	capture(tag)
