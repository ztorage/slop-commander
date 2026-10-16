class_name MissionRunner
extends Node
## Runs an original Strike Commander mission (FORM MISN converted to JSON): spawns the cast,
## executes the PROG bytecode for actors and scenes, drives AI objectives, tracks the player's
## navigation points and decides success / failure.
##
## VM semantics (per actor program, re-run every AI tick): a linear pass with labels and
## forward jumps; objective opcodes return "in progress" until the objective completes, and
## 0x46 skips ahead while a task is still running.

signal radio(callsign: String, text: String)
signal mission_over(won: bool, reason: String)

const FT := 0.3048
const AI_TICK := 0.1
const MAX_DEPTH := 8

enum { CMP_UNSET = 0, CMP_EQUAL = 1, CMP_LESS = 2, CMP_GREATER = 4 }

const OP_EXIT := 0x01; const OP_SUB := 0x02; const OP_LABEL := 0x08; const OP_SPOT := 0x09
const OP_MOV := 0x10; const OP_FLAG_TO_WORK := 0x11; const OP_TO_GAMEFLOW := 0x14
const OP_ADD_WORK_TO_FLAG := 0x23; const OP_MUL := 0x2E; const OP_CMP_WV := 0x40; const OP_CMP_VW := 0x41
const OP_TEST_FLAG := 0x45; const OP_IF_BUSY := 0x46; const OP_BEQ := 0x48; const OP_BNE := 0x49
const OP_BLT := 0x4A; const OP_BGT := 0x4B; const OP_CALL := 0x4F; const OP_WORK_TO_FLAG := 0x50
const OP_FLAG_TRUE := 0x52; const OP_FLAG_FALSE := 0x53; const OP_FLAG_INC := 0x55; const OP_FLAG_DEC := 0x56
const OP_SCENE_ON := 0x80; const OP_SCENE_OFF := 0x81
const OP_ACTIVATE := 0x90; const OP_DEACTIVATE := 0x91; const OP_IN_AREA := 0x92; const OP_ALIVE := 0x93
const OP_DESTROY := 0x94; const OP_DIST_TARGET := 0x95; const OP_DIST_SPOT := 0x97; const OP_IS_ACTIVE := 0x98
const OP_WAIT := 0xA0; const OP_TAKEOFF := 0xA1; const OP_LAND := 0xA2; const OP_FLY_WP := 0xA5
const OP_FLY_AREA := 0xA6; const OP_DESTROY_TGT := 0xA7; const OP_DEFEND_TGT := 0xA8; const OP_DEFEND_AREA := 0xA9
const OP_FOLLOW := 0xAA; const OP_MESSAGE := 0xAB; const OP_NAV_SHOW := 0xB6; const OP_NAV_HIDE := 0xB7
const OP_JOIN := 0xB8; const OP_LEAVE := 0xB9; const OP_PACIFY := 0xBE; const OP_PATROL := 0xBF
const OBJECTIVES := [0xA1, 0xA2, 0xA5, 0xA6, 0xA7, 0xA8, 0xA9, 0xAA, 0xAC, 0xBF]

var data := {}                    # mission JSON
var world: CombatWorld
var terrain: Terrain
var player: Aircraft
var actors: Array[MissionActor] = []
var flags := PackedInt32Array()
var gameflow := {}
var scenes: Array = []            # [{data, active, inside, started}]
var nav: Array = []               # player's navigation points [{op, arg, label, pos}]
var nav_index := 0
var won := false
var lost := false
var over := false
var player_area := -1
var unknown_ops := {}
var _tick := 0.0
var _airborne_once := false


func setup(mission: Dictionary, combat: CombatWorld, ter: Terrain, player_aircraft: Aircraft) -> void:
	data = mission
	world = combat
	terrain = ter
	player = player_aircraft
	flags.resize(256)
	for i in data.flags.size():
		flags[i] = int(data.flags[i])
	for s in data.scenes:
		scenes.append({"data": s, "active": int(s.active) == 1, "inside": false, "started": false})
	for p in data.parts:
		var a := MissionActor.new()
		a.id = int(p.id)
		a.name = String(p.actor)
		a.part = p
		a.is_player = a.name == "PLAYER"
		a.friendly = int(p.team) != 255
		var prof := GameData.path("profiles/%s.json" % a.name)
		if FileAccess.file_exists(prof):
			a.profile = JSON.parse_string(FileAccess.get_file_as_string(prof))
		actors.append(a)
	# scene casts are indices into the PART list; global (area -1) active scenes start in the world,
	# other actors appear when their scene activates or a script activates them (0x90)
	for a in actors:
		if a.is_player:
			_adopt_player(a)
	for s in scenes:
		if int(s.data.area) == -1 and s.active:
			s.started = true
			for c in s.data.cast:
				var a := _cast_actor(int(c))
				if a and not a.is_player:
					_spawn(a, s)
	_build_nav()
	world.aircraft_destroyed.connect(_on_aircraft_destroyed)
	world.aircraft_damaged.connect(_on_aircraft_damaged)
	for a in actors:
		_run(a, int(a.part.prog_init))


