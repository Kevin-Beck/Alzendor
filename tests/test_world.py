"""The game rules and event delivery, against a real Redis."""

import asyncio
import json

import pytest

from alzendor.world import validate_seed

from .conftest import SEED, drain, enter, texts


async def test_entering_subscribes_to_every_level(world):
    kevin = await enter(world, "kevin")
    assert set(kevin.subs) == {"PLAYER:kevin", "ROOM:tavern", "AREA:old_quarter", "CITY:harrowgate", "CHANNEL:general"}
    events = await drain(kevin)
    assert events[-1]["type"] == "room"
    assert events[-1]["room"]["id"] == "tavern"
    assert events[-1]["room"]["exits"] == ["down", "east", "north"]
    assert events[-1]["cause"] == "enter"


async def test_room_events_reach_only_the_room(world):
    kevin, mara = await enter(world, "kevin"), await enter(world, "mara")
    await world.call("move", "mara", "north")
    await drain(kevin), await drain(mara)

    await world.call("emote", "kevin", "touch", "ground", "", "{actor} touches {target}.")
    assert texts(await drain(kevin)) == ["Kevin crouches and presses a palm to the worn floorboards."]
    assert await drain(mara) == []


async def test_moving_swaps_room_channels(world):
    kevin, mara = await enter(world, "kevin"), await enter(world, "mara")
    await drain(kevin), await drain(mara)

    await world.call("move", "kevin", "north")
    assert texts(await drain(mara)) == ["Kevin heads north."]
    events = await drain(kevin)
    assert [e["type"] for e in events] == ["leave", "map", "room"]
    assert "ROOM:market_square" in kevin.subs and "ROOM:tavern" not in kevin.subs

    await world.call("say", "mara", "Bye!")
    assert await drain(kevin) == []

    await world.call("move", "mara", "north")
    assert texts(await drain(kevin)) == ["Mara arrives from the south."]


async def test_crossing_into_another_area_swaps_area_channel(world):
    kevin = await enter(world, "kevin")
    await world.call("move", "kevin", "north")
    await world.call("move", "kevin", "west")
    await drain(kevin)
    assert "AREA:docks" in kevin.subs and "AREA:old_quarter" not in kevin.subs
    assert "CITY:harrowgate" in kevin.subs

    await world.call("ambient", "AREA:old_quarter", "A bell tolls.")
    await world.call("ambient", "AREA:docks", "Gulls scream.")
    await world.call("ambient", "CITY:harrowgate", "It rains.")
    assert texts(await drain(kevin)) == ["Gulls scream.", "It rains."]


async def test_missing_exit_is_a_private_notice(world):
    kevin, mara = await enter(world, "kevin"), await enter(world, "mara")
    await drain(kevin), await drain(mara)
    await world.call("move", "kevin", "west")
    assert texts(await drain(kevin)) == ["You can't go that way."]
    assert await drain(mara) == []
    assert await world.redis.get("PLAYER:kevin:room") == "tavern"


async def test_entering_a_room_has_no_gap_and_no_repeats(world):
    """Events from just before you enter are in the room snapshot, not the feed;
    events from just after are in the feed, not the snapshot."""
    kevin, mara = await enter(world, "kevin"), await enter(world, "mara")
    await world.call("move", "mara", "north")
    await drain(kevin)

    await world.call("say", "mara", "Before.")
    await world.call("move", "kevin", "north")
    await world.call("say", "mara", "After.")
    events = await drain(kevin)
    assert [e["type"] for e in events] == ["leave", "map", "room", "say"]
    assert [card["name"] for card in events[2]["room"]["entities"]] == ["Mara"]
    assert events[3]["text"] == 'Mara says, "After."'


async def test_everyone_sees_the_same_order(world):
    feeds = [await enter(world, pid) for pid in ("kevin", "mara", "ida")]
    for feed in feeds:
        await drain(feed)

    async def chatter(pid):
        for i in range(10):
            await world.call("say", pid, f"{pid} {i}")

    await asyncio.gather(*(chatter(pid) for pid in ("kevin", "mara", "ida")))
    seen = [[e["seq"] for e in await drain(feed)] for feed in feeds]
    assert seen[0] == seen[1] == seen[2] == sorted(seen[0])
    assert len(seen[0]) == 30


