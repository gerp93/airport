extends Node2D

const AirportGrid = preload("res://AirportGrid.gd")
const Regions = preload("res://Regions.gd")
const KvgUpdate = preload("res://addons/kvg_update/kvg_update.gd")
const Render3D = preload("res://Render3D.gd")

const UPDATE_REPO := "gerp93/airport"

enum Tool { SELECT, TAXIWAY, RUNWAY, GATE_SMALL, GATE_LARGE, TERMINAL, ROAD, PARKING, DEMOLISH }

const TOOL_BUTTONS := {
	Tool.SELECT: "SelectBtn", Tool.TAXIWAY: "TaxiwayBtn", Tool.RUNWAY: "RunwayBtn",
	Tool.GATE_SMALL: "GateSmallBtn", Tool.GATE_LARGE: "GateLargeBtn",
	Tool.TERMINAL: "TerminalBtn", Tool.ROAD: "RoadBtn",
	Tool.PARKING: "ParkingBtn", Tool.DEMOLISH: "DemolishBtn",
}
const TOOL_KEYS := {
	KEY_ESCAPE: Tool.SELECT, KEY_T: Tool.TAXIWAY, KEY_R: Tool.RUNWAY,
	KEY_G: Tool.GATE_SMALL, KEY_H: Tool.GATE_LARGE, KEY_E: Tool.TERMINAL,
	KEY_O: Tool.ROAD, KEY_P: Tool.PARKING, KEY_X: Tool.DEMOLISH,
}

const AIRLINES := ["SkyNorth", "BlueWing", "CoastAir", "PineJet", "Vantage"]

# Bigger aircraft pay much better but demand a longer runway and a wider stand,
# so the fleet mix is what pushes the player to keep investing in the layout.
# "Regional" rather than light GA: real general aviation pays almost nothing in
# landing fees, which would make the opening minutes income-free. A 50-80 seat
# regional jet is both realistic and worth serving.
const CLASSES := [
	{
		"name": "Regional", "code": "R", "min_runway": 6, "gate_size": 1,
		"fee_min": 700, "fee_max": 1_100, "turnaround": 4.0, "scale": 0.7,
		"term_units": 1,
	},
	{
		"name": "Narrowbody", "code": "N", "min_runway": 12, "gate_size": 1,
		"fee_min": 1_900, "fee_max": 2_900, "turnaround": 8.0, "scale": 1.0,
		"term_units": 2,
	},
	{
		"name": "Widebody", "code": "W", "min_runway": 18, "gate_size": 2,
		"fee_min": 6_500, "fee_max": 9_500, "turnaround": 13.0, "scale": 1.35,
		"term_units": 3,
	},
]

# Runway lengths are shown to the player in feet. ICAO standardises on metres
# for aerodrome dimensions, but feet is the US/FAA convention and gives the
# recognisable landmark numbers (7,200 ft, 10,800 ft) this genre trades on.
# Switch this pair to convert the whole UI to metres.
const FEET_PER_TILE := 600
const LENGTH_UNIT := "ft"

# --- economy scale ---
# Capital costs and upkeep are real 2020s figures: runway pavement runs about
# $2,500 per linear foot, a stand with a jet bridge ~$4.5M, a modern ATC tower
# ~$35M, a terminal wing ~$55M. The per-flight fees in CLASSES are likewise
# realistic aeronautical revenue (landing fee + parking + passenger charges).
#
# REVENUE_SCALE then multiplies that revenue, and it is the one deliberate lie
# in the model. Real airports amortise a runway over decades and fund it with
# grants, not landing fees, so at 1.0 the economics are true to life and the
# game is unplayable. At 40 a runway pays back in roughly 15 game-days. The
# fudge lives here alone so it can be dialled without touching anything else.
const REVENUE_SCALE := 40

const COST_TAXIWAY := 500_000
const COST_RUNWAY_TILE := 1_500_000
const COST_GATE_TILE := 4_500_000
const REFUND_RATE := 0.5
const TOW_FEE := 25_000

const UPKEEP_RUNWAY := 2_000
const UPKEEP_STAND := 600
const DAY_LENGTH := 90.0

# Facilities are bought in units; each unit adds concurrency and daily upkeep,
# so scaling up traffic means scaling up overhead.
const FACILITIES := [
	# The tower is the throttle on all inbound volume, so at $35M for +3 it was
	# 70 game-days of income away — the airport strangled long before it could
	# afford to grow. $28M for +4 keeps it a real investment without making
	# capacity unreachable, and is still squarely in the real range for a
	# tower project.
	{
		"key": "tower", "name": "Control Tower", "cost": 28_000_000,
		"upkeep": 9_000, "per_unit": 4, "unit": "airborne",
	},
	{
		"key": "crew", "name": "Ground Crew Team", "cost": 1_500_000,
		"upkeep": 3_200, "per_unit": 2, "unit": "turnarounds",
	},
	{
		"key": "fuel", "name": "Fuel Truck", "cost": 600_000,
		"upkeep": 900, "per_unit": 2, "unit": "refuels",
	},
	{
		"key": "mech", "name": "Maintenance Hangar", "cost": 22_000_000,
		"upkeep": 7_500, "per_unit": 1, "unit": "checks",
	},
]
const START_FACILITIES := {"tower": 1, "crew": 1, "fuel": 1, "mech": 0}

# Terminal capacity now comes from placed concourse tiles rather than an
# abstract purchase, so passenger handling has to be laid out next to the
# stands it serves. This is the most compressed capital figure in the model:
# a real terminal runs into the hundreds of millions and would swamp
# everything else at this revenue scale.
const COST_TERMINAL_TILE := 18_000_000
const UPKEEP_TERMINAL_TILE := 6_000
const TERM_UNITS_PER_TILE := 3
# Landside: passengers arrive by road and have to leave their cars somewhere.
const COST_ROAD_TILE := 400_000
const UPKEEP_ROAD_TILE := 200
const COST_PARKING_TILE := 6_000_000
const UPKEEP_PARKING_TILE := 1_500
const PARK_UNITS_PER_TILE := 2
# A stand with no jet bridge still works, but everyone has to be bussed.
const REMOTE_STAND_FACTOR := 1.4

# A line check is worth servicing if you have the hangar for it, so maintenance
# is an extra revenue stream rather than another way to be punished.
const MAINT_FEE := 2_500
const MAINT_CHANCE := 0.12
const MAINT_TIME_FACTOR := 1.5
const SERVICE_PATIENCE := 18.0

const TAXI_SPEED := 60.0
const ROLLOUT_SPEED := 170.0
const TAKEOFF_SPEED := 200.0
const FLY_SPEED := 220.0

const REPATH_INTERVAL := 1.5
const MAX_BLOCK_TIME := 20.0
# Reputation has to be recoverable, or the game is just a countdown to losing.
# At +1 a good day still lost ground to a handful of diversions, so serving
# flights well never actually dug you out.
const REP_PER_TURNAROUND := 2
const REP_MAX := 100

const SAVE_PATH := "user://airport_save.dat"
const SAVE_VERSION := 3

const AIRPORT_CODE := "HOME"
const MAX_ROUTES := 8
# Commitment buys volume at a worse unit price: a charter pays over list, a
# recurring route takes a cut, and a hub carrier takes the deepest cut of all
# while supplying far more flights than either.
const CHARTER_RATE := 1.30
const ROUTE_RATE := 0.85
const HUB_RATE := 0.70
const HUB_ROUTE_REQ := 3
const HUB_BREAK_REP := 20
# A scheduled flight you cannot fit is turned away, which is what
# over-committing on routes actually costs.
const ARRIVAL_GRACE := 40.0
const REP_TURNED_AWAY := 5

# Aircraft bound elsewhere that have to come here instead. They pay well over
# list and earn goodwill if handled, but losing one is far worse than losing a
# scheduled flight — and they arrive whether or not you have room.
const EMERGENCY_RATE := 1.6
const REP_EMERGENCY_LOST := 22
const REP_EMERGENCY_HANDLED := 4

const SPAWN_POS := Vector2(-60.0, 150.0)
const AIR_ANCHOR := Vector2(110.0, 160.0)

var grid: AirportGrid
var render3d: Render3D
# Enough for two or three meaningful opening moves rather than exactly one.
var money := 28_000_000
var day := 1
var day_time := 0.0
var day_revenue := 0
var last_day_revenue := 0
var last_upkeep := 0
var facilities := {}
var used := {"crew": 0, "fuel": 0, "term": 0, "mech": 0}
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
var routes: Array = []
var arrival_queue: Array = []
var hub_airline := ""
var next_offer_at := 25.0
var next_emergency_at := 130.0

# Setup runs before the simulation: 0 picks a continent, 1 picks a region, 2 plays.
var setup_stage := 0
var continent_idx := -1
var continent_name := ""
var region := {}
var weather := {}
var weather_until := 0.0
var next_weather_at := 100.0

var selected_plane_id := -1
var tool: Tool = Tool.SELECT
var hover_cell := AirportGrid.NOWHERE
var drag_start := AirportGrid.NOWHERE
var is_dragging := false

