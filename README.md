# Airport Tycoon — prototype

A Godot 4 airport management sim. You site the airport in a region, lay it out
on a tile grid — runways, taxiways, and stands — and aircraft pathfind along
the taxiways you built, reserving tiles so they queue behind each other. Then
you scale ground operations to match the traffic you sign up for, and cope with
weather and emergencies you didn't.

Rendered isometrically from procedurally-generated `.glb` meshes (flat,
untextured materials) — no hand-drawn or licensed art assets.

This repo follows [gerp93/KVG_Standards](https://github.com/gerp93/KVG_Standards)
— see that repo's `game-repos.md` for how those standards apply to game repos,
and `TODO.md` here for this game's own backlog.

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
| Control Tower | 4 aircraft airborne | $28.0M | $9,000 |
| Ground Crew Team | 2 turnarounds | $1.5M | $3,200 |
| Fuel Truck | 2 refuels | $600k | $900 |
| Maintenance Hangar | 1 check | $22.0M | $7,500 |

Passenger capacity is not bought here — it comes from **concourse and car park
tiles you place**, which is why terminal layout is a build decision rather than
a number.

The **tower** is the throttle on inbound volume — it caps how many aircraft can
be in the air at once, so accepting more flights means buying more tower.
A turnaround needs a **crew** and a **fuel truck**, plus **passenger** capacity
weighted by class (a widebody consumes three times a regional's share).
Aircraft that park with no support free sit in `AWAIT_SERVICE` and bleed
reputation, naming whichever resource is actually short — so under-building
ground ops shows up as delays that tell you what to fix.

A stand touching a concourse is a **contact stand** with a jet bridge. One that
isn't still works, but every passenger has to be bussed out to it, which makes
the turnaround 40% longer.

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
| Runway | R | $1.5M/tile | Drag **any angle**; live length, heading and cost while dragging |
| Stand S | G | $4.5M | 1 tile — Regional and Narrowbody |
| Stand W | H | $9.0M | 2 tiles — anything |
| Concourse | E | $18M | Stands touching one get a jet bridge |
| Road | O | $400k/tile | Must reach the map edge to bring passengers in |
| Car Park | P | $6.0M | Adds passenger capacity; needs a road beside it |
| Demolish | X | recovers 50% | Removes a whole runway at once |

### Runways

Runways are free-angle segments, not rows of tiles, so any heading is
buildable. They are designated by approach heading in tens of degrees the way
real ones are — an east-west strip is 09/27, a 117° strip is 12/30 — and
parallel runways sharing a heading take mirrored L/C/R suffixes, so 09L reads as
27R from the other end.

Lengthen an existing runway by dragging outward from either end; the new pavement
is projected onto the existing axis so it can never bend, and the readout shows
the finished length so you can see a class threshold coming.

Runways work in both directions, so aircraft depart from whichever end they are
already near. A runway with only one taxiway access point will gridlock, because
every arrival and departure has to funnel through the same tile — build more
than one exit.

### Landside

A road network only counts if it **reaches the map edge**. A concourse or car
park is live only if it touches that network, so an airport with no road access
handles no passengers however much terminal it has built. Passenger capacity is
the sum of road-served concourse and parking.

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

## License

AGPL-3.0 — see `LICENSE`. The game has no third-party dependencies; Godot
Engine itself is MIT, which is permissive and imposes no obstacle, but an
exported build bundles the engine and must carry Godot's copyright notice (see
`game-repos.md` in KVG_Standards).

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
- No sound or menus. Buildings/aircraft render as procedurally-generated 3D
  meshes now, not sprites, but still flat-material and untextured.
- Save/load does not preserve in-flight aircraft (by design; the sky restarts
  empty). It does restore your region, layout, economy, facilities and routes.
- Stands are one aircraft each; no pushback or reverse maneuvers.
- Runways are one-directional — no wind direction or runway-end selection, so
  crosswind weather closes short runways rather than favouring an alignment.
- Weather is a single global condition, not a front that moves through.

**Demand follows capacity, not a clock.** Walk-in traffic scales with the
narrowest link in your chain — airborne slots, connected stands, ground crews,
terminal capacity — so growing the airport is what invites more traffic. An
earlier version tightened arrivals to one flight every 3-6s within five minutes
whether or not you had built anything, which flooded a starter airport by the
calendar. Deliberate pressure now comes from routes you signed, weather, and
emergencies.

Walk-in traffic and emergencies only bring aircraft classes the airport can
physically serve. Unmet widebody demand appears as route offers you can't
accept yet — that is the incentive to build a longer runway, rather than
reputation damage for not having built it already. Routes are the exception: if
you sign a widebody route you can't serve, you were warned, and you pay for it.

With that in place a passive airport now survives indefinitely but never grows;
losing comes from over-committing on routes. Whether that trade feels right is
the main thing still needing real play.

Natural next steps: splitting aircraft and stands into scenes with
`AnimatedSprite2D` when real art exists, runway direction and wind, de-icing as
a winter-specific facility, and passenger satisfaction as a second currency
alongside reputation.
