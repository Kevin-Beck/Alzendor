# Talk, items and layout: the next update

A design for the next round of changes: discussing things with people by
target, greetings, people who remember you, giving, gifts and selling, what
people will tell you as they come to trust you, quests handed over properly,
a pinned quest line, traps you can sneak past, hold / wear / equip, and a new
layout with the weather beside the map and gear shown as cards. It's built:
the rules are in `alzendor/alzendor.lua` (the Talk section), the commands in
`alzendor/commands.py`, and the client in `alzendor/web/index.html`. "Today"
notes say what existed before.

## Talking to people

### Discuss

Conversation is **`DISCUSS <topic>`**, not only questions and answers: some
topics are things you tell them, offer, or argue about.

- **`DISCUSS <topic>`** talks with your current target: `DISCUSS WEATHER`,
  `DISCUSS QUESTS`, `DISCUSS THE SIGNET`. `DISCUSS <topic> WITH <name>` talks
  to someone you haven't targeted. `ASK` and `TALK` are other ways to say it,
  so `ASK NAN ABOUT SIGNET` still works.
- **`DISCUSS`** on its own lists the topics your target has **for you, now**,
  as clickable words. Topics you don't qualify for aren't listed (and the
  target card lists only the same ones), so there's always a reason to come
  back: when they trust you more, or your story moves on, they'll have more
  to say.
- Naming a topic they won't discuss with you gets a deflection by
  disposition, never a hint that something's there: *"Can't help you with
  that."*
- With no target, DISCUSS picks the only person in the room if there's
  one; otherwise: *"Discuss it with whom? Press Tab, or click someone."*
- *Today:* the client sends your target with every command, and `ASK
  WEATHER` already falls back to it.

### Greet

- **`GREET`** (or `HELLO`) greets your target, and they answer with a line
  that fits who they are, how they feel about you, and whether they've met
  you (below).
- If they have something for you (a quest to offer, something they want),
  the greeting hints at it: *"You again. Got quick hands? I might have
  work."*
- It counts as the existing `greet` deed (as BOW and WAVE do today), so
  cultures that value courtesy notice; and it's a little rapport, once a day.

### People remember you

- An NPC knows whether you've spoken before (`PLAYER:<id>:met`). The first
  time is an introduction (*"Nan Gristle. You'll have heard of me."*); after,
  a greeting that knows you (*"Back, are you?"*).
- A topic can have a `again` line for when you've discussed it before:
  *"As I said: the stairs. Watch them."*
- Greetings shift with rapport and with what you've done for them (a
  `greet` line can require a quest done): *"The one who found the filed
  weights! Come in."*

### Standard topics

Every NPC can have a few standard topics, as well as their own (`signet`,
`moonbloom`):

| Topic | What it's for |
|---|---|
| `quests` (`work`, `jobs`, `help`) | Anything they need done: an offer, or "Nothing for you right now." |
| `wants` (`buy`) | What they'd pay for (see Giving and selling). |
| `background` (`yourself`, `family`) | Who they are, their family, their past. |
| `rumours` (`news`, `gossip`) | What they've heard: often a hint to a hidden place or a quest elsewhere. |
| `place` (`history`, `here`) | The area, its history, who runs it. |
| `weather`, `travel` | As today, for those who know about them. |

Like any topic, each is listed only when they'll discuss it with you.
`quests` is listed for everyone, so `DISCUSS QUESTS` always gets an answer.

### Trust: what people will discuss

A topic can have `requires`; until you meet it, it isn't one of their
topics for you:

```json
"background": {
  "text": "My mother ran these gutters before me...",
  "requires": {"rapport": 3}
}
```

