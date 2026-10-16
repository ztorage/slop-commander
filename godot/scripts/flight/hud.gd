class_name FlightHud
extends Control
## Head-up display drawn procedurally: pitch ladder, flight-path marker, speed/altitude boxes,
## heading tape, G / Mach / AoA, throttle, fuel and status flags. Milestone 4 replaces this with
## the original cockpit art.

const COL := Color(0.35, 1.0, 0.45)
const WARN := Color(1.0, 0.35, 0.25)
const FT := 3.28084
const KT := 1.0 / 0.514444

var aircraft: Aircraft
var camera: Camera3D
var message := ""
var _font: Font


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_font = ThemeDB.fallback_font


func _process(_d: float) -> void:
	queue_redraw()


func _txt(p: Vector2, s: String, size := 16, col := COL, align := HORIZONTAL_ALIGNMENT_LEFT, w := -1.0) -> void:
	draw_string_outline(_font, p, s, align, w, size, 3, Color(0, 0, 0, 0.6))
	draw_string(_font, p, s, align, w, size, col)


func _draw() -> void:
	if aircraft == null or camera == null:
		return
	var fm := aircraft.fm
	var vp := get_viewport_rect().size
	if camera is CameraRig and (camera as CameraRig).view != CameraRig.View.COCKPIT:
		_draw_external(fm, vp)
		return
	var c := vp * 0.5
	var px_per_rad := (vp.y * 0.5) / tan(deg_to_rad(camera.fov * 0.5))
	var fwd := -fm.basis.z
	var pitch := asin(clampf(fwd.y, -1, 1))
	var heading := fposmod(rad_to_deg(atan2(fwd.x, -fwd.z)), 360.0)
	var roll := fm.basis.get_euler(EULER_ORDER_YXZ).z  # screen rotation opposite to bank

	# --- pitch ladder (rotated by roll), relative to the boresight ---
	draw_set_transform(c, roll, Vector2.ONE)
	for deg in range(-90, 91, 5):
		var y := -(deg_to_rad(deg) - pitch) * px_per_rad
		if absf(y) > vp.y * 0.38:
			continue
		var w := 120.0 if deg == 0 else 70.0
		var gap := 40.0
		if deg == 0:
			draw_line(Vector2(-w * 2.2, y), Vector2(-gap, y), COL, 2)
			draw_line(Vector2(gap, y), Vector2(w * 2.2, y), COL, 2)
		elif deg % 10 == 0 or deg % 5 == 0 and deg != 0:
			var dashed := deg < 0
			for side in [-1, 1]:
				var a := Vector2(side * gap, y)
				var b := Vector2(side * (gap + w), y)
				if dashed:
					for k in 4:
						draw_line(a.lerp(b, k / 4.0), a.lerp(b, k / 4.0 + 0.15), COL, 2)
				else:
					draw_line(a, b, COL, 2)
				draw_line(b, b + Vector2(0, 10 if deg > 0 else -10), COL, 2)
			if deg % 10 == 0:
				_txt(Vector2(gap + w + 8, y + 6), str(absi(deg)), 14)
				_txt(Vector2(-gap - w - 30, y + 6), str(absi(deg)), 14)
	draw_set_transform(Vector2.ZERO, 0, Vector2.ONE)

	# --- boresight and flight path marker ---
	draw_line(c + Vector2(-14, 0), c + Vector2(-5, 0), COL, 2)
	draw_line(c + Vector2(5, 0), c + Vector2(14, 0), COL, 2)
	draw_line(c + Vector2(0, -5), c + Vector2(0, -12), COL, 2)
	if fm.airspeed > 5.0:
		var vb := fm.basis.inverse() * fm.velocity.normalized()
		if vb.z < -0.1:
			var fpm := c + Vector2(vb.x / -vb.z, -vb.y / -vb.z) * px_per_rad
			draw_arc(fpm, 9, 0, TAU, 20, COL, 2)
			draw_line(fpm + Vector2(-22, 0), fpm + Vector2(-9, 0), COL, 2)
			draw_line(fpm + Vector2(9, 0), fpm + Vector2(22, 0), COL, 2)
			draw_line(fpm + Vector2(0, -9), fpm + Vector2(0, -18), COL, 2)

	# --- heading tape ---
	var ty := 46.0
	for k in range(-30, 31, 5):
		var hd := int(round(heading / 5.0)) * 5 + k
		var x := c.x + (hd - heading) * 9.0
		if absf(x - c.x) > 150:
			continue
		draw_line(Vector2(x, ty), Vector2(x, ty + (12 if posmod(hd, 10) == 0 else 6)), COL, 2)
		if posmod(hd, 30) == 0:
			_txt(Vector2(x - 20, ty - 6), "%03d" % posmod(hd, 360), 14, COL, HORIZONTAL_ALIGNMENT_CENTER, 40)
	draw_line(Vector2(c.x, ty + 16), Vector2(c.x - 6, ty + 26), COL, 2)
	draw_line(Vector2(c.x, ty + 16), Vector2(c.x + 6, ty + 26), COL, 2)

	# --- speed (knots) and altitude (feet) boxes ---
	var box_y := c.y - 16
	_box(Vector2(c.x - 300, box_y), "%d" % (fm.airspeed * KT))
	_box(Vector2(c.x + 210, box_y), "%d" % (fm.position.y * FT))
	_txt(Vector2(c.x - 300, box_y - 10), "KTS", 13)
	_txt(Vector2(c.x + 210, box_y - 10), "ALT", 13)
	var climb := fm.velocity.y * FT * 60.0
	_txt(Vector2(c.x + 210, box_y + 52), "%+d FPM" % int(round(climb / 100.0) * 100), 13)
	_txt(Vector2(c.x - 300, box_y + 52), "M %.2f" % (fm.airspeed / 340.0), 13)

	# --- left column: G, AoA ---
	var lx := c.x - 300
	var ly := c.y + 120
	_txt(Vector2(lx, ly), "G %.1f" % fm.load_factor, 16, WARN if fm.load_factor > fm.max_g * 0.95 else COL)
	_txt(Vector2(lx, ly + 22), "AOA %.0f" % rad_to_deg(fm.alpha), 16, WARN if fm.stalled else COL)

	# --- right column: throttle, fuel ---
	var rx := c.x + 210
	var thr := "AB" if fm.afterburner and fm.has_afterburner and fm.throttle > 0.95 else "%d%%" % int(fm.throttle * 100)
	_txt(Vector2(rx, ly), "THR " + thr, 16)
	var fuel_frac := fm.fuel / maxf(fm.fuel_capacity, 1)
	_txt(Vector2(rx, ly + 22), "FUEL %d" % int(fm.fuel * 2.20462), 16, WARN if fuel_frac < 0.15 else COL)

	# --- status flags ---
	var flags := []
	if fm.gear_down: flags.append("GEAR")
	if fm.airbrake: flags.append("SPD BRK")
	if fm.brakes and fm.on_ground: flags.append("BRAKES")
	if fm.stalled: flags.append("STALL")
	_txt(Vector2(c.x - 150, vp.y - 60), "  ".join(flags), 16, WARN if fm.stalled else COL, HORIZONTAL_ALIGNMENT_CENTER, 300)

	if message != "":
		_txt(Vector2(0, c.y - 120), message, 26, WARN, HORIZONTAL_ALIGNMENT_CENTER, vp.x)


