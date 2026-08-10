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

# Ground colours are per-region now (see Regions.TERRAIN); these are the fallback
# used before a region has been chosen, and match the original temperate look.
const COL_OUTSIDE := Color(0.227, 0.361, 0.227)
const COL_FIELD := Color(0.19, 0.31, 0.19)
const COL_TAXIWAY := Color(0.40, 0.40, 0.43)
const COL_TERMINAL := Color(0.36, 0.33, 0.45)
const COL_TERMINAL_EDGE := Color(0.62, 0.58, 0.78)
const COL_ROAD := Color(0.24, 0.24, 0.26)
const COL_PARKING := Color(0.30, 0.31, 0.33)
const COL_RUNWAY := Color(0.28, 0.28, 0.30)
const COL_STAND_FREE := Color(0.18, 0.42, 0.18)
const COL_STAND_BUSY := Color(0.75, 0.32, 0.25)
const COL_STAND_ORPHAN := Color(0.45, 0.35, 0.15)
const COL_MARKING := Color(0.87, 0.87, 0.87)

# --- heights ----------------------------------------------------------------
# Coplanar surfaces z-fight, so each layer gets its own band rather than an
# epsilon nudge. Units match the 2D game exactly (1 unit = 1px, TILE = 32).

const H_PAVEMENT := 1.2
const H_STAND := 1.6
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

# Shared with Main's help overlay so the two listings cannot drift apart.
const CAMERA_HINT := "middle-drag pan · right-drag rotate · wheel zoom · arrows pan · , . rotate 45° · Home reset"

var grid

var _cam: Camera3D
var _yaw_node: Node3D
var _pitch_node: Node3D
var _static_root: Node3D
var _plane_root: Node3D
var _ghost_root: Node3D

var _plane_nodes := {}
var _stand_nodes := {}
var _mats := {}
var _livery_cache := {}

var _terrain: Dictionary = {}
var _weather_kind := ""
var _weather: CPUParticles3D

var _ground_root: Node3D
var _scenery_root: Node3D
var _tiles_root: Node3D
var _terminal_root: Node3D
var _runway_root: Node3D
var _stand_root: Node3D

var _scenery_built := false
var _ground_mask := -1

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
	# One root per rebuild tier, so a layout change never touches scenery.
	for holder in ["_ground_root", "_scenery_root", "_tiles_root", "_terminal_root",
			"_runway_root", "_stand_root"]:
		var n := Node3D.new()
		_static_root.add_child(n)
		set(holder, n)
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
	_hint.text = "CAMERA — " + CAMERA_HINT
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


# One shared unit cube, scaled per instance, rather than a fresh BoxMesh per
# call. A full rebuild made on the order of a thousand of those, and pushing that
# many new vertex buffers to the server cost more than the node churn did.
#
# Node3D applies scale before rotation, so scaling a unit box reproduces the old
# `box.size = size` transform exactly. Box normals stay axis-aligned under
# axis-aligned scale, so shading is unchanged too.
var _unit_box: BoxMesh


func _slab(parent: Node3D, size: Vector3, centre: Vector3, mat: Material, yaw: float = 0.0) -> MeshInstance3D:
	if _unit_box == null:
		_unit_box = BoxMesh.new()
		_unit_box.size = Vector3.ONE
	var mi := MeshInstance3D.new()
	mi.mesh = _unit_box
	mi.material_override = mat
	mi.position = centre
	mi.scale = size
	mi.rotation = Vector3(0.0, yaw, 0.0)
	parent.add_child(mi)
	return mi


# --- camera + lighting ------------------------------------------------------

# --- batching ---------------------------------------------------------------
#
# Per-tile geometry is accumulated by (mesh, material) and flushed into one
# MultiMeshInstance3D per group. Accumulate-then-flush keeps the fill a single
# tight pass with no capacity juggling inside the build loops.

var _batches := {}
var _unit_cone: CylinderMesh
var _unit_cyl: CylinderMesh
var _unit_sphere: SphereMesh


