"""Combat rhythms, against Redis's real clock (tests wait for actual beats)."""

import asyncio

from .conftest import drain, enter, texts

PERIOD = 1000  # ms between melee beats for the test player; melee hits within 300 ms, perfect within 100


async def redis_ms(redis) -> float:
    seconds, micros = await redis.time()
    return seconds * 1000 + micros / 1000


async def wait_until(redis, when_ms: float) -> None:
    delay = (when_ms - await redis_ms(redis)) / 1000
    if delay > 0:
        await asyncio.sleep(delay)


async def at_fish_market(world, pid="kevin"):
    """A player standing with the two dock rats."""
    await world.redis.hset(f"ACCOUNT:{pid}", "period:melee", PERIOD)
    feed = await enter(world, pid)
    for direction in ("north", "west", "south"):
        await world.call("move", pid, direction)
    await drain(feed)
    return feed


async def started(world, rhythm="melee", pid="kevin") -> int:
    return int(await world.redis.hget(f"PLAYER:{pid}:rhythm:{rhythm}", "start"))


def of_type(events, kind):
    return [e for e in events if e["type"] == kind]


async def test_connecting_announces_every_rhythm(world):
    kevin = await enter(world, "kevin")
    timings = of_type(await drain(kevin), "timing")
    assert [(t["rhythm"], t["label"], t["active"]) for t in timings] == [
        ("melee", "Melee", False), ("spell", "Spells", False), ("potion", "Potions", False),
    ]
    assert timings[0]["hint"] == "k to kick"


async def test_the_opening_kick_lands_and_starts_the_rhythm(world):
    kevin = await at_fish_market(world)
    await world.call("attack", "kevin", "kick", "npc:rat-2")
    events = await drain(kevin)
    assert texts(events) == ["Kevin kicks the Dock Rat. (4)"]
    assert of_type(events, "entity")[0]["entity"]["hp"] == 1
    timing = of_type(events, "timing")[0]
    assert (timing["rhythm"], timing["active"]) == ("melee", True)
    assert (timing["period_ms"], timing["grace_ms"], timing["perfect_ms"], timing["last_beat"]) == (PERIOD, 300, 100, 0)


async def test_kicks_land_on_the_beat_and_mashing_misses(world):
    kevin = await at_fish_market(world)
    await world.redis.hset("NPC:rat-1", "hp", 100)
    await world.call("attack", "kevin", "kick", "npc:rat-1")
    start = await started(world)
    await drain(kevin)

    # Straight away: too early, and it uses up beat 1.
    await world.call("attack", "kevin", "kick", "npc:rat-1")
    events = await drain(kevin)
    assert texts(events) == ["Too early: your kick goes wide.", "Kevin kicks at the Dock Rat and misses."]
    assert of_type(events, "timing")[0]["last_beat"] == 1

    # Right on beat 2: perfect.
    await wait_until(world.redis, start + 2 * PERIOD)
    await world.call("attack", "kevin", "kick", "npc:rat-1")
    assert texts(await drain(kevin)) == ["Kevin lands a perfect kick on the Dock Rat! (8)"]

    # A little after beat 3: still inside the grace window.
    await wait_until(world.redis, start + 3 * PERIOD + 200)
    await world.call("attack", "kevin", "kick", "npc:rat-1")
    assert texts(await drain(kevin)) == ["Kevin kicks the Dock Rat. (5)"]

    # Well after beat 4: too late.
    await wait_until(world.redis, start + 4 * PERIOD + 450)
    await world.call("attack", "kevin", "kick", "npc:rat-1")
    assert texts(await drain(kevin))[0] == "Too late: your kick goes wide."
    assert await world.redis.hget("NPC:rat-1", "hp") == str(100 - 4 - 8 - 5)


