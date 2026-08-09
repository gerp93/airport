# Airport Tycoon — MVP Demo

A Godot 4 prototype of an airport management sim. The player lays out the
airport on a tile grid — runways, taxiways, and gates — and aircraft pathfind
along the taxiways they built, reserving tiles so they queue behind each other.
Placeholder shapes only (rectangles/triangles), no art assets.

## Gameplay

### Building

Pick a tool from the bottom toolbar. Costs come out of your money, and
demolishing refunds 50%.

| Tool | Cost | Notes |
|---|---|---|
| Taxiway | $15/tile | Click or drag to paint |
| Runway | $40/tile | Drag a straight line; needs 8+ tiles to be usable |
| Gate | $250 | Must sit next to a taxiway tile |
| Demolish | refunds 50% | Removes a whole runway at once |

Runways and gates can be built anywhere, but they only get traffic once they're
**connected to a taxiway**. Unusable ones are outlined in red and labelled
(`TOO SHORT`, `NO TAXIWAY`, `unconnected`), and the log says why.

Occupied gates, in-use runways, and tiles with an aircraft on them can't be
demolished.

### Flights

Aircraft circle in the air (orange) until a runway is clear, land, roll out to
a taxiway connection, then taxi to a gate along a real A* route. Turnarounds pay
out; the gate frees at pushback.

Outbound aircraft taxi to a **hold-short** point beside the runway threshold and
only claim the runway once they're ready to roll, so a long taxi-out doesn't
block arrivals. Aircraft already holding short get priority over new arrivals.

Reputation drops when an aircraft diverts — no usable runway, all runways busy,
no free gate, no taxi route, or taxiway gridlock. Aircraft that get stuck
outbound are towed off for a fee.

In `Select` mode, click an aircraft to draw its current route, then click a free
gate to reassign a holding aircraft manually.

### Traffic

Every aircraft reserves the tile it occupies and must claim the next one before
moving, so they queue single-file instead of overlapping. Deadlocks are handled
in escalating order: yield priority (arrivals outrank departures), head-on
detection, repathing around claimed tiles, and finally a divert/tow escape valve
so the airport can never permanently lock up.

This is why layout quality matters — a single-width dead-end spine gridlocks
almost immediately, while a loop lets blocked aircraft find a detour.

## Running it

1. Install [Godot 4.3+](https://godotengine.org/download) (free).
2. Open this folder as an existing project in the Godot editor.
3. Press Play (F5).

## Code layout

- `AirportGrid.gd` — tile map, runway/gate entities, `AStarGrid2D` pathfinding,
  placement validation, and per-tile claims.
- `Main.gd` — aircraft state machine, economy, build tools, HUD, and rendering.

Aircraft state flow:

```
AIR_HOLD -> APPROACH -> INBOUND -> LANDING -> SEEK_GATE -> (HOLDING)
         -> TAXI_TO_GATE -> AT_GATE -> AWAIT_DEPART -> TAXI_OUT
         -> HOLD_SHORT -> DEPARTING -> CLIMB_OUT -> REMOVE
```

## Status

Still a logic/feel prototype, not a real game build:
- No sprites — everything is drawn in a single `_draw()` call.
- No persistence, sound, menus, or fail/game-over state.
- Gates are one tile; no pushback or reverse maneuvers.
- Runways are one-directional (no wind or runway-end selection).

Next steps once the loop feels right: splitting aircraft and gates into proper
scenes with `AnimatedSprite2D` nodes when real art exists, scheduled airline
contracts with deadlines, and a game-over state.
