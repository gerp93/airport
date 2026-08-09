extends Node2D

const AirportGrid = preload("res://AirportGrid.gd")

enum Tool { SELECT, TAXIWAY, RUNWAY, GATE_SMALL, GATE_LARGE, DEMOLISH }

const TOOL_BUTTONS := {
	Tool.SELECT: "SelectBtn", Tool.TAXIWAY: "TaxiwayBtn", Tool.RUNWAY: "RunwayBtn",
	Tool.GATE_SMALL: "GateSmallBtn", Tool.GATE_LARGE: "GateLargeBtn",
	Tool.DEMOLISH: "DemolishBtn",
}
const TOOL_KEYS := {
	KEY_ESCAPE: Tool.SELECT, KEY_T: Tool.TAXIWAY, KEY_R: Tool.RUNWAY,
	KEY_G: Tool.GATE_SMALL, KEY_H: Tool.GATE_LARGE, KEY_X: Tool.DEMOLISH,
}

const AIRLINES := ["SkyNorth", "BlueWing", "CoastAir", "PineJet", "Vantage"]

# Bigger aircraft pay much better but demand a longer runway and a wider stand,
# so the fleet mix is what pushes the player to keep investing in the layout.
const CLASSES := [
	{
		"name": "Light", "code": "L", "min_runway": 6, "gate_size": 1,
		"pay_min": 55, "pay_max": 95, "turnaround": 4.0, "scale": 0.7,
	},
	{
		"name": "Narrowbody", "code": "N", "min_runway": 12, "gate_size": 1,
		"pay_min": 150, "pay_max": 240, "turnaround": 8.0, "scale": 1.0,
	},
	{
		"name": "Widebody", "code": "W", "min_runway": 18, "gate_size": 2,
		"pay_min": 330, "pay_max": 480, "turnaround": 13.0, "scale": 1.35,
	},
]

const COST_TAXIWAY := 15
const COST_RUNWAY_TILE := 40
const COST_GATE_TILE := 250
const REFUND_RATE := 0.5
const TOW_FEE := 60

const TAXI_SPEED := 60.0
const ROLLOUT_SPEED := 170.0
const TAKEOFF_SPEED := 200.0
const FLY_SPEED := 220.0

const REPATH_INTERVAL := 1.5
const MAX_BLOCK_TIME := 20.0
# Reputation has to be recoverable, or the game is just a countdown to losing.
const REP_PER_TURNAROUND := 1
const REP_MAX := 100

const MAX_CONTRACTS := 2
# Signed contracts generate their own traffic, so taking one you can't handle
# actively floods the airport instead of just sitting in a list.
const CONTRACT_TRAFFIC_SHARE := 0.6

const SPAWN_POS := Vector2(-60.0, 150.0)
const AIR_ANCHOR := Vector2(110.0, 160.0)

var grid: AirportGrid
var money := 300
var reputation := 100
var game_over := false
var served := 0
var diverted := 0
var earned := 0
var time_elapsed := 0.0
var next_spawn_at := 5.0
var plane_id_seq := 1
var planes: Array = []
var log_lines: Array = []

var paused := false
var speed := 1.0
# Test affordances for headless balance runs: --headless ... -- --echo-log --auto-sign
var _echo_log := false
var _auto_sign := false

var offer = null
var contracts: Array = []
var next_offer_at := 25.0

var selected_plane_id := -1
var tool: Tool = Tool.SELECT
var hover_cell := AirportGrid.NOWHERE
var drag_start := AirportGrid.NOWHERE
var is_dragging := false

@onready var money_label: Label = $UI/MoneyLabel
@onready var rep_label: Label = $UI/RepLabel
@onready var next_in_label: Label = $UI/NextInLabel
@onready var stats_label: Label = $UI/StatsLabel
@onready var hint_label: Label = $UI/HintLabel
@onready var tool_info_label: Label = $UI/ToolInfoLabel
@onready var log_label: RichTextLabel = $UI/LogLabel


func _ready() -> void:
	randomize()
	var args := OS.get_cmdline_user_args()
	_echo_log = "--echo-log" in args
	_auto_sign = "--auto-sign" in args
	grid = AirportGrid.new()
	grid.seed_starter_airport()

	$UI/SelectBtn.pressed.connect(_set_tool.bind(Tool.SELECT))
	$UI/TaxiwayBtn.pressed.connect(_set_tool.bind(Tool.TAXIWAY))
	$UI/RunwayBtn.pressed.connect(_set_tool.bind(Tool.RUNWAY))
	$UI/GateSmallBtn.pressed.connect(_set_tool.bind(Tool.GATE_SMALL))
	$UI/GateLargeBtn.pressed.connect(_set_tool.bind(Tool.GATE_LARGE))
	$UI/DemolishBtn.pressed.connect(_set_tool.bind(Tool.DEMOLISH))

	$UI/PauseBtn.toggled.connect(_on_pause_toggled)
	$UI/Speed1Btn.pressed.connect(_set_speed.bind(1.0))
	$UI/Speed2Btn.pressed.connect(_set_speed.bind(2.0))
	$UI/Speed3Btn.pressed.connect(_set_speed.bind(4.0))
	$UI/GameOverPanel/RestartBtn.pressed.connect(func(): get_tree().reload_current_scene())
	$UI/ContractPanel/AcceptBtn.pressed.connect(accept_offer)
	$UI/ContractPanel/DeclineBtn.pressed.connect(decline_offer)

	add_log("Airport open. Build taxiways to connect runways and gates.")


func _on_pause_toggled(on: bool) -> void:
	paused = on
	$UI/PauseBtn.text = "Resume" if on else "Pause"


func _set_speed(s: float) -> void:
	speed = s
	if paused:
		$UI/PauseBtn.button_pressed = false


# Keyboard shortcuts drive the same buttons the mouse does, so the toolbar always
# shows the real state.
func _choose_speed(s: float) -> void:
	_set_speed(s)
	var btn := "Speed1Btn"
	if is_equal_approx(s, 2.0):
		btn = "Speed2Btn"
	elif is_equal_approx(s, 4.0):
		btn = "Speed3Btn"
	get_node("UI/" + btn).button_pressed = true