@onready var money_label: Label = $UI/MoneyLabel
@onready var rep_label: Label = $UI/RepLabel
@onready var next_in_label: Label = $UI/NextInLabel
@onready var day_label: Label = $UI/DayLabel
@onready var capacity_label: Label = $UI/CapacityLabel
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

	# The world is drawn in 3D by a Node3D child. A Node3D under a Node2D still
	# renders — 3D goes through the viewport's World3D, independent of the 2D
	# canvas — which lets `_draw()` below stay available for screen-space labels
	# and leaves the whole $UI CanvasLayer untouched.
	render3d = Render3D.new()
	add_child(render3d)
	render3d.attach(grid)

	$UI/SelectBtn.pressed.connect(_set_tool.bind(Tool.SELECT))
	$UI/TaxiwayBtn.pressed.connect(_set_tool.bind(Tool.TAXIWAY))
	$UI/RunwayBtn.pressed.connect(_set_tool.bind(Tool.RUNWAY))
	$UI/GateSmallBtn.pressed.connect(_set_tool.bind(Tool.GATE_SMALL))
	$UI/GateLargeBtn.pressed.connect(_set_tool.bind(Tool.GATE_LARGE))
	$UI/TerminalBtn.pressed.connect(_set_tool.bind(Tool.TERMINAL))
	$UI/RoadBtn.pressed.connect(_set_tool.bind(Tool.ROAD))
	$UI/ParkingBtn.pressed.connect(_set_tool.bind(Tool.PARKING))
	$UI/DemolishBtn.pressed.connect(_set_tool.bind(Tool.DEMOLISH))

	$UI/PauseBtn.toggled.connect(_on_pause_toggled)
	$UI/Speed1Btn.pressed.connect(_set_speed.bind(1.0))
	$UI/Speed2Btn.pressed.connect(_set_speed.bind(2.0))
	$UI/Speed3Btn.pressed.connect(_set_speed.bind(4.0))
	$UI/GameOverPanel/RestartBtn.pressed.connect(func(): get_tree().reload_current_scene())
	$UI/RoutePanel/AcceptBtn.pressed.connect(accept_offer)
	$UI/RoutePanel/DeclineBtn.pressed.connect(decline_offer)
	$UI/SaveBtn.pressed.connect(save_game)
	$UI/LoadBtn.pressed.connect(load_game)
	_refresh_save_buttons()

	# Godot's default Button style nearly vanishes on a dark panel, so the sidebar
	# controls get an explicit one.
	for b in [$UI/RoutePanel/AcceptBtn, $UI/RoutePanel/DeclineBtn,
			$UI/SaveBtn, $UI/LoadBtn]:
		_style_button(b)

	for i in 6:
		var b: Button = $UI/StartPanel.get_node("Opt%d" % i)
		b.pressed.connect(_choose_setup.bind(i))
		_style_button(b)
	# Headless balance runs can't click, so they take the first region.
	if _echo_log or _auto_sign:
		_choose_setup(0)
		_choose_setup(0)
	_show_setup()

	facilities = START_FACILITIES.duplicate()
	for i in FACILITIES.size():
		var fkey: String = FACILITIES[i]["key"]
		$UI/FacilityPanel.get_node("Row%dBuy" % i).pressed.connect(buy_facility.bind(fkey))
		$UI/FacilityPanel.get_node("Row%dSell" % i).pressed.connect(sell_facility.bind(fkey))
		_style_button($UI/FacilityPanel.get_node("Row%dBuy" % i))
		_style_button($UI/FacilityPanel.get_node("Row%dSell" % i))

	add_log("Airport open. Build taxiways to connect runways and gates.")

	# Headless/balance runs are deterministic test tooling, not a real play
	# session — they shouldn't make a network call or depend on GitHub being up.
	if not (_echo_log or _auto_sign):
		_check_for_update()


func _check_for_update() -> void:
	var checker := KvgUpdate.new()
	add_child(checker)
	checker.check_complete.connect(_on_update_checked)
	var current: String = ProjectSettings.get_setting("application/config/version", "0.0.0-dev")
	checker.check(UPDATE_REPO, current)


func _on_update_checked(result: Dictionary) -> void:
	if result["error"] != "":
		# Not user-facing: no releases yet, offline, GitHub hiccup — none of
		# these are worth interrupting a game session over.
		return
	if not result["available"]:
		return
	var btn: Button = $UI/UpdateBtn
	btn.text = "Update available: %s" % result["latest"]
	btn.visible = true
	btn.pressed.connect(func(): OS.shell_open(result["url"]))
	_style_button(btn)
	add_log("A new version (%s) is available — see the Update button." % result["latest"])


# --- location setup ---

func _show_setup() -> void:
	$UI/StartPanel.visible = setup_stage < 2
	if setup_stage >= 2:
		return

	var opts: Array = []
	if setup_stage == 0:
		$UI/StartPanel/Title.text = "WHERE IS YOUR AIRPORT?"
		$UI/StartPanel/Sub.text = "Pick a continent. Your location decides which airports feed you traffic and what weather you have to operate through."
		for c in Regions.CONTINENTS:
			opts.append(c["name"])
	else:
		$UI/StartPanel/Title.text = continent_name.to_upper()
		$UI/StartPanel/Sub.text = "Pick a region. Each has its own weather to contend with."
		for r in Regions.CONTINENTS[continent_idx]["regions"]:
			var kinds := []
			for k in r["weather"]:
				kinds.append(Regions.WEATHER[k]["name"])
			opts.append("%s  —  %s" % [r["name"], ", ".join(kinds)])

	for i in 6:
		var b: Button = $UI/StartPanel.get_node("Opt%d" % i)
		b.visible = i < opts.size()
		if i < opts.size():
			b.text = opts[i]


func _choose_setup(i: int) -> void:
	if setup_stage == 0:
		if i >= Regions.CONTINENTS.size():
			return
		continent_idx = i
		continent_name = Regions.CONTINENTS[i]["name"]
		setup_stage = 1
		_show_setup()
	elif setup_stage == 1:
		var regions: Array = Regions.CONTINENTS[continent_idx]["regions"]
		if i >= regions.size():
			return
		region = regions[i]
		setup_stage = 2
		_show_setup()
		add_log("Airport sited in %s, %s." % [region["name"], continent_name])
		var kinds := []
		for k in region["weather"]:
			kinds.append(Regions.WEATHER[k]["name"].to_lower())
		add_log("Local conditions to expect: %s." % ", ".join(kinds))


func _style_button(b: Button) -> void:
	var normal := StyleBoxFlat.new()
	normal.bg_color = Color(0.17, 0.23, 0.27)
	normal.border_color = Color(0.48, 0.60, 0.56)
	normal.set_border_width_all(1)
	normal.set_corner_radius_all(3)
	b.add_theme_stylebox_override("normal", normal)

	var hover := normal.duplicate()
	hover.bg_color = Color(0.25, 0.33, 0.37)
	b.add_theme_stylebox_override("hover", hover)

	var disabled := normal.duplicate()
	disabled.bg_color = Color(0.12, 0.14, 0.15)
	disabled.border_color = Color(0.28, 0.32, 0.31)
	b.add_theme_stylebox_override("disabled", disabled)


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


# --- facilities and capacity ---

func fac_def(key: String) -> Dictionary:
	for f in FACILITIES:
		if f["key"] == key:
			return f
	return {}


func capacity(key: String) -> int:
	if key == "term":
		# Only concourse and parking that a road actually reaches can handle
		# passengers, so landside access is a real constraint.
		var conc := grid.count_tiles(AirportGrid.TileType.TERMINAL, true)
		var park := grid.count_tiles(AirportGrid.TileType.PARKING, true)
		return conc * TERM_UNITS_PER_TILE + park * PARK_UNITS_PER_TILE
	return facilities.get(key, 0) * int(fac_def(key)["per_unit"])


func free_capacity(key: String) -> int:
	return capacity(key) - int(used.get(key, 0))


func total_upkeep() -> int:
	var total := 0
	for f in FACILITIES:
		total += int(facilities.get(f["key"], 0)) * int(f["upkeep"])
	total += grid.runways.size() * UPKEEP_RUNWAY
	total += grid.terminal_tile_count() * UPKEEP_TERMINAL_TILE
	total += grid.count_tiles(AirportGrid.TileType.ROAD, false) * UPKEEP_ROAD_TILE
	total += grid.count_tiles(AirportGrid.TileType.PARKING, false) * UPKEEP_PARKING_TILE
	total += grid.gates.size() * UPKEEP_STAND
	return total


func buy_facility(key: String) -> void:
	var d := fac_def(key)
	if money < int(d["cost"]):
		add_log("Not enough cash for a %s (%s)." % [d["name"].to_lower(), money_str(d["cost"])])
		return
	money -= int(d["cost"])
	facilities[key] = int(facilities.get(key, 0)) + 1
	add_log("Commissioned %s. Upkeep now %s/day." % [d["name"], money_str(total_upkeep())])


func sell_facility(key: String) -> void:
	var d := fac_def(key)
	if int(facilities.get(key, 0)) <= 0:
		return
	# Never sell capacity that aircraft are currently occupying.
	if capacity(key) - int(d["per_unit"]) < int(used.get(key, 0)):
		add_log("That %s is in use right now." % d["name"].to_lower())
		return
	facilities[key] -= 1
	var refund := int(int(d["cost"]) * REFUND_RATE)
	money += refund
	add_log("Decommissioned %s, recovered %s." % [d["name"], money_str(refund)])


# Turnarounds need a crew, a fuel truck, and terminal capacity scaled by how many
# passengers the aircraft carries. Maintenance is optional upside.
func try_start_service(p: Dictionary) -> bool:
	var need_term: int = class_of(p)["term_units"]
	if free_capacity("crew") < 1 or free_capacity("fuel") < 1 or free_capacity("term") < need_term:
		return false
	var holds := {"crew": 1, "fuel": 1, "term": need_term}
	if p["wants_check"] and free_capacity("mech") >= 1:
		holds["mech"] = 1
		p["turnaround"] *= MAINT_TIME_FACTOR
	for k in holds:
		used[k] = int(used[k]) + int(holds[k])
	p["holds"] = holds
	return true


