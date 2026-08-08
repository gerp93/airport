extends Node2D

const RUNWAY_X1 := 60.0
const RUNWAY_X2 := 900.0
const TAXI_X := RUNWAY_X1 + 260.0
const RUNWAY_Y_SLOTS := [300.0, 380.0, 460.0]
const GATE_SLOTS := [
	Vector2(580, 120), Vector2(660, 120), Vector2(740, 120),
	Vector2(580, 175), Vector2(660, 175), Vector2(740, 175),
]
const GATE_W := 60.0
const GATE_H := 40.0
const TERMINAL := Rect2(560, 90, 260, 145)
const AIRLINES := ["SkyNorth", "BlueWing", "CoastAir", "PineJet", "Vantage"]
const MAX_GATES := 6
const MAX_RUNWAYS := 3

var money := 300
var reputation := 100
var time_elapsed := 0.0
var next_spawn_at := 3.0
var plane_id_seq := 1
var selected_plane_id = null

var runways: Array = []
var gates: Array = []
var planes: Array = []
var log_lines: Array = []

@onready var money_label: Label = $UI/MoneyLabel
@onready var rep_label: Label = $UI/RepLabel
@onready var next_in_label: Label = $UI/NextInLabel
@onready var build_gate_btn: Button = $UI/BuildGateBtn
@onready var build_runway_btn: Button = $UI/BuildRunwayBtn
@onready var log_label: RichTextLabel = $UI/LogLabel


func _ready() -> void:
	randomize()
	runways.append({"id": 0, "y": RUNWAY_Y_SLOTS[0], "occupied": false})
	for i in range(3):
		gates.append({
			"id": i, "x": GATE_SLOTS[i].x, "y": GATE_SLOTS[i].y,
			"w": GATE_W, "h": GATE_H, "occupied": false,
		})
	build_gate_btn.pressed.connect(_on_build_gate_pressed)
	build_runway_btn.pressed.connect(_on_build_runway_pressed)
	add_log("Demo started. Watch for inbound flights.")


func gate_cost() -> int:
	return 250 + 150 * (gates.size() - 3)


func runway_cost() -> int:
	return 500 + 350 * (runways.size() - 1)


func add_log(msg: String) -> void:
	var t := "%.1f" % time_elapsed
	log_lines.push_front("[%ss] %s" % [t, msg])
	if log_lines.size() > 40:
		log_lines.resize(40)
	log_label.text = "\n".join(log_lines)


func _on_build_gate_pressed() -> void:
	if gates.size() >= MAX_GATES:
		return
	var cost := gate_cost()
	if money < cost:
		return
	money -= cost
	var slot: Vector2 = GATE_SLOTS[gates.size()]
	gates.append({
		"id": gates.size(), "x": slot.x, "y": slot.y,
		"w": GATE_W, "h": GATE_H, "occupied": false,
	})
	add_log("Built Gate %d for $%d." % [gates.size(), cost])


func _on_build_runway_pressed() -> void:
	if runways.size() >= MAX_RUNWAYS:
		return
	var cost := runway_cost()
	if money < cost:
		return
	money -= cost
	var y: float = RUNWAY_Y_SLOTS[runways.size()]
	runways.append({"id": runways.size(), "y": y, "occupied": false})
	add_log("Built Runway %d for $%d." % [runways.size(), cost])


func spawn_plane() -> void:
	var airline: String = AIRLINES[randi() % AIRLINES.size()]
	var payout := 80 + randi() % 120
	var plane := {
		"id": plane_id_seq, "airline": airline, "payout": payout,
		"state": "AIR_HOLD", "x": -40.0, "y": 40.0,
		"runway": null, "gate": null,
		"hold_timer": 0.0, "air_hold_timer": 0.0,
		"max_hold": 18.0, "max_air_hold": 25.0,
		"state_timer": 0.0, "turnaround": 6.0,
	}
	plane_id_seq += 1
	planes.append(plane)
	add_log("%s flight inbound (contract $%d)." % [airline, payout])


func assign_gate(plane: Dictionary, gate: Dictionary) -> void:
	gate["occupied"] = true
	plane["gate"] = gate
	plane["state"] = "TAXI_TO_GATE"
	plane["state_timer"] = 0.0
	add_log("%s assigned to Gate %d." % [plane["airline"], gate["id"] + 1])


func find_free_runway_index() -> int:
	for i in range(runways.size()):
		if not runways[i]["occupied"]:
			return i
	return -1


func find_free_gate_index() -> int:
	for i in range(gates.size()):
		if not gates[i]["occupied"]:
			return i
	return -1


