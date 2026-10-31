# Journeys: pace, traps, the clock, and travel events

How getting around should feel, and what can happen on the way. This builds
on [places.md](places.md) (the sizes of places and what routes are) and
keeps the rule from [weather.md](weather.md): every mechanic is read by other
systems, remembered, visible, and a choice. It's all built; the build order
and what changed on the way are at the end. Characters (classes, ancestries, backgrounds) are
in [characters.md](characters.md), and the quest engine that marooned islands
and starting realms use is in [quests.md](quests.md).

## The idea

Walking is the honest way to travel: slow over rough ground, dangerous, and
the way you find things. **Fast travel is genuinely fast**, often the only
practical way to somewhere, but you pay for it in coins and take a small
risk: something may happen on the road. Those happenings are short choices
with small consequences, and once in a long while a real crisis: an ambush,
a shipwreck, a drowning.

## Walking pace

Every step takes time, by the ground you're stepping onto. Click-to-walk still
works: it queues the steps and plays them out, and anything that happens on
the way (an attack, a trap, a refusal) stops it.

| Ground | Step | Terrains |
|---|---|---|
| Road, town, indoors | 0.6 s | rooms with no terrain, `road`, indoor rooms |
| Open | 0.9 s | `coast`, `field`, `forest` |
| Rough | 1.5 s | `mountain`, `marsh`, `deep_forest`, `scree` |

Snow and mud add to this, as now (up to 3 s more in deep snow). These are
deliberately on the quick side for testing; they're seed rules
(`step_ms: {road, open, rough}` and `terrain_ground`), so they can be
tuned later without code.

A 50-room mountain way then takes over a minute of real walking, plus
whatever lives on it. That is what makes a 25-second coach ride worth its
fare.

**The wilds bite.** With movement slower, the wilderness gets more dangerous
creatures that attack as you enter (they already turn on you as you pass;
these strike first and hard), and traps.

## Traps

A trap is set in a room. Walking in springs it unless you pass a check.

- **Seed:** a room's `trap` has a `name` ("a snare of piano wire"), the `stat`
  that avoids it (Poise for tripwires, Focus for runes, Vigor to tear free),
  a `difficulty`, what it does (`damage`, and optionally a condition like
  "slowed: steps take twice as long for 30 s"), `rearm` seconds, and `sign`:
  the subtle warning left nearby.
- **Signs.** Every trap has a sign in a neighbouring room: "a coil of
  trapper's wire half-buried in the leaves", "fresh sawdust and a bent
  nail". It's an ordinary feature, there for anyone who reads the room. A
  careful player learns to stop and `look`.
- **Trapsense** is an ancestry passive (see [characters.md](characters.md)):
  it marks a neighbouring room that holds a trap with a small warning glyph
  on the map, so you see it before you step. Without it, you only have the
  signs.
- **Remembered.** Once you've sprung or sensed a trap, your map keeps a mark
  on that room. A trap you know about you can step around, or walk into
  carefully (`CREEP <direction>`: slower, with a bonus to the
  check).
- **Rearming.** A sprung trap rearms after `rearm` seconds (the trapper
  comes back), so it stays a hazard on a route you use.

## Checks

One rule for every check (traps, travel events, later social encounters):

- A check names a **stat** (Vigor, Poise, Focus, Presence or Resilience).
  The player sees which stat is tested ("Poise check"), not the odds. A 0 in
  that stat is a hint to pick another option.
- The chance is `base + 12% per point in the stat`, clamped to 5–95%, where
  `base` comes from the difficulty: easy 50%, fair 30%, hard 10%.
- A matching **background** (a trade, like Sailor) gives a large bonus
  (+35%) on the checks that suit it, and sometimes unlocks a choice nobody
  else gets. There are no separate skills for now; background is the
  "skill".

## Day and night

A game clock, the same everywhere, with a day of **60 real minutes** for
testing (a seed rule, `day_minutes`, likely 2–4 hours later). It runs
dawn, day, dusk, night.

To earn its place, the clock is read by:

- **Travel events:** many are only possible by day or by night (`when:
  {time: "night"}`): highwaymen at night, market traders by day.
- **What you see:** at night, the map darkens, the weather panel's Time
  wheel shows the moon and how long until daylight, and outdoor room text
  says so. In the wilds at night (outdoors, away from a lit town) you can't
  see the ways you don't know without a light in your hand, and can't walk
  them: it matters where you are when darkness falls. Towns (`"lit": true`
  areas) keep their lamps on.