## Compact readout for chase/orbit views, where a pilot's HUD would be misleading.
func _draw_external(fm: FlightModel, vp: Vector2) -> void:
	var fwd := -fm.basis.z
	var heading := fposmod(rad_to_deg(atan2(fwd.x, -fwd.z)), 360.0)
	var thr := "AB" if fm.afterburner and fm.has_afterburner and fm.throttle > 0.95 else "%d%%" % int(fm.throttle * 100)
	var line := "%d KTS   %d FT   HDG %03d   G %.1f   THR %s   FUEL %d" % [
		fm.airspeed * KT, fm.position.y * FT, heading, fm.load_factor, thr, fm.fuel * 2.20462]
	var flags := []
	if fm.gear_down: flags.append("GEAR")
	if fm.airbrake: flags.append("SPD BRK")
	if fm.stalled: flags.append("STALL")
	_txt(Vector2(0, vp.y - 40), line + ("   " + " ".join(flags) if flags.size() else ""), 16, COL,
		HORIZONTAL_ALIGNMENT_CENTER, vp.x)
	_txt(Vector2(16, 28), "F1 cockpit  F2 chase  F3 orbit   Arrows stick  , . rudder  +/- 1-0 throttle  Bksp AB  G gear  B brake  R/T restart", 13, Color(1, 1, 1, 0.7))
	if message != "":
		_txt(Vector2(0, vp.y * 0.5 - 120), message, 26, WARN, HORIZONTAL_ALIGNMENT_CENTER, vp.x)


func _box(p: Vector2, s: String) -> void:
	draw_rect(Rect2(p, Vector2(90, 32)), COL, false, 2)
	_txt(p + Vector2(0, 24), s, 20, COL, HORIZONTAL_ALIGNMENT_RIGHT, 82)
