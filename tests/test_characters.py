"""Characters: class, ancestry and background, talents and passives, and the
starting realms. See docs/characters.md."""

from .conftest import drain, enter, ride, texts


def of_type(events, kind):
    return [e for e in events if e["type"] == kind]


async def create(world, pid, cls="rogue", ancestry="elf", passive="starsight", background="sailor"):
    await world.redis.hset(f"ACCOUNT:{pid}", "name", pid.capitalize())
    assert await world.call("create_character", pid, cls, ancestry, passive, background) == ""
    return await enter(world, pid)


async def test_creation_sets_up_class_ancestry_and_background(world):
    kevin = await create(world, "kevin")
    events = await drain(kevin)
    character = of_type(events, "character")[-1]
    assert (character["class"], character["ancestry"], character["background"]) == ("Rogue", "Elf", "Sailor")
    assert character["stats"]["focus"] == 1  # the elf's +1
    assert of_type(events, "kit")[-1]["slots"] == ["flick_knife", "tar_flask", "belaying_pin"]  # the sailor items a rogue can use
    assert of_type(events, "kit")[-1]["coins"] == 15
    assert of_type(events, "room")[-1]["room"]["self"]["label"] == "Elf Rogue"
    assert await world.redis.get("PLAYER:kevin:room") == "slipway"
    assert await world.redis.hget("PLAYER:kevin:rep:harrowfolk", "affinity") == "5"
    assert of_type(events, "intro")[0]["text"].startswith("The storm nearly drowned you all.")
    assert any(t.startswith("New quest: Caulk and Tar.") for t in texts(events))


async def test_creation_checks_its_choices(world):
    assert await world.call("create_character", "kevin", "bard", "elf", "starsight", "sailor") == "Choose a class."
    assert await world.call("create_character", "kevin", "rogue", "elf", "bloodrhythm", "sailor") == "Choose a passive from your ancestry."


async def test_a_class_can_only_use_its_kinds_of_gear(world):
    kevin = await create(world, "kevin", cls="fighter", ancestry="human", passive="second_wind")
    await world.redis.sadd("PLAYER:kevin:gear", "firebolt")
    await drain(kevin)
    await world.call("equip", "kevin", "firebolt", 1)
    assert texts(await drain(kevin)) == ["A Fighter can't use spell gear like Firebolt."]


async def test_talents_open_by_rank_and_come_at_even_levels(world):
    kevin = await create(world, "kevin", cls="mage", ancestry="human", passive="quick_study")
    await drain(kevin)
    await world.call("learn", "kevin", "spark")
    assert texts(await drain(kevin)) == ["You have no talent to learn yet: one comes at every even level."]
    await world.redis.hset("ACCOUNT:kevin", "level", 8)  # four talents' worth
    for talent in ("spark", "frost shard", "gust"):
        await world.call("learn", "kevin", talent)
    await drain(kevin)
    await world.call("learn", "kevin", "ice lance")  # rank 2 opens after three
    assert texts(await drain(kevin))[0] == "You learn Ice Lance. EQUIP ICE LANCE <slot> to use it."
    await world.call("learn", "kevin", "tempest")
    assert texts(await drain(kevin)) == ["You have no talent to learn yet: one comes at every even level."]
    await world.redis.hset("ACCOUNT:kevin", "level", 10)
    await world.call("learn", "kevin", "tempest")
    assert texts(await drain(kevin)) == ["Tempest opens after 7 talents."]
    await world.call("learn", "kevin", "chain lightning")  # the one link: needs Spark, which Kevin has
    assert texts(await drain(kevin))[0].startswith("You learn Chain Lightning.")


async def test_passives_come_at_fives_and_respec_resets_them(world):
    kevin = await create(world, "kevin", cls="fighter", ancestry="orc", passive="thick_hide", background="merchant")
    await world.redis.hset("ACCOUNT:kevin", "level", 5)
    await world.call("learn", "kevin", "iron gut")
    await world.call("learn", "kevin", "bloodrhythm")
    lines = texts(await drain(kevin))
    assert any(line.startswith("You gain Iron Gut") for line in lines)
    assert lines[-1].startswith("You have no passive to choose yet")

    await world.call("goto", "kevin", "training_yard")
    await world.redis.hset("ACCOUNT:kevin", "coins", 100)
    await drain(kevin)
    await world.call("respec", "kevin")
    assert texts(await drain(kevin))[0].startswith("Sergeant Holt takes 50 coins.")
    assert await world.redis.smembers("PLAYER:kevin:perks") == set()


