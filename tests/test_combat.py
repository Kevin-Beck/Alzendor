"""Combat slots, against Redis's real clock (tests wait for actual beats)."""

import asyncio

from .conftest import drain, enter, texts

PERIOD = 1000  # ms between kick beats in these tests; kicks hit within 300 ms, perfect within 100


async def redis_ms(redis) -> float:
    seconds, micros = await redis.time()
    return seconds * 1000 + micros / 1000


async def wait_until(redis, when_ms: float) -> None:
    delay = (when_ms - await redis_ms(redis)) / 1000
    if delay > 0:
        await asyncio.sleep(delay)


async def at_fish_market(world, pid="kevin"):
    """A player standing with the two dock rats, with the starting loadout: kick, magic missile, health potion."""
    await world.redis.hset("GEAR:kick", "period", PERIOD)
    await world.redis.hset("GEAR:potion", "period", PERIOD)
    feed = await enter(world, pid)
    for direction in ("north", "west", "south"):
        await world.call("move", pid, direction)
    await drain(feed)
    return feed


async def started(world, slot=1, pid="kevin") -> int:
    return int(await world.redis.hget(f"PLAYER:{pid}:slot:{slot}", "start"))


def of_type(events, kind):
    return [e for e in events if e["type"] == kind]


async def test_connecting_announces_every_slot(world):
    kevin = await enter(world, "kevin")
    timings = of_type(await drain(kevin), "timing")
    assert [(t["slot"], t["gear"], t["label"], t["active"]) for t in timings] == [
        (1, "kick", "Kick", False), (2, "missile", "Magic Missile", False), (3, "potion", "Health Potion", False),
    ]
    assert timings[0]["period_ms"] == 2000


async def test_the_opening_use_lands_and_starts_the_rhythm(world):
    kevin = await at_fish_market(world)
    await world.call("use", "kevin", 1, "npc:rat-2")
    events = await drain(kevin)
    assert texts(events) == ["Kevin kicks the Dock Rat. (4)"]
    assert of_type(events, "combat")[0]["slot"] == 1
    assert of_type(events, "entity")[0]["entity"]["hp"] == 1
    timing = of_type(events, "timing")[0]
    assert (timing["slot"], timing["active"]) == (1, True)
    assert (timing["period_ms"], timing["grace_ms"], timing["perfect_ms"], timing["last_beat"]) == (PERIOD, 300, 100, 0)


async def test_uses_land_on_the_beat_and_mashing_misses(world):
    kevin = await at_fish_market(world)
    await world.redis.hset("NPC:rat-1", "hp", 100)
    await world.call("use", "kevin", 1, "npc:rat-1")
    start = await started(world)
    await drain(kevin)

    # Straight away: too early, and it uses up beat 1.
    await world.call("use", "kevin", 1, "npc:rat-1")
    events = await drain(kevin)
    assert texts(events) == ["Too early: your kick goes wide.", "Kevin kicks at the Dock Rat and misses."]
    assert of_type(events, "timing")[0]["last_beat"] == 1

    # Right on beat 2: perfect.
    await wait_until(world.redis, start + 2 * PERIOD)
    await world.call("use", "kevin", 1, "npc:rat-1")
    assert texts(await drain(kevin)) == ["Kevin lands a perfect kick on the Dock Rat! (9)"]  # 8, +12% on a mild coastal day

    # A little after beat 3: still inside the window.
    await wait_until(world.redis, start + 3 * PERIOD + 200)
    await world.call("use", "kevin", 1, "npc:rat-1")
    assert texts(await drain(kevin)) == ["Kevin kicks the Dock Rat. (6)"]

    # Well after beat 4: too late.
    await wait_until(world.redis, start + 4 * PERIOD + 450)
    await world.call("use", "kevin", 1, "npc:rat-1")
    assert texts(await drain(kevin))[0] == "Too late: your kick goes wide."
    assert await world.redis.hget("NPC:rat-1", "hp") == str(100 - 4 - 9 - 6)


async def test_each_slot_keeps_its_own_beat(world):
    kevin = await at_fish_market(world)
    await world.redis.hset("NPC:rat-1", "hp", 100)
    await world.call("use", "kevin", 1, "npc:rat-1")
    # Slot 2 hasn't started, so magic missile opens it and lands at once.
    await world.call("use", "kevin", 2, "npc:rat-1")
    events = await drain(kevin)
    assert texts(events) == ["Kevin kicks the Dock Rat. (4)", "Kevin hurls a magic missile at the Dock Rat. (15)"]
    assert [(t["slot"], t["period_ms"], t["grace_ms"]) for t in of_type(events, "timing")] == [
        (1, PERIOD, 300), (2, 8000, 400),
    ]
    # Mashing slot 2 burns one of its beats but leaves slot 1 alone.
    await world.call("use", "kevin", 2, "npc:rat-1")
    assert texts(await drain(kevin))[0] == "Too early: your magic missile fizzles."
    assert await world.redis.hget("PLAYER:kevin:slot:1", "beat") == "0"
    assert await world.redis.hget("PLAYER:kevin:slot:2", "beat") == "1"


