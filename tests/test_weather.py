"""Weather: the shared sky, what it does to gear, travel, sight and NPCs, and
forecasts. See docs/weather.md."""

import json
import random

import pytest

from alzendor import weather
from alzendor.world import load_seed, validate_seed

from .conftest import SEED, drain, enter, set_weather, texts


def of_type(events, kind):
    return [e for e in events if e["type"] == kind]


async def probe(world, rid, t=""):
    return json.loads(await world.redis.fcall("weather_probe", 0, rid, t))


async def walk(world, pid, *directions):
    for direction in directions:
        await world.call("move", pid, direction)


# The sky -------------------------------------------------------------------------


def test_the_sky_is_temperate_a_third_of_the_time_and_wet_half():
    params = weather.realm_params("alzendor-1", "alzendor")
    rng = random.Random(1)
    samples = [weather.weather(params, rng.uniform(0, 1e6)) for _ in range(20000)]
    temperate = sum(abs(w["temperature"]) < 0.5 and abs(w["energy"]) < 0.5 for w in samples) / len(samples)
    wet = sum(w["precipitation"] > 0 for w in samples) / len(samples)
    deluge = sum(w["precipitation"] > 0 and w["precipitation"] ** 2 > 0.8 for w in samples) / len(samples)
    assert 0.30 < temperate < 0.37
    assert 0.47 < wet < 0.53
    assert 0.03 < deluge < 0.08


def test_the_stretch_sends_the_middle_to_the_middle():
    assert weather.stretch(0) == 0
    assert weather.stretch(weather.CENTER) == pytest.approx(0.5)
    assert weather.stretch(-1) == -1 and weather.stretch(1) == 1


async def test_lua_computes_the_same_sky_as_python(world):
    await world.redis.delete("alz:weather_override:alzendor")
    params = weather.realm_params("alzendor-1", "alzendor")
    for t in (0, 12.5, 1000.25, 98765.4):
        lua = await probe(world, "market_square", t)  # no terrain there
        python = weather.weather(params, t)
        for axis in weather.AXES:
            assert lua[axis] == pytest.approx(python[axis], abs=1e-9)


async def test_climates_and_terrain(world):
    tavern = await probe(world, "tavern")  # indoors: always dead neutral and dry
    assert tavern["indoor"] is True and [tavern[a] for a in weather.AXES] == [0, 0, -1]
    lair = await probe(world, "silk_cavern")  # an exceptional place keeps its own climate
    assert lair["indoor"] is True and lair["temperature"] == 0.85
    pier = await probe(world, "pier")  # the coast is windier
    assert pier["energy"] == pytest.approx(0.2) and "indoor" not in pier


async def test_rain_snow_and_hail_come_from_the_temperature(world):
    await set_weather(world.redis, "alzendor", 0.3, 0, 0.8)
    assert (await probe(world, "market_square"))["falling"] == "rain"
    await set_weather(world.redis, "alzendor", -0.6, 0, 0.8)
    assert (await probe(world, "market_square"))["falling"] == "snow"
    await set_weather(world.redis, "alzendor", -0.6, 0.8, 0.8)
    w = await probe(world, "market_square")
    assert w["falling"] == "hail" and w["zone"] == "Gale"
    assert w["summary"] == "cold and howling, heavy hail"


# Gear -----------------------------------------------------------------------------


async def kit_gear(feed, gid):
    kit = of_type(await drain(feed), "kit")[-1]
    return next(g for g in kit["gear"] if g["id"] == gid)


async def test_gear_is_strongest_at_its_spot(world):
    kevin = await enter(world, "kevin")
    await world.redis.sadd("PLAYER:kevin:gear", "stormcall")
    await walk(world, "kevin", "north")
    await set_weather(world.redis, "alzendor", 0.6, 0.8, 1)  # its spot, in a downpour
    await world.call("set_weather", "kevin", 0.6, 0.8, 1)
    storm = await kit_gear(kevin, "stormcall")
    assert storm["weather"] == {"temperature": 0.6, "energy": 0.8, "precipitation": "wet", "tier": "orange"}
    assert storm["now"]["amounts"] == [36, 47, 73]  # x2, and x1.3 for the rain

    await world.call("set_weather", "kevin", 0, 0, -1)  # a mild dry day: out of its element
    storm = await kit_gear(kevin, "stormcall")
    assert storm["now"]["amounts"] == [0, 0, 0]
    assert storm["now"]["mods"][0] == {"label": "Weather: out of its element", "pct": -100}