func _choose_tool(t: Tool) -> void:
	_set_tool(t)
	get_node("UI/" + TOOL_BUTTONS[t]).button_pressed = true


func _set_tool(t: Tool) -> void:
	tool = t
	is_dragging = false
	if t != Tool.SELECT:
		selected_plane_id = -1


func add_log(msg: String) -> void:
	log_lines.push_front("[%.1fs] %s" % [time_elapsed, msg])
	if log_lines.size() > 40:
		log_lines.resize(40)
	log_label.text = "\n".join(log_lines)
	if _echo_log:
		print(log_lines[0])


func find_plane(id: int) -> Variant:
	for p in planes:
		if p["id"] == id:
			return p
	return null


# --- spawning ---

# Light aircraft dominate early, narrowbodies phase in, widebodies arrive late.
func pick_size() -> int:
	# Narrowbodies taper off late so widebodies actually take over the schedule
	# rather than just being sprinkled on top of it.
	var narrow_decline := clampf(1.0 - (time_elapsed - 300.0) / 300.0, 0.35, 1.0)
	var weights: Array[float] = [
		max(0.15, 1.0 - time_elapsed / 200.0),
		clamp((time_elapsed - 60.0) / 120.0, 0.0, 1.0) * narrow_decline,
		clamp((time_elapsed - 240.0) / 180.0, 0.0, 1.0),
	]
	var roll := randf() * (weights[0] + weights[1] + weights[2])
	for i in weights.size():
		roll -= weights[i]
		if roll <= 0.0:
			return i
	return 0


# --- contracts ---

func can_handle_class(size: int) -> bool:
	var need: Dictionary = CLASSES[size]
	var runway_ok := false
	for r in grid.runways:
		if grid.runway_is_usable(r) and r["cells"].size() >= need["min_runway"]:
			runway_ok = true
			break
	if not runway_ok:
		return false
	for g in grid.gates:
		if grid.gate_is_connected(g) and g["size"] >= need["gate_size"]:
			return true
	return false


func make_offer() -> Dictionary:
	var size := pick_size()
	var count := 3 + randi() % 4
	var cls: Dictionary = CLASSES[size]
	var per: int = (cls["pay_min"] + cls["pay_max"]) / 2
	return {
		"airline": AIRLINES[randi() % AIRLINES.size()],
		"size": size, "count": count, "progress": 0,
		"reward": int(per * count * 0.6),
		"penalty": 8 + count * 2,
		"duration": 70.0 + count * 28.0,
		"deadline": 0.0,
	}


func accept_offer() -> void:
	if offer == null or contracts.size() >= MAX_CONTRACTS:
		return
	offer["deadline"] = time_elapsed + offer["duration"]
	contracts.append(offer)
	add_log("Signed %s: %d %s flights in %ds for $%d." % [
		offer["airline"], offer["count"], CLASSES[offer["size"]]["name"],
		int(offer["duration"]), offer["reward"],
	])
	offer = null
	next_offer_at = time_elapsed + 45.0 + randf() * 30.0


func decline_offer() -> void:
	if offer == null:
		return
	add_log("Passed on the %s contract." % offer["airline"])
	offer = null
	next_offer_at = time_elapsed + 25.0 + randf() * 20.0


func contract_needing_traffic() -> Variant:
	for c in contracts:
		if c["progress"] < c["count"]:
			return c
	return null


func credit_contracts(p: Dictionary) -> void:
	for c in contracts:
		if c["airline"] == p["airline"] and c["size"] == p["size"] and c["progress"] < c["count"]:
			c["progress"] += 1
			if c["progress"] >= c["count"]:
				money += c["reward"]
				earned += c["reward"]
				reputation = min(REP_MAX, reputation + 5)
				add_log("CONTRACT COMPLETE — %s. +$%d, Reputation +5." % [c["airline"], c["reward"]])
			return


func update_contracts() -> void:
	for c in contracts:
		if c["progress"] < c["count"] and time_elapsed >= c["deadline"]:
			reputation = max(0, reputation - c["penalty"])
			add_log("CONTRACT FAILED — %s, %d of %d flights. Reputation -%d." % [
				c["airline"], c["progress"], c["count"], c["penalty"],
			])
			c["progress"] = -1
	contracts = contracts.filter(func(c): return c["progress"] >= 0 and c["progress"] < c["count"])

	if offer == null and contracts.size() < MAX_CONTRACTS and time_elapsed >= next_offer_at:
		offer = make_offer()
		add_log("%s is offering a contract." % offer["airline"])
		if _auto_sign:
			if can_handle_class(offer["size"]):
				accept_offer()
			else:
				decline_offer()


func spawn_plane() -> void:
	var airline: String = AIRLINES[randi() % AIRLINES.size()]
	var size := pick_size()
	var contract = contract_needing_traffic()
	if contract != null and randf() < CONTRACT_TRAFFIC_SHARE:
		airline = contract["airline"]
		size = contract["size"]
	var cls: Dictionary = CLASSES[size]
	var payout: int = cls["pay_min"] + randi() % (cls["pay_max"] - cls["pay_min"] + 1)
	var callsign := "%s %d" % [airline, plane_id_seq]
	planes.append({
		"id": plane_id_seq, "airline": airline, "payout": payout,
		"size": size, "callsign": callsign,
		"state": "AIR_HOLD",
		"pos": SPAWN_POS, "heading": 0.0,
		"cell": AirportGrid.NOWHERE,
		"runway_id": -1, "gate_id": -1,
		"path": [], "path_index": 0,
		"air_hold_timer": 0.0, "max_air_hold": 25.0,
		"hold_timer": 0.0, "max_hold": 18.0,
		"blocked_timer": 0.0, "repath_timer": 0.0,
		"state_timer": 0.0, "turnaround": cls["turnaround"],
		# Each aircraft gets its own hold pattern so a stack of waiting traffic
		# doesn't collapse into one unreadable blob.
		"orbit_phase": randf() * TAU, "orbit_radius": 26.0 + randf() * 26.0,
	})
	add_log("%s inbound — %s, contract $%d." % [callsign, cls["name"], payout])
	plane_id_seq += 1


