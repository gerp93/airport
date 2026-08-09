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

const CONTINENTS := [
	{
		"name": "North America",
		"regions": [
			{
				"name": "Great Lakes",
				"weather": ["snow", "fog", "storm"],
				"origins": [
					["HRB", "Harbour Point"], ["KWN", "Kewanee"], ["MTC", "Mount Clair"],
					["SBY", "Sandbury"], ["TWL", "Twin Lakes"], ["GRN", "Granite Bay"],
				],
			},
			{
				"name": "Desert Southwest",
				"weather": ["heat", "storm", "crosswind"],
				"origins": [
					["RDM", "Red Mesa"], ["SLV", "Silverton"], ["CTS", "Cactus Flat"],
					["ARY", "Arroyo"], ["PLV", "Palo Verde"], ["DSC", "Dust Creek"],
				],
			},
			{
				"name": "Pacific Northwest",
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
				"weather": ["fog", "storm", "crosswind"],
				"origins": [
					["NHV", "Norderhaven"], ["BRG", "Bruggen"], ["ALK", "Aalkirk"],
					["DNM", "Dunmoor"], ["OST", "Oostvliet"], ["SKG", "Skagen Ness"],
				],
			},
			{
				"name": "Alpine Interior",
				"weather": ["snow", "fog", "crosswind"],
				"origins": [
					["HCB", "Hochberg"], ["VLD", "Valdenne"], ["STM", "Steinmark"],
					["CRV", "Corvara"], ["INB", "Innbruck"], ["MTF", "Montfroid"],
				],
			},
			{
				"name": "Mediterranean",
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
				"weather": ["storm", "fog", "heat"],
				"origins": [
					["KLB", "Kalibang"], ["SRT", "Sri Tanah"], ["MDN", "Madanpur"],
					["HPG", "Hai Phong Bay"], ["BTW", "Batu Wangi"], ["CHT", "Chandthar"],
				],
			},
			{
				"name": "Central Steppe",
				"weather": ["snow", "crosswind", "heat"],
				"origins": [
					["AQT", "Aqtobe Vale"], ["KRG", "Karagan"], ["ULN", "Ulan Dabaa"],
					["TRM", "Turmez"], ["SYK", "Saryk"], ["BLQ", "Balqash"],
				],
			},
			{
				"name": "Island Pacific",
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
				"weather": ["heat", "fog", "crosswind"],
				"origins": [
					["ALT", "Altiplano"], ["CZC", "Cuzcala"], ["PAZ", "La Paza"],
					["QNT", "Quintara"], ["VLC", "Volcan Norte"], ["SRR", "Sierra Roja"],
				],
			},
			{
				"name": "Tropical Lowlands",
				"weather": ["storm", "heat", "fog"],
				"origins": [
					["MNU", "Manaura"], ["BLM", "Belem Verde"], ["IQT", "Iquita"],
					["PTV", "Porto Velha"], ["SNT", "Santarena"], ["CYN", "Cayenna"],
				],
			},
			{
				"name": "Southern Cone",
				"weather": ["crosswind", "storm", "snow"],
				"origins": [
					["PTG", "Patagon"], ["BHB", "Bahia Blanca Sur"], ["MTV", "Montevida"],
					["USH", "Ushara"], ["NQN", "Neuquena"], ["VLP", "Valparana"],
				],
			},
		],
	},
]