# Name the resource that is actually short. "No ground support" sent the player
# hunting for crew when the real problem could be that no concourse has a road.
func service_shortfall(p: Dictionary) -> String:
	var need_term: int = class_of(p)["term_units"]
	if free_capacity("term") < need_term:
		if grid.count_tiles(AirportGrid.TileType.TERMINAL, true) == 0:
			return "no concourse with road access"
		return "passenger capacity full"
	if free_capacity("crew") < 1:
		return "no ground crew free"
	if free_capacity("fuel") < 1:
		return "no fuel truck free"
	return "ground support busy"


func release_service(p: Dictionary) -> void:
	var holds: Dictionary = p.get("holds", {})
	for k in holds:
		used[k] = int(used[k]) - int(holds[k])
	p["holds"] = {}


func airborne_count() -> int:
	var n := 0
	for p in planes:
		if p["state"] in ["AIR_HOLD", "APPROACH", "INBOUND", "LANDING"]:
			n += 1
	return n


# --- weather ---

func wx(field: String, default_value: float) -> float:
	if weather.is_empty():
		return default_value
	return weather.get(field, default_value)


func wx_closed() -> bool:
	return not weather.is_empty() and bool(weather.get("closed", false))


# Weather mostly costs revenue rather than reputation: arrivals stop coming, so
# you lose the fees. Aircraft already holding burn patience at half rate and
# divert for half the usual reputation, because a storm isn't the airport's fault.
func effective_air_capacity() -> int:
	return maxi(1, int(round(capacity("tower") * wx("arrivals", 1.0))))


func required_runway(p: Dictionary) -> float:
	return float(class_of(p)["min_runway"]) * wx("length", 1.0)


func taxi_speed() -> float:
	return TAXI_SPEED * wx("taxi", 1.0)


func update_weather() -> void:
	if not weather.is_empty():
		if time_elapsed >= weather_until:
			add_log("%s has cleared." % weather["name"])
			weather = {}
			next_weather_at = time_elapsed + 90.0 + randf() * 120.0
		return
	if region.is_empty() or time_elapsed < next_weather_at:
		return

	var kinds: Array = region["weather"]
	var kind: String = kinds[randi() % kinds.size()]
	var def: Dictionary = Regions.WEATHER[kind]
	weather = def.duplicate()
	weather["kind"] = kind
	weather_until = time_elapsed + 30.0 + randf() * 30.0
	add_log("WEATHER — %s: %s." % [def["name"], def["blurb"]])


# --- day cycle ---

func end_of_day() -> void:
	var bill := total_upkeep()
	money -= bill
	last_upkeep = bill
	last_day_revenue = day_revenue
	day_revenue = 0
	add_log("Day %d closed — took %s, upkeep %s." % [day, money_str(last_day_revenue), money_str(bill)])
	day += 1
	if money < 0:
		reputation = max(0, reputation - 12)
		add_log("OVERDRAWN — couldn't cover upkeep. Reputation -12.")


# --- airline relationships ---
# Three tiers, escalating in volume and falling in unit price:
#   charter - one-off flight, premium rate, no commitment
#   route   - recurring daily arrivals from one origin at a discount
#   hub     - one airline only, heavy daily volume at the deepest discount
# Earning a hub offer means already running several routes for that airline from
# different origins, so the ladder is the progression.

func can_handle_class(size: int) -> bool:
	var need: Dictionary = CLASSES[size]
	var runway_ok := false
	for r in grid.runways:
		if grid.runway_is_usable(r) and grid.runway_length_tiles(r) >= float(need["min_runway"]):
			runway_ok = true
			break
	if not runway_ok:
		return false
	for g in grid.gates:
		if grid.gate_is_connected(g) and g["size"] >= int(need["gate_size"]):
			return true
	return false


func random_origin() -> Array:
	var list: Array = region["origins"]
	return list[randi() % list.size()]


# Offer an airline somewhere it does not already fly from, otherwise it keeps
# proposing the same city and can never build up to a hub.
func fresh_origin_for(airline: String) -> Array:
	var taken := {}
	for r in routes_for(airline):
		taken[r["origin"][0]] = true
	var options := []
	for o in region["origins"]:
		if not taken.has(o[0]):
			options.append(o)
	if options.is_empty():
		return random_origin()
	return options[randi() % options.size()]


func routes_for(airline: String) -> Array:
	var out := []
	for r in routes:
		if r["airline"] == airline:
			out.append(r)
	return out


func distinct_origins(airline: String) -> int:
	var seen := {}
	for r in routes_for(airline):
		seen[r["origin"][0]] = true
	return seen.size()


# An airline will talk hub once it already flies enough distinct routes here.
func hub_candidate() -> String:
	for a in AIRLINES:
		if a != hub_airline and distinct_origins(a) >= HUB_ROUTE_REQ:
			return a
	return ""


func daily_route_flights() -> int:
	var n := 0
	for r in routes:
		n += int(r["per_day"])
	return n


# Airlines expand where they already operate. Without this the offer stream
# spreads evenly across all five carriers and none ever reaches hub scale, so
# the top relationship tier was effectively unreachable.
func offering_airline() -> String:
	var incumbents := []
	for a in AIRLINES:
		if not routes_for(a).is_empty():
			incumbents.append(a)
	if not incumbents.is_empty() and randf() < 0.65:
		return incumbents[randi() % incumbents.size()]
	return AIRLINES[randi() % AIRLINES.size()]


func make_offer() -> Dictionary:
	var cand := hub_candidate()
	if cand != "" and randf() < 0.6:
		var origins := []
		for r in routes_for(cand):
			if not origins.has(r["origin"]):
				origins.append(r["origin"])
		return {
			"kind": "hub", "airline": cand, "origins": origins,
			"per_day": 8 + randi() % 5, "rate": HUB_RATE,
			"size": 1 + randi() % 2,
		}

	if randf() < 0.4:
		return {
			"kind": "charter", "airline": offering_airline(),
			"origin": random_origin(), "size": pick_size(),
			"rate": CHARTER_RATE, "per_day": 1,
		}

	var carrier := offering_airline()
	return {
		"kind": "route", "airline": carrier,
		"origin": fresh_origin_for(carrier), "size": pick_size(),
		"per_day": 2 + randi() % 3, "rate": ROUTE_RATE,
	}


func offer_daily_value(o: Dictionary) -> int:
	var cls: Dictionary = CLASSES[o["size"]]
	var per: int = (int(cls["fee_min"]) + int(cls["fee_max"])) / 2
	return int(per * REVENUE_SCALE * float(o["rate"]) * int(o["per_day"]))


func accept_offer() -> void:
	if offer == null:
		return
	match offer["kind"]:
		"charter":
			# A one-off turns up shortly; nothing recurring is committed.
			arrival_queue.append({
				"at": time_elapsed + 8.0 + randf() * 20.0,
				"airline": offer["airline"], "origin": offer["origin"],
				"size": offer["size"], "rate": offer["rate"], "kind": "charter",
			})
			add_log("Took a %s charter from %s (%s)." % [
				CLASSES[offer["size"]]["name"], offer["origin"][1], offer["origin"][0],
			])
		"route":
			if routes.size() >= MAX_ROUTES:
				add_log("Too many routes already — turn one down first.")
				return
			routes.append({
				"airline": offer["airline"], "origin": offer["origin"],
				"size": offer["size"], "per_day": offer["per_day"], "rate": offer["rate"],
			})
			add_log("Opened route %s-%s for %s: %d %s daily at %d%% of list." % [
				offer["origin"][0], AIRPORT_CODE, offer["airline"], offer["per_day"],
				CLASSES[offer["size"]]["name"], int(offer["rate"] * 100.0),
			])
			schedule_day_arrivals()
		"hub":
			if hub_airline != "":
				# Only one hub carrier at a time, and walking away from one is costly.
				reputation = max(0, reputation - HUB_BREAK_REP)
				add_log("Broke the %s hub agreement. Reputation -%d." % [hub_airline, HUB_BREAK_REP])
				routes = routes.filter(func(r): return not r.get("hub", false))
			hub_airline = offer["airline"]
			for o in offer["origins"]:
				routes.append({
					"airline": hub_airline, "origin": o, "size": offer["size"],
					"per_day": maxi(2, int(offer["per_day"]) / max(1, offer["origins"].size())),
					"rate": offer["rate"], "hub": true,
				})
			add_log("%s HUB AGREEMENT signed — %d daily flights at %d%% of list." % [
				hub_airline, offer["per_day"], int(offer["rate"] * 100.0),
			])
			schedule_day_arrivals()
	offer = null
	next_offer_at = time_elapsed + 45.0 + randf() * 35.0


func decline_offer() -> void:
	if offer == null:
		return
	add_log("Passed on the %s %s." % [offer["airline"], offer["kind"]])
	offer = null
	next_offer_at = time_elapsed + 25.0 + randf() * 20.0


