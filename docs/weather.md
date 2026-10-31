# Weather and elements

Weather in Alzendor isn't scenery. It is a number every player shares, and it
moves through combat, travel, discovery, NPCs, stats and reputation. This
document is the design. How to build it is in
[weather-plan.md](weather-plan.md), and the README covers what players and
seed authors need.

## The rule: every mechanic is used, remembered and leveraged

A new mechanic earns its place only if it passes all four checks:

1. **Read by other systems.** At least two other systems use it. Weather is
   read by combat, travel, discovery, NPCs, stats and reputation.
2. **Remembered.** It has state that builds up over time, not just a fresh
   roll each time. Snow piles up and melts; forecasts you learn stay learned.
3. **Visible.** Players can see it, and see exactly how it changed a number.
4. **A choice.** It gives players a decision to make (what to carry, when to
   travel, whom to befriend), not just a penalty to sit through.

## Three axes

The weather in a place is three numbers, each from −1 to 1:

| Axis | −1 | 0 | +1 |
|---|---|---|---|
| **Temperature** (x) | dead cold | a 70° day | scorching |
| **Energy** (y) | dead still: unnerving, lifeless | a lively breeze, broken cloud | howling chaos |
| **Precipitation** (p) | bone dry | the edge of rain | a deluge |

Temperature and energy form a square grid. The neutral middle is the
pleasant, lively day: movement, shade, breeze and sun. "Calm" is not peaceful
here. Stillness is the deadness of a heat that won't break, or of a frozen
night.

The corners are the extremes, and each has a name, so gear and players can
talk about them:

| | Still (y < −½) | Chaos (y > ½) |
|---|---|---|
| **Hot** (x > ½) | **Scorch**: the sun bearing down, no air | **Tempest**: hot, roaring storms |
| **Cold** (x < −½) | **Rime**: frozen stillness | **Gale**: horizontal snow and hail |

The middle square (both |x| and |y| under ½) is **Temperate**. Anything else
is described by its two axes ("hot and breezy", "cold and gusty").

Precipitation is wet when p > 0, and its **intensity** is p² there: wet half
the time, but a deluge (intensity > 0.8) only about 5% of the time.
Temperature decides what falls: **rain**, **snow** when x < −0.15, and
**hail** when it's that cold and y > 0.5. Dry and windy is gusts and dust;
dry and cold is an icy wind.

## How the weather moves

Each **realm** has one sky: the weather is a pure function of time and the
realm, so it never jumps about as you walk from region to region. Every
player sees the same weather, every server computes it the same way, and the
future can be computed exactly, which is what makes forecasts possible.

Each axis of each realm does three steps, with its own random numbers:

1. **Add up five random sine waves.**
   `r(t) = Σₖ aₖ·sin(ωₖ·t + φₖ)`, with amplitudes aₖ from 0.5 to 1,
   frequencies ωₖ from 0.1 to 1 and phases φₖ from 0 to 2π. The 15 numbers
   are drawn once from the seed (`weather_seed` plus the realm and axis), so
   they never change. The frequencies don't line up, so the pattern
   meanders and never quite repeats.
2. **Even it out to −1…1:** `u(t) = 2·F(r(t)) − 1`. F is the measured
   cumulative distribution of r: the fraction of time r is below a given
   value. It's measured from 20,000 samples when the seed loads and stored as
   101 quantiles; Lua interpolates between them. (`erf(r / √Σa²)` is a close
   approximation, but a sum of five sines is bounded, so it has thinner tails
   than a bell curve and erf would make the extremes too rare. Measuring is
   exact and cheap.) Now u spends equal time everywhere from −1 to 1.
3. **Stretch toward the centre** (temperature and energy only). With
   c = √(1/3) ≈ 0.577:
   `|x| = |u| / (2c)` if |u| < c, else `0.5 + (|u| − c) / (2(1 − c))`, with
   x taking u's sign. Each axis spends 57.7% of the time in its middle half,
   so the weather is Temperate a third of the time (0.577² = 1/3), and in
   each of the four outer quadrants a sixth.

Precipitation uses steps 1 and 2 only, so p is evenly spread from −1 to 1,
and the p² intensity makes heavy rain rare.

**Time:** t is real time in units of `weather_unit_minutes` (default 30). The
fastest waves take about three hours to cycle and the slowest over a day.
Because of the evening-out step, the weather can still cross from one side
of the grid to the other in two or three hours, so it changes noticeably
during a session without lurching from one 10-minute stretch to the next.

