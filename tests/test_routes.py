"""Routes: fast travel by ferry and coach within a realm, the same way as portals
between realms. Journeys pass through waypoints and play themselves. See
docs/places.md and docs/journeys.md."""

from .conftest import drain, enter, ride, set_weather, texts


def of_type(events, kind):
    return [e for e in events if e["type"] == kind]


async def walk(world, pid, *directions):
    for direction in directions:
        await world.call("move", pid, direction)


async def test_the_coach_runs_through_its_waypoints_and_costs_a_fare(world):
    kevin, mara = await enter(world, "kevin"), await enter(world, "mara")
    await walk(world, "kevin", "north")
    await walk(world, "mara", "north")
    await drain(kevin), await drain(mara)

    await world.call("travel", "kevin", "")
    listing = of_type(await drain(kevin), "routes")[0]
    assert listing["text"].splitlines() == [
        "Routes from here. Type one of these to go (you have 20 coins):",
        "  TRAVEL VILLAGE GREEN: the High Road coach to Harrowlake. 3 coins, 4 stages.",
    ]

    await world.call("travel", "kevin", "village green")  # its destination, as listed
    events = await drain(kevin)
    assert texts(events)[0] == "You pay Bram three coins and climb into the coach. He cracks the whip."
    stage = of_type(events, "journey")[0]
    assert (stage["stage"], stage["stages"], stage["at"], stage["kind"]) == (1, 4, "switchbacks", "coach")
    assert stage["text"].startswith("The road climbs the mountain in tight switchbacks")
    assert await world.redis.get("PLAYER:kevin:room") == "switchbacks"
    assert of_type(events, "room")[-1]["room"]["waypoint"] is True
    assert of_type(events, "kit")[-1]["coins"] == 17
    assert "Kevin climbs into Bram's coach, and it rattles off towards the mountains." in texts(await drain(mara))

    # It moves on by itself after stage_seconds; nothing to press.
    await world.call("tick")
    assert of_type(await drain(kevin), "journey") == []
    await world.redis.zadd("alz:journeys", {"kevin": 0})
    await world.call("tick")
    assert of_type(await drain(kevin), "journey")[0]["at"] == "high_pass"

    await world.call("move", "kevin", "west")  # nowhere to walk mid-journey
    assert texts(await drain(kevin)) == ["You can't go that way."]
    await ride(world, "kevin")
    events = await drain(kevin)
    assert of_type(events, "journey")[-1].get("done") is True
    assert await world.redis.get("PLAYER:kevin:room") == "village_green"
    assert "REGION:harrowlake" in kevin.subs


async def test_riders_are_private(world):
    kevin, mara = await enter(world, "kevin"), await enter(world, "mara")
    for pid in ("kevin", "mara"):
        await walk(world, pid, "north")
        await world.call("travel", pid, "coach")  # each gets a coach of their own
    await drain(kevin), await drain(mara)
    assert await world.redis.get("PLAYER:mara:room") == "switchbacks"
    assert await world.redis.smembers("ROOM:switchbacks:players") == set()
    assert "ROOM:switchbacks" not in kevin.subs
    await world.call("look", "kevin")
    assert of_type(await drain(kevin), "room")[-1]["room"]["entities"] == []
    await world.call("say", "kevin", "Hello?")
    assert texts(await drain(mara)) == []


