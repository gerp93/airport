extends RefCounted

# Pseudo-real-world geography. A region defines two things: the airports that
# plausibly feed traffic into yours, and the weather you have to cope with.
# Place names are invented rather than real, so nothing here claims to describe
# an actual airport's operations.

# Each weather kind states how it degrades operations:
#   arrivals - multiplier on how much traffic the tower can accept
#   length   - multiplier on the runway length every aircraft requires
#   taxi     - multiplier on taxi speed
#   closed   - runways shut entirely for the duration
#
# "heat" raising the required runway length is the real density-altitude effect:
# hot thin air costs lift and engine thrust, so aircraft need more pavement.
const WEATHER := {
	"fog": {
		"name": "Fog", "arrivals": 0.5, "length": 1.0, "taxi": 1.0, "closed": false,
		"blurb": "low visibility, arrivals restricted",
	},
	"snow": {
		"name": "Snow", "arrivals": 0.5, "length": 1.15, "taxi": 0.65, "closed": true,
		"blurb": "runways closed for clearing",
	},
	"storm": {
		"name": "Thunderstorms", "arrivals": 0.34, "length": 1.0, "taxi": 0.8, "closed": true,
		"blurb": "all movements suspended",
	},
	"heat": {
		"name": "Extreme heat", "arrivals": 1.0, "length": 1.3, "taxi": 1.0, "closed": false,
		"blurb": "density altitude, aircraft need more runway",
	},
	"crosswind": {
		"name": "Crosswinds", "arrivals": 0.7, "length": 1.2, "taxi": 1.0, "closed": false,
		"blurb": "short runways unusable",
	},
}

# Terrain is cosmetic — it changes the ground colour and what is scattered
# around the airport perimeter, never the simulation. Regions share terrains
# where they plausibly look alike, rather than each inventing its own.
#
#   field    - the airport's own ground, inside the fence
#   surround - the land beyond it
#   feature  - what is scattered outside the perimeter
#   accent   - snow caps, foliage; meaning depends on the feature
const TERRAIN := {
	"temperate": {
		"name": "temperate grassland",
		"field": Color(0.19, 0.31, 0.19), "surround": Color(0.227, 0.361, 0.227),
		"feature": "conifers", "feature_color": Color(0.13, 0.26, 0.16),
		"accent": Color(0.20, 0.34, 0.20), "density": 150,
	},
	"desert": {
		"name": "desert",
		"field": Color(0.62, 0.51, 0.33), "surround": Color(0.70, 0.58, 0.39),
		"feature": "mesas", "feature_color": Color(0.55, 0.36, 0.25),
		"accent": Color(0.66, 0.46, 0.32), "density": 70,
	},
	"forest": {
		"name": "temperate rainforest",
		"field": Color(0.17, 0.28, 0.18), "surround": Color(0.15, 0.25, 0.17),
		"feature": "conifers", "feature_color": Color(0.09, 0.20, 0.12),
		"accent": Color(0.14, 0.28, 0.16), "density": 320,
	},
	"coastal": {
		"name": "coastal lowland",
		"field": Color(0.24, 0.33, 0.24), "surround": Color(0.28, 0.36, 0.28),
		"feature": "dunes", "feature_color": Color(0.61, 0.57, 0.40),
		"accent": Color(0.42, 0.45, 0.34), "density": 110,
	},
	"alpine": {
		"name": "alpine",
		"field": Color(0.24, 0.31, 0.24), "surround": Color(0.28, 0.33, 0.29),
		"feature": "mountains", "feature_color": Color(0.34, 0.35, 0.38),
		"accent": Color(0.93, 0.95, 0.97), "density": 46,
	},
	"highland": {
		"name": "high sierra",
		"field": Color(0.42, 0.36, 0.26), "surround": Color(0.46, 0.39, 0.29),
		"feature": "mountains", "feature_color": Color(0.44, 0.33, 0.26),
		"accent": Color(0.88, 0.86, 0.82), "density": 52,
	},
	"scrubland": {
		"name": "dry scrub",
		"field": Color(0.42, 0.42, 0.25), "surround": Color(0.48, 0.46, 0.29),
		"feature": "scrub", "feature_color": Color(0.31, 0.35, 0.21),
		"accent": Color(0.52, 0.48, 0.30), "density": 170,
	},
	"tropical": {
		"name": "tropical",
		"field": Color(0.18, 0.34, 0.20), "surround": Color(0.16, 0.31, 0.19),
		"feature": "palms", "feature_color": Color(0.14, 0.30, 0.17),
		"accent": Color(0.22, 0.42, 0.22), "density": 200,
	},
	"steppe": {
		"name": "open steppe",
		"field": Color(0.47, 0.44, 0.28), "surround": Color(0.52, 0.48, 0.31),
		"feature": "scrub", "feature_color": Color(0.40, 0.39, 0.24),
		"accent": Color(0.55, 0.51, 0.33), "density": 80,
	},
}