async def test_resilience_softens_penalties_but_keeps_bonuses(world):
    kevin = await enter(world, "kevin")
    await world.redis.sadd("PLAYER:kevin:gear", "stormcall")
    await world.redis.hset("ACCOUNT:kevin", "stat:resilience", 5)
    await walk(world, "kevin", "north")
    await world.call("set_weather", "kevin", 0, 0, -1)
    storm = await kit_gear(kevin, "stormcall")
    assert storm["now"]["amounts"] == [7, 9, 14]  # half, not nothing
    assert storm["now"]["mods"][-1]["label"] == "Resilience 5: penalties softened"

    await world.call("set_weather", "kevin", 0.6, 0.8, 1)
    assert (await kit_gear(kevin, "stormcall"))["now"]["amounts"] == [36, 47, 73]  # the bonus is untouched


async def test_heat_slows_beats_and_wind_narrows_windows(world):
    kevin = await enter(world, "kevin")
    await walk(world, "kevin", "north")
    await world.call("set_weather", "kevin", 1, 1, -1)  # scorching and howling
    kick = await kit_gear(kevin, "kick")
    assert kick["now"]["period_ms"] == 2600 and kick["now"]["grace_ms"] == 210
    await world.call("use", "kevin", 1, "")  # the kick needs a target, so try the rhythm with the potion
    await world.call("use", "kevin", 3, "")
    timing = [e for e in of_type(await drain(kevin), "timing") if e["active"]][-1]
    assert timing["period_ms"] == 6500  # 5000, 30% slower in the heat


# Travel, sight and NPCs -------------------------------------------------------------


async def test_deep_snow_holds_a_move_up_until_tick(world):
    kevin, mara = await enter(world, "kevin"), await enter(world, "mara")
    await walk(world, "kevin", "north")
    await walk(world, "mara", "north")
    await world.redis.hset("REALM:alzendor:ground", mapping={"snow": 1, "mud": 0})
    await drain(kevin), await drain(mara)

    await world.call("move", "kevin", "east")
    events = await drain(kevin)
    travel = of_type(events, "travel")[0]
    assert travel["delay_ms"] == 3000 and travel["cause"] == "snow"
    assert texts(events) == ["You take high steps, trying to clear the snow that impedes you.",
                             "Kevin starts wading east through the snow."]
    assert await world.redis.get("PLAYER:kevin:room") == "market_square"
    await world.call("move", "kevin", "west")
    assert texts(await drain(kevin)) == ["You're still making your way."]

    await world.call("tick")  # not due yet
    assert await world.redis.get("PLAYER:kevin:room") == "market_square"
    await world.redis.zadd("alz:pending_moves", {"kevin": 0})  # skip the wait
    await world.call("tick")
    assert await world.redis.get("PLAYER:kevin:room") == "smithy"
    assert "Kevin heads east." in texts(await drain(mara))


async def test_resilience_shortens_travel_delays(world):
    kevin = await enter(world, "kevin")
    await walk(world, "kevin", "north")
    await world.redis.hset("REALM:alzendor:ground", mapping={"snow": 1, "mud": 0})
    await world.redis.hset("ACCOUNT:kevin", "stat:resilience", 2)
    await drain(kevin)
    await world.call("move", "kevin", "east")
    assert of_type(await drain(kevin), "travel")[0]["delay_ms"] == 2400


