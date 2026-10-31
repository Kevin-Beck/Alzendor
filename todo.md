# Alzendor — Concept & TODO

## The concept

Alzendor is a text-based multiplayer world (a MUD) where **places are channels**.

A player is always *in* somewhere: a room, inside an area, inside a region. Being in a place means being subscribed to that place's channel. Whatever happens in the room — someone speaks, arrives, leaves, picks something up, or just touches the ground — is published to the room's channel, and everyone subscribed (everyone in the room) sees it.

> Kevin is in the Tavern. He types `touch ground`.
> The server checks the action, then publishes to `ROOM:tavern`.
> Everyone in the Tavern sees: *Kevin crouches and presses a palm to the worn floorboards.*
> Players in the room next door see nothing; they're subscribed to a different channel.

Moving from room to room means **unsubscribing from the old room's channel and subscribing to the new one**. Your view of the world is the set of channels you're subscribed to.

Chat channels, the part that works today, are the same mechanism with no location attached.

## Architecture

The original design, with two changes: clients connect over WebSocket (so a browser can be a client), and events travel through Redis Streams instead of pub/sub (so every connection sees one consistent order).

```
 Clients ──WebSocket──► Server 1 ─┐
                                  ├──► Redis (state + streams) — single source of truth
 Clients ──WebSocket──► Server 2 ─┘
```

- **Servers** hold client connections, parse and check input, and publish *outcomes* to Redis. They keep no game state of their own, so you can add more of them to scale.
- **Redis** stores world state and sends events. Two players on different servers who are in the same room both receive room events, because both servers are subscribed to that room's channel.
- **Clients** send what they're trying to do and show the events they receive. They never talk to Redis directly.

## Core rules

1. **The server decides what happens.** Clients send *intents* (`touch ground`, `move north`). The server checks them against world state (is the player here? does that exit exist? is the item in the room?) and only then publishes the *result*.
2. **Channels are layered.** A player is subscribed to several levels at the same time:

   | Channel | Who hears it | Example events |
   |---|---|---|
   | `PLAYER:<name>` | Only that player | "You can't go that way", inventory, room description on entering, DMs |
   | `ROOM:<id>` | Everyone in the room | speech, emotes, touch ground, arrive/leave, pick up/drop |
   | `AREA:<id>` | Everyone in the area | a bell tolling, a distant explosion |
   | `REGION:<id>` | Everyone in the region | weather, announcements, region-wide events |
   | `CHANNEL:<name>` | Anyone who joined | ordinary chat channels (what works today) |

   Moving between rooms only changes the `ROOM:` subscription, unless you cross into another area or region.
