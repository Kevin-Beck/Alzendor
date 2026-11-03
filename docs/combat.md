# Combat: balance

How fighting works: the rules, the fight panel, where each part runs, the
data, the protocol, and how the content is tuned. This is the reference; the
README has the player's short version.

You keep a drifting dot inside your centre of balance, you can strike only
while it's there, and every strike, blow and dodge knocks it back out. Every
fight is an **encounter**: it starts the moment you and an enemy share a
room (or you strike one), and one server runs it. That server simulates
every dot in the fight, and your browser predicts your own, so steering has
no lag. Redis applies every consequence (damage, kills, drops, reputation,
death). Safety comes from what you can see: danger in the next room shows on
the map, and `LOOK NORTH` tells you what it is, unless it's too dark or wet
to see.

(The design and build history, including the rhythm combat this replaced,
is in git: `docs/combat-redesign.md` before it was folded in here.)

## Decisions

| Area | Decision |
|---|---|
| Authority | **Server-run encounters.** One Python server (the encounter's owner) simulates each fight and every dot in it. The client predicts its own dot and corrects from the server. Redis Lua applies damage, kills, drops, reputation and death. |
| Starting a fight | **One rule:** a player and an enemy hostile to them in the same room fight, or you strike first. No prompt, anywhere. |
| Seeing danger | Rooms next to you with enemies in them get a **thin red ring on the map**. `LOOK <direction>` shows what's there. Darkness and heavy rain hide both. Hunter's Nose senses through them. |
| Leaving a fight | The **flee key**, only with your dot in the core, back the way you came. The **toughest** enemy gets one **parting blow**, which can't be blocked or dodged. Moves (and typed FLEE, TRAVEL, DISCUSS PASSAGE) are refused mid-fight. You can walk straight back in. |
| Keys | **Combat focus**: in a fight, with the command line empty, WASD (or the arrows) steers and the slot keys (J, K, L) strike; Space dodges, Shift blocks, F flees. Enter types; Enter on an empty line (or Esc) goes back to the fight. All rebindable in Settings. |
| Several enemies | **No special rule.** Every NPC in the fight hits you at full strength. Packs are tuned as content. |
| Defence | **Everyone can dodge; a shield adds block.** The attack's `defend` field says which works. |
| NPC balance | **Bosses only**, as a stagger meter. |
| Gear | No gear or slot changes during an encounter. Between encounters, free. |
| A server dies | Its encounters **end** when their lease lapses. Nothing is resumed; anyone still in a room with an enemy starts a fresh encounter. |
| Devices | Phones get a touch stick and Dodge/Block/Flee buttons. |

## How a fight works

### Seeing danger

When you arrive in a room, and whenever you `LOOK`, the server works out
which of the rooms past your exits have **enemies** in them. An enemy is an
NPC with attacks whose disposition toward you is hostile (an ambusher only
to its rider).

- **The map** draws a thin red ring around each of those neighbouring
  rooms. That's all it says: something hostile is that way.
- **`LOOK <direction>`** (`LOOK NORTH`, `L N`) shows the room that way: its
  name, and the enemy cards in it, as they'd show in your Here list
  (deadly and watchful tags included). It also refreshes the rings.
- **Darkness and heavy rain or snow hide it**, in your room or the next one:
  no rings, and `LOOK NORTH` says "It's too dark to make out what's north."
  No ring doesn't mean safe.
- **Hunter's Nose** senses through it: rings show even when you can't see,
  and `LOOK <direction>` names the creatures by smell.
- The rings are a **snapshot** taken on arrival or on `LOOK`, never pushed
  live.
- **Auto-walk** (clicking a room on the map) stops before stepping into a
  ringed room.

### Meeting enemies

A player and an enemy hostile to them, in the same room, neither of them in
a fight, start an **encounter**. That's checked wherever `aggro()` is
called: when you arrive (walking, teleporting, respawning, reconnecting),
when an enemy arrives (respawn, emerging), when a journey ambush springs, and
when your reputation turns an NPC hostile.

- **Watchful enemies** (`notice` in the seed) make a Poise check (easier
  with CREEP). One that doesn't notice you leaves you alone; one that does
  starts the encounter.
- **A fight already here:** if its NPCs are hostile to you, you join it when
  you walk in. If they aren't, you're a bystander until you strike one.
- **An enemy arriving where a fight is running** joins that encounter.
- **Attacking first:** striking an NPC that isn't fighting you (a neutral
  one, say) starts an encounter with it, or joins the one it's in. That
  strike is the encounter's opening, landed after the lead-in.

