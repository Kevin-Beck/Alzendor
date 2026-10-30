"""NPCs that fight back, dispositions, reputation, experience, sleeping and the move cooldown."""

from .conftest import drain, enter, texts


def of_type(events, kind):
    return [e for e in events if e["type"] == kind]


async def walk(world, pid, *directions):
    for direction in directions:
        await world.call("move", pid, direction)


async def attack_now(world, nid, n=1):
    """Makes one of an NPC's scheduled attacks due, and runs the combat tick."""
    await world.redis.zadd("alz:npc_attacks", {f"{nid}#{n}": 0})
    await world.call("tick")


async def kill(world, pid, nid, slot=1):
    """Lands one blow on an NPC with 1 HP left (an opener on an unused slot)."""
    await world.redis.hset(f"NPC:{nid}", "hp", 1)
    await world.call("use", pid, slot, f"npc:{nid}")


# Moving -----------------------------------------------------------------------


async def test_moves_have_a_short_cooldown(world):
    await world.redis.hset("alz:rules", "move_cooldown_ms", 60000)
    kevin = await enter(world, "kevin")
    await drain(kevin)
    await walk(world, "kevin", "north", "south", "sideways")
    assert texts(await drain(kevin))[-2:] == ["You need a moment to find your footing.", "You can't go that way."]
    assert await world.redis.get("PLAYER:kevin:room") == "market_square"


# NPCs fighting back ---------------------------------------------------------------


async def test_hostile_npcs_attack_on_sight(world):
    kevin = await enter(world, "kevin")
    await walk(world, "kevin", "east")  # the back alley: an orc warrior (hostile) and a whelp (neutral)
    events = await drain(kevin)
    assert "The Orc Warrior turns on Kevin!" in texts(events)
    timing = of_type(events, "npc_timing")[0]
    assert timing["entity_id"] == "npc:orc-1" and timing["target"] == "pc:kevin"
    assert [(a["name"], a["period_ms"]) for a in timing["attacks"]] == [("cleaver", 6000), ("shield bash", 9000)]
    room = of_type(events, "room")[-1]["room"]
    cards = {c["id"]: c for c in room["entities"]}
    assert cards["npc:orc-1"]["disposition"] == "hostile" and cards["npc:orc-2"]["disposition"] == "neutral"

    await attack_now(world, "orc-1")
    events = await drain(kevin)
    assert texts(events) == ["The Orc Warrior hacks at Kevin with a cleaver. (7)"]
    assert of_type(events, "entity")[0]["entity"]["hp"] == 93
    assert of_type(events, "npc_timing")[0]["attacks"][0]["next_ms"] > timing["attacks"][0]["next_ms"]


async def test_neutral_npcs_fight_back_and_forget_you_when_you_leave(world):
    kevin = await enter(world, "kevin")
    await walk(world, "kevin", "north", "west", "south")  # the fish market's rats are neutral
    assert not of_type(await drain(kevin), "npc_timing")
    await world.redis.hset("NPC:rat-1", "hp", 100)
    await world.call("use", "kevin", 1, "npc:rat-1")
    assert of_type(await drain(kevin), "npc_timing")[0]["target"] == "pc:kevin"
    await attack_now(world, "rat-1")
    assert texts(await drain(kevin)) == ["The Dock Rat nips at Kevin. (1)"]

    await world.call("move", "kevin", "north")
    assert not await world.redis.exists("NPC:rat-1:foes")
    assert not await world.redis.zscore("alz:npc_attacks", "rat-1#1")


async def test_friendly_npcs_cannot_be_attacked_but_can_be_healed(world):
    kevin = await enter(world, "kevin")
    await drain(kevin)
    await world.call("use", "kevin", 1, "marta")
    assert texts(await drain(kevin)) == ["You won't attack Marta."]

    await world.redis.sadd("PLAYER:kevin:gear", "mending")
    await world.call("equip", "kevin", "mending", 3)
    await world.redis.hset("NPC:marta", "hp", 10)
    await world.call("use", "kevin", 3, "npc:marta")
    assert texts(await drain(kevin))[1:] == [
        "Kevin lays glowing hands on Marta. (+8)",
        "The Folk of Harrowgate: They won't forget a kindness. (affinity +4, respect +1)",
    ]
    assert await world.redis.hget("NPC:marta", "hp") == "18"