The realm then moves and narrows its sky: each axis becomes
`centre + spread × value`, so a realm can be always frozen or always still.
Realms never share weather. See [realms.md](realms.md).

## Indoors, and places with their own climate

**Indoors is neutral.** Any livable space (an inn, a basement, an attic, a
dusky room, the inside of a coach) is marked `"indoor": true`, and its
weather is always dead centre on the grid and dry: a mild, still, dry room.
That balances the game around neutral gear: inside is almost always the
same, so ordinary weapons work as intended there, and the weather is
something you meet when you step out.

**Exceptional places** can have a fixed **climate** of their own instead:
`climate: {temperature, energy, precipitation}` on a room or area. The
Broodmother's lair is a dead-still heat. Everything that reads weather reads
the climate there, so a harsh lair is a challenge you prepare for, even if
the trip there is through opposite weather. Use these rarely.

Outdoors, **terrain** nudges the realm's weather a little: forest is
sheltered (less energy and less rain), the coast is windier. The amounts are
seed rules (`terrain_weather`).

## Ground: what the weather leaves behind

Each realm keeps a running total of **snow** and **mud**, from 0 to 1:

- Snow builds while snow falls (by its intensity) and melts in warmth.
  Melting snow turns to mud.
- Mud builds while rain falls, and dries out in dry, warm weather.

Ground lasts after the sky clears: the day after a blizzard is still slow
going. Indoor rooms have no ground.

## What weather does

### Gear: element profiles

Every piece of gear has a **weather profile**: a spot on the
temperature/energy grid where it works best, whether it wants **wet**,
**dry** or doesn't care (**any**), and a **tier** that says how much it
depends on the weather. That profile is its element. A "Rime dagger" is a
dagger whose spot is in the Rime corner.

Gear without its own profile uses its kind's default: weapons and melee sit
in the middle (they like a neutral day), spells sit high on energy (they
like energetic weather), and potions sit in the middle.

The **tier** is the gear's **weather sensitivity**, shown to players as one
to five dots (●○○○○ to ●●●●●), never as a colour: colours belong to
**rarity**, which is separate ([characters.md](characters.md), "Rarity and
weather sensitivity"). Rarity defaults to the tier's (grey common, green
uncommon, blue rare, purple epic, orange legendary), and the seed can set it
apart (`rarity`): the sensitive pieces are usually rare, but not always.

| Tier (sensitivity) | At its spot | Far away (radius R and beyond) | R | Wet/dry effect |
|---|---|---|---|---|
| Grey | +15% | −15% | 2.0 | ±10% |
| Green | +25% | −20% | 1.5 | ±15% |
| Blue | +40% | −30% | 1.1 | ±20% |
| Purple | +60% | −45% | 0.8 | ±25% |
| Orange | +100% | ×0: useless | 0.5 | ±30% |

With d the distance from the current weather to the gear's spot, and
`c = max(0, 1 − d/R)`:

```
place  = (1 − far) + (peak + far) · c
precip = 1 + k·s   (wants wet)   1 − k·s (wants dry)   1 (any)
         where s is the intensity when wet, or p (negative) when dry
factor = place × precip
```

The factor scales the gear's amounts (damage or healing), rounded, and can
reach 0. Grey and green stay within about ±30%, so no common gear is ever
useless and the right choice still clearly wins. Blue, purple and orange
break that on purpose.

### Gear: timing

The weather also changes the rhythm of every slot, whatever the gear:

- **Heat** (x > ½) makes you sluggish: beats come up to 30% slower at x = 1.
- **Chaos** (y > ½) buffets you: timing windows up to 30% narrower at y = 1.
- **Dead stillness** (y < −½) sets your nerves on edge: perfect windows up
  to 30% narrower at y = −1.

A rhythm takes its timings when it starts (its opener) and keeps them until
it ends, so the weather never shifts a beat under you mid-rhythm.

### Resilience softens the bad, keeps the good

**Resilience** is a fifth stat. Each point is 10% (up to 50% at 5 points),
and it softens every weather penalty by that much, but never a bonus:

```
factor' = 1 − (1 − factor) × (1 − resilience)    when factor < 1
```

So an orange spell outside its weather does half damage at 5 Resilience
instead of none, and still gets its full +100% inside. Resilience also
shortens travel delays and softens the timing penalties and the cold's slow
healing.

### Travel

