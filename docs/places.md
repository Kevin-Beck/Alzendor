# Places: rooms, areas, regions and realms

A guide for anyone building the world in [world/seed.json](../world/seed.json).
It says what each level of place is *for*, how big it should be, and how
players get around, so the world keeps a consistent sense of scale and
travel stays a real part of the game. The seed format itself is in the
README; realms are designed in [realms.md](realms.md) and weather in
[weather.md](weather.md).

## The four levels at a glance

| Level | What it is | Typical size | Examples |
|---|---|---|---|
| **Room** | A space a handful of people share comfortably | one room | a kitchen, a front yard, a dock, a tree house, a copse of trees, a small field |
| **Area** | One place with one character, that you can walk through in a minute | 3–15 rooms (dungeons up to ~20) | a house, a small forest with a hiking trail, a dungeon, a market district |
| **Region** | A town or a stretch of land with its own identity: one name on the map, one step of discovery | 3–10 areas, roughly 20–80 rooms | a town; a wilderness of forest climbing to a stony scramble and a summit; a coastline between two ports; a desert holding an oasis, a hunters' camp, a secret dungeon and a trade route |
| **Realm** | A world of its own, defined by what it is rather than its size | 1 region to dozens | a wizard's tower that exists in its own plane (1 region, 2 areas); a chain of islands as big and varied as a continent |

## Rooms

A room is a general space where a handful of people can stand together
comfortably and see each other. It's the unit of "here": everyone in a room
hears what's said, sees who arrives, and can fight what's there. Anything any
number of players can technically fit, but write it for a few.

- **One clear thing to look at.** Give it a name you'd use out loud ("the
  Smithy", "Rift Fall"), a description of two or three sentences, and one to
  four `features` worth `look`ing at or touching.
- **Not too big, not too small.** A whole street is several rooms; a single
  barrel is a feature, not a room. If people in it couldn't reasonably see or
  hear each other, split it. If two rooms would always be visited together and
  nothing separates them, merge them.
- **On the map**, neighbouring rooms sit **20–30 units apart**, in the
  direction of the exit between them (the seed checker insists the line on the
  map matches the direction within 10°). Up and down exits can sit close.
