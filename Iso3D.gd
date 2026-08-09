extends Node3D

## Isometric 3D rendering spike — "option C".
##
## This is a LOOK TEST, not a port. It answers one question: if the game as it
## exists today were rendered in 3D under an orthographic isometric camera,
## would it look better than the current top-down `_draw()`?
##
## What makes it a fair test rather than a mockup: it drives the real
## `AirportGrid` and its real `seed_starter_airport()` layout, and taxi routes
## come from the same `AStarGrid2D` pathfinding the game uses. Nothing here is
## hand-placed scenery. The palette is copied from `Main.gd`'s `_draw()` so the
## only variable being changed is the projection and the addition of height.
##
## Deliberately NOT here: economy, the aircraft state machine, HUD, build tools,
## save/load. `Main.gd` is untouched, and so is the main scene — run this scene
## directly (F6 in the editor, or `godot --path . res://Iso3D.tscn`).
##
## The seam this leans on: `AirportGrid.gd` contains no drawing code at all, so
## the entire simulation substrate is reusable under a different renderer. That
## is the finding that matters if this look test passes.

const AirportGrid = preload("res://AirportGrid.gd")
const PLANE_MODEL = preload("res://assets/models/widebody-airliner.glb")

# --- projection -------------------------------------------------------------

# 2D world coords map to 3D as (x, height, y): screen-down becomes ground-depth,
# so every existing Vector2 in the sim is usable with no conversion of the sim
# itself. Height is the one new axis, and it is the entire point of the spike.
func _w3(p: Vector2, y: float = 0.0) -> Vector3:
	return Vector3(p.x, y, p.y)


# True isometric, not the 2:1 "game isometric" cheat: atan(1/sqrt(2)) puts all
# three axes at equal screen angles. Worth using here precisely because it is
# the least flattering — if the look works at true iso it works at 30 too.
const ISO_PITCH_DEG := -35.264
const ISO_YAW_DEG := 45.0

# --- palette (copied from Main.gd _draw(), so only projection changes) -------

const COL_OUTSIDE := Color(0.227, 0.361, 0.227)
const COL_FIELD := Color(0.19, 0.31, 0.19)
const COL_TAXIWAY := Color(0.40, 0.40, 0.43)
const COL_TERMINAL := Color(0.36, 0.33, 0.45)
const COL_TERMINAL_EDGE := Color(0.62, 0.58, 0.78)
const COL_ROAD := Color(0.24, 0.24, 0.26)
const COL_PARKING := Color(0.30, 0.31, 0.33)
const COL_RUNWAY := Color(0.28, 0.28, 0.30)
const COL_GATE_FREE := Color(0.18, 0.42, 0.18)
const COL_GATE_BUSY := Color(0.75, 0.32, 0.25)
const COL_MARKING := Color(0.87, 0.87, 0.87)

# --- heights ----------------------------------------------------------------
#
# Coplanar surfaces z-fight, so every layer gets its own band rather than being
# nudged by epsilon. Values are in the same units as the 2D game (1 unit = 1px,
# TILE = 32), which keeps all the sim's existing numbers meaningful.

const H_PAVEMENT := 1.2
const H_GATE := 1.6
const H_MARKING := 2.0
const H_TERMINAL := 20.0
const H_KERB := 2.4

# --- aircraft scale ---------------------------------------------------------
#
# The model is 65.8 units nose-to-tail at real-world scale (a ~66m widebody).
# At FEET_PER_TILE = 600 that is 0.36 of a tile — about 11px, effectively
# invisible. `Main.gd` already draws a narrowbody 21px long, i.e. roughly 2.5x
# oversized, for exactly this reason.
#
# So this is a deliberate legibility lie in the same family as REVENUE_SCALE,
# and it is kept in ONE constant for the same reason: tune the number here, do
# not spread compensating tweaks through the render code.
const MODEL_LENGTH := 65.8
const PLANE_LENGTH_PX := 21.0