async def test_two_players_cannot_take_the_same_item(world):
    kevin, mara = await enter(world, "kevin"), await enter(world, "mara")
    await world.call("move", "kevin", "north")
    await world.call("move", "mara", "north")
    await drain(kevin), await drain(mara)

    await asyncio.gather(world.call("get", "kevin", "coin"), world.call("get", "mara", "coin"))
    seen = {pid: texts(await drain(feed)) for pid, feed in (("kevin", kevin), ("mara", mara))}
    assert all(sum("picks up the copper coin" in t for t in got) == 1 for got in seen.values())
    assert sorted(len(got) for got in seen.values()) == [1, 2]  # the loser also gets a private notice
    holders = [pid for pid in ("kevin", "mara") if await world.redis.sismember(f"PLAYER:{pid}:inv", "coin-1")]
    assert len(holders) == 1

    await world.call("drop", holders[0], "copper coin")
    assert await world.redis.sismember("ROOM:market_square:items", "coin-1")


async def test_inspect_is_private_with_a_room_emote(world):
    kevin, mara = await enter(world, "kevin"), await enter(world, "mara")
    await drain(kevin), await drain(mara)
    await world.call("inspect", "kevin", "hearth")
    assert texts(await drain(kevin)) == [
        "A wide stone hearth. The fire in it never seems to go out.",
        "Kevin examines the hearth.",
    ]
    assert texts(await drain(mara)) == ["Kevin examines the hearth."]


async def test_tell_is_private(world):
    kevin, mara, ida = [await enter(world, pid) for pid in ("kevin", "mara", "ida")]
    for feed in (kevin, mara, ida):
        await drain(feed)
    await world.call("tell", "kevin", "mara", "psst")
    assert texts(await drain(mara)) == ['Kevin tells you, "psst"']
    assert texts(await drain(kevin)) == ['You tell Mara, "psst"']
    assert await drain(ida) == []

    await world.call("tell", "kevin", "nobody", "hello?")
    assert texts(await drain(kevin)) == ["No one called nobody is online."]


async def test_chat_channels(world):
    kevin, mara = await enter(world, "kevin"), await enter(world, "mara")
    await world.call("move", "mara", "north")
    await drain(kevin), await drain(mara)

    await world.call("chat", "kevin", "general", "Hello all")
    assert texts(await drain(mara)) == ["[general] Kevin: Hello all"]
    assert texts(await drain(kevin)) == ["[general] Kevin: Hello all"]

    await world.call("create_channel", "kevin", "traders")
    await world.call("join", "mara", "traders")
    await world.call("chat", "mara", "traders", "Selling fish")
    assert texts(await drain(kevin)) == ["Kevin joined #traders.", "Mara joined #traders.", "[traders] Mara: Selling fish"]

    await world.call("leave", "mara", "traders")
    await world.call("chat", "kevin", "traders", "Gone?")
    assert texts(await drain(mara)) == ["Mara joined #traders.", "[traders] Mara: Selling fish", "Mara left #traders."]
    await world.call("chat", "mara", "traders", "Hello?")
    assert texts(await drain(mara)) == ["You aren't in #traders. Try 'join traders'."]


async def test_disconnect_leaves_the_room_and_keeps_chat_channels(world):
    kevin, mara = await enter(world, "kevin"), await enter(world, "mara")
    await drain(kevin), await drain(mara)
    assert await world.call("disconnect", "kevin", "session-kevin", "", "Bye.") == 1
    assert texts(await drain(mara)) == ["Kevin fades from view."]
    assert texts(await drain(kevin)) == ["Kevin fades from view."]
    assert kevin.ended == "Bye."
    assert not await world.redis.sismember("ROOM:tavern:players", "kevin")
    assert set(await world.redis.hkeys("PLAYER:kevin:subs")) == {"CHANNEL:general"}

    # Commands from a session that has left the world do nothing.
    assert await world.call("say", "kevin", "Hello?") == 0


async def test_logging_in_elsewhere_ends_the_old_connection(world):
    old = await enter(world, "kevin", session="old")
    mara = await enter(world, "mara")
    await drain(old), await drain(mara)

    new = await enter(world, "kevin", session="new")
    await drain(old)
    assert old.ended == "You connected from somewhere else."
    assert [(e["type"], e.get("cause")) for e in await drain(new) if e["type"] != "timing"] == [("map", None), ("room", "resume")]
    assert await drain(mara) == []  # no leave and re-enter for a takeover


async def test_resuming_replays_what_was_missed(world):
    kevin, mara = await enter(world, "kevin", session="first"), await enter(world, "mara")
    await drain(kevin)
    last_seen = kevin.cursor

    await world.call("say", "mara", "Are you there?")
    resumed = await enter(world, "kevin", session="second", since=last_seen)
    assert texts(await drain(resumed))[:1] == ['Mara says, "Are you there?"']