# Route flights are spread across the day so volume arrives as a stream rather
# than a single burst at the day boundary.
func schedule_day_arrivals() -> void:
	arrival_queue = arrival_queue.filter(func(a): return a["kind"] == "charter")
	for r in routes:
		for i in int(r["per_day"]):
			var frac := (float(i) + 0.5 + randf() * 0.4) / float(r["per_day"])
			arrival_queue.append({
				"at": (day - 1) * DAY_LENGTH + frac * DAY_LENGTH,
				"airline": r["airline"], "origin": r["origin"],
				"size": r["size"], "rate": r["rate"], "kind": "route",
			})


func update_offers() -> void:
	if offer == null and time_elapsed >= next_offer_at:
		offer = make_offer()
		add_log("%s is offering a %s." % [offer["airline"], offer["kind"]])
		if _auto_sign:
			if can_handle_class(offer["size"]):
				accept_offer()
			else:
				decline_offer()


# A scheduled flight the airport cannot take within the grace period is turned
# away. This is what over-committing on routes actually costs.
func process_scheduled_arrivals() -> void:
	var expired := []
	for a in arrival_queue:
		if time_elapsed < a["at"]:
			continue
		if time_elapsed > a["at"] + ARRIVAL_GRACE:
			expired.append(a)
			continue
		if wx_closed() or airborne_count() >= effective_air_capacity():
			continue
		spawn_flight(a["airline"], a["size"], a["origin"], a["rate"], a["kind"])
		expired.append(a)
	for a in expired:
		arrival_queue.erase(a)
		if time_elapsed > a["at"] + ARRIVAL_GRACE:
			reputation = max(0, reputation - REP_TURNED_AWAY)
			diverted += 1
			add_log("%s %s from %s TURNED AWAY — no capacity. Reputation -%d." % [
				a["airline"], CLASSES[a["size"]]["name"], a["origin"][0], REP_TURNED_AWAY,
			])


func spawn_flight(airline: String, size: int, origin: Array, rate: float, kind: String) -> void:
	var cls: Dictionary = CLASSES[size]
	var fee: int = int(cls["fee_min"]) + randi() % (int(cls["fee_max"]) - int(cls["fee_min"]) + 1)
	var payout := int(fee * REVENUE_SCALE * rate)
	var callsign := "%s %d" % [airline, plane_id_seq]
	planes.append({
		"id": plane_id_seq, "airline": airline, "payout": payout,
		"size": size, "callsign": callsign, "origin": origin, "kind": kind,
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
		"service_wait": 0.0, "delay_logged": false, "holds": {},
		"wants_check": randf() < MAINT_CHANCE,
		"emergency": kind == "emergency",
	})
	if kind == "emergency":
		# Give them more patience than a scheduled flight: they have nowhere else
		# to go, so the drama is whether you can clear space in time.
		planes[-1]["max_air_hold"] = 45.0
		planes[-1]["max_hold"] = 32.0
		add_log("EMERGENCY — %s diverted to us from %s (%s). Needs priority." % [
			callsign, origin[1], cls["name"],
		])
	else:
		add_log("%s inbound from %s — %s, fee %s." % [
			callsign, origin[0], cls["name"], money_str(payout),
		])
	plane_id_seq += 1


# Emergencies ignore the tower cap and any closure, because an aircraft
# declaring one is landing regardless of what the schedule says. Bad weather
# makes them more likely — other airports in the region are shut too.
func update_emergencies() -> void:
	if region.is_empty() or time_elapsed < next_emergency_at:
		return
	# Reschedule first, so an airport that currently can't take anything doesn't
	# re-run this check every frame.
	var gap := 130.0 + randf() * 130.0
	if not weather.is_empty():
		gap *= 0.55
	next_emergency_at = time_elapsed + gap

	# Only divert aircraft the airport could physically take. A widebody landing
	# at a field with no widebody stand is an unwinnable dice roll, not a test —
	# the challenge should be clearing space in time, not the class lottery.
	var size := pick_serviceable_size()
	if size < 0:
		return
	spawn_flight(
		AIRLINES[randi() % AIRLINES.size()], size,
		random_origin(), EMERGENCY_RATE, "emergency"
	)


# Unscheduled walk-in traffic, so an airport with no routes still has something
# to do. It thins out as contracted volume grows.
func serviceable_sizes() -> Array:
	var out := []
	for i in CLASSES.size():
		if can_handle_class(i):
			out.append(i)
	return out


# Keeps the time-based fleet progression, but never sends an aircraft the
# airport physically cannot serve. An airline doesn't schedule a widebody into a
# field with a 9,600 ft runway, and docking the player 15 reputation for not
# having built one yet is backwards — unmet widebody demand should show up as
# route offers they can't accept, which is the real incentive to invest.
func pick_serviceable_size() -> int:
	var options := serviceable_sizes()
	if options.is_empty():
		return -1
	for _attempt in 6:
		var s := pick_size()
		if options.has(s):
			return s
	return options[randi() % options.size()]


func spawn_plane() -> void:
	var size := pick_serviceable_size()
	if size < 0:
		return
	spawn_flight(AIRLINES[randi() % AIRLINES.size()], size, random_origin(), 1.0, "walk-in")


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
	var cost := rep_cost
	if p.get("emergency", false):
		cost = REP_EMERGENCY_LOST
	elif wx_closed():
		cost = maxi(1, rep_cost / 2)
	reputation = max(0, reputation - cost)
	diverted += 1
	add_log("%s DIVERTED — %s. Reputation -%d." % [p["callsign"], reason, rep_cost])
	release_plane(p)


# --- gate / runway acquisition ---

func class_of(p: Dictionary) -> Dictionary:
	return CLASSES[p["size"]]


func runway_fits(r: Dictionary, p: Dictionary) -> bool:
	return grid.runway_length_tiles(r) >= required_runway(p)


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
	var emerg: bool = p.get("emergency", false)
	if wx_closed() and not emerg:
		return null
	for r in grid.runways:
		if not runway_fits(r, p):
			continue
		if not grid.runway_is_clear(r):
			continue
		if emerg or not runway_has_waiting_departure(r["id"]):
			return r
	return null


func find_departure_runway(p: Dictionary) -> Dictionary:
	if wx_closed():
		return {}
	for r in grid.runways:
		if not grid.runway_is_usable(r) or not runway_fits(r, p):
			continue
		# A usable runway always has a connected taxiway, so there is always
		# somewhere to hold short.
		var target: Vector2i = grid.runway_hold_short_cell(r)
		if target == AirportGrid.NOWHERE:
			continue
		var path := grid.find_path(p["cell"], target)
		if not path.is_empty():
			# Runways work in both directions — that is what the two designators
			# mean — so depart from whichever end the aircraft is already near
			# rather than back-taxiing the full length with the runway closed.
			var hold := grid.cell_to_world(target)
			var from_b: bool = hold.distance_to(r["b"]) < hold.distance_to(r["a"])
			return {"runway": r, "path": path, "from_b": from_b}
	return {}


func tow(p: Dictionary, reason: String) -> void:
	money = max(0, money - TOW_FEE)
	reputation = max(0, reputation - 5)
	add_log("%s %s — towed off. -%s, Reputation -5." % [p["callsign"], reason, money_str(TOW_FEE)])
	release_plane(p)


# --- per-plane state machine ---

