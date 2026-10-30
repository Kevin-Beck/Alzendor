# Alzendor

A multiplayer text world (a MUD) where **places are channels**. Being in a room
means being subscribed to that room's channel; whatever happens there is
published to it, and everyone subscribed sees it. Moving means swapping one
room channel for another. See [todo.md](todo.md) for the full concept and
roadmap.

```
 Browser / CLI ──WebSocket──► Server 1 ─┐
                                        ├──► Redis — world state + event streams
 Browser / CLI ──WebSocket──► Server 2 ─┘        (the single source of truth)
```

- **Servers** hold client connections, parse input, and run actions against
  Redis. They keep no game state, so you can run as many as you like, and a
  client can reconnect to any of them.
- **Redis** stores the world and carries every event. Each action is one
  atomic function inside Redis ([alzendor/alzendor.lua](alzendor/alzendor.lua))
  that checks the world, changes it, and appends the resulting events.
- **Clients** send what they're trying to do and show the events they receive.
  Anything that speaks WebSocket + JSON can be a client; a web client and a
  terminal client are included.

## Consistent ordering

Every channel (`PLAYER:kevin`, `ROOM:tavern`, `AREA:docks`, `CITY:harrowgate`,
`CHANNEL:general`) is a Redis Stream, and every event's ID is the next number
from one global counter. That gives one total order across the whole world:

- Everyone who sees two events sees them in the same order, on every server.
- Entering a room returns the room's state and the point in the sequence it
  was taken at, together. Nothing that happens in that room around the moment
  you enter can be missed or shown twice.
- A connection's whole position in the world is one number. A client that
  drops resumes from its last sequence number, on any server, and gets exactly
  what it missed.
- Subscription changes are events too (on the player's own stream), so a
  server switches a player's channels at exactly the right point in the
  sequence. [alzendor/feed.py](alzendor/feed.py) explains how.

## Running locally

Requires Docker.

```sh
cp .env.example .env            # optional: put your name in ALZ_ADMINS
docker compose up -d --build    # Redis + two game servers
```

Open <http://localhost:8001> and <http://localhost:8002> in two windows. Each
one is served by a different server, and both are in the same world. Create an
account in each and try `look`, `north`, `say hello`, `touch ground`,
`get map`, `tell <name> hi`, `chat general hi`, and `help`.

The web client is built around the map:

- **Map.** Areas are boxes inside their region's box (a city like Harrowgate,
  or a wild place like Spiderwood), and rooms are dots placed where the seed
  map puts them. You see the rooms you've explored, plus faint outlines of the
  rooms their exits lead to. The map frames the area you're in and glides to
  each new area as you cross into it. Click any room to walk there; each step
  is a real move, and typing a command, pressing Esc or clicking the map stops
  the walk. Drag to pan and scroll to zoom; **Area** and **All** switch between
  following your area and showing everywhere you've been.
- **Combat.** Your three slots, and below them your target's card: a
  portrait, health, whether they're hostile, neutral or friendly to you, what
  their faction thinks of you, and each of an NPC's attacks with a bar filling
  up to its next blow. Everything about a fight is in one place.
- **Here.** Everyone in the room, as cards: name (players and NPCs in
  different colours), race/class, short description, health, and an NPC's
  disposition. Sleeping players are marked asleep.
- **Inventory** and **Character** (header buttons). Your gear, with buttons to
  put any piece in slot 1, 2 or 3; and your level, experience, stats (with
  `+` buttons when you have points to spend), abilities and reputation.
- **Targeting.** In the command box, **Tab** / **Shift+Tab** cycle through the
  cards and **Esc** clears the selection. Your slots and commands that take
  a target (`poke`, `wave`, `inspect`, …) go to the selected card when you don't type a
  name, even if two NPCs share a name. Clicking a card selects it too.
- **On the ground.** Items (click to look, or **get**) and room features you
  can look at or touch.

### Combat: three slots