func _mesh_for(shape: String) -> Mesh:
	match shape:
		"cone":
			if _unit_cone == null:
				_unit_cone = CylinderMesh.new()
				_unit_cone.top_radius = 0.0
				_unit_cone.bottom_radius = 0.5
				_unit_cone.height = 1.0
				# Must match the old _cone() silhouette exactly.
				_unit_cone.radial_segments = 7
			return _unit_cone
		"cyl":
			if _unit_cyl == null:
				_unit_cyl = CylinderMesh.new()
				_unit_cyl.top_radius = 0.5
				_unit_cyl.bottom_radius = 0.5
				_unit_cyl.height = 1.0
				_unit_cyl.radial_segments = 6
			return _unit_cyl
		"sphere":
			if _unit_sphere == null:
				_unit_sphere = SphereMesh.new()
				_unit_sphere.radius = 0.5
				_unit_sphere.height = 1.0
			return _unit_sphere
	if _unit_box == null:
		_unit_box = BoxMesh.new()
		_unit_box.size = Vector3.ONE
	return _unit_box


# Basis must be rotation * scale (local axes). Basis.scaled() post-multiplies,
# which scales along GLOBAL axes and silently skews every rotated runway into
# something that still looks plausible.
func _add(key: String, shape: String, mat: Material, size: Vector3, centre: Vector3,
		yaw: float = 0.0) -> void:
	var b := Basis(Vector3.UP, yaw) * Basis.from_scale(size)
	if not _batches.has(key):
		_batches[key] = {"shape": shape, "mat": mat, "x": []}
	(_batches[key]["x"] as Array).append(Transform3D(b, centre))


func _flush_batches(root: Node3D) -> void:
	for key in _batches:
		var b: Dictionary = _batches[key]
		var xforms: Array = b["x"]
		if xforms.is_empty():
			continue
		var mm := MultiMesh.new()
		# Format flags must be set BEFORE instance_count — changing either
		# afterwards wipes the buffer.
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.mesh = _mesh_for(b["shape"])
		mm.instance_count = xforms.size()
		for i in xforms.size():
			mm.set_instance_transform(i, xforms[i])
		var mmi := MultiMeshInstance3D.new()
		mmi.multimesh = mm
		mmi.material_override = b["mat"]
		# Without an explicit AABB the server recomputes bounds across every
		# instance each time the buffer changes — the exact O(n) cost being
		# removed here.
		var g: Rect2 = grid.grid_rect()
		mmi.custom_aabb = AABB(
			Vector3(g.position.x - 2000.0, -400.0, g.position.y - 2000.0),
			Vector3(g.size.x + 4000.0, 900.0, g.size.y + 4000.0))
		root.add_child(mmi)
	_batches.clear()


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
	# Owned land, not the whole grid: otherwise the game opens zoomed out over
	# tracts the player does not own yet.
	var b: Rect2 = grid.owned_rect()
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
		var b: Rect2 = grid.owned_rect()
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

# Rebuilds are split by how expensive a category is to regenerate, not by who
# changed it. The public API stays `mark_layout_dirty()` with no arguments on
# purpose: the caller cannot know which categories it invalidated. Painting a
# taxiway three tiles from a runway flips that runway's centreline from red to
# white via runway_is_usable(), so any caller-supplied category would be wrong.
func rebuild_if_dirty() -> void:
	if grid == null:
		return

	# Session-static: scenery only changes when the region does.
	if not _scenery_built:
		_scenery_built = true
		_rebuild_scenery()

	# Rarely dirty: ground follows land ownership, and so does the framing.
	var mask := _owned_mask()
	if mask != _ground_mask:
		_ground_mask = mask
		_rebuild_ground()
		_apply_camera()

	if not _layout_dirty:
		return
	_layout_dirty = false
	_rebuild_layout()


# Exact and cheap — tracts are only ever added by buy_tract() or replaced
# wholesale by from_dict(), and a bitmask catches both without hashing.
func _owned_mask() -> int:
	var m := 0
	for i in grid.owned_tracts:
		m |= 1 << int(i)
	return m


func _clear(root: Node3D) -> void:
	# free(), not queue_free(): the frees would otherwise be deferred to end of
	# frame while sync_stands() runs against _stand_nodes in this same frame.
	for c in root.get_children():
		root.remove_child(c)
		c.free()


func _rebuild_scenery() -> void:
	_clear(_scenery_root)
	_build_terrain_features()
	_build_compass()
	_flush_batches(_scenery_root)


func _rebuild_ground() -> void:
	_clear(_ground_root)
	_build_ground()