async def test_the_ferry_needs_the_island_known_the_ferryman_and_a_calm_enough_wind(world):
    kevin = await enter(world, "kevin")
    await world.call("goto", "kevin", "ferry_dock")
    await drain(kevin)
    await world.call("travel", "kevin", "ferry")
    assert texts(await drain(kevin)) == ["No route from here goes to 'ferry'. Type TRAVEL to see where you can go."]

    await world.redis.hset("PLAYER:kevin:regions", "saltmere", "discovered")  # as the sea chart would
    await set_weather(world.redis, "alzendor", 0, 0.5, -1)  # the coast makes it 0.7
    await world.call("travel", "kevin", "ferry")
    assert texts(await drain(kevin)) == ["Osric shakes his head at the water. He won't take the ferry out in a wind like this."]

    await set_weather(world.redis, "alzendor", 0, 0, -1)
    await world.redis.hset("ACCOUNT:kevin", "coins", 4)
    await world.call("travel", "kevin", "saltmere")
    assert texts(await drain(kevin)) == ["It costs 5 coins, and you have 4."]

    await world.redis.hset("ACCOUNT:kevin", "coins", 5)
    await world.redis.srem("ROOM:ferry_dock:npcs", "osric")
    await world.call("travel", "kevin", "ferry")
    assert texts(await drain(kevin)) == ["Osric isn't here to take you."]

    await world.redis.sadd("ROOM:ferry_dock:npcs", "osric")
    await world.call("travel", "kevin", "ferry")
    await ride(world, "kevin")
    assert await world.redis.get("PLAYER:kevin:room") == "saltmere_landing"
    assert await world.redis.hget("ACCOUNT:kevin", "coins") == "0"


async def test_asking_the_operator_about_passage_takes_their_route(world):
    kevin = await enter(world, "kevin")
    await walk(world, "kevin", "north")
    await drain(kevin)
    await world.call("ask", "kevin", "bram", "passage")
    assert await world.redis.get("PLAYER:kevin:room") == "switchbacks"


async def test_a_journey_waits_for_you_if_you_log_out_on_the_way(world):
    kevin = await enter(world, "kevin")
    await walk(world, "kevin", "north")
    await world.call("travel", "kevin", "coach")
    await ride(world, "kevin", stages=1)
    await world.call("disconnect", "kevin", "session-kevin", "", "Bye.")  # aboard is safe: gone at once
    await world.redis.zadd("alz:journeys", {"kevin": 0})
    await world.call("tick")  # offline: the journey doesn't move on without you
    assert await world.redis.get("PLAYER:kevin:room") == "high_pass"
    again = await enter(world, "kevin", session="again")
    events = await drain(again)
    assert of_type(events, "room")[-1]["room"]["id"] == "high_pass"
    assert of_type(events, "journey")[-1]["stage"] == 2  # where you left off
    await ride(world, "kevin")
    assert await world.redis.get("PLAYER:kevin:room") == "village_green"


async def test_instant_routes_need_no_waypoints(world):
    kevin = await enter(world, "kevin")
    await world.call("goto", "kevin", "chapel")
    await world.call("travel", "kevin", "ring")
    assert await world.redis.get("PLAYER:kevin:room") == "rime_landing"
    assert not await world.redis.exists("PLAYER:kevin:journey")


async def test_the_map_shows_routes_along_their_paths(world):
    kevin = await enter(world, "kevin")
    await walk(world, "kevin", "north")
    await drain(kevin)
    again = await enter(world, "kevin", session="again")
    full = of_type(await drain(again), "map")[0]
    [route] = full["routes"]
    assert (route["from"], route["to"], route["kind"], route["command"]) == (
        "market_square", "village_green", "coach", "TRAVEL VILLAGE GREEN")
    assert route["path"] == [[-160, -90], [-300, -140], [-450, -110], [-590, -30]]
    assert "switchbacks" not in {r["id"] for r in full["rooms"]}  # waypoints are drawn as the route, not as rooms
    assert "harrowlake" in {g["id"] for g in full["regions"]}  # the coach joins the regions


async def test_npcs_drop_coins(world):
    kevin = await enter(world, "kevin")
    await walk(world, "kevin", "north", "west", "south")  # the fish market
    await world.redis.hset("NPC:rat-1", "hp", 1)
    await drain(kevin)
    await world.call("use", "kevin", 1, "npc:rat-1")
    assert "You take the Dock Rat's 1 coin." in texts(await drain(kevin))
    assert await world.redis.hget("ACCOUNT:kevin", "coins") == "21"


async def test_riders_hear_themselves(world):
    kevin = await enter(world, "kevin")
    await walk(world, "kevin", "north")
    await world.call("travel", "kevin", "coach")
    await drain(kevin)
    await world.call("say", "kevin", "Lovely view.")
    assert texts(await drain(kevin)) == ['Kevin says, "Lovely view."']
