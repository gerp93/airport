extends Node

## Build-tool smoke test.
##
## The headless balance run (see CLAUDE.md) exercises the simulation but never
## picks up a build tool, because it has no cursor. That blind spot let a
## float-modulo crash live in the runway heading readout — code that only runs
## while the Runway tool is hovering or dragging, so every headless run passed
## and it surfaced the first time a human selected the tool.
##
## This drives every tool through the hover and drag paths that the HUD, the
## ghost preview and the 3D renderer all hang off. It asserts nothing; the point
## is that GDScript's runtime errors are caught by the same `SCRIPT ERROR` grep
## the balance run uses.
##
##   godot --headless --path . --fixed-fps 60 res://ToolSweep.tscn 2>&1 | grep "SCRIPT ERROR"

# The enum has to come off the script, not off an instance — `main.Tool` does not
# resolve, and because that error aborts this coroutine the scene then never
# reaches quit() and spins forever instead of failing.
const MainScript = preload("res://Main.gd")


func _ready() -> void:
	var main = preload("res://Main.tscn").instantiate()
	add_child(main)
	# Pick a region, or _terrain stays empty, _build_terrain_features() returns
	# immediately and the whole scenery path goes untested by both harnesses.
	# Pacific Northwest is `forest`, density 320 — the heaviest case — and this
	# also exercises set_terrain()'s full-rebuild reset.
	main._choose_setup(0)
	main._choose_setup(2)
	await get_tree().process_frame
	await get_tree().process_frame

	# Driven off the enum, not a literal: hardcoding the count is how the Buy Land
	# tool would silently drop out of coverage the moment it was added.
	for t in range(MainScript.Tool.size()):
		main.tool = t
		# Both placement axes: the ghost and the HUD readout both branch on
		# build_rot, and a vertical multi-tile stand takes a different path
		# through stand_cells_for than the east-west one every layout uses.
		for rot in 2:
			main.build_rot = rot
			# Several drag targets, so the runway readout's heading maths runs at
			# a range of angles rather than one convenient axis-aligned case.
			for target in [Vector2i(12, 8), Vector2i(20, 14), Vector2i(4, 4), Vector2i(25, 3)]:
				main.hover_cell = target
				main.drag_start = Vector2i(10, 10)
				main.is_dragging = true
				main._update_hud()
				main._update_ops_ui()
				main._update_bank_ui()
				main._sync_world()
				await get_tree().process_frame

			main.is_dragging = false
			main.hover_cell = Vector2i(9, 9)
			main._update_hud()
			main._sync_world()
			await get_tree().process_frame
	main.build_rot = 0

	_check_land(main)
	_check_rotation(main)
	_check_park_heading(main)
	_check_stand_routing(main)
	_check_finance(main)
	_check_tower(main)
	_check_layout(main)
	print("tool sweep complete")
	get_tree().quit()


# Land expansion invariants. Ownership gates every can_place_* call, so getting
# it wrong either bricks building entirely or lets the player build on dirt they
# never bought — neither of which the balance run would notice.
func _check_land(main) -> void:
	var grid = main.grid
	var AG = load("res://AirportGrid.gd")
	var outside := Vector2i(AG.COLS - 2, AG.ROWS - 2)
	var inside := Vector2i(6, 14)

	_expect(not grid.is_owned(outside), "unbought tract must not be owned")
	_expect(not grid.can_place_taxiway(outside), "must not build on unowned land")
	_expect(grid.is_owned(inside), "start tract must be owned")

	# The starter road exits north off the map edge; that must still count as
	# reaching the outside world now that the grid is larger than the airport.
	_expect(not grid.landside_roads().is_empty(), "starter road must reach outside")

	var before: Rect2i = grid.owned_bounds()
	var tract: int = grid.tract_at(outside)
	_expect(tract >= 0, "unowned cell must resolve to a buyable tract")
	grid.buy_tract(tract)
	_expect(grid.is_owned(outside), "bought tract must become owned")
	_expect(grid.can_place_taxiway(outside), "bought land must be buildable")
	_expect(grid.owned_bounds() != before, "owned bounds must grow after a purchase")
	_expect(not grid.landside_roads().is_empty(), "road must still reach outside after buying")