### The fight

1. **Lead-in.** "The Orc Warrior turns on you!" For 1 s
   (`encounter_lead_ms`) nothing moves while the client and the server start
   the simulation together. Then the circle is live and the web client
   enters combat focus (unless you're halfway through typing). Your dot
   starts at the centre.
2. **Balance.** An invisible well circles the ring and pulls your dot. You
   lean against it with WASD or the arrows.
3. **Strike** (a slot key) only while your dot is in the core, you're not
   staggered or blocking, and the slot's cooldown is up. How close to the
   centre you are sets the tier: **edge**, **clean** or **perfect**. The
   strike knocks your own dot by the gear's `kick`, and holds every other
   slot for `balance_global_cd_ms` (900 ms).
4. **Blows.** Each NPC attack is warned on the target card for its last
   `warn` ms (1.5 s), then lands. It does damage and knocks your dot. A big
   one staggers you, and some leave a debuff.
5. **Dodge** (everyone, a press): untouchable for 0.6 s, then your dot
   wobbles for 2.5 s. **Block** (shield in hand, held or toggled): your dot
   holds steady and blows are cut, but you can't strike or dodge.
6. **The rim.** If your dot touches it you **stagger** for 1.2 s: no input,
   blows do 1.5× damage, and the dot eases back in.
7. **The end.** For you, the fight ends when every enemy in it is down, when
   you flee, or when you die. Leaving the world is no escape: see
   Disconnects.

### Fleeing

During an encounter a plain move is refused, and so is a typed FLEE:
"You're in a fight. Get steady and press your flee key (F by default) to run
back the way you came." Fleeing is only the **flee key** (or the Flee
button), and it only goes **back the way you came**: the exit to the room
you last walked in from (`PLAYER:<id>:came`, set by a walk and cleared by
any other way of arriving, such as GOTO, a shrine or a journey). With no way
back ("No way back"), you fight. The exits can't be clicked during a fight.
The key:

1. needs your dot in the core, and you not staggered: pressed off centre,
   it's ignored ("Not steady");
2. the **toughest** enemy in the encounter (highest `max_hp`; ties go to the
   harder hitter) lands its **hardest** attack at once, as a parting blow.
   It can't be blocked or dodged; guard and armour count. If it kills you,
   you die as usual;
3. you leave the encounter and walk the exit at the normal pace. The `flee`
   reputation deed is recorded for each NPC in the encounter;
4. the NPCs don't follow. If other players remain, the encounter carries on
   with them; if not, it ends. The NPCs heal from there (see below).

Your dot starts every fight at the centre, so fleeing straight back out of a
room you shouldn't have entered always works, for the price of one blow. You
can come straight back in, and the fight starts again with the NPCs as hurt
as you left them.

On a journey ambush there are no exits. The flee key there strands you in
the wilds.

### Outside an encounter

There's no dot outside a fight. Using a slot outside an encounter:

- a damage gear on an NPC is attacking first, and starts an encounter;
- a heal or guard (on yourself, or an ally with `targets: ally`) just works,
  at its *clean* amount, and then waits `out_of_fight_cooldown_scale` (3)
  times its cooldown, so resting does the healing between fights, not
  potions.

## The rules in detail

### The simulation

The simulation runs in fixed 1/60 s steps, in two copies: Python on the
server (`alzendor/balance.py`, the authority) and JavaScript in the client
(the `Balance` block in `alzendor/web/index.html`, the prediction). Each
player has their own dot, well and random stream. The two copies are pinned
together by `tests/balance_vectors.json` (see Changing the simulation).

Per player, per step (`dt` = 1/60):

1. Timers count down: cooldowns, dodge (`invuln`), stagger, stagger immunity,
   and each debuff.
