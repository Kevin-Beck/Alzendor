"""Starting fights (the one rule), slots and gear. What happens inside a
fight, and owners running it, is in test_encounters.py; the simulation in
test_balance.py."""

from .conftest import blow, drain, enter, flee, hit, texts


def of_type(events, kind, **match):
    return [e for e in events if e["type"] == kind and all(e.get(k) == v for k, v in match.items())]


async def at_fish_market(world, pid="kevin"):
    """A player standing with the two dock rats (neutral), with the starting loadout: kick, magic missile, health potion."""
    feed = await enter(world, pid)
    for direction in ("north", "west", "south"):
        await world.call("move", pid, direction)
    await drain(feed)
    return feed


async def encounter(world, pid="kevin"):
    return await world.redis.get(f"PLAYER:{pid}:encounter")


# The one rule: where fights start -------------------------------------------------------


async def test_walking_in_on_an_enemy(world):
    kevin = await enter(world, "kevin")
    await world.call("move", "kevin", "east")  # the back alley's orc warrior is hostile
    events = await drain(kevin)
    assert "The Orc Warrior turns on Kevin!" in texts(events)
    assert of_type(events, "encounter", op="start")
    assert await encounter(world)


async def test_teleporting_in_on_an_enemy(world):
    await enter(world, "kevin")
    await world.call("goto", "kevin", "back_alley")
    assert await encounter(world)


async def test_connecting_where_an_enemy_waits(world):
    await world.redis.set("PLAYER:kevin:room", "back_alley")
    await enter(world, "kevin")
    assert await encounter(world)


async def test_reconnecting_mid_fight_resends_it(world):
    await enter(world, "kevin")
    await world.call("goto", "kevin", "back_alley")
    eid = await encounter(world)
    again = await enter(world, "kevin", session="again")  # a new connection, still in the world
    start = of_type(await drain(again), "encounter", op="start")[0]
    assert start["id"] == eid and start["resumed"] is True


async def test_an_enemy_appearing_starts_a_fight(world):
    kevin = await enter(world, "kevin")
    await world.call("move", "kevin", "east")
    await flee(world, "kevin", "west")
    # The orc goes down; when it comes back, it turns on whoever is there.
    await world.redis.srem("ROOM:back_alley:npcs", "orc-1")
    await world.redis.delete("PLAYER:kevin:moved")
    await world.call("move", "kevin", "east")
    assert not await encounter(world)
    await world.redis.zadd("alz:respawns", {"orc-1": 0})
    await world.call("respawn")
    assert await encounter(world)
    assert await world.redis.get("NPC:orc-1:encounter") == await encounter(world)


async def test_an_enemy_arriving_joins_the_fight_in_progress(world):
    await enter(world, "kevin")
    await world.call("goto", "kevin", "back_alley")
    eid = await encounter(world)
    # Another hostile one turns up mid-fight: it joins, rather than starting its own.
    await world.redis.hset("NPC:orc-2", "disposition", "hostile")
    await world.redis.delete("PLAYER:kevin:rep:orcs")
    await world.call("respawn")  # nothing due; then reputation turns the whelp hostile:
    await world.redis.hset("PLAYER:kevin:rep:orcs", mapping={"affinity": -100, "respect": -100})
    await world.call("greet", "kevin", "orc")  # any deed re-runs the rule
    assert set(await world.redis.zrange(f"ENC:{eid}:npcs", 0, -1)) == {"orc-1", "orc-2"}


async def test_reputation_turning_an_npc_hostile_starts_a_fight(world):
    # Respected enough that the orc lets him be (test_npcs), until he taunts it.
    await world.redis.hset("PLAYER:kevin:rep:orcs", mapping={"affinity": -40, "respect": 30})
    await world.redis.srem("ROOM:back_alley:npcs", "orc-2")  # (the whelp takes the dislike less calmly)
    await enter(world, "kevin")
    await world.call("move", "kevin", "east")
    assert not await encounter(world)
    await world.redis.hset("PLAYER:kevin:rep:orcs", mapping={"affinity": -80, "respect": -20})
    await world.call("emote", "kevin", "laugh", "orc warrior", "{actor} laughs.", "{actor} laughs at {target}.")
    assert await encounter(world)


async def test_a_player_walking_in_on_a_fight_joins_it(world):
    await enter(world, "kevin")
    await world.call("goto", "kevin", "back_alley")
    eid = await encounter(world)
    mara = await enter(world, "mara")
    await world.call("goto", "mara", "back_alley")
    assert await encounter(world, "mara") == eid
    assert await world.redis.zrange(f"ENC:{eid}:players", 0, -1) == ["kevin", "mara"]
    # The orc hits whoever joined first.
    await drain(mara)
    await blow(world, "orc-1")
    assert texts(await drain(mara))[0].startswith("The Orc Warrior hacks at Kevin")