# ---------------------------------------------------------------- geometry
func area_pos(i: int) -> Vector3:
	if i < 0 or i >= data.areas.size():
		return Vector3.ZERO
	var p: Array = data.areas[i].pos_ft
	return Vector3(p[0], p[1], p[2])


func spot_world(i: int) -> Vector3:
	if i < 0 or i >= data.spots.size():
		return Vector3.ZERO
	var s: Dictionary = data.spots[i]
	var p: Array = s.pos_ft
	var base := area_pos(int(s.area)) if int(s.area) >= 0 else Vector3.ZERO
	return ft_to_world(Vector3(base.x + p[0], base.y + p[1], base.z + p[2]))


func area_world(i: int) -> Vector3:
	return ft_to_world(area_pos(i))


func ft_to_world(f: Vector3) -> Vector3:
	return Vector3(f.x * FT, f.z * FT, -f.y * FT)


## Smallest area containing the point (0-based index), or -1.
func area_at(p: Vector3) -> int:
	var best := -1
	var best_w := INF
	for i in data.areas.size():
		var a: Dictionary = data.areas[i]
		var c := area_world(i)
		var half := float(a.width_ft) * FT * 0.5
		if absf(p.x - c.x) <= half and absf(p.z - c.z) <= half and float(a.width_ft) < best_w:
			best = i
			best_w = float(a.width_ft)
	return best


# ---------------------------------------------------------------- actors
func _adopt_player(a: MissionActor) -> void:
	a.node = player
	a.active = true
	a.spawned = true
	player.team = 0
	var pos := _part_world_pos(a, null)
	var ground := pos.y - _ground(pos) < 6.0
	if ground:
		pos.y = _ground(pos) + player.fm.gear_height
	player.place(pos, float(a.part.heading), 0.0 if ground else 200.0, ground)


func _ground(p: Vector3) -> float:
	return world.ground_height(p)


func _part_world_pos(a: MissionActor, scene) -> Vector3:
	var p: Array = a.part.pos_ft
	var base := Vector3.ZERO
	if int(a.part.area) != 255:
		base = area_pos(int(a.part.area))
	elif int(a.part.relative) == 1:
		var ar := int(scene.data.area) if scene != null and int(scene.data.area) >= 0 else player_area
		if ar >= 0:
			base = area_pos(ar)
	var w := ft_to_world(Vector3(base.x + p[0], base.y + p[1], base.z + p[2]))
	if int(p[2]) == 0 and base == Vector3.ZERO:
		w.y = _ground(w)
	return w


func _spawn(a: MissionActor, scene) -> void:
	if a.spawned or a.destroyed:
		return
	a.spawned = true
	a.active = true
	var model := String(a.part.model)
	var pos := _part_world_pos(a, scene)
	if FileAccess.file_exists(GameData.path("aircraft/%s.json" % model)):
		var ac := Aircraft.create(model)
		ac.team = 0 if a.friendly else 1
		_apply_loadout(ac, String(a.part.loadout))
		var skill := 0.6
		if a.profile.has("skills"):
			skill = clampf(float(a.profile.skills.get("air_to_air", 8)) / 16.0, 0.25, 1.0)
		ac.ai = AIPilot.new(ac, skill)
		ac.ai.mission_actor = a
		ac.ai.runner = self
		world.add_aircraft(ac)
		var on_ground := pos.y - _ground(pos) < 6.0
		if on_ground:
			pos.y = _ground(pos) + ac.fm.gear_height
		ac.place(pos, float(a.part.heading), 0.0 if on_ground else 190.0, on_ground)
		a.node = ac
	else:
		var u := GroundUnit.create(model, 0 if a.friendly else 1)
		world.add_ground_unit(u)
		if pos.y < _ground(pos) + 2.0 or int(a.part.pos_ft[2]) == 0:
			pos.y = _ground(pos)
		u.global_position = pos
		u.rotation.y = deg_to_rad(-float(a.part.heading))
		a.node = u
	_run(a, int(a.part.prog_activated))