async def test_the_same_gear_in_two_slots_keeps_two_rhythms(world):
    kevin = await at_fish_market(world)
    await world.redis.hset("NPC:rat-1", "hp", 100)
    await world.call("equip", "kevin", "kick", 2)
    await world.call("use", "kevin", 1, "npc:rat-1")
    await world.call("use", "kevin", 2, "npc:rat-1")
    assert texts(await drain(kevin))[-2:] == ["Kevin kicks the Dock Rat. (4)", "Kevin kicks the Dock Rat. (4)"]


async def test_healing_gear_works_on_its_own_beat(world):
    kevin = await at_fish_market(world)
    await world.redis.hset("ACCOUNT:kevin", mapping={"hp": 70, "max_hp": 100})
    await world.call("use", "kevin", 3, "npc:rat-1")  # a target makes no difference to a potion
    events = await drain(kevin)
    assert texts(events) == ["Kevin drinks a health potion. (+11)"]
    assert of_type(events, "heal")[0]["slot"] == 3

    await world.call("use", "kevin", 3, "")  # mashing
    assert texts(await drain(kevin))[0] == "Too early: you fumble the potion and spill it."

    await wait_until(world.redis, await started(world, 3) + 2 * PERIOD)
    await world.call("use", "kevin", 3, "")
    assert texts(await drain(kevin)) == ["Kevin downs a health potion in one perfect gulp! (+19)"]  # capped at 100
    assert await world.redis.hget("ACCOUNT:kevin", "hp") == "100"


async def test_npcs_go_down_and_come_back(world):
    kevin = await at_fish_market(world)
    await world.call("use", "kevin", 1, "npc:rat-1")
    start = await started(world)
    await wait_until(world.redis, start + PERIOD)
    await world.call("use", "kevin", 1, "npc:rat-1")
    events = await drain(kevin)
    death = of_type(events, "death")
    assert death[0]["entity_id"] == "npc:rat-1" and death[0]["text"] == "The Dock Rat collapses."
    assert of_type(events, "timing")[-1]["active"] is True  # still in the rhythm
    assert not await world.redis.sismember("ROOM:fish_market:npcs", "rat-1")
    assert await world.redis.zscore("alz:respawns", "rat-1") > start

    # A fresh target is no excuse for an instant opener: it waits for a beat too.
    await world.call("use", "kevin", 1, "npc:rat-2")
    assert texts(await drain(kevin))[0] == "Too early: your kick goes wide."

    await world.call("respawn")  # not due yet
    assert not await world.redis.sismember("ROOM:fish_market:npcs", "rat-1")
    await world.redis.zadd("alz:respawns", {"rat-1": 0})
    await world.call("respawn")
    arrive = of_type(await drain(kevin), "arrive")[0]
    assert arrive["text"] == "The Dock Rat appears." and arrive["entity"]["hp"] == 5
    assert await world.redis.sismember("ROOM:fish_market:npcs", "rat-1")


async def test_only_npcs_can_be_attacked(world):
    kevin = await at_fish_market(world)
    mara = await enter(world, "mara")
    for direction in ("north", "west", "south"):
        await world.call("move", "mara", direction)
    await drain(kevin), await drain(mara)
    for target in ("mara", "ice", "me", "orc", ""):
        await world.call("use", "kevin", 1, target)
    assert texts(await drain(kevin)) == [
        "You can't attack other players.", "You can't fight that.", "You think better of it.", "You don't see that here.",
        "Kick what? Name a target, or press Tab to pick one.",
    ]
    assert not await world.redis.exists("PLAYER:kevin:slot:1")


async def test_stepping_out_and_back_does_not_reset_the_rhythm(world):
    kevin = await at_fish_market(world)
    await world.call("use", "kevin", 1, "npc:rat-1")
    await world.call("move", "kevin", "north")
    await world.call("move", "kevin", "south")
    await world.call("use", "kevin", 1, "npc:rat-2")
    assert texts(await drain(kevin))[-2:] == ["Too early: your kick goes wide.", "Kevin kicks at the Dock Rat and misses."]


async def test_reconnecting_does_not_reset_the_rhythm(world):
    kevin = await at_fish_market(world)
    await world.call("use", "kevin", 1, "npc:rat-1")
    await world.call("disconnect", "kevin", "session-kevin", "", "Bye.")
    again = await enter(world, "kevin", session="again")
    timings = of_type(await drain(again), "timing")
    assert [t["active"] for t in timings] == [True, False, False]  # slot 1 is still going
    await world.call("use", "kevin", 1, "npc:rat-1")
    assert texts(await drain(again))[0] == "Too early: your kick goes wide."