- **Realms:** a realm can have its own sky: `"sky": "always_day"` (the
  Stillsands' sun never sets) or `"always_night"`.

Not yet: NPCs don't sleep, ferries and coaches run at all hours, and there
are no timetables. Those would all read the same clock later.

## Routes, rebuilt

A route's path is made of **waypoint rooms**: real rooms with a name, a
position on the map, terrain and weather, that you can't walk into or out of.
You only pass through them on a journey.

- **Seed:** a route lists its waypoints in order, `path: ["switchbacks",
  "high_pass", "river_ford"]`, and each waypoint room is
  `"waypoint": true` with no exits. The old `via` room and `stages` lines
  go: a waypoint's description is its stage line ("The coach lurches up the
  switchbacks, the drop beside the wheels a little too close").
- **It plays itself.** You don't press Enter. Every `stage_seconds` (4 s;
  3 s while testing) you move on to the next waypoint and see its line,
  then arrive. The journey only pauses for a travel event's choice.
- **Your own ride.** Every journey is private: your coach, your ferry, your
  events. Nobody waits on anyone else, and if two players board at once,
  each gets a coach. Other players can't see you in a waypoint room, and you
  can't see them, but chat and tells still work. The coach and the
  passengers are part of the telling, not shared rooms.
- **On the map**, a known route is drawn along its waypoints as a road you
  can't walk: a solid two-tone line (a coach road in amber, a ferry lane in
  water blue) with a small vehicle glyph at the middle, and ticks at the
  waypoints. It never takes a click-to-walk path. Hovering shows the route's
  name, fare and command (`TRAVEL VILLAGE GREEN`). While you ride, your dot
  moves along it.
- **When a route appears:** once you've seen the room it leaves from (as
  now with glimpses of rooms past exits).

### The world, rescaled

- The walkable **Lake Road** between Harrowgate and Harrowlake goes.
  Harrowlake moves far to the west on the map, beyond the mountains, and the
  coach is the only way there. Its path climbs the switchbacks and the high
  pass and fords the river: roughly what 50+ rooms of mountain walking would
  be, in about 25 seconds and three coins. The mountain way on foot is noted
  in the seed as future content.
- **Ferries** cross water much faster than any way round, or reach places
  you can't walk to at all (Saltmere). Water isn't drawn on the map for now;
  a ferry lane across empty space is fine.

## Travel events

Rare things that happen on a journey. Each is a short card in the log with a
situation and two to four choices; the journey waits for your choice.

### When they happen

- At each waypoint there's a small chance of an event, **5%**, the same in
  any weather (a route can add its own `risk`). At most one event per
  journey, so most rides have none.
- **Bad weather doesn't make events more likely; it makes them worse.** The
  weather's severity (wind, precipitation, snow on the ground) picks which
  events can happen: in calm weather a wheel stuck in a rut costs a little
  time; in a storm the same stretch can bring a rockslide, a capsizing or a
  drowning.
- An event is drawn from the **pools** the journey belongs to: the route
  (`lake-road`), its kind (`coach`, `ferry`, `portal`), its realm, and
  `any`. Each event has a `weight`, and `when` conditions: weather ranges
  and time of day. **Severe weather has its own events, with worse
  stakes**: a ferry in a gale can capsize, and you can drown.
- Some events happen only **once** per character (a rumour, a mysterious
  passenger); others can repeat (a toll-keeper, a lame horse). The ones
  you've had are remembered (`PLAYER:<id>:events`).
- If you don't choose within **60 s**, the event resolves with its last
  choice (usually the cautious one, "Stay in your seat").

### The choices

A choice can be any of:

- **A check:** "Help push the wheel out of the rut (Vigor check)."
- **A background option:** "(Sailor) Read the current and steer for the
  slack water." Only that background sees it, or it turns a hard check into
  an easy one.
