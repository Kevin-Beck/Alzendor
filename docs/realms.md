# Realms

Realms are separate worlds, like planes in D&D or Magic: The Gathering. The
home realm is where everyone starts: its weather ranges over everything, and
truly extreme weather is rare. Other realms are where the real challenge is:
fewer safe places, more danger, harsher and narrower weather. You get there
after levelling up and gearing up, and getting home can be hard. This
document is the design and the build plan; the README covers what players and
seed authors need. It follows the rule in [weather.md](weather.md): realms
are read by the weather, the map, travel and death, they're remembered, and
they're a choice you prepare for.

## The levels of place

**Realm › Region › Area › Room.** Every region belongs to one realm. Realms
never touch: no exit leads from one to another, so regions in different
realms never border each other. The only ways between realms are jumps (see
Travel).

Each realm has its own channel, `REALM:<id>`, so something can happen to a
whole realm at once (a storm front, an invasion, an admin `announce realm`).

## Weather per realm

Each realm has **one sky**: every region in it shares the same weather, the
same snow and mud on the ground, and the same forecast, and realms never
share weather with each other. Each realm sets, for each weather axis, a
**centre** and a **spread**: its weather is the value from the weather
function ([weather.md](weather.md)) scaled by the spread and moved to the
centre, `centre + spread × value`, clamped to −1…1. (Outdoor terrain still
nudges it a little; indoors is always neutral.)

- The home realm uses centre 0 and spread 1 on every axis: everything is
  possible, extremes are rare. (Cold and wild together, in a deluge, is about
  0.25% of the time.)
- **The Rimewaste:** temperature −0.85 ± 0.15, energy 0.7 ± 0.3,
  precipitation 0.75 ± 0.25. Frigid, howling, snowing almost always, with
  snow on the ground at full depth: every step is a struggle, and you often
  can't see the way on.
- **The Stillsands:** temperature 0.9 ± 0.1, energy −0.85 ± 0.15,
  precipitation −1 (never). A dead-still glass desert under a burning sun.

A spread of 0 makes the weather fixed. The variation that's left in a harsh
realm is small, but it matters more: whether the wind drops enough for a
rift to open, or the snow eases enough to see. So forecasts stay valuable.

## Forecasts

A forecast is a simulation of the next hour: the weather point moving across
the grid from now to an hour from now, with the precipitation, shown as a
trail on the weather panel and as steps in `weather`. Because weather is
computed, it's certain. Better standing with the teacher's people reaches
further (30 minutes more per 10 affinity, up to 3 hours).

**Foresight is meant to be scarce outside the home realm** (see "Foresight
is a resource" in [weather.md](weather.md)). Other realms are dangerous,
difficult places that aren't easily tamed, and not knowing what the sky will
do next is part of that. In the home realm, friendly locals teach the skies
and standing extends the forecast to three hours. Elsewhere, solid forecasts
should be rare and hard won (a hostile people won over, a quest, a find deep
inside), and short even then: a realm can cap how far ahead anyone sees. What
any explorer can have is a *sense* of where the weather is heading, about 10
minutes ahead, from a skill.

Items can teach a realm's skies (`forecasts` on an item, like `reveals` for
maps). The Rimewaste's storm glass does this now, but it lies in Ember
Hollow, a few steps from the landing, for anyone to pick up. That's too easy
for the new rule; it should be moved somewhere deep and dangerous, or made
the reward for something hard.

## Travel between realms

Travel between realms uses **routes**, exactly as fast travel within a realm
does (see [places.md](places.md)): `travel` lists the routes from where you
are, and `TRAVEL <destination>` takes one. A route can need an operator NPC who is
friendly to you, a fare, weather conditions (`when`) and a room clear of
hostiles (`clear`), and it can be a journey in stages or instant. Underneath
is one function, the jump: send a player to a room, with a line for the room
they leave and the room they arrive in. Abilities and events can call it
later.

- **Portal mages and ferrymen** for the first realms you visit: Sister Ilse
  in the Harrowlake chapel opens a ring of frost to the Rimewaste (`travel
  ring`, or `ask ilse about passage`); Veyra at Rime Landing opens the way
  back. These are round trips.
- **Conditional ways out**: the portal at the Sun Altar opens only when its
  conditions hold. A route with no conditions is always open.
- **One-way realms.** Later realms are one-way tickets: a route takes you in,
  and the way out is somewhere else, behind conditions you have to meet. The
  Stillsands is the first: the rift at the top of the Rimewaste's Howling
  Pass drops you onto its dunes, and the only way home is the portal at the
  Sun Altar. It opens only when a breath of wind stirs (energy −0.78 or
  more), and only when the altar is clear of sand wraiths, who come back
  every 20 seconds. Exits can be very harsh.

## Death and home

When you're defeated in any realm you wake at the home realm's shrine, as
now. That *is* the cost: everything you fought through to get there is lost,
and you have to make the journey again. Logging out in another realm leaves
you there (asleep, if it's not safe), so that's no way out either.

## The map

The map shows the realm you're in. In the **All** view, the other realms
you've been to appear as buttons. Choosing one shows that realm's map as you
knew it on your last visit (you can only explore a realm while you're in
it), and **Area** brings you back to where you are. Discovery, glimpses and
hidden regions work within each realm as before.

## Decisions made, and what's open

| Question | Decision |
|---|---|
| Realm weather | centre and spread per axis; no sharing |
| Constant harsh travel delay | intended |
| Death | always home, at the shrine; no extra penalty beyond the lost journey |
| Way back | routes run by portal mages for the first realms; routes with conditions after that |
| Route conditions | an operator, a fare, weather ranges and "clear of hostiles" to start |
| Map | the current realm; other visited realms as buttons in All |
| Forecast | an hour by default in the home realm; scarce, short and hard won elsewhere; a 10-minute sense of direction from a skill anywhere |

Ideas for later:

- More route conditions: carrying an item, a reputation, a time of day, a
  quest step, a number of players present.
- Realm events on `REALM:` channels (storm fronts, invasions) that shift the
  weather or spawn NPCs for a while.
- Abilities that jump (a recall stone with a long cooldown, a planeshift
  spell), and gear that only works in one realm.

## Build plan

1. [x] Seed `realms` (name, description, `home`, weather centre/spread) and
   `realm` on regions; validation (one home realm, no exits between realms).
2. [x] Lua: realm on regions; `REALM:<id>` channels; one sky per realm
   (waves, centre and spread, ground and forecasts all per realm); the
   forecast at an hour by default; items that teach skies.
3. [x] The jump: `teleport()`, with the map, weather and kit refreshed, and a
   record of realms visited (`PLAYER:<id>:realms`).
4. [x] Routes (`travel`, and `ask <npc> about passage` for an operator) with
   operators, fares, weather and `clear` conditions, instant or in stages.
   (These replaced the first version's passage NPCs and room gates.)
5. [x] Content: the Rimewaste (Frostfell, with Ember Hollow its one safe place)
   and the one-way Stillsands.
6. [x] Map: realms on rooms, areas and regions; the current realm shown; other
   realms as buttons in All.
7. [x] Tests, and the README, weather.md and todo.md updated.