async def test_npcs_keep_attacking_a_sleeping_body_and_players_wake_at_the_shrine(world):
    kevin = await enter(world, "kevin")
    await walk(world, "kevin", "east")
    await world.call("disconnect", "kevin", "session-kevin", "", "Bye.")  # in the open: Kevin lies down
    await world.redis.hset("ACCOUNT:kevin", mapping={"hp": 5, "xp": 50})
    watcher = await enter(world, "mara")
    await walk(world, "mara", "east")
    await drain(watcher)
    await attack_now(world, "orc-1")
    assert texts(await drain(watcher))[-3:] == [
        "The Orc Warrior hacks at Kevin with a cleaver. (7)", "Kevin collapses.", "Kevin's body fades away.",
    ]
    assert await world.redis.get("PLAYER:kevin:room") == "temple_steps"
    assert await world.redis.hmget("ACCOUNT:kevin", "hp", "xp") == ["50", "40"]  # half health; 10% of a level lost

    again = await enter(world, "kevin", session="again")
    room = of_type(await drain(again), "room")[-1]["room"]
    assert room["id"] == "temple_steps"


async def test_a_defeated_player_wakes_at_the_shrine(world):
    kevin = await enter(world, "kevin")
    await walk(world, "kevin", "east")
    await world.redis.hset("ACCOUNT:kevin", "hp", 3)
    await drain(kevin)
    await attack_now(world, "orc-1")
    events = await drain(kevin)
    assert "You were defeated, and wake at the shrine." in texts(events)
    assert of_type(events, "room")[-1]["room"]["id"] == "temple_steps"
    assert "The Back-Alley Orcs: You were beaten. Weakness. (respect -2)" in texts(events)
    assert not await world.redis.exists("NPC:orc-1:foes")


# Practice ---------------------------------------------------------------------------


async def test_the_training_dummy_never_falls_and_gives_nothing(world):
    kevin = await enter(world, "kevin")
    await walk(world, "kevin", "north", "east", "east")
    await drain(kevin)
    await kill(world, "kevin", "dummy-1")
    assert texts(await drain(kevin)) == ["Kevin kicks the Training Dummy. (4)", "The Training Dummy wobbles back upright."]
    assert await world.redis.hget("NPC:dummy-1", "hp") == "200"
    assert await world.redis.sismember("ROOM:training_yard:npcs", "dummy-1")
    assert not await world.redis.hget("ACCOUNT:kevin", "xp")


# Reputation ---------------------------------------------------------------------------


async def test_cultures_judge_the_same_kill_differently(world):
    kevin = await enter(world, "kevin")
    await walk(world, "kevin", "east")
    await drain(kevin)
    # The orc is already fighting Kevin (it turned on him), so this isn't an ambush.
    await kill(world, "kevin", "orc-1")
    lines = texts(await drain(kevin))
    assert lines[:2] == ["Kevin kicks the Orc Warrior. (4)", "The Orc Warrior collapses."]
    assert "The Folk of Harrowgate: They're glad of one less orc in the alleys. (affinity +3)" in lines
    assert "The Back-Alley Orcs: They hate you for it, but a warrior's death is honourable. (affinity -6, respect +4)" in lines
    assert "You take the Orc Warrior's Greataxe. ('inventory' to equip it.)" in lines
    assert "You gain 60 experience." in lines
    assert await world.redis.hgetall("PLAYER:kevin:rep:orcs") == {"affinity": "-6", "respect": "4"}


async def test_striking_first_is_an_ambush_and_whelps_are_off_limits(world):
    kevin = await enter(world, "kevin")
    await walk(world, "kevin", "east")
    await drain(kevin)
    await kill(world, "kevin", "orc-2")  # neutral, so it wasn't fighting: an ambush, of a whelp
    lines = texts(await drain(kevin))
    assert "The Back-Alley Orcs: Striking first, before they'd drawn a blade, is beneath a warrior. (respect -4)" in lines
    assert "The Back-Alley Orcs: Killing whelps is a coward's work. (affinity -10, respect -10)" in lines
    assert await world.redis.hgetall("PLAYER:kevin:rep:orcs") == {"affinity": "-10", "respect": "-14"}


async def test_respect_can_stay_a_hostile_hand(world):
    await world.redis.hset("PLAYER:kevin:rep:orcs", mapping={"affinity": -40, "respect": 30})
    kevin = await enter(world, "kevin")
    await walk(world, "kevin", "east")
    events = await drain(kevin)
    assert "The Orc Warrior turns on Kevin!" not in texts(events)
    room = of_type(events, "room")[-1]["room"]
    assert {c["id"]: c["disposition"] for c in room["entities"]}["npc:orc-1"] == "neutral"


async def test_presence_moves_reputation_further_and_greetings_count_once(world):
    await world.redis.hset("ACCOUNT:kevin", "stat:presence", 4)  # 60% further
    kevin = await enter(world, "kevin")
    await drain(kevin)
    for _ in range(2):
        await world.call("emote", "kevin", "bow", "marta", "{actor} bows.", "{actor} bows to {target}.")
    assert texts(await drain(kevin)) == [
        "Kevin bows to Marta.", "The Folk of Harrowgate: Good manners go a long way. (affinity +2)", "Kevin bows to Marta.",
    ]


