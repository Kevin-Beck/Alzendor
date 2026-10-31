# Quests: options for Alzendor

These were the ways quests could work in Alzendor, with
what each one costs and how it fits the architecture we already have. The
recommendation is at the end, followed by **the decided design**, which the
marooned islands ([journeys.md](journeys.md)) and the starting realms
([characters.md](characters.md)) are the first to use.

## What we already have to build on

- **Events on channels.** Everything that happens is an event appended to a
  Redis Stream (`ROOM:`, `AREA:`, `REGION:`, `PLAYER:`), in one global order.
  Kills, heals, emotes, moves, item pickups and reputation changes are already
  events with structured fields (`type`, `verb`, `actor`, `target`,
  `entity_id`).
- **Deeds.** `deed(pid, name, nid)` in `alzendor.lua` is a single choke point
  where "the player did X involving NPC Y" is recorded and judged by every
  faction's culture. It's the natural hook for quest progress too.
- **Atomic rules in Lua.** Any quest check that changes state (give a reward,
  advance a step) can run in the same atomic function as the action that
  triggered it, so a quest can't half-complete.
- **Static content from the seed, live state in Redis.** Quest definitions
  would live in `world/seed.json` like gear and factions; each player's
  progress would be keys like `PLAYER:<id>:quest:<qid>`.
- **Factions with two axes.** Quests can require or reward affinity *or*
  respect, which is more interesting than a single reputation number.

## Ways quests could be built

### 1. Objective lists (classic)

A quest is a list of steps, each a condition on deeds or events: "kill 3 dock
rats", "bring the iron horseshoe to Brannoc", "visit the lighthouse". Progress
is a counter per step.

- **Architecture:** quest definitions in the seed; `deed()` (and `get`,
  `move`, `say`) call `advance_quests(pid, deed, subject)`, which matches the
  player's active quests' current step and bumps counters. Rewards (XP, gear,
  reputation) are granted in the same atomic call.
- **Pros:** simple, predictable, easy to show in a quest log panel.
- **Cons:** feels like a checklist, and doesn't use the culture system.

### 2. Talking to NPCs (dialogue triggers)

NPCs respond to `say` aimed at them (we already have "says to Marta"). A
quest starts when you ask the right NPC the right thing: keywords in what you
say, matched against the NPC's topics.

- **Architecture:** NPC `topics` in the seed (`"work": "The rats are at it
  again…"`, with an optional `starts` quest id). The `say` function checks the
  target NPC's topics and replies as an NPC `say` event to the room.
- **Pros:** fits a text world perfectly, and lets players discover things.
- **Cons:** keyword matching is brittle. Show topic hints in the target card
  ("Marta might talk about: work, rumours") to keep it fair.

### 3. Faction quests (reputation-gated)

Each faction offers work that matches its culture, unlocked by standing on
**either** axis:

- The orcs offer a duel quest only once they **respect** you, even if they
  hate you.
- The Folk of Harrowgate offer errands once they **like** you.
- The Spiderwood Brood offer something deceptive (plant false tracks for the
  wardens) once you've proven your cunning with ambushes.

Rewards move reputation, and often in opposite directions with other
factions. This is where the two-axis system pays off: the same quest can make
one faction love you and another respect you.

- **Architecture:** quests carry `requires: {faction, affinity >= x}` or
  `respect >= y`; `factions_of()` already exposes the numbers.

### 4. Emergent / world-state quests

The world posts needs instead of an NPC handing out tasks: "the orcs have
taken the back alley" when the orc population is high, or "the north road is
webbed over" after the brood respawns. Anyone in the area can contribute, and
completion is shared, announced to the `AREA:` channel.

- **Architecture:** a `world_events` key per area with a goal counter (e.g.
  spiders killed in Spiderwood). `deed()` bumps it, and the server's ticker
  (or the same Lua call) announces start and completion on the area channel.
