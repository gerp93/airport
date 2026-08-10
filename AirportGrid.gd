extends RefCounted

enum TileType { EMPTY, TAXIWAY, RUNWAY, GATE, TERMINAL, ROAD, PARKING }

const COLS := 32
const ROWS := 18
const TILE := 32.0
const ORIGIN := Vector2(0.0, 96.0)
const MIN_RUNWAY_LEN := 6
const RUNWAY_WEIGHT := 8.0
const NOWHERE := Vector2i(-1, -1)

var tiles := {}
var claims := {}
var runways: Array = []
var gates: Array = []

var _astar := AStarGrid2D.new()
var _runway_seq := 0
var _landside_dirty := true
var _landside_cache := {}
var _gate_seq := 0


func _init() -> void:
	_astar.region = Rect2i(0, 0, COLS, ROWS)
	_astar.cell_size = Vector2(TILE, TILE)
	_astar.offset = ORIGIN + Vector2(TILE, TILE) * 0.5
	_astar.diagonal_mode = AStarGrid2D.DIAGONAL_MODE_NEVER
	_astar.default_compute_heuristic = AStarGrid2D.HEURISTIC_MANHATTAN
	_astar.default_estimate_heuristic = AStarGrid2D.HEURISTIC_MANHATTAN
	_astar.update()
	for y in ROWS:
		for x in COLS:
			_refresh_cell(Vector2i(x, y))


# --- geometry ---

func in_bounds(c: Vector2i) -> bool:
	return c.x >= 0 and c.x < COLS and c.y >= 0 and c.y < ROWS


func cell_to_world(c: Vector2i) -> Vector2:
	return ORIGIN + Vector2(c) * TILE + Vector2(TILE, TILE) * 0.5


func world_to_cell(p: Vector2) -> Vector2i:
	var local := p - ORIGIN
	return Vector2i(floori(local.x / TILE), floori(local.y / TILE))


func grid_rect() -> Rect2:
	return Rect2(ORIGIN, Vector2(COLS, ROWS) * TILE)


func neighbors(c: Vector2i) -> Array:
	var out := []
	for d in [Vector2i.LEFT, Vector2i.RIGHT, Vector2i.UP, Vector2i.DOWN]:
		var n: Vector2i = c + d
		if in_bounds(n):
			out.append(n)
	return out


# --- tile queries ---

func tile_type(c: Vector2i) -> int:
	if not tiles.has(c):
		return TileType.EMPTY
	return tiles[c]["type"]


func is_navigable(c: Vector2i) -> bool:
	return tile_type(c) != TileType.EMPTY


func _refresh_cell(c: Vector2i) -> void:
	var t := tile_type(c)
	# Terminals, roads and car parks are landside: aircraft route around them.
	_astar.set_point_solid(c, t == TileType.EMPTY or t == TileType.TERMINAL \
		or t == TileType.ROAD or t == TileType.PARKING)
	_landside_dirty = true
	_astar.set_point_weight_scale(c, RUNWAY_WEIGHT if t == TileType.RUNWAY else 1.0)


# --- placement ---

func can_place_taxiway(c: Vector2i) -> bool:
	return in_bounds(c) and tile_type(c) == TileType.EMPTY


func place_taxiway(c: Vector2i) -> void:
	tiles[c] = {"type": TileType.TAXIWAY, "entity_id": -1}
	_refresh_cell(c)


func can_place_terminal(c: Vector2i) -> bool:
	return in_bounds(c) and tile_type(c) == TileType.EMPTY


func place_terminal(c: Vector2i) -> void:
	tiles[c] = {"type": TileType.TERMINAL, "entity_id": -1}
	_refresh_cell(c)


# Roads carry passengers in from outside, so the network only counts if it
# reaches the map edge. Flood from every road tile on the boundary; a concourse
# or car park is live only if it touches that network. An airport with no road
# access handles nobody, however much terminal it has built.
func landside_roads() -> Dictionary:
	if not _landside_dirty:
		return _landside_cache
	var reached := {}
	var queue := []
	for c in tiles:
		if tiles[c]["type"] != TileType.ROAD:
			continue
		if c.x == 0 or c.y == 0 or c.x == COLS - 1 or c.y == ROWS - 1:
			reached[c] = true
			queue.append(c)
	while not queue.is_empty():
		var cur: Vector2i = queue.pop_back()
		for n in neighbors(cur):
			if reached.has(n) or tile_type(n) != TileType.ROAD:
				continue
			reached[n] = true
			queue.append(n)
	_landside_cache = reached
	_landside_dirty = false
	return reached