async def test_stale_connections_are_removed_after_the_cutoff(world):
    await enter(world, "kevin")
    beat = int(await world.redis.zscore("alz:online", "kevin"))
    assert await world.call("disconnect", "kevin", "", beat - 1, "Lost.") == 0
    assert await world.call("disconnect", "kevin", "", beat + 1, "Lost.") == 1


async def test_reseeding_keeps_live_state(world):
    kevin = await enter(world, "kevin")
    await world.call("move", "kevin", "north")
    await world.call("get", "kevin", "coin")
    await world.seed(SEED)
    assert await world.redis.sismember("PLAYER:kevin:inv", "coin-1")
    assert not await world.redis.sismember("ROOM:market_square:items", "coin-1")
    assert await world.redis.get("PLAYER:kevin:room") == "market_square"


async def test_map_shows_explored_rooms_and_glimpses_of_their_exits(world):
    kevin = await enter(world, "kevin")
    first = next(e for e in await drain(kevin) if e["type"] == "map")
    assert first["full"] is True
    rooms = {r["id"]: r for r in first["rooms"]}
    assert rooms["tavern"]["explored"] and rooms["tavern"]["pos"] == [40, 40]
    assert rooms["tavern"]["exits"] == {"north": "market_square", "east": "back_alley", "down": "cellar"}
    assert {rid for rid, r in rooms.items() if not r["explored"]} == {"market_square", "back_alley", "cellar"}
    assert "name" not in rooms["cellar"]  # glimpsed rooms stay unnamed until visited
    assert [a["id"] for a in first["areas"]] == ["old_quarter"]
    assert first["areas"][0]["bounds"] == [40, -20, 60, 48]
    assert first["areas"][0]["color"] == 5  # colours go in area id order: docks, forest_edge, …
    assert first["cities"][0]["id"] == "harrowgate"

    await world.call("move", "kevin", "north")
    update = next(e for e in await drain(kevin) if e["type"] == "map")
    assert update["full"] is False
    assert [r["id"] for r in update["rooms"] if r["explored"]] == ["market_square"]
    assert {r["id"] for r in update["rooms"] if not r["explored"]} == {"temple_steps", "smithy", "harbor_road", "back_alley"}

    await world.call("move", "kevin", "south")  # back somewhere known: nothing new to send
    assert [e["type"] for e in await drain(kevin)] == ["leave", "room"]

    # Reconnecting sends everything explored so far.
    again = await enter(world, "kevin", session="second")
    full = next(e for e in await drain(again) if e["type"] == "map")
    assert {r["id"] for r in full["rooms"] if r["explored"]} == {"tavern", "market_square"}


async def test_rooms_list_npcs_and_players_as_cards(world):
    kevin, mara = await enter(world, "kevin"), await enter(world, "mara")
    await drain(mara)
    room = [e for e in await drain(kevin) if e["type"] == "room"][-1]["room"]
    assert [c["id"] for c in room["entities"]] == ["npc:marta"]
    assert room["entities"][0] == {
        "id": "npc:marta", "kind": "npc", "name": "Marta", "label": "Human Innkeeper",
        "description": "round-faced, sleeves rolled up", "hp": 30, "max_hp": 30,
    }
    assert room["features"] == ["bar", "ground", "hearth"]
    assert room["items"] == [{"id": "map-1", "name": "worn map"}]

    await world.call("look", "mara")
    cards = [e for e in await drain(mara) if e["type"] == "room"][-1]["room"]["entities"]
    assert [c["id"] for c in cards] == ["npc:marta", "pc:kevin"]
    assert cards[1]["label"] == "Adventurer" and cards[1]["hp"] == cards[1]["max_hp"] == 100

    await world.call("move", "mara", "north")
    leave = [e for e in await drain(kevin) if e["type"] == "leave"][0]
    assert leave["entity_id"] == "pc:mara"
    await world.call("move", "mara", "south")
    arrive = [e for e in await drain(kevin) if e["type"] == "arrive"][0]
    assert arrive["entity"]["id"] == "pc:mara"


async def test_targets_by_id_pick_exactly_that_entity(world):
    kevin = await enter(world, "kevin")
    for direction in ("north", "west", "south"):
        await world.call("move", "kevin", direction)
    await drain(kevin)
    poke = ("{actor} pokes {target}.",)
    await world.call("emote", "kevin", "poke", "npc:rat-2", "", *poke)
    await world.call("inspect", "kevin", "npc:rat-2")
    assert texts(await drain(kevin)) == [
        "Kevin pokes the Dock Rat.",
        "Dock Rat, Vermin. fat and bold",
        "Kevin examines the Dock Rat.",
    ]

    await world.call("emote", "kevin", "poke", "npc:orc-1", "", *poke)  # not here
    await world.call("emote", "kevin", "poke", "pc:mara", "", *poke)  # not here either
    assert texts(await drain(kevin)) == ["You don't see that here.", "You don't see that here."]