2. **Random draws.** Exactly four numbers are drawn every step, whatever
   happens: well spin flip, well radius change (a new target radius reuses
   that draw, scaled), wobble direction, and a spare (knock directions for
   `bump`, `side` and a volley's `taps`, and the stagger point). The
   generator is mulberry32 (32-bit integer arithmetic, identical in Python
   and JavaScript), seeded with `hash(encounter seed, player id)`. Fixed
   draws keep the two copies' streams in step even when their branches
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

A step runs: timers, draws, the well, acts, a buffered strike, volleys,
blows, then the dot. Timers are whole steps (`steps(ms)`, half rounding up).
Up is −y, as on screen. Inputs (held keys, and acts) apply from the step the
client applied them at: the owner keeps each dot's last 200 ms
(`REWIND_STEPS`) and replays it from that step (steering always; a strike,
dodge or block only when nothing in between has gone to Lua yet).

### Strikes

- **Valid** when: dot within the core radius, not staggered, not blocking,
  the slot's cooldown is up (and `balance_global_cd_ms` since any strike),
  and the target is still in the encounter (or, for an ally heal, still in
  the room). A strike while blocking is refused as `not_steady`.
- **Buffer.** A strike pressed when it isn't valid is held for
  `balance_buffer_ms` (100 ms) and fires on the first step it becomes valid.
  Otherwise it's dropped, and the client shows "Not steady."
- **Target.** The selected target (an entity id). A typed word (`USE 2
  MARA`) names an NPC or a player in the fight; a word that names no one is
  refused (`no_target`). With nothing named, damage gear goes at the first
  enemy in the fight, and heals and guards at yourself.
- **Tier** from the dot's distance to the centre: perfect within
  `perfect_r × (1 + 0.05 × focus)`, clean within `clean_r`, else edge. The
  amount is the gear's `amounts[edge, clean, perfect]`, scaled by the
  weather (weather.md) and `balance_damage_scale`.
- **Kick** on your own dot: `kick` in the gear's `pattern`. `bump` goes in a
  random direction. `side` goes sideways (±x, small y). `taps` repeats one
  drawn direction for every hit of a volley.
- **Debuff** on yourself if the gear has one (e.g. `heavy`).
- **Volleys** (`hits` > 1): the first hit lands at once, and the rest every
  `gap` ms. Each hit does `ceil(amount / hits)` at the tier of the press and
  kicks you by `kick`. A volley keeps landing if you stagger, and stops if its
  target dies or you leave the encounter.
- **Ally targets.** Gear with `targets: ally` can target a player in the same
  encounter or a friendly NPC in the room. The healer still has to be
  centred.
- **Bleed** (`bleed` on gear) wears an NPC down by its damage on each of its
  blows, for that many blows, but never kills it. Gear `stagger_ms` pushes
  the NPC's next attack back.

### Blows

When an NPC attack lands on a player:

1. **Dodging** (in the 0.6 s): it misses, unless its `defend` is `block` or
   `none`. Nothing else applies.
2. **Blocking** (and its `defend` isn't `dodge` or `none`): damage × `(1 −
   block_cut × shield.block)`, knock × `block_kick`, and it can't stagger. If
   the block started within `defend_perfect_ms` (60 ms) before the blow,
   it's a **perfect block**: no damage, and a boss's meter fills by
   `balance_perfect_block_poise`.
3. **Guard** (talents like Guard Up) soaks what's left.
4. **Armour** takes `armor / (armor + armor_k)` off the rest (see Armour).
5. **Staggered:** ×`balance_stagger_dmg` (1.5).
6. **Knock:** the attack's `kick`, in the direction the server drew and
   announced with the warning.
7. **Stagger:** if the attack has `stagger: true`, or its `kick` ≥
   `balance_stagger_kick`, and it wasn't blocked, and you're not
   stagger-immune.
8. **Debuff:** the attack's `debuff`, if any, unless it was blocked.

A **parting blow** skips steps 1, 2, 5, 6, 7 and 8. Amounts are rounded
half away from zero at each step (Lua's `round`).

After any stagger ends, you're stagger-immune for
`balance_stagger_immune_ms` (3 s): blows can't stagger you, and the rim
bounces you back.

The combat line says what happened: "The Orc Warrior cleaves Kevin. (5, 2
armour)", "Kevin blocks the Orc Warrior's cleaver. (2, 5 blocked)".

### Armour

Worn gear ([characters.md](characters.md), "Worn gear") adds armour, and
armour takes `armor / (armor + armor_k)` off every blow, rounded (`armor_k`
is 30). Small blows can round to nothing taken off; big ones lose a steady
share. It's always on: no timing, no weather.

### NPCs in an encounter

- Each NPC's attacks run on the encounter's clock: the first lands one full
  `period` after it joins, then every `period`.
- An NPC attacks the first player in the encounter (in join order) who is
  still in it.
- An NPC that dies leaves the encounter. When none are left, the encounter
  ends. An NPC out of a fight stops bleeding, and heals `npc_regen_pct`
  (5%) of its health every 5 s until it's whole: weaken something and leave,
  and it won't stay weak for long.
- After a stall of the owner's loop (over 2 s), the encounter skips ahead,
  and each attack moves on to its next landing rather than landing every
  missed blow at once.

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

| Stat | In a fight |
|---|---|
| Vigor | 8 more max health a point |
| Poise | core radius `balance_core × (1 + 0.04 × poise)`; also watchful-enemy and trap checks |
| Focus | perfect radius `balance_perfect_r × (1 + 0.05 × focus)` |
| Resilience | debuffs 5% shorter a point, up to half (and weather penalties softened 10% a point, up to half) |
| Presence | none (reputation moves 15% further a point) |

The fight factors live in `balance.py` (`STAT_FACTORS`), and alzendor.lua's
`STAT_FACTORS` words them for players (TRAIN, STATS, the Character panel);
`tests/test_balance.py` pins the two, and the client's `forPlayer`.

### Passives

| Passive | Effect |
|---|---|
| Second Wind | heal 1 each time your dot comes back into the core after a knock (any kick, blow or stagger); not attuned to a slot |
| Berserk Seal | the attuned slot is 50% stronger, and sealed for the rest of the encounter at your first stagger |
| Moonlit Edge | at night, each clean or perfect strike with the attuned slot makes its next 10% stronger (up to 30%) |
| Bloodrhythm | each edge strike with the attuned slot makes its next 10% stronger (up to 30%) |
| Steady Hands | your first stagger in each encounter doesn't happen (at the rim, you bounce) |
| Long Breath | a perfect strike makes your core 20% larger for 3 s |
| Hunter's Nose | danger rings show, and `LOOK <direction>` names creatures, even when darkness or weather hides them |

The rest are in [characters.md](characters.md). `ATTUNE <passive> <slot>`
chooses the slot of a slot-bound passive.

### Reputation deeds

| Deed | When |
|---|---|
| `kill`, `defeated`, `heal`, `greet`, `taunt` | killing an NPC, being killed by one, healing one, greeting or taunting one |
| `clean_kill` | a perfect-tier killing blow |
| `ambush` | the strike that starts an encounter with an NPC that wasn't fighting you |
| `flee` | fleeing, for each NPC in the encounter |

## Deadly and watchful enemies

The client tags an NPC **deadly** when any of its blows would take 40% of
your health or more, and its target card says how hard it hits. Some deadly
things are **watchful** (`notice` in the seed): walking in, a Poise check
(easier with CREEP) decides whether it notices you, and unnoticed, it leaves
you alone for a minute unless you touch it. Auto-targeting never picks
something deadly or watchful that isn't already after you. See
[zones.md](zones.md).

## The fight panel

At the top left of the web client, beside the map, two by two:

1. **Your balance**: the circle, your dot, the core and the perfect centre,
   with the chips for any debuff, and Dodge, Block and Flee buttons (and a
   touch stick on a phone). Out of a fight it rests.
2. **Here**: everyone in the room, compact. Tab cycles your target through
   them.
3. **Slots**: your three slots, each with its key, its cooldown, what the
   weather is doing to it (▲ or ▼), and the tier and amount of your last
   strike with it. Hover one for its card.
4. **The target**: a portrait, a health bar that runs out from right to left
   (with a red trail that lags behind), each of its attacks with the coming
   blow warned on it, and a boss's stagger meter.

Behind all of it, faintly, **your health** fills the panel from the bottom.
Drag the bar between the panel and the map to resize them. On a phone the
panel stacks above the map, and out of a fight the resting balance and an
empty target card are hidden.

Entering a room targets the first hostile there, or else the first friendly
NPC (never a neutral one or a player, so a slot pressed by habit can't start a
fight); when your target falls, the next hostile is picked.

## Encounters: the architecture

### What runs where

| Part | Where | What it does |
|---|---|---|
| Simulation | an `asyncio` task on one Python server, the encounter's **owner** (`alzendor/encounter.py`) | every dot, the NPC attack clock, strikes, blows (who dodged, blocked, staggered), debuffs, boss meters; 30 ticks a second (`encounter_hz`), two steps a tick |
| Consequences | Redis Lua functions | damage, armour, guard, heals, weather on gear, bleed, kills, drops, XP, deeds, death; atomic and in the global event order |
| Starting and membership | Lua | the one rule, who's in which encounter, danger rings |
| Prediction | the browser | your own dot, corrected from the server's state |

The owner never writes world state. A landed strike calls
`encounter_strike` and a landed blow calls `encounter_blow`. Each returns
what happened (damage, a kill, a death) and the owner updates the encounter
from that. A passive at work on the dot (Second Wind's heal, Berserk Seal's
seal) goes through `encounter_passive`, and a boss reeling or steadying
through `encounter_note`.

### Records in Redis

| Key | What |
|---|---|
| `ENC:<id>` | hash: `room`, `kind` (`pve`), `seed`, `start_ms`, `owner` (server id) |
| `ENC:<id>:players`, `ENC:<id>:npcs` | sorted sets by join time |
| `ENC:<id>:lease` | owner's server id, SET PX 3000, refreshed every second |
| `ENC:<id>:opening` | the strike that started it, landed after the lead-in |
| `alz:encounters` | set of live encounter ids |
| `alz:new_encounters` | a stream of new encounter ids, read by every server to find the ones it owns |
| `PLAYER:<id>:encounter`, `NPC:<id>:encounter` | the encounter each is in |
| `ROOM:<id>:encounter` | the room's encounter, which arrivals join (a journey ambush is its rider's own) |

### Ownership and connections

The server that causes an encounter owns it: the one whose session moved
the player or sent the strike, or whose `tick` respawned the NPC or sprang
the ambush. Every Lua function gets the calling server's id as `KEYS[1]`
(`World.call` passes it), and the function that starts an encounter writes
it to `ENC:<id>` and the lease. That's why each server needs an id of its
own (`ALZ_SERVER_ID`, claimed in Redis while it runs). Players in it may be
connected to other servers, so:

- sessions publish their player's inputs on `enc:<id>:in`;
- the owner publishes state on `enc:<id>:out`;
- every session with a player in the encounter subscribes to `out` and
  forwards it as `state` messages (only the newest, if the client is slow).

Owners deliver to sessions on their own server directly, and publish to
Redis only while a session elsewhere follows (checked once a second by what
a publish reaches). Inputs to a local owner skip Redis too.

**A dead owner.** Every server's ticker checks `alz:encounters` once a
second. An encounter whose lease has lapsed is ended by calling
`encounter_end(id, 'lost')`: players keep the health they have, and Lua
then runs the one rule again for each player still in the room, which starts
a fresh encounter owned by the server that found it. So losing a server (or
a deploy restarting the only one) costs each of its fights its timers and
boss meters, and the opening strike.

### Prediction and correction

Your dot depends on your inputs (the client has them at once), the well (your
seeded stream, which both sides have) and blows (announced 1.5 s ahead with
their direction). So the client can predict it.

- The client numbers its inputs (`seq`) and sends the step it applied each
  at.
- Each state message carries the server's `step` and, per player, the dot as
  it was at the start of the rewind window (which no late input can change)
  and the last `seq` applied.
- On a state message, the client resets your dot to the server's and replays
  its own later inputs and the blows it has seen on top. A difference is
  blended in over about 6 frames rather than snapped.
- Clocks: encounter steps count from `start_ms` on Redis's clock, which the
  client tracks with ping/pong.

With the connection down, the client says so ("Offline: reconnecting…")
rather than predicting strikes that can't be sent. On reconnecting it drops
whatever fight, journey or travel event it was showing; the server sends
again what's still true.

### Disconnects

The encounter runs on. A disconnected player's held keys are released, so
their dot drifts and NPCs keep hitting them. On reconnect, the client gets
the encounter's current state and resumes.

Leaving the world (QUIT, LOGOUT, idling, or a connection lost past the
grace period) is no escape either: the body lies down where it is, even
somewhere safe, and stays in the fight, taking its blows. If it falls, the
player wakes at the shrine, as for any defeat. Logging back in before it
fades (`sleep_seconds`, 2 minutes), they wake in the fight. Once it fades,
it leaves the fight with no parting blow and no `flee` deed.

### Cost

Measured with `tools/load_encounters.py` on a 4-core development VM, 50
players fighting, each in a room of their own: 21.5% of one core at
`encounter_hz` 30 (19.1% at 20; 2.9% connected but not fighting). The
simulation is about 1% of that; the rest is moving messages (state 15 a
second and inputs 10 a second per player, and the room events of every
strike and blow), so the levers are the message rates, not `encounter_hz`.
The websocket has no per-message compression: deflating every state message
was the biggest single cost.

### Input bots

The server only accepts inputs, and plays them by its own rules. A modified
client can't fake position, precision or a skipped stagger (it could revise
its last 200 ms of steering). A script that presses keys perfectly is
possible. For PvE that's accepted.

## Data

### Gear (`world/seed.json` and the zone files)

| Field | Meaning |
|---|---|
| `name`, `kind`, `keywords`, `description`, `hit`, `perfect_hit` | its text |
| `effect` | `damage`, `heal` or `guard` |
| `amounts` | `[edge, clean, perfect]` |
| `cooldown` | ms before the slot can strike again |
| `kick` | knock on your own dot (per hit for a volley) |
| `pattern` | `bump`, `side` or `taps` |
| `hits`, `gap` | volleys: number of hits, ms between them |
| `debuff` | on yourself: `{"kind", "strength", "ms"}` |
| `bleed`, `stagger_ms`, `targets`, `weather`, `requires`, `rank`, `rarity` | as their names say; `weather` is in weather.md |

The seed validator refuses rhythm fields (`period`, `window`,
`perfect_window`).

### NPC attacks

`name`, `period` (ms between blows), `damage`, `hit` (its text), `defend`
(`both`, `block`, `dodge` or `none`), `kick`, `warn` (default
`balance_warn_ms`), `debuff` (on the player: `{"kind", "strength", "ms"}`),
`stagger` (default false). Bosses have `poise`.

### Rules (`seed.json` `rules`)

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
| `balance_global_cd_ms` | 900 |
| `balance_wobble_ms` | 2500 |
| `balance_block_cut` | 0.7 |
| `balance_block_kick` | 0.15 |
| `balance_perfect_block_poise` | 40 |
| `balance_boss_stagger_ms` | 4000 |
| `balance_boss_stagger_dmg` | 1.5 |
| `balance_boss_poise_decay` | 5 |
| `balance_damage_scale` | 0.4 (set by tuning) |
| `defend_perfect_ms` | 60 (the perfect-block window) |
| `armor_k` | 30 |
| `out_of_fight_cooldown_scale` | 3 |

The encounter sends the rules it uses to the client when it starts, so
tuning happens in one place.

## Protocol

Client → server (beside `cmd` and `ping`; see `alzendor/session.py`):

```
{"type": "input", "seq": 812, "step": 1290, "keys": 5, "act": "strike", "slot": 1, "target": "npc:orc-1"}
```

- `keys`: bitmask of held steering keys (1 up, 2 down, 4 left, 8 right).
- `step`: the step the client applied it at.
- `act` (optional): `strike` (with `slot`, and `target` when not the
  current one), `dodge`, `block`, `unblock`, or `flee` (with `dir`: `back`).
- Sent on any change, and every 100 ms during an encounter. At most 30 a
  second; over that, the session drops them.
- Typed `USE 2`, `DODGE`, `BLOCK` and `UNBLOCK` go through `commands.py`,
  which turns them into the same inputs, so typed and pressed are one path.

Server → client:

| Message | Carries |
|---|---|
| `encounter` event (player's stream) | `start`: id, seed, rules, `start_ms`, players, NPCs. `join` and `leave`: who. `end`: why |
| `room` event | plus `danger`: the ids of neighbouring rooms with enemies, when you can see them (or with Hunter's Nose) |
| `look` event | for `LOOK <direction>`: the room's name and its enemy cards, or why you can't see; plus `danger` refreshed |
| `state` message (direct, 15 a second) | `step`; per player: position, velocity, held keys, debuffs, cooldowns, staggered, immune, dodging, blocking, last `seq`; per NPC: next blows (time, target, kick, direction, `warn`); boss meters |
| `combat` event (room) | strikes with `tier`; blows with `result` (`hit`, `dodge`, `block`, `perfect_block`, `staggered`, `parting`) |
| `refused` message (direct) | a dropped strike, dodge, block or flee and why (`not_steady`, `cooldown`, `staggered`, `blocking`, `empty`, `no_shield`, `gone`, `no_target`, `no_exit`, `dark`, `no_way_back`) |

Positions only go to players in the encounter. Everyone in the room sees the
`combat` events.

## Tuning

`tools/balance_bot.py` imports `alzendor/balance.py` and plays it with no
server. It has two players:

- **ideal**: steers to the centre with full knowledge, and strikes and
  dodges at the best moment;
- **sloppy**: 250 ms reaction delay, steering noise, never perfect-blocks.

For each fighting NPC, it plays a character of the zone's level (its
`ZONE_LEVELS`, from [zones.md](zones.md); stat points spread evenly) with
each class's starting loadout, the class talents available by that level, and
the slot gear and armour that zones below that level give. Its damage sums
are its own copy of `encounter_blow`'s, pinned to it by
`tests/test_encounters.py`.

Targets:

| Enemy | Target |
|---|---|
| ordinary NPC, solo, at its zone's level | ideal kills in 20–40 s; sloppy wins at least 80% of fights |
| boss under 1000 `max_hp`, solo | ideal wins in 2–4 min, at least 90% of fights; sloppy may lose |
| boss of 1000 `max_hp` or more | three ideal players win in 2–4 min, at least 90% of fights |
| a room of three or more enemies, all at once | sloppy wins at least 60% |

Running it:

```sh
python -m tools.balance_bot -n 20 --seed 7     # every NPC against the targets (several minutes)
python -m tools.tune_balance --dry-run         # what retuning would change
python -m tools.tune_balance --steps 5         # only the last step, on the content as it is
```

`tools/tune_balance.py` writes into the content, in order: (1) health by
tier, so each kind and level's median fight takes its target time; (2) a
nudge for each NPC still outside its window; (3) slower attacks (up to
2.5×) where the player loses too often; (4) rooms of three or more
staggered; (5) where the player still loses, the NPC's hardest-hitting
attack loses damage, down to half. Experience stays where it was.
`balance_damage_scale` (0.4) was set first, so the median ordinary NPC dies
in about 30 s to the ideal player.

Where it stands (all five steps, checked on fights it wasn't tuned on: `-n 20
--seed 7`, 3 Nov 2026): **132 of 178 NPCs on target**, and the median
ordinary NPC dies in 27 s to the ideal player. Off target:

- big bosses three ideal players never beat: the Leviathan, the Fallen Star
  and the Storm King (nine before step 5); others they beat a third to
  nearly nine times in ten;
- lone bosses of the frontier (Old Gnasher, Brakka, Captain Crowe, the
  Hollow Rider, the Abbot's Shade, the Weaver Queen): one class in three
  beats each;
- late-realm ordinary enemies the sloppy player beats too rarely: crystal
  golems (32%), hollow knights (50%), star spawn (60%), bone drakes (67%),
  glass eels and rot elks (77%).

Their attacks are as slow as the tuner may make them, and their biggest
blows at half, so the next step is a design call: more players for big
bosses, other targets, or different attacks (todo.md, §18).

`tests/test_tuning.py` (marked slow: `pytest -m slow`) runs a 3-fight version
on a fixed sample of 10 NPCs: the ones on target are asserted, and the rest
are listed in `STILL_OFF`.

## Not built

- Prompts before a fight, safe zones, or areas with their own attack rules.
  What you can see is the only warning.
- Live danger updates: rings change only when you arrive or look.
- Resuming an encounter on another server when its owner dies.
- NPCs reacting to your balance (striking harder when you're staggered).
- Weather changing the simulation (wind speeding the well). Weather scales
  gear amounts and hides danger.
- Debuffs beyond `heavy`, `reeling`, `wobble` and `steady`.
- Showing other players' dots. Allies see your strikes and staggers on your
  card and in the log.
- PvP duels (planned: todo.md).