const CONTINENTS := [
	{
		"name": "North America",
		"regions": [
			{
				"name": "Great Lakes",
				"terrain": "temperate",
				"weather": ["snow", "fog", "storm"],
				"origins": [
					["HRB", "Harbour Point"], ["KWN", "Kewanee"], ["MTC", "Mount Clair"],
					["SBY", "Sandbury"], ["TWL", "Twin Lakes"], ["GRN", "Granite Bay"],
				],
			},
			{
				"name": "Desert Southwest",
				"terrain": "desert",
				"weather": ["heat", "storm", "crosswind"],
				"origins": [
					["RDM", "Red Mesa"], ["SLV", "Silverton"], ["CTS", "Cactus Flat"],
					["ARY", "Arroyo"], ["PLV", "Palo Verde"], ["DSC", "Dust Creek"],
				],
			},
			{
				"name": "Pacific Northwest",
				"terrain": "forest",
				"weather": ["fog", "storm", "crosswind"],
				"origins": [
					["EVG", "Evergreen"], ["CDR", "Cedar Sound"], ["RNR", "Rainier Vale"],
					["OLP", "Olympia Bay"], ["FRN", "Fern Hollow"], ["STK", "Straitkirk"],
				],
			},
		],
	},
	{
		"name": "Europe",
		"regions": [
			{
				"name": "North Sea Coast",
				"terrain": "coastal",
				"weather": ["fog", "storm", "crosswind"],
				"origins": [
					["NHV", "Norderhaven"], ["BRG", "Bruggen"], ["ALK", "Aalkirk"],
					["DNM", "Dunmoor"], ["OST", "Oostvliet"], ["SKG", "Skagen Ness"],
				],
			},
			{
				"name": "Alpine Interior",
				"terrain": "alpine",
				"weather": ["snow", "fog", "crosswind"],
				"origins": [
					["HCB", "Hochberg"], ["VLD", "Valdenne"], ["STM", "Steinmark"],
					["CRV", "Corvara"], ["INB", "Innbruck"], ["MTF", "Montfroid"],
				],
			},
			{
				"name": "Mediterranean",
				"terrain": "scrubland",
				"weather": ["heat", "storm", "fog"],
				"origins": [
					["PLR", "Portalero"], ["CSB", "Casabella"], ["ARG", "Argenta"],
					["THL", "Thalassa"], ["MRV", "Mirevall"], ["OLB", "Olivabranca"],
				],
			},
		],
	},
	{
		"name": "Asia",
		"regions": [
			{
				"name": "Monsoon Coast",
				"terrain": "tropical",
				"weather": ["storm", "fog", "heat"],
				"origins": [
					["KLB", "Kalibang"], ["SRT", "Sri Tanah"], ["MDN", "Madanpur"],
					["HPG", "Hai Phong Bay"], ["BTW", "Batu Wangi"], ["CHT", "Chandthar"],
				],
			},
			{
				"name": "Central Steppe",
				"terrain": "steppe",
				"weather": ["snow", "crosswind", "heat"],
				"origins": [
					["AQT", "Aqtobe Vale"], ["KRG", "Karagan"], ["ULN", "Ulan Dabaa"],
					["TRM", "Turmez"], ["SYK", "Saryk"], ["BLQ", "Balqash"],
				],
			},
			{
				"name": "Island Pacific",
				"terrain": "tropical",
				"weather": ["storm", "crosswind", "fog"],
				"origins": [
					["ISH", "Ishimura"], ["TKY", "Tokoyama"], ["NHA", "Naha Retto"],
					["PLW", "Palawa"], ["MRI", "Marindu"], ["KSK", "Kasaki"],
				],
			},
		],
	},
	{
		"name": "South America",
		"regions": [
			{
				"name": "Andean Highlands",
				"terrain": "highland",
				"weather": ["heat", "fog", "crosswind"],
				"origins": [
					["ALT", "Altiplano"], ["CZC", "Cuzcala"], ["PAZ", "La Paza"],
					["QNT", "Quintara"], ["VLC", "Volcan Norte"], ["SRR", "Sierra Roja"],
				],
			},
			{
				"name": "Tropical Lowlands",
				"terrain": "tropical",
				"weather": ["storm", "heat", "fog"],
				"origins": [
					["MNU", "Manaura"], ["BLM", "Belem Verde"], ["IQT", "Iquita"],
					["PTV", "Porto Velha"], ["SNT", "Santarena"], ["CYN", "Cayenna"],
				],
			},
			{
				"name": "Southern Cone",
				"terrain": "temperate",
				"weather": ["crosswind", "storm", "snow"],
				"origins": [
					["PTG", "Patagon"], ["BHB", "Bahia Blanca Sur"], ["MTV", "Montevida"],
					["USH", "Ushara"], ["NQN", "Neuquena"], ["VLP", "Valparana"],
				],
			},
		],
	},
]