# --- movement primitives ---

func move_toward_point(p: Dictionary, target: Vector2, speed: float, dt: float) -> bool:
	var delta: Vector2 = target - p["pos"]
	var dist := delta.length()
	if dist < 0.5:
		p["pos"] = target
		return true
	p["heading"] = delta.angle()
	var step := speed * dt
	if step >= dist:
		p["pos"] = target
		return true
	p["pos"] = p["pos"] + delta / dist * step
	return false


func set_path(p: Dictionary, path: Array) -> void:
	p["path"] = path
	p["path_index"] = 1 if not path.is_empty() and path[0] == p["cell"] else 0
	p["blocked_timer"] = 0.0
	p["repath_timer"] = 0.0


func path_destination(p: Dictionary) -> Vector2i:
	if p["path"].is_empty():
		return AirportGrid.NOWHERE
	return p["path"][p["path"].size() - 1]


# "arrived" | "moving" | "blocked" | "lost"
func advance_along_path(p: Dictionary, speed: float, dt: float) -> String:
	if p["path_index"] >= p["path"].size():
		return "arrived"
	var next_cell: Vector2i = p["path"][p["path_index"]]
	if not grid.is_navigable(next_cell):
		return "lost"
	if not grid.try_claim(next_cell, p["id"]):
		return "blocked"

	if move_toward_point(p, grid.cell_to_world(next_cell), speed, dt):
		if p["cell"] != next_cell and p["cell"] != AirportGrid.NOWHERE:
			grid.release(p["cell"], p["id"])
		p["cell"] = next_cell
		p["path_index"] += 1
		if p["path_index"] >= p["path"].size():
			return "arrived"
	return "moving"


func taxi_priority(p: Dictionary) -> int:
	return 1 if p["state"] == "TAXI_TO_GATE" else 0


func yields_to(p: Dictionary, other: Dictionary) -> bool:
	var mine := taxi_priority(p)
	var theirs := taxi_priority(other)
	if mine != theirs:
		return mine < theirs
	return p["id"] > other["id"]


# Escalating deadlock handling. Returns true when the plane has been stuck long
# enough that the caller should give up on it.
func handle_blocked(p: Dictionary, dt: float) -> bool:
	p["blocked_timer"] += dt
	p["repath_timer"] += dt

	var next_cell: Vector2i = p["path"][p["path_index"]]
	var blocker = find_plane(grid.claim_owner(next_cell))
	var head_on := false
	if blocker != null and blocker["path_index"] < blocker["path"].size():
		head_on = blocker["path"][blocker["path_index"]] == p["cell"]

	var must_yield: bool = head_on and blocker != null and yields_to(p, blocker)
	if must_yield or p["repath_timer"] >= REPATH_INTERVAL:
		p["repath_timer"] = 0.0
		var dest := path_destination(p)
		var alt := grid.find_path_avoiding_claims(p["cell"], dest, p["id"])
		if alt.size() > 1:
			set_path(p, alt)
			return false

	return p["blocked_timer"] >= MAX_BLOCK_TIME


# --- teardown ---

func release_plane(p: Dictionary) -> void:
	grid.release_all(p["id"])
	if p["gate_id"] != -1:
		var g = grid.get_gate(p["gate_id"])
		if g != null:
			g["occupied"] = false
		p["gate_id"] = -1
	if p["runway_id"] != -1:
		var r = grid.get_runway(p["runway_id"])
		if r != null:
			r["occupied"] = false
		p["runway_id"] = -1
	p["state"] = "REMOVE"
	if selected_plane_id == p["id"]:
		selected_plane_id = -1


func divert(p: Dictionary, reason: String, rep_cost: int) -> void:
	reputation = max(0, reputation - rep_cost)
	diverted += 1
	add_log("%s DIVERTED — %s. Reputation -%d." % [p["callsign"], reason, rep_cost])
	release_plane(p)


# --- gate / runway acquisition ---

func class_of(p: Dictionary) -> Dictionary:
	return CLASSES[p["size"]]


func runway_fits(r: Dictionary, p: Dictionary) -> bool:
	return r["cells"].size() >= class_of(p)["min_runway"]


func gate_fits(g: Dictionary, p: Dictionary) -> bool:
	return g["size"] >= class_of(p)["gate_size"]


func any_runway_fits(p: Dictionary) -> bool:
	for r in grid.runways:
		if grid.runway_is_usable(r) and runway_fits(r, p):
			return true
	return false


func any_gate_fits(p: Dictionary) -> bool:
	for g in grid.gates:
		if grid.gate_is_connected(g) and gate_fits(g, p):
			return true
	return false


func compatible_free_gates(p: Dictionary) -> Array:
	var out := []
	for g in grid.usable_free_gates():
		if gate_fits(g, p):
			out.append(g)
	return out


func try_assign_gate(p: Dictionary) -> bool:
	var best_path: Array = []
	var best_gate = null
	for g in compatible_free_gates(p):
		var path := grid.find_path(p["cell"], grid.gate_park_cell(g))
		if path.is_empty():
			continue
		if best_path.is_empty() or path.size() < best_path.size():
			best_path = path
			best_gate = g
	if best_gate == null:
		return false

	best_gate["occupied"] = true
	p["gate_id"] = best_gate["id"]
	set_path(p, best_path)
	p["state"] = "TAXI_TO_GATE"
	p["state_timer"] = 0.0
	add_log("%s cleared to Gate %d." % [p["callsign"], best_gate["id"] + 1])
	return true


func assign_gate_manual(p: Dictionary, gate: Dictionary) -> void:
	if not gate_fits(gate, p):
		add_log("Gate %d is too small for a %s." % [gate["id"] + 1, class_of(p)["name"].to_lower()])
		return
	var path := grid.find_path(p["cell"], grid.gate_park_cell(gate))
	if path.is_empty():
		add_log("No taxi route from %s to Gate %d." % [p["callsign"], gate["id"] + 1])
		return
	gate["occupied"] = true
	p["gate_id"] = gate["id"]
	set_path(p, path)
	p["state"] = "TAXI_TO_GATE"
	p["state_timer"] = 0.0
	add_log("%s assigned to Gate %d." % [p["callsign"], gate["id"] + 1])


