# Combat redesign: balance

How Alzendor's rhythm-slot combat is replaced by **balance**: you keep a
drifting dot inside your centre of balance, you can strike only while it's
there, and every strike, blow and dodge knocks it back out. The mechanic
comes from the Center of Balance prototype
(`iterbotgames/games/arcade/center/index.html`, its `T` table and `update`).
The proposal it grew from is the "Alzendor Combat Redesign: Balance Combat"
doc ([link](https://claude.ai/artifact/XVhrqcR9ScWFKdgoczj8Pf)). Today's
system is in the README (Combat) and [combat.md](combat.md).

Every fight is an **encounter**. It starts the moment you and an enemy share
a room (or you strike one), and one server runs it: that server simulates
every dot in the fight, and your browser predicts your own, so steering has
no lag. Redis still applies every consequence. Safety comes from what you
can see: danger in the next room shows on the map, and `LOOK NORTH` tells you
what it is, unless it's too dark or wet to see. PvP duels are encounters in a
place of their own.

This document is the whole plan: the rules, the architecture, the data, the
conversion, the tuning, and the order of the work.

## Decisions

| Area | Decision |
|---|---|
| Scope | Balance **fully replaces** rhythm slots. It's built as the only system on a branch, playtested on the test server, and deployed once. Rhythm code is deleted as it's replaced. |
| Authority | **Server-run encounters.** One Python server simulates each fight and every dot in it. The client predicts its own dot and corrects from the server. Redis Lua applies damage, kills, drops, reputation and death. |
| Starting a fight | **One rule:** a player and an enemy hostile to them in the same room fight, or you strike first. No prompt, anywhere. |
| Seeing danger | Rooms next to you with enemies in them get a **thin red ring on the map**. `LOOK <direction>` shows what's there. Darkness and heavy rain hide both. Hunter's Nose senses through them. |
| Leaving a fight | **FLEE &lt;direction&gt;**, only with your dot in the core. The **toughest** enemy in the fight gets one **parting blow**, which can't be blocked or dodged. Plain moves are refused mid-fight. You can walk straight back in. |
| Keys | **Combat focus**: while you're fighting and the command box is empty, WASD steers and the slot keys strike. Enter or `/` types; Esc returns to combat. |
| Several enemies | **No special rule.** Every NPC in the fight hits you at full strength. Packs are tuned as content. |
| Defence | **Everyone can dodge; a shield adds block.** The attack's `defend` field still decides which works. |
| NPC balance | **Bosses only**, as a stagger meter. |
| Gear | No gear or slot changes during an encounter. Between encounters, free. |
| A server dies | Its encounters **end**. Nothing is resumed; anyone still in a room with an enemy starts a fresh encounter. |
| Devices | **Phones get a touch stick.** The terminal (CLI) client is **retired**. |
| Existing characters | **Full character wipe** at cutover. |
| PvP | **Duels**, in an instance of their own, after the PvE cutover. |

## How a fight works

### Seeing danger

When you arrive in a room, and whenever you `LOOK`, the server works out
which of the rooms past your exits have **enemies** in them. An enemy is an
NPC with attacks whose disposition toward you is hostile.

- **The map** draws a thin red ring around each of those neighbouring
  rooms. That's all it says: something hostile is that way.
- **`LOOK <direction>`** (`LOOK NORTH`, `L N`) shows the room that way: its
  name, and the enemy cards in it, as they'd show in your Here list
  (deadly and watchful tags included). It also refreshes the rings.
- **Darkness and heavy rain or snow hide it**, by the same `can_see` check
  that hides glimpses today: no rings, and `LOOK NORTH` says "It's too dark
  to make out what's north." No ring doesn't mean safe.
- **Hunter's Nose** senses through it: rings show even when you can't see,
  and `LOOK <direction>` names the creatures by smell ("You smell a bear to
  the north.").
- The rings are a **snapshot** taken on arrival or on `LOOK`. They aren't
  updated live; something that turns up after you looked is the risk of the
  road.
- **Auto-walk** (clicking a room on the map) stops before stepping into a
  ringed room.

### Meeting enemies

A player and an enemy hostile to them, in the same room, neither of them in
a fight, start an **encounter**. That's checked wherever `aggro()` is called
today: when you arrive (walking, teleporting, respawning, reconnecting), when
an enemy arrives (respawn, emerging), when a journey ambush springs, and when
your reputation turns an NPC hostile.

- **Watchful enemies** (`notice` in the seed) make their Poise check, as
  today. One that doesn't notice you leaves you alone; one that does starts
  the encounter.
- **A fight already here:** if its NPCs are hostile to you, you join it when
  you walk in. If they aren't, you're a bystander until you strike one.
- **An enemy arriving where a fight is running** joins that encounter.
- **Attacking first:** striking an NPC that isn't fighting you (a neutral
  one, say) starts an encounter with it, or joins the one it's in.

### The fight

1. **Lead-in.** "The Orc Warrior turns on you!" For 1 s
   (`encounter_lead_ms`) nothing moves while the client and the server start
   the simulation together. Then the circle is live and the web client
   enters combat focus. Your dot starts at the centre.
2. **Balance.** An invisible well circles the ring and pulls your dot. You
   lean against it with WASD.
3. **Strike** (a slot key) only while your dot is in the core, you're not
   staggered or blocking, and the slot's cooldown is up. How close to the
   centre you are sets the tier: **edge**, **clean** or **perfect**. The
   strike knocks your own dot by the gear's `kick`.
4. **Blows.** Each NPC attack is warned on the target card for its last
   `warn` ms (1.5 s), then lands. It does damage and knocks your dot. A big
   one staggers you, and some leave a debuff.
5. **Dodge** (everyone, a press): untouchable for 0.6 s, then your dot
   wobbles for 2.5 s. **Block** (shield in hand, held): your dot holds steady
   and blows are cut, but you can't strike or dodge.
6. **The rim.** If your dot touches it you **stagger** for 1.2 s: no input,
   blows do 1.5× damage, and the dot eases back in.
7. **The end.** For you, the fight ends when every enemy in it is down, when
   you flee, when you die, or when you're taken out of the world (gone
   link-dead, or idle).

### Fleeing

During an encounter a plain move is refused: "You're in a fight. FLEE NORTH
to break away." **FLEE &lt;direction&gt;** (also `RUN`, or a flee button on
each exit during a fight):