# Equipping ---------------------------------------------------------------------


async def test_equipping_changes_a_slots_gear_and_timing(world):
    kevin = await enter(world, "kevin")
    await drain(kevin)
    await world.call("equip", "kevin", "dagger", 1)
    events = await drain(kevin)
    assert texts(events) == ["Slot 1: Dagger, every 1.2s."]
    timing = of_type(events, "timing")[0]
    assert (timing["slot"], timing["gear"], timing["active"], timing["period_ms"]) == (1, "dagger", False, 1200)
    assert of_type(events, "kit")[0]["slots"] == ["dagger", "missile", "potion"]
    assert await world.redis.hget("PLAYER:kevin:slots", "1") == "dagger"

    await world.call("equip", "kevin", "magic missile", 1)  # by name, or keyword
    await world.call("equip", "kevin", "axe", 1)  # not owned yet
    await world.redis.sadd("PLAYER:kevin:gear", "greataxe")
    await world.call("equip", "kevin", "axe", 1)
    await world.call("equip", "kevin", "axe", 1)
    await world.call("equip", "kevin", "banjo", 1)
    await world.call("equip", "kevin", "dagger", 4)
    assert texts(await drain(kevin)) == [
        "Slot 1: Magic Missile, every 8.0s.", "You don't have Greataxe.", "Slot 1: Greataxe, every 4.5s.",
        "Slot 1 already holds Greataxe.", "There's no gear called 'banjo'. Type GEAR to see what you have.",
        "Your slots are 1, 2 and 3.",
    ]


async def test_equip_without_a_slot_fills_the_first_empty_one(world):
    kevin = await enter(world, "kevin")
    await world.call("equip", "kevin", "dagger", "")
    await world.call("unequip", "kevin", 2)
    await world.call("equip", "kevin", "dagger", "")
    await world.call("use", "kevin", 2, "")
    await drain(kevin)
    assert await world.redis.hgetall("PLAYER:kevin:slots") == {"1": "kick", "2": "dagger", "3": "potion"}
    await world.call("unequip", "kevin", 2)
    await world.call("unequip", "kevin", 2)
    await world.call("use", "kevin", 2, "orc")
    assert texts(await drain(kevin)) == [
        "Slot 2 is empty now.", "Slot 2 is already empty.",
        "Slot 2 is empty. Try EQUIP <gear> 2, or GEAR to see what you have.",
    ]


async def test_a_full_loadout_needs_a_slot_number(world):
    kevin = await enter(world, "kevin")
    await drain(kevin)
    await world.call("equip", "kevin", "dagger", "")
    assert texts(await drain(kevin)) == ["Your slots are full. Say which one to replace: 'equip dagger 1', 2 or 3."]


async def test_a_slot_in_rhythm_cannot_be_swapped(world):
    kevin = await at_fish_market(world)
    await world.call("use", "kevin", 1, "npc:rat-1")
    await world.redis.delete("PLAYER:kevin:foes")  # the rat loses interest; only the rhythm holds the slot
    await world.call("equip", "kevin", "dagger", 1)
    await world.call("unequip", "kevin", 1)
    await world.call("equip", "kevin", "dagger", 2)  # slot 2 hasn't been used
    events = await drain(kevin)
    assert texts(events)[1:] == [
        "Slot 1 is still in rhythm. It settles 10s after its last use.",
        "Slot 1 is still in rhythm. It settles 10s after its last use.",
        "Slot 2: Dagger, every 1.2s.",
    ]
    assert await world.redis.hget("PLAYER:kevin:slots", "1") == "kick"


async def test_the_starting_loadout_is_only_given_once(world):
    kevin = await enter(world, "kevin")
    await world.call("unequip", "kevin", 3)
    await world.call("disconnect", "kevin", "session-kevin", "", "Bye.")
    again = await enter(world, "kevin", session="again")
    assert [t["label"] for t in of_type(await drain(again), "timing")] == ["Kick", "Magic Missile", "Empty"]


async def test_gear_lists_what_you_own_fastest_first(world):
    kevin = await enter(world, "kevin")
    await drain(kevin)
    await world.call("gear", "kevin")
    event = of_type(await drain(kevin), "gear")[0]
    assert [g["id"] for g in event["gear"]] == ["dagger", "kick", "potion", "missile"]
    assert event["slots"] == ["kick", "missile", "potion"]
    lines = event["text"].split("\n")
    # Indoors it's always dead neutral and dry: grey gear at its best, and the frost
    # dagger far from its cold, still spot but glad of the dry air.
    assert "  Dagger (weapon, green): every 1.2s, ±200ms, 3 / 6 damage [weather +12%]" in lines
    assert "  Health Potion (potion, grey): every 5.0s, ±350ms, heals 17 / 29 [weather +15%]" in lines
    assert lines[-1].startswith("Your slots: 1 Kick · 2 Magic Missile · 3 Health Potion.")
