extends Node3D

## Isometric 3D world renderer.
##
## Owns every piece of world geometry, the camera and the lighting. It knows
## nothing about money, airlines or aircraft states — `Main.gd` hands it plain
## render records and it draws them. That split is deliberate: the sim already
## had a clean seam (`AirportGrid.gd` contains no drawing at all), and keeping
## game rules out of here is what makes the renderer replaceable.
##
## Text is NOT drawn here. `Main._draw()` still renders every label in 2D screen
## space, positioned with `world_to_screen()`. Screen-space text stays crisp and
## upright at any camera angle, which billboarded `Label3D` does not.
##
## Rebuild policy: static geometry (tiles, runways, stands, concourses) is rebuilt
## only when the layout actually changes — `mark_layout_dirty()`. Per-frame work
## is limited to moving aircraft and recolouring stands, because stand occupancy
## changes constantly while the layout does not.

const AirportGrid = preload("res://AirportGrid.gd")
const PLANE_MODEL = preload("res://assets/models/widebody-airliner.glb")

# --- projection -------------------------------------------------------------

# 2D world coords map to 3D as (x, height, y): the sim's screen-down axis becomes
# ground-depth, so every existing Vector2 in the simulation is usable unchanged.
static func w3(p: Vector2, y: float = 0.0) -> Vector3:
	return Vector3(p.x, y, p.y)


const ISO_PITCH_DEG := -35.264
const ISO_YAW_DEG := 45.0

# --- palette (carried over from the old 2D _draw(), so the game still reads as
# itself — only the projection and the addition of height changed) ------------

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
const COL_GATE_ORPHAN := Color(0.45, 0.35, 0.15)
const COL_MARKING := Color(0.87, 0.87, 0.87)

# --- heights ----------------------------------------------------------------
# Coplanar surfaces z-fight, so each layer gets its own band rather than an
# epsilon nudge. Units match the 2D game exactly (1 unit = 1px, TILE = 32).

const H_PAVEMENT := 1.2
const H_GATE := 1.6
const H_MARKING := 2.0
const H_TERMINAL := 20.0
const H_KERB := 2.4
const H_GHOST := 3.0

# --- aircraft scale ---------------------------------------------------------
#
# The model is 65.8 units nose-to-tail at real-world scale. At FEET_PER_TILE=600
# that is 0.36 of a tile, effectively invisible, so aircraft are drawn oversized
# exactly as the old 2D renderer did (a 21px narrowbody against a 32px tile).
#
# This is a legibility lie in the same family as REVENUE_SCALE, and it lives in
# ONE constant for the same reason — tune it here, do not spread compensating
# tweaks through the renderer.
const MODEL_LENGTH := 65.8
const PLANE_LENGTH_PX := 21.0

const PLANE_SCALE_FUDGE := 2.0

# Airside/landside width hierarchy: runway > taxiway > road. Real proportions
# are roughly 45m / 23m / 7m, and a full-tile road read as wide as a taxiway,
# which made the landside look like more apron. A taxiway is locked to exactly
# one tile by the grid, so it is the fixed middle of the ratio and the other two
# move around it.
const RUNWAY_WIDTH_TILES := 1.2
const ROAD_WIDTH_TILES := 0.34

var grid

var _cam: Camera3D
var _yaw_node: Node3D
var _pitch_node: Node3D
var _static_root: Node3D
var _plane_root: Node3D
var _ghost_root: Node3D

var _plane_nodes := {}
var _gate_nodes := {}
var _mats := {}
var _livery_cache := {}

var _yaw_deg := ISO_YAW_DEG
var _pan := Vector2.ZERO
var _zoom := 1.0
var _layout_dirty := true
var _ghost_sig := ""
var _panning := false
var _orbiting := false
var _hint: Label