async def test_heavy_rain_hides_new_ways_and_neighbouring_regions(world):
    kevin = await enter(world, "kevin")
    await world.redis.delete("PLAYER:kevin:regions", "PLAYER:kevin:glimpsed")
    await world.redis.hset("PLAYER:kevin:regions", "harrowgate", "explored")
    await set_weather(world.redis, "alzendor", 0.2, 0, 0.9)
    await drain(kevin)

    await world.call("move", "kevin", "north")
    events = await drain(kevin)
    room = of_type(events, "room")[-1]
    assert room["room"]["exits"] == ["south"] and room["room"]["exits_hidden"] is True
    assert "Exits: south (the rain hides any other ways on)" in room["text"]
    assert {r["id"] for r in of_type(events, "map")[0]["rooms"]} == {"market_square"}  # no glimpses
    assert await world.redis.hgetall("PLAYER:kevin:regions") == {"harrowgate": "explored"}

    # Once it clears, looking around finds the ways on, and moving finds the neighbours.
    await set_weather(world.redis, "alzendor", 0.2, 0, -0.5)
    await world.call("look", "kevin")
    events = await drain(kevin)
    assert len(of_type(events, "room")[-1]["room"]["exits"]) == 5
    assert "smithy" in {r["id"] for r in of_type(events, "map")[0]["rooms"]}
    await world.call("move", "kevin", "east")
    assert set(await world.redis.hkeys("PLAYER:kevin:regions")) == {"harrowgate", "harrowlake", "spiderwood", "harrow_mountains", "greyfold"}


async def test_spiders_keep_out_of_the_rain(world):
    await world.call("weather_tick")
    assert await world.redis.sismember("ROOM:web_tunnel:npcs", "spider-1")
    await set_weather(world.redis, "alzendor", 0, 0, 0.5)
    await world.call("weather_tick")
    assert not await world.redis.sismember("ROOM:web_tunnel:npcs", "spider-1")
    assert await world.redis.hget("NPC:spider-1", "hidden") == "1"
    leave = json.loads((await world.redis.xrevrange("ROOM:web_tunnel", count=1))[0][1]["e"])
    assert leave["text"] == "The Giant Spider scuttles up into the dark as the wet comes in."

    await set_weather(world.redis, "alzendor", 0, 0, -0.5)
    await world.call("weather_tick")
    assert await world.redis.sismember("ROOM:web_tunnel:npcs", "spider-1")


async def test_regions_hear_when_their_weather_turns_and_ground_builds_up(world):
    kevin = await enter(world, "kevin")
    await walk(world, "kevin", "north")
    await world.call("weather_tick")  # remembers the starting condition
    await drain(kevin)
    await set_weather(world.redis, "alzendor", -0.8, 0.2, 0.9)
    await world.redis.hset("REALM:alzendor:ground", "at", 0)  # a long time ago: as long as ground counts (2 h)
    await world.call("weather_tick")
    events = await drain(kevin)
    assert "The weather over Alzendor turns: freezing and gusty, driving snow." in texts(events)
    assert of_type(events, "weather")[-1]["ground"]["snow"] == 1


# Forecasts, lore and boons ------------------------------------------------------------


async def test_without_lore_the_weather_is_rough_and_tamsin_teaches_it(world):
    kevin = await enter(world, "kevin")
    await walk(world, "kevin", "north", "west", "west")  # the pier
    await set_weather(world.redis, "alzendor", 0.33, 0.1, -0.7)
    await drain(kevin)
    await world.call("weather", "kevin")
    events = await drain(kevin)
    rough = of_type(events, "weather")[-1]
    assert rough["exact"] is False and rough["temperature"] == 0.5 and "forecast" not in rough
    assert "can't read these skies" in texts(events)[0]

    await walk(world, "kevin", "north")  # the lighthouse
    await drain(kevin)
    await world.call("ask", "kevin", "tamsin", "weather")
    events = await drain(kevin)
    assert texts(events)[1].startswith("Old Tamsin shows you how to read the skies over Alzendor.")
    exact = of_type(events, "weather")[-1]
    assert exact["exact"] is True and exact["temperature"] == 0.33
    assert len(exact["forecast"]) == 8 and exact["forecast"][-1]["minutes"] == 60  # the next hour

    # Better standing with her people sees further ahead.
    await world.redis.hset("PLAYER:kevin:rep:harrowfolk", mapping={"affinity": 25, "respect": 0})
    await world.call("weather", "kevin")
    events = await drain(kevin)
    assert len(of_type(events, "weather")[-1]["forecast"]) == 16
    assert texts(events)[0].splitlines()[-1].startswith("  In 2 h: ")


