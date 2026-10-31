# Design notes

The thinking behind some of Alzendor's systems, and options we didn't take
(yet). What's actually built is described in the [README](../README.md). The
weather and its elements have a document of their own,
[weather.md](weather.md), which also sets the rule every new mechanic follows:
it must be used by other systems, remembered, visible, and a real choice.

## Stats

Strength and Dexterity are dull because they're just "more damage" and "more
dodge", detached from anything you do. We considered stats with more
personality, but decided stats should stay simple and universally useful.
Everyone wants them, and the choice is where your points go. What makes
characters different is gear and abilities, which can keep changing as the
world grows.

So each stat plugs straight into a system you can feel:

| Stat | What it does | Why |
|---|---|---|
| **Vigor** | +8 max health per point | Survive longer; the baseline. |
| **Poise** | timing windows 15 ms wider per point | The timing game is the core skill; this makes it more forgiving. |
| **Focus** | perfect windows 10 ms wider per point | Rewards players who already hit their windows. |
| **Presence** | reputation moves 15% further per point | Your deeds matter more, good *or* bad. A social stat. |
| **Resilience** | weather penalties 10% softer per point (up to 50%); bonuses kept | Insurance against the weather. It never adds a bonus, so a specialist still wants its own weather. |

Stats can also come from **boons**: factions grant a stat bonus while your
standing with them is high enough (see [weather.md](weather.md)). That gives
reputation a payoff you can feel in every fight.

Windows are capped so they never reach halfway to the next beat (and perfect
never exceeds the window), so the timing game never goes away.

Ideas for later, if stats ever need more flavour:

- **Tempo:** slightly faster beats. It's strong, and it changes how gear
  combines, so it should probably come from gear or abilities rather than
  points.
- Stats that only matter in some places, like **Nerve** working only in
  arenas, or **Bearings** making you harder to ambush in the forest.
- Stats that touch the weather in other ways: **Wayfinding** (shorter travel
  delays, and spotting new regions in poor visibility). Not **Insight**
  (longer forecasts): foresight is meant to be scarce in other realms, so it
  comes from a narrow Skyreading sense instead (see docs/weather.md).

## Abilities (perks)

Abilities are now ancestry passives, chosen at creation and at levels 5, 10,
15 and 20 (see [characters.md](characters.md)). The first two were about
resting: **Woodcraft** (forests are safe places for you) and
**Shore-sleeper** (the coast is). They show the shape abilities can take:
they change how the world treats you, not just your numbers. More ideas:

- **Hide:** become untargetable to hostile NPCs until you act. Cultures that
  respect cunning would love it.
- **Parley:** talk a neutral NPC out of a fight, gaining respect with
  diplomatic factions and losing it with warlike ones.
- **Second wind:** once per fight, a free heal at low health.
- Choosing between two abilities at certain levels, instead of getting both.

## Reputation: two axes and cultures

A single like/hate number can't express "they hate you, but they respect
you". Each faction tracks **affinity** (like/hate) and **respect**
(rate/scorn) separately, and each faction's **culture** decides which deeds
move which.

Deeds are recorded at one choke point (`deed()` in `alzendor.lua`): `kill`,
`clean_kill`, `ambush`, `flee`, `defeated`, `heal`, `greet` and `taunt`.
Culture rules match a deed, optionally narrowed to the faction (`of`) or
`role` of the NPC involved, and every faction judges every deed. So the town
folk can be glad you killed an orc while the orcs hate you for it but respect
how you did it.

What the current cultures value:

- **Orcs (honour):** fair fights, clean kills, standing your ground. Ambushes,
  running, losing and killing the young cost respect.
- **Spiders (cunning):** ambushes, and slipping away. Getting caught is weak.
- **Harrowgate folk (community):** safe streets, kindness, manners.
- **Wardens (stewardship):** protecting the wood.

Deeds that would make cultures richer:

- **Looting a body** (once there are corpses): honour cultures disapprove;
  scavengers don't care.
- **Sparing** an NPC at low health (`spare <target>`): mercy is respected by
  some, seen as weakness by others.
- **Arena fights:** losing in an arena costs respect with warrior cultures;
  winning against the odds earns a lot.
- **Deception:** lying to an NPC in dialogue. Cunning cultures respect it,
  honest ones are furious if they find out.
- **Witnesses:** deeds could count only when someone of the faction is there
  to see them (an NPC in the room, or word spreading through the area
  channel), which makes stealth meaningful.

How standing shifts behaviour today: friendly NPCs turn hostile if their
faction hates you (affinity ≤ -50); neutral ones turn hostile at ≤ -25 or
friendly at ≥ 25; hostile ones stay their hand at respect ≥ 30 or affinity ≥
25, and become friendly at ≥ 50. Later, respect could open doors: trainers,
duels, quests, prices.

## NPC timing

Players' attacks are judged against a beat, because timing is the skill. NPCs
never miss, so there's nothing to judge, and NPC timing needs no client
verification. But it still lives on the server, because the server is what
lands the damage: every attack is in a schedule (`alz:npc_attacks`, a sorted
set by due time), and every server runs a combat tick ten times a second that
lands whatever is due. Taking an attack off the schedule is atomic, so with
several servers each attack still lands exactly once. Clients get each
attack's `next_ms` and draw the bars themselves; they never decide anything.

NPC attacks are deliberately slow (5–13 s) and few, so they're readable next
to the player's own three rhythms. An NPC can carry several attacks with
different periods, so its pattern has a shape you can learn: the orc warrior's
cleaver every 6 s and shield bash every 9 s line up every 18 s.

## Leaving the world, in the lore

A player vanishing mid-sentence breaks the fiction, so leaving is part of the
world:

- **Safe places** (inns, shrines, camps) are where you rest. Quit there and
  you "settle in to rest, and are gone" at once.
- **Anywhere else** you "lie down to rest", and your sleeping body stays,
  visible to everyone, for two minutes. Then it "fades away". Come back in
  time and you "wake and get up" where you lay. This makes safe places
  meaningful, and makes logging out mid-fight no escape: whatever was
  fighting you keeps hitting your sleeping body, and you can wake at the
  shrine.
- **Abilities** can make terrain safe for you (Woodcraft, Shore-sleeper), so
  a ranger can camp anywhere in the woods.
- **Dropped connections and idling** lead to the same thing. After
  `ALZ_LINKDEAD_SECONDS` without a connection, or `ALZ_IDLE_MINUTES` without
  a command, you lie down (or simply rest, if you're somewhere safe).
- **Coming back** after your body has faded: you "arrive, well rested".

Other options we considered:

- **Waystones:** adventurers are anchored to the world by a waystone. Logging
  out draws you back to it; idling makes you "flicker". Simple, but every
  logout looks the same.
- **Dreamers:** players are dreamers visiting Alzendor and "wake" to leave.
  Atmospheric, but it makes everything feel less real.
- **Vulnerable sleepers:** hostile NPCs (or, one day, players) could find and
  attack sleeping bodies they weren't already fighting. Riskier, and maybe
  right for dangerous areas.
- **Bedrolls and tents** as items that make one spot safe for a while.
- **Paying for a room** at an inn to rest safely, once there's money.