func _apply_loadout(ac: Aircraft, loadout: String) -> void:
	if loadout == "":
		return
	var f := GameData.path("loadouts/%s.json" % loadout)
	if not FileAccess.file_exists(f):
		return
	var l: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(f))
	ac.data.weapons = {"stations": l.stations, "chaff": l.get("chaff", 0), "flares": l.get("flares", 0)}
	ac.weapons = WeaponSystem.new()
	ac.weapons.setup(ac)


## Scene casts index the PART list (in file order).
func _cast_actor(part_index: int) -> MissionActor:
	return actors[part_index] if part_index >= 0 and part_index < actors.size() else null


func actor_by_id(id: int) -> MissionActor:
	for a in actors:
		if a.id == id:
			return a
	return null


func actor_for(node: Node) -> MissionActor:
	for a in actors:
		if a.node == node:
			return a
	return null


# ---------------------------------------------------------------- per-frame
func step(dt: float) -> void:
	if over:
		return
	for a in actors:
		if a.spawned and not a.destroyed and not a.alive():
			a.destroyed = true
			_run(a, int(a.part.prog_destroyed))
	_tick += dt
	if _tick < AI_TICK:
		return
	_tick = 0.0
	player_area = area_at(player.global_position)
	for i in scenes.size():
		var s: Dictionary = scenes[i]
		var area := int(s.data.area)
		var inside: bool = s.active and (area == -1 or area == player_area)
		if inside and not s.inside:
			s.inside = true
			if not s.started:
				s.started = true
				for c in s.data.cast:
					var a := _cast_actor(int(c))
					if a and not a.is_player:
						_spawn(a, s)
			_run(null, int(s.data.prog_activated))
		elif not inside and s.inside:
			s.inside = false
			_run(null, int(s.data.prog_leaving))
		if s.inside:
			_run(null, int(s.data.prog_update))
	for a in actors:
		if a.active and a.spawned and not a.destroyed and not a.is_player:
			_check_objective(a)
			_run(a, int(a.part.prog_update))
	_update_player_nav()
	_check_end()


