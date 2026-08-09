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

func _ready() -> void:
	var main = preload("res://Main.tscn").instantiate()
	add_child(main)
	await get_tree().process_frame
	await get_tree().process_frame

	for t in range(0, 9):
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

	print("tool sweep complete")
	get_tree().quit()
