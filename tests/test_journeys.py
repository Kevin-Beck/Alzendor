"""Journeys: walking pace, the clock, traps, routes made of waypoints, and
travel events. See docs/journeys.md."""

from .conftest import drain, enter, ride, set_weather, texts


def of_type(events, kind):
    return [e for e in events if e["type"] == kind]


async def walk(world, pid, *directions):
    for direction in directions:
        await world.call("move", pid, direction)


# Walking pace -----------------------------------------------------------------


async def test_each_step_takes_the_time_to_cross_the_ground(world):
    await world.redis.hset("alz:rules", "pace", 1)
    kevin = await enter(world, "kevin")
    await walk(world, "kevin", "north")
    room = of_type(await drain(kevin), "room")[-1]["room"]
    assert (room["id"], room["step_ms"]) == ("market_square", 600)  # a town street
    await walk(world, "kevin", "south")
    assert texts(await drain(kevin)) == ["You need a moment to find your footing."]

    await world.redis.hset("ROOM:market_square:info", "terrain", "marsh")  # rough ground
    await world.redis.delete("PLAYER:kevin:moved")
    await world.call("look", "kevin")
    assert of_type(await drain(kevin), "room")[-1]["room"]["step_ms"] == 1500
    await world.redis.sadd("PLAYER:kevin:perks", "feather_step")
    await world.call("look", "kevin")
    assert of_type(await drain(kevin), "room")[-1]["room"]["step_ms"] == 900


# The clock --------------------------------------------------------------------


async def test_night_hides_the_ways_you_dont_know_in_the_wilds(world):
    await world.redis.set("alz:clock_override", 23)
    kevin = await enter(world, "kevin")
    events = await drain(kevin)
    clock = of_type(events, "weather")[-1]["clock"]
    assert (clock["hour"], clock["phase"], round(clock["day"], 6)) == (23, "night", round(23 / 24, 6))
    assert "It is night." not in texts(events)[0]  # the tavern is indoors

    await walk(world, "kevin", "north")  # the market square: a town, with its lamps lit
    room = of_type(await drain(kevin), "room")[-1]
    assert len(room["room"]["exits"]) == 5 and "It is night." in room["text"]

    await walk(world, "kevin", "north", "north", "north")  # out of the north gate, into the wilds
    events = await drain(kevin)
    room = of_type(events, "room")[-1]
    assert room["room"]["exits"] == ["south"]  # only the way back to the gate
    assert "(the darkness hides any other ways on)" in room["text"] and "It is night." in room["text"]
    assert of_type(events, "weather")[-1]["visibility"] == "poor"
    await world.call("move", "kevin", "northwest")
    assert texts(await drain(kevin)) == ["It's too dark to find a way northwest. You need a light in your hand: EQUIP TORCH."]

    await world.redis.sadd("PLAYER:kevin:wardrobe", "torch")
    await world.call("wear", "kevin", "torch")
    assert len(of_type(await drain(kevin), "room")[-1]["room"]["exits"]) == 4

    await world.call("remove", "kevin", "hand")
    await world.redis.sadd("PLAYER:kevin:perks", "starsight")
    await world.call("look", "kevin")
    assert len(of_type(await drain(kevin), "room")[-1]["room"]["exits"]) == 4


async def test_a_realm_can_have_its_own_sky(world):
    await world.redis.delete("alz:clock_override")
    await world.redis.hset("REALM:alzendor:info", "sky", "always_night")
    kevin = await enter(world, "kevin")
    assert of_type(await drain(kevin), "weather")[-1]["clock"]["phase"] == "night"


async def test_admins_can_pin_the_clock(world):
    kevin = await enter(world, "kevin")
    await drain(kevin)
    await world.call("set_clock", "kevin", "6")
    assert texts(await drain(kevin))[0] == "The clock is pinned: 6:00, dawn."


# Traps ------------------------------------------------------------------------

TO_SNARE = ("north", "north", "north", "north")  # to the woodland path, next to the mossy clearing