func is_road_served(c: Vector2i) -> bool:
	var roads := landside_roads()
	for n in neighbors(c):
		if roads.has(n):
			return true
	return false


func count_tiles(type: int, road_served_only: bool) -> int:
	var n := 0
	for c in tiles:
		if tiles[c]["type"] != type:
			continue
		if road_served_only and not is_road_served(c):
			continue
		n += 1
	return n


func can_place_road(c: Vector2i) -> bool:
	return in_bounds(c) and tile_type(c) == TileType.EMPTY


func place_road(c: Vector2i) -> void:
	tiles[c] = {"type": TileType.ROAD, "entity_id": -1}
	_refresh_cell(c)


func can_place_parking(c: Vector2i) -> bool:
	return in_bounds(c) and tile_type(c) == TileType.EMPTY


func place_parking(c: Vector2i) -> void:
	tiles[c] = {"type": TileType.PARKING, "entity_id": -1}
	_refresh_cell(c)


func terminal_tile_count() -> int:
	var n := 0
	for c in tiles:
		if tiles[c]["type"] == TileType.TERMINAL:
			n += 1
	return n


# A stand touching a terminal is a contact stand — passengers walk a jet bridge.
# One that isn't still works, but everyone has to be bussed out to it.
func gate_is_contact(gate: Dictionary) -> bool:
	for c in gate["cells"]:
		for n in neighbors(c):
			if tile_type(n) == TileType.TERMINAL:
				return true
	return false


func line_cells(from: Vector2i, to: Vector2i) -> Array:
	var cells := []
	if abs(to.x - from.x) >= abs(to.y - from.y):
		var step := 1 if to.x >= from.x else -1
		for x in range(from.x, to.x + step, step):
			cells.append(Vector2i(x, from.y))
	else:
		var step := 1 if to.y >= from.y else -1
		for y in range(from.y, to.y + step, step):
			cells.append(Vector2i(from.x, y))
	return cells


# A runway is a free-angle segment in world space rather than a row of tiles.
# It is the one structure the grid buys nothing for: taxiways need a grid because
# they are a pathfinding graph and stands need one because they are discrete
# slots, but a runway is a single straight strip. Tile-stepping it restricted
# headings to the eight compass points; endpoints let the player build any
# alignment, so all 36 designators are reachable and lengths are exact.
#
# The footprint cells are still tracked, purely so nothing else can be built on
# the pavement and so demolition knows what to clear.

func runway_footprint(a: Vector2, b: Vector2) -> Array:
	var out := []
	var lo := Vector2(minf(a.x, b.x), minf(a.y, b.y)) - Vector2(TILE, TILE)
	var hi := Vector2(maxf(a.x, b.x), maxf(a.y, b.y)) + Vector2(TILE, TILE)
	var c0 := world_to_cell(lo)
	var c1 := world_to_cell(hi)
	for y in range(c0.y, c1.y + 1):
		for x in range(c0.x, c1.x + 1):
			var c := Vector2i(x, y)
			if not in_bounds(c):
				continue
			var centre := cell_to_world(c)
			var near := Geometry2D.get_closest_point_to_segment(centre, a, b)
			if centre.distance_to(near) <= TILE * 0.62:
				out.append(c)
	return out


# Measured end to end, plus one tile so a strip drawn between two cell centres
# covers the same distance the old tile count reported.
func runway_length_tiles(r: Dictionary) -> float:
	return (r["a"] as Vector2).distance_to(r["b"] as Vector2) / TILE + 1.0


func can_place_runway_seg(a: Vector2, b: Vector2) -> bool:
	var cells := runway_footprint(a, b)
	if cells.is_empty():
		return false
	for c in cells:
		if not can_place_taxiway(c):
			return false
	return true


func place_runway_seg(a: Vector2, b: Vector2) -> int:
	var id := _runway_seq
	_runway_seq += 1
	var cells := runway_footprint(a, b)
	runways.append({"id": id, "a": a, "b": b, "cells": cells, "occupied": false})
	for c in cells:
		tiles[c] = {"type": TileType.RUNWAY, "entity_id": id}
		_refresh_cell(c)
	return id


# A drag that begins on one end of an existing runway and continues roughly along
# its axis lengthens that runway instead of laying a parallel strip beside it.
const EXTEND_SNAP := 44.0
const EXTEND_ARC := 0.30