# A north-south widebody stand has to satisfy the same contract the sim reads
# off every stand — connected, contact, and parkable. Those all walk neighbours
# rather than assuming an axis, so this guards that they stay that way.
func _check_rotation(main) -> void:
	var grid = main.grid
	var AG = load("res://AirportGrid.gd")

	# The hall is 6x2; rotating it swaps the axes.
	var flat: Array = grid.building_cells(Vector2i(22, 1), AG.TERMINAL_SIZE, 0)
	var tall: Array = grid.building_cells(Vector2i(22, 1), AG.TERMINAL_SIZE, 1)
	_expect(flat.size() == 12 and tall.size() == 12, "a terminal is 12 cells either way")
	_expect(flat.has(Vector2i(27, 2)) and not flat.has(Vector2i(23, 6)),
		"rot 0 must lay the hall east-west")
	_expect(tall.has(Vector2i(23, 6)) and not tall.has(Vector2i(27, 2)),
		"rot 1 must lay the hall north-south")

	# A stand is square, so rotation moves the jet bridge, never the footprint.
	_expect(grid.stand_cells_for(Vector2i(22, 1), 0) == grid.stand_cells_for(Vector2i(22, 1), 1),
		"a square stand occupies the same cells at either rotation")

	_expect(grid.can_place_terminal(flat), "a terminal must be placeable on clear ground")
	var tid: int = grid.place_terminal(flat, 0)
	_expect(grid.get_terminal(tid) != null, "a placed terminal must be findable")
	_expect(not grid.terminal_is_roaded(grid.get_terminal(tid)),
		"a terminal with no road must not count as roaded")

	# A pier has to meet a hall end-on; floating in a field is not a concourse.
	var loose: Array = grid.building_cells(Vector2i(22, 8), AG.CONCOURSE_SIZE, 0)
	_expect(not grid.can_place_concourse(loose), "a concourse must touch a terminal")
	var joined: Array = grid.building_cells(Vector2i(24, 3), AG.CONCOURSE_SIZE, 0)
	_expect(grid.can_place_concourse(joined), "a concourse touching the hall end-on must place")
	var cid: int = grid.place_concourse(joined, 0)
	_expect(grid.get_concourse(cid)["terminal_id"] == tid,
		"a concourse must record the terminal it hangs off")
	_expect(grid.get_concourse(cid)["cells"][0] == Vector2i(24, 3),
		"a concourse must be stored root-first, from the end that meets the hall")

	# Both hall checks run BEFORE anything else is placed nearby, or they pass
	# and fail for reasons that have nothing to do with the rule.
	#
	# Under the hall's south face, far enough east that the pier at x=24 is not a
	# neighbour: no bridge, meshes interpenetrating. Refused.
	_expect(not grid.can_place_stand(grid.stand_cells_for(Vector2i(26, 3), 0)),
		"a stand touching only the hall must be refused")
	# The same face, but with the pier alongside — an ordinary stand at the root
	# of a pier. Refusing this was too blunt.
	_expect(grid.can_place_stand(grid.stand_cells_for(Vector2i(22, 3), 0)),
		"a stand against the hall AND a pier must be allowed")

	# Stands attach to the PIER, not to the hall.
	var by_pier = grid.get_stand(grid.place_stand(grid.stand_cells_for(Vector2i(25, 4), 0), 0))
	_expect(grid.stand_is_contact(by_pier), "a stand against a pier is a contact stand")

	# Demolishing the hall orphans its piers rather than destroying them.
	grid.demolish(Vector2i(22, 1))
	_expect(grid.get_terminal(tid) == null, "demolishing must remove the whole hall")
	_expect(grid.tile_type(Vector2i(27, 2)) == AG.TileType.EMPTY,
		"demolishing a hall must clear every one of its cells")
	_expect(grid.get_concourse(cid)["terminal_id"] == -1,
		"a pier whose hall is gone must be orphaned, not deleted")
	grid.demolish(Vector2i(24, 3))
	grid.demolish(Vector2i(25, 4))