func _ready() -> void:
	_build_environment()
	_build_camera()
	_static_root = Node3D.new()
	add_child(_static_root)
	_plane_root = Node3D.new()
	add_child(_plane_root)
	_ghost_root = Node3D.new()
	add_child(_ghost_root)
	_build_hint()


# Camera controls are invisible otherwise — there is nothing on screen to
# suggest the view can move at all. Sits just above the build toolbar.
func _build_hint() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)
	_hint = Label.new()
	_hint.position = Vector2(12, 648)
	_hint.add_theme_font_size_override("font_size", 12)
	_hint.add_theme_color_override("font_color", Color(1, 1, 1, 0.5))
	_hint.text = "CAMERA — middle-drag pan · right-drag rotate · wheel zoom · arrows pan · , . rotate 45° · Home reset"
	layer.add_child(_hint)


func attach(g) -> void:
	grid = g
	# The camera is built before the grid exists, so its pivot was placed at the
	# world origin. Re-apply now that there is a field to centre on.
	_apply_camera()
	mark_layout_dirty()


func mark_layout_dirty() -> void:
	_layout_dirty = true


# --- materials --------------------------------------------------------------

func _mat(key: String, c: Color, transparent: bool = false) -> StandardMaterial3D:
	if _mats.has(key):
		return _mats[key]
	var m := StandardMaterial3D.new()
	m.albedo_color = c
	m.roughness = 0.92
	m.metallic = 0.0
	if transparent:
		m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_mats[key] = m
	return m


func _slab(parent: Node3D, size: Vector3, centre: Vector3, mat: Material, yaw: float = 0.0) -> MeshInstance3D:
	var box := BoxMesh.new()
	box.size = size
	var mi := MeshInstance3D.new()
	mi.mesh = box
	mi.material_override = mat
	mi.position = centre
	mi.rotation = Vector3(0.0, yaw, 0.0)
	parent.add_child(mi)
	return mi


# --- camera + lighting ------------------------------------------------------

func _build_environment() -> void:
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = COL_OUTSIDE
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.58, 0.65, 0.75)
	env.ambient_light_energy = 0.6

	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)

	# Angled across the field rather than down the view axis, so concourses and
	# tails throw shadows that describe their shape instead of hiding behind them.
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-52.0, -130.0, 0.0)
	sun.light_energy = 1.15
	sun.shadow_enabled = true
	sun.directional_shadow_max_distance = 4000.0
	add_child(sun)


func _build_camera() -> void:
	# Nested yaw/pitch nodes rather than one Euler triple: rotation order on a
	# combined Vector3 is easy to get subtly wrong, and orbiting then reduces to
	# "spin the yaw node".
	_yaw_node = Node3D.new()
	add_child(_yaw_node)
	_pitch_node = Node3D.new()
	_yaw_node.add_child(_pitch_node)

	_cam = Camera3D.new()
	_cam.projection = Camera3D.PROJECTION_ORTHOGONAL
	# Ortho has no perspective falloff, so distance only affects clipping — keep
	# it well clear of the field from every orbit position.
	_cam.position = Vector3(0.0, 0.0, 2500.0)
	_cam.near = 1.0
	_cam.far = 8000.0
	_pitch_node.add_child(_cam)

	_apply_camera()


# The HUD sidebar and the bottom toolbar sit on top of the 3D view, so the
# usable window is smaller than the viewport. Framing against the full viewport
# buries a third of the airport under the UI.
const UI_MARGIN_RIGHT := 416.0
const UI_MARGIN_BOTTOM := 232.0
const UI_MARGIN_TOP := 96.0


func _visible_rect() -> Rect2:
	var vp: Vector2i = get_viewport().size
	return Rect2(0.0, UI_MARGIN_TOP,
		float(vp.x) - UI_MARGIN_RIGHT, float(vp.y) - UI_MARGIN_BOTTOM - UI_MARGIN_TOP)


