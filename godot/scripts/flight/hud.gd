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
var cockpit: Cockpit
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
	var rig := camera as CameraRig
	if rig and not rig.is_cockpit():
		_draw_external(fm, vp)
		return
	if rig and rig.view != CameraRig.View.COCKPIT_FRONT:
		_draw_status(fm, vp, vp.y - 30)  # side/rear views: no HUD glass in sight
		return
	# HUD frame: the art's HUD glass, or a centred region when the cockpit art is hidden
	var c := vp * 0.5
	var glass := Rect2(vp * Vector2(0.22, 0.08), vp * Vector2(0.56, 0.8))
	if cockpit and cockpit.art_enabled:
		c = cockpit.boresight_screen()
		glass = cockpit.hud_glass_screen()
	var px_per_rad := (vp.y * 0.5) / tan(deg_to_rad(camera.fov * 0.5))
	var fwd := -fm.basis.z
	var pitch := asin(clampf(fwd.y, -1, 1))
	var heading := fposmod(rad_to_deg(atan2(fwd.x, -fwd.z)), 360.0)
	var roll := fm.basis.get_euler(EULER_ORDER_YXZ).z  # screen rotation opposite to bank

	# --- pitch ladder (rotated by roll about the boresight), clipped to the HUD glass ---
	var rot := Transform2D(roll, c)
	var clip := glass.grow(-4)
	for deg in range(-90, 91, 5):
		var y := -(deg_to_rad(deg) - pitch) * px_per_rad
		if absf(y) > glass.size.y:
			continue
		var w := glass.size.x * (0.2 if deg == 0 else 0.13)
		var gap := glass.size.x * 0.07
		var segs := []
		if deg == 0:
			segs = [[Vector2(-w * 2.2, y), Vector2(-gap, y)], [Vector2(gap, y), Vector2(w * 2.2, y)]]
		else:
			for side in [-1, 1]:
				var a := Vector2(side * gap, y)
				var b := Vector2(side * (gap + w), y)
				if deg < 0:  # dashed below the horizon
					for k in 4:
						segs.append([a.lerp(b, k / 4.0), a.lerp(b, k / 4.0 + 0.15)])
				else:
					segs.append([a, b])
				segs.append([b, b + Vector2(0, 10 if deg > 0 else -10)])
		for sg in segs:
			_clipped_line(rot * sg[0], rot * sg[1], clip)
		if deg % 10 == 0 and deg != 0:
			for lp in [Vector2(gap + w + 14, y), Vector2(-gap - w - 18, y)]:
				var q: Vector2 = rot * lp
				if clip.has_point(q):
					_txt(q + Vector2(-8, 5), str(absi(deg)), 14)

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
	var ty := glass.position.y + 16
	for k in range(-30, 31, 5):
		var hd := int(round(heading / 5.0)) * 5 + k
		var x := c.x + (hd - heading) * 9.0
		if absf(x - c.x) > glass.size.x * 0.3:
			continue
		draw_line(Vector2(x, ty), Vector2(x, ty + (12 if posmod(hd, 10) == 0 else 6)), COL, 2)
		if posmod(hd, 30) == 0:
			_txt(Vector2(x - 20, ty - 6), "%03d" % posmod(hd, 360), 14, COL, HORIZONTAL_ALIGNMENT_CENTER, 40)
	draw_line(Vector2(c.x, ty + 16), Vector2(c.x - 6, ty + 26), COL, 2)
	draw_line(Vector2(c.x, ty + 16), Vector2(c.x + 6, ty + 26), COL, 2)

	# --- speed (knots) and altitude (feet) boxes ---
	var box_y := c.y - 16
	var lx := glass.position.x + 4
	var rx := glass.end.x - 94
	_box(Vector2(lx, box_y), "%d" % (fm.airspeed * KT))
	_box(Vector2(rx, box_y), "%d" % (fm.position.y * FT))
	_txt(Vector2(lx, box_y - 10), "KTS", 13)
	_txt(Vector2(rx, box_y - 10), "ALT", 13)
	var climb := fm.velocity.y * FT * 60.0
	_txt(Vector2(rx, box_y + 52), "%+d FPM" % int(round(climb / 100.0) * 100), 13)
	_txt(Vector2(lx, box_y + 52), "M %.2f" % (fm.airspeed / 340.0), 13)

	# --- left column: G, AoA ---
	var ly := glass.end.y - 40
	_txt(Vector2(lx, ly), "G %.1f" % fm.load_factor, 16, WARN if fm.load_factor > fm.max_g * 0.95 else COL)
	_txt(Vector2(lx, ly + 22), "AOA %.0f" % rad_to_deg(fm.alpha), 16, WARN if fm.stalled else COL)

	# --- right column: throttle, fuel ---
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
	_txt(Vector2(c.x - 150, glass.end.y + 4), "  ".join(flags), 16, WARN if fm.stalled else COL, HORIZONTAL_ALIGNMENT_CENTER, 300)

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
	_txt(Vector2(16, 28), "[ ] or F1-F3: view   Arrows stick  , . rudder  +/- 1-0 throttle  Bksp AB  G gear  B brake  R/T restart", 13, Color(1, 1, 1, 0.7))
	if message != "":
		_txt(Vector2(0, vp.y * 0.5 - 120), message, 26, WARN, HORIZONTAL_ALIGNMENT_CENTER, vp.x)


## Draw the part of segment a-b inside `r` (Liang-Barsky clipping).
func _clipped_line(a: Vector2, b: Vector2, r: Rect2) -> void:
	var d := b - a
	var t0 := 0.0
	var t1 := 1.0
	for e in [[-d.x, a.x - r.position.x], [d.x, r.end.x - a.x], [-d.y, a.y - r.position.y], [d.y, r.end.y - a.y]]:
		var pp: float = e[0]
		var qq: float = e[1]
		if absf(pp) < 1e-6:
			if qq < 0.0:
				return
			continue
		var t := qq / pp
		if pp < 0.0:
			t0 = maxf(t0, t)
		else:
			t1 = minf(t1, t)
	if t0 < t1:
		draw_line(a + d * t0, a + d * t1, COL, 2)


func _draw_status(fm: FlightModel, vp: Vector2, y: float) -> void:
	var flags := []
	if fm.stalled: flags.append("STALL")
	if fm.gear_down: flags.append("GEAR")
	_txt(Vector2(0, y), "  ".join(flags), 16, WARN if fm.stalled else COL, HORIZONTAL_ALIGNMENT_CENTER, vp.x)
	if message != "":
		_txt(Vector2(0, vp.y * 0.3), message, 26, WARN, HORIZONTAL_ALIGNMENT_CENTER, vp.x)


func _box(p: Vector2, s: String) -> void:
	draw_rect(Rect2(p, Vector2(90, 32)), COL, false, 2)
	_txt(p + Vector2(0, 24), s, 20, COL, HORIZONTAL_ALIGNMENT_RIGHT, 82)