func runway_extend_target(from: Vector2, to: Vector2) -> int:
	if from.distance_to(to) < 1.0:
		return -1
	var outward := (to - from).normalized()
	for r in runways:
		var axis := runway_direction(r)
		if from.distance_to(r["a"]) <= EXTEND_SNAP and absf(outward.angle_to(-axis)) < EXTEND_ARC:
			return int(r["id"])
		if from.distance_to(r["b"]) <= EXTEND_SNAP and absf(outward.angle_to(axis)) < EXTEND_ARC:
			return int(r["id"])
	return -1


func extend_runway_seg(id: int, to: Vector2) -> void:
	var r = get_runway(id)
	if r == null:
		return
	var a: Vector2 = r["a"]
	var b: Vector2 = r["b"]
	var axis := runway_direction(r)
	var span := a.distance_to(b)
	# Project onto the existing axis so extending can never bend the runway, and
	# clamp so a stray drag shortens nothing.
	var t: float = (to - a).dot(axis)
	if to.distance_to(a) < to.distance_to(b):
		r["a"] = a + axis * minf(t, 0.0)
	else:
		r["b"] = a + axis * maxf(t, span)
	_restamp_runway(r)


func _restamp_runway(r: Dictionary) -> void:
	var old: Array = r["cells"]
	for c in old:
		if tiles.has(c) and tiles[c]["entity_id"] == r["id"] and tile_type(c) == TileType.RUNWAY:
			tiles.erase(c)
	var cells := runway_footprint(r["a"], r["b"])
	r["cells"] = cells
	for c in cells:
		tiles[c] = {"type": TileType.RUNWAY, "entity_id": r["id"]}
	for c in old:
		_refresh_cell(c)
	for c in cells:
		_refresh_cell(c)


# A gate spans `size` tiles to the right of its anchor: 1 for a small stand,
# 2 for a widebody stand.
func gate_cells_for(anchor: Vector2i, size: int) -> Array:
	var cells := []
	for i in size:
		cells.append(anchor + Vector2i(i, 0))
	return cells


func can_place_gate(cells: Array) -> bool:
	for c in cells:
		if not in_bounds(c) or tile_type(c) != TileType.EMPTY:
			return false
	return not cells.is_empty()


func place_gate(cells: Array, size: int) -> int:
	var id := _gate_seq
	_gate_seq += 1
	gates.append({"id": id, "cells": cells.duplicate(), "size": size, "occupied": false})
	for c in cells:
		tiles[c] = {"type": TileType.GATE, "entity_id": id}
		_refresh_cell(c)
	return id


# --- entity lookup ---

func runway_at(c: Vector2i) -> Variant:
	if tile_type(c) != TileType.RUNWAY:
		return null
	return get_runway(tiles[c]["entity_id"])


func gate_at(c: Vector2i) -> Variant:
	if tile_type(c) != TileType.GATE:
		return null
	return get_gate(tiles[c]["entity_id"])


func get_runway(id: int) -> Variant:
	for r in runways:
		if r["id"] == id:
			return r
	return null


func get_gate(id: int) -> Variant:
	for g in gates:
		if g["id"] == id:
			return g
	return null


# --- usability ---

func gate_is_connected(g: Dictionary) -> bool:
	return gate_park_cell(g) != NOWHERE


# Planes park on whichever of the gate's tiles touches a taxiway.
func gate_park_cell(g: Dictionary) -> Vector2i:
	for c in g["cells"]:
		for n in neighbors(c):
			if tile_type(n) == TileType.TAXIWAY:
				return c
	return NOWHERE


func runway_is_usable(r: Dictionary) -> bool:
	return runway_length_tiles(r) >= float(MIN_RUNWAY_LEN) and runway_exit_taxiway(r) != NOWHERE


func runway_threshold_point(r: Dictionary) -> Vector2:
	return r["a"]


func runway_direction(r: Dictionary) -> Vector2:
	var d: Vector2 = (r["b"] as Vector2) - (r["a"] as Vector2)
	return Vector2.RIGHT if d.length() < 0.001 else d.normalized()


# Runway designators follow the real convention: the approach heading in tens of
# degrees, with both ends listed. Screen y grows downward, so north is -y — an
# east-west runway is 09/27 and a north-south one is 18/36.
func runway_headings(r: Dictionary) -> Array:
	var d: Vector2 = runway_direction(r)
	var deg: float = rad_to_deg(atan2(d.x, -d.y))
	if deg < 0.0:
		deg += 360.0
	var num := int(round(deg / 10.0))
	if num == 0:
		num = 36
	var recip := num + 18
	if recip > 36:
		recip -= 36
	return [mini(num, recip), maxi(num, recip)]