async def test_bystanders_stay_out_until_they_strike(world):
    kevin = await at_fish_market(world)
    mara = await at_fish_market(world, "mara")
    await world.redis.hset("NPC:rat-1", "hp", 100)
    await world.call("use", "kevin", 1, "npc:rat-1")
    eid = await encounter(world)
    assert not await encounter(world, "mara")  # the rats aren't hostile to her
    await world.call("use", "mara", 1, "npc:rat-1")  # striking one in the fight joins it
    assert await encounter(world, "mara") == eid


async def test_attacking_first(world):
    kevin = await at_fish_market(world)
    await world.redis.hset("NPC:rat-1", "hp", 100)
    await world.call("use", "kevin", 1, "npc:rat-1")
    eid = await encounter(world)
    assert await world.redis.zrange(f"ENC:{eid}:npcs", 0, -1) == ["rat-1"]  # the other rat stays out of it
    assert await world.redis.hget(f"ENC:{eid}:opening", "kevin") == "1|npc:rat-1"
    # In the fight, a typed USE is the owner's to land: Lua won't.
    await world.call("use", "kevin", 1, "npc:rat-1")
    assert texts(await drain(kevin))[-1] == "You strike from your balance in a fight: press the slot key."


async def test_watchful_enemies_are_checked(world):
    await enter(world, "kevin")
    await world.redis.hset("NPC:orc-1", "notice", "hard")
    await world.redis.rpush("alz:test_rolls", 0.0)  # a good Poise check
    await world.call("goto", "kevin", "back_alley")
    assert not await encounter(world)


async def test_only_npcs_can_be_attacked(world):
    kevin = await at_fish_market(world)
    mara = await at_fish_market(world, "mara")
    await drain(kevin), await drain(mara)
    for target in ("mara", "ice", "me", "orc", ""):
        await world.call("use", "kevin", 1, target)
    assert texts(await drain(kevin)) == [
        "You can't attack other players.", "You can't fight that.", "You think better of it.", "You don't see that here.",
        "Kick what? Name a target, or press Tab to pick one.",
    ]
    assert not await encounter(world)


async def test_npcs_go_down_and_come_back(world):
    kevin = await at_fish_market(world)
    await world.redis.hset("NPC:rat-1", "hp", 1)
    result = await hit(world, "kevin", "npc:rat-1", tier=2)
    assert result["killed"]
    events = await drain(kevin)
    death = of_type(events, "death")
    assert death[0]["entity_id"] == "npc:rat-1" and death[0]["text"] == "The Dock Rat collapses."
    assert not await world.redis.sismember("ROOM:fish_market:npcs", "rat-1")
    assert not await encounter(world)  # it was the only one in the fight

    await world.call("respawn")  # not due yet
    assert not await world.redis.sismember("ROOM:fish_market:npcs", "rat-1")
    await world.redis.zadd("alz:respawns", {"rat-1": 0})
    await world.call("respawn")
    arrive = of_type(await drain(kevin), "arrive")[0]
    assert arrive["text"] == "The Dock Rat appears." and arrive["entity"]["hp"] == 56  # at full health


# Slots and gear ------------------------------------------------------------------------


async def test_equipping_changes_a_slots_gear(world):
    kevin = await enter(world, "kevin")
    await drain(kevin)
    await world.call("equip", "kevin", "dagger", 1)
    events = await drain(kevin)
    assert texts(events) == ["Slot 1: Dagger, ready every 0.5s."]
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
        "Slot 1: Magic Missile, ready every 6.8s.", "You don't have Greataxe.", "Slot 1: Greataxe, ready every 3.8s.",
        "Slot 1 already holds Greataxe.", "There's no gear called 'banjo'. Type GEAR to see what you have.",
        "Your slots are 1, 2 and 3.",
    ]


async def test_equip_without_a_slot_fills_the_first_empty_one(world):
    kevin = await enter(world, "kevin")
    await world.call("equip", "kevin", "dagger", "")
    await world.call("unequip", "kevin", 2)
    await world.call("equip", "kevin", "dagger", "")
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


async def test_gear_is_locked_in_a_fight_and_free_between(world):
    kevin = await enter(world, "kevin")
    await world.call("goto", "kevin", "back_alley")
    await drain(kevin)
    await world.call("equip", "kevin", "dagger", 1)
    await world.call("unequip", "kevin", 1)
    assert texts(await drain(kevin)) == ["You can't change your gear mid-fight."] * 2
    await flee(world, "kevin", "west")
    await world.call("equip", "kevin", "dagger", 1)
    assert texts(await drain(kevin))[-1] == "Slot 1: Dagger, ready every 0.5s."


