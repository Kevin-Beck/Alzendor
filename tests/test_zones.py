"""The zones beyond the starting realms: zone files, exposure, watchful
enemies, creatures of the night, and quests that give gear. See docs/zones.md."""

import json

import pytest

from alzendor.world import load_seed

from .conftest import drain, enter, texts


def of_type(events, kind):
    return [e for e in events if e["type"] == kind]


async def create(world, pid, cls="fighter", background="sailor"):
    await world.redis.hset(f"ACCOUNT:{pid}", "name", pid.capitalize())
    assert await world.call("create_character", pid, cls, "human", "second_wind", background) == ""
    return await enter(world, pid)


def test_zone_files_add_to_the_seed_and_cant_redefine_it(tmp_path):
    (tmp_path / "zones").mkdir()
    (tmp_path / "seed.json").write_text(json.dumps({"rooms": {"a": {}}, "ambient": [1]}))
    (tmp_path / "zones" / "more.json").write_text(json.dumps({"_note": "x", "rooms": {"b": {}}, "ambient": [2]}))
    assert load_seed(tmp_path / "seed.json") == {"rooms": {"a": {}, "b": {}}, "ambient": [1, 2]}
    (tmp_path / "zones" / "clash.json").write_text(json.dumps({"rooms": {"a": {}}}))
    with pytest.raises(ValueError, match="clash.json: rooms already has a"):
        load_seed(tmp_path / "seed.json")


async def test_exposure_wears_you_down_until_shelter_or_the_right_gear(world):
    kevin = await create(world, "kevin")
    await world.call("goto", "kevin", "rw_edge")  # the Rotwood's edge: no spores yet
    await drain(kevin)
    await world.call("move", "kevin", "northeast")  # the Rotting Groves: spores, 5 steps
    exposure = of_type(await drain(kevin), "exposure")[-1]
    assert (exposure["kind"], exposure["level"], exposure["max"]) == ("spores", 1, 5)
    for direction in ("northeast", "southwest", "northeast", "southwest"):  # Bloom Hollow and back
        await world.call("move", "kevin", direction)
    assert "There's mould in your throat. You need clean air: a burned clearing." in texts(await drain(kevin))
    hp = int(await world.redis.hget("ACCOUNT:kevin", "hp"))
    await world.call("move", "kevin", "northeast")  # the sixth step
    assert "The spores are growing in your lungs. (18)" in texts(await drain(kevin))
    assert int(await world.redis.hget("ACCOUNT:kevin", "hp")) == hp - 18

    await world.call("move", "kevin", "southwest")
    await world.call("move", "kevin", "northwest")  # the Burned Clearing: a shelter
    events = await drain(kevin)
    assert "The burned ground is clean. You cough the spores out." in texts(events)
    assert of_type(events, "exposure")[-1]["level"] == 0

    await world.redis.sadd("PLAYER:kevin:wardrobe", "spore_mask")
    await world.call("wear", "kevin", "mask")
    await world.call("move", "kevin", "southeast")
    exposure = of_type(await drain(kevin), "exposure")[-1]
    assert (exposure["level"], exposure["protected"]) == (0, "Spore Mask")


async def test_watchful_enemies_can_be_slipped_past(world):
    kevin = await create(world, "kevin")
    await world.call("goto", "kevin", "sf_mire")
    await world.redis.rpush("alz:test_rolls", 0.0)  # a good Poise check
    await drain(kevin)
    await world.call("move", "kevin", "southeast")  # Gnasher's Wallow
    events = await drain(kevin)
    assert "Old Gnasher hasn't noticed you. Don't touch it, and don't linger. (Poise check; CREEP helps)" in texts(events)
    assert not await world.redis.exists("NPC:old_gnasher:foes")
    gnasher = next(c for c in of_type(events, "room")[-1]["room"]["entities"] if c["id"] == "npc:old_gnasher")
    assert gnasher["wary"] is True

    await world.call("move", "kevin", "southwest")  # past him, and back: still unnoticed for a while
    await world.call("move", "kevin", "northeast")
    assert not await world.redis.exists("NPC:old_gnasher:foes")

    await world.redis.delete("PLAYER:kevin:unseen:old_gnasher")
    await world.redis.rpush("alz:test_rolls", 0.99)  # a bad one
    await world.call("move", "kevin", "southwest")
    await world.call("move", "kevin", "northeast")
    assert await world.redis.zscore("NPC:old_gnasher:foes", "kevin") is not None


async def test_some_things_only_come_out_at_night(world):
    await world.call("weather_tick")  # midday: the Hollow Rider is gone
    assert not await world.redis.sismember("ROOM:gm_gibbet:npcs", "hollow_rider")
    await world.redis.set("alz:clock_override", 23)
    await world.call("weather_tick")
    assert await world.redis.sismember("ROOM:gm_gibbet:npcs", "hollow_rider")


async def test_quests_can_give_gear(world):
    kevin = await create(world, "kevin")
    await world.call("goto", "kevin", "smithy")
    await world.call("ask", "kevin", "brannoc", "iron")
    await world.call("accept", "kevin")
    await world.call("goto", "kevin", "ff_ditch")
    await world.call("get", "kevin", "iron")
    await world.call("goto", "kevin", "smithy")
    await drain(kevin)
    await world.call("use_item", "kevin", "iron", "brannoc")
    events = await drain(kevin)
    assert "You receive Greyfold Billhook (slot gear: EQUIP GREYFOLD BILLHOOK <slot>, or the Inventory)." in texts(events)
    assert "greyfold_billhook" in {g["id"] for g in of_type(events, "kit")[-1]["gear"]}


async def test_a_realm_is_found_where_it_makes_sense(world):
    """The Font in the Sunken Abbey opens onto Mirefall, but only in the rain."""
    kevin = await create(world, "kevin")
    await world.call("goto", "kevin", "sa_undercroft")
    await drain(kevin)
    await world.call("travel", "kevin", "font")
    assert texts(await drain(kevin)) == ["The Font is still. It only opens when it's raining up above."]
    await world.redis.hset("alz:weather_override:alzendor", mapping={"precipitation": 0.6})
    await world.call("travel", "kevin", "font")
    assert await world.redis.get("PLAYER:kevin:room") == "mf_landing"


def test_nothing_comes_back_in_under_five_minutes():
    seed = load_seed("world/seed.json")
    quick = [nid for nid, n in seed["npcs"].items() if n.get("attacks") and n.get("respawn", 300) < 300]
    assert quick == []