async def test_a_trap_springs_unless_you_pass_a_check(world):
    kevin = await enter(world, "kevin")
    await walk(world, "kevin", *TO_SNARE)
    await drain(kevin)
    await world.call("inspect", "kevin", "wire")
    assert "trapper's wire" in texts(await drain(kevin))[0]  # the sign next door

    await world.redis.rpush("alz:test_rolls", 0.99)  # fails any check
    await walk(world, "kevin", "northwest")
    events = await drain(kevin)
    assert "A loop of wire snaps tight around your ankle and yanks you off your feet. (8)" in texts(events)
    assert "You limp on, slowed." in texts(events)
    assert await world.redis.hget("ACCOUNT:kevin", "hp") == "92"
    assert await world.redis.exists("PLAYER:kevin:slowed")
    assert any(r.get("trap") for e in of_type(events, "map") for r in e["rooms"] if r["id"] == "mossy_clearing")

    # Sprung, it's harmless until it rearms.
    await walk(world, "kevin", "southeast", "northwest")
    assert not [t for t in texts(await drain(kevin)) if "snare" in t.lower()]


async def test_creeping_helps_and_reading_the_sign_as_well_gets_you_past(world):
    kevin = await enter(world, "kevin")
    await walk(world, "kevin", *TO_SNARE)
    # Creeping without knowing: base 30% (fair) + 50% = 80%, so a roll of 0.75 passes.
    await world.redis.rpush("alz:test_rolls", 0.75)
    await drain(kevin)
    await world.call("move", "kevin", "northwest", "careful")
    events = await drain(kevin)
    assert "You spot a poacher's snare among the moss, and step over it. (Poise check)" in texts(events)
    assert "Kevin creeps northwest." in texts(events)

    # Reading the sign, then creeping: always past, and the snare's still set.
    await walk(world, "kevin", "southeast")
    await world.redis.srem("PLAYER:kevin:traps", "mossy_clearing")
    await world.call("look", "kevin", "wire")
    events = await drain(kevin)
    assert of_type(events, "guide")[0]["text"].startswith("Something is set northwest: a poacher's snare. CREEP NORTHWEST")
    await world.redis.rpush("alz:test_rolls", 0.99)  # it wouldn't be needed
    await world.call("move", "kevin", "northwest", "careful")
    assert "You creep past a poacher's snare, testing every step. It is still set behind you." in texts(await drain(kevin))
    assert await world.redis.lpop("alz:test_rolls") == "0.99"
    assert not await world.redis.exists("ROOM:mossy_clearing:trap_sprung")

    # Walking in, knowing or not, it's the usual check.
    await walk(world, "kevin", "southeast")
    await world.redis.rpush("alz:test_rolls", 0.5)
    await walk(world, "kevin", "northwest")
    assert await world.redis.exists("ROOM:mossy_clearing:trap_sprung")


async def test_disarming_a_trap_is_a_gamble(world):
    kevin = await enter(world, "kevin")
    await walk(world, "kevin", *TO_SNARE)
    await drain(kevin)
    await world.call("disarm", "kevin", "northwest")
    assert texts(await drain(kevin)) == ["You don't know of anything to disarm that way. LOOK around first."]
    await world.call("look", "kevin", "wire")
    await world.redis.rpush("alz:test_rolls", 0.1)
    await world.call("disarm", "kevin", "northwest")
    assert "You disarm a poacher's snare. It will be a while before anyone sets it again. (Poise check)" in texts(await drain(kevin))
    assert await world.redis.exists("ROOM:mossy_clearing:trap_sprung")  # safe for anyone, until it rearms

    await world.redis.delete("ROOM:mossy_clearing:trap_sprung")
    await world.redis.hset("ACCOUNT:kevin", "hp", 50)
    hp = 50
    await world.redis.rpush("alz:test_rolls", 0.99)
    await world.call("disarm", "kevin", "northwest")
    said = texts(await drain(kevin))
    assert "Your hand slips. (Poise check)" in said and "A loop of wire snaps tight around your ankle and yanks you off your feet. (8)" in said
    assert int(await world.redis.hget("ACCOUNT:kevin", "hp")) == hp - 8


async def test_trapsense_marks_traps_next_door(world):
    kevin = await enter(world, "kevin")
    await world.redis.sadd("PLAYER:kevin:perks", "trapsense")
    await walk(world, "kevin", *TO_SNARE)
    events = await drain(kevin)
    assert "Your trapsense prickles: something is set to the northwest." in texts(events)
    assert await world.redis.sismember("PLAYER:kevin:traps", "mossy_clearing")


