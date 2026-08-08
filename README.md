# Airport Tycoon — MVP Demo

A bare-bones Godot 4 prototype of an airport management sim: planes spawn,
queue for a runway, land, taxi to a gate, turn around, and depart. Placeholder
shapes only (rectangles/triangles) — no art assets.

## Gameplay

- Planes circle in the air (orange) if all runways are occupied.
- Planes hold at the taxiway (yellow) if all gates are occupied — click a
  holding plane, then click a free gate, to assign it manually.
- Successful gate turnarounds pay out to your money total.
- Planes that wait too long (no runway or no gate) divert and cost reputation.
- Spend money to build additional gates (up to 6) and runways (up to 3) via
  the HUD buttons — each purchase costs more than the last.
- Flight spawn rate slowly ramps up over the first 3 minutes.

## Running it

1. Install [Godot 4.3+](https://godotengine.org/download) (free).
2. Open this folder as an existing project in the Godot editor.
3. Press Play (F5).

## Status

This is a throwaway logic/feel prototype, not a real game build:
- No sprites — everything is drawn via code (`_draw()`).
- No persistence, sound, menus, or balance tuning.
- Fixed hardcoded movement paths, no pathfinding.

If the core loop feels good, the next step is splitting planes/gates into
proper scenes with `AnimatedSprite2D` nodes once real art exists.