func _default_size() -> float:
	if grid == null:
		return 700.0
	var b: Rect2 = grid.grid_rect()
	# An iso-projected W x D rect spans (W+D)*cos45 horizontally and that same
	# span times sin(pitch) vertically.
	var span: float = b.size.x + b.size.y
	var horiz: float = span * cos(deg_to_rad(45.0))
	var vert: float = horiz * sin(-deg_to_rad(ISO_PITCH_DEG))

	# Solve for world-units-per-pixel that fits both axes inside the un-obscured
	# area, then scale back up to the full viewport height, which is what
	# Camera3D.size actually measures.
	var vis := _visible_rect()
	var vp: Vector2i = get_viewport().size
	var k: float = maxf(horiz / maxf(vis.size.x, 1.0), vert / maxf(vis.size.y, 1.0))
	return k * float(vp.y) * 1.06


func _apply_camera() -> void:
	var centre := Vector2.ZERO
	if grid != null:
		var b: Rect2 = grid.grid_rect()
		centre = b.position + b.size * 0.5
	_yaw_node.position = w3(centre + _pan, 0.0)
	_yaw_node.rotation_degrees = Vector3(0.0, _yaw_deg, 0.0)
	_pitch_node.rotation_degrees = Vector3(ISO_PITCH_DEG, 0.0, 0.0)
	_cam.size = _default_size() * _zoom

	# Shift the frustum so the field centres in the un-obscured area rather than
	# behind the sidebar. h_offset moves the camera, so the image moves opposite.
	var vp: Vector2i = get_viewport().size
	var vis := _visible_rect()
	var k: float = _cam.size / float(maxi(vp.y, 1))
	var d: Vector2 = vis.position + vis.size * 0.5 - Vector2(vp) * 0.5
	_cam.h_offset = -d.x * k
	_cam.v_offset = d.y * k


func reset_camera() -> void:
	_yaw_deg = ISO_YAW_DEG
	_pan = Vector2.ZERO
	_zoom = 1.0
	_apply_camera()


# --- picking / projection ---------------------------------------------------

# Screen point to a position on the airport's ground plane. This replaces the
# old renderer's direct use of the mouse position: under a 2D top-down view
# screen space *was* world space, which is exactly the assumption 3D breaks.
func screen_to_world(screen_pos: Vector2) -> Vector2:
	if _cam == null:
		return Vector2.ZERO
	var from: Vector3 = _cam.project_ray_origin(screen_pos)
	var dir: Vector3 = _cam.project_ray_normal(screen_pos)
	# Intersect the pavement plane rather than y=0, so the cursor lines up with
	# the surfaces the player is actually aiming at.
	if absf(dir.y) < 0.00001:
		return Vector2.ZERO
	var t: float = (H_PAVEMENT - from.y) / dir.y
	var hit: Vector3 = from + dir * t
	return Vector2(hit.x, hit.z)


func world_to_screen(w: Vector2, height: float = 0.0) -> Vector2:
	if _cam == null:
		return Vector2.ZERO
	return _cam.unproject_position(w3(w, height))


# --- static geometry --------------------------------------------------------

func rebuild_if_dirty() -> void:
	if not _layout_dirty or grid == null:
		return
	_layout_dirty = false
	_rebuild_static()


func _rebuild_static() -> void:
	for c in _static_root.get_children():
		c.queue_free()
	_gate_nodes.clear()

	_build_ground()
	_build_tiles()
	_build_terminals()
	_build_runways()
	_build_gates()


func _build_ground() -> void:
	var r: Rect2 = grid.grid_rect()
	# A skirt well beyond the buildable area, so the field does not simply end in
	# mid-air at this camera angle.
	_slab(_static_root, Vector3(r.size.x * 4.0, 2.0, r.size.y * 4.0),
		w3(r.position + r.size * 0.5, -2.0), _mat("skirt", COL_OUTSIDE))
	_slab(_static_root, Vector3(r.size.x, 2.0, r.size.y),
		w3(r.position + r.size * 0.5, 0.0), _mat("field", COL_FIELD))