async def test_the_starting_loadout_is_only_given_once(world):
    kevin = await enter(world, "kevin")
    await world.call("unequip", "kevin", 3)
    await world.call("disconnect", "kevin", "session-kevin", "", "Bye.")
    again = await enter(world, "kevin", session="again")
    assert of_type(await drain(again), "kit")[-1]["slots"] == ["kick", "missile", ""]


async def test_gear_lists_what_you_own_quickest_first(world):
    kevin = await enter(world, "kevin")
    await drain(kevin)
    await world.call("gear", "kevin")
    event = of_type(await drain(kevin), "gear")[0]
    assert [g["id"] for g in event["gear"]] == ["dagger", "kick", "potion", "missile"]
    assert event["slots"] == ["kick", "missile", "potion"]
    dagger = next(g for g in event["gear"] if g["id"] == "dagger")
    assert (dagger["cooldown_ms"], dagger["kick"], dagger["pattern"]) == (525, 1, "bump")
    lines = event["text"].split("\n")
    # Indoors it's always dead neutral and dry: grey gear at its best, and the frost
    # dagger out of its element (-14% all told).
    assert "  Dagger (light, green): every 0.5s, 2 / 3 / 4 damage [weather -14%]" in lines
    assert "  Magic Missile (spell, grey): every 6.8s, 14 / 18 / 30 damage in 4 hits" in lines
    assert lines[-1].startswith("Your slots: 1 Kick · 2 Magic Missile · 3 Health Potion.")


# Seeing danger ---------------------------------------------------------------------------

from .conftest import set_weather  # noqa: E402


def last_room(events):
    return of_type(events, "room")[-1]["room"]


async def test_rings_show_enemies_next_door_and_not_neutral_npcs(world):
    kevin = await enter(world, "kevin")  # the tavern; the back alley (east) has the orc warrior
    assert last_room(await drain(kevin))["danger"] == ["back_alley"]
    await world.redis.srem("ROOM:back_alley:npcs", "orc-1")  # just the whelp: neutral
    await world.call("look", "kevin", "")
    assert last_room(await drain(kevin))["danger"] == []


async def test_heavy_rain_hides_danger_and_hunters_nose_smells_it(world):
    await set_weather(world.redis, "alzendor", 0, 0, 1)  # a downpour (the tavern itself is dry)
    kevin = await enter(world, "kevin")
    room = last_room(await drain(kevin))
    assert room["danger"] == [] and "scents" not in room
    await world.call("look", "kevin", "east")
    assert texts(await drain(kevin)) == ["The rain hides what's east."]
    await world.redis.sadd("PLAYER:kevin:perks", "hunters_nose")
    await world.call("look", "kevin", "")
    room = last_room(await drain(kevin))
    assert room["danger"] == ["back_alley"] and room["scents"] == ["east"]
    await world.call("look", "kevin", "east")
    assert texts(await drain(kevin)) == ["The rain hides what's east. You smell an Orc Warrior to the east."]


async def test_looking_a_way_shows_the_enemies_there(world):
    kevin = await enter(world, "kevin")
    await drain(kevin)
    await world.call("look", "kevin", "east")
    look = of_type(await drain(kevin), "look")[0]
    assert look["text"] == "East: Back Alley. The Orc Warrior waits there."
    assert [c["id"] for c in look["entities"]] == ["npc:orc-1"] and look["entities"][0]["disposition"] == "hostile"
    assert look["danger"] == ["back_alley"]
    await world.call("look", "kevin", "north")
    assert of_type(await drain(kevin), "look")[0]["text"].endswith("Nothing hostile that you can see.")


async def test_rings_are_a_snapshot(world):
    kevin = await enter(world, "kevin")
    await drain(kevin)
    await world.redis.srem("ROOM:back_alley:npcs", "orc-1")  # the orc wanders off: nothing tells Kevin
    assert of_type(await drain(kevin), "room") == []
    await world.call("look", "kevin", "")  # until he looks
    assert last_room(await drain(kevin))["danger"] == []


async def test_too_dark_to_see_that_way(world):
    await world.redis.hset("ACCOUNT:kevin", "name", "Kevin")
    assert await world.call("create_character", "kevin", "rogue", "human", "last_stand", "sailor") == ""
    kevin = await enter(world, "kevin")  # on the slipway; the sail loft (east) is shuttered and dark
    await drain(kevin)
    await world.call("look", "kevin", "east")
    assert texts(await drain(kevin)) == ["It's too dark to make out what's east."]