# 1.0 reproduces the current 2D game exactly. That turns out to read as too
# small once buildings have height to be dwarfed by — see `--fudge` to compare.
const PLANE_SCALE_FUDGE_DEFAULT := 2.0
var plane_scale_fudge := PLANE_SCALE_FUDGE_DEFAULT

# Per-class scale, matching Main.gd's CLASSES[]["scale"].
const CLASS_SCALE := {"R": 0.7, "N": 1.0, "W": 1.35}

# Stand-in airline liveries, to show that per-airline paint is a material
# override rather than an art pipeline — the model keeps `livery` as its own
# named material, separate from `shell`.
const LIVERIES := [
	Color(0.85, 0.24, 0.24),
	Color(0.16, 0.42, 0.78),
	Color(0.94, 0.72, 0.16),
	Color(0.20, 0.62, 0.42),
]

var grid
var _planes: Array = []
var _yaw_node: Node3D
var _pitch_node: Node3D
var _cam: Camera3D
var _yaw_deg := ISO_YAW_DEG
var _status: Label


func _ready() -> void:
	grid = AirportGrid.new()
	grid.seed_starter_airport()

	var cli := OS.get_cmdline_user_args()
	var fi := cli.find("--fudge")
	if fi != -1 and fi + 1 < cli.size():
		plane_scale_fudge = float(cli[fi + 1])

	_build_environment()
	_build_camera()
	_build_ground()
	_build_tiles()
	_build_runways()
	_build_gates()
	_build_hud()
	_spawn_planes()

	# `--shot <dir>` renders a few fixed views to PNG and exits, so the look can
	# be reviewed without a human driving the camera. Headless cannot do this —
	# the dummy renderer produces no image — so this needs a real window.
	var args := OS.get_cmdline_user_args()
	var i := args.find("--shot")
	if i != -1 and i + 1 < args.size():
		_run_shots(args[i + 1])


# --- world ------------------------------------------------------------------

func _build_environment() -> void:
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = COL_OUTSIDE
	# Flat ambient rather than a sky, so the comparison against the 2D view is
	# about form and shadow rather than a nicer background.
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.58, 0.65, 0.75)
	env.ambient_light_energy = 0.6

	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)

	# Angled across the grid rather than down the view axis, so buildings and
	# tails throw shadows that actually describe their shape.
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-52.0, -130.0, 0.0)
	sun.light_energy = 1.15
	sun.shadow_enabled = true
	sun.directional_shadow_max_distance = 3000.0
	add_child(sun)


# Frame what has actually been built, not the whole 32x18 grid — the starter
# airport occupies about a third of it, and framing the empty remainder wastes
# most of the screen.
func _built_bounds() -> Rect2:
	var r := Rect2()
	var first := true
	for cell in grid.tiles:
		var cr := Rect2(AirportGrid.ORIGIN + Vector2(cell) * AirportGrid.TILE,
			Vector2(AirportGrid.TILE, AirportGrid.TILE))
		if first:
			r = cr
			first = false
		else:
			r = r.merge(cr)
	return grid.grid_rect() if first else r.grow(AirportGrid.TILE)


func _field_centre() -> Vector3:
	var r := _built_bounds()
	return _w3(r.position + r.size * 0.5, 0.0)


# An iso-projected ground rect W x D spans (W+D)*cos(45) horizontally and that
# same span times sin(pitch) vertically. The ortho camera keeps height, so the
# horizontal requirement has to be divided back out by the aspect ratio.
func _fit_size(b: Rect2) -> float:
	var span: float = b.size.x + b.size.y
	var horiz: float = span * cos(deg_to_rad(45.0))
	var vert: float = horiz * sin(-deg_to_rad(ISO_PITCH_DEG))
	var vp: Vector2i = get_viewport().size
	var aspect: float = float(vp.x) / float(maxi(vp.y, 1))
	return maxf(vert, horiz / aspect) * 1.12