func _build_tiles() -> void:
	var t: float = AirportGrid.TILE
	for cell in grid.tiles:
		var type: int = grid.tile_type(cell)
		var centre: Vector2 = grid.cell_to_world(cell)

		match type:
			AirportGrid.TileType.TAXIWAY:
				_slab(_static_root, Vector3(t, H_PAVEMENT, t), w3(centre, H_PAVEMENT * 0.5),
					_mat("taxi", COL_TAXIWAY))
			AirportGrid.TileType.ROAD:
				_build_road_tile(cell, centre)
			AirportGrid.TileType.PARKING:
				_slab(_static_root, Vector3(t, H_PAVEMENT, t), w3(centre, H_PAVEMENT * 0.5),
					_mat("park", COL_PARKING))
				for i in 3:
					var off: float = t * ((float(i) + 0.5) / 3.0 - 0.5)
					_slab(_static_root, Vector3(1.4, 0.6, t * 0.62),
						w3(centre + Vector2(off, 0.0), H_MARKING),
						_mat("baymark", Color(0.75, 0.75, 0.8)))
			AirportGrid.TileType.TERMINAL:
				pass  # Merged into runs below, so a concourse reads as one building.


# A road is a narrow ribbon rather than a full tile of tarmac, so landside stops
# reading as more apron. Because it is that much narrower than its own tile, it
# has to be built as a junction patch plus an arm toward each neighbour — a
# single centred quad would leave gaps at every corner and T-junction.
func _build_road_tile(cell: Vector2i, centre: Vector2) -> void:
	var t: float = AirportGrid.TILE
	var w: float = t * ROAD_WIDTH_TILES
	var mat := _mat("road", COL_ROAD)
	var mark := _mat("roadmark", Color(0.85, 0.8, 0.4))

	_slab(_static_root, Vector3(w, H_PAVEMENT, w), w3(centre, H_PAVEMENT * 0.5), mat)

	for d in [Vector2i.LEFT, Vector2i.RIGHT, Vector2i.UP, Vector2i.DOWN]:
		var n: Vector2i = cell + d
		var connects: bool = grid.tile_type(n) == AirportGrid.TileType.ROAD
		# Run out to the map edge as well: that is the airport entrance, and
		# stopping half a tile short would leave it hanging in the grass.
		if not connects and not grid.in_bounds(n):
			connects = true
		if not connects:
			continue

		var v := Vector2(d)
		var arm: Vector2 = centre + v * (t * 0.25)
		var size := Vector3(w, H_PAVEMENT, t * 0.5)
		if absf(v.x) > 0.0:
			size = Vector3(t * 0.5, H_PAVEMENT, w)
		_slab(_static_root, size, w3(arm, H_PAVEMENT * 0.5), mat)

		var dash := Vector3(w * 0.34, 0.6, 1.6) if absf(v.x) > 0.0 else Vector3(1.6, 0.6, w * 0.34)
		_slab(_static_root, dash, w3(centre + v * (t * 0.3), H_MARKING), mark)


# A concourse is one building, not a row of huts. Adjacent TERMINAL tiles are
# merged into horizontal runs and emitted as a single box, and the roof spans the
# full run at full tile width so neighbouring rows fuse into one mass instead of
# showing a seam between per-tile caps.
func _build_terminals() -> void:
	var cells: Array = []
	for c in grid.tiles:
		if grid.tile_type(c) == AirportGrid.TileType.TERMINAL:
			cells.append(c)
	if cells.is_empty():
		return

	cells.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
		if a.y != b.y:
			return a.y < b.y
		return a.x < b.x)

	var t: float = AirportGrid.TILE
	var i := 0
	while i < cells.size():
		var start: Vector2i = cells[i]
		var run := 1
		while i + run < cells.size() \
				and cells[i + run].y == start.y \
				and cells[i + run].x == start.x + run:
			run += 1

		var centre: Vector2 = grid.cell_to_world(start) + Vector2((float(run) - 1.0) * t * 0.5, 0.0)
		var width: float = float(run) * t
		_slab(_static_root, Vector3(width, H_TERMINAL, t), w3(centre, H_TERMINAL * 0.5),
			_mat("term", COL_TERMINAL))
		_slab(_static_root, Vector3(width, H_KERB, t), w3(centre, H_TERMINAL + H_KERB * 0.5),
			_mat("termedge", COL_TERMINAL_EDGE))
		i += run


