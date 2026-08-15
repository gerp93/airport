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

Static geometry is split into **three rebuild tiers**, by how expensive a
category is to regenerate rather than by who changed it:

- **Session-static** — terrain scenery and the compass, built once and rebuilt
  only by `set_terrain()`.
- **Ownership-gated** — the ground tracts and camera framing, guarded by a
  bitmask of `grid.owned_tracts`.
- **Layout** — tiles, concourses, runways and stands, on `mark_layout_dirty()`.

`mark_layout_dirty()` deliberately takes **no arguments**. A caller cannot know
what it invalidated: painting a taxiway three tiles from a runway flips that
runway's centreline from red to white via `runway_is_usable()`. Per-tile
geometry is batched into `MultiMesh` by material — build instances with
`Basis(UP, yaw) * Basis.from_scale(size)`, never `Basis.scaled()`, which
post-multiplies and silently skews rotated runways. `set_terrain()` calls
`_mats.clear()`, so it must invalidate **all three** tiers or live batches keep
rendering through orphaned materials.

**No authored `.glb` is ever instantiated per placement.** They are not one mesh
each — the taxiway pieces carry 35-82 `MeshInstance3D` children, the stand 68, the
tower 144 — so instancing one scene per object took the rebuild to 1740 nodes and
14ms, on every single tile placed. `_add_model()` accumulates a transform instead;
`_welded_mesh()` welds each model once into a single `ArrayMesh` with one surface
per material, and `_flush_models()` emits one `MultiMesh` per model. 62 nodes and
2.2ms, and a painted tile now costs a `Transform3D` rather than a subtree.

`_add_model()` also takes a `remap` — which repaints or drops individual meshes as
they are welded — and a `shadows` flag. Both are inputs to the weld, so **anything
they depend on must also vary the cache key**; the remap only runs on a miss.

Two things they exist for, both about the taxiway kit:

- **The kit's corner shoulders are repainted as pavement when the diagonal tile
  is pavement too.** Each junction piece fills the outside of its turn fillet
  with dark asphalt, which is right standing in grass and wrong in the middle of
  an apron. They are *repainted*, never dropped: the fillet sharing that corner
  box is only a quarter-disc, so removing the shoulder leaves a crescent of bare
  ground. Corners are identified by **geometry, not name** — the kit's names are
  in its own frame and do not survive the mapping (`corner` opens north and west,
  and `cross`'s "shoulder_sw" sits at its north-west).
- **Roads are autotiled from ONE straight piece, laid twice per cell.** The piece
  carries its edge lines down its two long sides, so the north-south copy can
  draw the west and east edges and the east-west copy the north and south ones —
  between them any subset of the four sides. An edge line is kept only where the
  road does *not* continue and a centre dash only where it does, which gives
  corners lined on the outside, open crossroads, and closed dead ends with no
  second piece. Only the first copy brings its asphalt; two full-tile slabs at
  one height is a z-fight.
- **The kit casts no shadow.** Its pavement, shoulders and fillets are separate
  slabs at slightly different heights, so under a low sun every fillet's curved
  edge threw a quarter-circle of shade across the slab beside it — four per cell
  across an apron. Flat ground has no business casting a shadow; the buildings
  and tower still do.

Anything that varies per placement goes in the **instance** transform, not the
weld — that is how every pier stretches to its own length off one shared mesh.
The weld's `pre` argument is for what is genuinely constant (the taxiway kit's
scale-to-tile and half-length offset) and is part of the cache key's meaning.
Welded meshes survive `set_terrain()`, unlike `_mats`: their materials come out
of the `.glb` and are never rebuilt against the palette.

**The control tower is the one building nothing places.** It is bought in the ops
panel as a *facility*, so the simulation has no idea where it stands and
`Render3D` picks the site itself: the nearest empty tile to the movement area,
preferring one that stands clear on all four sides. "Clear" is graded, not binary
— a neighbouring *building* is disqualifying (weight 1000, so distance only breaks
ties within that tier), while neighbouring *pavement* is merely unwanted (2.0 per
side, since the base is 41 units across a 32-unit tile and overhangs). Standing
over the movement area is the tower's whole job, so pavement must never
disqualify a site: an early flat 6.0 nudge pushed the tower clean across the
runway. The site is recomputed on every layout
rebuild, so building over it relocates the tower rather than leaving it inside a
new taxiway. `Main` pushes the count through `set_tower_count()` every frame —
a no-op unless the number moved — because buying, selling, undoing and loading
would otherwise each have to remember to invalidate the renderer. One building
however many units are commissioned; further units are controllers, not a second
tower.