func runway_has_waiting_departure(runway_id: int) -> bool:
	for p in planes:
		if p["state"] == "HOLD_SHORT" and p["runway_id"] == runway_id:
			return true
	return false


# Arrivals must not starve departures: a plane already holding short goes first,
# otherwise a steady arrival stream traps outbound traffic until it gets towed.
func find_arrival_runway(p: Dictionary) -> Variant:
	for r in grid.runways:
		if not runway_fits(r, p):
			continue
		if grid.runway_is_clear(r) and not runway_has_waiting_departure(r["id"]):
			return r
	return null


func find_departure_runway(p: Dictionary) -> Dictionary:
	for r in grid.runways:
		if not grid.runway_is_usable(r) or not runway_fits(r, p):
			continue
		var target: Vector2i = grid.runway_hold_short_cell(r)
		if target == AirportGrid.NOWHERE:
			# Nothing beside the threshold to wait on, so the plane has to
			# occupy the runway itself — only worth starting if it's clear.
			if not grid.runway_is_clear(r):
				continue
			target = grid.runway_threshold(r)
		var path := grid.find_path(p["cell"], target)
		if not path.is_empty():
			return {"runway": r, "path": path}
	return {}


func tow(p: Dictionary, reason: String) -> void:
	money = max(0, money - TOW_FEE)
	reputation = max(0, reputation - 5)
	add_log("%s %s — towed off. -$%d, Reputation -5." % [p["callsign"], reason, TOW_FEE])
	release_plane(p)


# --- per-plane state machine ---

func update_plane(p: Dictionary, dt: float) -> void:
	p["state_timer"] += dt

	match p["state"]:
		"AIR_HOLD":
			p["air_hold_timer"] += dt
			var t: float = p["air_hold_timer"] * 1.2 + p["orbit_phase"]
			var r: float = p["orbit_radius"]
			var orbit := AIR_ANCHOR + Vector2(sin(t) * r, cos(t) * r * 0.6)
			p["heading"] = (orbit - p["pos"]).angle()
			p["pos"] = p["pos"].move_toward(orbit, FLY_SPEED * dt)

			var runway = find_arrival_runway(p)
			# Never clear a landing we can't park — a plane that has already
			# touched down has nowhere to go, so the stand check belongs here.
			if runway != null and any_gate_fits(p):
				runway["occupied"] = true
				p["runway_id"] = runway["id"]
				p["state"] = "APPROACH"
				p["state_timer"] = 0.0
			elif p["air_hold_timer"] >= p["max_air_hold"]:
				var reason := "all runways busy"
				if not grid.has_usable_runway():
					reason = "no usable runway"
				elif not any_runway_fits(p):
					reason = "no runway long enough for a %s (needs %d tiles)" % [
						class_of(p)["name"].to_lower(), class_of(p)["min_runway"],
					]
				elif not any_gate_fits(p):
					reason = "no stand big enough for a %s" % class_of(p)["name"].to_lower()
				divert(p, reason, 15)

		"APPROACH":
			var runway = grid.get_runway(p["runway_id"])
			if runway == null:
				divert(p, "runway removed on approach", 15)
				return
			# Line up behind the threshold so the plane arrives along the runway
			# axis instead of turning 90 degrees on touchdown.
			var lineup: Vector2 = grid.cell_to_world(grid.runway_threshold(runway)) \
				- grid.runway_direction(runway) * 220.0
			if move_toward_point(p, lineup, FLY_SPEED, dt):
				p["state"] = "INBOUND"
				p["state_timer"] = 0.0

		"INBOUND":
			var runway = grid.get_runway(p["runway_id"])
			if runway == null:
				divert(p, "runway removed on approach", 15)
				return
			var threshold: Vector2i = grid.runway_threshold(runway)
			if move_toward_point(p, grid.cell_to_world(threshold), FLY_SPEED, dt):
				grid.try_claim(threshold, p["id"])
				p["cell"] = threshold
				var exit_cell: Vector2i = grid.runway_exit_cell(runway)
				var cells: Array = runway["cells"]
				set_path(p, cells.slice(0, cells.find(exit_cell) + 1))
				p["state"] = "LANDING"
				p["state_timer"] = 0.0
				add_log("%s touching down on Runway %d." % [p["callsign"], runway["id"] + 1])

		"LANDING":
			match advance_along_path(p, ROLLOUT_SPEED, dt):
				"arrived":
					var runway = grid.get_runway(p["runway_id"])
					if runway != null:
						runway["occupied"] = false
					p["runway_id"] = -1
					p["state"] = "SEEK_GATE"
					p["state_timer"] = 0.0
				"blocked":
					p["blocked_timer"] += dt
					if p["blocked_timer"] >= MAX_BLOCK_TIME:
						divert(p, "runway exit blocked", 15)
				"lost":
					divert(p, "runway removed while landing", 15)

		"SEEK_GATE":
			if try_assign_gate(p):
				return
			if not any_gate_fits(p):
				# Only reachable if the last compatible stand was demolished
				# mid-approach; AIR_HOLD screens this case before clearing.
				divert(p, "its stand was removed on approach", 10)
			elif compatible_free_gates(p).is_empty():
				p["state"] = "HOLDING"
				p["hold_timer"] = 0.0
				set_path(p, [])
				add_log("%s holding — no free stand." % p["callsign"])
			else:
				divert(p, "no taxi route to any stand", 10)

		"HOLDING":
			p["hold_timer"] += dt
			if try_assign_gate(p):
				return
			if p["path_index"] < p["path"].size():
				advance_along_path(p, TAXI_SPEED, dt)
			elif p["path"].is_empty():
				var spot: Vector2i = grid.nearest_free_taxiway(p["cell"], p["id"])
				if spot != AirportGrid.NOWHERE:
					var path := grid.find_path(p["cell"], spot)
					if path.size() > 1:
						set_path(p, path)
			if p["hold_timer"] >= p["max_hold"]:
				divert(p, "too long without a gate", 10)

		"TAXI_TO_GATE":
			match advance_along_path(p, TAXI_SPEED, dt):
				"arrived":
					p["state"] = "AT_GATE"
					p["state_timer"] = 0.0
					add_log("%s at Gate %d, turning around." % [p["callsign"], p["gate_id"] + 1])
				"blocked":
					if handle_blocked(p, dt):
						divert(p, "gridlocked on the taxiway", 10)
				"lost":
					var gate = grid.get_gate(p["gate_id"])
					if gate == null:
						divert(p, "gate demolished en route", 10)
					else:
						var path := grid.find_path(p["cell"], gate["cell"])
						if path.size() > 1:
							set_path(p, path)
						else:
							divert(p, "taxi route destroyed", 10)

		"AT_GATE":
			if p["state_timer"] >= p["turnaround"]:
				money += p["payout"]
				earned += p["payout"]
				served += 1
				reputation = min(REP_MAX, reputation + REP_PER_TURNAROUND)
				add_log("%s turnaround complete. +$%d" % [p["callsign"], p["payout"]])
				credit_contracts(p)
				p["state"] = "AWAIT_DEPART"
				p["state_timer"] = 0.0

		"AWAIT_DEPART":
			var departure := find_departure_runway(p)
			if departure.is_empty():
				return
			p["runway_id"] = departure["runway"]["id"]
			set_path(p, departure["path"])
			# Gate frees at pushback, not at the runway — keeps throughput sane.
			var gate = grid.get_gate(p["gate_id"])
			if gate != null:
				gate["occupied"] = false
			p["gate_id"] = -1
			p["state"] = "TAXI_OUT"
			p["state_timer"] = 0.0

		"TAXI_OUT":
			match advance_along_path(p, TAXI_SPEED, dt):
				"arrived":
					p["state"] = "HOLD_SHORT"
					p["state_timer"] = 0.0
				"blocked":
					if handle_blocked(p, dt):
						tow(p, "gridlocked outbound")
				"lost":
					var runway = grid.get_runway(p["runway_id"])
					if runway == null:
						tow(p, "runway removed while taxiing")
					else:
						var path := grid.find_path(p["cell"], grid.runway_hold_short_cell(runway))
						if path.size() > 1:
							set_path(p, path)
						else:
							tow(p, "taxi route destroyed")

		"HOLD_SHORT":
			var runway = grid.get_runway(p["runway_id"])
			if runway == null:
				tow(p, "runway removed before takeoff")
				return
			# Claim the runway only now, so a long taxi-out doesn't block landings.
			if grid.runway_is_clear(runway, p["id"]):
				runway["occupied"] = true
				set_path(p, runway["cells"])
				p["state"] = "DEPARTING"
				p["state_timer"] = 0.0
			elif p["state_timer"] >= MAX_BLOCK_TIME:
				tow(p, "never got a takeoff slot")

		"DEPARTING":
			match advance_along_path(p, TAKEOFF_SPEED, dt):
				"arrived":
					grid.release_all(p["id"])
					var runway = grid.get_runway(p["runway_id"])
					if runway != null:
						runway["occupied"] = false
					p["runway_id"] = -1
					p["cell"] = AirportGrid.NOWHERE
					p["state"] = "CLIMB_OUT"
					p["state_timer"] = 0.0
				"blocked":
					p["blocked_timer"] += dt
					if p["blocked_timer"] >= MAX_BLOCK_TIME:
						tow(p, "takeoff roll blocked")
				"lost":
					tow(p, "runway removed during takeoff")

		"CLIMB_OUT":
			var fwd := Vector2(cos(p["heading"]), sin(p["heading"]))
			p["pos"] = p["pos"] + fwd * TAKEOFF_SPEED * dt
			if not get_viewport_rect().grow(120.0).has_point(p["pos"]):
				add_log("%s departed." % p["callsign"])
				p["state"] = "REMOVE"