async def test_named_npcs_read_naturally(world):
    kevin = await enter(world, "kevin")
    await drain(kevin)
    await world.call("emote", "kevin", "wave", "marta", "{actor} waves.", "{actor} waves at {target}.")
    assert texts(await drain(kevin)) == ["Kevin waves at Marta."]


async def test_describe_updates_your_card_for_the_room(world):
    kevin, mara = await enter(world, "kevin"), await enter(world, "mara")
    await drain(kevin), await drain(mara)
    await world.call("describe", "kevin", "tall, with a scarred lip")
    update = [e for e in await drain(mara) if e["type"] == "entity"]
    assert update[0]["entity"]["description"] == "tall, with a scarred lip"
    assert "text" not in update[0]


async def test_npcs_keep_their_state_across_reseeds(world):
    await world.redis.hset("NPC:orc-1", "hp", 12)
    await world.seed(SEED)
    assert await world.redis.hget("NPC:orc-1", "hp") == "12"


async def test_leaving_the_city_enters_another_region(world):
    kevin = await enter(world, "kevin")
    for direction in ("north", "north", "north"):  # tavern -> market -> temple steps -> north gate
        await world.call("move", "kevin", direction)
    await drain(kevin)
    assert "CITY:harrowgate" in kevin.subs

    await world.call("move", "kevin", "north")
    events = await drain(kevin)
    assert events[-1]["room"]["id"] == "woodland_path" and events[-1]["room"]["area"] == "the Forest Edge"
    assert "CITY:spiderwood" in kevin.subs and "AREA:forest_edge" in kevin.subs
    assert "CITY:harrowgate" not in kevin.subs and "AREA:old_quarter" not in kevin.subs
    update = next(e for e in events if e["type"] == "map")
    assert [c["id"] for c in update["cities"]] == ["spiderwood"]
    assert [a["id"] for a in update["areas"]] == ["forest_edge"]

    await world.call("ambient", "CITY:harrowgate", "Rain in the city.")
    await world.call("ambient", "CITY:spiderwood", "Something skitters overhead.")
    assert texts(await drain(kevin)) == ["Something skitters overhead."]


def test_seed_validation_catches_broken_maps():
    data = json.loads(SEED.read_text())
    validate_seed(data)
    data["rooms"]["tavern"]["exits"]["west"] = "nowhere"
    with pytest.raises(ValueError, match="unknown room 'nowhere'"):
        validate_seed(data)


@pytest.mark.parametrize("change, message", [
    (lambda rooms: rooms["back_alley"].update(pos=[60, 30]), "exit west to tavern is drawn 27° off west"),
    (lambda rooms: rooms["smithy"]["exits"].update(southwest="back_alley"), "the way back is north, not northeast"),
])
def test_seed_validation_checks_exits_match_the_map(change, message):
    data = json.loads(SEED.read_text())
    change(data["rooms"])
    with pytest.raises(ValueError, match=message):
        validate_seed(data)


@pytest.mark.parametrize("change, message", [
    (lambda d: d["gear"]["sword"].update(window=1300), "windows can't overlap"),
    (lambda d: d["gear"]["sword"].update(perfect_window=400), "windows can't overlap"),
    (lambda d: d["gear"]["sword"].update(effect="poison"), "effect must be"),
    (lambda d: d["gear"]["sword"].update(amounts=[1, 2]), "amounts must be"),
    (lambda d: d["gear"]["sword"].pop("whiff"), "missing whiff"),
    (lambda d: d["loadout"].append("banjo"), "unknown gear 'banjo'"),
    (lambda d: d["loadout"].append("sword"), "at most 3 slots"),
])
def test_seed_validation_checks_gear(change, message):
    data = json.loads(SEED.read_text())
    change(data)
    with pytest.raises(ValueError, match=message):
        validate_seed(data)


async def test_reseeding_replaces_the_gear_catalog(world):
    await world.redis.hset("GEAR:kick", "period", 1)
    await world.seed(SEED)
    assert await world.redis.hget("GEAR:kick", "period") == "2000"
    assert await world.redis.lrange("alz:default_loadout", 0, -1) == ["kick", "missile", "potion"]
