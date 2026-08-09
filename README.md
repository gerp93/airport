# Airport Tycoon — prototype

A Godot 4 airport management sim. You site the airport in a region, lay it out
on a tile grid — runways, taxiways, and stands — and aircraft pathfind along
the taxiways you built, reserving tiles so they queue behind each other. Then
you scale ground operations to match the traffic you sign up for, and cope with
weather and emergencies you didn't.

Placeholder shapes only (rectangles and triangles), no art assets.

## The loop

Aircraft circle in the air until a runway is clear, land, roll out to a
taxiway connection, taxi to a compatible stand, wait for ground support, turn
around for a fee, then taxi back out and depart. Every completed turnaround
returns +1 reputation; every diversion costs 10–15. Reputation hitting zero
shuts the airport down.

Layout quality is the thing you are actually optimizing. A single-width
dead-end taxiway gridlocks almost immediately; a loop lets blocked aircraft
find a detour.

## Location and weather

You pick a continent and then a region at start. That decides which airports
feed you traffic and what weather you operate through. Each weather kind
degrades operations differently rather than being a reskin of one effect:

| Weather | Effect |
|---|---|
| Fog | Tower accepts less traffic |
| Snow | Runways closed for clearing, slower taxiing |
| Thunderstorms | All movements suspended |
| Extreme heat | Every aircraft needs a longer runway |
| Crosswinds | Short runways unusable |

Extreme heat is the real density-altitude effect: hot thin air costs lift and
thrust, so a 9,600 ft runway stops being enough for a narrowbody.

Weather costs revenue more than reputation — arrivals stop coming, aircraft
already holding burn patience at half rate, and diverting during a closure
costs half the usual reputation, because a storm isn't the airport's fault.

## Ground operations

Traffic volume is gated by infrastructure. Each facility is bought in units
that add concurrency *and* daily upkeep, so scaling traffic means scaling
overhead:

| Facility | Capacity per unit | Cost | Upkeep/day |
|---|---|---|---|
| Control Tower | 3 aircraft airborne | $35.0M | $9,000 |
| Ground Crew Team | 2 turnarounds | $1.5M | $3,200 |
| Fuel Truck | 2 refuels | $600k | $900 |
| Terminal Wing | 6 passenger units | $55.0M | $18,000 |
| Maintenance Hangar | 1 check | $22.0M | $7,500 |

