# Zones: where to go after the start, and why

What lies beyond the starting realms, from the first easy country to the
realms at the level cap. Each zone has a level it's meant for, a theme, a
plan of its regions and areas, its quest givers and quests, its enemies, and
what makes it different from everything before it. The last section says
where each one is on the map, how it connects, and how it's built.

The shape of a character's life:

| Levels | Where | What it asks of you |
|---|---|---|
| 1–3 | a starting realm | learn the game ([characters.md](characters.md)) |
| 3–5 | **the Greyfold**, east of Harrowgate | find your feet: errands, bounties, a first small dungeon |
| 5–9 | **five frontier zones** around Harrowgate | the first things that can kill you in two blows; sneaking past what you can't fight |
| 9–14 | **five dangerous places** at the edges of Alzendor | expeditions: exposure, gear that matters, every step a choice |
| 10–20 | **eleven other realms** | whole worlds with their own weather and rules |

Nothing directs you to a realm. Each one is there for a reason (a drowned
font that opens in the rain, a rift at the top of a mountain in a gale), and
you find it by going where the danger is.

## What's new in these zones

Three mechanics, used again and again:

- **Exposure.** Some areas wear you down a step at a time: the **cold** of
  the high passes, the **foul air** of the deep mines, the **heat** of the
  ash waste, the **spores** of a blighted wood, the **dread** of a cursed
  ruin, and, in one realm, **breath** under the sea. Each area says how many
  steps you can take (`max`) before each further step hurts (`damage`), and
  some weather doubles a step (a blizzard on the Spine). The right worn gear
  keeps it off entirely (a Fur Cloak for cold, a Miner's Mask for foul air,
  Desert Wraps for heat, a Spore Mask, a Pilgrim's Hood, a Diving Helm), and
  Resilience sometimes shrugs a step off. A **shelter** (a fire, an air
  pocket, a shrine) clears it, and so does leaving. A meter under the room
  name shows how much more you can take. Several protections are head gear,
  so you choose what to wear for where you're going.
- **Watchful enemies** (`notice`). Some things are far too strong to fight.
  Walking in, you get a Poise check (CREEP makes it easier) to slip past
  unnoticed; unnoticed, you have a minute before it's checked again. Touch it
  and it fights. The client tags anything that hits for 40% of your health or
  more as **deadly**, and never auto-targets something deadly or watchful
  that isn't already after you.
- **Things that come out at certain times** (`active_when` with `time`):
  the Hollow Rider rides the moor only at dusk and night; the lantern-men of
  the fen only show after dark.

And the tools already there: dark rooms (a torch, or the shield), traps used
as **hazards** that rearm at once (a steam vent, a crevasse: pass quickly or
carefully), weather that changes what's possible, journeys with travel events,
and big telegraphed blows to block or dodge ([combat.md](combat.md)).

## How hard things are

| Tier | Your health | Ordinary enemies | Their leaders | Too strong to fight |
|---|---|---|---|---|
| Greyfold (3–5) | ~110 | 20–45 hp, hit 2–5 | 100–150 hp, hit 7–14 | none |
| Frontier (5–9) | ~130–160 | 60–150 hp, hit 6–14 | 250–400 hp, hit 25–70 (half of you) | 600+ hp, hit 90+ |
| Dangerous (9–14) | ~160–220 | 150–300 hp, hit 15–30 | 600–1200 hp, hit 60–110 | 2000 hp, hit 200 |
| Realms (10–20) | ~170–260 | 200–600 hp, hit 20–50 | 1200–3000 hp, hit 80–160 | |

Big hitters are slow (10–15 s between blows) and most of their blows can be
blocked or dodged: the point is to read them, not to be killed at random.
Some can't be met (`defend: none`) and have to be outlasted or avoided.

**Experience.** Each zone after the Greyfold is worth about a level: its
quests plus one round of its kills come to about 750 experience on the
frontier, 950 in the dangerous places and 1000 in each realm (bosses give
a lot more than their minions, but the quests give most of it). So the
Greyfold ends around level 5, the frontier around 10, the dangerous places
around 14, and the last realms reach 20. Killing things again pays a
little; the quests are what move you on.

Rewards keep pace: each zone's main quest gives slot gear (mostly the Light,
Melee and Potion kinds every class can use) and worn gear, a step up from
the last.