# ---------------------------------------------------------------- the VM
func _run(actor: MissionActor, prog: int, depth := 0, task_state := 0) -> int:
	if prog < 0 or prog >= data.progs.size() or prog == 255 or depth > MAX_DEPTH:
		return task_state
	var code: Array = data.progs[prog]
	var execute := true
	var jump_to := -1
	var work := 0
	var cmp := CMP_UNSET
	for i in code.size():
		var op := int(code[i][0])
		var arg := int(code[i][1])
		if not execute:
			if op == OP_LABEL and arg == jump_to:
				execute = true
			continue
		match op:
			OP_EXIT: return task_state
			OP_SUB: task_state = _run(actor, arg, depth + 1, task_state)
			OP_LABEL, OP_SPOT, 0xD0: pass
			OP_MOV: work = arg
			OP_FLAG_TO_WORK: work = flags[arg]
			OP_TO_GAMEFLOW: gameflow[arg] = work
			OP_ADD_WORK_TO_FLAG: flags[arg] += work
			OP_MUL: work *= arg
			# provisional semantics inferred from usage (end-of-mission scoring); see docs/FORMATS.md
			0x20: work += arg
			0x21: work += flags[arg]
			0x24: work -= flags[arg]
			0x25: work -= arg
			0x2F:
				if arg != 0:
					work = int(work / arg)
			0x4C:
				if cmp & (CMP_LESS | CMP_EQUAL):
					jump_to = arg
					execute = false
			0x4E:
				jump_to = arg
				execute = false
			OP_CMP_WV: cmp = _compare(work, arg)
			OP_CMP_VW: cmp = _compare(arg, work)
			OP_TEST_FLAG: cmp = CMP_EQUAL if flags[arg] != 0 else CMP_UNSET
			OP_IF_BUSY:
				if task_state != 0:
					jump_to = arg
					execute = false
			OP_BEQ:
				if cmp & CMP_EQUAL:
					jump_to = arg
					execute = false
			OP_BNE:
				if not (cmp & CMP_EQUAL):
					jump_to = arg
					execute = false
			OP_BLT:
				if cmp & CMP_LESS:
					jump_to = arg
					execute = false
			OP_BGT:
				if cmp & CMP_GREATER:
					jump_to = arg
					execute = false
			OP_CALL:
				jump_to = work
				execute = false
			OP_WORK_TO_FLAG: flags[arg] = work
			OP_FLAG_TRUE: flags[arg] = 1
			OP_FLAG_FALSE: flags[arg] = 0
			OP_FLAG_INC: flags[arg] += 1
			OP_FLAG_DEC: flags[arg] -= 1
			OP_SCENE_ON, OP_SCENE_OFF:
				if arg < scenes.size():
					scenes[arg].active = op == OP_SCENE_ON
			OP_ACTIVATE:
				var t := actor_by_id(arg)
				if t:
					if t.spawned:
						t.active = true
					else:
						_spawn(t, null)
			OP_DEACTIVATE:
				var t := actor_by_id(arg)
				if t:
					t.active = false
			OP_IN_AREA:
				var t := actor_by_id(arg)
				var me_area := area_at(actor.position()) if actor else player_area
				cmp = CMP_EQUAL if t and t.spawned and area_at(t.position()) == me_area else CMP_UNSET
			OP_ALIVE:
				var t := actor_by_id(arg)
				cmp = CMP_UNSET if t and t.alive() else CMP_EQUAL   # EQUAL means destroyed
			OP_DESTROY:
				var t := actor_by_id(arg)
				if t and t.node is Aircraft:
					world.destroy(t.node, "destroyed")
				elif t and t.node is GroundUnit:
					world.damage(t.node, 1e6, null)
				elif t:
					t.destroyed = true
			OP_DIST_TARGET:
				var t := actor_by_id(arg)
				work = int((t.position() - _me(actor)).length() / FT / 1000.0) if t and t.spawned else 999
			OP_DIST_SPOT:
				work = int((spot_world(arg) - _me(actor)).length() / FT / 1000.0)
			OP_IS_ACTIVE:
				var t := actor_by_id(arg)
				cmp = CMP_EQUAL if t and (t.active or t.is_player) else CMP_UNSET
			OP_WAIT:
				if actor:
					task_state = 1
					if actor.wait_timer <= 0.0:
						actor.wait_timer = float(arg)
					else:
						actor.wait_timer -= AI_TICK
						if actor.wait_timer <= 0.0:
							actor.wait_timer = 0.0
							task_state = 0
			OP_MESSAGE:
				if actor and not actor.is_player:
					_message(actor, arg)
			OP_NAV_SHOW, OP_NAV_HIDE:
				var t := actor if arg == 255 else actor_by_id(arg)
				if t:
					t.on_nav_map = op == OP_NAV_SHOW
			OP_JOIN, OP_LEAVE:
				var t := actor if arg == 255 else actor_by_id(arg)
				if t:
					t.friendly = op == OP_JOIN or t.friendly
			OP_PACIFY:
				var t := actor_by_id(arg)
				if t and t.node is Aircraft and (t.node as Aircraft).ai:
					(t.node as Aircraft).ai.pacified = true
			_:
				if op in OBJECTIVES:
					if actor and not actor.is_player:
						var a2 := int(code[i + 1][1]) if i + 1 < code.size() and int(code[i + 1][0]) == OP_SPOT else 255
						var busy := actor.set_objective(op, arg)
						if busy:
							actor.command_arg2 = a2
						if op == OP_FOLLOW and arg == 255:
							actor.command_arg = int(actor.part.leader)
						if op in [OP_DESTROY_TGT, OP_DEFEND_TGT]:
							actor.target = actor_by_id(arg)
						task_state = 1 if busy else 0
				else:
					unknown_ops[op] = unknown_ops.get(op, 0) + 1
	return task_state


func _compare(a: int, b: int) -> int:
	var c := CMP_UNSET
	if a == b:
		c |= CMP_EQUAL
	if a < b:
		c |= CMP_LESS
	if a > b:
		c |= CMP_GREATER
	return c


func _me(actor: MissionActor) -> Vector3:
	return actor.position() if actor else player.global_position


func _message(actor: MissionActor, arg: int) -> void:
	var text := String(actor.profile.get("messages", {}).get(str(arg), ""))
	if text != "":
		radio.emit(actor.callsign(), text)
		if actor.profile.has("voice"):
			Audio.speech(int(actor.profile.voice), arg)
	if actor.name == "STRIBASE":
		if arg == 20:
			won = true
		elif arg == 21 or arg == 22:
			lost = true


