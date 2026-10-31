# Alzendor

A multiplayer text world (a MUD) where **places are channels**. Being in a room
means being subscribed to that room's channel; whatever happens there is
published to it, and everyone subscribed sees it. Moving means swapping one
room channel for another. See [todo.md](todo.md) for the full concept and
roadmap, and [Documentation](#documentation) for the design notes.

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

Every channel (`PLAYER:kevin`, `ROOM:tavern`, `AREA:docks`, `REGION:harrowgate`,
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
account in each, then a character (a class, an ancestry and a background), and
play through your background's starting realm: it teaches moving, looking,
talking (`ASK <name> ABOUT <topic>`), quests, fighting and the weather, and
ends with a journey into the world proper. Try `help` for every command.

The game writes commands in capitals (`TRAVEL VILLAGE GREEN`, `HELP`) so they
stand out from the text around them; type them in any case. In usages,
lowercase words are what you fill in (`EQUIP <gear> <slot>`).

The web client is built around the map:

- **Layout.** The map and log are on the left, and the room, weather, loadout
  and who's here are on the right. Drag the bar between the two sides, or the
  bar between the map and the log, to resize them. Focus a bar and use the
  arrow keys to nudge it, or double-click it to reset. Sizes are remembered
  per browser. On a phone, the panels stack instead.
- **Map.** Routes are drawn along their waypoints as roads you can't walk
  (amber for a coach, blue for a ferry), traps you know of are marked ⚠, and
  the map darkens outdoors at night. Realms you've only heard of are listed in
  **All**, greyed out.
- **The world.** The world nests in four levels: **realms** (separate worlds, see
  [Realms](#realms)) hold **regions** (a city like Harrowgate, a village like
  Harrowlake, a wild place like Spiderwood), which hold **areas**, which hold
  **rooms**. The map shows the realm you're in. Regions and areas are boxes; rooms are dots
  placed where the seed map puts them. You see the rooms you've explored, plus
  faint outlines of the rooms their exits lead to. The map frames the area
  you're in and glides to each new area as you cross into it. Click any room
  to walk there; each step is a real move, and typing a command, pressing Esc
  or clicking the map stops the walk. Drag to pan and scroll to zoom; **Area**
  and **All** switch between following your area and showing every region you
  know. You can't pan or zoom out past the regions you know. In **All**, the
  other realms you've been to are buttons: each shows that realm's map as you
  knew it on your last visit.
- **Regions you know.** Each region is in one of four states for each player:
  - *Explored*: you've set foot in it. It's drawn with the rooms you've seen.
  - *Discovered*: it borders a region you've explored, or a map or your
    reputation told you about it. It's drawn greyed out, marked
    "unexplored", with nothing inside.
  - *Unknown*: you haven't heard of it. It isn't drawn at all, and neither
    are glimpses of its rooms past an exit.
  - *Hidden*: a region marked hidden in the seed. Bordering it doesn't
    discover it; only a map item or reputation does. Until then it is
    unknown. Hidden regions only hide from the map. If you walk through an
    exit into one, you explore it.

  Picking up a map (for example the sea chart in the Drowned Lantern, which
  reveals Saltmere Isle) makes the regions it shows discovered.
- **Weather.** Four columns, always in the same order: **Sky** (a grid of
  temperature across and energy up, with today's weather as a dot, a blurred
  patch if you can't read these skies, and the forecast as a dotted trail if
  you can), **Rain** (what's falling, and how hard), **Time** (a day/night
  wheel and how long until dusk or daylight) and **Ground** (the footing,
  snow and mud). A line below says it in words. See [Weather](#weather).
- **Combat** ([docs/combat.md](docs/combat.md)), top to bottom: **Here**,
  everyone in the room, compact, with a fighting NPC's coming blows as thin
  bars; your **target**, popping up below them, with a health bar that runs
  out right to left and each NPC attack as a marker sliding to where the blow
  lands; your three **slots**, each marked ▲ or ▼ with what the weather is
  doing to it; and the **defend** row (7). Your own health fills the whole
  panel faintly from the bottom, so you see it fall without looking away.
  Hover a slot (or gear in the Inventory, or a talent, or tap it on a phone)
  for what it is, its rarity and weather sensitivity, where on the weather
  grid it works best, and today's conditions line by line.
- **Inventory**, **Character**, **Reputation** and **Quests** (header
  buttons). Your gear and what it does in today's weather, with buttons to
  put any piece in slot 1, 2 or 3, and how full your pack is; your class,
  ancestry and background, level, experience, stats (with `+` buttons when
  you have points to spend), talents and ancestry passives (with Learn
  buttons, and slot buttons to attune a passive), faction boons and other
  abilities; the factions that know you, grouped by realm (home first), with
  their affinity and respect; and your quests. A badge shows when you have
  points or picks to spend, or quests on the go.
- **Quest.** The goal of your current quest, always visible in the side panel.
- **Journeys.** On a route, your dot moves along it on the map, the room
  panel says where you are, and a travel event appears in the log as a card
  with a button for each choice.
- **Creating a character.** A new account (or one whose character was wiped)
  chooses a class, an ancestry and its first passive, and a background before
  entering the world. See [Characters](#characters).
- **Targeting.** In the command box, **Tab** / **Shift+Tab** cycle through the
  cards and **Esc** clears the selection. Your slots and commands that take
  a target (`poke`, `wave`, `inspect`, …) go to the selected card when you don't type a
  name, even if two NPCs share a name. Clicking a card selects it too.
- **On the ground.** Items (click to look, or **get**) and room features you
  can look at or touch.

### Combat: three slots

You have three **slots**, and each holds one piece of gear: a weapon, a spell,
a potion. The game treats them all alike. In the web client, press **4**,
**3** or **2** for slots 1, 2 and 3 (so a resting finger sits on the first
slot), or click a slot's bar, or type `use 2`, to use one on your target. Each piece of gear
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

(Effects are opening / good / perfect.) These are the base numbers: the
weather changes all of them, and each piece of gear has its own weather
element (see [Weather](#weather)). The Broodmother drops **Stormcall**, an
orange spell that is devastating in a hot, wild downpour and useless anywhere
else. There's also **Mending Light** (a
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
- **4**, **3** and **2** fire straight away when the command line is empty (or
  in a fight, when it holds your last command, selected). Typing a sentence
  with a number in it doesn't use a slot.
- A rhythm belongs to you, not the fight. It carries on across targets, kills,
  leaving the room and reconnecting, and ends only after 10 seconds unused (or
  two beats, if longer). Stepping out and back in doesn't buy a fresh opener,
  and neither does swapping gear: a slot can't be changed while its rhythm is
  running, and no gear can be changed while anything is fighting you. Choose
  your loadout before the fight.
- Redis's clock judges the timing, the one clock every server shares. The
  client syncs to it with ping/pong and draws each ball where it will be when
  your command arrives, so pressing the key when the ball looks centred lands
  on the beat.
- An NPC at 0 HP collapses and comes back after its `respawn` time (five
  minutes by default, and never less; bosses take 15 to 30). Your health is in the header, and behind the combat panel.
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
shown on the target card so you can plan around them, and you can meet
them: **7** (or `DEFEND`) blocks with a shield in hand or dodges without, and
timed to when the blow lands it takes part or all of it. A press is spent on
one blow and needs 1.5 s to recover, and some attacks can only be dodged, or
not met at all. Worn **armour** takes a share off every blow. See
[docs/combat.md](docs/combat.md).

Every NPC is **hostile** (attacks you on sight), **neutral** (fights back if
you attack it) or **friendly** (can't be attacked). Everything can be
targeted: friendly NPCs can be healed with gear that heals allies, and `say`
and emotes go to your target. An NPC fights the first of its foes who is
still in the room; leave and it forgets you.

At 0 HP you collapse and wake at the temple shrine with half your health, a
tenth of a level's experience poorer (never losing a level).

### Weather

Every realm has one sky, the same for everyone everywhere in it, made of three numbers:
**temperature** (cold to scorching), **energy** (dead still to howling
chaos) and **precipitation** (bone dry to a deluge). It drifts over hours. The
neutral middle, a mild breezy day, is **Temperate**; the extreme corners are
**Scorch** (hot and still), **Tempest** (hot and wild), **Gale** (cold and
wild) and **Rime** (cold and still). Indoors (inns, houses, cellars, the
inside of a coach) it's always dead neutral and dry, so ordinary gear works
as intended there. A few exceptional places have a fixed climate of their
own: the Broodmother's lair is always a dead-still heat.

What it does:

- **Gear.** Every piece has a spot on the weather grid where it works best,
  wants wet, dry or doesn't care, and a **weather sensitivity** (one to five
  dots) saying how much it depends on the weather. Its **rarity** (the
  colour of its name: common, uncommon, rare, epic, legendary) is separate,
  though the touchiest pieces are usually rare. Weapons like a mild day,
  spells like energetic air. The Inventory and the slot tooltips show each
  piece's spot and what today does to it.
- **Timing.** Heat slows every beat (up to 30%), wind narrows timing windows,
  and dead stillness narrows perfect windows. A rhythm keeps the timings it
  opened with.
- **Travel.** Rain leaves mud and snow piles up, and both last after the sky
  clears. Moving through them holds you up for a moment (up to 3 s in deep
  snow), and you're told why first.
- **Seeing.** In heavy rain or snow you only see the ways you already know,
  the map shows nothing new, and you don't notice neighbouring regions.
  The exits are still there if you try them.
- **NPCs.** Some come and go with the weather: the giant spider in the web
  tunnel keeps out of the rain, and the bog lurker in the reed marsh only rises when it's wet.
- **Healing.** Bitter cold outdoors slows it.
- **Resilience** (a stat) softens every bad effect by 10% a point, up to
  half, and keeps the good ones.

**Forecasts.** You can always feel the weather where you are, but only
roughly. Locals who know a realm's skies can teach you to read them: in
Alzendor, `ask tamsin about weather` at the lighthouse, or ask Osric the
ferryman or Wren the warden. After that you see the realm's weather exactly,
and `weather` shows what's coming: the next hour at first, and further (up
to 3 hours) the better their people like you. They only teach those they're
friendly with. Some items teach a realm's skies too, like the storm glass in
the Rimewaste.

The full design, including the formulas, is in
[docs/weather.md](docs/weather.md).

### Realms

Realms are separate worlds, like planes. **Alzendor** is the home realm:
every kind of weather, extremes only rarely. The others are where the real
challenge is: harsher, narrower weather, few safe places, more danger. Each
realm sets a centre and spread for each weather axis, so a realm can be
always frozen or always a still, burning desert. Realms never share weather,
and no exit leads between them.

- **The Rimewaste** is frigid and howling, with snow nearly always falling and
  deep on the ground: every step is slow, and you often can't see the way on.
  Reach it through Sister Ilse's ring of frost in the Harrowlake chapel
  (`travel ring`, or `ask ilse about passage`); Veyra at Rime Landing sends
  you back. Ember Hollow is its one
  warm, safe place. Frost wolves and an ice wraith (who drops **Rimefang**, a
  purple blade made for a blizzard) hunt there.
- **The Stillsands** is a one-way trip: the rift at the top of the Rimewaste's
  Howling Pass (`travel rift`) drops you onto burning glass with no way back
  up. The only way home is the portal at the Sun Altar, which opens only when
  the dead-still air stirs, and only when no sand wraiths stand on the altar.
  They come back every 20 seconds.

Defeat anywhere sends you home to the temple shrine, and that's the cost: the
whole journey is lost. Each realm has a `REALM:` channel for realm-wide
events. The design is in [docs/realms.md](docs/realms.md).

### Where to go: the zones

Past the starting realms, Alzendor and its realms are laid out by danger
([docs/zones.md](docs/zones.md) has every zone, its quests and its map):

- **Levels 3–5: the Greyfold**, farmland east of Harrowgate's East Gate.
  Marta in the tavern, Brannoc the smith and the people of Millbrook have
  errands, pelts and bounties: Redcap bandits, wolves, boars, and a barrow
  that needs a torch.
- **Levels 5–9: the frontier**: Sallow Fen (a troll to sneak past), Cindercrag
  Quarry (steam vents to get through), Gallows Moor (a rider who only comes
  out at night), the Sunken Abbey (dark halls), the Deepwood (a spider queen).
  The first things that can take half your health in a blow.
- **Levels 9–14: five dangerous places**, each an expedition with its own
  **exposure** (the meter under the room name): the Cold Spine (cold), the
  Underdeep (foul air, and no light but yours), the Emberwaste (heat, at the
  end of a caravan journey), the Rotwood (spores) and Hollowcrown (dread,
  across the lake by barge). The people at each base camp give you what you
  need to wear: a Fur Cloak, a Miner's Mask, Desert Wraps, a Spore Mask, a
  Pilgrim's Hood. Shelters (fires, lamp stations, shrines) clear it.
- **Levels 10–20: eleven realms**, each through a door in the place it
  belongs to: Mirefall, the Ember Courts, Hollowmoon, the Gyre, the
  Overgrowth, Brassmarch, the Pale Deep, the Gloaming, the Bone Steppe,
  Starfall, and at the end the Tempest Throne, behind a door in Hollowcrown
  that wants three relics from three realms.

Anything that hits for 40% of your health or more is tagged **deadly**.
Some deadly things are **watchful**: walk (or better, CREEP) in, and a Poise
check decides whether they notice you. Unnoticed, leave them be.

### Getting around: walking, traps and night

Every step takes time: 0.6 s through towns, along roads and indoors, 0.9 s
over open country, and 1.5 s on rough ground (mountains, marsh, scree, deep
forest), plus whatever snow and mud add. Click-to-walk paces itself to match.

**Traps** lie in some rooms: walking in springs one unless you pass a stat
check (a snare tests Poise, a rockfall Vigor), and the next room over always
shows a sign for those who look ("a coil of trapper's wire in the leaves").
`CREEP <direction>` steps in slowly and carefully, with a better chance; a
trap you already know about is easier too, and your map marks it ⚠.
**Trapsense** (an ancestry passive) warns you of traps next door.

**Checks** (traps, travel events) test one stat: the chance is the
difficulty's base (easy 50%, fair 30%, hard 10%) plus 12% a point, between
5% and 95%. You're told which stat is tested, not the odds. A background
that suits the check adds 35%.

**Day and night, and the dark.** A game day lasts an hour of real time
(`day_minutes`). Towns keep their lamps lit, but in the wilds at night, and
in dark rooms (caves, shuttered lofts) at any hour, you can't see or walk
past the ways you know without a light in your hand: `WEAR TORCH`. Some
travel events only happen at night. A realm can have a sky of its own:
the Stillsands' sun never sets. `SETCLOCK <hour>` (admin) pins the hour for
testing.

### Travel: routes, journeys and travel events

Walk with exits, or click a known room on the map. For longer trips there
are **routes**: ferries, coaches, portal mages and rifts. `travel` lists the
routes from where you are as the exact commands to type, one per line:

```
Routes from here. Type one of these to go (you have 20 coins):
  TRAVEL VILLAGE GREEN: the High Road coach to Harrowlake. 3 coins, 4 stages.
```

A route is named by where it goes. `TRAVEL VILLAGE GREEN` takes it (so does
`travel to village green`, or one of the route's keywords like `travel
coach`), and each is also a button beside the exits. A place you've never
heard of is listed as "somewhere you know nothing about". A route can need
its operator there and friendly to you, a fare, the right weather, or a room
clear of enemies. Routes to a hidden place are only offered once you know
it's there.

Coaches and ferries are **journeys**: they run through waypoints (the
Switchbacks, the High Pass, Gallows Ridge, the Harrow Ford), one every few
seconds, by themselves. You can't walk to a waypoint or off the route, and
every ride is your own: nobody waits for anyone, and other riders can't see
you (chat still works). Log out on the way and you're still aboard when you
come back. Portals and rifts are instant.

- **The High Road coach** goes from Harrowgate's market square over the
  mountains to Harrowlake's village green and back (Bram, 3 coins). There's
  no road on foot: Harrowlake is far to the west.
- **The Saltmere ferry** is the only way to Saltmere Isle (Osric, 5 coins),
  and it won't sail in a strong wind.

**Travel events** are rare (5% at each waypoint, at most one a journey): a
wheel stuck in the mud, a toll-keeper, a pickpocket, a passenger asking the
innkeeper's name, a riddle from a man adrift in a rowboat, rumours of hidden
places and other realms. Each is a card with two to four choices: a stat
check, a cost, an answer, or an option only your background gets ("Read the
gusts and take the helm" for a sailor). Choose with the buttons or `CHOOSE
<n>`; wait a minute and the last choice is taken for you. Results are small:
time lost or gained, coins, health, reputation, a short buff, a region or
realm you hear of.

Bad weather doesn't make them likelier: it makes them worse. In a storm, a
squall can swamp the ferry (and you can drown: a real death), rocks can come
down on the coach, and the ferry can run aground on a skerry, **marooning**
you on Castaway Isle until you find what's needed to mend it (a priority
quest; the journey waits for you). Very rarely the ride is **ambushed**
(wolves at the ford at dusk, highwaymen at night): fight your attackers
(they're yours alone) and the ride goes on; lose, or `FLEE`, and you're
**stranded** in the wilds below the road, battered, the fare gone, with a
walk back to town.

You start with some **coins** (your background decides how many), and NPCs
you defeat drop more. The guide to places and travel is
[docs/places.md](docs/places.md); the design of journeys is
[docs/journeys.md](docs/journeys.md).

### Quests

People have things to say: a character's card lists their topics, and `ASK
<name> ABOUT <topic>` asks. Some start quests. `QUESTS` (or the Quests
panel) lists yours with what each needs next, and the side panel shows the
current goal. Quests move on when you do what they ask: talk to someone,
pick something up, go somewhere, defeat something, use an item on something
(`USE <item> ON <thing>`), or be somewhere in the right weather. Quest items
are your own: two players on the same quest each find their own. A
**priority** quest (being marooned) holds you: leaving its place any other
way than finishing it (dying, a teleport) fails it, but logging out doesn't.

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

### Characters

A new character chooses three things, once ([docs/characters.md](docs/characters.md)):

- **Class**: how you fight. It gives your first slot ability and decides
  which kinds of gear you can use. **Fighter** (Cleave; weapon, light, melee,
  potion), **Mage** (Magic Missile; spell, light, melee, potion) or **Rogue**
  (Flick Knife; light, trick, melee, potion).
- **Ancestry**: what you are. +1 to a stat and a passive from its pool of
  seven. **Human** (+1 Presence: Second Wind, Last Stand, Quick Study,
  Haggler, Shore-sleeper, Trapsense, Steady Hands), **Elf** (+1 Focus: Long
  Breath, Woodcraft, Starsight, Feather Step, Skyreading, Trapsense, Moonlit
  Edge) or **Orc** (+1 Vigor: Bloodrhythm, Berserk Seal, Thick Hide, Iron
  Gut, Hunter's Nose, Trapsense, Skyreading).
- **Background**: how you've lived. Two starting items (the two of its four
  that your class can use), coins, small starting opinions with factions,
  better options in travel events, and where your story starts: **Sailor**
  (Gullhaven), **Merchant** (Copperstall), **Woodsman** (Thornwick) or
  **Street Urchin** (Low Wick).

Your class ability and background items fill your three slots. Choices are
sidegrades, not ranks: none is meant to be best.

**Worn gear.** Besides the slots you wear things: head, chest, legs and a
hand. Armour takes a share off every blow, some pieces add a stat, and the
hand holds a torch (see in the dark), a shield (block instead of dodge) or
an orb. Classes wear some types only (mages no mail). You start in your
class's and background's clothes; quests give more. `WEAR <item>`,
`REMOVE <item or place>`, or the Character panel.

**Starting realms.** Each background begins in a small realm of its own: a
shipyard town, a market town, a hamlet in an old wood, a town that's got too
small for you. Its quests teach the game one thing at a time: a first small
quest; a local's lesson on the weather panel, weather sensitivity and rarity,
with a torch and a first fight (level 2, a stat point); then a dark room, the
longer quests and level 3 with your first talent; and a journey out into
Alzendor. You can't go back. Die there and you wake where
you began.

**Levelling** (to a cap of 20; each level needs 100 × your level in
experience):

- every level: a **stat point** (`TRAIN <stat>`, or the `+` buttons);
- levels 3, 6, 9, 12, 15 and 18: a **talent**, a slot ability from your
  class's pool (`LEARN <talent>`, or the Character panel, where hovering a
  talent shows everything about it first). Your first two are rank 1; rank 2
  opens after two talents, rank 3 after four. Talents have weather
  elements, so a broad set lets you swap slots as the weather turns. Some
  stagger (push the target's next blow back), guard (soak up the next blows)
  or bleed and burn (hurt on each of the target's next beats, never quite
  killing it);
- levels 5, 10, 15 and 20: another **ancestry passive** (`LEARN <passive>`).

Levelling gives no gear: that comes from the world. Some passives play with
the slot ball: Second Wind heals you each time the attuned slot's ball
touches the left edge, Bloodrhythm makes misses charge the next hit, and
Berserk Seal makes a slot 50% stronger until its ball first touches the left
edge, then seals it for the rest of the fight. `ATTUNE <passive> <slot>`
chooses the slot (not mid-fight). **Sergeant Holt**, in the Harrowgate
training yard, resets your talents and passives for 10 coins a level
(`RESPEC`).

The stats are deliberately plain: everyone wants them, and you choose where
your points go. Gear and abilities are what make characters different.

| Stat | Each point |
|---|---|
| Vigor | 8 more max health |
| Poise | timing windows 15 ms wider (never reaching halfway to the next beat) |
| Focus | perfect windows 10 ms wider (never wider than the window) |
| Presence | your deeds move reputation 15% further, good or bad |
| Resilience | weather penalties 10% softer (up to 50%); bonuses kept |

Your ancestry's +1 counts like a trained point. Factions can grant **boons**: a stat bonus while your standing with them is
high enough. The Wardens give +1 Resilience at affinity 20, and the
Spiderwood Brood +1 Poise at respect 30. The Reputation panel shows which are
active and what the others need.

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
Out of a fight, wounds heal slowly (faster somewhere safe, slower in bitter
cold). Moving has a short cooldown (250 ms), so a client can't send a whole
journey at once.

Your **pack** holds 12 things: what you carry, plus gear that isn't in a
slot. With a full pack you can't pick anything up (gear from a level or a
kill still arrives).
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
| `ALZ_ADMINS` | | Comma-separated account names allowed the admin commands: `announce <area/region/realm>`, and `setweather` to pin your realm's weather for testing |
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

[world/seed.json](world/seed.json) defines realms, regions, areas, rooms, items, NPCs,
gear, default chat channels, and ambient events like bells and weather, and
each file in [world/zones/](world/zones/) adds a zone in the same format
(merged in when the world loads; a zone can add to existing places but never
redefine anything; see [docs/zones.md](docs/zones.md)). Every server loads
them at start. Map data is rewritten each time. Live state (where
items are, who is where, NPC health) is never overwritten.

- **Rooms** have a `pos` of `[x, y]` on an abstract plane (x grows east, y
  grows south). Distances are only for drawing, not travel: put rooms wherever
  the map reads best. Exits can go `north`, `south`, `east`, `west`,
  `northeast`, `northwest`, `southeast`, `southwest`, `up` and `down` (drawn
  dashed). Rooms also have `features` you can look at, and `flavor` text for
  verbs on them (`"touch:ground": "crouches and presses a palm to…"`).
- **Realms** have a `name`, a `description`, and optionally `weather`:
  `[centre, spread]` for each axis (e.g. `"temperature": [-0.85, 0.15]`),
  default `[0, 1]`; a `sky` (`always_day`, `always_dusk` or `always_night`); and a `shrine`
  (where you wake if you die there; default the `shrine_room` rule).
  Exactly one is `"home": true`; `"starting": true` marks a background's
  starting realm. Rooms in different realms can't be joined by exits.
- **Regions** belong to a `realm`: Harrowgate is a city, Harrowlake a
  village, Spiderwood a forest, Saltmere a hidden isle. Each has a `name`,
  and optionally:
  - `"hidden": true`, so bordering it doesn't discover it.
  - `borders`: a list of other regions it borders. Regions joined by an exit
    border each other anyway, so this is only for neighbours with no road
    between them.
  - `reveal`: a reputation gate, e.g. `{"faction": "harrowfolk",
    "affinity": 10, "text": "…"}`. Players whose affinity and/or respect with
    that faction reach the thresholds discover the region, and are told
    `text`.

  Crossing between regions swaps the player's `REGION:` channel, so each
  region has its own weather and announcements.
- **Areas** belong to a `region`. Areas and regions get their boxes from the
  rooms inside them. Leave clear space between regions and between areas so
  their boxes don't touch on the map. Areas are coloured in id order, or set
  `"color": 1`–`6`.
- **Waypoints** are rooms with `"waypoint": true` and no exits: the stops on
  a route's `path`, drawn as part of the route and only reached by riding it.
  Their `description` is the line you see as you pass.
- **Traps**: a room's `trap` has a `name`, the `stat` that avoids it, a
  `difficulty` (`easy`, `fair`, `hard`), `damage`, optionally `slows`
  (seconds of slower steps) and `rearm` (seconds), texts `hit`, `avoid` and
  `sprung` (with `{actor}`), and a `sign`: `{room, name, text}`, a feature in
  a room next door.
- **`terrain_ground`** maps terrains to `open` or `rough` for walking pace
  (rooms without a terrain, and indoor rooms, are road).
- **Items** can be `"quest": true` (each player gets their own; with no
  `room`, only a quest hands it out). They can have `reveals`: a list of regions that become discovered for
  whoever picks the item up (a map), and `forecasts`: realms whose skies
  they can then read (a storm glass).
- **NPCs** have a `name`, `label` (race/class), short `description`, longer
  `details` for `inspect`, `keywords` to refer to them by, a `room` and
  `max_hp`, and optionally `respawn` (seconds, default and minimum 300). Set
  `"proper": true` for named characters ("Brannoc" rather than "the
  Brannoc"). For combat and reputation: `disposition` (`hostile`, `neutral`
  or `friendly`), `faction`, `role` (e.g. `warrior`, `young`; cultures can
  judge by it), an `icon` (an emoji for the target card), `attacks` (each
  with a `name`, `period` in ms, `damage`, `hit` text using `{actor}` and
  `{target}`, and optionally `defend`: `both` (default), `block`, `dodge` or
  `none`), `notice` (`easy`, `fair` or `hard`: a watchful NPC that only
  attacks if it notices you), `xp` (default half its max HP), `drops` (gear ids given to
  whoever kills it), `coins` they drop, and `"immortal": true` for practice
  targets. `topics` maps what they'll talk about to a line, or to `{text,
  starts, explains}`: `starts` a quest, and `explains` is guide text shown
  after the line (what it means in game terms). `"trainer": true` lets players `RESPEC` there.
  A `"template": true` NPC has no room: ambushes copy it.
- **Darkness.** A room with `"dark": true` is pitch dark at any hour without
  a light; an area (or room) with `"lit": true` is never dark at night.
- **Exposure.** An area's `exposure`: `kind` (cold, air, heat, spores,
  dread, breath, storm…), a `name` to show, `max` steps before it hurts,
  `damage` a step after that, optionally `worse_when` (weather ranges, or
  `time` phases) when a step counts double, and `warn`, `hurt` and `relief`
  texts. A room with `"shelter": true` (or `"safe": true`) clears it; worn
  gear that `protects` the kind keeps it off.
- **`wearables`** (worn gear): a `name`, `keywords`, `place` (`head`,
  `chest`, `legs`, `hand`), `type` (`cloth`, `leather`, `mail`, or for the
  hand `shield`, `light`, `orb`), optionally `armor`, `stats` (`{stat: n}`),
  `"light": true` (lights only), `block` (shields: the share of a block it
  gives), `protects` (exposure kinds it keeps off) and `rarity`, and a
  `description`.
- **Rooms** can be `"safe": true` (inns, shrines, camps) and have a `terrain`
  (`forest`, `coast`, …) that perks can make safe and that nudges the weather
  (`terrain_weather`, e.g. forests are sheltered).
- **Indoors and climates.** A livable room is `"indoor": true`: its weather
  is always neutral and dry. An exceptional room or area can have a fixed
  `climate: {temperature, energy, precipitation}` (each -1 to 1) instead.
- **`routes`** are every jump between rooms (ferries, coaches, portals,
  rifts; see [docs/places.md](docs/places.md)): a `name`, a `kind` (`coach`,
  `ferry`, `portal`, `rift`), `keywords` (other words `travel` matches,
  besides the `to` room's name, which is what players are shown to type),
  `from` and `to` rooms, and optionally `by` (an operator NPC who must be in
  the `from` room and friendly), `fare` (coins), `when` (weather ranges like
  `active_when`), `clear` (no NPC hostile to you there), a `path` of
  waypoint rooms (a journey; without one it's instant), `strand` (where the
  stranded wake), `risk` (added to the chance of an event), `events` (only
  these travel events), `"hidden": true` (only a quest can start it),
  `quest` and `step` (offered only to a player at that quest step),
  `leaves_start` (taking it removes the starting realm from the map), and
  texts `closed`, `depart`, `leave` and `arrive` (with `{actor}`). Two
  routes from one room can't share a destination.
- **`travel_events`** ([docs/journeys.md](docs/journeys.md)): `text`,
  `pools` (route ids, route kinds, realms, or `any`), `weight`, `once`,
  `when` (weather ranges, `severity` [low, high] and `time` phases), and two
  to four `choices`. A choice has a `label`, optionally a `check` (`{stat,
  difficulty}`), `cost` (coins), `background` (only they see it) or `bonus`
  (they get +35%), and `success` and `failure` outcomes: lists of effects
  (`text`, `delay`, `hasten`, `coins`, `xp`, `hp`, `reputation`, `discover`,
  `rumour`, `boon`, `death`, `strand`, `ambush` (template NPCs), `maroon`
  (`{room, quest}`)).
- **`quests`** ([docs/quests.md](docs/quests.md)): a `name`, `start` step,
  optionally `"priority": true` with its `area`, a `giver` and `offer` (what
  they say when another quest leads here), and `steps`, each with a
  `goal`, `on` (one of `ask` + `about`, `get`, `enter`, `kill`, `use` + `on`,
  `have`, `level`, `in`, `travel` (a route); any with `when`), `effects`
  (travel event effects, plus `give` (an item, slot gear or worn gear),
  `take`, `start`, `say` + `by`, `guide`, `teleport`, `resume_journey`,
  `leave_start`)
  and `then`.
- **`classes`**, **`ancestries`** and **`backgrounds`**
  ([docs/characters.md](docs/characters.md)): a class has a `name`,
  `description`, `ability` (gear), the gear `kinds` it can use and its
  `talents` (gear with a `rank` of 1 to 3, and maybe `requires`), the worn
  gear types it `wears` and its starting `outfit`; an ancestry
  a `stat` and its `passives` (perks); a background its four `items`, an
  `outfit`,
  `coins`, `opinions` (`{faction, affinity, respect}`), `start` (a room in
  its starting realm), `arrive` (where its journey out lands), `intro` and
  first `quest`.
- **NPC weather.** `forecasts` lists the realms whose skies an NPC can teach
  a player (`ask <npc> about weather`). `active_when` gives ranges, e.g.
  `{"precipitation": [-1, 0.2]}`, and optionally `time` phases (`{"time":
  ["dusk", "night"]}`): outside them the NPC hides (never mid-fight), with
  optional `hide` and `emerge` texts using `{actor}`.
- **Factions** have a `name`, `realm` (where they live, for grouping on the
  Reputation tab; the home realm if left out), `description` and `rules`: each rule has a
  `deed`, optionally `of` (the faction of the NPC involved) and `role`, the
  `affinity` and `respect` it adds, and a `note` explaining why. `boons` give
  a stat bonus (`stat`, `amount`, `note`) at an `affinity` and/or `respect`
  threshold.
- **Perks** (passives) have a `name`, `description`, optionally a
  `safe_terrain`, and `"slot": true` for passives attuned to a slot.
  **`starting_gear`** and `loadout` are only for characters made without
  creation (tests).
- **`rules`** holds tunable numbers: `pace` (scales walking; 0 turns it off),
  `step_road_ms`, `step_open_ms`, `step_rough_ms`, `day_minutes`,
  `sleep_seconds`, `shrine_room`, `regen` and `safe_regen` (health per
  upkeep, every 5 s), `social_cooldown` (seconds), `pack_size`,
  `starting_coins`, `stage_seconds` (between waypoints), `event_chance` and
  `event_seconds` (travel events), `level_cap`, `respec_coins_per_level`,
  `armor_k` (armour's curve), `defend_cooldown_ms`, `defend_late_ms`,
  `dodge_window_ms`, `block_window_ms` and `defend_perfect_ms`, and for the weather
  `weather_seed` (which draws every realm's sky; change it for different
  weather) and `weather_unit_minutes` (how fast it moves; default 30).
- **Gear** has a `name`, `kind` (shown in `gear`; classes use some kinds),
  `keywords`, an `effect` (`damage` a target, `heal` yourself, or `guard`:
  soak up the next blows), optionally `stagger_ms` (pushes the target's next
  blow back) and `bleed` (`{damage, beats}`), a `period` (ms between beats), a
  `window` and `perfect_window` (ms either side of a beat), `amounts` (opening
  / good / perfect), and texts: `hit`, `perfect_hit` and `miss` for the room
  (with `{actor}` and `{target}`), and `whiff` for you when you mistime it.
  A `description` says what it is, and `weather` is its element:
  `{temperature, energy}` (its spot on the grid), `precipitation` (`wet`,
  `dry` or `any`) and `tier` (`grey`, `green`, `blue`, `purple`, `orange`:
  weather sensitivity 1 to 5). `rarity` (`common` … `legendary`) defaults to
  the tier's. Gear without a profile uses its kind's default from **`kinds`**.
  `loadout` lists the gear new characters start with, one per slot.

## Protocol

One JSON object per WebSocket message, at `/ws`. The full reference is in
[alzendor/session.py](alzendor/session.py). In short: the client sends
`register`, `login` or `resume`, then `{"type": "cmd", "text": "...",
"target": "npc:orc-1"}` messages (`target` is optional). A player without a
character is first sent `create` (with the `options`: classes, ancestries
with their passives, backgrounds with their items per class) and answers
`{"type": "create", "class", "ancestry", "passive", "background"}` until it
stops getting `create_error`. The server sends `auth_ok`/`auth_error`, then a stream of `{"type": "event", "event": {...}}`
messages, each with a `seq`. Clients can also send `{"type": "ping", "t": …}`
and get back a `pong` with `server_ms`, Redis's clock, for drawing combat
timing. Most events have a `text` to show. A few are pure
state updates, without one:

- `room`: the full room, with `entities` (cards, NPCs with their `topics`),
  `items` (quest items marked `quest`) and `features`, `indoor`, `step_ms`
  (how long crossing it takes), `routes` (the routes leaving it: `id`, `name`,
  `fare`, `to`, `command`), `exits_hidden` when rain, snow or the dark hides
  some exits, `dark` when it's too dark to see the ways on without a light, `scents` (Hunter's Nose), and `waypoint` and `pos` while riding
- `map`: explored rooms (each with its `realm`), glimpsed rooms and areas
  (`full` replaces what the client knows; otherwise merge them in);
  `regions`: every region the player knows in every realm, with `state`
  (`explored` or `discovered`), `bounds` and `realm` (always the whole list;
  replace it); `realms`: the realms they've been to; `realm`: the one
  they're in (realms only heard of have `rumour`); and `routes` (`from`,
  `to`, `name`, `kind`, `fare`, `command`, and `path`: the waypoints'
  positions) leaving rooms they've explored. Rooms with a known trap have `trap`
- `entity`: a changed card
- `timing`: one of your slots (`slot`, `label`, and if it holds something
  `gear`, `kind` and `period_ms`; `active`, and while active `start_ms`,
  `grace_ms`, `perfect_ms`, `last_beat`, `last_ms`, `timeout_ms`). Every slot
  is sent on connect, and again when its gear changes.
- `gear` (has text): all the gear there is, and the ids in your `slots`
- `combat` / `heal` (have text): a use's `slot`, `result` (`opener`,
  `perfect`, `good`, `early`, `late`, `miss`), and `damage` or `amount`. An
  NPC's attack is a `combat` event with its `entity_id`, the `target` it hit
  and `damage`, and `defended` (`block` or `dodge`) and `perfect` if it was met
- `defend`: a DEFEND press: `ready` (false if it's still recovering), `mode`,
  `cooldown_ms` and `window_ms`
- `npc_timing`: an NPC starting, continuing or stopping a fight (`entity_id`,
  `active`, `target`, and `attacks` with `name`, `period_ms`, `damage`,
  `defend` and `next_ms`, by Redis's clock). Room cards carry the same as `fight`
- `dispositions`: how each NPC in your room treats you, by entity id. Room
  cards carry `disposition` (for you) and `base_disposition` (its nature)
- `kit`: the gear you own, your `slots`, the `items` you carry, `coins`, and
  `pack` / `pack_size`. Each piece of gear has its base numbers, `description`,
  `rarity`, `sensitivity` (1-5), `stagger_ms` and `bleed` if it has them,
  `weather` (its profile) and `now`: its `factor`, `amounts` and timings in
  today's weather, and `mods`, one `{label, pct, on}` per modifier. Sent
  again whenever the weather changes it
- `character`: your `level`, `level_cap`, `xp`, `xp_next`, `points`, `stats`
  (with ancestry, buffs and boons), `trained`, `stat_order`, `stat_info`,
  `boons`, `perks` (each with `slot` and `attuned`), `factions` (the ones
  that know you, home realm first: `realm`, `realm_name`, `description`,
  affinity and respect), `hp`, `max_hp`, and for a created character
  `class`, `ancestry`, `background`, `talent_picks`, `passive_picks`,
  `talents` (each a full gear summary, as in `kit`, plus `rank`, `learned`
  and `locked`), `passives` (`id`, `name`, `slot`, `learned`), `worn` (place
  to worn gear), `wardrobe` (all of it, with `worn` and `usable`), `places`,
  `armor` and `armor_pct`; and `defence` (`mode`, `window_ms`,
  `cooldown_ms`)
- `weather`: where you are (`place`, `indoor`), `temperature`, `energy`,
  `precipitation` (exact, or to the nearest half if `exact` is false),
  `zone`, `falling`, `intensity`, `summary`, `visibility`, `ground` (`snow`,
  `mud`), `footing` (`road`, `open`, `rough`), `realm` (its name), `clock`
  (`hour`, `phase`, `day` from 0 to 1, `day_ms` while it runs, `sky` for a
  realm's own), with lore a
  `forecast` (a point every 7.5 minutes), and with Skyreading a `heading`. Sent on connecting, on changing realm, region or indoors, and
  every 30 s
- `travel` (has text): a move held up by snow or mud (`delay_ms`, `cause`).
  The `leave` and `room` follow when it's done
- `weather_report` (has text) answers `weather`; `weather_change` (has text)
  tells a realm its weather has turned
- `routes` (has text) answers `travel` with the routes from here (`id`,
  `name`, `to`, `command` (what to type), `fare`, `stages`, and `refusal` if
  it won't take you now). Routes in a `room` event carry `to` and `command`
  too
- `journey` (has text): reaching a waypoint (`route`, `kind`, `stage`,
  `stages`, `at`, `pos`, `name`), or `done` at the end
- `travel_event` (has text): a choice on the road (`id`, `choices`: `n`,
  `label`, `check`, `cost`, `background`, `tags`; `until_ms`), or `done`
  once chosen. Send `choose <n>`
- `quests`: your quests (`id`, `name`, `status`, `priority`, `goal`,
  `count`, `need`), active first
- `intro` (has text): a new character's story so far
- `guide` (has text): what someone just said means in game terms (the
  weather panel, sensitivity, travel), shown set apart from speech
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
  server.py      WebSocket server, web client, heartbeats, upkeep, weather tick, ambient events
  auth.py        accounts, passwords, tokens, rate limits
  world.py       loading the rules and the map, and checking the map
  weather.py     each realm's weather waves, and a reference copy of the weather function
  cli.py         terminal client
  web/index.html web client
world/seed.json  the realms and map, gear, NPCs, factions, perks and levels
docs/            design notes (see Documentation)
tests/
```

## Documentation

- [README.md](README.md) (this file): what the game is, how to run and deploy
  it, how to play, the seed format and the protocol.
- [todo.md](todo.md): the concept, and the roadmap with what's done.
- [docs/design.md](docs/design.md): the thinking behind stats, abilities,
  reputation, NPC timing and leaving the world, with options not taken.
- [docs/weather.md](docs/weather.md): the weather and elements design: the
  rule that every mechanic is used, remembered and leveraged; the three axes;
  the weather function; what weather does; forecasts; and decisions still
  open.
- [docs/weather-plan.md](docs/weather-plan.md): how the weather was built, in
  stages.
- [docs/places.md](docs/places.md): the guide to rooms, areas, regions and
  realms (what each is for and how big), and to getting around: walking,
  routes and journeys in stages.
- [docs/realms.md](docs/realms.md): realms (separate worlds): their weather,
  travel between them by routes, one-way realms, death and the map, with its
  build plan.
- [docs/quests.md](docs/quests.md): options for quests, and the quest engine
  that was built.
- [docs/combat.md](docs/combat.md): blocking and dodging, armour, and the
  combat panel.
- [docs/zones.md](docs/zones.md): every zone after the starting realms (the
  Greyfold, the frontier, the dangerous places and the eleven realms): their
  plans, quests, enemies and mechanics, where they are and why.
- [docs/journeys.md](docs/journeys.md): walking pace, traps, day and night,
  routes as waypoints, and travel events: checks, stranding, surprise combat
  and marooning.
- [docs/characters.md](docs/characters.md): class, ancestry and background;
  talents, ancestry passives (including ones that play with the slot ball),
  levelling to 20, respec, and the four starting realms.