# --- build actions ---

func apply_tool_at(cell: Vector2i) -> void:
	if not grid.in_bounds(cell):
		return

	match tool:
		Tool.TAXIWAY:
			if not grid.can_place_taxiway(cell):
				return
			if money < COST_TAXIWAY:
				add_log("Not enough money for taxiway ($%d)." % COST_TAXIWAY)
				return
			money -= COST_TAXIWAY
			grid.place_taxiway(cell)

		Tool.GATE_SMALL, Tool.GATE_LARGE:
			var size := tool_gate_size()
			var cells := grid.gate_cells_for(cell, size)
			if not grid.can_place_gate(cells):
				return
			var gate_cost: int = COST_GATE_TILE * size
			if money < gate_cost:
				add_log("Not enough money for that stand ($%d)." % gate_cost)
				return
			money -= gate_cost
			var id := grid.place_gate(cells, size)
			var kind := "widebody stand" if size >= 2 else "stand"
			var gate = grid.get_gate(id)
			if grid.gate_is_connected(gate):
				add_log("Built Gate %d (%s) for $%d." % [id + 1, kind, gate_cost])
			else:
				add_log("Built Gate %d — NOT connected to a taxiway, no flights will use it." % (id + 1))

		Tool.DEMOLISH:
			var preview := grid.demolish_preview(cell)
			if preview.is_empty():
				add_log("Can't demolish that — it's in use or empty.")
				return
			var refund := int(round(tile_cost(preview["type"]) * preview["tiles"] * REFUND_RATE))
			grid.demolish(cell)
			money += refund
			add_log("Demolished %d tile(s), refunded $%d." % [preview["tiles"], refund])