func _build_runways() -> void:
	var t: float = AirportGrid.TILE
	for r in grid.runways:
		var a: Vector2 = r["a"]
		var b: Vector2 = r["b"]
		var axis: Vector2 = grid.runway_direction(r)
		# Overrun the ends by half a tile, matching the old renderer.
		var ea := a - axis * (t * 0.5)
		var eb := b + axis * (t * 0.5)
		var length: float = ea.distance_to(eb)
		# A free-angle runway is simply a rotated box here. No rasterization and
		# no eight-compass-point restriction — the reason 3D suits this game
		# better than isometric sprites, which need one sprite per heading.
		var yaw := -axis.angle()
		_slab(_static_root, Vector3(length, H_PAVEMENT, t * RUNWAY_WIDTH_TILES),
			w3((ea + eb) * 0.5, H_PAVEMENT * 0.5), _mat("rwy", COL_RUNWAY), yaw)

		var usable: bool = grid.runway_is_usable(r)
		var mark := _mat("rwymark", COL_MARKING) if usable else _mat("rwybad", Color(1.0, 0.35, 0.35))
		var dashes := maxi(int(length / 24.0), 1)
		for i in dashes:
			var f: float = (float(i) + 0.5) / float(dashes)
			_slab(_static_root, Vector3(12.0, 0.6, 1.8), w3(ea.lerp(eb, f), H_MARKING), mark, yaw)


func _build_gates() -> void:
	var t: float = AirportGrid.TILE
	for g in grid.gates:
		var nodes: Array = []
		for c in g["cells"]:
			nodes.append(_slab(_static_root, Vector3(t * 0.96, H_GATE, t * 0.96),
				w3(grid.cell_to_world(c), H_GATE * 0.5), _mat("gatefree", COL_GATE_FREE)))
		_gate_nodes[g["id"]] = nodes


# Stand occupancy flips constantly while the layout does not, so colour is
# refreshed per frame rather than triggering a full static rebuild.
func sync_gates() -> void:
	if grid == null:
		return
	for g in grid.gates:
		if not _gate_nodes.has(g["id"]):
			continue
		var mat: Material
		if not grid.gate_is_connected(g):
			mat = _mat("gateorphan", COL_GATE_ORPHAN)
		elif g["occupied"]:
			mat = _mat("gatebusy", COL_GATE_BUSY)
		else:
			mat = _mat("gatefree", COL_GATE_FREE)
		for mi in _gate_nodes[g["id"]]:
			(mi as MeshInstance3D).material_override = mat


# --- aircraft ---------------------------------------------------------------

func _collect_mesh_instances(n: Node, out: Array) -> void:
	if n is MeshInstance3D:
		out.append(n)
	for child in n.get_children():
		_collect_mesh_instances(child, out)


# The model keeps `livery` as its own named material, separate from `shell`, so
# an airline's colours are a per-instance override rather than a second mesh.
func _tint_livery(root: Node, color: Color) -> void:
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
			# Duplicate first: the imported material is shared by every instance
			# of the model, so editing in place repaints the whole fleet.
			var dup: Material = m.duplicate()
			if dup is StandardMaterial3D:
				(dup as StandardMaterial3D).albedo_color = color
			mi.set_surface_override_material(s, dup)