func update_plane(p: Dictionary, dt: float) -> void:
	p["state_timer"] += dt

	match p["state"]:
		"AIR_HOLD":
			p["air_hold_timer"] += dt
			p["x"] = 40.0 + sin(p["air_hold_timer"] * 1.5) * 20.0
			p["y"] = 40.0 + cos(p["air_hold_timer"] * 1.5) * 15.0
			var runway_idx = find_free_runway_index()
			if runway_idx != -1:
				var free_runway: Dictionary = runways[runway_idx]
				free_runway["occupied"] = true
				p["runway"] = free_runway
				p["state"] = "INBOUND"
				p["state_timer"] = 0.0
			elif p["air_hold_timer"] >= p["max_air_hold"]:
				reputation = max(0, reputation - 15)
				add_log("%s DIVERTED — no runway available. Reputation -15." % p["airline"])
				p["state"] = "REMOVE"

		"INBOUND":
			var t = min(p["state_timer"] / 4.0, 1.0)
			p["x"] = lerp(-40.0, RUNWAY_X1, t)
			p["y"] = p["runway"]["y"]
			if t >= 1.0:
				p["state"] = "LANDING"
				p["state_timer"] = 0.0
				add_log("%s touching down on Runway %d." % [p["airline"], p["runway"]["id"] + 1])

		"LANDING":
			var t = min(p["state_timer"] / 3.0, 1.0)
			p["x"] = lerp(RUNWAY_X1, TAXI_X, t)
			p["y"] = p["runway"]["y"]
			if t >= 1.0:
				p["runway"]["occupied"] = false
				p["state"] = "SEEK_GATE"
				p["state_timer"] = 0.0

		"SEEK_GATE":
			var gate_idx = find_free_gate_index()
			if gate_idx != -1:
				assign_gate(p, gates[gate_idx])
			else:
				p["state"] = "HOLDING"
				p["hold_timer"] = 0.0
				add_log("%s holding — no free gate." % p["airline"])

		"HOLDING":
			p["hold_timer"] += dt
			p["x"] = TAXI_X + sin(p["hold_timer"] * 2.0) * 6.0
			p["y"] = p["runway"]["y"]
			if p["hold_timer"] >= p["max_hold"]:
				reputation = max(0, reputation - 10)
				add_log("%s DIVERTED — too long without a gate. Reputation -10." % p["airline"])
				p["state"] = "REMOVE"

		"TAXI_TO_GATE":
			var start_x = TAXI_X
			var start_y = p["runway"]["y"]
			var end_x = p["gate"]["x"] + p["gate"]["w"] / 2.0
			var end_y = p["gate"]["y"] + p["gate"]["h"] + 10.0
			var t = min(p["state_timer"] / 3.0, 1.0)
			p["x"] = lerp(start_x, end_x, t)
			p["y"] = lerp(start_y, end_y, t)
			if t >= 1.0:
				p["state"] = "AT_GATE"
				p["state_timer"] = 0.0
				add_log("%s at Gate %d, turning around." % [p["airline"], p["gate"]["id"] + 1])

		"AT_GATE":
			if p["state_timer"] >= p["turnaround"]:
				money += p["payout"]
				add_log("%s turnaround complete. +$%d" % [p["airline"], p["payout"]])
				p["state"] = "TAXI_OUT"
				p["state_timer"] = 0.0

		"TAXI_OUT":
			var start_x = p["gate"]["x"] + p["gate"]["w"] / 2.0
			var start_y = p["gate"]["y"] + p["gate"]["h"] + 10.0
			var end_x = TAXI_X
			var end_y = p["runway"]["y"]
			var t = min(p["state_timer"] / 3.0, 1.0)
			p["x"] = lerp(start_x, end_x, t)
			p["y"] = lerp(start_y, end_y, t)
			if t >= 1.0:
				p["gate"]["occupied"] = false
				p["gate"] = null
				p["state"] = "DEPARTING"
				p["state_timer"] = 0.0

		"DEPARTING":
			var t = min(p["state_timer"] / 3.0, 1.0)
			p["x"] = lerp(TAXI_X, 1000.0, t)
			p["y"] = p["runway"]["y"]
			if t >= 1.0:
				add_log("%s departed." % p["airline"])
				p["state"] = "REMOVE"


func _process(delta: float) -> void:
	time_elapsed += delta

	if time_elapsed >= next_spawn_at:
		spawn_plane()
		var tightness = max(0.0, 1.0 - time_elapsed / 180.0)
		var min_gap = 3.0 + 3.0 * tightness
		var max_gap = 6.0 + 4.0 * tightness
		next_spawn_at = time_elapsed + min_gap + randf() * (max_gap - min_gap)

	for p in planes:
		update_plane(p, delta)
	planes = planes.filter(func(p): return p["state"] != "REMOVE")

	money_label.text = "Money: $%d" % money
	rep_label.text = "Reputation: %d" % reputation
	next_in_label.text = "Next contract in: %.1fs" % max(0.0, next_spawn_at - time_elapsed)

	if gates.size() >= MAX_GATES:
		build_gate_btn.text = "Build Gate (MAX)"
	else:
		build_gate_btn.text = "Build Gate ($%d)" % gate_cost()
	build_gate_btn.disabled = gates.size() >= MAX_GATES or money < gate_cost()

	if runways.size() >= MAX_RUNWAYS:
		build_runway_btn.text = "Build Runway (MAX)"
	else:
		build_runway_btn.text = "Build Runway ($%d)" % runway_cost()
	build_runway_btn.disabled = runways.size() >= MAX_RUNWAYS or money < runway_cost()

	queue_redraw()