Snow and mud slow you down. Moving through deep ground first shows why
("You take high steps, trying to clear the snow that impedes you."), then,
after the delay, the move happens. The delay is the mechanic. Up to 3 s for
deep snow and 1.5 s for deep mud, softened by Resilience. Leaving a fight
through snow takes just as long, while your foes keep swinging.

### Healing

Out of a fight you heal slowly over time. Bitter cold outdoors (x < −½) slows
that by up to half, softened by Resilience.

### Seeing the way

In heavy precipitation (intensity ≥ ½), in a dark room, or outdoors at
night away from a town's lamps, you can't see far:

- `look` and the exit buttons only show exits to rooms you've already been
  to (and say other ways are hidden by the rain or snow), and the map shows
  no glimpses of unexplored rooms.
- Entering a region doesn't discover the regions bordering it.

The exits are still there. In rain or snow you can walk any direction and
find the way for real, and once the weather clears, discovery happens again
as you move. In the dark you can only feel your way back along ways you know,
until you hold a light (a torch in your hand, [characters.md](characters.md),
"Worn gear"). Dark rooms (`"dark": true`: caves, shuttered lofts) are dark at
any hour and also hide what's on the floor; areas with `"lit": true` (towns)
are never dark. A light doesn't help in heavy rain.

### Exposure

In the dangerous places ([zones.md](zones.md)), some weather makes exposure
worse: a step on the Cold Spine counts double in freezing weather, in the
Emberwaste when it's hot, in the Rotwood when it's wet, and on the Bone
Steppe in a high wind. Resilience sometimes shrugs a step off, as it softens
everything else the weather does.

### NPCs

An NPC can be active only in some weather (`active_when` ranges for
temperature, energy and precipitation). Outside them it hides, leaving the
room with a line of text, and it comes back when the weather turns. NPCs
never hide mid-fight. Spiders keep out of the rain; the bog lurker only
comes out when it's wet.

## Forecasts and weather lore

Because weather is computed, not rolled, a forecast is the real future.
Knowing it is power: when the spiders will clear the passage, or when
they'll be out for the killing.

- **Weather lore** for a realm is learned from an NPC who knows its skies
  (`ask <npc> about weather`): in Alzendor, Old Tamsin at the lighthouse,
  Osric the ferryman and Wren the warden can all teach you. They only teach
  people they're friendly with. Lore is permanent, like a map.
- **How far ahead** you can see depends on your affinity with the faction of
  the NPC who taught you: the next hour at first, and 30 minutes more for
  every 10 affinity, up to 3 hours. (Items can teach skies too, like the
  storm glass in the Rimewaste, where no one is friendly enough to teach
  you; they give the first hour. See below: this is too generous for a harsh
  realm.)
- **Without lore**, you can still feel the weather where you are, but only
  roughly: the grid shows a blurred patch, not an exact point, and there's
  no forecast. The further you travel from what you know, the more the
  weather catches you off guard.
- Indoors (and fixed climates) are always known exactly. You're standing in
  them.

### Foresight is a resource, and other realms ration it

Knowing what the sky will do is one of the most valuable things a player can
have. It decides when to cross a pass, when to fight, and when to run for a
portal before it closes. So it should be earned, and how hard it is to earn
depends on where you are:

- **The home realm is where you learn it.** Friendly locals teach its skies,
  and better standing sees further, as above. That's fine: the home realm is
  meant to be knowable, and learning to plan around the weather here is how
  players learn the system.
- **Other realms are not meant to be tamed.** They're dangerous, difficult
  places to explore, and part of what makes them so is that you mostly can't
  see what's coming. Good, solid forecasts there should be rare, partial and
  hard won. A realm's weather lore might come only from a hostile people
  you've somehow won over, a long and risky expedition, a quest's reward, or
  a rare find deep inside. It shouldn't be a pickup on the way in.
- **Even earned lore is shorter there.** A harsh realm can cap how far ahead
  anyone sees its skies (say 30 minutes to an hour, never three), and
  standing should stretch it slowly if at all.