func update_plane(p: Dictionary, dt: float) -> void:
	p["state_timer"] += dt

	match p["state"]:
		"AIR_HOLD":
			p["air_hold_timer"] += dt * (0.5 if wx_closed() else 1.0)
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
					reason = "no runway long enough for a %s (needs %s)" % [
						class_of(p)["name"].to_lower(), length_str(class_of(p)["min_runway"]),
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
			var lineup: Vector2 = grid.runway_threshold_point(runway) \
				- grid.runway_direction(runway) * 220.0
			if move_toward_point(p, lineup, FLY_SPEED, dt):
				p["state"] = "INBOUND"
				p["state_timer"] = 0.0

		"INBOUND":
			var runway = grid.get_runway(p["runway_id"])
			if runway == null:
				divert(p, "runway removed on approach", 15)
				return
			if move_toward_point(p, grid.runway_threshold_point(runway), FLY_SPEED, dt):
				p["state"] = "LANDING"
				p["state_timer"] = 0.0
				add_log("%s touching down on Runway %s." % [p["callsign"], grid.runway_name(runway)])

		"LANDING":
			var runway = grid.get_runway(p["runway_id"])
			if runway == null:
				divert(p, "runway removed while landing", 15)
				return
			# Roll along the centreline, then hand back to the taxi grid at the exit.
			if move_toward_point(p, grid.runway_exit_point(runway), ROLLOUT_SPEED, dt):
				var exit_cell: Vector2i = grid.runway_exit_taxiway(runway)
				if exit_cell == AirportGrid.NOWHERE:
					divert(p, "runway lost its taxiway connection", 15)
					return
				if grid.try_claim(exit_cell, p["id"]):
					p["cell"] = exit_cell
					runway["occupied"] = false
					p["runway_id"] = -1
					p["blocked_timer"] = 0.0
					p["state"] = "SEEK_GATE"
					p["state_timer"] = 0.0
				else:
					p["blocked_timer"] += dt
					if p["blocked_timer"] >= MAX_BLOCK_TIME:
						divert(p, "runway exit blocked", 15)

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
				advance_along_path(p, taxi_speed(), dt)
			elif p["path"].is_empty():
				var spot: Vector2i = grid.nearest_free_taxiway(p["cell"], p["id"])
				if spot != AirportGrid.NOWHERE:
					var path := grid.find_path(p["cell"], spot)
					if path.size() > 1:
						set_path(p, path)
			if p["hold_timer"] >= p["max_hold"]:
				divert(p, "too long without a gate", 10)

		"TAXI_TO_GATE":
			match advance_along_path(p, taxi_speed(), dt):
				"arrived":
					p["state"] = "AWAIT_SERVICE"
					p["state_timer"] = 0.0
					p["service_wait"] = 0.0
				"blocked":
					if handle_blocked(p, dt):
						divert(p, "gridlocked on the taxiway", 10)
				"lost":
					var gate = grid.get_gate(p["gate_id"])
					if gate == null:
						divert(p, "gate demolished en route", 10)
					else:
						var path := grid.find_path(p["cell"], grid.gate_park_cell(gate))
						if path.size() > 1:
							set_path(p, path)
						else:
							divert(p, "taxi route destroyed", 10)

		# Parked, but the turnaround cannot begin until ground support frees up.
		"AWAIT_SERVICE":
			p["service_wait"] += dt
			if try_start_service(p):
				p["state"] = "AT_GATE"
				p["state_timer"] = 0.0
				var extra := " (line check)" if p["holds"].has("mech") else ""
				var gate = grid.get_gate(p["gate_id"])
				# No jet bridge means bussing every passenger, which takes longer.
				if gate != null and not grid.gate_is_contact(gate):
					p["turnaround"] *= REMOTE_STAND_FACTOR
					extra += " (remote stand)"
				add_log("%s at Gate %d, turning around%s." % [p["callsign"], p["gate_id"] + 1, extra])
			elif p["service_wait"] >= SERVICE_PATIENCE and not p["delay_logged"]:
				p["delay_logged"] = true
				reputation = max(0, reputation - 4)
				add_log("%s stuck at Gate %d — %s. Reputation -4." % [
					p["callsign"], p["gate_id"] + 1, service_shortfall(p),
				])

		"AT_GATE":
			if p["state_timer"] >= p["turnaround"]:
				var take: int = p["payout"]
				if p["holds"].has("mech"):
					take += MAINT_FEE * REVENUE_SCALE
				money += take
				earned += take
				day_revenue += take
				served += 1
				var rep_gain := REP_PER_TURNAROUND
				if p.get("emergency", false):
					rep_gain = REP_EMERGENCY_HANDLED
					add_log("%s emergency handled. Reputation +%d." % [p["callsign"], rep_gain])
				reputation = min(REP_MAX, reputation + rep_gain)
				add_log("%s turnaround complete. +%s" % [p["callsign"], money_str(take)])
				release_service(p)
				p["state"] = "AWAIT_DEPART"
				p["state_timer"] = 0.0

		"AWAIT_DEPART":
			var departure := find_departure_runway(p)
			if departure.is_empty():
				return
			p["runway_id"] = departure["runway"]["id"]
			p["dep_from_b"] = departure["from_b"]
			set_path(p, departure["path"])
			# Gate frees at pushback, not at the runway — keeps throughput sane.
			var gate = grid.get_gate(p["gate_id"])
			if gate != null:
				gate["occupied"] = false
			p["gate_id"] = -1
			p["state"] = "TAXI_OUT"
			p["state_timer"] = 0.0

		"TAXI_OUT":
			match advance_along_path(p, taxi_speed(), dt):
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
				# Free the taxiway tile: from here the strip is held as a whole.
				grid.release_all(p["id"])
				p["cell"] = AirportGrid.NOWHERE
				set_path(p, [])
				p["state"] = "LINE_UP"
				p["state_timer"] = 0.0
			elif p["state_timer"] >= MAX_BLOCK_TIME:
				tow(p, "never got a takeoff slot")

		# Taxi onto the threshold and align before rolling.
		"LINE_UP":
			var runway = grid.get_runway(p["runway_id"])
			if runway == null:
				tow(p, "runway removed before takeoff")
				return
			var start_end: Vector2 = runway["b"] if p.get("dep_from_b", false) else runway["a"]
			if move_toward_point(p, start_end, taxi_speed(), dt):
				p["state"] = "DEPARTING"
				p["state_timer"] = 0.0

		"DEPARTING":
			var runway = grid.get_runway(p["runway_id"])
			if runway == null:
				tow(p, "runway removed during takeoff")
				return
			var roll_to: Vector2 = runway["a"] if p.get("dep_from_b", false) else runway["b"]
			if move_toward_point(p, roll_to, TAKEOFF_SPEED, dt):
				runway["occupied"] = false
				p["runway_id"] = -1
				p["state"] = "CLIMB_OUT"
				p["state_timer"] = 0.0

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
				add_log("Not enough cash for taxiway (%s)." % money_str(COST_TAXIWAY))
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
				add_log("Not enough cash for that stand (%s)." % money_str(gate_cost))
				return
			money -= gate_cost
			var id := grid.place_gate(cells, size)
			var kind := "widebody stand" if size >= 2 else "stand"
			var gate = grid.get_gate(id)
			if grid.gate_is_connected(gate):
				add_log("Built Gate %d (%s) for %s." % [id + 1, kind, money_str(gate_cost)])
			else:
				add_log("Built Gate %d — NOT connected to a taxiway, no flights will use it." % (id + 1))

		Tool.TERMINAL:
			if not grid.can_place_terminal(cell):
				return
			if money < COST_TERMINAL_TILE:
				add_log("Not enough cash for a concourse section (%s)." % money_str(COST_TERMINAL_TILE))
				return
			money -= COST_TERMINAL_TILE
			grid.place_terminal(cell)
			add_log("Built concourse section for %s — passenger capacity now %d." % [
				money_str(COST_TERMINAL_TILE), capacity("term"),
			])
			if not grid.is_road_served(cell):
				add_log("That concourse has no road access — it handles no passengers.")

		Tool.ROAD:
			if not grid.can_place_road(cell):
				return
			if money < COST_ROAD_TILE:
				add_log("Not enough cash for road (%s)." % money_str(COST_ROAD_TILE))
				return
			money -= COST_ROAD_TILE
			grid.place_road(cell)

		Tool.PARKING:
			if not grid.can_place_parking(cell):
				return
			if money < COST_PARKING_TILE:
				add_log("Not enough cash for a car park (%s)." % money_str(COST_PARKING_TILE))
				return
			money -= COST_PARKING_TILE
			grid.place_parking(cell)
			if not grid.is_road_served(cell):
				add_log("Car park built but has no road to it — handles nobody yet.")

		Tool.DEMOLISH:
			var preview := grid.demolish_preview(cell)
			if preview.is_empty():
				add_log("Can't demolish that — it's in use or empty.")
				return
			var refund := int(round(tile_cost(preview["type"]) * preview["tiles"] * REFUND_RATE))
			grid.demolish(cell)
			money += refund
			add_log("Demolished %d tile(s), recovered %s." % [preview["tiles"], money_str(refund)])

	# Every branch above either returned on failure or changed the layout, so the
	# 3D world is only rebuilt when something actually moved.
	render3d.mark_layout_dirty()


func commit_runway(from: Vector2i, to: Vector2i) -> void:
	# Endpoints are cell centres, but the strip between them is free-angle, so any
	# heading the grid can express is buildable.
	var pa := grid.cell_to_world(from)
	var pb := grid.cell_to_world(to)

	# A drag starting on an existing runway end lengthens it instead of laying a
	# parallel strip alongside.
	var extend_id := grid.runway_extend_target(pa, pb)
	if extend_id >= 0:
		var existing = grid.get_runway(extend_id)
		var before: float = grid.runway_length_tiles(existing)
		var added: float = maxf(0.0, pa.distance_to(pb) / AirportGrid.TILE)
		var ext_cost := int(round(COST_RUNWAY_TILE * added))
		if money < ext_cost:
			add_log("Not enough cash — that extension costs %s." % money_str(ext_cost))
			return
		grid.extend_runway_seg(extend_id, pb)
		# Marked before the no-op check below: the segment was already restamped,
		# so the 3D geometry is stale either way.
		render3d.mark_layout_dirty()
		if is_equal_approx(grid.runway_length_tiles(existing), before):
			add_log("That drag wouldn't lengthen Runway %s." % grid.runway_name(existing))
			return
		money -= ext_cost
		add_log("Extended Runway %s to %s for %s — now takes %s." % [
			grid.runway_name(existing), length_str(grid.runway_length_tiles(existing)),
			money_str(ext_cost), _runway_capability(grid.runway_length_tiles(existing)),
		])
		return

	if not grid.can_place_runway_seg(pa, pb):
		add_log("Runway must be placed on clear ground.")
		return
	var tiles_used: float = pa.distance_to(pb) / AirportGrid.TILE + 1.0
	var cost := int(round(COST_RUNWAY_TILE * tiles_used))
	if money < cost:
		add_log("Not enough cash — that runway costs %s." % money_str(cost))
		return

	money -= cost
	var id := grid.place_runway_seg(pa, pb)
	var runway = grid.get_runway(id)
	var length: float = grid.runway_length_tiles(runway)
	if length < float(AirportGrid.MIN_RUNWAY_LEN):
		add_log("Built Runway %s for %s — TOO SHORT (needs %s)." % [
			grid.runway_name(runway), money_str(cost),
			length_str(float(AirportGrid.MIN_RUNWAY_LEN)),
		])
	elif not grid.runway_is_usable(runway):
		add_log("Built Runway %s for %s — no taxiway connection yet." % [
			grid.runway_name(runway), money_str(cost),
		])
	else:
		add_log("Built Runway %s (%s) for %s — takes %s." % [
			grid.runway_name(runway), length_str(length), money_str(cost),
			_runway_capability(length),
		])
	render3d.mark_layout_dirty()
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
		AirportGrid.TileType.TERMINAL:
			return COST_TERMINAL_TILE
		AirportGrid.TileType.ROAD:
			return COST_ROAD_TILE
		AirportGrid.TileType.PARKING:
			return COST_PARKING_TILE
	return 0


# --- input ---

func _unhandled_input(event: InputEvent) -> void:
	if setup_stage < 2:
		return

	# Save/load stay available after a shutdown so a bad run can be rolled back.
	if event is InputEventKey and event.pressed and not event.echo:
		match event.keycode:
			KEY_F5:
				save_game()
				return
			KEY_F9:
				load_game()
				return

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

	# Under the old top-down view the mouse position WAS the world position. In 3D
	# it is a ray, so every screen coordinate has to be intersected with the
	# ground plane first — see Render3D.screen_to_world().
	if event is InputEventMouseMotion:
		hover_cell = grid.world_to_cell(render3d.screen_to_world(event.position))
		if is_dragging and tool == Tool.TAXIWAY:
			apply_tool_at(hover_cell)
		return

	if not (event is InputEventMouseButton) or event.button_index != MOUSE_BUTTON_LEFT:
		return

	var world := render3d.screen_to_world(event.position)
	var cell := grid.world_to_cell(world)

	if event.pressed:
		if tool == Tool.SELECT:
			_handle_select_click(world, cell)
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
	var dt := 0.0 if (paused or game_over or setup_stage < 2) else delta * speed
	if dt > 0.0:
		_simulate(dt)
		if reputation <= 0:
			_end_run()
	_update_hud()
	_update_ops_ui()
	_update_route_ui()
	_sync_world()
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
		+ "Total earned:    %s" % money_str(earned)
	)
	$UI/GameOverPanel.visible = true
	add_log("GAME OVER — reputation hit zero after %d:%02d." % [minutes, seconds])


