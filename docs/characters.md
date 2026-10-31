# Characters: class, ancestry, background, talents and starting realms

Who you are when you arrive, and how you grow. It's all built; the build order
and what changed on the way are at the end. It builds on the combat slots (README, "Combat:
three slots"), the weather elements ([weather.md](weather.md)), reputation
([design.md](design.md)) and journeys ([journeys.md](journeys.md)). The quest
engine the starting realms need is in [quests.md](quests.md).

## The three choices

A new character picks one of each. They're fixed for life.

| Choice | Gives you | In one line |
|---|---|---|
| **Class** | one slot ability, the gear you can use, and a talent pool | how you fight |
| **Ancestry** | +1 to a stat, and a passive from your ancestry's pool | what you are |
| **Background** | two starting items, some coins, starting opinions, a starting realm, and options in travel and social events | how you've lived |

Together they fill your three slots exactly: the class ability, and the
background's two items. That replaces today's Kick, Magic Missile and
Health Potion.

**Flat, not ranked.** Choices are sidegrades. No class, ancestry, background
or passive should be clearly the best; each should be good somewhere.

## Classes

A class gives a starting ability, decides which kinds of gear you can put in a
slot, and owns a talent pool.

| Class | Starting ability | Can use |
|---|---|---|
| **Fighter** | Cleave (weapon, 2.5 s, solid hits) | Weapon, Light, Melee, Potion |
| **Mage** | Magic Missile (spell, 8 s, big hits) | Spell, Light, Melee, Potion |
| **Rogue** | Flick Knife (light, 1.2 s, quick small hits) | Light, Trick, Melee, Potion |

- **Gear kinds:** today's `Weapon` splits into `Weapon` (swords, axes) and
  `Light` (daggers, knives), and a new `Trick` kind holds a rogue's
  caltrops, smoke and poisons. Melee and Potion are for everyone.
- Gear you can't use can still be carried, sold or given away, but `EQUIP`
  refuses it ("A Fighter can't use spells"). Loot drops as now.

### Talents

Talents are slot abilities: gear you learn instead of find. You choose one at
**every third level** (3, 6, 9, 12, 15 and 18: six in all).

- **Ranks:** your first two picks are rank 1. From your third (level 9),
  rank 2 is open too; from your fifth (level 15), rank 3. Rank 2 is a little
  stronger than rank 1, rank 3 clearly stronger, but rank 1 talents stay
  useful forever.
- **Look before you choose.** Hovering a talent in the Character panel shows
  everything about it before you learn it: what it does, its beat and
  windows, its rarity, its weather sensitivity and spot, and what today's
  weather would do to it.
- **A grab bag, not a tree.** Almost nothing requires anything else. A link
  exists only where it's needed to make sense (Chain Lightning needs Spark).
- **Ten tools for three slots.** The point is flexibility: every talent has
  a weather element ([weather.md](weather.md)), and a class's pool is spread
  across the weather grid, so as the weather turns you swap slots to suit it
  (before a fight; never during).
- **New effects.** Today gear deals damage or heals. Talents add a few
  effects: **stagger** (pushes the target's next blow back), **guard**
  (absorbs the next few points of damage), and **bleed/burn** (a little
  damage on each of the target's next beats).

A first pool per class (6 / 4 / 3), with each talent's beat and weather spot
to be tuned when built:

| Class | Rank 1 | Rank 2 | Rank 3 |
|---|---|---|---|
| Fighter | Shield Bash (stagger), Guard Up (guard), Hamstring (bleed), Second Breath (small fast self-heal), Heavy Swing, Brace (guard, strong in wind) | Whirlwind, Iron Wall, Rending Blow, Rallying Shout (heal self or ally) | Earthbreaker, Unbroken, Executioner |
| Mage | Spark (wild weather), Frost Shard (cold), Firebolt (heat), Gust (stagger), Mist Veil (guard, wet), Mending Light (heal) | Chain Lightning (needs Spark), Ice Lance, Cinder Rain (burn), Renewal | Tempest, Absolute Zero, Sunlance |
| Rogue | Caltrops (stagger), Poisoned Edge (bleed), Low Blow, Smoke Pellet (guard), Feint, Twin Jab | Garrote, Shadowstep, Venom Cloud, Gutter Trick | Assassinate, A Thousand Cuts, Vanishing Act |

## Ancestries

An ancestry gives **+1 to a stat** and a **pool of seven passives**. You pick
one passive when you create the character, and another at levels **5, 10, 15
and 20**: five of the seven by the cap. Every passive in your pool is
available from the start, and none of them scale with level: a passive taken
at level 20 is the same as at level 1. Some look strongest early, others
shine later (in harsh realms, against strong enemies, when you travel a lot).
Some passives (Trapsense, Skyreading) appear in more than one pool.

### Passives that play with the slot ball

Each slot's ball swings out to the right, back through the centre, out to the
left and back. Passives can hook into that motion, which makes the bar more
than a timer and gives fast gear and slow gear different strengths:

- **Edge triggers:** something happens each time a ball touches the left or
  right edge (fast gear touches the edges more often).
- **Beat triggers:** on a perfect hit, on a miss, on every beat.
- **Seals:** a big bonus with a catch, like "+50% to this slot, but when its
  ball first touches the left edge, the slot is sealed until the fight ends".
  Great for a short fight; bad for a long one.

A slot passive is **attuned to one slot**, which you choose (`ATTUNE <passive>
<slot>`, or in the Loadout panel), and like gear it can't change mid-fight.
The bar shows it, quietly: a soft glow on the edge that triggers it, small
pips for stacks, and a sealed slot greyed with a lock.

### A first pool per ancestry

| Ancestry | Stat | Passives |
|---|---|---|
| **Human** | +1 Presence | **Second Wind** (each time the attuned ball touches the left edge, heal 1); **Last Stand** (below a quarter of your health, all slots +20%); **Quick Study** (+10% experience); **Haggler** (fares and prices −15%); **Shore-sleeper** (the coast is safe for you; today's perk); **Trapsense**; **Steady Hands** (your first miss in each fight doesn't use up the beat) |
| **Elf** | +1 Focus | **Long Breath** (a perfect hit widens your other slots' windows for one beat); **Woodcraft** (forests are safe for you; today's perk); **Starsight** (you see at night as by day); **Feather Step** (rough ground costs you no more than open ground); **Skyreading** (a sense of where the weather is heading, about 10 minutes ahead; [weather.md](weather.md)); **Trapsense**; **Moonlit Edge** (at night, the attuned ball's right-edge touches add +10% to its next hit) |
| **Orc** | +1 Vigor | **Bloodrhythm** (each miss on the attuned slot charges its next hit +10%, up to 3); **Berserk Seal** (attuned slot +50%, sealed after its ball first touches the left edge); **Thick Hide** (weather penalties to you are halved); **Iron Gut** (potions heal 25% more); **Hunter's Nose** (you see creatures in neighbouring rooms on the map); **Trapsense**; **Skyreading** |

**Trapsense** marks a trap in a neighbouring room on the map
([journeys.md](journeys.md)). Today's two perks, Woodcraft and Shore-sleeper,
move into the ancestry pools, and the level table stops granting perks.

## Backgrounds

A background is your trade and your past: the culture you come from, not
your body. It gives:

- **Two starting items** for your slots. Each background lists four; you get
  the two your class can use (a Sailor Mage gets the tar flask and the sea
  biscuits, not the boathook).
- **Coins** to start with.
- **Starting opinions:** small affinity or respect with factions that would
  know your kind.
- **A starting realm** (below), where your story begins.
- **Options in events:** in travel events and later social encounters, your
  background unlocks choices or makes checks much easier
  ([journeys.md](journeys.md), "Checks").

| Background | Items (by class) | Coins | Opinions | Good at |
|---|---|---|---|---|
| **Sailor** | Boathook (Weapon), Tar Flask (Trick), Belaying Pin (Light), Sea Biscuits (Potion) | 15 | the Folk of Harrowgate +5 affinity (ferrymen talk) | water: currents, squalls, wrecks, knots |
| **Merchant** | Cudgel (Weapon), Weighted Purse (Light), Pepper Pouch (Trick), Tonic (Potion) | 40 | the Folk +10 affinity; the orcs −5 affinity | tolls, bargains, pickpockets, talk |
| **Woodsman** | Hatchet (Weapon), Skinning Knife (Light), Snare (Trick), Poultice (Potion) | 10 | the Wardens +10 affinity | the wild: tracking, beasts, weather on the road |
| **Street Urchin** | Shiv (Light), Pocket Sand (Trick), Cosh (Weapon), Stolen Tonic (Potion) | 25 | the orcs +5 respect; the Folk −5 affinity | night, locks, crowds, lying |

## Levelling

- The level cap is **20**, and the experience curve stays `100 × level`.
- **Every level:** a stat point (as now). Level 2 is only that: a small first
  level-up, so a new player meets one thing at a time.
- **Levels 3, 6, 9, 12, 15, 18:** a talent.
- **Levels 5, 10, 15, 20:** an ancestry passive.
- No gear or items for levelling up: the `levels` table's gear and perks go.
  Gear comes from loot, backgrounds and the world.
- Picks don't have to be spent at once; the Character button shows a badge
  while you have one waiting. `LEARN <talent or passive>` takes one, or use
  the Character panel, which shows the talent ranks as rows (locked ranks
  greyed: "opens after 2 talents") and the ancestry pool.

## Worn gear

Besides the three slots, a character wears and carries things: **head**,
**chest**, **legs** and a **hand**. Worn gear is never used like a slot; it's
what you have on.

- **Armour** is mostly what worn gear is for, and style: each piece adds to
  your armour, and armour takes `armor / (armor + armor_k)` off every blow
  (`armor_k` is 30: a fighter's starting 9 takes 23%). Some pieces add a stat
  too (+1 Presence for a fine hat), so the world can be balanced around gear
  adding some stats on top of the points from levelling.
- **The hand** holds one special thing: a **torch** (a light: you see the
  ways on in the dark), a **shield** (DEFEND blocks instead of dodging,
  with a wider window; see [combat.md](combat.md)), or an **orb** (a mage's
  focus). One hand means a choice: in a dark cave, the fighter's shield goes
  on the back and the torch comes out.
- **By class:** each piece has a type, and a class wears some types only
  (`wears`): fighters cloth, leather, mail, shields and lights; rogues cloth,
  leather and lights; mages cloth, lights and orbs.
- **Starting clothes:** the class's `outfit` (a fighter's mail shirt,
  breeches and round shield) and the background's (a sailor's knitted cap)
  are put on at creation. More comes from quests (`give`), such as the
  starting realms' rewards.
- `WEAR <item>` and `REMOVE <item or place>`, or the Character panel's Worn
  section. Armour can't change mid-fight; the hand can.
- Data: `alz:wearables` (the catalog), `PLAYER:<id>:wardrobe` (what you own),
  `PLAYER:<id>:worn` (place to item) and `PLAYER:<id>:worn_stats` (the sum,
  which `stat()` adds in).

## Rarity and weather sensitivity

Two different things, shown two different ways:

- **Rarity** is how unusual a thing is: common, uncommon, rare, epic or
  legendary. It's the colour of its name.
- **Weather sensitivity** is how much the weather moves it, from one dot
  (barely cares) to five (only works at its spot). It's the dots
  (●●●○○) in its tooltip, with its spot on the weather grid.

They're set separately: a plain sailor's boathook is common but touchy about
the wet, and a rare blade can be steady in any weather. The really sensitive
pieces are usually rare, so rarity defaults to the sensitivity's level
(the gear's `tier`, [weather.md](weather.md)) unless the seed says otherwise.

### Respec

The **trainer** in Harrowgate (the Training Yard's master) resets your talents
and ancestry passives for **10 coins × your level**, out of combat. You pick
again straight away. Class, ancestry and background never change.

## Creating a character

After you register (and on your next login, for every existing character:
they're wiped and start over, kev included), a creation screen takes you
through:

1. **Class:** three cards, each with its ability and what it can use.
2. **Ancestry:** three cards with the stat; then choose your first passive
   from that ancestry's pool.
3. **Background:** four cards with the items you'd get (for your class), the
   coins, the opinions, and a line about where you'll start.
4. **Summary:** confirm, and you wake in your starting realm.

Your character's card then shows your ancestry and class ("Elf Rogue")
instead of "Adventurer".

## Starting realms

Each background starts in its own small realm: a place you'll never go back
to, where your old life ends and your adventuring starts. It's also the
tutorial.

- **A realm of its own** (`"starting": true`), cut off from the world, with
  its own mild weather and the clock. Three or four areas of 5–10 rooms each.
- **What it teaches**, in order, through the story: first a small quest
  (moving, looking, asking, getting and using things). Then a **lesson** from
  a local (Pell, Aunt Brisa, Maud, Nan): `ASK … ABOUT WEATHER` explains the
  weather panel, `ASK … ABOUT SENSITIVITY` explains weather sensitivity and
  rarity (and hands you a torch), and a first fight with something weak
  teaches the slots and blocking or dodging (7). You go back and tell them
  how it went, and that makes **level 2**: a stat point, nothing more. Then a dark room that needs the torch, the
  realm's longer quests and harder fights, and **level 3** with the first
  talent, once you've seen the weather at work. At the end, a journey with a
  scripted travel event.
- **Two levels:** the quests give 40 (the first), 60 (the lesson), 80 and
  120: exactly the 300 to reach level 3 with nothing else, and a little more
  with the fights on the way.
- **People hand you the next job.** When a quest is handed in, the person
  says so, and a beat later (`offer_beat_ms`, 2.5 s) offers the next one out
  loud; it starts then. A quest that ends in a fight away from them has a
  last step to go back and tell them, so the handover happens face to face.
- **Two voices.** People talk like people who live there ("a merchant who
  can't read the sky gets rained on with her silks out"). What that means
  in game terms (the four parts of the weather panel, the sensitivity pips,
  how travel works) follows as **guide text**, set apart in the log.
- **Leaving:** the last quest's operator (a captain, a carter, a caravan
  master) explains travel when you `ASK … ABOUT TRAVEL`: where routes leave
  from, `TRAVEL` to list them, fares and stages, and that this one is for
  good. Only then does `TRAVEL` show the way out, and you take it yourself
  (`TRAVEL COG`, `CARAVAN`, `BARGE` or `CART`). The journey arrives in
  Alzendor, and the starting realm disappears from your map's realm buttons:
  you can't go back.
- Factions inside a starting realm (rival stallholders, a gang) show on your
  Reputation tab under that realm.

### Gullhaven (Sailor)

*Your ship limps into a shipyard after a storm, and won't sail again this
season.*

- **Areas:** the Slipway (dry dock, sail loft, tar pits, timber stacks);
  Gullhaven Quay (the Salted Gull tavern, the harbourmaster); the Breakwater
  and Seal Rocks (outdoors, exposed to the weather); Wreckers' Cove (a cave).
- **Caulk and Tar:** the shipwright needs tar from the pits for the hull
  (moving, looking, asking, getting, using an item on something). She gives
  you a torch: the sail loft on the way to the quay is shuttered and pitch
  dark.
- **Reading the Sky:** Old Pell teaches the sky and weather sensitivity; a
  rock crab on Seal Rocks is the first fight.
- **Lost Chain:** the anchor chain went over at Seal Rocks; bring it back.
- **Wreckers:** false lights in the cove at night. Find the wreckers and
  their leader, then turn them in to the harbourmaster or take a cut
  (reputation with the town or the wreckers).
- **Out:** the captain pays you off and finds you a berth on a trading cog.
  A squall on the way (the Sailor option shines), arriving at the Harrowlake
  ferry dock.

### Copperstall (Merchant)

*Your family's stall, your first day running it alone, and a market about to
boil over.*

- **Areas:** Copperstall Market (the stalls, where Aunt Brisa works with
  Wenna and Hob); Guild Row (the counting house, the guildmaster, the
  caravan yard and, south of it, the coach stand where Dace loads); the Old
  Granary (cellars).
- **Opening the Stall:** fetch your crates and set out your goods.
- **Market Weather:** Aunt Brisa's lesson, a torch, and a feed rat in the
  caravan yard.
- **Short Weight:** the spice sellers and the cloth sellers accuse each other
  of crooked scales. Investigate (look at features, ask around), calm a
  crowd (Presence), and decide whom to side with: two small factions.
- **Rats in the Granary:** the guild's grain is being eaten; kill the Rat
  King and tell Thorne.
- **Your Own Road:** Thorne thinks you're wasted behind a stall and sends you
  to ask your aunt what she really wants. She wants the stall, with Wenna
  and Hob, for good, and wants you to go and see the world. Dace explains the
  road, and you take his caravan to the city when you're ready. The road is
  ambushed (scripted), arriving at Harrowgate's market square.

### Thornwick (Woodsman)

*A hamlet at the edge of an old wood, and a hunter's last season.*

- **Areas:** Thornwick Hamlet (the lodge, the smokehouse); the Old Wood;
  Fernhollow (a misty bog); Stag's Rise (a hill above the trees).
- **Checking the Snares:** walk your snare line, and find a poacher's trap
  laid on it (traps and their signs). It ends under the deep oaks, dark even
  at noon: without a light you can only go back.
- **Signs in the Sky:** Maud's lesson, a torch, and a bog wisp (it can be
  dodged, not blocked).
- **Moonbloom:** the healer needs a flower that only opens in still, damp
  weather in Fernhollow. Read the forecast and be there when it opens.
- **The White Hart:** hunt an elusive deer on Stag's Rise, and deal with
  the wolves that are hunting it too.
- **Out:** sell the hide in the city: ride a timber barge downriver to the
  edge of the Spiderwood.

### Low Wick (Street Urchin)

*A small town that's got too small for you.*

- **Areas:** the Gutters (alleys); Low Wick Square (the magistrate's house,
  the stocks); the Watch House; the Rooftops.
- **Lifting:** Nan Gristle, who runs the gutter kids, wants a drunk's purse.
- **Gutter Weather:** Nan's lesson, a torch for the magistrate's dark house,
  and a rat in Rat Alley.
- **The Signet:** steal the magistrate's signet ring. Get past the dog, and
  look at the stairs before you climb: a tripwire bell (a trap, with its
  sign on the stairs) guards the study.
- **Too Hot:** the watch is turning the town over. Bribe the carter or hide
  in his cart; a checkpoint on the road (the Urchin option shines), arriving
  in Harrowgate's back alley.

## Build order

1. **Character data and creation:** classes, ancestries, backgrounds in the
   seed and validated; the creation screen; wiping existing characters; the
   card showing "Elf Rogue".
2. **Gear by class:** the Light and Trick kinds, `EQUIP` refusing other
   kinds, the class abilities and background items.
3. **Levelling:** stat points, talent picks with ranks, passive picks at
   5/10/15/20, the cap at 20, `LEARN`, the Character panel's talent rows and
   pool, and the badge. The `levels` table goes.
4. **Talents:** the first pools, with stagger, guard and bleed/burn.
5. **Passives:** world passives first (Trapsense, Woodcraft, Starsight,
   Skyreading), then the slot-ball passives, attuning and their marks on the
   bar.
6. **Respec** at the trainer.
7. **Starting realms:** the quest engine first ([quests.md](quests.md)),
   then one realm end to end (Low Wick, since its exit teaches journeys and
   events), then the other three.

The journeys work in [journeys.md](journeys.md) can go first, in parallel, or
after; backgrounds plug into travel events whenever both exist.

**What changed while building it.**

- The White Hart comes to Stag's Rise at any hour: a tutorial shouldn't make
  a new player wait half an hour for dusk. Moonbloom still waits on the
  weather (Thornwick's sky is still and damp most of the time).
- NPCs don't walk rounds yet, so Low Wick's study is guarded by a trap
  instead of a patrol.
- Starting realms have no factions of their own yet.
- Quest XP was 50, 100 and 150; with the lesson it's 40, 60, 80 and 120.
- Level 2 came too fast, with too much to take in at once (the weather grid,
  talents, ranks). Now talents start at level 3, the lesson explains the
  weather panel before any talent choice, and level 2 is just a stat point.
- A starting realm's `shrine` is where you began: dying in the tutorial
  doesn't throw you out of it.
- Existing characters aren't wiped by a script: any account without a
  created character is offered the creation screen when it next logs in,
  and creating one starts from nothing.

## Open questions

- The names of the new gear kinds (`Light`, `Trick`) and of the talents are
  placeholders.
- Whether a background's starting opinions should be bigger (they're small
  nudges now).
- Whether anyone should be able to see another player's class, ancestry and
  background on their card, or only class and ancestry.