func _build_camera() -> void:
	# Nested yaw/pitch nodes rather than a single Euler triple: rotation order
	# on a combined Vector3 is easy to get subtly wrong, and orbiting is then
	# just "spin the yaw node".
	_yaw_node = Node3D.new()
	_yaw_node.position = _field_centre()
	add_child(_yaw_node)

	_pitch_node = Node3D.new()
	_yaw_node.add_child(_pitch_node)

	_cam = Camera3D.new()
	_cam.projection = Camera3D.PROJECTION_ORTHOGONAL
	_cam.size = _fit_size(_built_bounds())
	# Ortho has no perspective falloff, so distance only sets clipping — keep it
	# well clear of the field in every orbit position.
	_cam.position = Vector3(0.0, 0.0, 2000.0)
	_cam.near = 1.0
	_cam.far = 6000.0
	_pitch_node.add_child(_cam)

	_apply_camera_angles()


func _apply_camera_angles() -> void:
	_yaw_node.rotation_degrees = Vector3(0.0, _yaw_deg, 0.0)
	_pitch_node.rotation_degrees = Vector3(ISO_PITCH_DEG, 0.0, 0.0)


func _flat_material(c: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = c
	m.roughness = 0.92
	m.metallic = 0.0
	return m


func _slab(size: Vector3, centre: Vector3, mat: StandardMaterial3D, yaw: float = 0.0) -> MeshInstance3D:
	var box := BoxMesh.new()
	box.size = size
	var mi := MeshInstance3D.new()
	mi.mesh = box
	mi.material_override = mat
	mi.position = centre
	mi.rotation = Vector3(0.0, yaw, 0.0)
	add_child(mi)
	return mi


func _build_ground() -> void:
	var r: Rect2 = grid.grid_rect()

	# Apron/grass the airport sits on, plus a larger skirt so the field does not
	# end in mid-air at this camera angle.
	var skirt := _flat_material(COL_OUTSIDE)
	_slab(Vector3(r.size.x * 3.0, 2.0, r.size.y * 3.0), _w3(r.position + r.size * 0.5, -2.0), skirt)

	var field := _flat_material(COL_FIELD)
	_slab(Vector3(r.size.x, 2.0, r.size.y), _w3(r.position + r.size * 0.5, 0.0), field)


func _build_tiles() -> void:
	var mats := {
		AirportGrid.TileType.TAXIWAY: _flat_material(COL_TAXIWAY),
		AirportGrid.TileType.ROAD: _flat_material(COL_ROAD),
		AirportGrid.TileType.PARKING: _flat_material(COL_PARKING),
	}
	var term_mat := _flat_material(COL_TERMINAL)
	var kerb_mat := _flat_material(COL_TERMINAL_EDGE)
	var road_mark := _flat_material(Color(0.85, 0.8, 0.4))
	var bay_mark := _flat_material(Color(0.75, 0.75, 0.8))
	var t := AirportGrid.TILE

	for cell in grid.tiles:
		var type: int = grid.tile_type(cell)
		var centre: Vector2 = grid.cell_to_world(cell)

		match type:
			AirportGrid.TileType.TAXIWAY, AirportGrid.TileType.ROAD, AirportGrid.TileType.PARKING:
				_slab(Vector3(t, H_PAVEMENT, t), _w3(centre, H_PAVEMENT * 0.5), mats[type])

			AirportGrid.TileType.TERMINAL:
				# The whole reason to go isometric: a concourse stops being a
				# purple square and becomes a massed volume with a roofline.
				_slab(Vector3(t, H_TERMINAL, t), _w3(centre, H_TERMINAL * 0.5), term_mat)
				_slab(Vector3(t * 0.92, H_KERB, t * 0.92), _w3(centre, H_TERMINAL + H_KERB * 0.5), kerb_mat)

		# Surface markings, matching the cues the 2D view draws.
		if type == AirportGrid.TileType.ROAD:
			_slab(Vector3(2.0, 0.6, t * 0.34), _w3(centre, H_MARKING), road_mark)
		elif type == AirportGrid.TileType.PARKING:
			for i in 3:
				var off: float = t * ((float(i) + 0.5) / 3.0 - 0.5)
				_slab(Vector3(1.4, 0.6, t * 0.62), _w3(centre + Vector2(off, 0.0), H_MARKING), bay_mark)


func _build_runways() -> void:
	var pave := _flat_material(COL_RUNWAY)
	var mark := _flat_material(COL_MARKING)
	var t: float = AirportGrid.TILE

	for r in grid.runways:
		var a: Vector2 = r["a"]
		var b: Vector2 = r["b"]
		var axis: Vector2 = grid.runway_direction(r)
		# Overrun the ends by half a tile, exactly as _draw_runway does.
		var ea := a - axis * (t * 0.5)
		var eb := b + axis * (t * 0.5)
		var length: float = ea.distance_to(eb)
		var mid := (ea + eb) * 0.5

		# A free-angle runway is a rotated box here — no rasterization, no
		# eight-compass-point restriction. This is the single strongest argument
		# for 3D over isometric sprites, which would need one sprite per angle.
		var yaw := -axis.angle()
		_slab(Vector3(length, H_PAVEMENT, t * 0.84), _w3(mid, H_PAVEMENT * 0.5), pave, yaw)

		# Dashed centreline.
		var dashes := int(length / 24.0)
		for i in dashes:
			var f: float = (float(i) + 0.5) / float(maxi(dashes, 1))
			var p: Vector2 = ea.lerp(eb, f)
			_slab(Vector3(12.0, 0.6, 1.8), _w3(p, H_MARKING), mark, yaw)


func _build_gates() -> void:
	var free_mat := _flat_material(COL_GATE_FREE)
	var busy_mat := _flat_material(COL_GATE_BUSY)
	var t: float = AirportGrid.TILE

	for g in grid.gates:
		var cells: Array = g["cells"]
		var occupied: bool = g["occupied"]
		for c in cells:
			var centre: Vector2 = grid.cell_to_world(c)
			_slab(Vector3(t * 0.96, H_GATE, t * 0.96), _w3(centre, H_GATE * 0.5),
				busy_mat if occupied else free_mat)


# --- aircraft ---------------------------------------------------------------

func _collect_mesh_instances(n: Node, out: Array) -> void:
	if n is MeshInstance3D:
		out.append(n)
	for child in n.get_children():
		_collect_mesh_instances(child, out)


# The model keeps `livery` as a separate named material from `shell`, so an
# airline's colours are a per-instance override — no second mesh, no texture.
# Given the game already models airline relationships, that is a real payoff.
func _tint_livery(root: Node, color: Color) -> int:
	var found := 0
	var meshes: Array = []
	_collect_mesh_instances(root, meshes)
	for mi in meshes:
		var mesh: Mesh = mi.mesh
		if mesh == null:
			continue
		for s in mesh.get_surface_count():
			var m: Material = mesh.surface_get_material(s)
			if m == null or m.resource_name != "livery":
				continue
			# Duplicate first: the imported material is shared across every
			# instance of the model, so editing it in place repaints all of them.
			var dup: Material = m.duplicate()
			if dup is StandardMaterial3D:
				(dup as StandardMaterial3D).albedo_color = color
			mi.set_surface_override_material(s, dup)
			found += 1
	return found


func _make_plane(class_code: String, livery: Color) -> Node3D:
	var holder := Node3D.new()
	var model: Node3D = PLANE_MODEL.instantiate()

	var s: float = float(CLASS_SCALE.get(class_code, 1.0))
	var scale_factor: float = (PLANE_LENGTH_PX * s * plane_scale_fudge) / MODEL_LENGTH
	model.scale = Vector3.ONE * scale_factor
	_tint_livery(model, livery)

	holder.add_child(model)
	add_child(holder)
	return holder


# The model's nose points down -Z (confirmed from the mesh: the vertical
# stabiliser sits at +Z), which is already Godot's forward convention. A 2D
# heading h has forward (cos h, sin h), which in 3D is (cos h, 0, sin h);
# solving for the Y rotation that takes -Z there gives this.
func _yaw_for_heading(h: float) -> float:
	return -h - PI * 0.5


func _path_points(from: Vector2i, to: Vector2i) -> Array:
	var cells: Array = grid.find_path(from, to)
	var pts: Array = []
	for c in cells:
		pts.append(grid.cell_to_world(c))
	return pts


func _add_taxiing_plane(from: Vector2i, to: Vector2i, class_code: String, livery: Color, speed: float) -> void:
	var pts := _path_points(from, to)
	if pts.size() < 2:
		push_warning("Iso3D: no taxi path %s -> %s; skipping that aircraft." % [from, to])
		return
	_planes.append({
		"node": _make_plane(class_code, livery),
		"mode": "taxi",
		"points": pts,
		"t": 0.0,
		"speed": speed,
		"dir": 1.0,
	})


func _spawn_planes() -> void:
	_add_taxiing_plane(Vector2i(4, 10), Vector2i(16, 6), "W", LIVERIES[0], 26.0)
	_add_taxiing_plane(Vector2i(20, 8), Vector2i(10, 6), "N", LIVERIES[1], 30.0)
	_add_taxiing_plane(Vector2i(21, 10), Vector2i(8, 9), "R", LIVERIES[2], 34.0)

	# One parked at a stand, so the render shows an aircraft at rest against a
	# concourse — the shot that actually sells or kills an isometric look.
	if grid.gates.size() > 1:
		var g = grid.gates[1]
		var cell: Vector2i = g["cells"][0]
		var parked := _make_plane("N", LIVERIES[3])
		parked.position = _w3(grid.cell_to_world(cell), H_GATE)
		parked.rotation = Vector3(0.0, _yaw_for_heading(-PI * 0.5), 0.0)
		_planes.append({"node": parked, "mode": "parked"})

	# A takeoff roll down the free-angle runway, looping.
	if not grid.runways.is_empty():
		var r = grid.runways[0]
		_planes.append({
			"node": _make_plane("W", LIVERIES[1]),
			"mode": "takeoff",
			"a": r["a"],
			"b": r["b"],
			"t": 0.0,
		})


func _process(delta: float) -> void:
	for p in _planes:
		match p["mode"]:
			"taxi":
				_step_taxi(p, delta)
			"takeoff":
				_step_takeoff(p, delta)


func _step_taxi(p: Dictionary, delta: float) -> void:
	var pts: Array = p["points"]
	var total := float(pts.size() - 1)
	p["t"] = p["t"] + p["dir"] * p["speed"] * delta / AirportGrid.TILE
	# Shuttle back and forth rather than teleporting, so motion always reads as
	# an aircraft under its own power.
	if p["t"] >= total:
		p["t"] = total
		p["dir"] = -1.0
	elif p["t"] <= 0.0:
		p["t"] = 0.0
		p["dir"] = 1.0

	var i: int = clampi(int(floor(p["t"])), 0, pts.size() - 2)
	var f: float = clampf(p["t"] - float(i), 0.0, 1.0)
	var a: Vector2 = pts[i]
	var b: Vector2 = pts[i + 1]
	var pos: Vector2 = a.lerp(b, f)
	var dir: Vector2 = (b - a) * p["dir"]

	var node: Node3D = p["node"]
	node.position = _w3(pos, H_PAVEMENT)
	if dir.length() > 0.001:
		node.rotation = Vector3(0.0, _yaw_for_heading(dir.angle()), 0.0)


func _step_takeoff(p: Dictionary, delta: float) -> void:
	p["t"] = p["t"] + delta * 0.16
	if p["t"] > 1.6:
		p["t"] = 0.0

	var a: Vector2 = p["a"]
	var b: Vector2 = p["b"]
	var t: float = float(p["t"])
	var roll: float = minf(t, 1.0)
	# Ease in: an aircraft accelerating down the roll, not sliding at constant speed.
	var pos: Vector2 = a.lerp(b, roll * roll)
	var climb := 0.0
	if t > 1.0:
		var over: float = t - 1.0
		pos = b + (b - a).normalized() * (over * 420.0)
		climb = over * 260.0

	var node: Node3D = p["node"]
	node.position = _w3(pos, H_PAVEMENT + climb)
	node.rotation = Vector3(0.0, _yaw_for_heading((b - a).angle()), 0.0)
	# Rotate the nose up once airborne.
	if t > 1.0:
		node.rotation.z = deg_to_rad(9.0)
	else:
		node.rotation.z = 0.0


# --- offline capture --------------------------------------------------------

func _capture(path: String) -> void:
	# Two frames of settling, then wait for the draw to actually land — grabbing
	# the texture before frame_post_draw yields the previous frame or a blank.
	await get_tree().process_frame
	await get_tree().process_frame
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	img.save_png(path)
	print("wrote ", path)


func _run_shots(dir: String) -> void:
	# Let the taxiing aircraft get clear of their start cells first, so the
	# shots show traffic in motion rather than four planes sitting on origins.
	for i in 90:
		await get_tree().process_frame

	var tag: String = "f%.1f" % plane_scale_fudge
	_update_hud()
	await _capture("%s/iso_01_overview_%s.png" % [dir, tag])

	_yaw_deg = ISO_YAW_DEG + 90.0
	_apply_camera_angles()
	_update_hud()
	await _capture("%s/iso_02_yaw135_%s.png" % [dir, tag])

	# Close on the concourse row: buildings, contact stands, a parked aircraft.
	_yaw_deg = ISO_YAW_DEG
	_apply_camera_angles()
	_yaw_node.position = _w3(grid.cell_to_world(Vector2i(13, 7)), 0.0)
	_cam.size = 300.0
	_update_hud()
	await _capture("%s/iso_03_stands_%s.png" % [dir, tag])

	# Tight on the runway, to judge the free-angle strip and the model itself.
	_yaw_node.position = _w3(grid.cell_to_world(Vector2i(14, 11)), 0.0)
	_cam.size = 200.0
	_update_hud()
	await _capture("%s/iso_04_runway_%s.png" % [dir, tag])

	get_tree().quit()


# --- camera controls + HUD --------------------------------------------------

func _build_hud() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)
	_status = Label.new()
	_status.position = Vector2(12, 10)
	_status.add_theme_font_size_override("font_size", 13)
	layer.add_child(_status)
	_update_hud()


func _update_hud() -> void:
	_status.text = "ISO 3D SPIKE — starter airport, real AStar taxi routes\n" \
		+ "Q / E rotate · wheel zoom · R reset · Esc quit\n" \
		+ "yaw %d°  pitch %.1f°  ortho size %d  plane scale x%.1f" \
		% [int(_yaw_deg), ISO_PITCH_DEG, int(_cam.size), plane_scale_fudge]


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_WHEEL_UP:
			_cam.size = maxf(180.0, _cam.size - 60.0)
			_update_hud()
		elif mb.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_cam.size = minf(2200.0, _cam.size + 60.0)
			_update_hud()

	if event is InputEventKey and event.pressed and not event.echo:
		var key := (event as InputEventKey).keycode
		match key:
			KEY_Q:
				_yaw_deg += 45.0
				_apply_camera_angles()
				_update_hud()
			KEY_E:
				_yaw_deg -= 45.0
				_apply_camera_angles()
				_update_hud()
			KEY_R:
				_yaw_deg = ISO_YAW_DEG
				_yaw_node.position = _field_centre()
				_cam.size = _fit_size(_built_bounds())
				_apply_camera_angles()
				_update_hud()
			KEY_ESCAPE:
				get_tree().quit()