# The narrowest link in the chain from approach to stand: airborne slots,
# connected stands, ground crews, terminal capacity. Everything downstream of
# the tower matters, which is why buying tower capacity alone made things worse.
func service_capacity() -> int:
	var stands := 0
	for g in grid.gates:
		if grid.gate_is_connected(g):
			stands += 1
	return maxi(1, mini(
		mini(stands, capacity("crew")),
		mini(capacity("term") / 2, effective_air_capacity())
	))


# Walk-in demand follows capacity rather than a fixed clock. Previously the ramp
# tightened to a flight every 3-6s within five minutes whether or not the player
# had built anything, so a starter airport was flooded by the calendar and lost
# before it could grow. Now growing the airport is what invites more traffic,
# and deliberate pressure comes from routes you signed, weather, and emergencies.
func walkin_gap() -> float:
	var ramp: float = clampf(1.0 - time_elapsed / 600.0, 0.75, 1.0)
	return clampf(26.0 / float(service_capacity()) * ramp, 3.5, 14.0)


# The tower caps concurrent airborne traffic, so tower capacity is the thing
# that decides how many inbound flights the airport can accept at all.
func _try_spawn() -> void:
	if wx_closed():
		next_spawn_at = time_elapsed + 3.0
		return
	if airborne_count() >= effective_air_capacity():
		next_spawn_at = time_elapsed + 2.0
		return
	spawn_plane()
	var gap := walkin_gap()
	next_spawn_at = time_elapsed + gap * (0.75 + randf() * 0.5)


func _simulate(dt: float) -> void:
	time_elapsed += dt
	day_time += dt
	if day_time >= DAY_LENGTH:
		day_time -= DAY_LENGTH
		end_of_day()
	update_weather()
	update_emergencies()
	update_offers()
	process_scheduled_arrivals()

	if time_elapsed >= next_spawn_at:
		_try_spawn()

	for p in planes:
		if p["state"] != "REMOVE":
			update_plane(p, dt)
	for p in planes:
		if p["state"] == "REMOVE":
			grid.release_all(p["id"])
			release_service(p)
	planes = planes.filter(func(p): return p["state"] != "REMOVE")


# --- persistence ---

func save_game() -> void:
	# Saving a shut-down airport would just reload straight back into game over.
	if game_over:
		add_log("Can't save a shut-down airport.")
		return
	var f := FileAccess.open(SAVE_PATH, FileAccess.WRITE)
	if f == null:
		add_log("Could not write the save file.")
		return
	f.store_var({
		"version": SAVE_VERSION,
		"money": money, "reputation": reputation, "time_elapsed": time_elapsed,
		"served": served, "diverted": diverted, "earned": earned,
		"next_spawn_at": next_spawn_at, "plane_id_seq": plane_id_seq,
		"day": day, "day_time": day_time, "day_revenue": day_revenue,
		"last_day_revenue": last_day_revenue, "last_upkeep": last_upkeep,
		"facilities": facilities.duplicate(),
		"routes": routes.duplicate(true),
		"arrival_queue": arrival_queue.duplicate(true),
		"hub_airline": hub_airline,
		"continent_idx": continent_idx,
		"region_name": region.get("name", ""),
		"offer": null if offer == null else offer.duplicate(true),
		"next_offer_at": next_offer_at,
		"grid": grid.to_dict(),
	})
	f.close()
	add_log("Airport saved.")
	_refresh_save_buttons()


func load_game() -> void:
	if not FileAccess.file_exists(SAVE_PATH):
		return
	var f := FileAccess.open(SAVE_PATH, FileAccess.READ)
	if f == null:
		add_log("Could not read the save file.")
		return
	var d = f.get_var()
	f.close()
	if typeof(d) != TYPE_DICTIONARY or d.get("version") != SAVE_VERSION:
		add_log("That save was made by a different version — ignoring it.")
		return

	# Airborne aircraft are not saved, so clear the sky before restoring.
	planes.clear()
	selected_plane_id = -1
	grid.from_dict(d["grid"])
	render3d.mark_layout_dirty()

	money = d["money"]
	reputation = d["reputation"]
	time_elapsed = d["time_elapsed"]
	served = d["served"]
	diverted = d["diverted"]
	earned = d["earned"]
	next_spawn_at = d["next_spawn_at"]
	plane_id_seq = d["plane_id_seq"]
	day = d["day"]
	day_time = d["day_time"]
	day_revenue = d["day_revenue"]
	last_day_revenue = d["last_day_revenue"]
	last_upkeep = d["last_upkeep"]
	facilities = d["facilities"]
	# No aircraft are restored, so nothing is holding ground support.
	for k in used:
		used[k] = 0
	routes = d["routes"]
	arrival_queue = d["arrival_queue"]
	hub_airline = d["hub_airline"]
	# Location has to come back too, or weather and origins would be wrong.
	continent_idx = d["continent_idx"]
	if continent_idx >= 0:
		continent_name = Regions.CONTINENTS[continent_idx]["name"]
		for r in Regions.CONTINENTS[continent_idx]["regions"]:
			if r["name"] == d["region_name"]:
				region = r
		setup_stage = 2
		_show_setup()
	offer = d["offer"]
	next_offer_at = d["next_offer_at"]

	game_over = false
	$UI/GameOverPanel.visible = false
	add_log("Airport restored — the sky starts empty.")


func _refresh_save_buttons() -> void:
	$UI/LoadBtn.disabled = not FileAccess.file_exists(SAVE_PATH)


# GDScript has no thousands separator, and "10800 ft" reads badly.
func _grouped(n: int) -> String:
	var s := str(n)
	var out := ""
	var count := 0
	for i in range(s.length() - 1, -1, -1):
		out = s[i] + out
		count += 1
		if count % 3 == 0 and i > 0:
			out = "," + out
	return out


# Airport money runs to tens of millions, so raw digits are unreadable.
func money_str(v: int) -> String:
	var sign_txt := "-" if v < 0 else ""
	var a: int = absi(v)
	if a >= 1_000_000:
		return "%s$%.1fM" % [sign_txt, a / 1_000_000.0]
	if a >= 10_000:
		return "%s$%.0fk" % [sign_txt, a / 1_000.0]
	return "%s$%s" % [sign_txt, _grouped(a)]


func length_str(tiles: float) -> String:
	return "%s %s" % [_grouped(int(round(tiles * FEET_PER_TILE))), LENGTH_UNIT]


func _class_requirements() -> String:
	var parts := []
	for c in CLASSES:
		parts.append("%s %s" % [c["code"], _grouped(c["min_runway"] * FEET_PER_TILE)])
	return "Needs: " + " / ".join(parts) + " " + LENGTH_UNIT