- **Indoors.** Any livable space (a kitchen, a basement, an attic, a dusky
  back room, the inside of a coach) is `"indoor": true`, and its weather is
  always dead neutral and dry: the middle of the weather grid. That makes
  indoors a fair, steady place where ordinary gear works as intended. Only
  exceptional places (a dragon's lair, a forge of the gods) get a fixed
  `climate` of their own instead.
- **Outdoors**, give a `terrain` (forest, coast, marsh…), which nudges the
  realm's weather a little and can make a room safe for players with the
  right ability.
- **Safe rooms** (inns, shrines, camps, a fire in a cave) are where players can
  rest and log out instantly. They're valuable: be generous in towns, rare in
  the wild, and rarer still in harsh realms.

## Areas

An area is one place with one character: a person's house of ten rooms, a
small forest with a hiking trail through it, a dungeon of fifteen rooms. It
has one name and one colour on the map, and its own channel for things like a
bell tolling across a district.

- **3–15 rooms**, so a player can walk end to end in a handful of moves
  (3–8). Dungeons can run to ~20 if they're meant to be a journey of their own.
- **One idea.** If you find yourself describing two different kinds of place,
  make two areas.
- **One to three ways in or out.** Areas join each other through ordinary
  exits. Few entrances make an area feel like a place you enter; many make it
  a crossroads, which is fine for a market square.
- **On the map**, an area's box is drawn around its rooms, so an area is
  typically **60–150 units** across. Keep **at least 30 units** between the
  rooms of neighbouring areas (the seed check insists), so their boxes don't
  overlap. A room belongs to one area, and it must look that way: watch for
  loops of rooms, where an area's box drawn around three corners of a square
  takes in a fourth room that belongs to someone else. Bend the loop with a
  diagonal exit instead.

## Regions

A region is a town, or a stretch of land with a shared identity: a wilderness
where a forest climbs to a stony scramble and a summit; a long beach wrapping
the coast between two port cities; a far-reaching desert holding an oasis, a
hunters' encampment, a secret dungeon and a well-trodden trade route.

A region is where several of the game's systems meet, which is the best
guide to where to draw its edges:

- **One step of discovery.** Regions are what the map discovers: setting foot
  in one shows its neighbours greyed out, maps reveal them, and hidden ones
  stay unknown until found. A region should be a place worth discovering.
- **One channel.** Announcements can reach a whole region.

Weather is **not** per region: a realm has one sky (see
[weather.md](weather.md)), so the weather never jumps about as you walk from
one region to the next. Terrain gives outdoor rooms small local differences
(a sheltered forest, a windy coast).

Sizes and layout:

- **3–10 areas, roughly 20–80 rooms.** Crossing one on foot should take 8–25
  moves.
- **On the map**, a region's box is drawn around its areas: roughly
  **150–500 units** across. Leave **at least 40 units** of clear space between
  regions so their boxes and titles don't collide (the seed check insists).
- **Joined by roads or routes.** Neighbouring regions are joined by one to
  three roads (chains of rooms through an in-between area, like the Cliff
  Stair and Goat Track out of Harrowgate), or by **routes** (below) when the
  journey is long, dull, dangerous or impossible on foot (the High Road
  coach is the only way to Harrowlake).

## Realms

A realm is a world of its own, like a plane in D&D or Magic: The Gathering
(see [realms.md](realms.md)). Its size matters much less than what it *is*:

- **Its weather.** One sky for the whole realm, with a centre and spread for
  each axis: anything from the home realm's full range to a realm that is
  always frozen and howling. Snow and mud, forecasts and "the weather turns"
  all belong to the realm too.
- **Its danger.** How hostile it is, and how few safe places it has.
- **Its ways in and out.** A round trip with a ferryman, or a one-way ticket
  whose exit has to be found and earned.

A realm can be tiny (a wizard's tower in its own plane: one region of two
areas) or vast (a chain of islands as big and varied as a continent, with
dozens of regions joined by sea routes). Each realm has its own map and its
own coordinates: positions in one realm never relate to another's.

## Getting around

Players move one room at a time with exits (`north`, `east`…), or click a
known room on the map and walk the shortest known path automatically. Walking
a known path is quick, so **distance alone isn't the cost of travel**. What
makes travel matter is:

1. **Not knowing the way.** You only see rooms you've been to and glimpses of
   where their exits lead, and in heavy rain or snow you don't even see those.
2. **What's on the road.** Hostile NPCs turn on you as you pass, and leaving a
   fight is fleeing it.
3. **The weather.** Snow and mud hold up every step (up to 3 s in deep snow),
   and harsh realms keep the ground deep all the time.
4. **Routes cost coins and time**, and some only run in certain weather.

### Routes: fast travel


A **route** takes a player from one room to another: `TRAVEL` lists the
routes from where you are, each as the exact command to type, named by its
destination (`TRAVEL VILLAGE GREEN`), and typing it (or the route's button
beside the exits) takes one. Name the `to` room so it reads well as a
destination, and make sure two routes from one room never share one. The same thing covers every kind of jump:

- **A ferry** across the lake to an island, or along the coast between ports.
- **A carriage** along a toll road to a town you can't otherwise reach.
- **A portal mage** who opens a way to another realm.
- **A rift or portal** that only opens under certain conditions.

A route can have:

- **An operator**: an NPC who must be there and friendly to you (a ferryman
  won't take someone his people hate).
- **A fare** in coins.
- **A journey**: a `path` of waypoint rooms (the switchbacks, the high
  pass, the ford) that the ride passes through by itself, one every few
  seconds. Waypoints are drawn as the route on the map, have weather and
  terrain, and can't be walked to. Every ride is private. A route without a
  path (a portal) is instant.
- **Conditions**: weather ranges (a ferry that won't sail in a gale, a portal
  that only opens when the air stirs) and "clear" (no one hostile in the
  way).

Routes to a **hidden region** are only offered once you know it's there: the
ferryman won't take you to an island you've never heard of.

**Travel events** are rare choices on the road (a toll, a stuck wheel, a
squall), worse in bad weather, sometimes an ambush or a shipwreck. They're
designed in [journeys.md](journeys.md).

**When to use a route instead of a road:** when the connection on foot would
be more than about 15 rooms of nothing in particular; when it crosses
something you can't walk (open water, a chasm, the void between realms); or
when a toll, a timetable or the weather should decide who gets through. A
route doesn't replace the land in between: if the land is interesting, build
it, and let the route be the fast, paid way past it.

### Rules of thumb for travel

| Journey | On foot | By route |
|---|---|---|
| Across an area | 3–8 moves | — |
| Across a region | 8–25 moves | a carriage within a big region, if the walk is dull |
| Between neighbouring regions | 5–15 moves of road | a ferry or coach: 3–5 stages, a few coins |
| Far across a realm | not expected | 6–10 stages, more coins; maybe weather-bound |
| Between realms | never | a passage (free or paid) or a gate with conditions |

Fares should feel like a choice, not a toll on every step: a few coins for a
local ferry, more for a long voyage, nothing for a portal you had to earn.

## Checklist for a new place

- Is each room somewhere a handful of people would stand? Is it named, with a
  short description and something to look at?
- Does each area have one idea, 3–15 rooms, and one to three ways in?
- Does each region have a few areas, room to breathe on the map, and a
  reason to be discovered?
- Are livable spaces marked `indoor`, and only truly exceptional places given
  a `climate`?
- Are there safe places in proportion to how dangerous it should feel?
- How do players get here the first time, and how do they get back? By road,
  by route, or only by finding the way?
- Does the seed check pass? (Every server checks it at start, and so do the
  tests.)

## The current world against this guide

- **Alzendor (home realm):** four regions. Harrowgate is a small town (two
  areas, eleven rooms); Harrowlake a village far to the west, over the Harrow
  Mountains, reached only by the High Road coach;
  Spiderwood a wilderness of a forest edge and a webbed hollow; Saltmere a
  hidden island reached by the lake ferry. A coach runs from Harrowgate's
  market square to Harrowlake's village green.
- **The Rimewaste:** one region, Frostfell, of two areas: a deliberately small,
  harsh realm with one safe place.
- **The Stillsands:** one region of one area: a one-way trap whose exit has to
  be earned.

The world is small for now. As it grows, Harrowgate should become a proper
town region (more districts), and the wilderness between towns should follow
the road and route rules above.