func _rebuild_layout() -> void:
	_clear(_tiles_root)
	_clear(_terminal_root)
	_clear(_runway_root)
	_clear(_stand_root)
	_stand_nodes.clear()

	_build_tiles()
	_flush_batches(_tiles_root)
	_build_terminals()
	_flush_batches(_terminal_root)
	_build_runways()
	_flush_batches(_runway_root)
	_build_stands()


# Terrain is cosmetic and arrives only once the player picks a region, which is
# after the renderer already exists — so it is applied late.
#
# This MUST invalidate every tier. _mats.clear() orphans the cached materials
# while existing batches still hold material_override references to the old
# objects, so anything not rebuilt would silently keep the fallback colours.
func set_terrain(t: Dictionary) -> void:
	_terrain = t
	_mats.clear()
	_scenery_built = false
	_ground_mask = -1
	mark_layout_dirty()


func _terrain_color(key: String, fallback: Color) -> Color:
	if _terrain.has(key):
		return _terrain[key]
	return fallback


func _build_ground() -> void:
	var r: Rect2 = grid.grid_rect()
	# A skirt well beyond the buildable area, so the field does not simply end in
	# mid-air at this camera angle.
	_slab(_ground_root, Vector3(r.size.x * 4.0, 2.0, r.size.y * 4.0),
		w3(r.position + r.size * 0.5, -2.0),
		_mat("skirt", _terrain_color("surround", COL_OUTSIDE)))
	# Owned land is drawn as the airport's own ground; buyable tracts are drawn
	# darker and a touch lower, so the boundary of the property is legible
	# without needing an overlay.
	var field := _terrain_color("field", COL_FIELD)
	var field_mat := _mat("field", field)
	var raw_mat := _mat("rawland", field.darkened(0.34).lerp(Color(0.28, 0.26, 0.20), 0.25))

	_tract_slab(AirportGrid.START_TRACT, field_mat, 0.0)
	for i in AirportGrid.TRACTS.size():
		var tr: Rect2i = AirportGrid.TRACTS[i]
		if grid.owned_tracts.has(i):
			_tract_slab(tr, field_mat, 0.0)
		else:
			_tract_slab(tr, raw_mat, -0.7)

	_build_terrain_features()
	_build_compass()


func _tract_slab(r: Rect2i, mat: Material, y: float) -> void:
	var t: float = AirportGrid.TILE
	var pos: Vector2 = AirportGrid.ORIGIN + Vector2(r.position) * t
	var size: Vector2 = Vector2(r.size) * t
	_slab(_ground_root, Vector3(size.x, 2.0, size.y), w3(pos + size * 0.5, y), mat)


# Scatter whatever the region grows outside the fence. Deterministic from the
# terrain name so the skyline is stable across rebuilds — a fresh scatter every
# time a taxiway is placed would make the horizon crawl.
func _build_terrain_features() -> void:
	if _terrain.is_empty():
		return
	var kind: String = _terrain.get("feature", "none")
	if kind == "none":
		return

	var rng := RandomNumberGenerator.new()
	rng.seed = hash(str(_terrain.get("name", "x")))

	var r: Rect2 = grid.grid_rect()
	# Keep a clear margin so nothing sprouts on the apron, and stay inside the
	# skirt so features never float off its edge.
	var inner := r.grow(AirportGrid.TILE * 1.5)
	var outer := r.grow(AirportGrid.TILE * 13.0)
	var body := _mat("feat", _terrain_color("feature_color", COL_OUTSIDE))
	var accent := _mat("feataccent", _terrain_color("accent", COL_OUTSIDE))

	var want: int = int(_terrain.get("density", 100))
	var placed := 0
	var guard := 0
	while placed < want and guard < want * 12:
		guard += 1
		var p := Vector2(
			rng.randf_range(outer.position.x, outer.end.x),
			rng.randf_range(outer.position.y, outer.end.y))
		if inner.has_point(p):
			continue
		_spawn_feature(kind, p, rng, body, accent)
		placed += 1