- **Pros:** multiplayer by nature. It uses the channel model ("places are
  channels") directly.
- **Cons:** needs care so one player can't lock everyone else out of the
  credit. Reward everyone who contributed above a threshold.

### 5. Quest chains as small state machines

Each quest is a named state machine: states with entry text, and transitions
triggered by deeds or events (`on: {deed: "kill", of: "orcs", role:
"warrior"} -> state: "orc_respects_you"`). Branches let the *way* you did
something matter: kill the orc chieftain honourably (respect branch) or by
ambush (cunning branch), with different endings.

- **Architecture:** the same matcher as option 1, generalised:
  `PLAYER:<id>:quest:<qid>` holds the current state, and transitions are
  checked in `deed()`. This also covers options 1–4 as special cases.
- **Pros:** expresses "how you did it matters", which is what the culture
  system is about.
- **Cons:** content is harder to write. A seed validator (like the existing
  one) should check that every state is reachable and every quest can end.

### 6. Player-made quests (later)

Players post bounties ("10 silk bundles, reward: my spare sword") to a board
in a safe place. That needs trading and item ownership first.

## Practical concerns

- **Quest log UI:** a third header panel next to Inventory and Character:
  active quests, current step, and hints. Driven by a `quests` event, like
  `kit` and `character`.
- **Progress events:** emit a private `quest` event with text on each step
  ("Brannoc's horseshoe: 1 / 1"). Keep them rarer than reputation notes.
- **Respawning targets:** kill counts should count kills that happen while
  the quest is active, not the NPC's identity, since NPCs respawn.
- **Shared credit:** for group play, credit everyone fighting the NPC (its
  `foes` set already lists them) rather than only the killing blow.
- **Abandoning and repeating:** `quest abandon <name>`; repeatable faction
  quests with a cooldown, like the social deed cooldown.
- **Testing:** quests are pure Lua plus seed data, so they can be tested the
  way `tests/test_npcs.py` tests deeds: call actions and assert on events.

## Recommendation

Start with **option 5 (small state machines)**, driven from `deed()` and a
few other hooks (`say` to an NPC, `get`, entering a room), with **option 2
(talking to NPCs)** as the way most quests start. Use **option 3 (faction
gating)** for the first real content: one quest per faction that shows off
its culture. Add **option 4 (world-state quests)** once there are enough
players for shared goals to feel alive.

## Decided: the quest engine

Option 5, small state machines, started mostly by talking to NPCs (option 2).
The first quests are the starting realms' and the marooned island's; faction
quests follow.

- **Seed:** `quests: {id: {name, priority, steps: {id: {goal, on, then,
  effects}}, start}}`. `goal` is the line the quest panel shows ("Find a
  plank, pitch and rope"). `on` is what moves the step on; `then` is the
  next step, or `done`.
- **Triggers (`on`):** `ask` an NPC (`about` a topic); `get` an item; `enter`
  a room; `kill` an NPC (by id, template, faction or role, counted while the
  step is active, since NPCs respawn); `use` an item (`on` a feature or NPC);
  `have` all of a list of items; `level`; and `in` a room. Any of them can
  add `when` (weather ranges and time phases); states (`have`, `level`, `in`)
  are checked after anything happens and on every weather tick, so a quest
  that waits on the weather moves on when it turns.
  `travel` a route fires when the player takes it.
- **Effects:** experience, coins, items, reputation, discover a region,
  start another quest, teleport, resume a journey (end of a marooning),
  `say` (`by` an NPC: spoken to the room if they're there) and `guide`
  (an explanation in game terms, set apart in the log).
- **Offers:** a quest with a `giver` and an `offer` that another quest
  starts is offered out loud by the giver a beat after the last one is
  handed in (`offer_beat_ms`, default 2500; `alz:quest_offers` holds the
  due times, `tick` delivers them), and starts then. Without them it starts
  at once.
- **Quest routes:** a route with `quest` and `step` is offered (listed by
  `TRAVEL`, and takeable) only to a player at that step; `leaves_start`
  takes the starting realm off their map. The starting realms end this way.
- **State:** `PLAYER:<id>:quest:<qid>` holds the step and counters;
  `PLAYER:<id>:quests` lists active and finished quests. Progress is checked
  in the same atomic Lua call as the action that triggered it, from `deed()`
  and the `ask`, `get`, `move` and `use` functions.
- **Quest items are personal.** An item marked `quest` is seen and picked up
  by each player on that quest step separately, so two players never fight
  over the one plank.
- **Using and giving items:** `USE <item> ON <thing>` for things (slots stay
  `USE <number>`); `GIVE <item> TO <someone>` hands something over, and
  quests wait for it with `give` + `to`.
- **NPC topics:** NPCs get `topics` in the seed (`{"work": "The rats are at
  it again…", "starts": "rats"}`), talked over with `DISCUSS <topic>`.
  People talk in their own words; a topic's `explains` follows as guide text
  with the commands and mechanics. The target card lists the topics an NPC
  will discuss with you, so talking is never a guessing game, and some only
  open as they get to know you or as a quest goes on
  ([talk-and-layout.md](talk-and-layout.md)).
- **Offers and answers:** a topic that `starts` a quest, or a quest offered
  when the last one is handed in, waits for `ACCEPT` (or `DECLINE`, unless
  it's `"must": true`); `PLAYER:<id>:offer` holds it. A declined quest is
  offered again by `DISCUSS QUESTS`. Whoever gave a quest gets rapport when
  it's done.
- **Priority quests:** a quest marked `priority` (being marooned) is pinned
  in the panel, and it ends, failed, if you leave its area any way but by
  finishing it: death, a teleport. Logging out doesn't end it.
- **The quest panel:** a **Quests** header button lists active and finished
  quests; the current goal of your top quest also shows in a small section
  of the side panel, above the Loadout. Driven by a `quests` event, like
  `kit` and `character`.
- **The validator** checks every step is reachable and every quest can end.

