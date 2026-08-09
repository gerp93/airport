extends RefCounted

enum TileType { EMPTY, TAXIWAY, RUNWAY, GATE }

const COLS := 40
const ROWS := 16
const TILE := 32.0
const ORIGIN := Vector2(0.0, 88.0)
const MIN_RUNWAY_LEN := 8
const RUNWAY_WEIGHT := 8.0
const NOWHERE := Vector2i(-1, -1)

var tiles := {}
var claims := {}
var runways: Array = []
var gates: Array = []

var _astar := AStarGrid2D.new()
var _runway_seq := 0
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
	_astar.set_point_solid(c, t == TileType.EMPTY)
	_astar.set_point_weight_scale(c, RUNWAY_WEIGHT if t == TileType.RUNWAY else 1.0)


# --- placement ---

func can_place_taxiway(c: Vector2i) -> bool:
	return in_bounds(c) and tile_type(c) == TileType.EMPTY


func place_taxiway(c: Vector2i) -> void:
	tiles[c] = {"type": TileType.TAXIWAY, "entity_id": -1}
	_refresh_cell(c)


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


func can_place_runway(cells: Array) -> bool:
	if cells.is_empty():
		return false
	for c in cells:
		if not can_place_taxiway(c):
			return false
	return true


func place_runway(cells: Array) -> int:
	var sorted: Array = cells.duplicate()
	var horizontal: bool = sorted.size() < 2 or sorted[0].y == sorted[1].y
	# Normalize so cells[0] is always the threshold (left for horizontal, top for vertical).
	sorted.sort_custom(func(a, b): return (a.x < b.x) if horizontal else (a.y < b.y))

	var id := _runway_seq
	_runway_seq += 1
	runways.append({
		"id": id, "cells": sorted, "horizontal": horizontal, "occupied": false,
	})
	for c in sorted:
		tiles[c] = {"type": TileType.RUNWAY, "entity_id": id}
		_refresh_cell(c)
	return id


func can_place_gate(c: Vector2i) -> bool:
	return in_bounds(c) and tile_type(c) == TileType.EMPTY


func place_gate(c: Vector2i) -> int:
	var id := _gate_seq
	_gate_seq += 1
	gates.append({"id": id, "cell": c, "occupied": false})
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
	for n in neighbors(g["cell"]):
		if tile_type(n) == TileType.TAXIWAY:
			return true
	return false


func runway_is_usable(r: Dictionary) -> bool:
	return r["cells"].size() >= MIN_RUNWAY_LEN and runway_exit_cell(r) != NOWHERE


func runway_threshold(r: Dictionary) -> Vector2i:
	return r["cells"][0]


func runway_direction(r: Dictionary) -> Vector2:
	return Vector2.RIGHT if r["horizontal"] else Vector2.DOWN


# Where an outbound plane waits without standing on the runway itself.
func runway_hold_short_cell(r: Dictionary) -> Vector2i:
	for n in neighbors(runway_threshold(r)):
		if tile_type(n) == TileType.TAXIWAY:
			return n
	return NOWHERE


func runway_is_clear(r: Dictionary, ignore_plane: int = -1) -> bool:
	if r["occupied"] or not runway_is_usable(r):
		return false
	for c in r["cells"]:
		var owner := claim_owner(c)
		if owner != -1 and owner != ignore_plane:
			return false
	return true


# The runway cell with an adjacent taxiway that sits furthest along the rollout,
# so a connection near the far end produces a realistically long landing roll.
func runway_exit_cell(r: Dictionary) -> Vector2i:
	var found := NOWHERE
	for c in r["cells"]:
		for n in neighbors(c):
			if tile_type(n) == TileType.TAXIWAY:
				found = c
				break
	return found


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
		TileType.TAXIWAY:
			if claims.has(c):
				return {}
			return {"type": t, "tiles": 1, "cells": [c]}
		TileType.GATE:
			var g = gate_at(c)
			if g == null or g["occupied"] or claims.has(c):
				return {}
			return {"type": t, "tiles": 1, "cells": [c]}
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


# --- starting layout ---

func seed_starter_airport() -> void:
	place_runway(line_cells(Vector2i(4, 12), Vector2i(19, 12)))
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
	for x in [10, 13, 16]:
		place_gate(Vector2i(x, 6))
