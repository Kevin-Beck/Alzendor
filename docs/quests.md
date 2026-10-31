# Quests: options for Alzendor

Nothing here is built yet. These are ways quests could work in Alzendor, with
what each one costs and how it fits the architecture we already have. The
recommendation is at the end.

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