Stand *pads* stay individual `MeshInstance3D`s on purpose: `sync_stands()`
recolours them every frame, and batching would force per-instance colour. The
stand *model* sitting on the pad is welded and batched like every other. Aircraft use `assets/models/widebody-airliner.glb`, whose
`livery` material is separate from `shell` — so per-airline colours are a
material override, not an art pipeline.

Aircraft state flow:

```
AIR_HOLD -> APPROACH -> INBOUND -> LANDING -> SEEK_STAND -> (HOLDING)
         -> TAXI_TO_STAND -> AWAIT_SERVICE -> AT_STAND -> AWAIT_DEPART
         -> PUSHBACK -> TAXI_OUT -> HOLD_SHORT -> LINE_UP -> DEPARTING
         -> CLIMB_OUT
         -> REMOVE
```

### The HUD is laid out in code, not in the scene

`Main.tscn` still carries `offset_*` on every control, but **none of it is what
you see**. `_layout_ui()` overwrites the position and size of every HUD node from
the live viewport size, and it runs on `size_changed`. Editing offsets in the
editor changes the editor preview and nothing else — change `_layout_ui()`.

The screen is three regions that never overlap: a **top strip** across the full
width, a **right sidebar**, and a **full-width bottom bar**. The sidebar stops
where the bottom bar starts, which is what gives the toolbar room for every
tool; the old fixed layout ran the speed buttons straight over the route panel.
Vertical space is claimed sidebar-first — its contents have a real minimum — and
the flight log absorbs whatever is left over. Sizing the log first is what used
to push the route list out through the bottom of its own panel.

Two `Panel` backdrops (`hud_top`, `hud_bottom`) sit behind the text and are
`move_child(_, 0)`'d to the back, because they are added after the scene's own
controls. In-world `draw_string()` labels get their own plate via
`_plate_string()` — an outline still loses contrast against desert tan or snow,
a plate cannot.

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

**Terminals, concourses and stands are one mesh each.** `TERMINAL_SIZE` 6x2,
`CONCOURSE_SIZE` 1x6, `STAND_SIZE` 2x3 are their footprints in tiles, which is why
they are fixed-size entities rather than painted tiles — one model per building.
The hierarchy is load-bearing: a **hall** is landside, needs a road and is where
passenger capacity comes from; **piers** hang off it end-on and add no capacity
of their own; **stands** attach to a *pier*, never to the hall, and only a stand
touching a pier gets a jet bridge. Demolishing a hall orphans its piers rather
than destroying them.

Two of those three sizes are *not* the mesh's own, and both for a reason:

- **A stand is three cells across a 56-unit mesh, and the odd number is the
  point.** Its lead-in line has to land on a taxiway centreline, and centrelines
  run down the middle of a cell — so the lead-in axis must be a cell centre. An
  even width puts it on the grid line between two cells and needs a half-tile
  correction, which then slides the mesh 16 units off centre in a 64-wide
  footprint and leaves it overhanging the next tile by 12. At a pier root that
  neighbour is the hall, and the two visibly interpenetrated. Three cells needs
  no correction at all. The correction survives in `stand_park_point()` only as a
  fallback for a stand turned across its own pier — the player's mistake, but an
  unreachable stand is a worse answer than a shifted one.
- **A pier is a design figure, stretched from a 30x120.5 mesh.** Six tiles takes
  two stands per flank; four could only ever take one once stands widened.
  `_place_pier()` scales **length only** — width and height are pinned to the
  tile. Uniform scaling happened to work at four tiles (128/120.5 = 1.06) and was
  luck: at six the same factor is 1.59 and the pier comes out 1.6 tiles wide,
  straddling the stands on both flanks. `COST_CONCOURSE` is derived per tile from
  `CONCOURSE_SIZE` so lengthening one cannot quietly discount it.

**`stand_park_cell()` returns the cell the lead-in runs through**, not the first
one touching a taxiway. `Render3D._on_stand_leadin()` branches the taxiway into
exactly one cell of a stand, so taking any other routes the aircraft in one cell
to the side of its own painted turn-off.