func _spawn_feature(kind: String, p: Vector2, rng: RandomNumberGenerator,
		body: Material, accent: Material) -> void:
	match kind:
		"mountains":
			# Big enough to actually ring the airport rather than read as rubble.
			var h: float = rng.randf_range(90.0, 240.0)
			var rad: float = h * rng.randf_range(0.45, 0.75)
			_cone(p, rad, h, body)
			# Snow line only on the taller peaks, which is what makes a range
			# read as a range instead of a row of identical cones.
			if h > 150.0:
				_cone(p + Vector2(0.0, 0.0), rad * 0.34, h * 0.3, accent, h * 0.72)
		"conifers":
			var th: float = rng.randf_range(16.0, 30.0)
			_cone(p, th * rng.randf_range(0.24, 0.34), th, body)
		"palms":
			var ph: float = rng.randf_range(20.0, 34.0)
			_cylinder(p, 1.1, ph, accent)
			_cone(p, 7.0, 8.0, body, ph * 0.86)
		"mesas":
			var mh: float = rng.randf_range(14.0, 34.0)
			var mw: float = mh * rng.randf_range(0.8, 1.5)
			_add("mesa", "box", body, Vector3(mw, mh, mw * rng.randf_range(0.6, 1.0)),
				w3(p, mh * 0.5), rng.randf_range(0.0, TAU))
		"dunes":
			var dh: float = rng.randf_range(6.0, 16.0)
			var dr: float = dh * rng.randf_range(2.2, 4.0)
			# SphereMesh already took radius and height independently, i.e. it was
			# an ellipsoid; non-uniform scale of a unit sphere is the same shape.
			_add("dune", "sphere", body, Vector3(dr * 2.0, dh * 2.0, dr * 2.0), w3(p, 0.0))
		"scrub":
			var sh: float = rng.randf_range(3.0, 7.0)
			_add("scrub", "sphere", body, Vector3(sh * 2.0, sh * 1.4, sh * 2.0), w3(p, sh * 0.4))


# Scenery cones and cylinders batch against shared unit meshes. Curved surfaces
# do get skewed normals under non-uniform scale, but the old code already set
# radius and height independently, so the result is identical.
func _cone(p: Vector2, radius: float, height: float, mat: Material, base: float = 0.0) -> void:
	_add("cone_" + str(mat.get_instance_id()), "cone", mat,
		Vector3(radius * 2.0, height, radius * 2.0), w3(p, base + height * 0.5))


func _cylinder(p: Vector2, radius: float, height: float, mat: Material) -> void:
	_add("cyl_" + str(mat.get_instance_id()), "cyl", mat,
		Vector3(radius * 2.0, height, radius * 2.0), w3(p, height * 0.5))


# A compass rose painted on the field's north-west corner. World -y is north (the
# same convention runway designators use), and because it is real ground geometry
# rather than a HUD widget it stays truthful as the camera rotates.
#
# Painted inside the field rather than out on the surround: outside it sits
# beyond the camera's default framing and is simply never seen. It is only a
# ground marking, so building over it is harmless.
func _build_compass() -> void:
	var r: Rect2 = grid.grid_rect()
	var c := r.position + Vector2(AirportGrid.TILE * 2.2, AirportGrid.TILE * 2.2)
	var ink := _mat("compass", Color(0.93, 0.95, 0.93, 0.85), true)

	var ring := TorusMesh.new()
	ring.inner_radius = 30.0
	ring.outer_radius = 33.0
	var rm := MeshInstance3D.new()
	rm.mesh = ring
	rm.material_override = ink
	rm.position = w3(c, H_MARKING)
	_scenery_root.add_child(rm)

	# North needle, then a shorter cross-bar for the other three points.
	_slab(_scenery_root, Vector3(4.0, 0.6, 54.0), w3(c + Vector2(0.0, -6.0), H_MARKING), ink)
	_slab(_scenery_root, Vector3(40.0, 0.6, 3.0), w3(c, H_MARKING), ink)

	var n := Label3D.new()
	n.text = "N"
	n.font_size = 96
	n.pixel_size = 0.42
	n.modulate = Color(0.95, 0.97, 0.95)
	n.billboard = BaseMaterial3D.BILLBOARD_DISABLED
	n.double_sided = true
	n.no_depth_test = false
	n.rotation_degrees = Vector3(-90.0, 0.0, 0.0)
	n.position = w3(c + Vector2(0.0, -46.0), H_MARKING)
	_scenery_root.add_child(n)