async def test_a_trap_can_be_the_end_of_you(world):
    kevin = await enter(world, "kevin")
    await walk(world, "kevin", *TO_SNARE)
    await world.redis.hset("ACCOUNT:kevin", "hp", 5)
    await world.redis.rpush("alz:test_rolls", 0.99)
    await walk(world, "kevin", "northwest")
    assert await world.redis.get("PLAYER:kevin:room") == "temple_steps"


# Travel events ----------------------------------------------------------------


async def only_event(world, event_id):
    """Makes one travel event the only one, and certain to happen."""
    for other in await world.redis.hkeys("alz:travel_events"):
        if other != event_id:
            await world.redis.hdel("alz:travel_events", other)
    await world.redis.hset("alz:rules", "event_chance", 1)


async def board_coach(world, pid):
    await walk(world, pid, "north")
    await world.call("travel", pid, "coach")


async def test_an_event_pauses_the_journey_for_a_choice(world):
    await only_event(world, "rut")
    await set_weather(world.redis, "alzendor", 0, 0, 0.2)  # a little rain: mud
    kevin = await enter(world, "kevin")
    await board_coach(world, "kevin")
    event = of_type(await drain(kevin), "travel_event")[0]
    assert event["text"].splitlines() == [
        "The coach lurches and stops. A wheel is sunk to the hub in mud, and the driver swears at it.",
        "  CHOOSE 1: Climb down and help push (Vigor check)",
        "  CHOOSE 2: Stay in your seat",
    ]
    await world.redis.zadd("alz:journeys", {"kevin": 0})
    await world.call("tick")  # the journey waits for you (until the time runs out)
    assert await world.redis.get("PLAYER:kevin:room") == "switchbacks"

    await world.redis.rpush("alz:test_rolls", 0.1)  # passes: fair is 30%
    await world.call("choose", "kevin", "1")
    lines = texts(await drain(kevin))
    assert lines[:2] == ["> Climb down and help push",
                         "With a heave and a sucking sound, the wheel comes free. The driver claps you on the back."]
    assert "The Folk of Harrowgate: Word gets round that you put your shoulder to a stuck wheel. (affinity +1)" in lines
    await ride(world, "kevin", stages=1)  # and you made up time: a waypoint skipped
    assert await world.redis.get("PLAYER:kevin:room") == "gallows_ridge"
    await world.call("choose", "kevin", "1")
    assert texts(await drain(kevin))[-1] == "There's nothing to choose right now."


async def test_backgrounds_get_choices_of_their_own(world):
    await only_event(world, "toll")
    kevin = await enter(world, "kevin")
    await board_coach(world, "kevin")
    labels = [c["label"] for c in of_type(await drain(kevin), "travel_event")[0]["choices"]]
    assert "Press a clipped coin into his hand" not in labels

    await world.call("goto", "kevin", "market_square")
    await world.redis.delete("PLAYER:kevin:journey")
    await world.redis.hset("ACCOUNT:kevin", "background", "street_urchin")
    await world.call("travel", "kevin", "coach")
    event = of_type(await drain(kevin), "travel_event")[0]
    assert [c["label"] for c in event["choices"]][2] == "Press a clipped coin into his hand"
    assert "CHOOSE 3: Press a clipped coin into his hand (Street urchin)" in event["text"]


async def test_an_event_left_too_long_takes_the_last_choice(world):
    await only_event(world, "rut")
    await set_weather(world.redis, "alzendor", 0, 0, 0.2)
    kevin = await enter(world, "kevin")
    await board_coach(world, "kevin")
    await world.redis.hset("PLAYER:kevin:journey", "event_until", 0)
    await drain(kevin)
    await world.redis.zadd("alz:journeys", {"kevin": 0})
    await world.call("tick")
    lines = texts(await drain(kevin))
    assert lines[:3] == ["The moment passes.", "> Stay in your seat", "You wait while the driver digs. It takes a long time."]