You have three **slots**, and each holds one piece of gear: a weapon, a spell,
a potion. The game treats them all alike. Press **1**, **2** or **3** (or click
a slot's bar, or type `use 2`) to use one on your target. Each piece of gear
has its own **beat**, timing window and amounts, so every slot keeps its own
rhythm with its own timing bar above the "Here" cards.

There's no roll to hit: if you land in the window, it lands. Fitting three
rhythms together is the skill. Fast gear gives you lots of chances for small
hits; slow gear hits hard but is easy to miss. Rhythms that overlap make it
harder to land them all.

| Gear | Kind | Beat | Window (perfect) | Effect |
|---|---|---|---|---|
| Dagger | weapon | 1.2 s | ±200 ms (±70) | 2 / 3 / 5 damage |
| Kick | melee | 2 s | ±300 ms (±100) | 4 / 5 / 8 damage |
| Healing Draught | potion | 2.5 s | ±250 ms (±80) | heals 4 / 6 / 10 |
| Sword | weapon | 2.5 s | ±300 ms (±100) | 6 / 7 / 11 damage |
| Firebolt | spell | 4 s | ±300 ms (±100) | 8 / 10 / 16 damage |
| Greataxe | weapon | 4.5 s | ±250 ms (±80) | 10 / 14 / 24 damage |
| Health Potion | potion | 5 s | ±350 ms (±120) | heals 10 / 15 / 25 |
| Magic Missile | spell | 8 s | ±400 ms (±130) | 14 / 18 / 30 damage |

(Effects are opening / good / perfect.) There's also **Mending Light** (a
6 s spell healing 8 / 12 / 20 that can heal another player or a friendly NPC
you've targeted). New characters own a Dagger, Kick, Magic Missile and Health
Potion, with the last three in their slots. The rest comes from levelling up
and from what NPCs drop. `gear` (or the Inventory panel) lists what you own and
what's in your slots; `equip sword 2` puts your sword in slot 2, and
`unequip 2` empties it. The same gear can go in more than one slot: three
potions is a loadout too.

The first use of a slot lands straight away and starts its rhythm. Its ball
then swings out to the right and back to the centre, then out to the left and
back, and each centre crossing is a beat. A use lands only if it reaches the
server within its gear's window around a beat.

- Every attempt uses up a beat, hit or miss. One sent before the next unused
  beat takes that beat and misses, so mashing keys only burns beats.
- **1**, **2** and **3** fire straight away when the command line is empty (or
  in a fight, when it holds your last command, selected). Typing a sentence
  with a number in it doesn't use a slot.
- A rhythm belongs to you, not the fight. It carries on across targets, kills,
  leaving the room and reconnecting, and ends only after 10 seconds unused (or
  two beats, if longer). Stepping out and back in doesn't buy a fresh opener,
  and neither does swapping gear: a slot can't be changed while its rhythm is
  running.
- Redis's clock judges the timing, the one clock every server shares. The
  client syncs to it with ping/pong and draws each ball where it will be when
  your command arrives, so pressing the key when the ball looks centred lands
  on the beat.
- An NPC at 0 HP collapses and comes back after its `respawn` time (60 s by
  default). Your health is in the header.
- The **Training Yard** (east of the smithy) has a Training Dummy, which never
  attacks, and a Sparring Post, whose arm clips you every 6 seconds: good for
  practising with a potion in a slot. Neither ever falls, and they give no
  experience.

Gear is defined in [world/seed.json](world/seed.json) (see below); the rules
are in the combat section of [alzendor/alzendor.lua](alzendor/alzendor.lua).

### NPCs fight back

NPCs have one or more attacks, each slow next to yours (one every 5–13
seconds) and each on its own timer. NPCs never miss, so there's nothing for
the server to judge: it simply lands each attack when it's due (every server
runs a combat tick ten times a second, and each attack is taken off a shared
schedule in Redis as it lands, so it lands exactly once). Their timers are
shown on the target card so you can plan around them.

