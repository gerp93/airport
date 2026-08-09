# TODO

This app's own backlog of future features and fixes — not a KVG_Standards
compliance checklist (see [KVG_Standards](https://github.com/gerp93/KVG_Standards)
and this repo's `REPO_SCOPE.md` entry for that). Just what's not built yet.

## Features

- More aircraft models. Rendering is 3D isometric now and aircraft use a real
  mesh, but there is only one — a widebody, scaled down to stand in for the
  Regional and Narrowbody classes. Each class wants its own model.
- Buildings and ground clutter are still untextured boxes. Concourses, car
  parks and the tower would all benefit from real meshes now that there is a
  3D pipeline to hang them on.
- Batch the ground plane. `Render3D` currently emits one `MeshInstance3D` per
  tile, which is fine at 32x18 but wants a `MultiMesh` before the grid grows.
- Runway direction and wind, so crosswind weather favours an alignment
  instead of just closing short runways.
- De-icing as a winter-specific facility, tied to snow regions.
- Passenger satisfaction as a second currency alongside reputation.
- Sound, menus, and a settings screen (none exist).
- Multiple save slots — there is one fixed save file today.

## Fixes / balance

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
- Weather is a single global condition, not a front that moves through.
