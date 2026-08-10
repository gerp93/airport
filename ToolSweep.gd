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
	await get_tree().process_frame
	await get_tree().process_frame

	# Driven off the enum, not a literal: hardcoding the count is how the Buy Land
	# tool would silently drop out of coverage the moment it was added.
	for t in range(MainScript.Tool.size()):
		main.tool = t
		# Several drag targets, so the runway readout's heading maths runs at a
		# range of angles rather than one convenient axis-aligned case.
		for target in [Vector2i(12, 8), Vector2i(20, 14), Vector2i(4, 4), Vector2i(25, 3)]:
			main.hover_cell = target
			main.drag_start = Vector2i(10, 10)
			main.is_dragging = true
			main._update_hud()
			main._update_ops_ui()
			main._sync_world()
			await get_tree().process_frame

		main.is_dragging = false
		main.hover_cell = Vector2i(9, 9)
		main._update_hud()
		main._sync_world()
		await get_tree().process_frame

	_check_land(main)
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


func _expect(ok: bool, what: String) -> void:
	if not ok:
		push_error("LAND CHECK FAILED: " + what)
		print("LAND CHECK FAILED: ", what)