- **A cost:** "Pay the toll-keeper (2 coins)."
- **An answer:** someone asks a question, and the choices are possible
  answers. These are always people: a passenger making small talk ("Do you
  remember the innkeeper's name, back at the Tankard? I never caught it,
  and I owe her a thank-you."), or a riddle from a strange man found adrift
  in a rowboat on the still sea. The answers to small talk are things the
  world told you (a name, a sign, a feature you looked at), so paying
  attention pays.
- **Walking away:** "Stay in your seat." Always available, rarely the best.

### What they do

Small things, mostly, good or bad. Each choice has an `outcome` for success
and one for failure, each a list of effects:

| Effect | Example |
|---|---|
| `delay` / `hasten` | an extra waypoint stop, or skip one |
| `coins` | +3 found in a seat cushion; −2 to a pickpocket |
| `hp` | −10 from a fall; +5 from a passenger's flask |
| `reputation` | a faction's affinity or respect (someone tells the story) |
| `discover` | a region you'd never heard of becomes discovered (a rumour) |
| `rumour` | you hear of a realm; it shows in the All view as a name, unvisited |
| `boon` | a short buff: "well rested: +1 Poise for 20 minutes" |
| `xp` | a little experience |
| `ambush` | surprise combat (below) |
| `strand` | thrown off the route into the wilderness (below) |
| `maroon` | stuck in a pocket area until a quest is done (below) |
| `death` | drowned, or worse: an ordinary death, home to the shrine |

The design rule applies: rumours mark regions on your map, reputation sticks,
and a sailor learns that their trade matters on the water.

### Surprise combat

Very rarely, the ride is attacked: highwaymen, wolves at the ford, something
from the water.

- You're set down at the waypoint and the attackers appear there, **yours
  alone**: copies of seed NPCs owned by your journey, which nobody else sees
  and which vanish when the fight is over.
- **Win**, and you climb back aboard and the journey carries on.
- **Lose, or flee**, and you're **stranded**: you wake at the route's strand
  room for that stretch ("the bottom of the scree below the High Road",
  "washed up on a shingle beach you don't know"), roughed up (a third of
  your health), and the fare is gone. You aren't dead: you walk out through
  the wilderness to the nearest town.
- Some routes need a little wilderness content for this: each stretch of a
  route names a `strand` room, and those rooms connect, by real walking,
  to somewhere. Until the 50-room mountain way exists, the High Road's strand
  room starts a short scree trail back to Harrowgate's outskirts.

Death is different from stranding: drowning when a ferry capsizes, or a
fatal fall, is a real death and sends you home.

### Marooned: pocket areas

The biggest events strand you somewhere small with a goal: the ferry runs
aground on a tiny island, and you have to find supplies to mend it.

- A **pocket area** is a small, hidden area of the same realm (same sky),
  reachable only through an event, with no way out on foot. Other NPCs are
  marooned there too: castaways who help, hint, or have their own troubles.
- Arriving starts a **priority quest** (see [quests.md](quests.md)): the
  quest panel shows its goal ("Find a plank, pitch, and a length of rope,
  then mend the ferry"). Quest items are personal: everyone marooned sees
  their own plank until they take it, so players never compete for them.
- Finish it and the journey carries on from the next waypoint.
- **Logging out** leaves you on the island; you're still there next time.
  **Dying** sends you home and drops the quest. **Being teleported away**
  (an ability, a portal) also drops it. The quest only exists while you're
  on the island.
- Other players marooned at the same time share the island's rooms and can
  help each other, but each has their own quest and items.

### Seed format (sketch)

```json
"travel_events": {
  "rut": {
    "pools": ["coach"], "weight": 3, "when": {"precipitation": [0.2, 1]},
    "text": "The coach lurches and stops: a wheel is sunk in the mud.",
    "choices": [
      {"label": "Help push", "check": {"stat": "vigor", "difficulty": "fair"},
       "success": [{"hasten": 1}, {"reputation": {"faction": "harrowfolk", "affinity": 1}}],
       "failure": [{"hp": -6}, {"delay": 1}]},
      {"label": "Stay in your seat", "success": [{"delay": 2}]}
    ]
  }
}
```

A question choice has `answer: true` on the right one; a background choice
has `background: "sailor"` (only that background sees it) or `bonus:
"sailor"` (that background gets the large bonus).

### A first set of events

About fifteen, enough to feel varied: a wheel in the mud, a toll-keeper, a
pickpocket passenger, a talkative passenger's question, a lame horse, a
fallen tree, a rumour of Saltmere, a rumour of the Rimewaste, a calm sea
fish-jump (a free meal: health), a sudden squall (Sailor bonus), a man adrift
in a rowboat with a riddle, a gale that swamps the ferry (can drown), wolves
at the ford (ambush), highwaymen at night (ambush), and the ferry run aground
(maroon on the first pocket island).

## Build order

1. **Pace and the clock:** step times by ground, the day/night clock and
   what reads it.
2. **Routes rebuilt:** waypoint rooms, journeys that play themselves,
   private rides, routes drawn on the map, the Lake Road removed and
   Harrowlake moved west.
3. **Traps:** traps, signs, the map mark, careful entering.
4. **Travel events:** the event engine, checks, the first events, stranding
   (with the scree trail), and surprise combat with journey-owned NPCs.
5. **Marooned:** the first pocket island and its priority quest (needs the
   quest engine from [quests.md](quests.md)).

Backgrounds and Trapsense came with characters ([characters.md](characters.md)).

**What changed while building it.** Careful stepping is `CREEP <direction>`
(ENTER is already the travel command). The `lore` and `item` event effects
were left out: forecasts are meant to be scarce outside the home realm, and
quests hand out items instead. A route can name its own `events` (the
starting realms' scripted exits) and be `hidden` (only a quest starts it).
Stranding uses one `strand` room per route rather than one per stretch. An
NPC set down by an ambush is a copy of a `template` NPC, owned by the rider;
two riders ambushed at the same waypoint at the same moment would see each
other's fights, which is rare enough to accept.

## Open questions

- How long a game day should be once testing is over (2 hours? 4?).
- Decided: a light exists. A torch in your hand shows the way at night and in
  dark rooms ([characters.md](characters.md), "Worn gear"); it costs you the
  shield.
- Whether travel events should ever happen while walking on foot (a hermit on
  the mountain way), or only on routes.