func commit_runway(from: Vector2i, to: Vector2i) -> void:
	var cells := grid.line_cells(from, to)
	if not grid.can_place_runway(cells):
		add_log("Runway must be placed on clear ground.")
		return
	var cost: int = COST_RUNWAY_TILE * cells.size()
	if money < cost:
		add_log("Not enough money — that runway costs $%d." % cost)
		return
	money -= cost
	var id := grid.place_runway(cells)
	var runway = grid.get_runway(id)
	if cells.size() < AirportGrid.MIN_RUNWAY_LEN:
		add_log("Built Runway %d for $%d — TOO SHORT (needs %d tiles)." % [id + 1, cost, AirportGrid.MIN_RUNWAY_LEN])
	elif not grid.runway_is_usable(runway):
		add_log("Built Runway %d for $%d — no taxiway connection yet." % [id + 1, cost])
	else:
		add_log("Built Runway %d for $%d." % [id + 1, cost])


func tool_gate_size() -> int:
	return 2 if tool == Tool.GATE_LARGE else 1


func tile_cost(type: int) -> int:
	match type:
		AirportGrid.TileType.TAXIWAY:
			return COST_TAXIWAY
		AirportGrid.TileType.RUNWAY:
			return COST_RUNWAY_TILE
		AirportGrid.TileType.GATE:
			return COST_GATE_TILE
	return 0


# --- input ---

func _unhandled_input(event: InputEvent) -> void:
	if game_over:
		return

	if event is InputEventKey and event.pressed and not event.echo:
		match event.keycode:
			KEY_SPACE:
				$UI/PauseBtn.button_pressed = not paused
				return
			KEY_1:
				_choose_speed(1.0)
				return
			KEY_2:
				_choose_speed(2.0)
				return
			KEY_3:
				_choose_speed(4.0)
				return
			KEY_A:
				accept_offer()
				return
			KEY_D:
				decline_offer()
				return
		if TOOL_KEYS.has(event.keycode):
			_choose_tool(TOOL_KEYS[event.keycode])
		return

	if event is InputEventMouseMotion:
		hover_cell = grid.world_to_cell(event.position)
		if is_dragging and tool == Tool.TAXIWAY:
			apply_tool_at(hover_cell)
		return

	if not (event is InputEventMouseButton) or event.button_index != MOUSE_BUTTON_LEFT:
		return

	var cell := grid.world_to_cell(event.position)

	if event.pressed:
		if tool == Tool.SELECT:
			_handle_select_click(event.position, cell)
			return
		is_dragging = true
		drag_start = cell
		if tool == Tool.RUNWAY:
			return
		apply_tool_at(cell)
	else:
		if is_dragging and tool == Tool.RUNWAY and grid.in_bounds(drag_start) and grid.in_bounds(cell):
			commit_runway(drag_start, cell)
		is_dragging = false


func _handle_select_click(pos: Vector2, cell: Vector2i) -> void:
	for p in planes:
		if p["pos"].distance_to(pos) < 18.0:
			selected_plane_id = p["id"]
			add_log("Selected %s (%s)." % [p["callsign"], p["state"]])
			return

	var gate = grid.gate_at(cell)
	if gate != null:
		if gate["occupied"]:
			add_log("Gate %d is occupied." % (gate["id"] + 1))
			return
		if not grid.gate_is_connected(gate):
			add_log("Gate %d has no taxiway connection." % (gate["id"] + 1))
			return
		var p = find_plane(selected_plane_id)
		if p == null:
			add_log("Select a holding plane first.")
		elif p["state"] != "HOLDING":
			add_log("%s is not holding for a gate." % p["callsign"])
		else:
			assign_gate_manual(p, gate)
			selected_plane_id = -1
		return

	selected_plane_id = -1


# --- frame ---

func _process(delta: float) -> void:
	# Building stays fully usable while paused, so only the simulation is gated.
	var dt := 0.0 if (paused or game_over) else delta * speed
	if dt > 0.0:
		_simulate(dt)
		if reputation <= 0:
			_end_run()
	_update_hud()
	_update_contract_ui()
	queue_redraw()


func _end_run() -> void:
	game_over = true
	var minutes := int(time_elapsed) / 60
	var seconds := int(time_elapsed) % 60
	var handled := served + diverted
	var rate := 0.0 if handled == 0 else 100.0 * float(served) / float(handled)
	$UI/GameOverPanel/GameOverLabel.text = (
		"AIRPORT SHUT DOWN\n\n"
		+ "The airline authority pulled your licence after\ntoo many diverted flights.\n\n"
		+ "Survived:        %d:%02d\n" % [minutes, seconds]
		+ "Flights served:  %d\n" % served
		+ "Flights lost:    %d\n" % diverted
		+ "On-time rate:    %.0f%%\n" % rate
		+ "Total earned:    $%d" % earned
	)
	$UI/GameOverPanel.visible = true
	add_log("GAME OVER — reputation hit zero after %d:%02d." % [minutes, seconds])


func _simulate(dt: float) -> void:
	time_elapsed += dt
	update_contracts()

	if time_elapsed >= next_spawn_at:
		spawn_plane()
		var tightness: float = max(0.0, 1.0 - time_elapsed / 180.0)
		var min_gap := 3.0 + 3.0 * tightness
		var max_gap := 6.0 + 4.0 * tightness
		next_spawn_at = time_elapsed + min_gap + randf() * (max_gap - min_gap)

	for p in planes:
		if p["state"] != "REMOVE":
			update_plane(p, dt)
	for p in planes:
		if p["state"] == "REMOVE":
			grid.release_all(p["id"])
	planes = planes.filter(func(p): return p["state"] != "REMOVE")


func _class_requirements() -> String:
	var parts := []
	for c in CLASSES:
		parts.append("%s %dt" % [c["code"], c["min_runway"]])
	return "Needs: " + ", ".join(parts)