---

## The Greyfold (levels 3–5)

*Farmland, hedges and old woods east of Harrowgate: the country the city
eats from, and lately the country the Redcaps rob.*

The first place out of the tutorial, close to the city, where everything can
be fought and a mistake costs a walk back. Quest givers in Harrowgate send
you out for intel and errands; the people of the Greyfold ask for pelts and
bounties.

**Region: the Greyfold** (east of Harrowgate's new East Gate)

| Area | What's there |
|---|---|
| the East Road | the road out, the Crow Milestone, the Greyfold Crossroads |
| Millbrook (lit) | the green, Fenwick's Mill, the Reeve's House, the Stoat & Barrel inn (safe), Cobb's Tannery |
| the Fallow Fields | the scarecrow field, the drainage ditch, the old orchard (boars) |
| Bramblewood | the wood's edge, the thicket, the wolf den |
| Redcap Hollow | the camp, the lookout, Mags Redcap's tent |
| Barrow Knoll | the knoll, and below it the dark barrow: the passage, the burial hall, the crypt |

**Quest givers:** Marta (the Harrowgate tavern, the first person most new
arrivals meet), Brannoc the smith, Reeve Halden, Goodwife Ama of the inn,
Cobb the tanner, Fenwick the miller.

**Quests**

- **A Newcomer** (started as you leave your starting realm): find the
  tavern in Harrowgate and ask Marta about work.
- **Word from Millbrook** (Marta): the ale from Millbrook has stopped
  coming. Go and ask the reeve why (intel), and bring the answer back: the
  Redcaps have been robbing the road.
- **Bog Iron** (Brannoc): fetch a lump of bog iron from the Fallow Fields'
  drainage ditch. He forges you a Greyfold Billhook.
- **Wolf Pelts** (Cobb): five pelts from Bramblewood's wolves. Then **The
  Wolf Mother**: the old she-wolf in the den, who hits a good deal harder.
  A wolfskin hood.
- **Rooting Boars** (Fenwick): four boars wrecking the orchard. Their charge
  can be dodged, not blocked.
- **The Redcaps** (Reeve Halden): four Redcaps, then Mags Redcap herself, in
  Redcap Hollow. A Redcap knife (it bleeds).
- **Lights on the Knoll** (Goodwife Ama): lights on Barrow Knoll at night.
  Take a torch into the barrow, put down the Barrow-Wight, and bring back the
  grave lantern: a light that steadies you (+1 Resilience).

**Enemies:** bramble wolves (quick, small bites), wild boars (a charge you
can only dodge), Redcap cutthroats and their lookout, Mags Redcap (a heavy
cudgel blow to block), barrow ghouls in the dark, and the Barrow-Wight, whose
grave-chill can only be dodged.

**What makes it the Greyfold:** nothing here is too strong to fight, and it
all teaches what's coming: count quests, bounties, a boss with a blow to
read, a dark dungeon. The quests give about 1000 experience with the kills,
enough for level 5.

---

### Wren's hunting (the Spiderwood, levels 3–5)

Wren, the ranger at the Hunter's Camp on the Spiderwood's edge, buys the
woodsman's white hide, and asks anyone about hunting: **Thinning the Webs**
(three giant spiders in the Web Tunnel and the Hollow Tree; they hide when
it rains) and then **The Broodmother** (the 200-health broodmother in the
Silk Cavern, for a Hunter's Jerkin). She buys spider silk and pelts. Her
Deepwood errand (Into the Deepwood) waits until level 8.

## The frontier (levels 5–9)

Five zones around the Greyfold, each a different kind of country, each built
around one lesson. They're the first places with things that can take half
your health in one blow, and things you shouldn't fight at all.

### Sallow Fen (5–6)

*A drowned fen south of the Greyfold: peat cuts, fog, causeways that sink,
and the troll that owns it.*

- **Areas:** the Causeway, the Peat Cuts, Gnasher's Wallow, the Fen Chapel
  (a shelter).
- **Quest giver:** Sister Odile, the hermit of the Fen Chapel.
- **Quests:** **The Drowned Reliquary** (the chapel's relic lies in the
  troll's wallow: creep in while Old Gnasher dozes, take it, get out);
  **Leech Harvest** (six giant leeches, for Odile's remedies); **The
  Lantern-Men** (wisps that only come out after dark and lead travellers
  into the bog).
- **Enemies:** giant leeches, bog-lurkers, the lantern-men (dusk and night
  only), and **Old Gnasher**, a fen troll who hits for 70 and is watchful.
- **The lesson:** you can't win every fight. Sneak.

### Cindercrag Quarry (6–7)

*An abandoned quarry east of the Greyfold, overrun by the Slagborn: little
soot-coloured raiders who live in the heat of the old kilns.*

- **Areas:** the Quarry Gate (the foreman's camp, a shelter), the Slag Run,
  the Steam Galleries, the Deep Face (and the shaft down to the Underdeep).
- **Quest giver:** Foreman Dunstan.
- **Quests:** **The Lost Survey** (the survey case is in the far gallery,
  past steam vents that scald anyone who stops: a hazard to cross, not
  fight); **Slagborn Raiders** (six of them); **The Quarry Ogre** (Brakka,
  who throws boulders for 65; optional, for the brave).
- **Enemies:** Slagborn raiders and their fire-pot throwers (dodge only),
  steam vents, and Brakka the ogre.
- **The lesson:** some rooms are the enemy. Move through.

### Gallows Moor (7)

*A high, bare moor north-east of the Greyfold, all wind and standing stones,
where the highwaymen work and something rides at night.*

- **Areas:** the Moor Road, the Stone Circle (the Wardens' camp, a
  shelter), the Gibbet, Crowe's Hide.
- **Quest giver:** Warden Ysolde, of the Wardens.
- **Quests:** **Stones That Sing** (stand at the three standing stones
  while the wind is up, and listen: weather intel for the Wardens);
  **The Highwaymen** (five, then Captain Crowe); **The Rider's Lantern**
  (the lantern on the gibbet, taken by day while the Hollow Rider is gone).
- **Enemies:** highwaymen, moor crows, Captain Crowe (a pistol shot for 45:
  dodge it), and **the Hollow Rider**, who only rides at dusk and night and
  hits for 120.
- **The lesson:** the clock. Come back by day.

### The Sunken Abbey (8)

*An abbey on the south coast that the sea took one stormy night. Its lower
halls are flooded and dark, and its monks never left.*

- **Areas:** the Gatehouse (Brother Aldous, a shelter), the Cloister, the
  Flooded Nave (dark), the Undercroft (dark, the Font).
- **Quest giver:** Brother Aldous, the last living monk.
- **Quests:** **Drowned Brothers** (six drowned monks, put to rest);
  **The Abbot's Ledger** (in the Abbot's study, where his shade walks:
  creep); **The Bell of Saint Hesk** (ring the sunken bell, and the Font
  opens: in the rain it's a way to Mirefall).
- **Enemies:** drowned monks, the eels of the nave, and **the Abbot's
  Shade**, whose wail can't be blocked or dodged (80).
- **The lesson:** darkness and a light, and a door to another realm.

### The Deepwood (9)

*North of the Spiderwood, the forest gets old enough to forget the sun.*

- **Areas:** the Thornway (the Thornkin's grove, a shelter), the
  Webwood (dark), the Weaver's Hollow (dark), the Heartwood.
- **Quest givers:** Wren of the Wardens (from her camp in the Spiderwood),
  and the Barkmother of the Thornkin.
- **Quests:** **Into the Deepwood** (Wren: find out what's driving the
  spiders south; intel from the Barkmother); **The Weaver's Brood** (eight
  deep spiders); **The Weaver Queen** (the queen herself: 650 hp, a venom
  bite for 60 that can only be dodged).
- **Enemies:** deep spiders, thornbacks (block only), and the Weaver Queen.
- **The lesson:** a long boss fight that you can lose. The first one.

---

## The dangerous places (levels 9–14)

Five expeditions at the edges of Alzendor. Each has a base camp with a
quest giver who gives you the gear you'll need for its **exposure**, a long
way in, hazards, things you must sneak past, and at its far end a way into
another realm.

### The Cold Spine (10)

*The mountains north-west of Harrowgate, above the Harrow Mountains. Cold
enough to kill, and at the top, in a gale, a rift into the sky.*

- **Exposure: cold** (6 steps, then 14 a step; doubled in freezing weather).
  Protection: the **Fur Cloak**. Shelter: Bergen's Hut, the Ice Cave fire.
- **Areas:** the Trailhead (Bergen's Hut), the Icefall (crevasses: hazards),
  the Long Ridge, the Frostfang Caves (dark), the Summit.
- **Quest givers:** Bergen the mountaineer; Hulda, who hunts what lives up
  here.
- **Quests:** **The Lost Expedition** (three frozen climbers' journals, one
  in each high area: where did they go?); **Fire on the Mountain** (light the
  two signal cairns, so the next expedition can find its way); **The White
  Hunger** (Hulda: the great white beast of the ridge, watchful, 1700 hp,
  hits for 110. For the very brave).
- **Enemies:** ice trolls, frost wyrmlings (breath: dodge only), crevasses,
  and the White Hunger.
- **The way on:** at the Summit, when the wind is high, a rift opens into
  **the Gyre**.

### The Underdeep (11)

*Below Cindercrag's deepest face, the old mine goes down into the dark, and
the dark goes down further.*

- **Exposure: foul air** (5 steps, then 16). Protection: the **Miner's
  Mask**. Shelter: the lamp stations, where the air is pumped.
- **Every room is dark:** you need a light, so no shield.
- **Areas:** the Old Workings (Ketta's lamp station), the Gloom Galleries,
  the Black Lake.
- **Quest giver:** Ketta Lampwright, who keeps the last lamp station lit.
- **Quests:** **Lamps in the Deep** (relight three dead lamp stations with
  her oil); **The Lost Shift** (what happened to the miners: their tally
  board, deep in the galleries); **The Stone Worm** (watchful; 2200 hp; its
  crush can't be met).
- **Enemies:** deep crawlers, the blind ones (they hear you: watchful, but
  weak), and the Stone Worm.
- **The way on:** the Black Lake reflects a sky that isn't there: a way into
  **Hollowmoon**.

### The Emberwaste (12)

*Far east beyond Cindercrag, past the end of the Ash Road: a waste of black
glass and ash where nothing should live.*

- **Getting there:** the Ash Road caravan, a long journey from the quarry
  gate (travel events: ash storms, raiders).
- **Exposure: heat** (6 steps, then 15; doubled when it's hot). Protection:
  **Desert Wraps**. Shelter: the Caravanserai, the Glass Spring.
- **Areas:** the Caravanserai, the Glass Barrens, the Caldera.
- **Quest givers:** Saffa, the caravan-mistress; Ithren, an exile from the
  Ember Courts.
- **Quests:** **Water for the Caravanserai** (fill skins at two springs);
  **Ash Wyrm Bounty** (five); **The Exile's Word** (Ithren: tell the court's
  gatekeeper she sends you; intel that opens the Courts).
- **Enemies:** ash wyrms, cinder salamanders, and the Cinder Colossus
  (watchful, 2500 hp).
- **The way on:** the Caldera's heart is a rift into **the Ember Courts**.

### The Rotwood (13)

*North-east beyond Gallows Moor, a forest is dying of something that
spreads.*

- **Exposure: spores** (5 steps, then 18). Protection: the **Spore Mask**.
  Shelter: the burned clearings, the Warden outpost.
- **Areas:** the Blight Edge (the outpost), the Rotting Groves, the Fungal
  Heart.
- **Quest givers:** Warden-Captain Maelis; Pim the herbalist.
- **Quests:** **Burn the Bloom** (fire three bloom-hearts with Pim's oil);
  **Infected Wardens** (six shamblers who were Wardens); **The Mind in the
  Mould** (the Mycelial Mind: 3000 hp, a slow spore-burst that can't be
  met).
- **Enemies:** spore shamblers, rot elk (a charge to dodge), and the Mind.
- **The way on:** past the Heart, the green goes on into **the Overgrowth**.

### Hollowcrown (14)

*Across Harrowlake, the ruins of Old Harrow, the capital before the flood:
a crown of broken towers, where the dead still keep court.*

- **Getting there:** the pilgrims' barge from Harrowlake's beach, a journey.
- **Exposure: dread** (5 steps, then 20; doubled at night). Protection: the
  **Pilgrim's Hood**. Shelter: the sanctified shrines.
- **Areas:** Pilgrim Landing, the Drowned Streets, the Crown Keep, the
  Throne Hall (sealed).
- **Quest givers:** Mother Aveline of the pilgrims; Corvin, the last herald
  (a ghost).
- **Quests:** **The Herald's Roll** (Corvin: ask three ghosts their names);
  **Lay the Knights to Rest** (six hollow knights); **The Sealed Throne** (the
  endgame: bring the Ember Crown, the Drowned Pearl and the Star Heart from
  three realms, and the throne opens into **the Tempest Throne**).
- **Enemies:** hollow knights (heavy, block their blows), dreadhounds, and
  the Crownless King (watchful, 3500 hp).

---

## The realms (levels 10–20)

Eleven worlds, each a level step up, each self-contained: its own weather
(set by the realm's bias), its own people and factions, quests, and one or
two rules of its own. Each has a way in from somewhere that makes sense and a
way home. From level 15 on, the realms are where the adventures are.

| Level | Realm | Weather | Its own rule | The way in |
|---|---|---|---|---|
| 10 | **Mirefall** | always raining, mild | mud everywhere; wet gear thrives | the Sunken Abbey's Font, in the rain |
| 11 | **the Ember Courts** | scorching, still | heat; a court with a faction to please | the Emberwaste's Caldera |
| 12 | **Hollowmoon** | always night, cold | every outdoor room dark; things that hunt by moonlight | the Underdeep's Black Lake |
| 13 | **the Gyre** | wild wind, always | islands in the sky: skiffs between them, falls | the Cold Spine's Summit in a gale |
| 14 | **the Overgrowth** | hot and wet | titanic beasts to sneak past | the Rotwood's Heart |
| 15 | **Brassmarch** | dead still, dry | clockwork that can only be blocked | the Ember Courts' Clockwork Gate |
| 16 | **the Pale Deep** | cold, wet | breath under the sea | Mirefall's Whirlpool |
| 17 | **the Gloaming** | always dusk | fey bargains and riddles | Hollowmoon's Moon Gate |
| 18 | **the Bone Steppe** | cold, dry, windy | cold; nomad clans | the Gyre's Long Fall |
| 19 | **Starfall** | hot, wild | falling stars: hazards everywhere | the Bone Steppe's Crater |
| 20 | **the Tempest Throne** | every extreme in turn | all of it at once | Hollowcrown's sealed throne |

### Mirefall (10)

*A realm that drowned and kept living: stilt villages on an endless marsh
under a rain that never stops.*

- **Regions and areas:** the Reach (Ploverhold, a stilt town; the Reedways),
  the Sunk Groves (the Toad Court).
- **Quest giver:** Reedmother Ossa of Ploverhold; Fen-captain Dav.
- **Quests:** **Rising Water** (the toads' dams are flooding Ploverhold:
  break three); **The Toad King** (in his court: 2000 hp, a tongue lash to
  dodge, a belly-slam for 80); **Lost Nets** (Dav: four bog-hags' charms).
- **Enemies:** bog-hags, giant toads, the Toad King. **Special:** the rain
  never stops, so the wet-loving gear you ignored is the best you have here,
  and the mud slows every step.
- **The way on:** a whirlpool in the Sunk Groves goes down to the Pale Deep.

### The Ember Courts (11)

*A realm of fire, ruled by salamander nobles in an obsidian palace. They
admire nothing like a duel.*

- **Areas:** the Ash Gate, the Obsidian Palace (the Court), the Magma Gardens.
- **Faction:** the Ember Court (they respect duels and despise cowards).
- **Quest givers:** Vizier Aszh; the Ashen Duchess Kalimar.
- **Quests:** **The Exile's Word** (from the Emberwaste: the gatekeeper lets
  you in); **Duel of Embers** (beat the Duchess's champion); **The Ember
  Crown** (the Ashen Duke has stolen it; 2800 hp; take it back, and keep it:
  one of the three relics).
- **Enemies:** magma hounds, cinder guards, the Ashen Duke. **Special:** heat
  exposure without shelter except in the palace; the Court's opinion of you.
- **The way on:** the Clockwork Gate, to Brassmarch.

### Hollowmoon (12)

*Always night, under a moon that's too big. The lanterns are all that keep
the shadows off.*

- **Areas:** Lanternhold (a town of lamps), the Silverwood, the Moonwell.
- **Quest giver:** Siel, the lantern-keeper.
- **Quests:** **Keep the Lanterns** (relight three); **The Pale Hunt**
  (shadow-stalkers, watchful); **The Eclipse Hound** (3000 hp; its bite in
  the dark).
- **Special:** every room outside Lanternhold is dark: the torch never
  leaves your hand.
- **The way on:** the Moon Gate in the Moonwell, to the Gloaming.

### The Gyre (13)

*Islands that float in a storm that never ends.*

- **Areas:** Kitefast (the skiff docks), the Shearwater Isles, the Roc's
  Crag.
- **Quest giver:** Skymaster Tavi.
- **Quests:** **Kites for the Skiffs** (silk from the storm-hawks);
  **The Thunder Roc** (its nest, its dive for 130).
- **Special:** you get between islands by skiff (journeys, with falls);
  ledges are hazards; the wind narrows every timing window.
- **The way on:** the Long Fall, off the lowest island, to the Bone Steppe.

### The Overgrowth (14)

*A jungle grown to the size of mountains, and the beasts that grew with it.*

- **Areas:** the Canopy Camp, the Green Deep, the Titan's Path.
- **Quest giver:** Annick Vos, an explorer.
- **Quests:** **Charting the Green** (reach three landmarks); **The Mantis
  Queen**.
- **Special:** the Thunderhorns, watchful titans you have to sneak between.

### Brassmarch (15)

*Endless still plains of brass, worked by machines whose makers are gone.*

- **Areas:** the Gearworks, the Brass Plain, the Grand Engine.
- **Quest giver:** Odo, the last engineer; the Arbiter, a machine that
  judges.
- **Quests:** **Wind the Arbiter**; **Scrap Tyrants** (spider-engines); **The
  Grand Automaton**.
- **Special:** machines can only be blocked, not dodged: bring a shield, or
  be fast. The stillness narrows perfect windows.

### The Pale Deep (16)

*A realm under the sea, lit by things that glow.*

- **Exposure: breath** (4 steps, then 22). Protection: the **Diving Helm**.
  Shelter: the air bells.
- **Areas:** the Air Bells (the merrow town), the Kelp Abyss (dark), the
  Leviathan's Trench.
- **Quest giver:** Ysse, the merrow queen.
- **Quests:** **Air for the Bells**; **The Drowned Pearl** (from the angler
  queen: one of the three relics).
- **Special:** the Leviathan, watchful and enormous.

### The Gloaming (17)

*A realm stuck at dusk, ruled by the fey, where every bargain has a catch.*

- **Areas:** the Thorn Market, the Briar Maze, the Erlking's Hall.
- **Quest giver:** the Herald of the Thorn Queen.
- **Quests:** **Three Riddles** (ask the right fey about the right things);
  **The Erlking's Hunt**.
- **Special:** always dusk; fey who are watchful and tricky.

### The Bone Steppe (18)

*A cold, windy grassland strewn with the bones of things the size of hills,
and the clans who ride between them.*

- **Exposure: cold** (6 steps, then 25; doubled in a wild wind). Shelter:
  the yurts.
- **Areas:** the Clan Camp, the Ribcage Hills, the Marrow Pit.
- **Quest giver:** Khagan Temur.
- **Quests:** **Ride with the Clan** (bone-drakes); **The Marrow Titan**.

### Starfall (19)

*Where the stars come down. Hot, wild, and on fire.*

- **Areas:** the Observatory, the Crater Field, the Heart of the Fall.
- **Quest giver:** Ilun, the star-reader.
- **Quests:** **Starshards** (from crystal golems); **The Star Heart** (the
  Fallen Star itself: one of the three relics).
- **Special:** falling stars: hazards in every open room.

### The Tempest Throne (20)

*The eye of every storm: the place the weather comes from.*

- **Areas:** the Eye, the Four Winds, the Throne.
- **Quest giver:** the Weatherwitch, who has waited here a long time.
- **Quests:** **Into the Eye**; **The Storm King** (12000 hp; the last fight).
- **Special:** its weather swings through every extreme; exposure to the
  storm itself.

---

## Where it all is

The home realm, Alzendor, with north up (map units; Harrowgate is near 0, 0):

```
                     the Rotwood (450..650, -455..-305)
  the Cold Spine          the Deepwood        Gallows Moor
  (-340..-165,            (-60..90,           (150..375,
   -385..-110)             -435..-310)         -305..-155)
        \                     |                   |
   Harrow Mountains      the Spiderwood        Redcap Hollow
   (scree slopes)        (15..65, -260..-130)      |
        \                     |                    |
 Harrowlake ...coach... HARROWGATE --East Gate-- the GREYFOLD --- Cindercrag --- Ash Road caravan --- the Emberwaste
 (-690, 0..70)          (-10..100, -20..48)     (150..375,        (450..700)       (journey)            (950..1075, -75..100)
    |  pilgrims' barge                            -110..215)          | shaft down
 Hollowcrown                                         |            the Underdeep (650..850, 190..365)
 (-550..-425, 190..340)                        Sallow Fen --- the Sunken Abbey
                                              (200..400,     (450..575, 340..440)
                                               265..390)
```

| Zone | Level | Where, and why there | How you get there |
|---|---|---|---|
| the Greyfold | 3–5 | east of Harrowgate: the city's farms | Harrowgate's new East Gate (east of the back alley) |
| Sallow Fen | 5–6 | south of the Greyfold, where the land goes to water | Fen Lane, south of Millbrook |
| Cindercrag Quarry | 6–7 | east of the Greyfold, where the hills start | east from the Fallow Fields' orchard |
| Gallows Moor | 7 | north of the Greyfold, high and bare | north from Redcap Hollow, or east from the Spiderwood's hunters' camp |
| the Sunken Abbey | 8 | the south coast, east of the fen | east from the Mire, in Sallow Fen |
| the Deepwood | 9 | north of the Spiderwood: the same forest, older | north from the Spiderwood's silk cavern |
| the Cold Spine | 10 | the high mountains above the Harrow range | north-west from Scree Foot |
| the Underdeep | 11 | under Cindercrag | down the shaft at the quarry's Deep Face |
| the Emberwaste | 12 | far east, past the end of the road | the Ash Road caravan from the quarry gate (a journey) |
| the Rotwood | 13 | north-east past the moor, a forest that's dying | north-east from Crowe's Hide on Gallows Moor |
| Hollowcrown | 14 | across Harrowlake: the old capital the flood took | the pilgrims' barge from Harrowlake's beach (a journey) |

Each realm is reached from the place it belongs to, and has a way home:

| Realm | Level | The way in (and why it's there) | The way home |
|---|---|---|---|
| Mirefall | 10 | the Sunken Abbey's Font, only when it's raining: the abbey drowned into it | the Font, back to the undercroft |
| the Ember Courts | 11 | the rift at the Emberwaste's caldera heart, behind the Cinder Colossus | the same rift |
| Hollowmoon | 12 | the Black Mirror on the Underdeep's lake, which shows its moon | the Mirror Pool |
| the Gyre | 13 | the tear at the Cold Spine's summit, only in a high wind | the tear |
| the Overgrowth | 14 | the ripple at the Rotwood's Fungal Heart: the green the blight came from | the ripple |
| Brassmarch | 15 | the Clockwork Gate in the Ember Courts' palace | the Clockwork Gate |
| the Pale Deep | 16 | Mirefall's whirlpool | the whirlpool |
| the Gloaming | 17 | Hollowmoon's Moon Gate | the arch |
| the Bone Steppe | 18 | the Gyre's Long Fall: everything that falls lands there | the clan shaman's fire, to Harrowgate |
| Starfall | 19 | the Bone Steppe's fresh crater | the star road, to the steppe |
| the Tempest Throne | 20 | Hollowcrown's sealed door, opened with three relics: the Ember Crown, the Drowned Pearl and the Star Heart | the Weatherwitch's door, to Harrowgate |

So the realms form chains, each starting in one of the dangerous places:
the Sunken Abbey → Mirefall → the Pale Deep; the Emberwaste → the Ember
Courts → Brassmarch; the Underdeep → Hollowmoon → the Gloaming; the Cold
Spine → the Gyre → the Bone Steppe → Starfall; the Rotwood → the Overgrowth.
Three of them hold the relics, and Hollowcrown ties them together.

## How it's built

- **Zone files.** Each zone is a file in `world/zones/` (`greyfold.json`,
  `mirefall.json` …) in the same format as `world/seed.json`, merged into it
  when the world loads (`load_seed` in `alzendor/world.py`). A zone file adds
  its own realms, regions, areas, rooms, NPCs, items, gear, worn gear,
  factions, routes, travel events and quests; it can put NPCs and rooms in
  existing places (Teodor at the quarry gate, the East Gate in the Old
  Quarter), but it can't redefine anything. The ways back from existing rooms
  (the back alley's east exit) and changes to existing NPCs (Marta's, Brannoc's
  and Wren's topics) are in `seed.json`.
- **Mechanics in the seed:** an area's `exposure` (`kind`, `name`, `max`,
  `damage`, `worse_when` with weather ranges or `time`, and the `warn`,
  `hurt` and `relief` texts); a room's `shelter`; worn gear's `protects`; an
  NPC's `notice` (easy, fair or hard to slip past); `active_when.time`; a
  realm's `sky` of `always_dusk`; quests that `give` slot gear.
- **Quest steps that wait for an item** check what you carry (`have`), so
  picking a relic up before you have its quest still counts.
- **Where the rules are:** exposure, watchful NPCs and the rest are in
  `alzendor/alzendor.lua` (search for "Exposure" and "noticed"); the client
  shows exposure under the room name and tags deadly NPCs.

## What changed while building it

- The frontier zones each got three or four areas and about ten rooms, the
  dangerous places five areas and a dozen rooms, and each realm two or three
  areas and eight to eleven rooms: enough for their quests and their one
  idea, with room to grow.
- Rain that's heavy enough hides the ways on, so the wet realms (Mirefall,
  the Overgrowth, the Pale Deep) rain steadily but never heavily; otherwise
  you'd arrive in Mirefall unable to see a single exit.
- The Underdeep is drawn on the map as its own region south-east of the
  quarry: the map has no floors yet.
- Quest rewards that are slot gear come with a line saying how to equip them.
- Quests that send you somewhere tell you the way in the goal text, so a new
  player is never lost; the realms are only ever named by the people near
  their doors.
- Not yet: shops, so gear comes only from quests and drops; NPCs that wander
  (the Hollow Rider appears and vanishes, but doesn't ride between rooms);
  balancing, which needs players.
