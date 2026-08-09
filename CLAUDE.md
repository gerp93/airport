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

Two scripts, split along a deliberate seam:

- `AirportGrid.gd` — tile map, runway/stand entities, `AStarGrid2D` taxi
  pathfinding, placement validation, per-tile claims, landside road network,
  and layout serialization.
- `Regions.gd` — continents, regions, their origin airports and weather
  tables. Place names are invented, so nothing claims to describe a real
  airport.
- `Main.gd` — aircraft state machine, economy, facilities, airline
  relationships, build tools, HUD, and all rendering.

Everything is drawn in one `_draw()` with no sprites. That's the known
shortcut to revisit when real art exists — see `TODO.md`.

Aircraft state flow:

```
AIR_HOLD -> APPROACH -> INBOUND -> LANDING -> SEEK_GATE -> (HOLDING)
         -> TAXI_TO_GATE -> AWAIT_SERVICE -> AT_GATE -> AWAIT_DEPART
         -> TAXI_OUT -> HOLD_SHORT -> LINE_UP -> DEPARTING -> CLIMB_OUT
         -> REMOVE
```

### Two things that will bite you

**Runways are not tiles.** They are free-angle segments defined by two
endpoints in world space, with a rasterized footprint tracked only for
blocking and demolition. Taxiways and stands *are* on the grid. Don't
"simplify" a runway back into a row of cells — that restricts headings to the
eight compass points and was removed on purpose.

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
capacity; `stuck at Gate` names whichever ground resource is short.

GDScript gotchas that have cost real time here: `clamp()` and
`Dictionary.get()` return `Variant`, so `var x := clamp(...)` fails the
"inferred from Variant" check — use `clampf()`/`minf()`/`maxf()` or annotate
the type. `%g` is not a valid format specifier and throws at runtime, not
parse time.