1. needs your dot in the core, and you not staggered: otherwise "Steady
   yourself first.";
2. the **toughest** enemy in the encounter (highest `max_hp`; ties go to the
   harder hitter) lands its **hardest** attack at once, as a parting blow.
   It can't be blocked or dodged; guard and armour count. If it kills you,
   you die as usual;
3. you leave the encounter and walk the exit at the normal pace. The `flee`
   reputation deed is recorded for each NPC in the encounter, as today;
4. the NPCs don't follow. If other players remain, the encounter carries on
   with them; if not, it ends, and the NPCs keep the health they have.

Your dot starts every fight at the centre, so fleeing straight back out of a
room you shouldn't have entered always works, for the price of one blow.

You can come straight back in, and the fight starts again with the NPCs as
hurt as you left them. Stepping out and back in is a legitimate tactic.

On a journey ambush there are no exits. FLEE there (no direction) keeps
today's meaning: you're stranded in the wilds.

### Outside an encounter

There's no dot outside a fight. Using a slot outside an encounter:

- a damage gear on an NPC is attacking first, and starts an encounter;
- a heal or guard (on yourself, or an ally with `targets: ally`) just works,
  with its cooldown and its *clean* amount.

## The rules in detail

### The simulation

The simulation is the prototype's `update`, made deterministic. It runs in
fixed 1/60 s steps, in two copies: Python on the server (the authority) and
JavaScript in the client (the prediction). Each player has their own dot,
well and random stream.

Per player, per step (`dt` = 1/60):

1. Timers count down: cooldowns, dodge (`invuln`), stagger, stagger immunity,
   and each debuff.
2. **Random draws.** Exactly four numbers are drawn every step, whatever
   happens: well spin flip, well radius change, wobble direction, and a
   spare. The generator is mulberry32 (32-bit integer arithmetic, identical
   in Python and JavaScript), seeded with `hash(encounter seed, player id)`.
   Fixed draws keep the two copies' streams in step even when their branches
   differ.
3. **The well.** With reeling strength `r` (0 to 1): flip spin with
   probability `dt × (0.08 + 0.6r)`; pick a new target radius in
   `well_radius` with probability `dt × (0.25 + r)`; ease the radius toward
   it (`1 − e^(−0.8 dt)`); advance the angle by
   `spin × well_speed × (1 + 3r) × dt`.
4. **Staggered:** ease the dot toward its stagger point (`1 − e^(−3 dt)`),
   velocity zero, nothing else.
5. **Otherwise:**
   - gravity toward the well: strength `gravity × (1 + 0.6r) × calm` (calm =
     0.1 while blocking, else 1), eased off inside `gravity_falloff`;
   - wobble: every 0.07 s, a kick of `1.1 × wobble × calm` in the drawn
     direction;
   - push (not while blocking): the held direction × `push × steady / (1 +
     heavy_strength × heavy)`, where `heavy` fades from 1 to 0 over its
     duration and `steady` is 1.5 while it lasts;
   - damping: `e^(−damping × dt)` (`block_damping` while blocking);
   - move; at the rim (distance ≥ 1), bounce back if wobbling (wobble > 0.15)
     or stagger-immune, else stagger.
6. **Stagger** puts the dot on the rim, zeroes velocity, and picks a point
   0.35 from the centre within ±0.8 rad of where it hit.

Inputs (held keys, and acts) apply from the next step after the server
receives them (or the client presses them).

### Strikes

- **Valid** when: dot within the core radius, not staggered, not blocking,
  the slot's cooldown is up, the target is still in the encounter (or, for an
  ally heal, still in the room).
- **Buffer.** A strike pressed when it isn't valid is held for
  `balance_buffer_ms` (100 ms) and fires on the first step it becomes valid.
  Otherwise it's dropped, and the client shows "Not steady."
- **Tier** from the dot's distance to the centre: perfect within
  `perfect_r × (1 + 0.05 × focus)`, clean within `clean_r`, else edge. The
  amount is the gear's `amounts[edge, clean, perfect]`.
- **Kick** on your own dot: `kick` in the gear's `pattern`. `bump` goes in a
  random direction (drawn from your stream). `side` goes sideways (±x, small
  y). `taps` repeats one drawn direction for every hit of a volley.
- **Debuff** on yourself if the gear has one (e.g. `heavy`).
- **Volleys** (`hits` > 1): the first hit lands at once, and the rest every
  `gap` ms. Each hit does `ceil(amount / hits)` at the tier of the press and
  kicks you by `kick`. A volley keeps landing if you stagger, and stops if its
  target dies or you leave the encounter.
- **Ally targets.** Gear with `targets: ally` can target a player in the same
  encounter or a friendly NPC in the room. The healer still has to be
  centred.
