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
- **Here.** Everyone in the room, as cards: name (players and NPCs in
  different colours), race/class, short description and health.
- **Targeting.** In the command box, **Tab** / **Shift+Tab** cycle through the
  cards and **Esc** clears the selection. Commands that take a target (`kick`,
  `poke`, `wave`, `inspect`, …) go to the selected card when you don't type a
  name, even if two NPCs share a name. Clicking a card selects it too.
- **On the ground.** Items (click to look, or **get**) and room features you
  can look at or touch.

### Combat and rhythms

Every action in a fight belongs to a **rhythm**, and each rhythm has its own
timing bar above the "Here" cards:

| Rhythm | Command | Beat | Window (perfect) | Effect |
|---|---|---|---|---|
| Melee | `k` / `kick` | 2 s | ±300 ms (±100) | 4 / 5 / 8 damage |
| Spells | `mm` / `missile` / `cast magic missile` | 8 s | ±400 ms (±130) | 10 / 12 / 20 damage |
| Potions | `hp` / `potion` | 5 s | ±350 ms (±120) | heals 10 / 15 / 25 |

(Effects are opening / good / perfect.) The first use of a rhythm lands
straight away and starts it. Its ball then swings out to the right and back to
the centre, then out to the left and back, and each centre crossing is a beat.
An action lands only if it reaches the server within its rhythm's window around
a beat. A good fight keeps every rhythm on its beat.

- Every attempt uses up a beat, hit or miss. One sent before the next unused
  beat takes that beat and misses, so mashing Enter only burns beats.
- In a fight the command box keeps your last command, highlighted: press Enter
  on the beat to repeat it, or type to replace it.
- A rhythm belongs to you, not the fight. It carries on across targets, kills,
  leaving the room and reconnecting, and ends only after 10 seconds unused (or
  two beats, if longer). Stepping out and back in doesn't buy a fresh opener.
- Redis's clock judges the timing, the one clock every server shares. The
  client syncs to it with ping/pong and draws each ball where it will be when
  your command arrives, so pressing Enter when the ball looks centred lands on
  the beat.
- An NPC at 0 HP collapses and comes back after its `respawn` time (60 s by
  default). Players can't be attacked yet, so potions have nothing to heal for
  now. Your health is in the header.

Rhythms and abilities are defined at the top of the combat section of
[alzendor/alzendor.lua](alzendor/alzendor.lua). A player can have their own
beat for a rhythm (`period:<rhythm>` on their account).

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
| `ALZ_HEARTBEAT_SECONDS` | `10` | |
| `ALZ_SESSION_TTL_DAYS` | `7` | Lifetime of a "stay signed in" token, extended on use |
| `ALZ_SIGNUPS_PER_HOUR` | `20` | New accounts per client address per hour. Locally, all clients share Docker's gateway address |
| `ALZ_LOG_LEVEL` | `INFO` | |
| `ALZ_DOMAIN` | | Production only: the public domain |
| `ALZ_HTTP_PORT` / `ALZ_HTTPS_PORT` | `80` / `443` | Production only: Caddy's host ports |

## The world map

[world/seed.json](world/seed.json) defines cities, areas, rooms, items, NPCs,
default chat channels, and ambient events like bells and weather. Every
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
  Brannoc").

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
- `timing`: one of your rhythms (`rhythm`, `label`, `hint`, `active`, and
  while active `start_ms`, `period_ms`, `grace_ms`, `perfect_ms`,
  `last_beat`, `last_ms`, `timeout_ms`). Every rhythm is sent on connect.
- `combat` / `heal` (have text): an action's `rhythm`, `result` (`opener`,
  `perfect`, `good`, `early`, `late`, `miss`), and `damage` or `amount`
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
world/seed.json  the map
tests/
```
