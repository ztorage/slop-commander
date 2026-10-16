extends Node
## Registers flight input actions at startup (keyboard + gamepad), so bindings live in code
## rather than in hand-edited project.godot InputEvent blobs.
##
## Keyboard (close to the original's layout):
##   Arrows: stick   , / . : rudder   + / - : throttle   1-0: throttle 10%-100%
##   Backspace: afterburner   G: gear   B: airbrake   W: wheel brakes   R: restart on runway
##   T: restart airborne   F1/F2/F3: cockpit / chase / orbit camera

const KEYS := {
	"pitch_up": [KEY_DOWN], "pitch_down": [KEY_UP],
	"roll_left": [KEY_LEFT], "roll_right": [KEY_RIGHT],
	"yaw_left": [KEY_COMMA, KEY_Z], "yaw_right": [KEY_PERIOD, KEY_X],
	"throttle_up": [KEY_EQUAL, KEY_KP_ADD], "throttle_down": [KEY_MINUS, KEY_KP_SUBTRACT],
	"afterburner": [KEY_BACKSPACE, KEY_TAB],
	"gear": [KEY_G], "airbrake": [KEY_B], "brakes": [KEY_W],
	"reset_runway": [KEY_R], "reset_air": [KEY_T],
	"view_cockpit": [KEY_F1], "view_chase": [KEY_F2], "view_orbit": [KEY_F3],
}

const JOY_AXES := {
	"pitch_up": [JOY_AXIS_LEFT_Y, 1.0], "pitch_down": [JOY_AXIS_LEFT_Y, -1.0],
	"roll_left": [JOY_AXIS_LEFT_X, -1.0], "roll_right": [JOY_AXIS_LEFT_X, 1.0],
	"yaw_left": [JOY_AXIS_RIGHT_X, -1.0], "yaw_right": [JOY_AXIS_RIGHT_X, 1.0],
	"throttle_up": [JOY_AXIS_TRIGGER_RIGHT, 1.0], "throttle_down": [JOY_AXIS_TRIGGER_LEFT, 1.0],
}

const JOY_BUTTONS := {
	"afterburner": JOY_BUTTON_RIGHT_SHOULDER, "airbrake": JOY_BUTTON_LEFT_SHOULDER,
	"gear": JOY_BUTTON_Y, "brakes": JOY_BUTTON_B, "reset_runway": JOY_BUTTON_BACK,
	"view_chase": JOY_BUTTON_DPAD_DOWN, "view_cockpit": JOY_BUTTON_DPAD_UP, "view_orbit": JOY_BUTTON_DPAD_RIGHT,
}


func _ready() -> void:
	for action in KEYS:
		if not InputMap.has_action(action):
			InputMap.add_action(action, 0.15)
		for k in KEYS[action]:
			var ev := InputEventKey.new()
			ev.physical_keycode = k
			InputMap.action_add_event(action, ev)
	for action in JOY_AXES:
		var ev := InputEventJoypadMotion.new()
		ev.axis = JOY_AXES[action][0]
		ev.axis_value = JOY_AXES[action][1]
		InputMap.action_add_event(action, ev)
	for action in JOY_BUTTONS:
		var ev := InputEventJoypadButton.new()
		ev.button_index = JOY_BUTTONS[action]
		InputMap.action_add_event(action, ev)