async def test_guard_soaks_up_blows(world):
    kevin = await create(world, "kevin", cls="fighter", ancestry="human", passive="last_stand")
    await world.redis.sadd("PLAYER:kevin:gear", "guard_up")
    await world.call("goto", "kevin", "back_alley")  # an orc warrior, who attacks
    await world.call("equip", "kevin", "guard up", 1)  # can't: in a fight
    await world.redis.delete("PLAYER:kevin:foes")
    await world.redis.delete("NPC:orc-1:foes")
    await world.call("equip", "kevin", "guard up", 1)
    await world.call("use", "kevin", 1, "")
    guard = int(await world.redis.get("PLAYER:kevin:guard"))  # the opener, after the weather
    await world.redis.zadd("NPC:orc-1:foes", {"kevin": 0})
    await world.redis.hset("NPC:orc-1:next", 1, 0)
    await world.redis.zadd("alz:npc_attacks", {"orc-1#1": 0})
    hp = int(await world.redis.hget("ACCOUNT:kevin", "hp"))
    await drain(kevin)
    await world.call("tick")
    assert f"The Orc Warrior hacks at Kevin with a cleaver. ({7 - guard}, {guard} guarded)" in texts(await drain(kevin))
    assert int(await world.redis.hget("ACCOUNT:kevin", "hp")) == hp - (7 - guard)


async def test_stagger_pushes_back_the_next_blow(world):
    kevin = await create(world, "kevin", cls="rogue", ancestry="human", passive="last_stand")
    await world.call("goto", "kevin", "back_alley")
    before = float(await world.redis.hget("NPC:orc-1:next", "1"))
    await world.call("use", "kevin", 2, "npc:orc-1")  # the tar flask: stagger 1200 ms
    assert float(await world.redis.hget("NPC:orc-1:next", "1")) == before + 1200


async def test_slot_ball_edges(world):
    kevin = await create(world, "kevin", cls="fighter", ancestry="human", passive="second_wind", background="merchant")
    await world.call("attune", "kevin", "second wind", 1)
    assert texts(await drain(kevin))[-1] == "Second Wind is attuned to slot 1."
    await world.redis.hset("ACCOUNT:kevin", "hp", 50)
    await world.call("goto", "kevin", "training_yard")
    await world.call("use", "kevin", 1, "dummy")  # the opener starts the rhythm
    # Pretend 3.6 periods have passed: the ball has touched the left edge twice (at 1.5 and 3.5).
    start = int(await world.redis.hget("PLAYER:kevin:slot:1", "start"))
    await world.redis.hset("PLAYER:kevin:slot:1", mapping={"start": start - 9000, "last": start - 9000})
    await drain(kevin)
    await world.call("use", "kevin", 1, "dummy")
    assert "Second Wind: +2 health." in texts(await drain(kevin))


async def test_a_starting_realm_from_start_to_finish(world):
    """Low Wick, the street urchin's start, played through with commands."""
    kevin = await create(world, "kevin", cls="rogue", ancestry="human", passive="trapsense", background="street_urchin")

    async def do(*command):
        await world.call(*command)

    await do("move", "kevin", "west")
    await do("get", "kevin", "purse")
    await do("move", "kevin", "east")
    await do("use_item", "kevin", "purse", "nan")
    await do("ask", "kevin", "nan", "signet")
    for nid in ("guard_dog",):
        await world.redis.srem("ROOM:magistrates_house:npcs", nid)  # the dog is dealt with
    await world.redis.rpush("alz:test_rolls", 0.0)  # step over the thread
    for direction in ("east", "east", "east", "north"):
        await do("move", "kevin", direction)
    await do("get", "kevin", "signet")
    for direction in ("south", "west", "west", "west"):
        await do("move", "kevin", direction)
    await do("use_item", "kevin", "signet", "nan")
    assert await world.redis.hget("PLAYER:kevin:quests", "lw_hot") == "active"
    await world.redis.delete("ROOM:rooftops:npcs")  # the watch looks the other way
    for direction in ("east", "east", "east", "north", "east", "south"):
        await do("move", "kevin", direction)
    events = await drain(kevin)
    assert "Too Hot: Joss the carter owes Nan a favour: ASK JOSS ABOUT PASSAGE." in texts(events)

    await do("ask", "kevin", "joss", "passage")
    events = await drain(kevin)
    assert of_type(events, "character")[-1]["level"] == 3  # two levels in the tutorial
    event = of_type(events, "travel_event")[0]  # the scripted checkpoint
    assert event["id"] == "checkpoint" and len(event["choices"]) == 2  # the urchin's own way out
    await do("choose", "kevin", "2")
    await ride(world, "kevin")
    assert await world.redis.get("PLAYER:kevin:room") == "back_alley"
    assert not await world.redis.sismember("PLAYER:kevin:realms", "lowwick")  # never to return


async def test_dying_in_a_starting_realm_wakes_you_where_you_began(world):
    kevin = await create(world, "kevin", background="woodsman")
    await world.call("goto", "kevin", "fern_bog")
    await world.redis.hset("ACCOUNT:kevin", "hp", 1)
    await world.redis.zadd("alz:npc_attacks", {"bog_wisp#1": 0})
    await world.call("tick")
    assert await world.redis.get("PLAYER:kevin:room") == "hunters_lodge"