Every NPC is **hostile** (attacks you on sight), **neutral** (fights back if
you attack it) or **friendly** (can't be attacked). Everything can be
targeted: friendly NPCs can be healed with gear that heals allies, and `say`
and emotes go to your target. An NPC fights the first of its foes who is
still in the room; leave and it forgets you.

At 0 HP you collapse and wake at the temple shrine with half your health, a
tenth of a level's experience poorer (never losing a level).

### Reputation: affinity and respect

NPCs can belong to a **faction**, and every faction holds two separate
opinions of you: **affinity** (do they like you?) and **respect** (do they
rate you?), each from -100 to 100. What moves them is the faction's
**culture**: rules in the seed that match your deeds (`kill`, `clean_kill`
(a perfect killing blow), `ambush` (striking an NPC that wasn't fighting you),
`flee`, `defeated`, `heal`, `greet` (bow, wave, nod, smile, cheer) and `taunt`
(laugh, poke, point)), optionally only when the NPC involved is of a given
faction or role. Each change is shown with the reason.

- **The Back-Alley Orcs** hate you for killing their warriors but respect a
  fair fight: honourable kills and clean blows earn respect, while ambushes,
  running away, losing, and killing their young cost it. Enough respect and
  they stop attacking you on sight, even while they hate you.
- **The Spiderwood Brood** prize cunning: ambushes and slipping away earn
  their respect.
- **The Folk of Harrowgate** like you for clearing out orcs and spiders,
  healing them and having good manners, and dislike rudeness.
- **The Wardens of the Wood** like you for keeping spiders off the road.

Affinity and respect shift how an NPC treats you: a friendly NPC whose
faction comes to hate you turns hostile; a neutral one turns hostile or
friendly; a hostile one stays its hand if it respects you or likes you enough.
Greetings and taunts count once per NPC per 10 minutes. Your **Presence**
stat moves every change further.

### Experience, stats and abilities

Defeating NPCs earns experience (each level needs 100 × your level). Each
level gives a **stat point** to spend with `train <stat>` (or the `+`
buttons), and the seed's level table grants gear and abilities: a Sword at
level 2, Mending Light and Woodcraft at 3, Firebolt and the Healing Draught at
4, Shore-sleeper at 5, a Greataxe at 6.

The stats are deliberately plain: everyone wants them, and you choose where
your points go. Gear and abilities are what make characters different.

| Stat | Each point |
|---|---|
| Vigor | 8 more max health |
| Poise | timing windows 15 ms wider (never reaching halfway to the next beat) |
| Focus | perfect windows 10 ms wider (never wider than the window) |
| Presence | your deeds move reputation 15% further, good or bad |

`stats` shows your sheet as text.

### Resting and leaving

Inns, shrines and camps are **safe places** (the room panel says "safe to
rest"). Quit there, or go idle there, and you settle in to rest and are gone
at once. Anywhere else you **lie down to rest**: your sleeping body stays in
the room for two minutes, and everyone there can see it. NPCs already
fighting you keep at it, so logging out is no escape. Come back in time and
you wake where you lay; otherwise your body fades and you arrive later, well
rested. Abilities can make a kind of terrain safe for you: **Woodcraft** makes
any forest safe, **Shore-sleeper** any stretch of coast.

The same happens if your connection drops and doesn't come back within
`ALZ_LINKDEAD_SECONDS`, or if you send no commands for `ALZ_IDLE_MINUTES`.
Out of a fight, wounds heal slowly (faster somewhere safe). Moving has a
short cooldown (250 ms), so a client can't send a whole journey at once.
See [docs/design.md](docs/design.md) for the thinking behind this and other
options.

## Deploying

The production setup is the local one plus
[docker-compose.prod.yml](docker-compose.prod.yml). That file adds
[Caddy](https://caddyserver.com) for HTTPS with automatic certificates and
load balancing across the servers, and it closes every other port. On a server
with Docker and a DNS name pointing at it:

```sh
git clone <this repo> && cd Alzendor
cp .env.example .env   # set ALZ_DOMAIN (and ALZ_ADMINS)
docker compose -f docker-compose.yml -f docker-compose.prod.yml up -d --build
```

Players then go to `https://<your domain>`. To add capacity, add a `server3`
next to the others and to the [Caddyfile](Caddyfile). Redis persists to a
volume with append-only logging. Servers can be restarted one at a time:
players on a restarting server reconnect to another without leaving the world,
as long as they're back within `ALZ_LINKDEAD_SECONDS`.

## Configuration

Servers read `ALZ_*` environment variables (compose passes `.env` through):

| Variable | Default | |
|---|---|---|
| `ALZ_REDIS_URL` | `redis://localhost:6379/0` | |
| `ALZ_HOST` / `ALZ_PORT` | `0.0.0.0` / `8000` | |
| `ALZ_SERVER_ID` | hostname | Shown to clients and in logs |
| `ALZ_SEED_FILE` | `world/seed.json` | The map; see below |
| `ALZ_ADMINS` | | Comma-separated account names allowed to `announce` |
| `ALZ_ALLOWED_ORIGINS` | any | Browser origins allowed to connect; production sets `https://$ALZ_DOMAIN` |
| `ALZ_TRUST_PROXY` | `false` | Use `X-Forwarded-For` for client addresses (production sets it) |
| `ALZ_LINKDEAD_SECONDS` | `60` | How long a dropped player stays in the world |
| `ALZ_IDLE_MINUTES` | `30` | A player who sends no commands for this long leaves (lying down to sleep unless somewhere safe); `0` turns it off |
| `ALZ_HEARTBEAT_SECONDS` | `10` | |
| `ALZ_SESSION_TTL_DAYS` | `7` | Lifetime of a "stay signed in" token, extended on use |
| `ALZ_SIGNUPS_PER_HOUR` | `20` | New accounts per client address per hour. Locally, all clients share Docker's gateway address |
| `ALZ_LOG_LEVEL` | `INFO` | |
| `ALZ_DOMAIN` | | Production only: the public domain |
| `ALZ_HTTP_PORT` / `ALZ_HTTPS_PORT` | `80` / `443` | Production only: Caddy's host ports |

## The world map

[world/seed.json](world/seed.json) defines cities, areas, rooms, items, NPCs,
gear, default chat channels, and ambient events like bells and weather. Every
server loads it at start. Map data is rewritten each time. Live state (where
items are, who is where, NPC health) is never overwritten.

- **Rooms** have a `pos` of `[x, y]` on an abstract plane (x grows east, y
  grows south). Distances are only for drawing, not travel: put rooms wherever
  the map reads best. Exits can go `north`, `south`, `east`, `west`,
  `northeast`, `northwest`, `southeast`, `southwest`, `up` and `down` (drawn
  dashed). Rooms also have `features` you can look at, and `flavor` text for
  verbs on them (`"touch:ground": "crouches and presses a palm to…"`).
- **Areas and cities** get their boxes from the rooms inside them. A "city" is
  any top-level region: Harrowgate is a city, Harrowlake a village, Spiderwood
  a forest. Crossing between regions swaps the player's `CITY:` channel, so
  each region has its own weather and announcements. Leave clear space between
  regions and between areas so their boxes don't touch on the map. Areas are
  coloured in id order, or set `"color": 1`–`6`.
- **NPCs** have a `name`, `label` (race/class), short `description`, longer
  `details` for `inspect`, `keywords` to refer to them by, a `room` and
  `max_hp`, and optionally `respawn` (seconds, default 60). Set
  `"proper": true` for named characters ("Brannoc" rather than "the
  Brannoc"). For combat and reputation: `disposition` (`hostile`, `neutral`
  or `friendly`), `faction`, `role` (e.g. `warrior`, `young`; cultures can
  judge by it), an `icon` (an emoji for the target card), `attacks` (each
  with a `name`, `period` in ms, `damage` and `hit` text using `{actor}` and
  `{target}`), `xp` (default half its max HP), `drops` (gear ids given to
  whoever kills it) and `"immortal": true` for practice targets.
- **Rooms** can be `"safe": true` (inns, shrines, camps) and have a `terrain`
  (`forest`, `coast`, …) that perks can make safe.
- **Factions** have a `name`, `description` and `rules`: each rule has a
  `deed`, optionally `of` (the faction of the NPC involved) and `role`, the
  `affinity` and `respect` it adds, and a `note` explaining why.
- **Perks** (abilities) have a `name`, `description` and optionally a
  `safe_terrain`. **`levels`** maps a level number to the `gear` and `perks`
  it grants. **`starting_gear`** is what new characters own.
- **`rules`** holds tunable numbers: `move_cooldown_ms`, `sleep_seconds`,
  `shrine_room`, `regen` and `safe_regen` (health per upkeep, every 5 s) and
  `social_cooldown` (seconds).
- **Gear** has a `name`, `kind` (shown in `gear`), `keywords`, an `effect`
  (`damage` a target, or `heal` yourself), a `period` (ms between beats), a
  `window` and `perfect_window` (ms either side of a beat), `amounts` (opening
  / good / perfect), and texts: `hit`, `perfect_hit` and `miss` for the room
  (with `{actor}` and `{target}`), and `whiff` for you when you mistime it.
  `loadout` lists the gear new characters start with, one per slot.

## Protocol

One JSON object per WebSocket message, at `/ws`. The full reference is in
[alzendor/session.py](alzendor/session.py). In short: the client sends
`register`, `login` or `resume`, then `{"type": "cmd", "text": "...",
"target": "npc:orc-1"}` messages (`target` is optional). The server sends
`auth_ok`/`auth_error`, then a stream of `{"type": "event", "event": {...}}`
messages, each with a `seq`. Clients can also send `{"type": "ping", "t": …}`
and get back a `pong` with `server_ms`, Redis's clock, for drawing combat
timing. Most events have a `text` to show. A few are pure
state updates, without one:

- `room`: the full room, with `entities` (cards), `items` and `features`
- `map`: explored rooms, glimpsed rooms, areas and cities (`full` replaces
  what the client knows; otherwise merge it in)
- `entity`: a changed card
- `timing`: one of your slots (`slot`, `label`, and if it holds something
  `gear`, `kind` and `period_ms`; `active`, and while active `start_ms`,
  `grace_ms`, `perfect_ms`, `last_beat`, `last_ms`, `timeout_ms`). Every slot
  is sent on connect, and again when its gear changes.
- `gear` (has text): all the gear there is, and the ids in your `slots`
- `combat` / `heal` (have text): a use's `slot`, `result` (`opener`,
  `perfect`, `good`, `early`, `late`, `miss`), and `damage` or `amount`. An
  NPC's attack is a `combat` event with its `entity_id`, the `target` it hit
  and `damage`
- `npc_timing`: an NPC starting, continuing or stopping a fight (`entity_id`,
  `active`, `target`, and `attacks` with `name`, `period_ms`, `damage` and
  `next_ms`, by Redis's clock). Room cards carry the same as `fight`
- `dispositions`: how each NPC in your room treats you, by entity id. Room
  cards carry `disposition` (for you) and `base_disposition` (its nature)
- `kit`: the gear you own, your `slots` and the `items` you carry
- `character`: your `level`, `xp`, `xp_next`, `points`, `stats`,
  `stat_info`, `perks`, `factions` (with affinity and respect), `hp`, `max_hp`
- `reputation` (has text): a faction's opinion of you changed
- `death` (has text): an NPC going down, with its `entity_id`
- `arrive` / `leave` (these have text) carry `entity` / `entity_id`, so the
  client can keep its cards current

## Accounts and security

- Passwords are hashed with Argon2id on the server, with a salt per account.
- Login errors don't reveal whether an account exists.
- Failed logins are rate limited per address and per account. Account creation
  is rate limited per address.
- Session tokens are random. Only their SHA-256 is stored, and `logout`
  revokes them.
- Origin checks guard the WebSocket. Message sizes and command rates are
  capped per connection.
- Only the server changes subscriptions: personal and room channels can't be
  joined.

## Layout

```
alzendor/
  alzendor.lua   game rules, run atomically in Redis
  commands.py    command parsing and one handler per command
  feed.py        ordered event delivery from Redis streams
  session.py     the protocol for one connection
  server.py      WebSocket server, web client, heartbeats, ambient events
  auth.py        accounts, passwords, tokens, rate limits
  world.py       loading the rules and the map
  cli.py         terminal client
  web/index.html web client
world/seed.json  the map, gear, NPCs, factions, perks and levels
docs/            design notes: stats, reputation, leaving the world, quests
tests/
```