async def test_bad_weather_brings_worse_events_and_you_can_drown(world):
    for event_id in await world.redis.hkeys("alz:travel_events"):
        if event_id not in ("fish", "squall", "swamped"):
            await world.redis.hdel("alz:travel_events", event_id)
    await world.redis.hset("alz:rules", "event_chance", 1)
    await set_weather(world.redis, "alzendor", 0, 0, 1)  # a deluge, but no wind: the ferry still runs
    kevin = await enter(world, "kevin")
    await world.call("goto", "kevin", "ferry_dock")
    await world.redis.hset("PLAYER:kevin:regions", "saltmere", "discovered")
    await world.call("travel", "kevin", "saltmere")
    assert of_type(await drain(kevin), "travel_event")[0]["id"] == "swamped"

    await world.redis.rpush("alz:test_rolls", 0.99)  # the swim fails
    await world.call("choose", "kevin", "2")
    assert "The water is too cold and the shore too far. The lake keeps you." in texts(await drain(kevin))
    assert await world.redis.get("PLAYER:kevin:room") == "temple_steps"  # a real death: home
    assert not await world.redis.exists("PLAYER:kevin:journey")


async def test_an_ambush_is_yours_alone_and_you_ride_on_after(world):
    await only_event(world, "wolves")
    await world.redis.set("alz:clock_override", 19)  # dusk
    kevin = await enter(world, "kevin")
    await board_coach(world, "kevin")
    await drain(kevin)
    await world.call("choose", "kevin", "2")  # fight
    events = await drain(kevin)
    wolves = [e["id"] for e in of_type(events, "room")[-1]["room"]["entities"]]
    assert wolves == ["npc:ford_wolf~kevin~1", "npc:ford_wolf~kevin~2"]
    assert "ROOM:switchbacks" in kevin.subs
    assert await world.redis.smembers("PLAYER:kevin:foes") == {"ford_wolf~kevin~1", "ford_wolf~kevin~2"}

    mara = await enter(world, "mara")  # someone else on the same road sees none of it
    await board_coach(world, "mara")
    assert of_type(await drain(mara), "room")[-1]["room"]["entities"] == []

    for n, wolf in enumerate(("ford_wolf~kevin~1", "ford_wolf~kevin~2"), 1):
        await world.redis.hset(f"NPC:{wolf}", "hp", 1)
        await world.call("use", "kevin", n, f"npc:{wolf}")
    await world.redis.zadd("alz:journeys", {"kevin": 0})
    await world.call("tick")
    assert "The last of them is down. You climb back aboard, and the journey goes on." in texts(await drain(kevin))
    assert "ROOM:switchbacks" not in kevin.subs
    assert not await world.redis.exists("NPC:ford_wolf~kevin~1")
    await ride(world, "kevin")
    assert await world.redis.get("PLAYER:kevin:room") == "village_green"


async def test_losing_or_fleeing_an_ambush_strands_you(world):
    await only_event(world, "wolves")
    await world.redis.set("alz:clock_override", 19)
    kevin = await enter(world, "kevin")
    await board_coach(world, "kevin")
    await world.call("choose", "kevin", "2")
    await world.call("flee", "kevin")
    assert await world.redis.get("PLAYER:kevin:room") == "scree_foot"
    assert not await world.redis.exists("PLAYER:kevin:journey")
    assert await world.redis.hget("ACCOUNT:kevin", "hp") == "33"
    assert await world.redis.scard("ROOM:switchbacks:npcs") == 0

    # Beaten, it's the same: thrown off the road, not killed.
    await world.call("goto", "kevin", "market_square")
    await world.redis.hset("ACCOUNT:kevin", "hp", 100)
    await world.call("travel", "kevin", "coach")
    await world.call("choose", "kevin", "2")
    await world.redis.hset("ACCOUNT:kevin", "hp", 1)
    await world.redis.zadd("alz:npc_attacks", {"ford_wolf~kevin~1#1": 0})
    await world.call("tick")
    assert await world.redis.get("PLAYER:kevin:room") == "scree_foot"


async def test_rumours_mark_realms_and_regions(world):
    await only_event(world, "rimewaste_rumour")
    kevin = await enter(world, "kevin")
    await board_coach(world, "kevin")
    await drain(kevin)
    await world.call("choose", "kevin", "1")
    events = await drain(kevin)
    assert "You hear talk of the Rimewaste, another world entirely." in texts(events)
    realms = of_type(events, "map")[-1]["realms"]
    assert {"id": "rimewaste", "name": "the Rimewaste", "rumour": True} in realms


# Marooned ---------------------------------------------------------------------


