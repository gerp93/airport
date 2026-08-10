# TODO

This app's own backlog of future features and fixes — not a KVG_Standards
compliance checklist (see [KVG_Standards](https://github.com/gerp93/KVG_Standards)
and this repo's `REPO_SCOPE.md` entry for that). Just what's not built yet.

## How this is sequenced

The phases are ordered by what unblocks what, not by appeal:

1. **Batching comes before content.** `Render3D` rebuilds *all* static geometry
   on every placement, across a grid that is now 44x26. Every mesh and building
   added before that is fixed makes the problem worse, so Phase 1 precedes
   Phase 4.
2. **The open balance questions gate the economy work.** Four of them are still
   unresolved (bottom of this file) and each needs a play session, not a code
   change. Stacking loans, cargo and satisfaction on top of unresolved balance
   compounds the uncertainty instead of settling it.
3. **Cheap UI wins go first** because they pay off in every later session,
   including the play sessions the balance questions require.

Effort: **S** small, **M** moderate, **L** large. ⚠️ = changes game balance.

## Phase 0 — Housekeeping and cheap UI wins  (DONE)

- [x] Delete `Iso3D.gd` / `Iso3D.tscn`. The look-test spike served its purpose
      when the port landed; it is dead code now. **S**
- [x] Unify "Gate" vs "Stand". Code and log say `Gate 3`, the UI says `Stand S`
      and `Stands:`. *Stand* is the accurate term (a marked parking position);
      *tarmac* is a mass noun and cannot be counted, *apron* is the whole area.
      Pick one and make the log, HUD, buttons and `gates` array agree. **S**
- [x] Confirmation dialog for large purchases. One misclick with Buy Land spends
      $9.7M with no undo. **S**
- [x] Colour-code the flight log by severity. `DIVERTED`, `TURNED AWAY` and
      emergencies currently scroll past looking identical to routine arrivals.
      `bbcode_enabled` is off on `LogLabel` today. **S**
- [x] Facility tooltips. The ops panel shows costs but never says what a Ground
      Crew Team actually gates. **S**
- [x] Help / shortcuts overlay. Tool keys are undiscoverable; the camera hint is
      the only affordance on screen. **S**

## Phase 1 — Technical debt, before more content  (DONE)

- [x] **`MultiMesh` + incremental rebuild.** Done: rebuilds split into three
      tiers (session-static scenery, ownership-gated ground, layout) and per-tile
      geometry batched into `MultiMesh`. Measured on the heaviest terrain:
      6.5ms -> 0.34ms per placement, 9246 -> 294 nodes.
- [x] Multiple save slots. Done: three slots with a picker, F5/F9 quick
      save/load against the last-used slot.

## Phase 2 — Make the existing simulation legible

The sim already models more than the UI reveals; this phase surfaces it rather
than adding new mechanics.

- [ ] Aircraft list panel — click a callsign to select and centre it. Finding a
      specific aircraft is currently a visual hunt. **M**
- [ ] Camera follows the selected aircraft. Pairs with the above. **S**
- [ ] Turnaround progress bar above aircraft at stands. Progress is only
      inferable from the log today. **S**
- [ ] Click a stand or runway for detail: occupancy, current aircraft, and *why*
      it is unusable. **M**
- [ ] Colourblind-safe status palette. Stand free/occupied is green/red and the
      aircraft state colours lean red-green. **S**
- [ ] Minimap. Worth more now that land expands and the camera pans. **M**

## Phase 3 — Economy depth (resolve the open questions first)

Ordered cheap-knob-first, so each can be judged before the next lands.

**Already landed and needing a play session to judge:** demolition now *costs*
a flat `COST_DEMOLISH_TILE` per tile rather than refunding, and anything bought
during a pause can be undone in full until time resumes. Both are new balance
levers that have never been played against.

- [ ] Land holding cost ⚠️. Buying tracts is pure upside once affordable; a small
      per-tile upkeep makes *when* you expand a decision. **S**
- [ ] Fix the starter layout's road ⚠️. Only one of three concourse tiles touches
      the access road, so two-thirds of the building handles nobody. Fixing it
      roughly triples starting passenger capacity — a real balance change, which
      is why it is here and not in Phase 0. **S**
- [ ] Fuel price fluctuation ⚠️. Recurring pressure on margins. **S**
- [ ] Difficulty settings ⚠️. Starting cash and demand multipliers. Also the
      cheapest way to explore the balance questions below. **S**
- [ ] Loans and financing ⚠️. $28M starting cash against $18M per concourse
      section makes early choices brutal; debt would allow ambition and add a
      failure path that is not purely reputation. The single highest-leverage
      economy change. **M**
- [ ] Counter-offers on airline contracts ⚠️. Accept/decline is binary today;
      negotiating rate or volume adds a decision. **M**
- [ ] Cargo flights ⚠️. A second demand stream wanting stands but no concourse,
      which finally gives remote stands a purpose. **M**
- [ ] Night curfew / noise limits ⚠️. Ties to the day timer and would make runway
      placement and alignment matter. **M**
- [ ] Passenger satisfaction as a second currency ⚠️. **L**
- [ ] Milestones and achievements. Gives passive play direction, which is
      relevant to the "doing nothing no longer loses" question. **M**

## Phase 4 — World, atmosphere and assets

Depends on Phase 1 batching.

- [ ] Per-class aircraft meshes. One widebody mesh currently stands in for
      Regional and Narrowbody at different scales. Generatable — see
      *Generated assets* below. **M**
- [ ] Real building meshes: concourse with a roofline and glazing, control tower,
      jetbridges, hangars, service vehicles. Currently untextured boxes. **L**
- [ ] Sound. None exists. Engine noise, ground ambience, weather beds, UI
      feedback, an emergency alert. Generatable — see below. **L**
- [ ] Day/night cycle. Light angle and colour over the day timer. Renderer only,
      no simulation impact. **M**
- [ ] Weather **forecast and gradual onset** ⚠️ — *reframed, see note below*.
      Weather currently flips on and off instantly at a random duration. The
      value is a warning window and a ramp, not spatial variation. **M**
- [ ] Wind direction, so crosswind favours an alignment instead of only closing
      short runways ⚠️. Pairs with the painted runway designators. **M**
- [ ] Regional weather affecting *origins* ⚠️. Distinct from the item above: a
      front sitting over the region could delay or cancel inbound flights from
      particular origin airports. This is the only genuinely *spatial* weather
      idea that means anything here. **M**
- [ ] Seasons ⚠️. Weather frequency shifting over time; leans on the terrain work
      already done. **M**
- [ ] De-icing as a winter facility, tied to snow regions ⚠️. **S**

## Phase 5 — Structural

- [ ] Symmetric land expansion. Currently right/down only, which is what allowed
      every existing coordinate to stay fixed. All four directions means shifting
      the starter airport, `SPAWN_POS` and `AIR_ANCHOR`, and re-testing the
      opening. **M**
- [ ] A competing airport in-region ⚠️. Real pressure against passive play, and
      the most invasive economy change on this list. **L**

## Why "weather fronts" was the wrong framing

The old entry here read "weather is a single global condition, not a front that
moves through". That is a bad goal for this game, because the airport is a
single point: the field is about 6km corner to corner, and real weather does not
meaningfully vary across 6km. A front crossing the map would be animation with
no decision attached.

What is actually missing is **temporal**, not spatial:

- **Forecast.** Knowing snow arrives in 90 seconds creates a real decision — push
  departures out now, or start the turnarounds you cannot finish?
- **Onset and clearing ramps.** Conditions currently snap between clear and
  closed at full severity.

The one spatial version worth having is weather at the *origin* airports, which
are genuinely elsewhere — tracked separately in Phase 4.

## Generated assets — what is actually feasible

Both verified against this toolchain rather than assumed:

- **Meshes: yes, procedurally.** A Python generator can emit valid `.glb`
  directly (confirmed: Godot 4.7.1 imports a generated file cleanly), and
  `Render3D` already builds primitive geometry at runtime. This suits the
  existing art direction, which is flat-material low-poly with no textures —
  the shipped widebody is itself a procedural export. Parametric airliners
  (fuselage length, span, engine count) and buildings are well within reach.
  **Not** feasible: sculpted organic detail, painted textures, normal maps.
- **Sound: yes, synthesised.** WAV generation works with the standard library,
  and numpy is available for anything more involved. Filtered noise plus a
  harmonic stack gives usable jet and turboprop beds; wind, rain and snow are
  shaped noise; UI clicks and alert tones are trivial. **Not** feasible:
  sampled realism, ATC voice, or anything resembling licensed music. Expect
  "stylised and functional", not cinematic.

Neither is blocked on tooling. Both are a question of how much time to spend.

## Open balance questions

These need a play session to answer, not a code change — and they gate Phase 3.

- **Doing nothing no longer loses.** Demand scales with capacity, so a passive
  airport survives indefinitely but never grows. Losing only comes from
  over-committing on routes. Needs a play session to decide whether that
  trade feels right or whether passive play needs some pressure back.
- **The hub tier is hard to reach.** Verifying the hub-switch penalty needed
  `HUB_ROUTE_REQ` and starting reputation temporarily loosened, because a
  normal run ends before a second carrier qualifies.
- **Opening budget may be too tight** now that a concourse section is $18M
  against $28M starting cash.
- **Jet-bridge penalty may be too subtle** — a remote stand is only 40%
  slower, which may not be enough to change where the player puts stands.
- Save/load intentionally drops in-flight aircraft; the sky restarts empty.
  Revisit if that ever feels bad mid-session.