The **tower** is the throttle on inbound volume — it caps how many aircraft can
be in the air at once, so accepting more flights means buying more tower.
A turnaround needs a **crew** and a **fuel truck**, plus **terminal** capacity
weighted by class (a widebody consumes three times a regional's share).
Aircraft that park with no support free sit in `AWAIT_SERVICE` and bleed
reputation, so under-building ground ops shows up as delays.

The **maintenance hangar** is upside rather than another penalty: ~12% of
flights want a line check and pay a bonus if you can service it.

Upkeep is billed at the end of each day (90s). Failing to cover it costs
reputation.

## Airline relationships

Three tiers, where commitment buys volume at a worse unit price:

| Tier | Rate | Commitment |
|---|---|---|
| Charter | 130% of list | Single flight, no commitment |
| Route | 85% of list | Recurring daily arrivals from one origin |
| Hub | 70% of list | Heavy daily volume across several origins |

A **hub offer has to be earned** — the airline must already fly three routes
here from *different* origins. Only one hub carrier at a time; taking a new one
breaks the existing agreement for -20 reputation.

Route flights are scheduled across the day rather than dumped at the boundary.
Arrivals aren't hard-capped by your stand count, but a scheduled flight you
can't fit within 40 seconds is **turned away** for reputation — so
over-committing on routes shows up as flights you couldn't take.

**Emergency diversions** arrive unannounced from other airports. They ignore
the tower cap, land through closures, and outrank departures. They pay 160% and
earn +4 reputation handled, but cost 22 lost. They only ever divert aircraft
classes your airport could physically accept.

## Aircraft classes

| Class | Runway | Stand | Fee | Turnaround | Terminal |
|---|---|---|---|---|---|
| Regional | 3,600 ft (6 tiles) | small | ~$36k | 4s | 1 unit |
| Narrowbody | 7,200 ft (12 tiles) | small | ~$96k | 8s | 2 units |
| Widebody | 10,800 ft (18 tiles) | widebody | ~$320k | 13s | 3 units |

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
| Taxiway | T | $500k/tile | Click or drag to paint |
| Runway | R | $1.5M/tile | Drag a straight line; live length readout while dragging |
| Stand S | G | $4.5M | 1 tile — Regional and Narrowbody |
| Stand W | H | $9.0M | 2 tiles — anything |
| Demolish | X | recovers 50% | Removes a whole runway at once |

Capital costs are real 2020s figures — runway pavement at roughly $2,500 per
linear foot, a stand with a jet bridge at $4.5M, an ATC tower at $35M.
Per-flight fees in `CLASSES` are realistic aeronautical revenue too, but
`REVENUE_SCALE` multiplies them by 40, and that is the one deliberate lie in
the model: real airports amortise a runway over decades on grants, not landing
fees, so truthful revenue against truthful capex gives a payback measured in
decades. At 40 a runway pays back in roughly 15 game-days. Set it to 1.0 for
true economics and an unplayable game.

Runways and stands can go anywhere, but only get traffic once **connected to a
taxiway**. Unusable ones are outlined in red and labelled (`TOO SHORT`,
`NO TAXIWAY`, `unconnected`). Occupied stands, in-use runways, and tiles with
an aircraft on them can't be demolished.

Building works while paused, which is the intended way to plan a big change.

## Controls

- `Space` pause, `1`/`2`/`3` for 1x/2x/4x
- `A`/`D` sign or pass the current offer
- `F5`/`F9` save and load
- Tool keys as listed above

Building works while paused, which is the intended way to plan a big change.

## Running it

1. Install [Godot 4.3+](https://godotengine.org/download).
2. Open this folder as an existing project.
3. Press Play (F5).

## Code layout

- `AirportGrid.gd` — tile map, runway/stand entities, `AStarGrid2D`
  pathfinding, placement validation, per-tile claims, and layout serialization.
- `Regions.gd` — continents, regions, their origin airports and weather tables.
  Place names are invented, so nothing claims to describe a real airport.
- `Main.gd` — aircraft state machine, economy, facilities, relationships, build
  tools, HUD, and all rendering (still a single `_draw()`).

Aircraft state flow:

```
AIR_HOLD -> APPROACH -> INBOUND -> LANDING -> SEEK_GATE -> (HOLDING)
         -> TAXI_TO_GATE -> AWAIT_SERVICE -> AT_GATE -> AWAIT_DEPART
         -> TAXI_OUT -> HOLD_SHORT -> DEPARTING -> CLIMB_OUT -> REMOVE
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
flight log to stdout and `--auto-sign` accepts any offer the airport can
handle, so a run exercises the full lifecycle without a player. Either flag
also auto-selects the first region, since headless runs can't click the start
screen. Note the process **exits 0 even on script errors** — grep the output
for `SCRIPT ERROR`.

Because `--auto-sign` signs *everything* regardless of capacity, its runs
deliberately over-commit and are a worst case, not a balance target.

## Status

Still a prototype:
- No sprites, sound, or menus — everything is drawn in code.
- Save/load does not preserve in-flight aircraft (by design; the sky restarts
  empty). It does restore your region, layout, economy, facilities and routes.
- Stands are one aircraft each; no pushback or reverse maneuvers.
- Runways are one-directional — no wind direction or runway-end selection, so
  crosswind weather closes short runways rather than favouring an alignment.
- Weather is a single global condition, not a front that moves through.

Known balance gap: **the hub tier is hard to reach in practice.** An unattended
run ends before a second carrier can qualify, and reaching a hub needs three
routes from one airline plus the tower capacity to fly them. Verifying the
hub-switch penalty required temporarily loosening `HUB_ROUTE_REQ` and starting
reputation. The long-arc content probably needs either a gentler reputation
curve or a longer runway of days to unfold in.

Natural next steps: splitting aircraft and stands into scenes with
`AnimatedSprite2D` when real art exists, runway direction and wind, de-icing as
a winter-specific facility, and passenger satisfaction as a second currency
alongside reputation.