func _draw() -> void:
	draw_rect(Rect2(0, 0, 960, 600), Color(0.227, 0.361, 0.227), true)

	for r in runways:
		draw_rect(Rect2(RUNWAY_X1 - 10, r["y"] - 18, (RUNWAY_X2 - RUNWAY_X1) + 20, 36), Color(0.33, 0.33, 0.33), true)
		draw_dashed_line(Vector2(RUNWAY_X1, r["y"]), Vector2(RUNWAY_X2, r["y"]), Color(0.87, 0.87, 0.87), 2.0, 14.0)
		var col = Color(0.95, 0.55, 0.42) if r["occupied"] else Color(0.81, 0.91, 0.81)
		draw_string(ThemeDB.fallback_font, Vector2(RUNWAY_X1 - 5, r["y"] - 22), "RWY %d" % (r["id"] + 1), HORIZONTAL_ALIGNMENT_LEFT, -1, 12, col)

	var lowest_runway_y = runways[runways.size() - 1]["y"]
	draw_rect(Rect2(TAXI_X - 10, 130, 20, lowest_runway_y - 130), Color(0.4, 0.4, 0.4), true)

	draw_rect(TERMINAL, Color(0.49, 0.49, 0.54), true)
	draw_string(ThemeDB.fallback_font, Vector2(TERMINAL.position.x + TERMINAL.size.x / 2.0 - 28, TERMINAL.position.y + 14), "TERMINAL", HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color(0.87, 0.87, 0.87))

	for g in gates:
		var fill = Color(0.75, 0.32, 0.25) if g["occupied"] else Color(0.18, 0.42, 0.18)
		var outline = Color(1.0, 0.7, 0.63) if g["occupied"] else Color(0.61, 0.91, 0.61)
		draw_rect(Rect2(g["x"], g["y"], g["w"], g["h"]), fill, true)
		draw_rect(Rect2(g["x"], g["y"], g["w"], g["h"]), outline, false, 2.0)
		draw_string(ThemeDB.fallback_font, Vector2(g["x"] + g["w"] / 2.0 - 10, g["y"] + g["h"] / 2.0 + 4), "G%d" % (g["id"] + 1), HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color(0.07, 0.07, 0.07))

	for p in planes:
		var color = Color(0.91, 0.91, 0.91)
		if p["state"] == "AIR_HOLD":
			color = Color(0.96, 0.65, 0.26)
		if p["state"] == "HOLDING":
			color = Color(0.96, 0.83, 0.26)
		if p["state"] == "AT_GATE":
			color = Color(0.26, 0.77, 0.96)
		if selected_plane_id == p["id"]:
			color = Color(1.0, 0.37, 0.82)

		var px = p["x"]
		var py = p["y"]
		var points = PackedVector2Array([
			Vector2(px + 14, py),
			Vector2(px - 10, py - 8),
			Vector2(px - 10, py + 8),
		])
		draw_colored_polygon(points, color)

		var label = p["airline"]
		if p["state"] == "HOLDING":
			label += " (HOLDING)"
		if p["state"] == "AIR_HOLD":
			label += " (circling)"
		draw_string(ThemeDB.fallback_font, Vector2(px - 20, py - 14), label, HORIZONTAL_ALIGNMENT_LEFT, -1, 10, Color(1, 1, 1))


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		var mx = event.position.x
		var my = event.position.y

		for p in planes:
			if p["state"] == "HOLDING":
				var dx = mx - p["x"]
				var dy = my - p["y"]
				if dx * dx + dy * dy < 20.0 * 20.0:
					selected_plane_id = p["id"]
					add_log("Selected %s (holding)." % p["airline"])
					return

		for g in gates:
			if mx >= g["x"] and mx <= g["x"] + g["w"] and my >= g["y"] and my <= g["y"] + g["h"]:
				if g["occupied"]:
					add_log("Gate %d is occupied." % (g["id"] + 1))
					return
				if selected_plane_id == null:
					add_log("Select a holding plane first.")
					return
				var found = null
				for p in planes:
					if p["id"] == selected_plane_id and p["state"] == "HOLDING":
						found = p
						break
				if found != null:
					assign_gate(found, g)
					selected_plane_id = null
				else:
					add_log("Selected plane is no longer holding.")
					selected_plane_id = null
				return