func _livery_for(airline: String) -> Color:
	if _livery_cache.has(airline):
		return _livery_cache[airline]
	# Deterministic per-airline hue, so a carrier keeps its colours across a run
	# without needing an art table.
	var h: float = float(abs(airline.hash()) % 360) / 360.0
	var c := Color.from_hsv(h, 0.62, 0.72)
	_livery_cache[airline] = c
	return c


# The model's nose points down -Z (its vertical stabiliser sits at +Z), which is
# already Godot's forward convention. A 2D heading h has forward (cos h, sin h),
# which maps to 3D (cos h, 0, sin h); solving for the Y rotation that takes -Z
# there gives this.
static func yaw_for_heading(h: float) -> float:
	return -h - PI * 0.5


func _make_plane(class_code: String, airline: String) -> Dictionary:
	var container := Node3D.new()
	_plane_root.add_child(container)

	# Ground ring stays on the pavement even when the aircraft is airborne, so it
	# doubles as a position marker for anything in the air.
	var ring_mesh := TorusMesh.new()
	ring_mesh.inner_radius = 11.0
	ring_mesh.outer_radius = 14.0
	var ring := MeshInstance3D.new()
	ring.mesh = ring_mesh
	ring.position = Vector3(0.0, H_MARKING, 0.0)
	container.add_child(ring)

	var holder := Node3D.new()
	container.add_child(holder)

	var model: Node3D = PLANE_MODEL.instantiate()
	var s: float = 1.0
	match class_code:
		"R":
			s = 0.7
		"W":
			s = 1.35
	model.scale = Vector3.ONE * ((PLANE_LENGTH_PX * s * PLANE_SCALE_FUDGE) / MODEL_LENGTH)
	_tint_livery(model, _livery_for(airline))
	holder.add_child(model)

	return {"container": container, "holder": holder, "ring": ring}


## `records` is an array of plain dictionaries, one per aircraft:
##   id, pos (Vector2), heading (float), altitude (float),
##   class_code (String), airline (String), status (Color)
func sync_planes(records: Array) -> void:
	var seen := {}
	for rec in records:
		var id: int = rec["id"]
		seen[id] = true
		if not _plane_nodes.has(id):
			_plane_nodes[id] = _make_plane(rec["class_code"], rec["airline"])
		var n: Dictionary = _plane_nodes[id]

		var container: Node3D = n["container"]
		var holder: Node3D = n["holder"]
		var ring: MeshInstance3D = n["ring"]

		container.position = w3(rec["pos"], 0.0)
		holder.position = Vector3(0.0, H_PAVEMENT + float(rec["altitude"]), 0.0)
		holder.rotation = Vector3(0.0, yaw_for_heading(rec["heading"]), 0.0)

		var status: Color = rec["status"]
		ring.material_override = _mat("ring_" + status.to_html(false), status, true)
		# Airborne aircraft get a pitch-up attitude, which is most of what sells
		# a climb-out at this camera angle.
		holder.rotation.z = deg_to_rad(9.0) if float(rec["altitude"]) > 6.0 else 0.0

	for id in _plane_nodes.keys():
		if seen.has(id):
			continue
		(_plane_nodes[id]["container"] as Node3D).queue_free()
		_plane_nodes.erase(id)


# --- build ghost ------------------------------------------------------------

func clear_ghost() -> void:
	if _ghost_sig == "":
		return
	_ghost_sig = ""
	for c in _ghost_root.get_children():
		c.queue_free()


func set_ghost_cells(cells: Array, color: Color) -> void:
	var sig := "c%s%s" % [color.to_html(false), cells]
	if sig == _ghost_sig:
		return
	_ghost_sig = sig
	for c in _ghost_root.get_children():
		c.queue_free()
	var t: float = AirportGrid.TILE
	var mat := _mat("ghost_" + color.to_html(true), color, true)
	for cell in cells:
		if not grid.in_bounds(cell):
			continue
		_slab(_ghost_root, Vector3(t, H_GHOST, t), w3(grid.cell_to_world(cell), H_GHOST * 0.5), mat)


