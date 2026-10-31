# Weather: implementation plan

How [weather.md](weather.md) gets built, in stages. Each stage is usable on
its own and has tests (in [tests/test_weather.py](../tests/test_weather.py)).
A box is ticked when its stage is built and tested. Everything here is built;
what's left for later is in [todo.md](../todo.md) under "Next".

Since this was built, the weather became **realm-wide** (one sky, ground and
forecast per realm, not per region) and **indoors became neutral** (`indoor:
true`; a fixed `climate` only for exceptional places). The stages below are
kept as they were built; [weather.md](weather.md) describes the current design.

## 1. The weather function

- [x] `alzendor/weather.py`: draws each region's sine parameters from
  `weather_seed`, measures the 101 quantiles, and computes the weather the
  same way the Lua does (tests compare the two).
- [x] The seed loader passes each region's parameters to Lua
  (`REGION:<id>:weather`).
- [x] Lua: `weather_at(rid, t)` returns `{x, y, p}` for a room: its climate
  (room, then area), or its region's weather plus terrain nudges. An admin
  override (`alz:weather_override:<region>`) pins a region's weather for
  testing.
- [x] Seed: `weather_seed`, `weather_unit_minutes`, `terrain_weather`, and
  climates for indoor rooms.

## 2. Gear profiles and timing

- [x] Seed: `kinds` (default profiles per gear kind), and `weather` profiles
  and a `description` on gear.
- [x] Lua: `weathered(pid, rid, gear)` gives the factor, the adjusted
  amounts and timings, and the list of modifiers, softened by Resilience.
- [x] `use` and healing land the adjusted amounts; a rhythm's opener takes
  the adjusted period and windows.
- [x] Resilience as a fifth stat.
- [x] The `kit` event carries each gear's profile and current effect.

## 3. Weather panel and tooltips

- [x] `weather` event per player: the place, the three numbers, words,
  ground, visibility, whether it's exact, and the forecast trail.
- [x] Server ticker: every 30 s one server runs `weather_tick`, which updates
  ground, hides and brings back NPCs, announces changes of condition to each
  region, and sends each online player their weather and kit.
- [x] Client: the weather panel (grid, dot or blur, trail, precipitation bar,
  ground), always-visible slots with ▲/▼, and the gear tooltip.
- [x] `weather` command.

## 4. Ground and travel

- [x] Ground (snow and mud per region) built up in `weather_tick`.
- [x] Delayed moves: `move` sends the reason and schedules the move
  (`alz:pending_moves`); `tick` makes it happen. No second move while one is
  pending.
- [x] Cold slows healing outdoors.

## 5. Visibility and NPCs

- [x] Heavy precipitation hides unexplored exits and map glimpses, and stops
  border discovery. Discovery is retried on every move once it clears.
- [x] NPC `active_when`: hiding and coming back in `weather_tick`.

## 6. Forecasts, lore and boons

- [x] `ask <npc> weather` teaches lore for the NPC's `forecasts` regions.
- [x] The forecast horizon follows affinity with the teacher's faction.
- [x] Faction `boons` add to stats; the Character panel shows them.

## 7. Pack and loadout

- [x] Pack limit on `get`; gear grants may overfill.
- [x] No equipping or unequipping while fighting.

## 8. Documentation

- [x] README: weather for players, seed fields, events and commands.
- [x] docs/design.md: stats table with Resilience and boons.
- [x] todo.md: what's built, and the ideas for later.