`TileType`'s ordinals are serialized, so the old `TERMINAL` member (4) was
*renamed* to `CONCOURSE` — which is what those tiles always functionally were,
since stands attached to them — and the new `TERMINAL` was appended as 7. Old
saves therefore load with their buildings as concourses.

**Placement has an axis, and same rot means perpendicular.** Anything larger
than one tile reads `build_rot` (0 east, 1 south), flipped with **Q** — `R` is
the Runway tool and moving it would invalidate the shortcut sheet. Both building
meshes are authored with their long axis on the same axis, so a hall and a pier
at the *same* rot are automatically at right angles to each other. A stand's
three-cell width lies along the pier at the same rot, so the rule holds for all
three — and rot genuinely moves a stand's footprint now, where a square one only
turned its jet bridge.

Everything the sim reads off a stand — `stand_park_cell`, `stand_is_connected`,
`stand_is_contact`, `stand_park_heading` — walks neighbours rather than assuming
an axis. Keep it that way.

**A pier pushes stands off the through taxiway, which is a deadlock risk.** The
old layout put its stands straight onto a through row. Behind a pier they sit
off service lanes instead, and a single-width lane serving two stands is a
cul-de-sac: two aircraft wanting stands off the same lane have nowhere to pass
and get towed. The starter therefore puts one stand per lane, and it took three
balance runs to find — the failure is intermittent.

**Lane *depth* is the other half of that, and it is measured, not guessed.** A
departure crosses the lane before it has anywhere to pass, so the number that
matters is how many single-width cells lie between the stand's lead-in cell and
the apron. Two is safe. Running the lane the full three cells of the stand's
width instead — the obvious thing to do when stands widened — cost 5 gridlocks and
2 tows a run. The starter's lanes are two cells for that reason, and the stand's
other cells simply front onto grass and apron, which is what a real stand does.

**Pausing is an undo window, and demolition costs money.** Every purchase routes
through `_spend()`, which records it in `pause_ledger` while paused. Demolishing
or selling it during that same pause refunds the full amount; resuming time is
the commit point and asks for confirmation. After that, demolition refunds
nothing and *charges* `COST_DEMOLISH_TILE` per tile. `REFUND_RATE` survives only
for selling facilities, which are equipment and genuinely resaleable.

**Log severity is stored beside each line, never baked into it.** `--echo-log`
mirrors the plain text to stdout and the balance-run verification below greps
that output, so putting bbcode into `log_lines` would corrupt the documented
check. The timestamp's own brackets are escaped as `[lb]`.

**The bank lends against reputation, not assets.** `credit_limit()` is
`LOAN_LIMIT_PER_REP * reputation`, so a well-run airport can borrow into its next
expansion and a failing one cannot borrow out of trouble — and an overdrawn day
costs reputation, which *narrows* the facility. Interest is charged daily in
`end_of_day()` before upkeep and nothing amortises automatically. The rate has to
stay well under what capital returns at `REVENUE_SCALE` (a runway pays back
around 6-7%/day) or borrowing is never worth doing, and far enough under that
debt is not simply free. Borrowing and repaying deliberately bypass `_spend()`:
they are not purchases and there is nothing to undo.

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
godot --headless --path . --fixed-fps 60 res://ToolSweep.tscn 2>&1 | grep -E "SCRIPT ERROR|FAILED"
```

`ToolSweep` also carries the invariants no headless *simulation* run can reach,
because they need a cursor, a window or a button: land ownership, both placement
axes, borrowing and repayment, and the HUD layout at three window sizes. Its
assertions print `LAND CHECK FAILED` and `push_error`, so grep for `FAILED` as
well as `SCRIPT ERROR`. When adding one, break it deliberately once and confirm
it reports — an assertion that never runs is worse than no assertion.

GDScript gotchas that have cost real time here: `clamp()` and
`Dictionary.get()` return `Variant`, so `var x := clamp(...)` fails the
"inferred from Variant" check — use `clampf()`/`minf()`/`maxf()` or annotate
the type. `%g` is not a valid format specifier and throws at runtime, not
parse time. `round()` returns a **float** and `%` rejects float operands, so
`int(round(x) % n)` throws where `int(round(x)) % n` is meant — note that both
parse fine and only the second is correct. Untyped assignment from a preloaded
script's constant (`var t = AirportGrid.TILE`) infers `Variant` and poisons
every expression derived from it, while `var t: float = ...` does not.
