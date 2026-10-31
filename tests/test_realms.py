"""Realms: separate worlds with their own weather, joined only by passages and
gates. See docs/realms.md."""

import json

import pytest

from alzendor.world import validate_seed

from .conftest import SEED, drain, enter, set_weather, texts

TO_CHAPEL = ("north", "west", "west", "west", "west", "west", "north")


def of_type(events, kind):
    return [e for e in events if e["type"] == kind]


async def walk(world, pid, *directions):
    for direction in directions:
        await world.call("move", pid, direction)


async def probe(world, rid, t):
    return json.loads(await world.redis.fcall("weather_probe", 0, rid, t))


async def test_each_realm_has_its_own_weather(world):
    for realm in ("rimewaste", "stillsands"):
        await world.redis.delete(f"alz:weather_override:{realm}")
    for t in (0, 3.3, 77.7, 4321.5, 99999.9):
        rime = await probe(world, "frozen_lake", t)
        assert rime["temperature"] <= -0.7 and rime["energy"] >= 0.4 and rime["precipitation"] >= 0.5
        sands = await probe(world, "dune_sea", t)
        assert sands["temperature"] >= 0.8 and sands["energy"] <= -0.7 and sands["precipitation"] == -1


async def test_a_passage_npc_takes_you_to_another_realm_and_back(world):
    kevin = await enter(world, "kevin")
    await walk(world, "kevin", *TO_CHAPEL)
    await drain(kevin)
    await world.call("ask", "kevin", "ilse", "passage")
    events = await drain(kevin)
    assert "Sister Ilse traces a ring of frost in the air" in texts(events)[1]
    assert await world.redis.get("PLAYER:kevin:room") == "rime_landing"
    assert "REALM:rimewaste" in kevin.subs and "REALM:alzendor" not in kevin.subs
    assert "REGION:frostfell" in kevin.subs and "REGION:harrowlake" not in kevin.subs
    full = of_type(events, "map")[-1]
    assert full["full"] is True and full["realm"] == "rimewaste"
    assert [r["id"] for r in full["realms"]] == ["alzendor", "rimewaste"]
    assert {g["realm"] for g in full["regions"]} == {"alzendor", "rimewaste"}  # the home map is kept for the buttons
    assert of_type(events, "weather")[-1]["place"] == "Frostfell"

    await world.call("ask", "kevin", "veyra", "passage")
    await drain(kevin)
    assert await world.redis.get("PLAYER:kevin:room") == "chapel"
    assert "REALM:alzendor" in kevin.subs


async def test_realm_channels_reach_the_whole_realm(world):
    kevin, mara = await enter(world, "kevin"), await enter(world, "mara")
    await walk(world, "kevin", *TO_CHAPEL)
    await world.call("ask", "kevin", "ilse", "passage")
    await drain(kevin), await drain(mara)
    await world.call("ambient", "REALM:rimewaste", "The ground shudders.")
    assert texts(await drain(kevin)) == ["The ground shudders."]
    assert await drain(mara) == []


async def test_the_rift_is_one_way_and_the_portal_home_needs_wind_and_no_wraiths(world):
    kevin = await enter(world, "kevin")
    await walk(world, "kevin", *TO_CHAPEL)
    await world.call("ask", "kevin", "ilse", "passage")
    await walk(world, "kevin", "north", "north")  # past the ice wraith to the rift
    await drain(kevin)
    await world.call("look", "kevin")
    assert "Routes: TRAVEL RIFT FALL (the rift). Type TRAVEL for details." in texts(await drain(kevin))[0]
    await world.call("travel", "kevin", "")
    assert of_type(await drain(kevin), "routes")[0]["text"].splitlines()[1] == (
        "  TRAVEL RIFT FALL: the rift to somewhere you know nothing about. Free, instant.")
    await world.call("travel", "kevin", "rift")
    assert await world.redis.get("PLAYER:kevin:room") == "rift_fall"
    assert of_type(await drain(kevin), "room")[-1]["room"]["exits"] == ["east"]  # no way back up

    await walk(world, "kevin", "east", "east")
    await world.redis.delete("PLAYER:kevin:foes")  # outrun the scorpion
    await set_weather(world.redis, "stillsands", 0.95, -0.9, -1)  # dead still
    await drain(kevin)
    await world.call("travel", "kevin", "portal")
    assert texts(await drain(kevin)) == [
        "The portal frame stays dark. It needs the still air to stir, and no wraiths standing in your way."]

    await set_weather(world.redis, "stillsands", 0.95, -0.6, -1)  # a breath of wind, but the wraiths are here
    await world.call("travel", "kevin", "portal")
    assert await world.redis.get("PLAYER:kevin:room") == "sun_altar"

    await world.redis.srem("ROOM:sun_altar:npcs", "sandwraith-1", "sandwraith-2")  # cut down
    await world.call("travel", "kevin", "portal")
    await drain(kevin)
    assert await world.redis.get("PLAYER:kevin:room") == "temple_steps"
    assert "REALM:alzendor" in kevin.subs and "REALM:stillsands" not in kevin.subs


async def test_a_storm_glass_teaches_the_rimewastes_skies(world):
    kevin = await enter(world, "kevin")
    await walk(world, "kevin", *TO_CHAPEL)
    await world.call("ask", "kevin", "ilse", "passage")
    await walk(world, "kevin", "north", "west")  # Ember Hollow, the one warm place
    await drain(kevin)
    await world.call("get", "kevin", "glass")
    assert "With the storm glass you can read the skies over the Rimewaste now (WEATHER)." in texts(await drain(kevin))
    assert await world.redis.hget("PLAYER:kevin:lore", "rimewaste") == ""
    await world.call("move", "kevin", "east")
    weather = of_type(await drain(kevin), "weather")[-1]
    assert weather["exact"] is True and len(weather["forecast"]) == 8


@pytest.mark.parametrize("change, message", [
    (lambda d: d["realms"]["rimewaste"].update(home=True), "exactly one realm must be the home realm"),
    (lambda d: d["regions"]["frostfell"].update(realm="faerie"), "unknown realm 'faerie'"),
    (lambda d: d["realms"]["rimewaste"]["weather"].update(energy=[0.7, 2]), "weather needs \\[centre, spread\\]"),
    (lambda d: d["rooms"]["rime_landing"]["exits"].update(south="tavern"), "leads into another realm"),
    (lambda d: d["routes"]["sun-portal"].update(to="nowhere"), "to is not a room: 'nowhere'"),
    (lambda d: d["routes"]["portal-home"].update(by="ilse"), "operator 'ilse' must be an NPC in the room it leaves from"),
    (lambda d: d["routes"]["rift"].update(stages=["You fall."]), "needs a 'via' room"),
    (lambda d: d["routes"]["coach-to-harrowlake"].update(fare=-1), "fare must be a whole number"),
    (lambda d: d["items"]["glass-1"].update(forecasts=["nowhere"]), "forecasts unknown realm 'nowhere'"),
    (lambda d: d["routes"]["rift"].update(**{"from": "rime_landing", "to": "chapel"}), "routes from one room need different destinations"),
    (lambda d: d["factions"]["orcs"].update(realm="faerie"), "faction orcs: unknown realm 'faerie'"),
])
def test_seed_validation_checks_realms(change, message):
    data = json.loads(SEED.read_text())
    change(data)
    with pytest.raises(ValueError, match=message):
        validate_seed(data)