# Parallel runways sharing a heading take L/C/R, ordered across the field, and the
# suffix mirrors at the far end the way it does in reality: 09L reads as 27R.
func runway_name(r: Dictionary) -> String:
	var pair := runway_headings(r)
	var siblings := []
	for other in runways:
		if runway_headings(other) == pair:
			siblings.append(other)

	if siblings.size() <= 1:
		return "%02d/%02d" % pair

	var axis := runway_direction(r)
	var perp := Vector2(-axis.y, axis.x)
	siblings.sort_custom(func(x, y): return perp.dot(x["a"]) < perp.dot(y["a"]))

	var idx := 0
	for i in siblings.size():
		if siblings[i]["id"] == r["id"]:
			idx = i
			break

	var suffix := str(idx + 1)
	if siblings.size() == 2:
		suffix = "L" if idx == 0 else "R"
	elif siblings.size() == 3:
		suffix = ["L", "C", "R"][idx]
	var mirrored: String = {"L": "R", "R": "L", "C": "C"}.get(suffix, suffix)
	return "%02d%s/%02d%s" % [pair[0], suffix, pair[1], mirrored]


# Taxiway touching the pavement nearest the threshold: where an outbound aircraft
# waits without standing on the runway itself.
func runway_hold_short_cell(r: Dictionary) -> Vector2i:
	return _connected_taxiway(r, true)


# Taxiway furthest along the landing roll, so a connection near the far end
# produces a realistically long rollout.
func runway_exit_taxiway(r: Dictionary) -> Vector2i:
	return _connected_taxiway(r, false)


func _connected_taxiway(r: Dictionary, nearest: bool) -> Vector2i:
	var axis := runway_direction(r)
	var a: Vector2 = r["a"]
	var best := NOWHERE
	var best_t := INF if nearest else -INF
	for c in r["cells"]:
		for n in neighbors(c):
			if tile_type(n) != TileType.TAXIWAY:
				continue
			var t: float = (cell_to_world(n) - a).dot(axis)
			if (t < best_t) if nearest else (t > best_t):
				best_t = t
				best = n
	return best


# Where the landing roll ends: the exit taxiway projected onto the centreline.
func runway_exit_point(r: Dictionary) -> Vector2:
	var n := runway_exit_taxiway(r)
	var a: Vector2 = r["a"]
	if n == NOWHERE:
		return r["b"]
	var axis := runway_direction(r)
	var t: float = clampf((cell_to_world(n) - a).dot(axis), 0.0, a.distance_to(r["b"]))
	return a + axis * t


# Aircraft no longer claim individual runway tiles - the strip is held as a whole
# by whoever is using it, which is both simpler and how a real runway works.
func runway_is_clear(r: Dictionary, _ignore_plane: int = -1) -> bool:
	return not r["occupied"] and runway_is_usable(r)


func usable_free_gates() -> Array:
	var out := []
	for g in gates:
		if not g["occupied"] and gate_is_connected(g):
			out.append(g)
	return out


func usable_free_runway() -> Variant:
	for r in runways:
		if runway_is_clear(r):
			return r
	return null


func has_usable_runway() -> bool:
	for r in runways:
		if runway_is_usable(r):
			return true
	return false


# --- claims ---

func claim_owner(c: Vector2i) -> int:
	return claims.get(c, -1)


func try_claim(c: Vector2i, plane_id: int) -> bool:
	var owner: int = claims.get(c, -1)
	if owner == plane_id:
		return true
	if owner != -1:
		return false
	claims[c] = plane_id
	return true


func release(c: Vector2i, plane_id: int) -> void:
	if claims.get(c, -1) == plane_id:
		claims.erase(c)


func release_all(plane_id: int) -> void:
	for c in claims.keys():
		if claims[c] == plane_id:
			claims.erase(c)


# --- pathfinding ---

func find_path(from: Vector2i, to: Vector2i) -> Array:
	if not in_bounds(from) or not in_bounds(to):
		return []
	if not is_navigable(from) or not is_navigable(to):
		return []
	return Array(_astar.get_id_path(from, to))


