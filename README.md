# Airport Tycoon — prototype

A Godot 4 airport management sim. You lay out the airport on a tile grid —
runways, taxiways, and stands — and aircraft pathfind along the taxiways you
built, reserving tiles so they queue behind each other. Bigger aircraft pay
better but demand longer runways and wider stands, so the schedule keeps
raising the bar on your layout.

Placeholder shapes only (rectangles and triangles), no art assets.

## The loop

Aircraft circle in the air until a runway is clear, land, roll out to a
taxiway connection, taxi to a compatible stand, turn around for a payout, then
taxi back out and depart. Every completed turnaround returns +1 reputation;
every diversion costs 10–15. Reputation hitting zero shuts the airport down.

Layout quality is the thing you are actually optimizing. A single-width
dead-end taxiway gridlocks almost immediately; a loop lets blocked aircraft
find a detour.

## Aircraft classes

| Class | Runway | Stand | Payout | Turnaround |
|---|---|---|---|---|
| Light | 3,600 ft (6 tiles) | small | ~$75 | 4s |
| Narrowbody | 7,200 ft (12 tiles) | small | ~$195 | 8s |
| Widebody | 10,800 ft (18 tiles) | widebody | ~$400 | 13s |

**One tile is 600 ft**, shown to the player on the runway tool. Runway lengths
are displayed in feet: ICAO standardises on metres for aerodrome dimensions,
but feet is the US/FAA convention and gives the recognisable landmark numbers
this genre trades on. `FEET_PER_TILE` and `LENGTH_UNIT` in `Main.gd` convert
the whole UI if you'd rather have metres — the tile math is unaffected.

The fleet mix shifts from Light to Narrowbody to Widebody over the first
several minutes. The starter runway is 9,600 ft on purpose — it handles
narrowbodies but is two tiles short of a widebody, so the first widebody on
approach is what tells you to invest in a longer runway.

Aircraft are never cleared to land unless a long-enough runway *and* a
big-enough stand exist, so you get "no runway long enough for a widebody"
rather than a plane landing with nowhere to park.

## Building

| Tool | Key | Cost | Notes |
|---|---|---|---|
| Select | Esc | — | Click an aircraft to draw its route; click a free stand to assign a holding one |
| Taxiway | T | $15/tile | Click or drag to paint |
| Runway | R | $40/tile | Drag a straight line |
| Stand S | G | $250 | 1 tile — Light and Narrowbody |
| Stand W | H | $500 | 2 tiles — anything |
| Demolish | X | refunds 50% | Removes a whole runway at once |

Runways and stands can go anywhere, but only get traffic once **connected to a
taxiway**. Unusable ones are outlined in red and labelled (`TOO SHORT`,
`NO TAXIWAY`, `unconnected`). Occupied stands, in-use runways, and tiles with
an aircraft on them can't be demolished.

Building works while paused, which is the intended way to plan a big change.

## Contracts

Airlines offer contracts: serve N flights of a given class within a deadline
for a cash bonus, or lose reputation. Sign with **A**, pass with **D**.

A signed contract **biases arrivals toward that airline and class**, so it
generates the traffic it asks for. Signing a widebody contract you can't
handle actively floods your approach rather than quietly failing, so passing
is a real decision. Offers state the runway length and stand size they need
and warn when the airport can't handle them yet.

## Controls

- `Space` pause, `1`/`2`/`3` for 1x/2x/4x
- `A`/`D` sign or pass the current contract offer
- `F5`/`F9` save and load
- Tool keys as listed above

## Running it

1. Install [Godot 4.3+](https://godotengine.org/download).
2. Open this folder as an existing project.
3. Press Play (F5).

## Code layout

- `AirportGrid.gd` — tile map, runway/stand entities, `AStarGrid2D`
  pathfinding, placement validation, per-tile claims, and layout serialization.
- `Main.gd` — aircraft state machine, economy, contracts, build tools, HUD,
  and all rendering (still a single `_draw()`).

Aircraft state flow:

```
AIR_HOLD -> APPROACH -> INBOUND -> LANDING -> SEEK_GATE -> (HOLDING)
         -> TAXI_TO_GATE -> AT_GATE -> AWAIT_DEPART -> TAXI_OUT
         -> HOLD_SHORT -> DEPARTING -> CLIMB_OUT -> REMOVE
```

### Traffic reservation

Every aircraft claims the tile it occupies and must claim the next before
moving, so they queue single-file instead of overlapping. Deadlocks are
handled in escalating order: yield priority (arrivals outrank departures),
head-on detection, repathing around claimed tiles, then a divert/tow escape
valve so the airport can never permanently lock up.

Outbound aircraft taxi to a **hold-short** point beside the runway threshold
and only claim the runway once ready to roll, so a long taxi-out doesn't block
arrivals. Aircraft already holding short get priority over new arrivals, or a
steady arrival stream would starve them until they got towed.

### Verifying changes headlessly

```bash
godot --headless --fixed-fps 60 --path . --quit-after 18000 -- --echo-log --auto-sign
```

`--fixed-fps 60` is essential: without it headless runs as fast as possible
and `delta` reflects real time, so thousands of frames simulate only seconds.
With it, 18000 frames is 300 simulated seconds. `--echo-log` mirrors the
flight log to stdout and `--auto-sign` accepts any contract the airport can
handle, so a run exercises the full lifecycle without a player. Note the
process **exits 0 even on script errors** — grep the output for `SCRIPT ERROR`.

## Status

Still a prototype:
- No sprites, sound, or menus — everything is drawn in code.
- Save/load does not preserve in-flight aircraft (by design; the sky restarts
  empty).
- Stands are one aircraft each; no pushback or reverse maneuvers.
- Runways are one-directional — no wind or runway-end selection.
- Balance is tuned against unattended headless runs, which never build
  anything, so it is deliberately pessimistic. Doing nothing loses at ~4:00.

Natural next steps: splitting aircraft and stands into scenes with
`AnimatedSprite2D` when real art exists, ground crew and fuel services as a
second resource to manage, and multiple runway directions.