# Parked aircraft face where the stand says, not where they happened to be
# driving. The case that matters is a stand entered from the side: the taxiway
# and the pier then disagree, and the pier has to win or the aircraft sits
# broadside to its own jet bridge.
func _check_park_heading(main) -> void:
	var grid = main.grid

	var AG = load("res://AirportGrid.gd")
	# A hall standing on end, with a pier running west off it, and a stand tucked
	# under the pier with its taxiway to the EAST — so the two disagree and the
	# pier has to win.
	grid.place_terminal(grid.building_cells(Vector2i(25, 8), AG.TERMINAL_SIZE, 1), 1)
	grid.place_concourse(grid.building_cells(Vector2i(21, 11), AG.CONCOURSE_SIZE, 1), 1)
	var contact = grid.get_stand(grid.place_stand(grid.stand_cells_for(Vector2i(22, 12), 0), 0))
	grid.place_taxiway(Vector2i(24, 12))
	_expect(_same_angle(grid.stand_park_heading(contact), -PI / 2.0),
		"a contact stand must point its aircraft at the pier, not away from the taxiway")

	# The aircraft parks in the middle of the whole stand, not on the park cell.
	var mid: Vector2 = grid.stand_park_point(contact)
	_expect(mid != grid.cell_to_world(grid.stand_park_cell(contact)),
		"a 2x2 stand must park its aircraft off the park cell, in the middle")
	# ...and NOT on the stand's own centre either. A 2x2 block's middle is a grid
	# line, while taxiway pieces draw their centreline down a cell's middle, so
	# parking there put the lead-in permanently half a tile off the taxiway it
	# joins. The axis is shifted onto a cell centre so the two meet.
	var block: Vector2 = (grid.cell_to_world(Vector2i(22, 12))
		+ grid.cell_to_world(Vector2i(23, 13))) * 0.5
	_expect(mid != block, "the park point must not sit on the grid line between cells")
	_expect(is_equal_approx(mid.distance_to(block), AG.TILE * 0.5),
		"it must be shifted exactly half a tile off the block centre")
	# Only the CROSS axis has to line up — that is the one the lead-in line runs
	# down and the one a taxiway centreline sits on. How deep into the stand the
	# aircraft sits meets nothing, so it is free to stay on a grid line.
	_expect(is_equal_approx(mid.x, grid.cell_to_world(Vector2i(22, 12)).x),
		"the lead-in axis must sit on a column centre, so it meets a centreline")

	# Remote stand: nothing to face, so it points back out along the taxiway.
	var remote = grid.get_stand(grid.place_stand(grid.stand_cells_for(Vector2i(26, 16), 0), 0))
	_expect(is_nan(grid.stand_park_heading(remote)),
		"an unconnected stand must not claim a heading")
	grid.place_taxiway(Vector2i(28, 16))
	_expect(_same_angle(grid.stand_park_heading(remote), PI),
		"a remote stand must point away from its taxiway")


# A stand is a destination, not a through route. Aircraft were taxiing straight
# across rows of stands and from one stand onto the next, because stands were
# left walkable in the A* grid.
func _check_stand_routing(main) -> void:
	var grid = main.grid
	# A taxiway, a stand beside it, and a second taxiway on the far side, so the
	# stand sits on the short route between the two.
	grid.place_taxiway(Vector2i(18, 14))
	grid.place_stand(grid.stand_cells_for(Vector2i(18, 15), 0), 0)
	grid.place_taxiway(Vector2i(18, 17))

	var through: Array = grid.find_path(Vector2i(18, 14), Vector2i(18, 17))
	_expect(not through.has(Vector2i(18, 15)),
		"a route between two taxiways must not cut across the stand between them")

	# ...but the stand itself is still reachable, and still leavable.
	var onto: Array = grid.find_path(Vector2i(18, 14), Vector2i(18, 15))
	_expect(onto.size() >= 2 and onto[onto.size() - 1] == Vector2i(18, 15),
		"an aircraft must still be able to taxi onto its own stand")
	var off: Array = grid.find_path(Vector2i(18, 15), Vector2i(18, 14))
	_expect(off.size() >= 2, "an aircraft must still be able to push back off its stand")

	# Two stands touching: neither may be a doorway to the other.
	grid.place_stand(grid.stand_cells_for(Vector2i(20, 15), 0), 0)
	var hop: Array = grid.find_path(Vector2i(18, 15), Vector2i(20, 15))
	_expect(hop.is_empty(), "there must be no route at all from one stand to another")