func _build_tiles() -> void:
	var t: float = AirportGrid.TILE
	for cell in grid.tiles:
		var type: int = grid.tile_type(cell)
		var centre: Vector2 = grid.cell_to_world(cell)

		match type:
			AirportGrid.TileType.TAXIWAY:
				_add("taxi", "box", _mat("taxi", COL_TAXIWAY),
					Vector3(t, H_PAVEMENT, t), w3(centre, H_PAVEMENT * 0.5))
			AirportGrid.TileType.ROAD:
				_build_road_tile(cell, centre)
			AirportGrid.TileType.PARKING:
				_add("park", "box", _mat("park", COL_PARKING),
					Vector3(t, H_PAVEMENT, t), w3(centre, H_PAVEMENT * 0.5))
				for i in 3:
					var off: float = t * ((float(i) + 0.5) / 3.0 - 0.5)
					_add("baymark", "box", _mat("baymark", Color(0.75, 0.75, 0.8)),
						Vector3(1.4, 0.6, t * 0.62), w3(centre + Vector2(off, 0.0), H_MARKING))
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

	_add("road", "box", mat, Vector3(w, H_PAVEMENT, w), w3(centre, H_PAVEMENT * 0.5))

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
		_add("road", "box", mat, size, w3(arm, H_PAVEMENT * 0.5))

		var dash := Vector3(w * 0.34, 0.6, 1.6) if absf(v.x) > 0.0 else Vector3(1.6, 0.6, w * 0.34)
		_add("roadmark", "box", mark, dash, w3(centre + v * (t * 0.3), H_MARKING))


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
		_add("term", "box", _mat("term", COL_TERMINAL),
			Vector3(width, H_TERMINAL, t), w3(centre, H_TERMINAL * 0.5))
		_add("termedge", "box", _mat("termedge", COL_TERMINAL_EDGE),
			Vector3(width, H_KERB, t), w3(centre, H_TERMINAL + H_KERB * 0.5))
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
		_add("rwy", "box", _mat("rwy", COL_RUNWAY),
			Vector3(length, H_PAVEMENT, t * RUNWAY_WIDTH_TILES),
			w3((ea + eb) * 0.5, H_PAVEMENT * 0.5), yaw)

		var usable: bool = grid.runway_is_usable(r)
		var mark := _mat("rwymark", COL_MARKING) if usable else _mat("rwybad", Color(1.0, 0.35, 0.35))
		var dashes := maxi(int(length / 24.0), 1)
		for i in dashes:
			var f: float = (float(i) + 0.5) / float(dashes)
			_add("rwymark_" + ("ok" if usable else "bad"), "box", mark,
				Vector3(12.0, 0.6, 1.8), w3(ea.lerp(eb, f), H_MARKING), yaw)

		# Threshold designators, painted on the pavement at each end.
		var ends: Array = grid.runway_end_labels(r)
		_paint_designator(ends[0], ea + axis * (t * 0.9), axis)
		_paint_designator(ends[1], eb - axis * (t * 0.9), -axis)


# Painted flat on the pavement rather than drawn as a screen-space label: it is a
# runway marking, so it belongs to the ground and should rotate with the strip
# and with the camera. `facing` is the direction a departing aircraft is looking,
# which is the direction the numerals must read.
func _paint_designator(text: String, at: Vector2, facing: Vector2) -> void:
	var l := Label3D.new()
	l.text = text
	l.font_size = 128
	l.pixel_size = 0.24
	l.modulate = Color(0.94, 0.94, 0.94)
	l.billboard = BaseMaterial3D.BILLBOARD_DISABLED
	l.double_sided = true
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	# Lay it flat (-90 about X), then spin it so its "up" runs down the strip.
	l.rotation_degrees = Vector3(-90.0, rad_to_deg(-facing.angle() - PI * 0.5), 0.0)
	l.position = w3(at, H_MARKING)
	_runway_root.add_child(l)


func _build_stands() -> void:
	var t: float = AirportGrid.TILE
	for g in grid.stands:
		var nodes: Array = []
		for c in g["cells"]:
			nodes.append(_slab(_stand_root, Vector3(t * 0.96, H_STAND, t * 0.96),
				w3(grid.cell_to_world(c), H_STAND * 0.5), _mat("standfree", COL_STAND_FREE)))
		_stand_nodes[g["id"]] = nodes