- **What everyone can have is a sense of direction.** A skill or ability (a
  working name: *Skyreading*) gives a slight notion of which way the weather
  is heading: about **10 minutes** ahead, as a direction rather than a point.
  The panel would show an arrow from the blurred patch ("getting colder,
  the wind rising"), not a trail. It works in any realm, including ones you
  have no lore for, so it's what a careful explorer relies on out there. It
  might improve a little with training, but never into a real forecast.

That gives four levels of foresight, from least to most:

| Level | What you see | Where it comes from |
|---|---|---|
| Feel | a blurred patch for now | everyone, everywhere |
| Sense | the patch and a 10-minute heading | Skyreading, an elf and orc passive (built) |
| Lore | the exact point and a trail ahead | taught or found, per realm |
| Deep lore | a longer trail | standing with the teacher's people; capped low in harsh realms |

Lore stays learned once you have it (it's remembered, like a map), so the
scarcity is in getting it, not in keeping it.

## Reputation pays in stats

A faction can grant **boons**: a stat bonus while your affinity or respect
with it is at or above a threshold. The Wardens teach those they like to
weather the wood (+1 Resilience at affinity 20); the Brood respects cunning
(+1 Poise at respect 30). Boons add to trained stats everywhere a stat is
used, and the Character panel shows where each bonus comes from.

## Your pack and loadout

Spare gear only matters if carrying it costs something and swapping has a
moment:

- Your **pack** holds 12 things (`pack_size`): carried items plus gear that
  isn't in a slot. You can't pick things up with a full pack. Gear from a
  level-up or a kill always arrives, even over the limit.
- **No swapping mid-fight**: you can't change slots while anything is
  fighting you. So you choose your loadout before the fight, for the weather
  you expect.

## Seeing it all

Weather is only fair if it's readable:

- **The weather panel** (always visible) is four columns, always in the same
  order, each with its heading, so you find each thing by where it is rather
  than by reading: **Sky** (the grid, with the current point as a dot, a
  blurred patch without lore, and the forecast as a trail of fading dots),
  **Rain** (a vertical bar: what's falling and how hard), **Time** (a
  day/night wheel turning under a marker, with how long until dusk or
  daylight) and **Ground** (road, open or rough footing, and any snow or
  mud). A line below sums it up in words.
- **Slots are always visible.** Each one shows its gear and a ▲ or ▼ with the
  weather's effect, so you can see at a glance how your loadout suits the
  conditions.
- **The tooltip** for gear (on slots, in the inventory, and on talents in the
  Character panel before you learn them) shows its name in its rarity's
  colour, what it is and does, then **Weather sensitivity** with its dots,
  the same grid with its spot shaded, its wet/dry bar (filled for wet, empty
  for dry, half for any) and the current weather dot on top. Below that is
  **Right now**, one line per modifier, ending in the numbers you'll
  actually get:

  ```
  Firebolt
  Rare · Spell
  A bolt of fire that loves a hot, wild sky and hates the wet.
  8 / 10 / 16 damage (opener / hit / perfect) · every 4.0 s
  Weather sensitivity ●●●○○
  [grid: its spot in Tempest, shaded; today's dot nearby] [bar: empty, wants dry]
  Right now · Harrowgate
  Hot and gusty, light rain
    Weather: near its spot                      +20%
    Rain (it wants dry)                         −2%
    Heat: beats slower                          +5% beat
    Resilience 2: penalties softened            20% softer
    → 9 / 12 / 19 damage · every 4.2 s · ±300 ms (perfect ±100)
  ```

  (Temperature 0.6, energy 0.3, precipitation 0.3, and Resilience 2: the
  heat's +6% is softened to +5%.)

- The `weather` command prints the same as text, and the `gear` command shows
  each piece's current effect.

## Decisions made, and what's open

These are defaults chosen to get the design built, all easy to change:

| Question | Decision |
|---|---|
| How fast weather moves | `weather_unit_minutes` = 30 (10 swung the weather across the whole grid in under an hour) |
| Where a grey item's spot is | its kind's default (spells high on energy) |
| Wet/dry on items | wet, dry or any; strength scales with intensity or dryness |
| What heavy precipitation hides | unexplored exits in `look`, glimpses on the map, discovering borders |
| What the pack holds | items and unslotted gear, 12 in all |
| Where weather lives | one sky per realm, never per region; realms never share |
| Indoors | always neutral and dry; a fixed `climate` only for exceptional places |
| New stat | Resilience added as a fifth stat |

Ideas for later:

- NPCs with weather profiles, so the weather cuts both ways in a fight.
- More stats that touch systems, e.g. **Wayfinding** (shorter delays, and
  discovering in poor visibility). (**Insight**, longer forecasts and an exact
  dot without lore, would undercut how scarce foresight is meant to be in
  other realms; the Skyreading sense above replaces it.)
- Skyreading, harder-won lore and per-realm forecast caps (see "Foresight is
  a resource" above), and a harder way to get the Rimewaste's storm glass.
- Hyper-specific gear: a narrow precipitation range as well as a spot.
- Stashing or discarding gear to free up the pack.
