"""NPCs that fight back, dispositions, reputation, experience, sleeping and the move cooldown."""

from .conftest import blow, drain, enter, flee, hit, texts


def of_type(events, kind):
    return [e for e in events if e["type"] == kind]


async def walk(world, pid, *directions):
    for direction in directions:
        await world.call("move", pid, direction)


async def kill(world, pid, nid, slot=1):
    """Lands one strike (edge) on an NPC with 1 HP left."""
    await world.redis.hset(f"NPC:{nid}", "hp", 1)
    await hit(world, pid, f"npc:{nid}", slot)


# Moving -----------------------------------------------------------------------


# NPCs fighting back ---------------------------------------------------------------


async def test_hostile_npcs_attack_on_sight(world):
    kevin = await enter(world, "kevin")
    await walk(world, "kevin", "east")  # the back alley: an orc warrior (hostile) and a whelp (neutral)
    events = await drain(kevin)
    assert "The Orc Warrior turns on Kevin!" in texts(events)
    start = [e for e in of_type(events, "encounter") if e["op"] == "start"][0]["encounter"]
    assert [n["nid"] for n in start["npcs"]] == ["orc-1"]  # the whelp isn't hostile
    assert [(a["name"], a["period"]) for a in start["npcs"][0]["attacks"]] == [("cleaver", 7500), ("shield bash", 11200)]
    room = of_type(events, "room")[-1]["room"]
    cards = {c["id"]: c for c in room["entities"]}
    assert cards["npc:orc-1"]["disposition"] == "hostile" and cards["npc:orc-2"]["disposition"] == "neutral"

    await blow(world, "orc-1")
    events = await drain(kevin)
    assert texts(events) == ["The Orc Warrior hacks at Kevin with a cleaver. (7)"]
    assert of_type(events, "entity")[0]["entity"]["hp"] == 93


async def test_neutral_npcs_fight_back_and_stay_when_you_flee(world):
    kevin = await enter(world, "kevin")
    await walk(world, "kevin", "north", "west", "south")  # the fish market's rats are neutral
    assert not await world.redis.get("PLAYER:kevin:encounter")
    await world.redis.hset("NPC:rat-1", "hp", 100)
    await world.call("use", "kevin", 1, "npc:rat-1")  # striking first starts a fight
    eid = await world.redis.get("PLAYER:kevin:encounter")
    assert await world.redis.get("NPC:rat-1:encounter") == eid
    await drain(kevin)
    await blow(world, "rat-1")
    assert texts(await drain(kevin)) == ["The Dock Rat nips at Kevin. (1)"]

    await flee(world, "kevin", "north")
    assert await world.redis.get("PLAYER:kevin:room") == "harbor_road"
    assert not await world.redis.exists("NPC:rat-1:encounter", f"ENC:{eid}")


async def test_friendly_npcs_cannot_be_attacked_but_can_be_healed(world):
    kevin = await enter(world, "kevin")
    await drain(kevin)
    await world.call("use", "kevin", 1, "marta")
    assert texts(await drain(kevin)) == ["You won't attack Marta."]

    await world.redis.sadd("PLAYER:kevin:gear", "mending")
    await world.call("equip", "kevin", "mending", 3)
    await world.redis.hset("NPC:marta", "hp", 10)
    await world.call("use", "kevin", 3, "npc:marta")  # out of a fight: its clean amount
    assert texts(await drain(kevin))[1:] == [
        "Kevin lays glowing hands on Marta. (+11)",  # a rain spell, in the dry (neutral) tavern
        "The Folk of Harrowgate: They won't forget a kindness. (affinity +4, respect +1)",
    ]
    assert await world.redis.hget("NPC:marta", "hp") == "21"


async def test_leaving_the_world_mid_fight_is_no_escape(world):
    kevin = await enter(world, "kevin")
    await walk(world, "kevin", "east")
    eid = await world.redis.get("PLAYER:kevin:encounter")
    await world.call("disconnect", "kevin", "session-kevin", "", "Bye.")
    # The body lies down and stays in the fight, taking its blows.
    assert await world.redis.hget("ACCOUNT:kevin", "asleep") == "1"
    assert await world.redis.get("PLAYER:kevin:encounter") == eid
    await world.redis.hset("ACCOUNT:kevin", "hp", 90)
    await blow(world, "orc-1")
    assert int(await world.redis.hget("ACCOUNT:kevin", "hp")) < 90
    # Back in time, they wake in the fight, and are told so.
    back = await enter(world, "kevin", session="again")
    starts = [e for e in of_type(await drain(back), "encounter") if e["op"] == "start"]
    assert starts and starts[-1]["id"] == eid and starts[-1]["resumed"]


async def test_a_sleeping_body_leaves_the_fight_when_it_fades(world):
    await enter(world, "kevin")
    await walk(world, "kevin", "east")
    eid = await world.redis.get("PLAYER:kevin:encounter")
    await world.call("disconnect", "kevin", "session-kevin", "", "Bye.")
    await world.redis.zadd("alz:sleepers", {"kevin": 0})  # sleep_seconds have passed
    await world.call("upkeep")
    assert not await world.redis.exists("PLAYER:kevin:encounter", f"ENC:{eid}")
    assert not await world.redis.sismember("ROOM:back_alley:players", "kevin")