func _update_contract_ui() -> void:
	var offer_label: Label = $UI/ContractPanel/OfferLabel
	var active_label: Label = $UI/ContractPanel/ActiveLabel
	var full := contracts.size() >= MAX_CONTRACTS

	if offer == null:
		offer_label.text = "No offers right now.\n\nNext approach in %ds." % int(max(0.0, next_offer_at - time_elapsed))
	else:
		var cls: Dictionary = CLASSES[offer["size"]]
		var lines := [
			"%s wants a deal:" % offer["airline"],
			"",
			"%d x %s" % [offer["count"], cls["name"]],
			"within %ds" % int(offer["duration"]),
			"pays $%d bonus" % offer["reward"],
			"fail: -%d reputation" % offer["penalty"],
			"",
			"Needs %dt runway + %s stand." % [cls["min_runway"], "widebody" if cls["gate_size"] >= 2 else "small"],
		]
		if not can_handle_class(offer["size"]):
			lines.append("")
			lines.append("!! Your airport cannot handle this yet.")
		elif full:
			lines.append("")
			lines.append("!! Contract slots full.")
		offer_label.text = "\n".join(lines)

	$UI/ContractPanel/AcceptBtn.visible = offer != null
	$UI/ContractPanel/DeclineBtn.visible = offer != null
	$UI/ContractPanel/AcceptBtn.disabled = full

	if contracts.is_empty():
		active_label.text = "Signed: none."
	else:
		var parts := ["Signed:"]
		for c in contracts:
			parts.append("")
			parts.append("%s — %d/%d %s" % [
				c["airline"], c["progress"], c["count"], CLASSES[c["size"]]["code"],
			])
			parts.append("  %ds left · $%d" % [int(max(0.0, c["deadline"] - time_elapsed)), c["reward"]])
		active_label.text = "\n".join(parts)


func _update_hud() -> void:
	money_label.text = "Money: $%d" % money
	rep_label.text = "Reputation: %d" % reputation
	var clock := "PAUSED" if paused else "%dx" % int(speed)
	next_in_label.text = "Next flight in: %.1fs   [%s]" % [max(0.0, next_spawn_at - time_elapsed), clock]

	var usable_runways := 0
	for r in grid.runways:
		if grid.runway_is_usable(r):
			usable_runways += 1
	var connected_gates := 0
	var wide_stands := 0
	for g in grid.gates:
		if grid.gate_is_connected(g):
			connected_gates += 1
			if g["size"] >= 2:
				wide_stands += 1
	var longest := 0
	for r in grid.runways:
		if grid.runway_is_usable(r):
			longest = max(longest, r["cells"].size())
	stats_label.text = "Runways: %d (%d usable, longest %dt → %s)\nStands: %d connected of %d (%d widebody)\nAircraft: %d\nServed: %d   Lost: %d" % [
		grid.runways.size(), usable_runways, longest, _runway_capability(longest),
		connected_gates, grid.gates.size(), wide_stands, planes.size(),
		served, diverted,
	]

	match tool:
		Tool.SELECT:
			hint_label.text = "SELECT — click a plane to see its route,\nthen click a free gate to assign it."
			tool_info_label.text = "Demolish refunds %d%%" % int(REFUND_RATE * 100)
		Tool.TAXIWAY:
			hint_label.text = "TAXIWAY — click or drag to paint.\nGates and runways need a taxiway connection."
			tool_info_label.text = "$%d per tile" % COST_TAXIWAY
		Tool.RUNWAY:
			hint_label.text = "RUNWAY — drag a straight line.\n%s" % _class_requirements()
			tool_info_label.text = "$%d per tile" % COST_RUNWAY_TILE
		Tool.GATE_SMALL:
			hint_label.text = "STAND (small) — 1 tile, next to a taxiway.\nTakes Light and Narrowbody."
			tool_info_label.text = "$%d" % COST_GATE_TILE
		Tool.GATE_LARGE:
			hint_label.text = "STAND (widebody) — 2 tiles wide.\nTakes any aircraft, including Widebody."
			tool_info_label.text = "$%d" % (COST_GATE_TILE * 2)
		Tool.DEMOLISH:
			hint_label.text = "DEMOLISH — click to remove.\nOccupied gates and runways can't be removed."
			tool_info_label.text = "Refunds %d%%" % int(REFUND_RATE * 100)


# --- rendering ---

func _draw() -> void:
	var view := get_viewport_rect()
	draw_rect(view, Color(0.227, 0.361, 0.227), true)

	var field := grid.grid_rect()
	draw_rect(field, Color(0.19, 0.31, 0.19), true)
	_draw_grid_lines(field)

	for cell in grid.tiles:
		if grid.tile_type(cell) == AirportGrid.TileType.TAXIWAY:
			_draw_tile(cell, Color(0.40, 0.40, 0.43))

	for r in grid.runways:
		_draw_runway(r)
	for g in grid.gates:
		_draw_gate(g)

	_draw_selected_route()

	for p in planes:
		_draw_plane(p)

	_draw_ghost()


func _draw_grid_lines(field: Rect2) -> void:
	var line_color := Color(1, 1, 1, 0.045)
	for x in range(AirportGrid.COLS + 1):
		var px: float = field.position.x + x * AirportGrid.TILE
		draw_line(Vector2(px, field.position.y), Vector2(px, field.end.y), line_color, 1.0)
	for y in range(AirportGrid.ROWS + 1):
		var py: float = field.position.y + y * AirportGrid.TILE
		draw_line(Vector2(field.position.x, py), Vector2(field.end.x, py), line_color, 1.0)


func _cell_rect(cell: Vector2i) -> Rect2:
	return Rect2(AirportGrid.ORIGIN + Vector2(cell) * AirportGrid.TILE, Vector2(AirportGrid.TILE, AirportGrid.TILE))


func _draw_tile(cell: Vector2i, color: Color) -> void:
	draw_rect(_cell_rect(cell), color, true)


# Largest aircraft class a runway of this length can take, as a letter code.
func _runway_capability(length: int) -> String:
	for i in range(CLASSES.size() - 1, -1, -1):
		if length >= CLASSES[i]["min_runway"]:
			return CLASSES[i]["code"]
	return "-"


