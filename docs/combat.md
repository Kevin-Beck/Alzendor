# Combat: defence, armour and the combat panel

How a player meets the blows coming at them, and how the side panel shows a
fight. The slots themselves (three rhythms, timing windows, the weather on
gear) are in the README's Combat section and [weather.md](weather.md).

## Blocking and dodging

NPCs never miss, but a player can meet a blow:

- **DEFEND** (the **7** key by default, changed in Settings, or `DEFEND` / `BLOCK` / `DODGE`)
  braces for the next blow. With a **shield** in your hand it's a **block**;
  without one, a **dodge**.
- **Timing:** the press counts if it's within the window of when the blow
  lands, before or after. Perfect (within `defend_perfect_ms`, 60 ms) takes
  the whole blow. Further out it takes from 75% down to 25% at the edge of
  the window. A shield scales a block by its `block` (1 for a round shield).
- **Windows:** a dodge is `dodge_window_ms` (200) + 15 ms per point of
  Poise; a block is `block_window_ms` (300) + 15 ms per point of
  Resilience. Both are capped at `defend_late_ms` (400), because that's how
  long a blow waits after it's due before it lands, so a late press still
  counts.
- **No spamming:** a press is spent on one blow, and there's a cooldown
  (`defend_cooldown_ms`, 1.5 s) before the next. Against one enemy you can
  meet nearly every blow; against two, you choose.
- **Not everything can be met.** Each NPC attack says how (`defend`):
  `both` (the default), `block` only, `dodge` only, or `none`. A bog wisp's
  sting is light: dodge it, you can't block it. The Rat King's swarm can't be
  met at all.
- The combat line says what happened: "Kevin blocks the Orc Warrior's
  cleaver perfectly! (0, 7 blocked)", or "(3, 4 dodged)" for part of it.

Order of what takes damage off a blow: the block or dodge, then a guard
(talents like Guard Up), then armour.

## Armour

Worn gear ([characters.md](characters.md), "Worn gear") adds armour, and
armour takes `armor / (armor + armor_k)` off every blow, rounded (`armor_k`
is 30). Small blows can round to nothing taken off; big ones lose a steady
share. It's always on: no timing, no weather.

## Deadly and watchful enemies

The client tags an NPC **deadly** when any of its blows would take 40% of
your health or more, and its target card says how hard it hits. Some deadly
things are **watchful** (`notice` in the seed): walking in, a Poise check
(easier with CREEP) decides whether it notices you, and unnoticed, it leaves
you alone for a minute unless you touch it. Auto-targeting never picks
something deadly or watchful that isn't already after you. See
[zones.md](zones.md).

## The combat panel

The side panel, top to bottom, always in the same places:

1. **Here:** everyone in the room, compact. A fighting NPC's coming blows
   show as thin bars in its row.
2. **The target**, which pops up in its own space below the list: a portrait,
   a thick health bar that runs out from right to left (with a red trail that
   lags behind, so you can judge how fast it's falling), and each of its
   attacks as a **marker sliding to the end of its bar**, where the blow
   lands. When it's aiming at you, the end of the bar is shaded: that's your
   window. Press 7 as the marker reaches it. Each attack says whether it can
   be blocked or dodged.
3. **Your slots**, and below them the **defend row**: its key (click it to
   choose another, remembered in this browser), Block or Dodge, a bar that
   fills as it recovers, and the result.

Behind all of it, faintly, **your health** fills the panel from the bottom.
As you're hit, the level drops past the target and your slots, with a red
trail behind it, so you see your health falling without looking away from
the fight.

Entering a room targets the first hostile there, or else the first friendly
NPC (never a neutral one or a player, so a slot pressed by habit can't start a
fight); when your target falls, the next hostile is picked.

## Decisions, and what's open

- One key for both: block if you hold a shield, dodge if not. A shield's
  window is wider, but the shield takes the hand a torch would need.
- Presses are judged by Redis's clock when they arrive, like slots; the
  client draws attack markers for when a press sent now would arrive.
- Open: whether some enemies should telegraph a heavier blow differently,
  and whether a perfect block should stagger the attacker.
