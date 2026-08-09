# VENDORED from gerp93/KVG_Standards — do not edit here.
#   source: packages/godot/kvg_update/kvg_update.gd
#   commit: 66c787e
# Godot has no dependency manager that can pin a git ref, so this is copied in
# rather than pinned. Refresh it with scripts/update-kvg-update.sh and update
# the commit above; fix bugs upstream in KVG_Standards, not in this copy.

extends Node

## Update check for Godot games — KVG_Standards shared component.
##
## Asks GitHub for the latest release tag and compares it to the running build's
## version. Add it as a child node, connect `check_complete`, call `check()`.
##
## DELIBERATELY NOTIFY-ONLY. Unlike kvg_updater (Python) and kvgupdate (Go),
## this does not download or replace anything. Those packages self-replace
## because their apps are single binaries built around that flow; a Godot export
## is an executable plus (usually embedded) resources, and swapping it while the
## engine holds file handles open is platform-specific and easy to get subtly
## wrong. Shipping an untested self-replace into a game is worse than telling the
## player a new version exists and opening the download page. If a game later
## needs true self-update, design it here rather than in the game repo.

signal check_complete(result: Dictionary)

const API_HOST := "https://api.github.com/repos/%s/releases/latest"

var _http: HTTPRequest
var _current := ""
var _repo := ""


func _ready() -> void:
	_http = HTTPRequest.new()
	add_child(_http)
	_http.request_completed.connect(_on_request_completed)


## `repo` is "owner/name". `current_version` is the running build's version,
## with or without a leading "v" — normally
## ProjectSettings.get_setting("application/config/version").
func check(repo: String, current_version: String) -> void:
	_repo = repo
	_current = current_version
	var err := _http.request(API_HOST % repo, ["Accept: application/vnd.github+json"])
	if err != OK:
		_fail("could not start request (%d)" % err)


func _fail(message: String) -> void:
	check_complete.emit({
		"available": false, "latest": "", "current": _current,
		"url": "", "error": message,
	})


func _on_request_completed(result: int, code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	if result != HTTPRequest.RESULT_SUCCESS:
		_fail("network error (%d)" % result)
		return
	# A repo with no releases yet returns 404 — that is a normal state, not a
	# fault, so it must not surface as a scary error.
	if code == 404:
		_fail("no releases published yet")
		return
	if code != 200:
		_fail("GitHub returned HTTP %d" % code)
		return

	var parsed = JSON.parse_string(body.get_string_from_utf8())
	if typeof(parsed) != TYPE_DICTIONARY or not parsed.has("tag_name"):
		_fail("unexpected response from GitHub")
		return

	var latest: String = parsed["tag_name"]
	check_complete.emit({
		"available": is_newer(latest, _current),
		"latest": latest,
		"current": _current,
		"url": parsed.get("html_url", "https://github.com/%s/releases/latest" % _repo),
		"error": "",
	})


## Numeric semver comparison. Compares component by component rather than
## lexically, so 0.10.0 correctly beats 0.9.0 — a string compare would not, and
## that bites early while versions are still pre-1.0 and gaining digits.
static func is_newer(candidate: String, current: String) -> bool:
	var a := _parts(candidate)
	var b := _parts(current)
	for i in 3:
		if a[i] != b[i]:
			return a[i] > b[i]
	return false


static func _parts(v: String) -> Array:
	# Tolerates "v1.2.3", "1.2.3", and trailing suffixes like "1.2.3-rc1".
	var cleaned := v.strip_edges().lstrip("vV")
	var head := cleaned.split("-")[0]
	var bits := head.split(".")
	var out := [0, 0, 0]
	for i in mini(bits.size(), 3):
		out[i] = int(bits[i])
	return out