func _update_ops_ui() -> void:
	var left := int(max(0.0, DAY_LENGTH - day_time))
	var wx_txt := ""
	if not weather.is_empty():
		wx_txt = " · %s %ds%s" % [
			weather["name"], int(max(0.0, weather_until - time_elapsed)),
			" CLOSED" if wx_closed() else "",
		]
	day_label.text = "Day %d · %ds to close%s" % [day, left, wx_txt]
	day_label.modulate = Color(1.0, 0.72, 0.35) if not weather.is_empty() else Color.WHITE

	var stranded := grid.count_tiles(AirportGrid.TileType.TERMINAL, false) \
		- grid.count_tiles(AirportGrid.TileType.TERMINAL, true)
	var road_note := "" if stranded == 0 else "  !! %d concourse unroaded" % stranded
	capacity_label.text = "Airborne %d/%d · Crew %d/%d · Fuel %d/%d\nPax %d/%d · Checks %d/%d\nUpkeep %s/day%s\nLast day: %s in, %s out" % [
		airborne_count(), effective_air_capacity(),
		used["crew"], capacity("crew"),
		used["fuel"], capacity("fuel"),
		used["term"], capacity("term"),
		used["mech"], capacity("mech"),
		money_str(total_upkeep()), road_note,
		money_str(last_day_revenue), money_str(last_upkeep),
	]

	for i in 5:
		var row_used := i < FACILITIES.size()
		$UI/FacilityPanel.get_node("Row%dLabel" % i).visible = row_used
		$UI/FacilityPanel.get_node("Row%dBuy" % i).visible = row_used
		$UI/FacilityPanel.get_node("Row%dSell" % i).visible = row_used
		if not row_used:
			continue
		var f: Dictionary = FACILITIES[i]
		var key: String = f["key"]
		var n: int = facilities.get(key, 0)
		var lbl: Label = $UI/FacilityPanel.get_node("Row%dLabel" % i)
		lbl.text = "%s  x%d\n%d %s · %s · %s/day" % [
			f["name"], n, capacity(key), f["unit"],
			money_str(f["cost"]), money_str(f["upkeep"]),
		]
		$UI/FacilityPanel.get_node("Row%dBuy" % i).disabled = money < int(f["cost"])
		$UI/FacilityPanel.get_node("Row%dSell" % i).disabled = n <= 0


func _update_route_ui() -> void:
	var offer_label: Label = $UI/RoutePanel/OfferLabel
	var active_label: Label = $UI/RoutePanel/ActiveLabel

	if offer == null:
		offer_label.text = "No offers right now.\n\nNext approach in %ds." % int(max(0.0, next_offer_at - time_elapsed))
	else:
		var cls: Dictionary = CLASSES[offer["size"]]
		var lines := []
		match offer["kind"]:
			"charter":
				lines = [
					"%s one-off charter" % offer["airline"],
					"%s from %s (%s)" % [cls["name"], offer["origin"][1], offer["origin"][0]],
					"Pays %d%% of list, no commitment" % int(offer["rate"] * 100.0),
					"About %s for the single flight" % money_str(offer_daily_value(offer)),
				]
			"route":
				lines = [
					"%s wants a daily route" % offer["airline"],
					"%s x %s from %s (%s)" % [offer["per_day"], cls["name"], offer["origin"][1], offer["origin"][0]],
					"Rate %d%% of list, ongoing" % int(offer["rate"] * 100.0),
					"About %s per day" % money_str(offer_daily_value(offer)),
				]
			"hub":
				lines = [
					"%s HUB AGREEMENT" % offer["airline"],
					"%d daily flights across %d origins" % [offer["per_day"], offer["origins"].size()],
					"Rate %d%% of list — deepest discount" % int(offer["rate"] * 100.0),
					"About %s per day" % money_str(offer_daily_value(offer)),
				]
				if hub_airline != "":
					lines.append("!! Drops the %s hub, -%d rep" % [hub_airline, HUB_BREAK_REP])
		if not can_handle_class(offer["size"]):
			lines.append("!! Airport can't handle this yet")
		offer_label.text = "\n".join(lines)

	$UI/RoutePanel/AcceptBtn.visible = offer != null
	$UI/RoutePanel/DeclineBtn.visible = offer != null

	var parts := []
	if hub_airline != "":
		parts.append("HUB: %s" % hub_airline)
	if routes.is_empty():
		parts.append("No routes yet — walk-in traffic only.")
	else:
		parts.append("%d routes · %d flights/day" % [routes.size(), daily_route_flights()])
		for r in routes:
			parts.append("  %s %s %dx %s %d%%" % [
				r["airline"], r["origin"][0], r["per_day"],
				CLASSES[r["size"]]["code"], int(r["rate"] * 100.0),
			])
	# Show the ladder toward a hub so the progression is visible.
	for a in AIRLINES:
		var n := distinct_origins(a)
		if a != hub_airline and n > 0 and n < HUB_ROUTE_REQ:
			parts.append("%s: %d/%d origins to hub" % [a, n, HUB_ROUTE_REQ])
	active_label.text = "\n".join(parts)


func _update_hud() -> void:
	money_label.text = "Cash: %s" % money_str(money)
	rep_label.text = "Reputation: %d" % reputation
	# Reputation is the lose condition, so make it shout before it runs out.
	if reputation < 25:
		rep_label.modulate = Color(1.0, 0.42, 0.38)
	elif reputation < 50:
		rep_label.modulate = Color(1.0, 0.78, 0.35)
	else:
		rep_label.modulate = Color.WHITE
	var clock := "PAUSED" if paused else "%dx" % int(speed)
	next_in_label.text = "Next flight in: %.1fs   [%s]" % [max(0.0, next_spawn_at - time_elapsed), clock]

	var usable_runways := 0
	for r in grid.runways:
		if grid.runway_is_usable(r):
			usable_runways += 1
	var connected_gates := 0
	var wide_stands := 0
	var contact_stands := 0
	for g in grid.gates:
		if grid.gate_is_connected(g):
			connected_gates += 1
			if g["size"] >= 2:
				wide_stands += 1
			if grid.gate_is_contact(g):
				contact_stands += 1
	var longest := 0.0
	for r in grid.runways:
		if grid.runway_is_usable(r):
			longest = maxf(longest, grid.runway_length_tiles(r))
	stats_label.text = "Runways: %d (%d usable, longest %s → %s)\nStands: %d connected of %d (%d widebody, %d bridged)\nAircraft: %d\nServed: %d   Lost: %d" % [
		grid.runways.size(), usable_runways, length_str(longest), _runway_capability(longest),
		connected_gates, grid.gates.size(), wide_stands, contact_stands, planes.size(),
		served, diverted,
	]

	match tool:
		Tool.SELECT:
			hint_label.text = "SELECT — click a plane to see its route,\nthen click a free gate to assign it."
			tool_info_label.text = "Demolish refunds %d%%" % int(REFUND_RATE * 100)
		Tool.TAXIWAY:
			hint_label.text = "TAXIWAY — click or drag to paint.\nGates and runways need a taxiway connection."
			tool_info_label.text = "%s per tile" % money_str(COST_TAXIWAY)
		Tool.RUNWAY:
			hint_label.text = "RUNWAY — drag any angle. 1 tile = %d %s\n%s" % [
				FEET_PER_TILE, LENGTH_UNIT, _class_requirements(),
			]
			# Live length while dragging — you need to know when you cross a
			# class threshold, not after you've paid for the runway.
			if is_dragging and grid.in_bounds(drag_start) and grid.in_bounds(hover_cell):
				var pa := grid.cell_to_world(drag_start)
				var pb := grid.cell_to_world(hover_cell)
				var span: float = pa.distance_to(pb) / AirportGrid.TILE
				# Report the finished length: an extension inherits what is already
				# there, so quoting only the new pavement would understate the class.
				var ext := grid.runway_extend_target(pa, pb)
				var total := span + 1.0
				var cost := int(round(COST_RUNWAY_TILE * total))
				if ext >= 0:
					total = grid.runway_length_tiles(grid.get_runway(ext)) + span
					cost = int(round(COST_RUNWAY_TILE * span))
				var cap := _runway_capability(total)
				var takes := "too short" if cap == "-" else "takes " + cap
				var prefix := "extend to " if ext >= 0 else ""
				# int() has to close before the modulo, not after it: round() returns
				# a float and GDScript's % rejects float operands outright.
				var heading := "%03d°" % (int(round(rad_to_deg(atan2((pb - pa).x, -(pb - pa).y) + TAU))) % 360)
				tool_info_label.text = "%s%s · %s · %s · %s" % [prefix, length_str(total), heading, takes, money_str(cost)]
			else:
				tool_info_label.text = "%s per tile" % money_str(COST_RUNWAY_TILE)
		Tool.GATE_SMALL:
			hint_label.text = "STAND (small) — 1 tile, next to a taxiway.\nTakes Light and Narrowbody."
			tool_info_label.text = money_str(COST_GATE_TILE)
		Tool.GATE_LARGE:
			hint_label.text = "STAND (widebody) — 2 tiles wide.\nTakes any aircraft, including Widebody."
			tool_info_label.text = money_str(COST_GATE_TILE * 2)
		Tool.TERMINAL:
			hint_label.text = "CONCOURSE — click to build. Stands touching one\nget a jet bridge; the rest have to bus passengers."
			tool_info_label.text = "%s · +%d pax units" % [money_str(COST_TERMINAL_TILE), TERM_UNITS_PER_TILE]
		Tool.ROAD:
			hint_label.text = "ROAD — click or drag. Must reach the map edge\nto bring passengers in."
			tool_info_label.text = "%s per tile" % money_str(COST_ROAD_TILE)
		Tool.PARKING:
			hint_label.text = "CAR PARK — click to build beside a road.\nAdds passenger capacity."
			tool_info_label.text = "%s · +%d pax units" % [money_str(COST_PARKING_TILE), PARK_UNITS_PER_TILE]
		Tool.DEMOLISH:
			hint_label.text = "DEMOLISH — click to remove.\nOccupied gates and runways can't be removed."
			tool_info_label.text = "Refunds %d%%" % int(REFUND_RATE * 100)


# --- rendering ---
#
# The world itself is drawn in 3D by `render3d` (see Render3D.gd). What remains
# here is everything that must stay in screen space: labels, the grid overlay,
# and the selected aircraft's route. Those are positioned by projecting a world
# point through the camera with `render3d.world_to_screen()`, so they track the
# 3D scene exactly while staying upright and crisp at any camera angle.