# ---------------------------------------------------------------- combat chatter
## Event-driven radio lines from pilot profiles (message numbers shared by all profiles:
## 2 "Outstanding", 7 "I'm hit", 9 "Ejecting / Going down").
var _hit_reported := {}


func _on_aircraft_damaged(a: Aircraft, _by: Node3D) -> void:
	var who := actor_for(a)
	if who and not who.is_player and a.alive and a.hp < a.max_hp * 0.6 and not _hit_reported.has(who):
		_hit_reported[who] = true
		_message(who, 7)


func _on_aircraft_destroyed(a: Aircraft) -> void:
	var who := actor_for(a)
	if who and not who.is_player:
		_message(who, 9)
	var killer := actor_for(a.last_attacker) if a.last_attacker else null
	if killer and not killer.is_player and killer.friendly and who and not who.friendly:
		_message(killer, 2)


# ---------------------------------------------------------------- objectives
## Mark AI objectives complete when their condition is met.
func _check_objective(a: MissionActor) -> void:
	var ac := a.aircraft()
	if ac == null or a.command_done:
		return
	var p := ac.global_position
	match a.command:
		OP_TAKEOFF:
			a.command_done = not ac.fm.on_ground and p.y - _ground(p) > 300.0
		OP_FLY_WP:
			var s := spot_world(a.command_arg)
			a.command_done = Vector2(p.x - s.x, p.z - s.z).length() < 3000.0 * FT
		OP_FLY_AREA:
			a.command_done = area_at(p) == a.command_arg
		OP_LAND:
			a.command_done = ac.fm.on_ground and ac.fm.airspeed < 15.0
		OP_DESTROY_TGT:
			a.command_done = a.target == null or not a.target.alive()


## Player navigation points come from the player's own script: objective opcodes in order,
## with the following SET_MESSAGE naming the point (MSGS chunk).
func _build_nav() -> void:
	var me: MissionActor = null
	for a in actors:
		if a.is_player:
			me = a
	if me == null:
		return
	var code: Array = data.progs[int(me.part.prog_init)] if int(me.part.prog_init) < data.progs.size() else []
	for c in code:
		var op := int(c[0])
		var arg := int(c[1])
		if op in [OP_TAKEOFF, OP_FLY_WP, OP_LAND, OP_FLY_AREA]:
			var pos := area_world(arg) if op == OP_FLY_AREA else spot_world(arg)
			var label: String = {OP_TAKEOFF: "Take off", OP_LAND: "Land", OP_FLY_WP: "Waypoint", OP_FLY_AREA: "Area"}[op]
			if op == OP_FLY_AREA and arg < data.areas.size():
				label = String(data.areas[arg].name).capitalize()
			nav.append({"op": op, "arg": arg, "label": label, "pos": pos})
		elif op == OP_MESSAGE and nav.size() > 0 and arg < data.messages.size():
			nav[-1].label = String(data.messages[arg]).replace("\n", " ")
	nav_index = 0


func current_nav() -> Dictionary:
	return nav[nav_index] if nav_index < nav.size() else {}


func _update_player_nav() -> void:
	if not player.fm.on_ground:
		_airborne_once = true
	var n := current_nav()
	if n.is_empty():
		return
	var p := player.global_position
	var done := false
	match int(n.op):
		OP_TAKEOFF:
			done = not player.fm.on_ground and p.y - _ground(p) > 150.0
		OP_FLY_WP:
			done = Vector2(p.x - n.pos.x, p.z - n.pos.z).length() < 3000.0 * FT
		OP_FLY_AREA:
			done = area_at(p) == int(n.arg)
		OP_LAND:
			done = player.fm.on_ground and player.fm.airspeed < 10.0
	if done:
		nav_index += 1


func _check_end() -> void:
	if not player.alive or player.ejected:
		var why := "You ejected." if player.ejected else ("You were shot down." if player.death_reason == "shot down" else "You crashed (%s)." % player.fm.crash_reason)
		_finish(false, why)
	elif lost:
		_finish(false, "Mission failed.")
	elif _airborne_once and player.fm.on_ground and player.fm.airspeed < 5.0:
		_finish(won, "Mission accomplished." if won else "You landed before completing the mission.")
	elif won and nav_index >= nav.size():
		_finish(true, "Mission accomplished.")


func _finish(success: bool, reason: String) -> void:
	if over:
		return
	over = true
	mission_over.emit(success, reason)