async def test_each_rhythm_keeps_its_own_beat(world):
    kevin = await at_fish_market(world)
    await world.redis.hset("NPC:rat-1", "hp", 100)
    await world.call("attack", "kevin", "kick", "npc:rat-1")
    # The spell rhythm hasn't started, so magic missile opens it and lands at once.
    await world.call("attack", "kevin", "missile", "npc:rat-1")
    events = await drain(kevin)
    assert texts(events) == ["Kevin kicks the Dock Rat. (4)", "Kevin hurls a magic missile at the Dock Rat. (10)"]
    assert [(t["rhythm"], t["period_ms"], t["grace_ms"]) for t in of_type(events, "timing")] == [
        ("melee", PERIOD, 300), ("spell", 8000, 400),
    ]
    # Mashing the spell burns a spell beat but leaves melee alone.
    await world.call("attack", "kevin", "missile", "npc:rat-1")
    assert texts(await drain(kevin))[0] == "Too early: your magic missile fizzles."
    assert await world.redis.hget("PLAYER:kevin:rhythm:melee", "beat") == "0"
    assert await world.redis.hget("PLAYER:kevin:rhythm:spell", "beat") == "1"


async def test_potions_heal_on_their_own_beat(world):
    kevin = await at_fish_market(world)
    await world.redis.hset("ACCOUNT:kevin", mapping={"hp": 70, "max_hp": 100, "period:potion": PERIOD})
    await world.call("drink", "kevin")
    events = await drain(kevin)
    assert texts(events) == ["Kevin drinks a health potion. (+10)"]
    assert of_type(events, "timing")[0]["rhythm"] == "potion"

    await world.call("drink", "kevin")  # mashing
    assert texts(await drain(kevin))[0] == "Too early: you fumble the potion and spill it."

    await wait_until(world.redis, await started(world, "potion") + 2 * PERIOD)
    await world.call("drink", "kevin")
    assert texts(await drain(kevin)) == ["Kevin downs a health potion in one perfect gulp! (+20)"]  # capped at 100
    assert await world.redis.hget("ACCOUNT:kevin", "hp") == "100"


async def test_npcs_go_down_and_come_back(world):
    kevin = await at_fish_market(world)
    await world.call("attack", "kevin", "kick", "npc:rat-1")
    start = await started(world)
    await wait_until(world.redis, start + PERIOD)
    await world.call("attack", "kevin", "kick", "npc:rat-1")
    events = await drain(kevin)
    death = of_type(events, "death")
    assert death[0]["entity_id"] == "npc:rat-1" and death[0]["text"] == "The Dock Rat collapses."
    assert of_type(events, "timing")[-1]["active"] is True  # still in the rhythm
    assert not await world.redis.sismember("ROOM:fish_market:npcs", "rat-1")
    assert await world.redis.zscore("alz:respawns", "rat-1") > start

    # A fresh target is no excuse for an instant opener: it waits for a beat too.
    await world.call("attack", "kevin", "kick", "npc:rat-2")
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
    for target in ("mara", "ice", "me", "orc"):
        await world.call("attack", "kevin", "kick", target)
    assert texts(await drain(kevin)) == [
        "You can't attack other players.", "You can't fight that.", "You think better of it.", "You don't see that here.",
    ]
    assert not await world.redis.exists("PLAYER:kevin:rhythm:melee")


async def test_stepping_out_and_back_does_not_reset_the_rhythm(world):
    kevin = await at_fish_market(world)
    await world.call("attack", "kevin", "kick", "npc:rat-1")
    await world.call("move", "kevin", "north")
    await world.call("move", "kevin", "south")
    await world.call("attack", "kevin", "kick", "npc:rat-2")
    assert texts(await drain(kevin))[-2:] == ["Too early: your kick goes wide.", "Kevin kicks at the Dock Rat and misses."]


async def test_reconnecting_does_not_reset_the_rhythm(world):
    kevin = await at_fish_market(world)
    await world.call("attack", "kevin", "kick", "npc:rat-1")
    await world.call("disconnect", "kevin", "session-kevin", "", "Bye.")
    again = await enter(world, "kevin", session="again")
    timings = of_type(await drain(again), "timing")
    assert [t["active"] for t in timings] == [True, False, False]  # melee is still going
    await world.call("attack", "kevin", "kick", "npc:rat-1")
    assert texts(await drain(again))[0] == "Too early: your kick goes wide."