async def test_only_friends_are_taught(world):
    kevin = await enter(world, "kevin")
    await walk(world, "kevin", "north", "west", "west", "north")
    await world.redis.hset("PLAYER:kevin:rep:harrowfolk", mapping={"affinity": -60, "respect": 0})
    await drain(kevin)
    await world.call("ask", "kevin", "tamsin", "weather")
    assert texts(await drain(kevin)) == ["Old Tamsin has nothing to say to you."]  # hostile: no talk at all
    assert not await world.redis.exists("PLAYER:kevin:lore")


async def test_faction_boons_add_to_stats(world):
    kevin = await enter(world, "kevin")
    await drain(kevin)
    await world.redis.hset("PLAYER:kevin:rep:wardens", mapping={"affinity": 20, "respect": 0})
    await world.call("train", "kevin", "resilience")  # no points: just to get a character update
    await world.redis.hset("ACCOUNT:kevin", "points", 1)
    await world.call("train", "kevin", "resilience")
    character = of_type(await drain(kevin), "character")[-1]
    assert character["stats"]["resilience"] == 2 and character["trained"]["resilience"] == 1
    boon = next(b for b in character["boons"] if b["stat"] == "resilience")
    assert boon["active"] is True and boon["faction"] == "The Wardens of the Wood"


# Pack and loadout ----------------------------------------------------------------------


async def test_a_full_pack_cannot_take_more(world):
    kevin = await enter(world, "kevin")
    await world.redis.hset("alz:rules", "pack_size", 1)  # the spare dagger fills it
    await drain(kevin)
    await world.call("get", "kevin", "map")
    assert texts(await drain(kevin)) == ["Your pack is full (1/1). Drop something first."]


async def test_no_changing_gear_mid_fight(world):
    kevin = await enter(world, "kevin")
    await walk(world, "kevin", "north", "west", "south")  # the fish market
    await world.call("use", "kevin", 1, "npc:rat-1")
    await drain(kevin)
    await world.call("equip", "kevin", "dagger", 2)
    assert texts(await drain(kevin)) == ["You can't change your gear mid-fight."]


# The seed -------------------------------------------------------------------------------


@pytest.mark.parametrize("change, message", [
    (lambda d: d["rooms"]["silk_cavern"]["climate"].update(temperature=3), "climate needs temperature, energy, precipitation"),
    (lambda d: d["rooms"]["tavern"].update(climate={"temperature": 1, "energy": 0, "precipitation": -1}), "indoor rooms are always neutral"),
    (lambda d: d["gear"]["dagger"]["weather"].update(tier="gold"), "tier must be one of"),
    (lambda d: d["gear"]["dagger"]["weather"].update(precipitation="damp"), "precipitation must be one of"),
    (lambda d: d["kinds"].pop("Weapon"), "kind 'Weapon' has no default"),
    (lambda d: d["npcs"]["tamsin"].update(forecasts=["atlantis"]), "forecasts unknown realm 'atlantis'"),
    (lambda d: d["npcs"]["spider-1"].update(active_when={"precipitation": [1, 0]}), "active_when needs"),
    (lambda d: d["factions"]["wardens"]["boons"][0].update(stat="luck"), "boon for unknown stat 'luck'"),
    (lambda d: d["terrain_weather"]["forest"].update(humidity=1), "unknown axis 'humidity'"),
])
def test_seed_validation_checks_weather(change, message):
    data = load_seed(SEED)
    change(data)
    with pytest.raises(ValueError, match=message):
        validate_seed(data)


async def test_bitter_cold_slows_healing_outdoors(world):
    kevin = await enter(world, "kevin")
    await walk(world, "kevin", "north")
    await world.redis.hset("ACCOUNT:kevin", "hp", 50)
    await world.redis.sadd("alz:wounded", "kevin")
    await world.call("upkeep")
    assert await world.redis.hget("ACCOUNT:kevin", "hp") == "52"
    await set_weather(world.redis, "alzendor", -1, 0, -1)
    await world.call("upkeep")
    assert await world.redis.hget("ACCOUNT:kevin", "hp") == "53"  # half as fast