- Bleed, gear `stagger_ms` (pushes the NPC's next attack back), weather
  scaling and reputation work as today.

### Blows

When an NPC attack lands on a player:

1. **Dodging** (in the 0.6 s): it misses, unless its `defend` is `block` or
   `none`. Nothing else applies.
2. **Blocking** (and its `defend` isn't `dodge` or `none`): damage × `(1 −
   block_cut × shield.block)`, knock × `block_kick`, and it can't stagger. If
   the block started within `defend_perfect_ms` (60 ms) before the blow,
   it's a **perfect block**: no damage, and a boss's meter fills by
   `balance_perfect_block_poise`.
3. **Guard** (talents like Guard Up) soaks what's left, as today.
4. **Armour** takes `armor / (armor + armor_k)` off the rest.
5. **Staggered:** ×`balance_stagger_dmg` (1.5).
6. **Knock:** the attack's `kick`, in the direction the server drew and
   announced with the warning.
7. **Stagger:** if the attack has `stagger: true`, or its `kick` ≥
   `balance_stagger_kick`, and it wasn't blocked, and you're not
   stagger-immune.
8. **Debuff:** the attack's `debuff`, if any, unless it was blocked.

A **parting blow** skips steps 1, 2, 5, 6, 7 and 8.

After any stagger ends, you're stagger-immune for
`balance_stagger_immune_ms` (3 s): blows can't stagger you, and the rim
bounces you back.

### NPCs in an encounter

- Each NPC's attacks run on the encounter's clock: the first lands one full
  `period` after it joins, then every `period`.
- An NPC attacks the first player in the encounter (in join order) who is
  still in it, as today.
- An NPC that dies leaves the encounter. When none are left, the encounter
  ends.

### Boss stagger meter

A boss is an NPC with `poise`. The meter is part of the encounter's state:

- every strike on the boss adds `kick × 10` (heavy gear fills it fastest); a
  volley adds it once per hit;
- a perfect block adds `balance_perfect_block_poise` (40);
- it drains at `balance_boss_poise_decay` (5 a second);
- when it reaches `poise`, the boss is **staggered** for
  `balance_boss_stagger_ms` (4 s): attacks due in that time are pushed to its
  end, it takes ×`balance_boss_stagger_dmg` (1.5) damage, the meter empties,
  and the room sees "The Broodmother reels!"

### Debuffs

| Kind | Effect | Default duration |
|---|---|---|
| `heavy` | push ÷ `(1 + strength × h)`, `h` fading 1 → 0 | gear's `ms` |
| `reeling` | well ×4 speed, ×1.6 pull, turns and shifts more (`r` fading 1 → 0) | attack's `ms` |
| `wobble` | kicks every 0.07 s, fading; rim bounces | `balance_wobble_ms` (2.5 s), after a dodge |
| `steady` | push × 1.5 | gear's `ms` |

Resilience shortens debuff durations by 5% a point, up to half. A debuff
applied while it's already running restarts it at the larger strength.

### Stats

| Stat | Under balance |
|---|---|
| Vigor | max health, as today |
| Poise | core radius `balance_core × (1 + 0.04 × poise)`; watchful checks as today |
| Focus | perfect radius `balance_perfect_r × (1 + 0.05 × focus)` |
| Resilience | weather penalties as today; debuffs 5% shorter a point, up to half |
| Presence | as today |

### Passives

| Passive | Under balance |
|---|---|
| Second Wind | heal 1 each time your dot re-enters the core after a knock |
| Berserk Seal | the attuned slot is 50% stronger, and sealed for the rest of the encounter at your first stagger |
| Moonlit Edge | at night, each clean or perfect strike with the attuned slot makes its next 10% stronger (up to 30%) |
| Bloodrhythm | each edge strike with the attuned slot makes its next 10% stronger (up to 30%) |
| Steady Hands | your first stagger in each encounter doesn't happen |
| Long Breath | a perfect strike makes your core 20% larger for 3 s |
| Hunter's Nose | danger rings show, and `LOOK <direction>` names creatures, even when darkness or weather hides them |
| all others | unchanged |

ATTUNE stays. Faction boons (+1 Poise) keep working.

### Reputation deeds

| Deed | Under balance |
|---|---|
| `kill`, `defeated`, `heal`, `greet`, `taunt` | as today |
| `clean_kill` | a perfect-tier killing blow |
| `ambush` | the strike that starts an encounter with an NPC that wasn't fighting you |
| `flee` | FLEE, for each NPC in the encounter |

No new deeds.

## Encounters: the architecture

### What runs where

| Part | Where | What it does |
|---|---|---|
| Simulation | an `asyncio` task on one Python server, the encounter's **owner** | every dot, the NPC attack clock, strikes, blows (who dodged, blocked, staggered), debuffs, boss meters; 30 ticks a second, two steps a tick |
| Consequences | Redis Lua functions | damage, armour, guard, heals, weather on gear, bleed, kills, drops, XP, deeds, death; atomic and in the global event order |
| Starting and membership | Lua | the one rule, who's in which encounter, danger rings |
| Prediction | the browser | your own dot, corrected from the server's state |

The owner never writes world state. A landed strike calls
`encounter_strike` and a landed blow calls `encounter_blow`. Each returns
what happened (damage, a kill, a death) and the owner updates the encounter
from that.

### Records in Redis

| Key | What |
|---|---|
| `ENC:<id>` | hash: `room`, `kind` (`pve` or `duel`), `seed`, `start_ms`, `owner` (server id) |
| `ENC:<id>:players`, `ENC:<id>:npcs` | sorted sets by join time |
| `ENC:<id>:lease` | owner's server id, SET PX 3000, refreshed every second |
| `alz:encounters` | set of live encounter ids |
| `alz:new_encounters` | a stream of new encounter ids, read by every server to find the ones it owns |
| `PLAYER:<id>:encounter`, `NPC:<id>:encounter` | the encounter each is in |

### Ownership and connections

The server that causes an encounter owns it: the one whose session moved
the player or sent the strike, or whose `tick` respawned the NPC or sprang
the ambush. The Lua function that starts it is passed that server's id and
writes it to `ENC:<id>` and the lease. Players in it may be connected to
other servers, so:

- sessions publish their player's inputs on `enc:<id>:in`;
- the owner publishes state on `enc:<id>:out`;
- every session with a player in the encounter subscribes to `out` and
  forwards it as `state` messages.

**A dead owner.** Every server's ticker checks `alz:encounters` once a
second. An encounter whose lease has lapsed is ended by calling
`encounter_end(id, 'lost')`: everyone keeps the health they have, and Lua
then runs the one rule again for each player still in the room, which starts
a fresh encounter owned by the server that found it.

### Prediction and correction

Your dot depends on your inputs (the client has them at once), the well (your
seeded stream, which both sides have) and blows (announced 1.5 s ahead with
their direction). So the client can predict it.

- The client numbers its inputs (`seq`) and keeps them with the step it
  applied them at.
- Each state message carries the server's `step` and, per player, the last
  `seq` applied.
- On a state message, the client resets your dot to the server's at that step
  and replays your later inputs on top. A difference is blended in over 6
  frames rather than snapped.
- Clocks: encounter steps count from `start_ms` on Redis's clock, which the
  client already tracks with ping/pong.

An honest client differs from the server only around a blow. The server
applies it after the inputs it has *received*, the client after the ones
you've *pressed*: at most half a round trip of steering.

### Disconnects

The encounter runs on. A disconnected player's held keys are released, so
their dot drifts and NPCs keep hitting them. On reconnect, the client gets
the encounter's current state and resumes. When the heartbeat takes a
link-dead or idle player out of the world, they leave the encounter: no
parting blow and no `flee` deed.

### Cost and tick rate

The budget is 10% of one core on the t4g.micro with 50 players fighting at
once. Step 12 measures it with a load test of bot players. If it's over
budget, `encounter_hz` drops from 30 to 20 (three steps a tick) and the
measurement is repeated.

Danger rings cost one loop over a room's exits when you arrive or look, and
nothing else: they're never pushed to players when NPCs move.

### Input bots

The server only accepts inputs, and plays them by its own rules. A modified
client can't fake position, precision or a skipped stagger. A script that
presses keys perfectly is possible. For PvE that's accepted. Duels log their
inputs (see PvP duels).

## Data

### Gear (`world/seed.json` and the zone files: 92 pieces, including the 41 class talents)

Removed: `period`, `window`, `perfect_window`. Added:

| Field | Meaning |
|---|---|
| `cooldown` | ms before the slot can strike again |
| `kick` | knock on your own dot (per hit for a volley) |
| `pattern` | `bump`, `side` or `taps` |
| `hits`, `gap` | volleys: number of hits, ms between them |
| `debuff` | on yourself: `{"kind", "strength", "ms"}` |

Kept: `amounts` (now `[edge, clean, perfect]`), `effect`, `bleed`,
`stagger_ms`, `targets`, `weather`, `requires`, `rank`, `rarity`, `kind`,
and the text fields.

### NPC attacks (183 fighting NPCs)

Kept: `name`, `period`, `damage`, `hit`, `defend`. Added: `kick`, `warn`
(default `balance_warn_ms`), `debuff`, `stagger` (default false). Bosses get
`poise`.

### Rules (`seed.json` `rules`)

Removed: `defend_cooldown_ms`, `defend_late_ms`, `dodge_window_ms`,
`block_window_ms`. Kept: `armor_k` (30), `defend_perfect_ms` (60, now the
perfect-block window).

| Rule | Value |
|---|---|
| `encounter_hz` | 30 |
| `encounter_lead_ms` | 1000 |
| `balance_core` | 0.22 |
| `balance_perfect_r` | 0.06 |
| `balance_clean_r` | 0.14 |
| `balance_damping` | 2.5 |
| `balance_block_damping` | 10 |
| `balance_push` | 2.6 |
| `balance_gravity` | 0.9 |
| `balance_gravity_falloff` | 0.3 |
| `balance_well_radius` | [0.5, 0.85] |
| `balance_well_speed` | 0.3 |
| `balance_warn_ms` | 1500 |
| `balance_buffer_ms` | 100 |
| `balance_stagger_ms` | 1200 |
| `balance_stagger_dmg` | 1.5 |
| `balance_stagger_kick` | 1.8 |
| `balance_stagger_immune_ms` | 3000 |
| `balance_dodge_ms` | 600 |
| `balance_dodge_cd_ms` | 3000 |
| `balance_wobble_ms` | 2500 |
| `balance_block_cut` | 0.7 |
| `balance_block_kick` | 0.15 |
| `balance_perfect_block_poise` | 40 |
| `balance_boss_stagger_ms` | 4000 |
| `balance_boss_stagger_dmg` | 1.5 |
| `balance_boss_poise_decay` | 5 |
| `balance_damage_scale` | 1 (set by tuning) |

The encounter sends the rules it uses to the client when it starts, so
tuning happens in one place.

## Protocol

Client → server (beside `cmd` and `ping`, in `session.py`):

```
{"type": "input", "seq": 812, "keys": 5, "act": "strike", "slot": 1, "target": "npc:orc-1"}
```

- `keys`: bitmask of held steering keys (1 up, 2 down, 4 left, 8 right).
- `act` (optional): `strike` (with `slot`, and `target` when not the
  current one), `dodge`, `block`, `unblock`, or `flee` (with `dir`).
- Sent on any change, and every 100 ms during an encounter. At most 30 a
  second; over that, the session drops them.
- Typed `USE 2`, `DODGE`, `BLOCK` and `FLEE NORTH` go through
  `commands.py`, which turns them into the same inputs, so typed and pressed
  are one path.

Server → client:

| Message | Carries |
|---|---|
| `encounter` event (player's stream) | `start`: id, seed, rules, `start_ms`, players, NPCs. `join` and `leave`: who. `end`: why |
| `room` event (as today) | plus `danger`: the ids of neighbouring rooms with enemies, when you can see them (or with Hunter's Nose) |
| `look` event | for `LOOK <direction>`: the room's name and its enemy cards, or why you can't see; plus `danger` refreshed |
| `state` message (direct, 15 a second) | `step`; per player: position, velocity, held keys, debuffs, cooldowns, staggered, immune, dodging, blocking, last `seq`; per NPC: next blows (time, target, kick, direction, `warn`); boss meters |
| `combat` event (room) | as today, plus `tier` on strikes and `result` (`hit`, `dodge`, `block`, `perfect_block`, `staggered`, `parting`) on blows |
| `refused` message (direct) | a dropped strike or flee and why (`not_steady`, `cooldown`, `staggered`) |

Positions only go to players in the encounter. Everyone in the room sees the
`combat` events.

Removed: `timing`, `defend`, `npc_timing`.

## Content conversion

`tools/convert_balance.py` rewrites `world/seed.json` and `world/zones/*.json`
once. The result is committed and then tuned.

**Gear.** Interpolate linearly on `period` between the anchors, and clamp
outside them:

| `period` (ms) | 1000 | 1200 | 4500 | 8000 |
|---|---|---|---|---|
| `cooldown` (ms) | 300 | 350 | 2500 | 4500 |
| `kick` | 0.8 | 1.0 | 1.6 | 2.0 |

- `pattern`: `bump` under 3000 ms, `side` from 3000 ms.
- `heavy` debuff on damage gear with `period` ≥ 4000: strength `1.5 +
  (period − 4000) / 2000`, at most 2.5; 5000 ms.
- Volleys, set by name:

  | Gear | `hits` | `gap` (ms) | `kick` per hit |
  |---|---|---|---|
  | `missile` | 4 | 1000 | 0.7 |
  | `chain_lightning` | 3 | 300 | 0.5 |
  | `cinder_rain` | 3 | 1000 | 0.5 |
  | `twin_jab` | 2 | 150 | 0.4 |

  Their `pattern` is `taps` and they get no `heavy`.
- `effect` `heal` or `guard`: `kick` 0, no pattern. `kind` `Potion` also gets
  `steady` (1.5, 3000 ms).

**NPC attacks.** Interpolate `kick` on the attack's `period`:

| `period` (ms) | 2500 | 8000 | 15000 |
|---|---|---|---|
| `kick` | 0.8 | 2.0 | 2.4 |

- `stagger: true` on every boss attack with `period` ≥ 10000 (the
  signature blows). Other attacks stagger only through
  `balance_stagger_kick`.
- `reeling` (strength 1, 5000 ms) on every attack with `period` ≥ 12000.

**Bosses.** The 29 NPCs with `respawn` ≥ 900 get `poise = min(400, 100 +
max_hp / 40)`.

## Tuning

`tools/balance_bot.py` imports `alzendor/balance.py` and plays it with no
server. It has two players:

- **ideal**: steers to the centre with full knowledge, and strikes and
  dodges at the best moment;
- **sloppy**: 250 ms reaction delay, steering noise, never perfect-blocks.

For each fighting NPC, it plays a character of the zone's level (stat points
spread evenly) with each class's starting loadout and the class talents
available by that level, 20 fights each. It reports time to kill, deaths and
staggers.

Targets:

| Enemy | Target |
|---|---|
| ordinary NPC, solo, at its zone's level | ideal kills in 20–40 s; sloppy wins at least 80% of fights |
| boss under 1000 `max_hp`, solo | ideal wins in 2–4 min; sloppy may lose |
| boss of 1000 `max_hp` or more | three ideal players win in 2–4 min |
| a room of three or more enemies, all at once | sloppy wins at least 60% |

Procedure, in this order:

1. Set `balance_damage_scale` (it multiplies every gear amount) so that the
   median ordinary NPC hits its time-to-kill target.
2. NPCs still outside their targets: change their attack `kick` and
   `period`, not their damage, so the danger stays where content placed it.
3. Rooms of three or more enemies outside their target: stagger their attack
   periods so blows don't line up, then cut a member if that isn't enough.
4. Rerun the bot on everything after any rule change. `tests/test_tuning.py`
   runs a 3-fight version on a fixed sample of 10 NPCs and fails if any is
   outside its target.

## Implementation plan

The work happens on a `balance` branch. Live keeps running `main` until the
cutover in step 21. Rhythm code is deleted in the step that replaces it, so
the branch never carries both systems. Each step lists its files, what it
does, what it deletes, and its tests. A phase ends at its gate, and the next
phase doesn't start before the gate is met. Tests run against the test Redis
on port 6380, never the live one.

**Progress.** Phases 1 and 2 (Steps 1–12) are built, and Gates 1 and 2
passed (the controls felt right; fake lag of 80 ms each way felt fine, and
the CPU checked out). Phase 3 is built (Steps 13–18) except the per-NPC
part of tuning: Gate 3 waits on retuning the content against the targets
(the numbers are at the end of this note) and on the phone controls on a
real phone.

Phase 1: `alzendor/balance.py`, the `Balance` block in
`alzendor/web/index.html`, `tools/make_vectors.py`, `tools/check_vectors.mjs`
and `tests/test_balance.py`. The vectors also check that a Python snapshot
restored in JavaScript carries on identically.

Phase 2: the encounter block in `alzendor.lua` (records, the one rule in
`aggro()`, `encounter_strike`, `encounter_blow`, `encounter_flee`),
`alzendor/encounter.py` (the owner, the bus, the host), inputs in
`session.py` and `commands.py`, the live client, and
`tools/load_encounters.py`. Rhythm code is gone from Lua and the client:
`engage` and the `:foes`/`:next` keys, `alz:npc_attacks`, DEFEND, the slot
rhythms (`take_beat`, `timing` events), `npc_timing`, and the sandbox.
`tests/test_encounters.py` covers the Lua functions and owners against the
test Redis; `test_combat.py` covers the one rule; `test_e2e.py` runs a fight
owned by one server with a player on another.

Choices made that the rules above leave open:

- Timers are whole steps (`steps(ms)`, half rounding up). Up is −y, as on
  screen.
- The four draws are used as: well spin flip, well radius change (a new
  target radius reuses that draw, scaled), wobble direction, and the spare
  for knock directions (`bump`, `side`, a volley's `taps`) and the stagger
  point.
- A step runs: timers, draws, the well, acts, a buffered strike, volleys,
  blows, then the dot. A blow's `result` is `staggered` when it lands on a
  staggered dot (for the ×1.5); whether it staggered you is a separate flag.
- A strike is refused as `not_steady` while blocking; a dodge is refused as
  `staggered`, `blocking` or `cooldown`; a block without a shield as
  `no_shield`.
- Every Lua function gets the calling server's id as `KEYS[1]`
  (`World.call` passes it): that's how "the server that causes an
  encounter owns it" reaches `aggro()` from all its call sites.
- One encounter per room (`ROOM:<id>:encounter`), which arrivals join; a
  journey ambush is its rider's own and isn't the room's.
- Striking first records the strike as the encounter's opening
  (`ENC:<id>:opening`); the owner lands it after the lead-in.
- Weather no longer changes timings; it scales amounts, as the plan says.
  GEAR hashes keep their amounts as `edge`, `clean` and `perfect`.
- Owners deliver state to sessions on their own server directly, and
  publish to Redis only while a session elsewhere follows (checked once a
  second by what a publish reaches). Inputs to a local owner skip Redis too.
- The websocket has no per-message compression: deflating every state
  message was the biggest single cost under load.
- The Redis pool allows 1000 connections (redis-py's default is 100; every
  connected player's feed holds one in a blocking read).

Measured with `tools/load_encounters.py` on the 4-core development VM (not
the t4g.micro), 50 players fighting, each in a room of their own:

| | Server CPU (one core) |
|---|---|
| 50 connected, not fighting | 2.9% |
| 50 fighting, `encounter_hz` 30 | 21.5% |
| 50 fighting, `encounter_hz` 20 | 19.1% |
| 50 fighting in one room, 30 Hz (before the fast paths) | 56.5% |

The simulation itself is about 1% of that, and per-encounter wakeups about
1%; the rest is moving messages (state 15 a second and inputs 10 a second
per player, and the room events of every strike and blow). So lowering
`encounter_hz` barely helps; the levers are the message rates. Locally, a
steering bot in the browser saw a visible correction on 4 of 270 state
messages.

**Lag.** `ALZ_FAKE_LATENCY_MS` and `ALZ_FAKE_JITTER_MS` fake a connection's
delay locally. Corrections turned out not to come only at blows, as
"Prediction and correction" above expects: the server applied inputs when
they arrived, a round trip after the client did. So inputs carry the step
the client applied them at, and the owner keeps each dot's last 200 ms
(`REWIND_STEPS`) and replays it from that step: steering always; a strike,
dodge or block only when nothing in between has gone to Lua yet. State
messages carry each dot as it was at the start of that window (which no late
input can change), and the client replays its own inputs and the blows it
has seen from there. A modified client could revise its last 200 ms of
steering; duels should shrink or drop the window. With a steering bot in the
browser, visible corrections went from 72–177 in 240 state messages at
100–150 ms each way to 1–2.

**Phase 3 choices.**

- `tools/convert_balance.py` converted all 92 gear, 282 attacks and 29
  bosses; seed validation now requires the balance fields and refuses
  rhythm ones.
- Danger: an enemy is an NPC with attacks hostile to you (an ambusher only
  to its rider). Darkness or heavy rain or snow in your room or the next one
  hides it. `LOOK <dir>` emits a `look` event with the room's name, the
  enemy cards and `danger`.
- Passives on the dot: Steady Hands also saves you from the rim (you bounce).
  Second Wind counts a knock (any kick, blow or stagger) until the dot comes
  back into the core. Berserk Seal's seal and Second Wind's heal go to Lua
  through `encounter_passive`.
- Settings: dodge and block are bindable keys (Space and Shift by default),
  steering is WASD, the arrows, or both, and block can toggle.

**Tuning so far.** `tools/balance_bot.py` plays each class at the NPC's zone
level (levels from docs/zones.md), with stat points spread evenly, the
starting loadout, that level's talents, and, beyond the plan, the slot gear
and armour that zones below that level give (quest rewards and drops).
Without them, high-level fights were unwinnable. Step 1 set
`balance_damage_scale` to 0.4: the median ordinary NPC dies in 28 s to the
ideal player. With 20 fights a class (ideal win rate and sloppy win rate):

| | Tier | NPCs | Ideal kills in (median) | Ideal wins | Sloppy wins | On target |
|---|---|---|---|---|---|---|
| ordinary | starting realms, Harrowgate (2–3) | 22 | 5 s | 100% | 100% | 0 |
| ordinary | the Greyfold (4) | 17 | 7 s | 100% | 99% | 1 |
| ordinary | the frontier (5–9) | 35 | 18 s | 100% | 89% | 9 |
| ordinary | dangerous places, early realms (10–14) | 51 | 33 s | 92% | 34% | 4 |
| ordinary | late realms (15–20) | 24 | 47 s | 43% | 19% | 0 |
| boss | the Greyfold (4) | 1 | 36 s | 100% | 97% | 0 |
| boss | the frontier (5–9) | 6 | 78 s | 36% | 13% | 0 |
| boss, 1000+ (three players) | 10–14 | 11 | 51 s | 74% | | 0 |
| boss, 1000+ (three players) | 15–20 | 11 | 60 s | 35% | | 0 |

Rooms of three or more at once: 1 of 4 on target (the granary cellar; the
abbey nave, the Ember Courts' pavilion and the Hollowmoon glade the sloppy
player loses almost always).

So one scale can't meet the targets: early enemies die in seconds, later
ones get too strong, and bosses are too short for their 2–4 minutes. The
spread comes from enemies' health and damage growing faster than a
character's does. Steps 2 and 3 (an NPC's `kick` and `period`) can't close
gaps this size on their own; it needs either per-tier health changes or
targets that fit what each tier is meant to be (a rat isn't meant to last
20 s). That's a design decision, so it waits.

### Phase 1: the simulation

**Step 1. Python simulation.** `alzendor/balance.py`: pure functions, no
I/O. `Rules` (from the seed's rules), `Dot` (position, velocity, timers,
debuffs, its random stream), `Well`, `mulberry32`, `step(dot, keys, rules)`,
`strike_check(dot, slot)`, `tier(dot)`, `apply_blow(dot, blow)`,
`apply_kick(dot, kick, pattern)`, `stagger(dot)`, `Boss` meter. Tests:
`tests/test_balance.py` covers everything in "The simulation", "Strikes",
"Blows", "Debuffs" and the boss meter, with no Redis.

**Step 2. Shared vectors.** `tools/make_vectors.py` writes
`tests/balance_vectors.json`: 20 scripted runs (inputs per step, blows,
strikes) and the Python positions every 30 steps. `test_balance.py` checks
Python against it exactly.

**Step 3. JavaScript simulation.** The same simulation in the web client,
as its own block at the top of the script in `alzendor/web/index.html`
(`const Balance = (() => { … })()`). A Node check (`tools/check_vectors.mjs`,
run by `tests/test_balance.py` when `node` is on the path) loads that block
from the HTML and checks it against the vectors, to within 1e-6.

**Step 4. Sandbox in the client.** Behind a local flag (`?balance=1`): the
circle, combat focus, strike row, dodge and block, debuff chips and the
touch stick. It runs against the Training Dummy and Sparring Post using their
attack timers from `npc_timing`, client-only, without sending anything.

*Gate 1:* fighting the dummies feels right on a keyboard and on a phone,
typing mid-fight works, and both simulations pass the vectors.

### Phase 2: one encounter end to end

**Step 5. Seed and rules.** The new rules, and the new gear and attack
fields, loaded by `world.py`'s seeding into the existing hashes (gear fields
into `GEAR:<id>`, attacks into `NPC:<id>`'s `attacks` JSON). For now only the
Training Yard loadout (Dagger, Magic Missile, Greataxe, Round Shield) and the
Sparring Post are converted, by hand. Tests: `test_world.py` checks that the
fields are seeded.

**Step 6. Lua: encounter records and consequences.** In `alzendor.lua`, a
`do … end` block holding one table, `enc = {}` (the 200-local cap),
placed after "NPCs fighting back". Registered functions:

- `encounter_start(server, room, kind, seed, pid, npcs…)`: creates the
  records, adds the id to `alz:new_encounters`, and emits `encounter start`;
- `encounter_join(id, pid | npc)` and `encounter_leave(id, pid | npc, why)`;
- `encounter_end(id, why)`;
- `encounter_strike(id, pid, target, slot, tier, hit, hits)`: today's slot
  `use` path without `take_beat` (target checks, effect, `bleed`,
  `stagger_ms`, `weathered()`, `balance_damage_scale`, deeds, kill, drops);
- `encounter_blow(id, nid, n, pid, how)`: today's blow path from `tick`
  (guard, armour, death) with `how` from the simulation, and the staggered
  multiplier.

Tests: `tests/test_encounters.py` calls each function directly and checks the
records and events.

**Step 7. Owner loop.** `alzendor/encounter.py`: `Encounter` (a
`balance.py` simulation of its players and NPCs, the NPC attack clock, the
volley queue) and `Owner` (the 30 Hz loop, reading `enc:<id>:in`, publishing
`enc:<id>:out` 15 times a second, the Lua calls, the lease). In `server.py`:
a loop reading `alz:new_encounters` that starts an `Owner` for each
encounter whose `owner` is this server, and the lapsed-lease check in
`_ticker`. Tests: `test_encounters.py` runs an owner against the test Redis
with a scripted input stream, and checks blows, strikes, a kill, the end, and
a lapsed lease ending the encounter and starting a fresh one.

**Step 8. Session and commands.** `session.py`: the `input` message (rate
limit, `seq`), publishing to the encounter, subscribing to its `out` channel
while the player is in one, and `state` and `refused` messages.
`commands.py`: `USE`, `DODGE`, `BLOCK` and `FLEE <dir>` become inputs when
the player is in an encounter. Tests: `test_encounters.py` with two sessions
on two `Server` objects sharing the test Redis.

**Step 9. The one rule.** `aggro()` keeps its name and its five call sites,
but starts (or joins) an encounter instead of `engage()`. It takes the
server id (passed down from the action or `tick` that called it), applies
the watchful check, and adds enemies arriving in a room with a running
encounter to it. Striking an NPC outside an encounter starts one. *Deletes:*
`engage`, `stop_fighting`, `drop_foe`, `NPC:<id>:foes`, `PLAYER:<id>:foes`,
`NPC:<id>:next`, `alz:npc_attacks` and its part of `tick`, `defend`,
`travel.defended`, the `defend_*` rules, `npc_timing_event`. The Step 4
sandbox stops working here (it read `npc_timing`), and the branch has no
playable client until Step 11. Steps 9 and 10 are checked by their tests.
Tests: `test_combat.py` (rewritten from here on) covers each of the five
call sites starting an encounter, watchful enemies, joining a fight in
progress, bystanders, an enemy arriving mid-fight, attacking first.

**Step 10. Fleeing.** The `flee` act in the owner (core check, toughest
enemy, hardest attack), `encounter_blow` with `how = 'parting'`, then
`encounter_leave` and the move. `move` refuses during an encounter. Lua
`flee` with no direction keeps stranding on ambushes. *Deletes:*
`finish_move`'s fled-foes handling (the `flee` deed moves to the flee path).
Tests: a refused move, flee refused off-centre, the parting blow
(unblockable, toughest only), death by parting blow, the encounter carrying
on without you, walking back in.

**Step 11. Client, live.** `index.html`: `input` sending; prediction, replay
and blending from `state`; `refused`; combat focus switched by `encounter`
events; the target card's warning markers from `state`; flee buttons on
exits; boss meter. The `?balance=1` sandbox goes. *Deletes:* slot balls,
`applyTiming`, `drawTiming`, `decorateSlots`, the defend row (`renderDefend`,
`defend`, `showDefend`), `applyNpcTiming`, `drawNpcTimers`.

**Step 12. Measure.** From a remote connection to the test server: round
trip, how often corrections are visible, and CPU with 50 bot players fighting
(`tools/load_encounters.py`, which drives sessions with the ideal bot's
inputs). Set `encounter_hz` by the budget.

*Gate 2:* steering feels like the sandbox at real latency, corrections show
only at blows, a dead owner's encounters end and restart cleanly, and CPU is
within budget.

### Phase 3: content

**Step 13. Conversion.** Run `tools/convert_balance.py` over all gear,
attacks and bosses, and commit the result. *Deletes:* slot rhythms in Lua
(`SLOTS`' rhythm state, `live_slot`, `take_beat`, `timing_event`, `every`,
`MIN_TIMEOUT_MS`, `timeout_for`, `PLAYER:<id>:slot:<n>`) and the rhythm
tests in `test_combat.py`, `test_npcs.py`, `test_characters.py` and
`test_e2e.py`. Tests: `test_world.py` checks that no gear has `period` left,
every attack has `kick`, and the 29 bosses have `poise`.

**Step 14. Seeing danger.** Lua: `enc.danger(pid, rid)` (neighbouring rooms
with enemies, through `can_see` and Hunter's Nose), added to the room event;
`look` with a direction, through the same check, emitting `look`.
`commands.py`: `LOOK <dir>` and `L <dir>`. `index.html`: the thin red ring on
the map in `drawMap`, the `look` result in the log, and `walkTo` stopping
before a ringed room. Tests: rings for enemies next door and not for
neutral NPCs; none in the dark or heavy rain; Hunter's Nose through both;
`LOOK NORTH` cards, and "too dark"; rings not updated live.

**Step 15. Passives, deeds and stats.** The passives table in Lua (strike
side) and `balance.py` (dot side: Second Wind's re-entry, Steady Hands,
Long Breath, Berserk Seal's seal); Poise, Focus and Resilience into
`Rules` per player at join; the deeds table. Tests: each passive, each stat,
each deed.

**Step 16. Gear lock and out-of-fight use.** `equip` and `unequip` are
refused during an encounter (replacing the rhythm lock). Heals and guards
work outside an encounter at their clean amount; damage gear outside one
attacks first. Tests: both.

**Step 17. Settings.** In the client's existing Settings panel: key binding
for dodge, block and steering (WASD or arrows), and toggle-block.

**Step 18. Tuning.** `tools/balance_bot.py`, the procedure under Tuning,
and `tests/test_tuning.py`. Then a two-player encounter by hand on the test
server.

*Gate 3:* every target in the Tuning table is met, and the phone controls
work on a real phone.

### Phase 4: playtest

**Step 19. Playtest on the test server** (port 8097, its own Redis on
6380), from the `balance` branch, with a small group for two weeks. Their
fights are logged (encounter length, staggers, deaths, flees, `LOOK`s before
entering a ringed room), and tuning follows the Tuning procedure.

*Gate 4:* median fight length is within target for ordinary NPCs and
bosses, the playtesters prefer balance to rhythm, and there are no open bugs
in encounters, danger rings or fleeing.

### Phase 5: cutover

**Step 20. Docs and leftovers.** Rewrite the README's Combat section,
Settings and Protocol; [combat.md](combat.md) (defence, the panel, seeing
danger, fleeing); each background's starting-realm tutorial text in the
seed. *Deletes:* `alzendor/cli.py` and its README mentions. A final search
of the branch for `period`, `timing`, `defend` and `npc_attacks` comes up
empty outside this document and git history.

**Step 21. Cut over.** Merge `balance` into `main`, deploy with
`deploy/iterbotgames/deploy.sh`, announce in game (`announce`), and run
`reset_character` for every account. The previous deploy is the rollback
point.

*Gate 5:* the full test suite passes, and a week of live play has no
rollback.

### Phase 6: PvP duels

**Step 22. Duels.** Everything in the next section. Tests:
`tests/test_duels.py` covers challenge and decline, the duel ground,
wind-up, impact, yield, the time limit, forfeit, health restored, results,
and records.

*Gate 6:* duels between remote players with different round trips, where
the wind-up hides the difference.

## PvP duels

A duel is an encounter of kind `duel`, in a place of its own.

- **Challenge.** `CHALLENGE <player>`, in the same room. The other player
  answers with ACCEPT or DECLINE within 30 s (`PLAYER:<id>:challenge`, PX
  30000). Neither can be in an encounter or on a journey.
- **The duel ground.** Both move to `duel:<id>`, a room made for the duel
  and not on the map. It has neutral weather (all axes 0, dry) and nobody
  else can enter. Their world rooms are kept, and they return there after.
- **Loadouts.** Their own slots, as they are when the duel starts.
- **The fight.** The same simulation with both players' dots. Each gear has
  `impact` (its knock on the opponent's dot; the conversion sets it to the
  gear's `kick`). A strike has a **wind-up** (`duel_windup_ms`, 300 ms)
  between the press and when it lands, shown on the opponent's card as a
  warning. The opponent can block or dodge it like an NPC blow. A strike
  is judged when pressed and lands after the wind-up even if the striker is
  knocked meanwhile.
- **Ending.** At zero health the player loses (no death, shrine or XP
  loss). `YIELD` concedes. After 3 minutes, the higher share of health left
  wins (a tie is a draw). Disconnected for more than 10 s forfeits. Both
  players' health goes back to what it was before. If the owner dies, the
  duel is a draw.
- **Results.** `duel_result` in Lua: an event to both and to the room they
  came from, `PLAYER:<id>:duels` (wins, losses, draws), and the `duel_win`
  deed, which factions can value in their reputation rules (the orcs'
  respect).
- **Input log.** Every duel's inputs are kept for 7 days
  (`DUEL:<id>:inputs`, a Redis stream with a TTL) so a reported fight can be
  replayed with `tools/replay_duel.py`.

## Not in this redesign

These are deliberately left out and aren't built:

- Prompts before a fight, safe zones, or areas with their own attack rules.
  What you can see is the only warning.
- Live danger updates: rings change only when you arrive or look.
- Resuming an encounter on another server when its owner dies.
- NPCs reacting to your balance (striking harder when you're staggered).
- Weather changing the simulation (wind speeding the well). Weather scales
  gear amounts and hides danger, as described.
- Debuffs beyond `heavy`, `reeling`, `wobble` and `steady`.
- Showing other players' dots. Allies see your strikes and staggers on your
  card and in the log.
- Duel wagers, spectators and ranked play.
- Detecting input bots.
