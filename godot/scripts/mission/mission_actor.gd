class_name MissionActor
extends RefCounted
## One mission participant (a PART record): its programs, objective state and scene node.

var id := 0                      # PART id (= index into CAST)
var name := ""                   # CAST name, e.g. PLAYER, STERN, MIG-21R, STRIBASE
var part := {}
var profile := {}
var node: Node3D                 # Aircraft for flyers, a static model otherwise
var is_player := false
var active := false
var spawned := false
var destroyed := false
var on_nav_map := false
var friendly := true

# objective state (set by the mission program)
var command := 0                 # opcode of the current objective
var command_arg := -1
var command_arg2 := 255
var command_done := false
var wait_timer := 0.0
var target: MissionActor


func aircraft() -> Aircraft:
	return node as Aircraft


func position() -> Vector3:
	return node.global_position if node else Vector3.ZERO


func alive() -> bool:
	if destroyed:
		return false
	if node is Aircraft:
		return (node as Aircraft).alive
	if node is GroundUnit:
		return (node as GroundUnit).alive
	return true


func callsign() -> String:
	return String(profile.get("callsign", name)) if not profile.is_empty() else name


## Set an objective; returns true while it is still in progress (original VM semantics).
func set_objective(op: int, arg: int) -> bool:
	if command != op or command_arg != arg:
		command_done = false
	command = op
	command_arg = arg
	return not command_done