func _same_angle(a: float, b: float) -> bool:
	if is_nan(a):
		return false
	return absf(wrapf(a - b, -PI, PI)) < 0.001


# Borrowing has no cursor either, so the balance run never touches it. The
# invariant worth guarding is that cash and debt move together and that the
# reputation-derived ceiling actually holds.
func _check_finance(main) -> void:
	var cash0: int = main.money
	var limit: int = main.credit_limit()
	_expect(limit > 0, "a reputable airport must have credit")

	main.borrow(MainScript.LOAN_STEP)
	_expect(main.loan_principal == MainScript.LOAN_STEP, "borrowing must record the debt")
	_expect(main.money == cash0 + MainScript.LOAN_STEP, "borrowing must deliver the cash")

	# Draw the ceiling down in full, then check it refuses to go past it.
	main.borrow(limit)
	_expect(main.loan_principal == limit, "borrowing must cap at the credit limit")
	main.borrow(MainScript.LOAN_STEP)
	_expect(main.loan_principal == limit, "a full facility must refuse more credit")

	var interest: int = main.daily_interest()
	_expect(interest > 0, "outstanding debt must accrue interest")
	main.end_of_day()

	main.repay(limit)
	_expect(main.loan_principal == 0, "repaying in full must clear the debt")
	main.repay(MainScript.LOAN_STEP)
	_expect(main.loan_principal == 0, "repaying with no debt must be a no-op")
	main.money = cash0


# The tower is the one building the player never places, so nothing else would
# notice if the renderer sited it on top of something or left it standing in a
# taxiway the player laid over it.
func _check_tower(main) -> void:
	var r = main.render3d
	var grid = main.grid
	var AG = load("res://AirportGrid.gd")

	r.set_tower_count(0)
	r.rebuild_if_dirty()
	_expect(r._tower_root.get_child_count() == 0, "no tower until one is commissioned")

	r.set_tower_count(1)
	r.rebuild_if_dirty()
	_expect(r._tower_root.get_child_count() == 1, "a commissioned tower must be built")

	r.set_tower_count(3)
	r.rebuild_if_dirty()
	_expect(r._tower_root.get_child_count() == 1,
		"extra tower units are capacity, not a second building")

	var site: Vector2i = r._tower_site()
	_expect(grid.tile_type(site) == AG.TileType.EMPTY, "the tower must stand on an empty tile")
	_expect(grid.is_buildable(site), "the tower must stand on owned land")

	grid.place_taxiway(site)
	r.mark_layout_dirty()
	r.rebuild_if_dirty()
	var moved: Vector2i = r._tower_site()
	_expect(moved != site, "building over the tower's site must move it")
	_expect(grid.tile_type(moved) == AG.TileType.EMPTY,
		"the relocated tower must still be on an empty tile")


# The HUD is laid out from the live viewport size, so a window the layout has
# never seen is exactly the case that used to break. Drive both extremes.
func _check_layout(main) -> void:
	for size in [Vector2i(1120, 800), Vector2i(2560, 1440), Vector2i(1440, 900)]:
		main.get_window().size = size
		main._layout_ui()
		var vp: Vector2 = main.get_viewport_rect().size
		var log_node = main.log_label
		_expect(log_node.position.x >= 0.0, "log must not start off-screen")
		_expect(log_node.position.y + log_node.size.y <= vp.y + 1.0,
			"log must stay inside the window at %s" % size)
		var route = main.get_node("UI/RoutePanel")
		_expect(route.position.x + route.size.x <= vp.x + 1.0,
			"sidebar must stay inside the window at %s" % size)
		# The regression that prompted this: speed buttons drawn over the sidebar.
		_expect(main.get_node("UI/Speed3Btn").position.y > route.position.y + route.size.y - 1.0,
			"toolbar must clear the sidebar at %s" % size)
		# ...and the one it turned up: route text spilling out of its own panel.
		var active = route.get_node("ActiveLabel")
		_expect(active.position.y + active.size.y <= route.size.y + 1.0,
			"route list must stay inside the route panel at %s" % size)


func _expect(ok: bool, what: String) -> void:
	if not ok:
		push_error("LAND CHECK FAILED: " + what)
		print("LAND CHECK FAILED: ", what)
