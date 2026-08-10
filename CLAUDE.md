# CLAUDE.md — airport

An airport management sim in Godot 4 (GDScript), exported as a native desktop
app for Windows/Mac/Linux.

## Standards

This repo follows [gerp93/KVG_Standards](https://github.com/gerp93/KVG_Standards).
See that repo's `game-repos.md` for which standards apply to game repos and
which deliberately don't, and its `REPO_SCOPE.md` entry for this repo's
current scope and open compliance items.

Godot is not yet a stack KVG_Standards covers for release/CI, theming,
update-check, or icon generation. Per that repo's "New tech stacks" process,
those gaps are **not to be papered over locally here** — they need a design
approved by the human and added to KVG_Standards first.

## Architecture

Four scripts, split along deliberate seams:

- `AirportGrid.gd` — tile map, runway/stand entities, `AStarGrid2D` taxi
  pathfinding, placement validation, per-tile claims, landside road network,
  and layout serialization. Contains **no drawing code at all**, which is what
  made the 3D port a renderer swap rather than a rewrite.
- `Regions.gd` — continents, regions, their origin airports and weather
  tables. Place names are invented, so nothing claims to describe a real
  airport.
- `Main.gd` — aircraft state machine, economy, facilities, airline
  relationships, build tools, HUD, and the screen-space overlay.
- `Render3D.gd` — all world geometry, camera and lighting. Knows nothing about
  money, airlines or aircraft states: `Main.gd` hands it plain render records.

### Rendering is 3D isometric, but the simulation is still 2D

The world is drawn in real 3D under an orthographic camera at true isometric
angles. **The simulation itself never gained a third axis** — it is still
`Vector2` world coordinates throughout, and `Render3D.w3()` maps them to 3D as
`(x, height, y)`. Altitude exists only in the renderer (`RENDER_ALT` in
`Main.gd`), derived from aircraft state. Don't push height into the sim.

Three consequences worth knowing before editing:

- **`Main` is still a `Node2D`** with a `Node3D` child. That is deliberate, not
  an oversight: 3D renders through the viewport's `World3D` regardless of the
  parent being 2D, which keeps `_draw()` available for labels and leaves the
  `$UI` CanvasLayer untouched.
- **Text is not drawn in 3D.** Every label is screen-space `draw_string()` in
  `Main._draw()`, positioned by `render3d.world_to_screen()`. Screen-space text
  stays upright and crisp at any camera angle; billboarded `Label3D` does not.
- **The mouse is a ray now.** Under the old top-down view the mouse position
  *was* the world position. Any new input code must go through
  `render3d.screen_to_world()` first.

Static geometry rebuilds only when the layout actually changes
(`mark_layout_dirty()`), because stand occupancy flips constantly while the
layout does not. Aircraft use `assets/models/widebody-airliner.glb`, whose
`livery` material is separate from `shell` — so per-airline colours are a
material override, not an art pipeline.

Aircraft state flow:

```
AIR_HOLD -> APPROACH -> INBOUND -> LANDING -> SEEK_STAND -> (HOLDING)
         -> TAXI_TO_STAND -> AWAIT_SERVICE -> AT_STAND -> AWAIT_DEPART
         -> TAXI_OUT -> HOLD_SHORT -> LINE_UP -> DEPARTING -> CLIMB_OUT
         -> REMOVE
```

### The grid is larger than the airport

`AirportGrid` covers 44x26 cells, but only `START_TRACT` — the original fixed
32x18 playfield, at the same coordinates — is owned at the start. The rest is
divided into `TRACTS` the player buys with the Buy Land tool.

That coordinate choice is load-bearing: keeping `START_TRACT` identical to the
old playfield means the starter layout, the road that has to reach the boundary,
and the whole opening economy are unchanged by expansion existing.

- **Every `can_place_*` goes through `is_buildable()`**, which is `in_bounds()`
  *and* `is_owned()`. New placement code must not check `in_bounds()` alone.
- **Landside is measured against owned land, not the map edge.** A road counts
  as reaching the outside world when it touches an unowned cell or runs off the
  grid. Buying the tract a road used to exit through can therefore strand it —
  the "concourse unroaded" warning is the signal.
- The camera frames `owned_rect()`, so buying land widens the view rather than
  the game opening zoomed out over land nobody owns.
- Terrain features scatter outside `grid_rect()` — the whole 44x26 world — so
  they can never spawn on a buyable tract and block an expansion.

### Two things that will bite you

**Runways are not tiles.** They are free-angle segments defined by two
endpoints in world space, with a rasterized footprint tracked only for
blocking and demolition. Taxiways and stands *are* on the grid. Don't
"simplify" a runway back into a row of cells — that restricts headings to the
eight compass points and was removed on purpose.

**Aircraft are drawn oversized on purpose.** The model is real-world scale
(65.8 units nose-to-tail); at `FEET_PER_TILE = 600` that is 0.36 of a tile and
effectively invisible. `Render3D.PLANE_SCALE_FUDGE` multiplies it, exactly as
the old 2D renderer drew a 21px narrowbody against a 32px tile. Same rule as
`REVENUE_SCALE` below: keep the lie in that one constant.

**`REVENUE_SCALE` is a deliberate lie.** Capital costs in `Main.gd` are real
2020s figures (runway pavement ~$2,500/linear ft, ATC tower ~$28M). Real
airports amortise those over decades on grants, not landing fees, so truthful
revenue against truthful capex gives a payback measured in decades. Per-flight
fees are realistic and `REVENUE_SCALE` multiplies them by 40. Keep the fudge
in that one constant; don't spread compensating tweaks through the economy.

## Verifying changes

There are no unit tests. The simulation is verified by running it headless and
checking the flight log:

```bash
godot --headless --fixed-fps 60 --path . --quit-after 18000 -- --echo-log --auto-sign
```

- `--fixed-fps 60` is **essential**. Without it headless runs as fast as
  possible and `delta` reflects real time, so thousands of frames simulate
  only a few seconds. With it, 18000 frames is 300 simulated seconds.
- `--echo-log` mirrors the in-game flight log to stdout.
- `--auto-sign` accepts any offer the airport can handle, so a run exercises
  the whole relationship lifecycle without a player. It signs *everything*
  regardless of capacity, so its runs deliberately over-commit and are a worst
  case, not a balance target.
- Either flag also auto-selects the first region, since headless can't click
  the start screen.
- **The process exits 0 even on script errors** — grep stdout for
  `SCRIPT ERROR`, don't trust the exit code.

Useful signals in the log: `towed off` and `gridlocked` mean the traffic
reservation system deadlocked; `TURNED AWAY` means scheduled volume exceeded
capacity; `stuck at Stand` names whichever ground resource is short.

The balance run never picks up a build tool, because it has no cursor. Tool
hover/drag code — the HUD readouts, the ghost preview, the renderer's ghost —
is therefore invisible to it, and a crash lived in the runway heading readout
until a human selected the tool. Cover that path too:

```bash
godot --headless --path . --fixed-fps 60 res://ToolSweep.tscn 2>&1 | grep "SCRIPT ERROR"
```

GDScript gotchas that have cost real time here: `clamp()` and
`Dictionary.get()` return `Variant`, so `var x := clamp(...)` fails the
"inferred from Variant" check — use `clampf()`/`minf()`/`maxf()` or annotate
the type. `%g` is not a valid format specifier and throws at runtime, not
parse time. `round()` returns a **float** and `%` rejects float operands, so
`int(round(x) % n)` throws where `int(round(x)) % n` is meant — note that both
parse fine and only the second is correct. Untyped assignment from a preloaded
script's constant (`var t = AirportGrid.TILE`) infers `Variant` and poisons
every expression derived from it, while `var t: float = ...` does not.
