extends Node
## Input actions registered in code. Keyboard follows the original Strike Commander reference
## card (handled by key code in flight_scene.gd); actions here cover the analogue controls, fire,
## and gamepad buttons.
##
##   Arrows: stick   , . : rudder   Z: cockpit zoom onto the HUD   + -: throttle   1-5: military power   6-0: afterburner
##   Space: fire   W: next weapon   G: guns   T / Shift-T / Ctrl-T: target farther / closer / none
##   ; chaff   ' flare   L gear   B brakes (wheel / air)   Ctrl-E eject   D damage MFD
##   F1 cockpit  F2 chase  F3/F4/F5 left/right/back  F6 external   [ ] cycle views
##   Ctrl-R restart   Shift-R restart airborne   Ctrl-I cockpit art on/off   Esc menu

const KEYS := {
	"pitch_up": [KEY_DOWN], "pitch_down": [KEY_UP],
	"roll_left": [KEY_LEFT], "roll_right": [KEY_RIGHT],
	"yaw_left": [KEY_COMMA], "yaw_right": [KEY_PERIOD],
	"throttle_up": [KEY_EQUAL, KEY_KP_ADD], "throttle_down": [KEY_MINUS, KEY_KP_SUBTRACT],
	"fire": [KEY_SPACE],
}

const JOY_AXES := {
	"pitch_up": [JOY_AXIS_LEFT_Y, 1.0], "pitch_down": [JOY_AXIS_LEFT_Y, -1.0],
	"roll_left": [JOY_AXIS_LEFT_X, -1.0], "roll_right": [JOY_AXIS_LEFT_X, 1.0],
	"yaw_left": [JOY_AXIS_RIGHT_X, -1.0], "yaw_right": [JOY_AXIS_RIGHT_X, 1.0],
	"throttle_up": [JOY_AXIS_TRIGGER_RIGHT, 1.0], "throttle_down": [JOY_AXIS_TRIGGER_LEFT, 1.0],
}

const JOY_BUTTONS := {
	"fire": JOY_BUTTON_A, "next_weapon": JOY_BUTTON_X, "target_next": JOY_BUTTON_Y,
	"decoys": JOY_BUTTON_B, "brakes": JOY_BUTTON_LEFT_SHOULDER, "gear": JOY_BUTTON_RIGHT_SHOULDER,
	"reset_runway": JOY_BUTTON_BACK, "view_chase": JOY_BUTTON_DPAD_DOWN,
	"view_cockpit": JOY_BUTTON_DPAD_UP, "view_orbit": JOY_BUTTON_DPAD_RIGHT,
}


func _ready() -> void:
	for action in KEYS:
		_ensure(action)
		for k in KEYS[action]:
			var ev := InputEventKey.new()
			ev.physical_keycode = k
			InputMap.action_add_event(action, ev)
	for action in JOY_AXES:
		_ensure(action)
		var ev := InputEventJoypadMotion.new()
		ev.axis = JOY_AXES[action][0]
		ev.axis_value = JOY_AXES[action][1]
		InputMap.action_add_event(action, ev)
	for action in JOY_BUTTONS:
		_ensure(action)
		var ev := InputEventJoypadButton.new()
		ev.button_index = JOY_BUTTONS[action]
		InputMap.action_add_event(action, ev)


func _ensure(action: String) -> void:
	if not InputMap.has_action(action):
		InputMap.add_action(action, 0.15)