# Stand occupancy flips constantly while the layout does not, so colour is
# refreshed per frame rather than triggering a full static rebuild.
func sync_stands() -> void:
	if grid == null:
		return
	for g in grid.stands:
		if not _stand_nodes.has(g["id"]):
			continue
		var mat: Material
		if not grid.stand_is_connected(g):
			mat = _mat("standorphan", COL_STAND_ORPHAN)
		elif g["occupied"]:
			mat = _mat("standbusy", COL_STAND_BUSY)
		else:
			mat = _mat("standfree", COL_STAND_FREE)
		for mi in _stand_nodes[g["id"]]:
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


# --- weather ----------------------------------------------------------------
#
# CPUParticles3D rather than GPUParticles3D: the project runs the
# gl_compatibility renderer, where CPU particles are the dependable option.
#
# The emitter is parented to the camera pivot and emits from a flat box above it,
# so precipitation follows the view instead of being a patch of weather sitting
# over one corner of a field the player may have panned away from.

## `kind` is a Regions.WEATHER key, or "" for clear.
func set_weather(kind: String) -> void:
	if kind == _weather_kind:
		return
	_weather_kind = kind

	if _weather != null:
		_weather.queue_free()
		_weather = null
	if kind != "snow" and kind != "storm" and kind != "fog":
		return

	var p := CPUParticles3D.new()
	p.local_coords = false
	p.emission_shape = CPUParticles3D.EMISSION_SHAPE_BOX
	p.emission_box_extents = Vector3(900.0, 4.0, 900.0)
	p.position = Vector3(0.0, 620.0, 0.0)
	p.draw_order = CPUParticles3D.DRAW_ORDER_VIEW_DEPTH

	var mesh := QuadMesh.new()
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	mat.vertex_color_use_as_albedo = true

	match kind:
		"snow":
			mesh.size = Vector2(3.4, 3.4)
			mat.albedo_color = Color(1, 1, 1, 0.9)
			p.amount = 1400
			p.lifetime = 7.0
			p.gravity = Vector3(0.0, -70.0, 0.0)
			# Lateral spread makes it drift rather than fall like a curtain.
			p.initial_velocity_min = 8.0
			p.initial_velocity_max = 26.0
			p.direction = Vector3(0.35, -1.0, 0.2)
			p.spread = 28.0
		"storm":
			mesh.size = Vector2(1.1, 13.0)
			mat.albedo_color = Color(0.68, 0.78, 0.92, 0.55)
			p.amount = 2200
			p.lifetime = 2.2
			p.gravity = Vector3(0.0, -900.0, 0.0)
			p.initial_velocity_min = 220.0
			p.initial_velocity_max = 300.0
			p.direction = Vector3(0.18, -1.0, 0.1)
			p.spread = 4.0
		"fog":
			# Fog is not precipitation — a few big, slow, near-transparent puffs
			# drifting through read as murk without hiding the airport.
			mesh.size = Vector2(150.0, 150.0)
			mat.albedo_color = Color(0.78, 0.82, 0.85, 0.10)
			p.amount = 26
			p.lifetime = 26.0
			p.gravity = Vector3.ZERO
			p.initial_velocity_min = 4.0
			p.initial_velocity_max = 12.0
			p.direction = Vector3(1.0, 0.0, 0.3)
			p.spread = 12.0
			p.position = Vector3(0.0, 60.0, 0.0)
			p.emission_box_extents = Vector3(900.0, 40.0, 900.0)

	mesh.material = mat
	p.mesh = mesh
	# Pre-fill, so weather starting does not begin with an empty sky.
	p.preprocess = p.lifetime
	_yaw_node.add_child(p)
	_weather = p


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


# A whole parcel as one slab. Emitting 100+ per-cell ghosts for a land purchase
# would be pointless churn every time the cursor moves.
func set_ghost_rect(r: Rect2i, color: Color) -> void:
	var sig := "t%s%s" % [color.to_html(false), r]
	if sig == _ghost_sig:
		return
	_ghost_sig = sig
	for c in _ghost_root.get_children():
		c.queue_free()

	var t: float = AirportGrid.TILE
	var pos: Vector2 = AirportGrid.ORIGIN + Vector2(r.position) * t
	var size: Vector2 = Vector2(r.size) * t
	_slab(_ghost_root, Vector3(size.x, H_GHOST, size.y),
		w3(pos + size * 0.5, H_GHOST * 0.5), _mat("ghost_" + color.to_html(true), color, true))


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
