"""Quest machinery the content leans on: counted steps, steps waiting on the
weather, offers declined and taken up again, and the costs and background
bonuses of travel-event choices."""

from .conftest import drain, enter, hit, set_weather, texts
from .test_journeys import board_coach, only_event


def of_type(events, kind):
    return [e for e in events if e["type"] == kind]


async def start(world, pid, qid, step=None, count=0):
    await world.redis.hset(f"PLAYER:{pid}:quests", qid, "active")
    first = step or await world.redis.hget(f"QUEST:{qid}", "start") or "kill"
    await world.redis.hset(f"PLAYER:{pid}:quest:{qid}", mapping={"step": first, "count": count, "since": 0})


async def kill(world, pid, nid):
    await world.redis.hset(f"NPC:{nid}", "hp", 1)
    await hit(world, pid, f"npc:{nid}")


async def test_a_counted_step_waits_for_its_count_then_starts_the_next_afresh(world):
    kevin = await enter(world, "kevin")
    await world.call("goto", "kevin", "ff_orchard")
    await start(world, "kevin", "gf_boars", "kill")  # four boars
    await drain(kevin)
    await kill(world, "kevin", "wild_boar_1")
    updates = [e["text"] for e in of_type(await drain(kevin), "quest_update")]
    assert updates == ["Rooting Boars: 1 / 4"]
    assert await world.redis.hmget("PLAYER:kevin:quest:gf_boars", "step", "count") == ["kill", "1"]
    await world.redis.hset("PLAYER:kevin:quest:gf_boars", "count", 3)  # two more since
    await kill(world, "kevin", "wild_boar_2")
    assert await world.redis.hmget("PLAYER:kevin:quest:gf_boars", "step", "count") == ["back", "0"]


async def test_a_step_waiting_on_the_weather_finishes_when_the_weather_comes(world):
    kevin = await enter(world, "kevin")
    await start(world, "kevin", "gm_stones", "one")  # the Leaning Stone, while the wind is up
    await set_weather(world.redis, "alzendor", 0, -1, -1)  # dead calm
    await world.call("goto", "kevin", "gm_stone_1")
    assert await world.redis.hget("PLAYER:kevin:quest:gm_stones", "step") == "one"
    await set_weather(world.redis, "alzendor", 0, 0.8, -1)  # the wind gets up, and the player hasn't moved
    await drain(kevin)
    await world.call("weather_tick")
    assert await world.redis.hget("PLAYER:kevin:quest:gm_stones", "step") == "two"


async def test_a_declined_offer_is_made_again_and_accepted_only_beside_its_giver(world):
    kevin = await enter(world, "kevin")
    await world.call("goto", "kevin", "mb_tannery")
    await world.redis.hset("PLAYER:kevin:offer", mapping={"quest": "gf_wolfmother", "npc": "cobb"})
    await world.call("decline", "kevin")
    assert not await world.redis.exists("PLAYER:kevin:offer")
    # Cobb remembers he has work for you, and asks again.
    await world.call("discuss", "kevin", "cobb", "quests")
    assert await world.redis.hgetall("PLAYER:kevin:offer") == {"quest": "gf_wolfmother", "npc": "cobb"}
    # Walk away and ACCEPT: you have to go back to him.
    await world.call("move", "kevin", next(iter(await world.redis.hkeys("ROOM:mb_tannery:exits"))))
    await world.call("accept", "kevin")
    assert await world.redis.hget("PLAYER:kevin:quests", "gf_wolfmother") is None
    await world.call("goto", "kevin", "mb_tannery")
    await world.call("accept", "kevin")
    assert await world.redis.hget("PLAYER:kevin:quests", "gf_wolfmother") == "active"


async def test_a_paid_choice_costs_its_coins(world):
    await only_event(world, "toll")
    kevin = await enter(world, "kevin")
    await world.redis.hset("ACCOUNT:kevin", "coins", 10)
    await board_coach(world, "kevin")  # the fare is 3
    await drain(kevin)
    before = int(await world.redis.hget("ACCOUNT:kevin", "coins"))
    await world.call("choose", "kevin", "1")  # pay the toll: 2
    assert int(await world.redis.hget("ACCOUNT:kevin", "coins")) == before - 2


async def test_a_background_makes_its_own_choices_likelier(world):
    await only_event(world, "rut")
    await set_weather(world.redis, "alzendor", 0, 0, 0.2)  # mud
    results = {}
    for background in ("sailor", "woodsman"):  # a woodsman knows how to free a stuck wheel
        pid = f"p{background}"
        feed = await enter(world, pid)
        await world.redis.hset(f"ACCOUNT:{pid}", "background", background)
        await board_coach(world, pid)
        await drain(feed)
        await world.redis.rpush("alz:test_rolls", 0.5)  # misses fair (30%), makes it with the bonus (+35%)
        await world.call("choose", pid, "1")
        results[background] = any("the wheel comes free" in t for t in texts(await drain(feed)))
    assert results == {"sailor": False, "woodsman": True}