func set_ghost_runway(a: Vector2, b: Vector2, color: Color) -> void:
	var sig := "r%s%s%s" % [color.to_html(false), a, b]
	if sig == _ghost_sig:
		return
	_ghost_sig = sig
	for c in _ghost_root.get_children():
		c.queue_free()

	var t: float = AirportGrid.TILE
	var axis := b - a
	if axis.length() < 0.001:
		axis = Vector2.RIGHT
	axis = axis.normalized()
	var ea := a - axis * (t * 0.5)
	var eb := b + axis * (t * 0.5)
	_slab(_ghost_root, Vector3(ea.distance_to(eb), H_GHOST, t * 0.84),
		w3((ea + eb) * 0.5, H_GHOST * 0.5), _mat("ghost_" + color.to_html(true), color, true),
		-axis.angle())


# --- camera controls --------------------------------------------------------
#
# Mouse-first, because obscure keys are undiscoverable: drag with the middle or
# right button, wheel to zoom. The keyboard fallbacks are deliberately on keys
# the build tools do not already claim — Main.gd binds T/R/G/H/E/O/P/X to tools
# and 1/2/3, A, D, Space to the sim, so Q/E and WASD are all unavailable.

const ARROW_PAN_PX := 90.0
const ORBIT_SENSITIVITY := 0.35


# Panning is done by measuring how far the ground moved under the cursor and
# undoing exactly that. It needs no trigonometry and stays correct at any yaw,
# pitch or zoom — the hand-rolled version this replaces was none of those.
func _pan_by_screen(delta_px: Vector2) -> void:
	var before := screen_to_world(Vector2.ZERO)
	var after := screen_to_world(delta_px)
	_pan += after - before
	_apply_camera()


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		match mb.button_index:
			MOUSE_BUTTON_WHEEL_UP:
				if mb.pressed:
					_zoom = maxf(0.25, _zoom - 0.08)
					_apply_camera()
			MOUSE_BUTTON_WHEEL_DOWN:
				if mb.pressed:
					_zoom = minf(2.5, _zoom + 0.08)
					_apply_camera()
			MOUSE_BUTTON_MIDDLE:
				_panning = mb.pressed
			MOUSE_BUTTON_RIGHT:
				_orbiting = mb.pressed
				# Snap back to a clean isometric angle on release: free rotation
				# feels good to drag but only the 45s actually look isometric.
				if not mb.pressed:
					_yaw_deg = roundf(_yaw_deg / 45.0) * 45.0
					_apply_camera()

	elif event is InputEventMouseMotion:
		var mm := event as InputEventMouseMotion
		if _panning:
			var before := screen_to_world(mm.position - mm.relative)
			var after := screen_to_world(mm.position)
			_pan -= after - before
			_apply_camera()
		elif _orbiting:
			_yaw_deg += mm.relative.x * ORBIT_SENSITIVITY
			_apply_camera()

	elif event is InputEventKey and event.pressed:
		match (event as InputEventKey).keycode:
			KEY_BRACKETLEFT, KEY_COMMA:
				_yaw_deg += 45.0
				_apply_camera()
			KEY_BRACKETRIGHT, KEY_PERIOD:
				_yaw_deg -= 45.0
				_apply_camera()
			KEY_HOME:
				reset_camera()
			KEY_LEFT:
				_pan_by_screen(Vector2(-ARROW_PAN_PX, 0.0))
			KEY_RIGHT:
				_pan_by_screen(Vector2(ARROW_PAN_PX, 0.0))
			KEY_UP:
				_pan_by_screen(Vector2(0.0, -ARROW_PAN_PX))
			KEY_DOWN:
				_pan_by_screen(Vector2(0.0, ARROW_PAN_PX))