3. **Streams carry events and Redis keys store state.** Each channel is a Redis Stream, and every event's ID comes from one global counter, so all events share a single order. Each room's saved state (description, exits, items, who's present) lives in Redis hashes and sets. When a player enters a room, they get that state along with the exact point in the sequence it was taken at, so nothing is missed or repeated. A client that drops resumes from its last sequence number.
4. **Only the server manages subscriptions.** Players can't subscribe to `PLAYER:` or `ROOM:` channels directly. Moving is the only way to change room subscriptions, and personal channels are always private.
5. **Every action is atomic.** An action's check, state change and published events happen in one Redis function (`alzendor/alzendor.lua`), so no two actions can interleave (two players grabbing the same item, someone arriving as you leave).

## Event format

Room events should be structured, not raw chat strings, so clients can display different kinds differently:

```json
{
  "channel": "ROOM:tavern",
  "type": "emote",
  "actor": "kevin",
  "verb": "touch",
  "target": "ground",
  "text": "Kevin crouches and presses a palm to the worn floorboards.",
  "ts": 1729530000
}
```

`type` examples: `say`, `emote`, `arrive`, `leave`, `item`, `system`.

## Movement steps (`move north`)

All of these steps run as one atomic Redis function, `move` in `alzendor/alzendor.lua`. Steps 4 and 6 change the subscriptions stored in Redis and append a `control` event that tells the player's server to switch channels at exactly that point in the sequence.

1. Look up the player's current room: `PLAYER:kevin:room` → `tavern`
2. Look up the exit: `ROOM:tavern` exits → `north: market_square` (if it's missing, send "You can't go that way" to `PLAYER:kevin` and stop)
3. Publish `leave` to `ROOM:tavern`: *Kevin heads north.*
4. Remove Kevin from the tavern's player set; unsubscribe from `ROOM:tavern`
5. Set `PLAYER:kevin:room` = `market_square`; add Kevin to the market square's player set
6. Subscribe to `ROOM:market_square`; if the area or region changed, swap those subscriptions too
7. Publish `arrive` to `ROOM:market_square`: *Kevin arrives from the south.*
8. Send the room description, exits, items and present players to `PLAYER:kevin`

Movement is the first real game mechanic; most later features depend on it.

## TODO

### 1. Fix what's broken in the existing networking
The C# code has been replaced by a Python (asyncio) implementation; each problem is handled by its design:
- [x] Logins no longer block new connections: every connection is its own async task
- [x] Disconnects are detected by the WebSocket layer (with keepalive pings)
- [x] Clean up on disconnect: after a grace period (`ALZ_LINKDEAD_SECONDS`) the player leaves the room, `leave` is published and room/area/region subscriptions are dropped; chat channels are kept for next time. A heartbeat reaper also cleans up after servers that crash
- [x] Message boundaries and UTF-8 come with WebSocket text frames; every message is one JSON object
- [x] Bad commands get a usage hint, and a failing command never ends the connection
- [x] Input cleaning (`commands.clean`) keeps its result
- [x] `edit`/`change` channel renaming was dropped; channels are now `create`/`join`/`leave`
- [x] Every server message is JSON
- [x] Redis connection retries back off (up to 10s); the web client reconnects with backoff and resumes

### 2. Separate names and secure channels
- [x] Give each kind of channel its own prefix: `PLAYER:`, `ROOM:`, `AREA:`, `REGION:`, `CHANNEL:`
- [x] Stop players from subscribing to `PLAYER:`/`ROOM:`/`AREA:`/`REGION:` themselves (fixes anyone being able to read anyone's DMs)
- [x] Add `unsubscribe` / `leave <channel>` for chat channels
- [x] Real login: accounts with hashed passwords, so names are owned rather than first come, first served. Uses server-side Argon2id instead of the client-side salt scheme from `Client.cs` (a hash the client sends is effectively the password); TLS comes from Caddy in production

### 3. World model
- [x] Define what a room stores: `id`, `name`, `description`, `exits {dir: roomId}`, `area`, `items[]`, `players` (a Redis set)
- [x] Define areas and regions as groups of rooms
- [x] Seed a small test map (5–10 rooms, 2 areas, 1 region) from a JSON file at server start (`world/seed.json`)
- [x] On login, put the player in their last room (or a starting room) and subscribe them to their room, area, region and personal channel

### 4. Room actions
- [x] `look`: room description, exits, items, present players (sent to the player only)
- [x] `move <dir>` / `n s e w`: the movement steps above
- [x] `say <text>`: speech to the room
- [x] `emote <text>` and fixed verbs (`touch ground`, `wave`, `sit`) as structured room events
- [x] `get` / `drop <item>`: change room state, then publish the event
- [x] `inspect <thing>`: a private reply, or optionally a room event ("Kevin examines the anvil")
- [x] Area and region events (a timer or admin command that publishes to `AREA:`/`REGION:`)

### 5. Code structure
- [x] Replace the `if/else` chain in `ActionProcessor` with one handler per action type (`commands.py`)
- [x] Have the parser find commands automatically instead of a hand-written `actionMap`; add `help` to list commands
- [x] Remove or finish dead code (gone with the C# code)
- [x] Async sockets and WebSockets so a browser client is possible (`alzendor/web/index.html`)

### 6. Running & deploying
- [x] `docker-compose.yml` with Redis + 2 server instances to prove the multi-server setup works locally
- [x] One Dockerfile at the repo root (runtime and test targets); `docker-compose.prod.yml` adds Caddy for HTTPS
- [x] Listen on `0.0.0.0` (or a configured address) instead of the first address `localhost` resolves to
- [x] Read the port and Redis address from config or environment variables (`ALZ_*`, see the README)
- [x] Tests: the parser, the action handlers (against a test Redis), and an end-to-end test where two clients on two servers see each other move between rooms

### 7. Map and room UI
- [x] Rooms have positions on an abstract plane; areas and regions are boxes around their rooms, nested on the map
- [x] Fog of war: players see the rooms they've explored and outlines of where exits lead (`PLAYER:<id>:explored`)
- [x] Click a room on the map to walk the shortest known path, one real move at a time
- [x] Diagonal exits (`northeast` …) and dashed up/down connections
- [x] NPCs (stationary for now) and players shown as cards: name, race/class, short description, health bar; different colours for PCs and NPCs
- [x] Tab / Shift+Tab to pick a target; commands that take a target use it, by exact id
- [x] On-the-ground panel for items and room features
- [x] `describe <text>` to set the short description on your card
- [x] Regions beyond Harrowgate: Harrowlake (west of the docks) and Spiderwood (north through the North Gate), each with its own areas, NPCs and weather
- [x] The map follows the area you're in, gliding to each new area; Area / All views; room names placed so they never collide
- [x] Rename cities to regions: Region › Area › Room, `REGION:` channels
- [x] Region states per player (`PLAYER:<id>:regions`): explored, discovered (borders an explored region; drawn greyed out), unknown (not drawn), and hidden regions that only maps and reputation reveal. "All" shows only known regions, and pan/zoom stop at them
- [x] Map items (`reveals`) and reputation gates (`reveal`) that discover regions; a hidden region, Saltmere Isle, past the Harrowlake ferry
- [ ] Quests that reveal regions (see docs/quests.md)

### 8. Combat
- [x] `kick`: the first one opens combat and lands; after that, attacks land only on the beat (within a grace window), judged by Redis's clock
- [x] Timing bar above the "Here" cards: the ball swings out and back, a beat at every centre crossing; the client syncs its clock (ping/pong) and draws ahead by the network delay
- [x] Every attempt uses a beat, so mashing only burns beats; perfect hits do more damage
- [x] The rhythm survives target changes, kills, leaving the room and reconnecting, and ends after 10s without attacking
- [x] NPCs take damage, collapse at 0 HP and respawn
- [x] Rhythms: melee (`k`, 2s), spells (`mm`, 8s) and potions (`hp`, 5s) each keep their own beat and bar
- [x] Three slots, each holding gear (weapon, spell, potion — all alike to the game) with its own beat, window and amounts; 1/2/3 (or clicking a bar) use them
- [x] Gear catalog in the seed; `gear`, `equip <gear> [slot]`, `unequip <slot>`; a starting loadout; slots can't be swapped mid-rhythm
- [x] No roll to hit: a mistimed use is the miss, and it uses up that beat
- [x] In a fight the command box keeps your last command, so Enter repeats it on the beat

### 9. NPCs, reputation and characters
- [x] NPCs fight back: each has one or more slow attacks on their own timers, landed by a server-side combat tick (NPCs never miss, so nothing to verify); their timers show on the target card
- [x] Dispositions: hostile (attacks on sight), neutral (fights back), friendly (can't be attacked; can be healed); anything can be targeted, and `say` and emotes go to the target
- [x] Defeat: wake at the temple shrine with half health, a little experience poorer
- [x] Target card under the slots: portrait, health, disposition, faction standing, NPC attack timers
- [x] Factions with two-axis reputation (affinity and respect) and cultures that judge deeds differently (orcs: honour; spiders: cunning; townsfolk: community; wardens: the wood)
- [x] Experience and levels; stats to train (vigor, poise, focus, presence, and later resilience); a level table granting gear and abilities
- [x] Gear is owned: an inventory of slot items, from starting gear, levels and NPC drops; Inventory and Character panels
- [x] Training yard with an immortal dummy and a sparring post
- [x] Safe places; sleeping bodies out in the open; Woodcraft and Shore-sleeper make terrain safe; idle timeout
- [x] A short cooldown between moves
- [x] Quest design options written up in [docs/quests.md](docs/quests.md)

### 10. Weather and elements ([docs/weather.md](docs/weather.md))
- [x] Design rule: every mechanic is used by other systems, remembered, visible, and a real choice
- [x] Weather as three axes (temperature, energy, precipitation), the same for everyone: one sky per realm, sums of sine waves evened out and stretched so a third of the time is temperate; named corners (Scorch, Tempest, Gale, Rime)
- [x] Indoors is always neutral and dry; fixed climates only for exceptional places; terrain nudges the sky outdoors
- [x] Gear elements: a spot on the grid, wet/dry/any, and a tier (grey to orange); kind defaults; the effect on amounts and timings, with every modifier listed
- [x] Resilience, a fifth stat that softens weather penalties and keeps bonuses
- [x] Snow and mud that build up and hold up travel, with the reason shown first
- [x] Heavy precipitation hides new exits, map glimpses and neighbouring regions; glimpses are remembered
- [x] NPCs that hide or come out with the weather
- [x] Forecasts: weather lore taught by friendly locals (`ask <npc> about weather`), reaching further with better standing; a rough reading without it
- [x] Faction boons (stat bonuses at a standing)
- [x] A pack limit, and no changing gear mid-fight
- [x] Weather panel, always-visible loadout with ▲/▼, gear tooltips with the weather grid; `weather`, admin `setweather`
- [ ] NPCs with elements, so weather cuts both ways in a fight
- [ ] More stats that touch the world (Wayfinding) and hyper-specific gear (narrow precipitation ranges)
- [ ] Stashing or discarding gear to free the pack
- [ ] Decide whether hidden regions should also block travel until known

### 11. Realms ([docs/realms.md](docs/realms.md))
- [x] Realm › Region › Area › Room; `REALM:` channels; realms never share weather or exits
- [x] Realm weather: a centre and spread per axis (the Rimewaste: frozen, howling, snowing; the Stillsands: still, burning, dry)
- [x] Jumps between realms by routes (portal mages, rifts, portals) with operators, fares, weather and "clear of hostiles" conditions
- [x] A one-way realm (the Stillsands) whose exit needs the wind to stir and the wraiths cut down
- [x] Forecasts cover the next hour by default; items can teach a realm's skies
- [x] The map shows your realm; other realms you've visited are buttons in All, shown as you last saw them
- [ ] More route conditions: items carried, reputation, quest steps, players present
- [ ] Realm events on `REALM:` channels (storm fronts, invasions)
- [ ] Abilities that jump (a recall stone, a planeshift spell); gear that only works in one realm
- [ ] Scarce foresight outside the home realm (docs/weather.md, "Foresight is a resource"): a Skyreading sense (about 10 minutes ahead, a direction, any realm); a per-realm cap on forecasts; harder-won lore in harsh realms; move the storm glass somewhere hard or make it a reward

### 12. Places and travel ([docs/places.md](docs/places.md))
- [x] A guide to rooms, areas, regions and realms: what each is for, how big, and how players get around
- [x] Routes for every jump: ferries, coaches, portals and rifts (`travel`), with operators, fares and conditions; routes to hidden regions only once known
- [x] Journeys in stages: each stage a line, Enter to go on, a short wait between; a hook for travel events (`journey_event`)
- [x] Coins: a purse, starting coins, NPCs that drop coins, fares
- [x] The Lake Road coach (Harrowgate ↔ Harrowlake) and the Saltmere ferry (Saltmere is now reached only by ferry)
- [x] TRAVEL lists each route as the exact command to type, named by its destination (TRAVEL VILLAGE GREEN); commands are shown in capitals everywhere and accepted in any case
- [x] A Reputation tab of its own: the factions that know you, grouped by realm (factions have a `realm`)
- [x] Area and region boxes never overlap on the map (a seed check, and padding that stops growing when zoomed out)
- [ ] Travel events: challenges, choices and skill checks during journeys; failures cost health, coins or extra stages
- [ ] Spending coins elsewhere: shops, trainers, inns
- [ ] Grow Harrowgate into a proper town region, and build wilderness between towns to the guide's sizes

### Next
- [ ] Quests: start with small state machines driven by deeds, begun by talking to NPCs (see docs/quests.md)
- [ ] More deeds for cultures to judge: looting, sparing, arena fights, deception, witnesses (see docs/design.md)
- [ ] NPCs that talk back (topics), and choosing between abilities at some levels
- [ ] Character creation: player race/class (cards say "Adventurer" for now)
- [ ] NPCs that move or wander (publish room events like players do)
- [ ] More combat: potions that run out, gear to find or buy beyond drops and levels, balancing gear and NPCs, NPCs that heal or call for help
- [ ] Map: separate floors for up/down (the cellar sits next to the tavern for now), and keyboard navigation of the map
- [ ] Password change and reset (changing a password should revoke the account's other tokens)
- [ ] Resume edge case: if a player's last command moved them and the connection dropped before they saw it, a resume skips the old room's events from that gap (they get a fresh room view instead)
- [ ] Each connection holds one blocking Redis connection for its feed; past a few thousand players per server, switch to one multiplexed reader per server
- [ ] Streams keep the last ~1000 events per channel; a client resuming from further back gets the current state but not the full history
- [ ] Rooms/items for players to build in-game (admin `create room`, `dig <dir>`), instead of only the seed file

### Later
- [ ] NPCs as non-player actors that publish room events
- [ ] Areas or regions divided across servers / Redis Cluster (the global sequence counter and multi-key Lua functions assume one Redis primary; a cluster would need one sequence per shard, e.g. per region)
- [ ] Regional routing (the latency issue noted in the README)