func _sync_world() -> void:
	if render3d == null:
		return
	render3d.rebuild_if_dirty()
	render3d.sync_gates()
	render3d.sync_planes(_plane_records())
	_sync_ghost()


# Altitude is a rendering concern only — the simulation is still purely 2D, and
# deliberately so. Heights are eased rather than snapped so an aircraft rolling
# out of LANDING doesn't drop through the runway in a single frame.
const RENDER_ALT := {
	"AIR_HOLD": 150.0, "APPROACH": 108.0, "INBOUND": 62.0, "CLIMB_OUT": 96.0,
}


func _altitude_of(p: Dictionary, dt: float) -> float:
	var target: float = float(RENDER_ALT.get(p["state"], 0.0))
	var cur: float = float(p.get("_render_alt", target))
	var eased: float = cur + (target - cur) * minf(1.0, dt * 2.2)
	p["_render_alt"] = eased
	return eased


# Carried over verbatim from the old 2D renderer so aircraft state stays as
# readable as it was. The colour now tints a ground ring under the aircraft
# rather than the aircraft itself, which keeps the model's own livery visible.
func _plane_status_color(p: Dictionary) -> Color:
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
	# An emergency has to be findable at a glance, so it overrides state colour.
	if p.get("emergency", false) and p["state"] != "AT_GATE":
		color = Color(1.0, 0.25, 0.55)
	if selected_plane_id == p["id"]:
		color = Color(1.0, 0.37, 0.82)
	return color


func _plane_records() -> Array:
	var dt := get_process_delta_time()
	var out: Array = []
	for p in planes:
		out.append({
			"id": p["id"],
			"pos": p["pos"],
			"heading": p["heading"],
			"altitude": _altitude_of(p, dt),
			"class_code": class_of(p)["code"],
			"airline": p["airline"],
			"status": _plane_status_color(p),
		})
	return out


func _sync_ghost() -> void:
	if tool == Tool.SELECT or not grid.in_bounds(hover_cell):
		render3d.clear_ghost()
		return

	if tool == Tool.RUNWAY:
		if not is_dragging or not grid.in_bounds(drag_start):
			render3d.clear_ghost()
			return
		var pa := grid.cell_to_world(drag_start)
		var pb := grid.cell_to_world(hover_cell)
		var ext := grid.runway_extend_target(pa, pb)
		var span: float = pa.distance_to(pb) / AirportGrid.TILE
		var rcost := int(round(COST_RUNWAY_TILE * (span if ext >= 0 else span + 1.0)))
		var rok := money >= rcost and (ext >= 0 or grid.can_place_runway_seg(pa, pb))
		render3d.set_ghost_runway(pa, pb,
			Color(0.45, 0.95, 0.5, 0.4) if rok else Color(0.95, 0.35, 0.35, 0.4))
		return

	var cells: Array = [hover_cell]
	var ok := true
	match tool:
		Tool.TAXIWAY:
			ok = grid.can_place_taxiway(hover_cell) and money >= COST_TAXIWAY
		Tool.TERMINAL:
			ok = grid.can_place_terminal(hover_cell) and money >= COST_TERMINAL_TILE
		Tool.ROAD:
			ok = grid.can_place_road(hover_cell) and money >= COST_ROAD_TILE
		Tool.PARKING:
			ok = grid.can_place_parking(hover_cell) and money >= COST_PARKING_TILE
		Tool.GATE_SMALL, Tool.GATE_LARGE:
			var size := tool_gate_size()
			cells = grid.gate_cells_for(hover_cell, size)
			ok = grid.can_place_gate(cells) and money >= COST_GATE_TILE * size
		Tool.DEMOLISH:
			var preview := grid.demolish_preview(hover_cell)
			ok = not preview.is_empty()
			if ok:
				cells = preview["cells"]

	var fill := Color(0.4, 1.0, 0.5, 0.35) if ok else Color(1.0, 0.3, 0.3, 0.35)
	if tool == Tool.DEMOLISH and ok:
		fill = Color(1.0, 0.65, 0.2, 0.4)
	render3d.set_ghost_cells(cells, fill)


# --- screen-space overlay ---------------------------------------------------

func _draw() -> void:
	if render3d == null or setup_stage < 2:
		return

	_draw_grid_overlay()
	_draw_selected_route()

	for r in grid.runways:
		_label_runway(r)
	for g in grid.gates:
		_label_gate(g)
	for p in planes:
		_label_plane(p)

	_draw_ghost_label()


# The faint buildable-area grid. Projecting the ground endpoints rather than
# drawing screen-aligned lines means it lands exactly on the 3D ground plane and
# stays correct through every camera rotation.
func _draw_grid_overlay() -> void:
	var line_color := Color(1, 1, 1, 0.05)
	var o := AirportGrid.ORIGIN
	var t: float = AirportGrid.TILE
	var w: float = AirportGrid.COLS * t
	var h: float = AirportGrid.ROWS * t
	for x in range(AirportGrid.COLS + 1):
		var px: float = o.x + x * t
		draw_line(render3d.world_to_screen(Vector2(px, o.y)),
			render3d.world_to_screen(Vector2(px, o.y + h)), line_color, 1.0)
	for y in range(AirportGrid.ROWS + 1):
		var py: float = o.y + y * t
		draw_line(render3d.world_to_screen(Vector2(o.x, py)),
			render3d.world_to_screen(Vector2(o.x + w, py)), line_color, 1.0)


func _draw_selected_route() -> void:
	var p = find_plane(selected_plane_id)
	if p == null or p["path"].is_empty():
		return
	var points := PackedVector2Array([render3d.world_to_screen(p["pos"], Render3D.H_MARKING)])
	for i in range(p["path_index"], p["path"].size()):
		points.append(render3d.world_to_screen(
			grid.cell_to_world(p["path"][i]), Render3D.H_MARKING))
	if points.size() > 1:
		draw_polyline(points, Color(1.0, 0.37, 0.82, 0.65), 3.0)


func _label_runway(r: Dictionary) -> void:
	var length: float = grid.runway_length_tiles(r)
	var usable: bool = grid.runway_is_usable(r)
	var label_color := Color(0.95, 0.55, 0.42) if r["occupied"] else Color(0.81, 0.91, 0.81)
	if not usable:
		label_color = Color(1.0, 0.45, 0.45)

	var label := "RWY %s · %s · %s" % [
		grid.runway_name(r), length_str(length), _runway_capability(length),
	]
	if length < float(AirportGrid.MIN_RUNWAY_LEN):
		label += " (TOO SHORT)"
	elif not usable:
		label += " (NO TAXIWAY)"
	var at: Vector2 = render3d.world_to_screen(r["a"], Render3D.H_MARKING) + Vector2(-14, -10)
	draw_string(ThemeDB.fallback_font, at, label, HORIZONTAL_ALIGNMENT_LEFT, -1, 12, label_color)


func _label_gate(g: Dictionary) -> void:
	var cells: Array = g["cells"]
	var centre := Vector2.ZERO
	for c in cells:
		centre += grid.cell_to_world(c)
	centre /= float(cells.size())

	var tag := "G%d%s" % [g["id"] + 1, "·W" if g["size"] >= 2 else ""]
	var at: Vector2 = render3d.world_to_screen(centre, Render3D.H_GATE) + Vector2(-10, 4)
	draw_string(ThemeDB.fallback_font, at, tag, HORIZONTAL_ALIGNMENT_LEFT, -1, 12,
		Color(0.95, 0.95, 0.95))
	if not grid.gate_is_connected(g):
		draw_string(ThemeDB.fallback_font, at + Vector2(-8, -14), "unconnected",
			HORIZONTAL_ALIGNMENT_LEFT, -1, 10, Color(1.0, 0.55, 0.55))


func _label_plane(p: Dictionary) -> void:
	var label: String = "%s [%s]" % [p["callsign"], class_of(p)["code"]]
	if p.get("emergency", false):
		label = "!! " + label
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

	var alt: float = float(p.get("_render_alt", 0.0))
	var at: Vector2 = render3d.world_to_screen(p["pos"], alt + 18.0) + Vector2(-22, -6)
	# Skip the label while the aircraft is still flying in from off-map, or it
	# renders as clipped text jammed against the screen edge.
	if at.x < 28.0:
		return
	draw_string(ThemeDB.fallback_font, at, label, HORIZONTAL_ALIGNMENT_LEFT, -1, 10,
		Color(1, 1, 1))


func _draw_ghost_label() -> void:
	if tool != Tool.RUNWAY or not is_dragging or not grid.in_bounds(drag_start):
		return
	var pa := grid.cell_to_world(drag_start)
	var pb := grid.cell_to_world(hover_cell)
	var ext := grid.runway_extend_target(pa, pb)
	var span: float = pa.distance_to(pb) / AirportGrid.TILE
	var total: float = span if ext >= 0 else span + 1.0
	var cost := int(round(COST_RUNWAY_TILE * total))
	var at: Vector2 = render3d.world_to_screen(pb, Render3D.H_GHOST) + Vector2(-10, -18)
	draw_string(ThemeDB.fallback_font, at, "%s — %s" % [length_str(total), money_str(cost)],
		HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color(1, 1, 1))


# Largest aircraft class a runway of this length can take, as a letter code.
func _runway_capability(length: float) -> String:
	for i in range(CLASSES.size() - 1, -1, -1):
		if length >= CLASSES[i]["min_runway"]:
			return CLASSES[i]["code"]
	return "-"