async def maroon(world, pid):
    await only_event(world, "aground")
    await world.call("goto", pid, "ferry_dock")
    await world.redis.hset(f"PLAYER:{pid}:regions", "saltmere", "discovered")
    await world.call("travel", pid, "saltmere")
    await world.call("choose", pid, "2")  # wade ashore


async def test_marooned_you_mend_the_ferry_and_sail_on(world):
    kevin = await enter(world, "kevin")
    await maroon(world, "kevin")
    events = await drain(kevin)
    assert await world.redis.get("PLAYER:kevin:room") == "wreck_cove"
    assert "New quest: Marooned. Find a sound plank, a lump of pitch and a coil of rope to mend the ferry." in texts(events)
    quest = of_type(events, "quests")[-1]["quests"][0]
    assert (quest["id"], quest["status"], quest["priority"]) == ("marooned", "active", True)

    # Out of time doesn't matter here: the journey waits while you're ashore.
    await world.redis.zadd("alz:journeys", {"kevin": 0})
    await world.call("tick")
    assert await world.redis.get("PLAYER:kevin:room") == "wreck_cove"

    # Quest items are your own: someone else marooned here gets their own plank.
    await world.call("use_item", "kevin", "plank", "ferry")
    assert texts(await drain(kevin)) == ["You aren't carrying that."]
    await walk(world, "kevin", "east")
    await world.call("get", "kevin", "plank")
    await walk(world, "kevin", "west", "north")
    await world.call("get", "kevin", "pitch")
    await walk(world, "kevin", "east")
    await world.call("ask", "kevin", "ness", "ferry")
    await world.call("get", "kevin", "rope")
    events = await drain(kevin)
    assert "Marooned: Mend the ferry: USE PLANK ON FERRY in Wreck Cove." in texts(events)
    assert await world.redis.scard("ROOM:tide_pools:qitems") == 1  # still there for the next castaway

    await walk(world, "kevin", "west", "south")
    await world.call("use_item", "kevin", "plank", "ferry")
    events = await drain(kevin)
    assert "Quest complete: Marooned." in texts(events)
    assert await world.redis.get("PLAYER:kevin:room") == "open_lake"  # back aboard where it ran aground
    assert not await world.redis.smembers("PLAYER:kevin:inv") & {"plank-1", "pitch-1", "rope-1"}
    await ride(world, "kevin")
    assert await world.redis.get("PLAYER:kevin:room") == "saltmere_landing"


async def test_leaving_the_island_any_other_way_fails_the_quest(world):
    kevin = await enter(world, "kevin")
    await maroon(world, "kevin")
    await world.call("goto", "kevin", "tavern")  # teleported away
    assert await world.redis.hget("PLAYER:kevin:quests", "marooned") == "failed"
    assert not await world.redis.exists("PLAYER:kevin:journey")


async def test_marooned_you_are_still_there_after_logging_out(world):
    kevin = await enter(world, "kevin")
    await maroon(world, "kevin")
    await world.call("disconnect", "kevin", "session-kevin", "", "Bye.")
    again = await enter(world, "kevin", session="again")
    events = await drain(again)
    assert of_type(events, "room")[-1]["room"]["id"] == "wreck_cove"
    assert of_type(events, "quests")[-1]["quests"][0]["goal"].startswith("Find a sound plank")


async def test_npcs_talk_about_their_topics(world):
    kevin = await enter(world, "kevin")
    await world.call("goto", "kevin", "training_yard")
    holt = next(e for e in of_type(await drain(kevin), "room")[-1]["room"]["entities"] if e["id"] == "npc:holt")
    assert holt["topics"] == ["quests", "rumours", "training"]  # the card says what to discuss
    assert holt["rapport"] == "stranger"
    await world.call("discuss", "kevin", "holt", "training")
    assert texts(await drain(kevin))[-1].startswith('Sergeant Holt says, "Want to unlearn your talents')
    await world.call("discuss", "kevin", "holt", "dragons")
    assert texts(await drain(kevin))[-1] == 'Sergeant Holt says, "Can\'t help you with that, I\'m afraid."'
    await world.call("discuss", "kevin", "holt", "")
    assert texts(await drain(kevin)) == ["Sergeant Holt will discuss: quests, rumours, training. (DISCUSS <topic>)"]