- **Faction reputation** (today's affinity and respect) gates what a group
  will discuss: the Harrowfolk talk about the town's history once they like
  you.
- **Rapport** is new: how well one NPC knows you, from 0. It comes from
  greeting them (once a day), discussing them (their background, their
  family), quests done for them, gifts, and selling to them. It's per player,
  per NPC (`PLAYER:<id>:rapport`, NPC id → number), and it can fall: insult
  them, or harm their friends. It doesn't fade with time: what you've built
  stays built.
- Rapport is shown on their card as a word: *stranger*, *known*, *friendly*,
  *trusted*.
- `requires` can also name a `level`, or a quest (done, or active at a
  step).
- **Some people are open and some aren't.** Maud tells anyone what she needs;
  Nan doesn't say what she wants until you've done a job; a guard never
  talks about his family.

### Topics that open, spread and close

Topics aren't permanent; they follow the story.

- **A quest can open a topic for a while.** A topic with `while` (a quest
  active, or at a step) is only there during it: the magistrate is something
  to discuss while you're after his signet, not after.
- **Topics spread.** Discussing a topic with one person can open it with
  others who know about it: an NPC's topic with `heard_from` (`["nan"]`)
  opens once you've discussed it with Nan, *if* you're on good enough terms
  with them (its `requires`).
- **They close.** A topic with a `while` closes when the quest moves past
  it. If you finish the signet job before you've opened `magistrate` with the
  fence, it's gone: the moment has passed.

## Giving, gifts and selling

### Give

- **`GIVE <item> [TO <someone>]`** hands something you carry to your target
  (or whoever you name). They take it if a quest needs it, it's a gift they'd
  like, or they want to buy it; otherwise: *"You offer the bear claw to Nan
  Gristle, but she won't take it."* An NPC can have its own refusal line.
- **Quests use give for handing things over.** A new trigger, `give` +
  `to`, replaces `use … on <npc>` in every quest (USE SIGNET ON NAN becomes
  GIVE SIGNET TO NAN). `USE <item> ON <npc>` keeps working as another way to
  say it. `USE` stays for things: USE TAR ON HULL.

### Gifts

- An NPC can have **`likes`** (items or tags: Maud likes herbs, Brannoc good
  iron). Giving them something they like is a gift: rapport, and a line.
- **One gift per NPC per day** (`gift_cooldown`); a second that day: *"You've
  given me plenty. Keep it."* Something they don't like is refused.

### Selling what people want

- An NPC can have **`wants`**: things they'll buy, by item or by a tag
  (`claw`, `pelt`, `herb`), with a price and a line:
  *"Bear claws. Two coins each. The apothecary grinds them for gout."*
- **Creatures drop things.** NPCs get `loot` (items, with a chance each:
  bear claws, bat wings, wolf pelts, newt eyes), as well as today's gear
  `drops`. These are ordinary items, with a `tags` list and a base `value`.
- **`GIVE <item> TO <someone>`** who wants it sells it, for coins and a
  little rapport. Sell any time; a want can have a daily cap, so it can't be
  farmed endlessly.
- **Haggling:** every sale's price rises a little with your Presence (and
  the merchant's Haggler passive). No command and no risk; it just pays to
  be charming.
- **You have to ask around.** `DISCUSS WANTS` tells you what someone buys,
  and that can need rapport. Wants you've heard about are listed in a new
  **Wants** section of the Quests panel, so you remember who buys what.
- Your pack is limited (`pack_size`), so selling is also how you clear it.

## Quests, handed over

### What went wrong

A trace of a fresh urchin start shows Nan *did* speak each offer, about three
seconds after the hand-in. It still didn't feel like being given a quest:

- Her lines are curt instructions, not a request ("Now, real work. The
  magistrate's signet ring…").
- A red **New quest:** system line arrives at the same moment and takes the
  attention, and the Quests badge lights up, so the quest seems to come from
  the interface, not from her.
- Nothing is asked of you: it's on your list whether you said yes or not.

### The fix

- **Offers are asked.** Every `offer` is written as a request, to you:
  *"If you've got the nerve, I've a real job. The magistrate's signet
  ring…"*
- **You accept by answering.** After an offer the NPC waits for your answer,
  and guide text says to type **`ACCEPT`** (or `YES`). Then they react
  (*"Good. Watch the stairs."*) and the quest begins.
- **Early quests can't be declined.** The starting realms' quests and the
  first few in the Greyfold (A Newcomer, Word from Millbrook, and the like)
  are marked `"must": true`. Their guide text only mentions ACCEPT, and
  typing `DECLINE` gets *"This one isn't one to turn down: type ACCEPT."*
- **Later quests can be turned down.** Their guide text offers `ACCEPT` or
  `DECLINE` (or `NO`). Declining leaves the quest with the NPC: `DISCUSS
  QUESTS` with them to have it offered again. An offer doesn't run out.
- **No "New quest:" line in the log.** The quest begins in the pinned quest
  line instead (below), which opens and flashes once. The log keeps only
  what people say and do.

### The pinned quest line

- One long box **above the chat log**, the same width, showing your current
  quest's name and what to do next: *The Signet — Steal the magistrate's
  signet: east of Wick Square, up the stairs (NORTH).*
- It can be collapsed to a thin bar, or hidden; that's remembered in the
  browser. A new quest, or a step moving on, opens it again.
- Clicking it opens the Quests panel, the full list. The panel no longer
  draws attention to itself: it's where you go when you're unsure what to do.
- The small quest section in the side panel goes; the pinned line replaces
  it.

### What now?

- **`WHAT NOW`** (or `WHATNOW`, `HINT`) answers "what am I meant to be
  doing?" With a quest, it repeats it: the quest and its current step.
- **Without one, it leads you by your senses**, never by directions. Each NPC
  with a quest to give has a **`lure`**: what draws you to them, written for
  the senses. WHAT NOW picks the nearest one with work you qualify for (met
  or not; one at random if several are about as near), and says which way
  and how far, in the same voice:
  - *"Far off to the west you see the light of what may be an inn."* (Marta)
  - *"The sound of waves crashes to the south. Perhaps something worth
    seeing."*
  - *"Close by, to the east, the smell of a bakery."*
- **Which way** is the compass bearing from you to them (eight ways), not
  the path, so it points without solving the route. **How far** is a word
  from the walking distance: *close by* (a few steps), *off to the*
  (further), *far off in the distance* (further still).
- **Within reason:** only givers within `whatnow_steps` (say 15 steps) in
  your realm. With none in reach: *"Nothing calls to you here. Towns are
  where work is found."*
- **Lures also come unbidden.** Now and then (`lure_chance`, a small chance
  each step) you notice a nearby quest giver's lure as you walk, whether or
  not you have a quest: the world pulling at you. Each lure is felt at most
  once a day.
- **Rumours point to people.** A quest giver's lure has a `rumour` form, as
  hearsay: *"They say the Gilded Tankard always has work going."* When you
  `DISCUSS RUMOURS` with someone who has no rumour of their own, they pass on
  one of these about a quest giver nearby.

## Traps: sneak in, sneak out

*Today:* every trap has a sign in a neighbouring room (LOOK at the stairs),
and `CREEP <direction>` (or `CAREFUL`, `SNEAK`) moves a step slower with
+25% to the check; knowing the trap is there adds another +25%. Thornwick's
quest teaches CREEP, Low Wick's doesn't, and nothing says what a sign is for.

How you meet a trap:

| You | What happens |
|---|---|
| Walk in | The usual check (the trap's stat), as today; fail, and it springs. |
| Creep in, without having read the sign | Much slower, and a big bonus (+50%) to the check. |
| **Read the sign, then creep in** | **You get past, always.** The trap stays set for whoever comes next. |
| Disarm it | A check; pass, and it's sprung harmlessly for everyone until it rearms. Fail, and it springs on you. |

- **Reading the sign** (LOOK at it) is remembered (as today, on your map).
  It follows with guide text: *"There's a tripwire on the stairs. CREEP
  NORTH to get past it safely: slow, but sure. Or try DISARM NORTH: it's
  a Poise check, and failing springs it."*
- **Sneak in, sneak out.** Reading the sign and creeping gets you safely
  past, but the trap is still live: going back, or coming again another day,
  you have to creep again (and remember that you must). That costs time
  every time; disarming costs a risk once.
- **CREEP is slow:** each step takes three times as long as walking (3×
  `pace`).
- **DISARM <direction>** is new. From the sign's room, a check (the trap's
  stat; Focus for mechanisms, Poise for tripwires) that takes a few seconds.
  Failing springs it on you, with all its harm, so a deadly trap is a real
  gamble. Trapsense gives a bonus.
- Nan's offer mentions the stairs, and the quest goal says how: *"Watch the
  stairs: LOOK at them before you climb, then CREEP NORTH."*

## Hold, wear and equip

- **`HOLD <item>`** takes a hand item (torch, shield, orb) in your hand.
- **`WEAR <item>`** puts on head, chest and legs gear. Told to wear a torch,
  it holds it, and says so: *"You hold the torch (HOLD is for things in your
  hand)."*
- **`EQUIP <anything>`** works for all of it: slot gear goes to a slot (as
  today, `EQUIP SWORD 2`), worn gear to where it goes, a torch to your hand.
- `REMOVE` (or `UNEQUIP`) takes any of it off.
- *Today:* WEAR already takes HOLD as another name, and EQUIP only knows
  slot gear.

## The layout

```
┌───────────────────────┬───────────────────────┬──────────────────┐
│ WEATHER               │ MAP                   │ HERE AND NOW     │
│                       │                       │                  │
│  Sky       Rain       │                       │ Room, exits      │
│  (big)                │                       │ People here      │
│                       │                       │ Target           │
│  Time      Ground     │                       │ Slots, defend    │
│                       │                       │                  │
│  Forecast             │                       │ (the combat      │
├───────────────────────┴───────────────────────┤  panel is being  │
│ ▸ The Signet — Steal the magistrate's signet… │  redesigned)     │
├───────────────────────────────────────────────┤                  │
│ Chat log                                      │                  │
│                                               │                  │
├───────────────────────────────────────────────┤                  │
│ > command                                     │                  │
└───────────────────────────────────────────────┴──────────────────┘
```

- **Top left: the weather and the map, side by side, the same size.** The
  weather (sky, rain, time, ground, the forecast) gets as much room as the
  map.
- **Bottom left: the pinned quest line, the chat log and the command line,**
  across the full width under both.
- **Right: here and now, top to bottom.** The room and its exits, who's
  here, your target, your slots and defence: everything you can act on in
  this place. Its arrangement is yours to redesign; this update only moves
  the weather out of it.
- **On a phone** it stacks: the weather becomes a slim strip at the top (sky
  dot, rain, time, ground as icons) that opens to the full panel; then the
  map, the quest line, the log, and the here-and-now panel behind a button,
  as the side panel is today.

### A bigger, clearer weather panel

- With half the top row to itself, the sky grid grows from about 95 px to
  about 220 px, and its labels (Gale, Tempest, Rime, Scorch, cold, hot) to a
  readable 12 px. No text in the game goes below 11 px.
- **The rain bar shows only what's falling, 0 to 1:** empty when dry, full
  in a downpour. It's as tall as the grid and narrow beside it.
- **In a gear card, rain is a preference, not a level:** "Wants rain" (a
  filled drop), "Wants it dry" (a struck-out drop), or nothing at all for
  gear that doesn't mind. Today it draws a half-full bar for "doesn't mind",
  which reads as half-raining.

## Gear as cards

Hovering a slot (or anything in the Inventory or Character panels) shows a
**card**, always laid out the same way, so you learn where to look:

```
┌──────────────────────────────────┐
│ Weighted Purse              [3]  │  name (rarity colour) · its key
│ Uncommon · Trick                 │  type line
├──────────────────────────────────┤
│            (icon)                │  a drawn icon for its kind
├──────────────────────────────────┤
│ DAMAGE    6 / 9 / 14             │  opener / hit / perfect
│ BEAT      every 1.6 s            │
│ TIMING    ±350 ms · ±120 perfect │
├──────────────────────────────────┤
│ WEATHER              ●●○○○       │
│ ┌────────┐  Best: mild, a light  │
│ │  grid  │  breeze               │
│ │ + ring │  Wants it dry         │
│ └────────┘  +25% at the dot      │
├──────────────────────────────────┤
│ RIGHT NOW · Copperstall          │
│ Weather: near its spot     +13%  │
│ → 7 / 10 / 16 · every 1.6 s      │
├──────────────────────────────────┤
│ "Heavy with coin, and heavier    │  flavour, in italics
│  with intent."                   │
└──────────────────────────────────┘
```

- **Art:** a simple drawn (SVG) icon for each kind of gear (blade, spell,
  trick, potion, shield, light, orb, armour…), tinted by rarity. No image
  files, and it looks the same on every device and in both themes.
- A fixed width (about 300 px), a frame in the rarity colour, and a ruled
  box per section, each with a small heading. Labels and values in two
  columns, so nothing wraps mid-number.
- The same card for slot gear, talents, worn gear (armour and stats in place
  of damage) and items (value, and who wants it, if you know).
- Sections that don't apply are left out, not left empty.

## Build order

1. **Talk:** DISCUSS by target, listing only your topics, the standard
   topics, GREET, and people remembering you.
2. **Quests handed over:** offers written as requests, ACCEPT and DECLINE
   (and `must`), no New quest line, the pinned quest line, and WHATNOW
   (with a `lure` written for every quest giver).
3. **Give:** the GIVE command and refusals, the `give` quest trigger, and
   every quest that hands something to someone moved to it.
4. **Hold, wear and equip.**
5. **Traps:** sign guide text, the new CREEP, DISARM.
6. **Layout:** weather beside the map, the log underneath, the bigger grid,
   the rain bar fix, readable text.
7. **Cards:** the gear card, then worn gear, talents and items.
8. **Trust and trade:** rapport, `requires`, topics that open, spread and
   close, `loot` and item tags, `likes` and gifts, `wants`, haggling, and
   the Wants list. Then write backgrounds, rumours, likes and wants for the
   people of the starting realms and the Greyfold.

## Decided

- **Discuss, not ask:** DISCUSS is the verb (ASK and TALK also work), and
  only topics you qualify for now are listed.
- **Accepting quests:** ACCEPT starts an offered quest. Early quests
  (`"must": true`) can't be declined, and the guide only mentions ACCEPT;
  later quests can be accepted or declined on the spot.
- **Trust:** per-NPC rapport and faction reputation, both usable in a
  topic's `requires`.
- **Topics follow the story:** a quest can open a topic for a while; topics
  spread to people who know about them if you're on good terms; they close
  when the moment has passed.
- **Traps:** read the sign and creep, and you always get past, leaving the
  trap set. Disarming is a check with real consequences, and a disarmed trap
  is safe for everyone until it rearms.
- **Layout:** weather and map share the top, the log runs underneath both,
  and the here-and-now panel runs top to bottom on the right.
- **Card art:** a drawn icon for each kind of gear, tinted by rarity.
- **What now:** a typed command (WHAT NOW or WHATNOW). With a quest, it repeats it; without one,
  it leads you towards the nearest quest giver (met or not, within reason)
  by their `lure`, a hint for the senses with a rough direction and
  distance, never step-by-step directions.
- **Walking into a trap:** the usual check, as today.
- **Haggling:** automatic, from Presence (and Haggler).
- **Rapport** stays; it doesn't fade.
- **People remember you; gifts once per NPC per day.**
- **Lures** come unbidden now and then, and **rumours** can point to quest
  givers.

## What changed while building it

- **Topics are only listed when they're open,** and naming one that isn't
  gets the same brush-off as a topic they never had, so nothing hints it's
  there.
- **Every NPC who talks has `quests` and `rumours`** (and `wants` if they
  buy); creatures don't talk at all. Rumours pick any quest giver within
  reach, not only the nearest.
- **Meeting someone isn't news:** rapport only gets a line when someone
  becomes friendly or trusted, or thinks less of you.
- **WHAT NOW, with the quest giver in the room,** just says so: *"Marta is
  right here, and might have work for you: GREET them."* Straight up or down,
  a lure says *close by* with no direction.
- **Quest updates** are their own event (`quest_update`), so the pinned line
  takes them and the log doesn't.
- **USE <item> ON <someone>** is GIVE, so old habits still work. `UNEQUIP`
  already empties a slot, so REMOVE takes worn gear off.
- **An NPC moved in the seed moves in the world** on the next load (before,
  only new NPCs were placed), which also put Dace at his coach stand on live.
- **The quest helpers** live in a block of their own, so the Talk section
  reaches them through `travel`, and is itself a function rather than a
  do-block: the main chunk had run out of locals.
- **Content written:** quest talk in the starting realms only while it
  matters; backgrounds (some needing rapport), places, rumours and greetings
  for the starting realms' people and the Greyfold's; lures for every quest
  giver; claws, tails, pelts, tusks, haunches and Redcaps' caps from
  creatures, and people who buy them or are glad of them as gifts.