func _draw_runway(r: Dictionary) -> void:
	var cells: Array = r["cells"]
	for c in cells:
		_draw_tile(c, Color(0.28, 0.28, 0.30))

	var first: Vector2 = grid.cell_to_world(cells[0])
	var last: Vector2 = grid.cell_to_world(cells[cells.size() - 1])
	draw_dashed_line(first, last, Color(0.87, 0.87, 0.87, 0.8), 2.0, 12.0)

	var usable := grid.runway_is_usable(r)
	var label_color := Color(0.95, 0.55, 0.42) if r["occupied"] else Color(0.81, 0.91, 0.81)
	if not usable:
		label_color = Color(1.0, 0.45, 0.45)
		for c in cells:
			draw_rect(_cell_rect(c), Color(1.0, 0.35, 0.35, 0.9), false, 1.0)

	var label := "RWY %d · %dt · %s" % [r["id"] + 1, cells.size(), _runway_capability(cells.size())]
	if cells.size() < AirportGrid.MIN_RUNWAY_LEN:
		label += " (TOO SHORT)"
	elif not usable:
		label += " (NO TAXIWAY)"
	draw_string(ThemeDB.fallback_font, first + Vector2(-14, -18), label, HORIZONTAL_ALIGNMENT_LEFT, -1, 12, label_color)


func _draw_gate(g: Dictionary) -> void:
	var cells: Array = g["cells"]
	var rect := _cell_rect(cells[0])
	for c in cells:
		rect = rect.merge(_cell_rect(c))

	var connected := grid.gate_is_connected(g)
	var fill := Color(0.75, 0.32, 0.25) if g["occupied"] else Color(0.18, 0.42, 0.18)
	var outline := Color(1.0, 0.7, 0.63) if g["occupied"] else Color(0.61, 0.91, 0.61)
	if not connected:
		fill = Color(0.45, 0.35, 0.15)
		outline = Color(1.0, 0.45, 0.45)

	draw_rect(rect, fill, true)
	draw_rect(rect, outline, false, 2.0)
	var tag := "G%d%s" % [g["id"] + 1, "·W" if g["size"] >= 2 else ""]
	draw_string(ThemeDB.fallback_font, rect.position + Vector2(6, 21), tag, HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color(0.95, 0.95, 0.95))
	if not connected:
		draw_string(ThemeDB.fallback_font, rect.position + Vector2(-6, -6), "unconnected", HORIZONTAL_ALIGNMENT_LEFT, -1, 10, Color(1.0, 0.55, 0.55))


func _draw_selected_route() -> void:
	var p = find_plane(selected_plane_id)
	if p == null or p["path"].is_empty():
		return
	var points := PackedVector2Array([p["pos"]])
	for i in range(p["path_index"], p["path"].size()):
		points.append(grid.cell_to_world(p["path"][i]))
	if points.size() > 1:
		draw_polyline(points, Color(1.0, 0.37, 0.82, 0.65), 3.0)


func _draw_plane(p: Dictionary) -> void:
	var color := Color(0.91, 0.91, 0.91)
	match p["state"]:
		"AIR_HOLD":
			color = Color(0.96, 0.65, 0.26)
		"HOLDING":
			color = Color(0.96, 0.83, 0.26)
		"AT_GATE", "AWAIT_DEPART":
			color = Color(0.26, 0.77, 0.96)
	if p["blocked_timer"] > 1.0:
		color = Color(0.95, 0.35, 0.35)
	if selected_plane_id == p["id"]:
		color = Color(1.0, 0.37, 0.82)

	var pos: Vector2 = p["pos"]
	var fwd := Vector2(cos(p["heading"]), sin(p["heading"]))
	var side := Vector2(-fwd.y, fwd.x)
	var s: float = class_of(p)["scale"]

	draw_line(pos + side * 9.0 * s, pos - side * 9.0 * s, color.darkened(0.25), 3.0 * s)
	draw_colored_polygon(PackedVector2Array([
		pos + fwd * 13.0 * s,
		pos - fwd * 8.0 * s + side * 6.0 * s,
		pos - fwd * 8.0 * s - side * 6.0 * s,
	]), color)

	var label: String = "%s [%s]" % [p["callsign"], class_of(p)["code"]]
	match p["state"]:
		"AIR_HOLD":
			label += " (circling)"
		"HOLDING":
			label += " (holding)"
		"AWAIT_DEPART":
			label += " (waiting for runway)"
		"HOLD_SHORT":
			label += " (holding short)"
	if p["blocked_timer"] > 1.0:
		label += " !"
	draw_string(ThemeDB.fallback_font, pos + Vector2(-22, -16), label, HORIZONTAL_ALIGNMENT_LEFT, -1, 10, Color(1, 1, 1))


func _draw_ghost() -> void:
	if tool == Tool.SELECT or not grid.in_bounds(hover_cell):
		return

	var cells: Array = [hover_cell]
	var ok := true

	match tool:
		Tool.TAXIWAY:
			ok = grid.can_place_taxiway(hover_cell) and money >= COST_TAXIWAY
		Tool.GATE_SMALL, Tool.GATE_LARGE:
			var size := tool_gate_size()
			cells = grid.gate_cells_for(hover_cell, size)
			ok = grid.can_place_gate(cells) and money >= COST_GATE_TILE * size
		Tool.RUNWAY:
			if is_dragging and grid.in_bounds(drag_start):
				cells = grid.line_cells(drag_start, hover_cell)
			ok = grid.can_place_runway(cells) and money >= COST_RUNWAY_TILE * cells.size()
		Tool.DEMOLISH:
			var preview := grid.demolish_preview(hover_cell)
			ok = not preview.is_empty()
			if ok:
				cells = preview["cells"]

	var fill := Color(0.4, 1.0, 0.5, 0.3) if ok else Color(1.0, 0.3, 0.3, 0.3)
	if tool == Tool.DEMOLISH and ok:
		fill = Color(1.0, 0.65, 0.2, 0.35)
	for c in cells:
		if grid.in_bounds(c):
			draw_rect(_cell_rect(c), fill, true)

	if tool == Tool.RUNWAY and cells.size() > 1:
		var cost := COST_RUNWAY_TILE * cells.size()
		var anchor := grid.cell_to_world(cells[0]) + Vector2(-10, -16)
		draw_string(ThemeDB.fallback_font, anchor, "%d tiles — $%d" % [cells.size(), cost], HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color(1, 1, 1))