async def test_leaving_somewhere_safe_mid_fight_still_leaves_a_body(world):
    await enter(world, "kevin")
    await world.call("encounter_start", "tavern", "pve", "", "kevin", "orc-1")  # trouble in the tavern
    assert await world.redis.get("PLAYER:kevin:encounter")
    await world.call("disconnect", "kevin", "session-kevin", "", "Bye.")
    assert await world.redis.sismember("ROOM:tavern:players", "kevin")
    assert await world.redis.hget("ACCOUNT:kevin", "asleep") == "1"


async def test_an_npc_left_wounded_heals_and_stops_bleeding(world):
    await enter(world, "kevin")
    await walk(world, "kevin", "east")
    await world.redis.hset("NPC:orc-1", "hp", 20)
    await world.redis.hset("NPC:orc-1:bleed", mapping={"damage": 3, "beats": 3})
    await world.call("disconnect", "kevin", "session-kevin", "", "Bye.")
    await world.redis.zadd("alz:sleepers", {"kevin": 0})
    await world.call("upkeep")  # the body fades; the fight is over
    assert not await world.redis.exists("NPC:orc-1:bleed")
    max_hp = int(await world.redis.hget("NPC:orc-1", "max_hp"))
    for _ in range(25):
        await world.call("upkeep")
    assert int(await world.redis.hget("NPC:orc-1", "hp")) == max_hp
    assert not await world.redis.sismember("alz:wounded_npcs", "orc-1")


async def test_a_defeated_player_wakes_at_the_shrine(world):
    kevin = await enter(world, "kevin")
    await walk(world, "kevin", "east")
    await world.redis.hset("ACCOUNT:kevin", mapping={"hp": 3, "xp": 50})
    await drain(kevin)
    await blow(world, "orc-1")
    events = await drain(kevin)
    assert "You were defeated, and wake at the shrine, 10 experience poorer." in texts(events)
    assert of_type(events, "room")[-1]["room"]["id"] == "temple_steps"
    assert "The Back-Alley Orcs: You were beaten. Weakness. (respect -2)" in texts(events)
    assert await world.redis.hmget("ACCOUNT:kevin", "hp", "xp") == ["50", "40"]  # half health; 10% of a level lost
    assert not await world.redis.exists("NPC:orc-1:encounter", "PLAYER:kevin:encounter")


# Practice ---------------------------------------------------------------------------


async def test_the_training_dummy_never_falls_and_gives_nothing(world):
    kevin = await enter(world, "kevin")
    await walk(world, "kevin", "north", "east", "east")
    await drain(kevin)
    await kill(world, "kevin", "dummy-1")
    assert texts(await drain(kevin)) == ["Kevin kicks the Training Dummy. (5)", "The Training Dummy wobbles back upright."]
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
    assert lines[:2] == ["Kevin kicks the Orc Warrior. (5)", "The Orc Warrior collapses."]
    assert "The Folk of Harrowgate: They're glad of one less orc in the alleys. (affinity +3)" in lines
    assert "The Back-Alley Orcs: They hate you for it, but a warrior's death is honourable. (affinity -6, respect +4)" in lines
    assert any(line.startswith("You take the Orc Warrior's Greataxe, 6 coins.") for line in lines)
    assert await world.redis.sismember("PLAYER:kevin:gear", "greataxe")
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


async def test_levelling_up_grants_a_point_and_no_gear(world):
    kevin = await enter(world, "kevin")
    await walk(world, "kevin", "east")
    await world.redis.hset("ACCOUNT:kevin", "xp", 90)
    await drain(kevin)
    await kill(world, "kevin", "orc-1")
    events = await drain(kevin)
    assert "You reach level 2! You have a stat point to spend (TRAIN <stat>)." in texts(events)  # talents come at 3
    character = of_type(events, "character")[-1]
    assert (character["level"], character["xp"], character["xp_next"], character["points"]) == (2, 50, 200, 1)
    # Reputation lists only the factions that know you, each with its realm.
    assert {(f["id"], f["realm"], f["realm_name"]) for f in character["factions"]} == {
        ("harrowfolk", "alzendor", "Alzendor"), ("orcs", "alzendor", "Alzendor")}
    assert "sword" not in [g["id"] for g in of_type(events, "kit")[-1]["gear"]]  # gear comes from the world

    await world.call("train", "kevin", "vigor")
    await world.call("train", "kevin", "vigor")
    lines = texts(await drain(kevin))
    assert lines[:1] == ["Vigor is now 1. Vigor: 8 more max health per point."]
    assert lines[-1] == "You have no stat points to spend. You'll get one each level."
    assert await world.redis.hget("ACCOUNT:kevin", "hp") == "108"


async def test_poise_focus_and_resilience_go_to_the_fight(world):
    await world.redis.hset("ACCOUNT:kevin", mapping={"stat:poise": 2, "stat:focus": 3})
    kevin = await enter(world, "kevin")
    await walk(world, "kevin", "east")
    start = [e for e in of_type(await drain(kevin), "encounter") if e["op"] == "start"][0]["encounter"]
    assert start["players"][0]["stats"] == {"poise": 2, "focus": 3, "resilience": 0}


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