# Same query, but treats tiles held by other planes as walls so a blocked plane
# can discover a detour when the layout offers one.
func find_path_avoiding_claims(from: Vector2i, to: Vector2i, plane_id: int) -> Array:
	var toggled := []
	for c in claims:
		if claims[c] == plane_id or c == from or c == to:
			continue
		if not _astar.is_point_solid(c):
			_astar.set_point_solid(c, true)
			toggled.append(c)
	var path := find_path(from, to)
	for c in toggled:
		_astar.set_point_solid(c, false)
	return path


func nearest_free_taxiway(from: Vector2i, plane_id: int) -> Vector2i:
	var seen := {from: true}
	var queue := [from]
	while not queue.is_empty():
		var c: Vector2i = queue.pop_front()
		if c != from and tile_type(c) == TileType.TAXIWAY and claim_owner(c) in [-1, plane_id]:
			return c
		for n in neighbors(c):
			if seen.has(n) or not is_navigable(n):
				continue
			seen[n] = true
			queue.append(n)
	return NOWHERE


# --- demolition ---

func demolish_preview(c: Vector2i) -> Dictionary:
	if not in_bounds(c):
		return {}
	var t := tile_type(c)
	match t:
		TileType.EMPTY:
			return {}
		TileType.TAXIWAY, TileType.TERMINAL, TileType.ROAD, TileType.PARKING:
			if claims.has(c):
				return {}
			return {"type": t, "tiles": 1, "cells": [c]}
		TileType.GATE:
			var g = gate_at(c)
			if g == null or g["occupied"]:
				return {}
			for gc in g["cells"]:
				if claims.has(gc):
					return {}
			return {"type": t, "tiles": g["cells"].size(), "cells": g["cells"].duplicate()}
		TileType.RUNWAY:
			var r = runway_at(c)
			if r == null or r["occupied"]:
				return {}
			for rc in r["cells"]:
				if claims.has(rc):
					return {}
			return {"type": t, "tiles": r["cells"].size(), "cells": r["cells"].duplicate()}
	return {}


func demolish(c: Vector2i) -> Dictionary:
	var preview := demolish_preview(c)
	if preview.is_empty():
		return {}

	match preview["type"]:
		TileType.GATE:
			var g = gate_at(c)
			gates.erase(g)
		TileType.RUNWAY:
			var r = runway_at(c)
			runways.erase(r)

	for cell in preview["cells"]:
		tiles.erase(cell)
		_refresh_cell(cell)
	return preview


# --- persistence ---
# Only layout is serialized. Claims and occupancy belong to live aircraft, which
# are not restored, so they are rebuilt empty on load.

func to_dict() -> Dictionary:
	return {
		"tiles": tiles.duplicate(true),
		"runways": runways.duplicate(true),
		"gates": gates.duplicate(true),
		"runway_seq": _runway_seq,
		"gate_seq": _gate_seq,
	}


func from_dict(d: Dictionary) -> void:
	tiles = d["tiles"]
	runways = d["runways"]
	gates = d["gates"]
	_runway_seq = d["runway_seq"]
	_gate_seq = d["gate_seq"]

	claims.clear()
	for r in runways:
		r["occupied"] = false
	for g in gates:
		g["occupied"] = false
	for y in ROWS:
		for x in COLS:
			_refresh_cell(Vector2i(x, y))


# --- starting layout ---

func seed_starter_airport() -> void:
	place_runway_seg(cell_to_world(Vector2i(4, 12)), cell_to_world(Vector2i(19, 12)))
	# A parallel taxiway plus an apron loop, so a blocked plane has a detour to
	# find. A single-width spine deadlocks head-on traffic almost immediately.
	for x in range(4, 22):
		place_taxiway(Vector2i(x, 10))
	for x in range(8, 21):
		place_taxiway(Vector2i(x, 7))
	place_taxiway(Vector2i(4, 11))
	place_taxiway(Vector2i(19, 11))
	for y in [8, 9]:
		place_taxiway(Vector2i(8, y))
		place_taxiway(Vector2i(20, y))
	# Three stands side by side sharing ONE concourse. Spacing them out gave each
	# stand its own detached one-tile building, which read as three terminals.
	# Same tile counts as before, so the opening economy is unchanged.
	for x in [11, 12, 13]:
		place_gate(gate_cells_for(Vector2i(x, 6), 1), 1)
		place_terminal(Vector2i(x, 5))

	# Access road out to the northern boundary, plus a small car park. Without
	# a road to the edge the concourse would handle no passengers at all.
	for y in range(0, 5):
		place_road(Vector2i(13, y))
	place_parking(Vector2i(12, 3))
	place_parking(Vector2i(14, 3))