async def test_saying_something_to_your_target(world):
    kevin = await enter(world, "kevin")
    await drain(kevin)
    await world.call("say", "kevin", "Ale, please.", "npc:marta")
    await world.call("say", "kevin", "Hello?", "nobody")
    assert texts(await drain(kevin)) == ['Kevin says to Marta, "Ale, please."', 'Kevin says, "Hello?"']


# Experience ---------------------------------------------------------------------------


async def test_levelling_up_grants_a_point_and_rewards(world):
    kevin = await enter(world, "kevin")
    await walk(world, "kevin", "east")
    await world.redis.hset("ACCOUNT:kevin", "xp", 90)
    await drain(kevin)
    await kill(world, "kevin", "orc-1")
    events = await drain(kevin)
    assert "You reach level 2! You have a stat point to spend: 'train <stat>'. You gain: Sword." in texts(events)
    character = of_type(events, "character")[-1]
    assert (character["level"], character["xp"], character["xp_next"], character["points"]) == (2, 50, 200, 1)
    assert "sword" in [g["id"] for g in of_type(events, "kit")[-1]["gear"]]

    await world.call("train", "kevin", "vigor")
    await world.call("train", "kevin", "vigor")
    lines = texts(await drain(kevin))
    assert lines[:1] == ["Vigor is now 1. Vigor: 8 more max health per point."]
    assert lines[-1] == "You have no stat points to spend. You'll get one each level."
    assert await world.redis.hget("ACCOUNT:kevin", "hp") == "108"


async def test_poise_and_focus_widen_timing_windows(world):
    await world.redis.hset("ACCOUNT:kevin", mapping={"stat:poise": 2, "stat:focus": 3})
    kevin = await enter(world, "kevin")
    await walk(world, "kevin", "north", "east", "east")
    await drain(kevin)
    await world.call("use", "kevin", 1, "npc:dummy-1")
    timing = of_type(await drain(kevin), "timing")[0]
    assert (timing["grace_ms"], timing["perfect_ms"]) == (330, 130)


async def test_wounds_heal_out_of_a_fight_and_faster_somewhere_safe(world):
    kevin = await enter(world, "kevin")
    await world.redis.hset("ACCOUNT:kevin", "hp", 50)
    await world.redis.sadd("alz:wounded", "kevin")
    await world.call("upkeep")  # in the tavern: safe
    await world.call("move", "kevin", "north")
    await world.call("upkeep")
    assert await world.redis.hget("ACCOUNT:kevin", "hp") == "62"


# Leaving ------------------------------------------------------------------------------


async def test_leaving_in_the_open_leaves_a_sleeping_body_for_a_while(world):
    kevin, mara = await enter(world, "kevin"), await enter(world, "mara")
    await walk(world, "kevin", "north")
    await walk(world, "mara", "north")
    await drain(mara)
    await world.call("disconnect", "kevin", "session-kevin", "", "Bye.")
    update = of_type(await drain(mara), "entity")[0]
    assert update["text"] == "Kevin lies down to rest." and update["entity"]["asleep"] is True
    assert await world.redis.sismember("ROOM:market_square:players", "kevin")

    # Coming back before it fades: Kevin wakes where he lay.
    await enter(world, "kevin", session="again")
    assert texts(await drain(mara)) == ["Kevin wakes and gets up."]
    await world.call("disconnect", "kevin", "again", "", "Bye.")
    await world.redis.zadd("alz:sleepers", {"kevin": 0})
    await world.call("upkeep")
    assert texts(await drain(mara))[-1] == "Kevin's sleeping form fades away."
    assert not await world.redis.sismember("ROOM:market_square:players", "kevin")
    await enter(world, "kevin", session="third")
    assert texts(await drain(mara)) == ["Kevin arrives, well rested."]


async def test_woodcraft_makes_any_forest_a_safe_place(world):
    kevin = await enter(world, "kevin")
    await walk(world, "kevin", "north", "north", "north", "north", "northwest")  # the mossy clearing
    await world.redis.sadd("PLAYER:kevin:perks", "woodcraft")
    room = of_type(await drain(kevin), "room")[-1]["room"]
    assert room["safe"] is False  # the view was sent before he learned it
    await world.call("disconnect", "kevin", "session-kevin", "", "Bye.")
    assert texts(await drain(kevin))[-1] == "Kevin settles in to rest, and is gone."
    assert not await world.redis.zscore("alz:sleepers", "kevin")
