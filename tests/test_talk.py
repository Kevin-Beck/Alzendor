"""Talk: DISCUSS by target, topics that open and close, greetings, rapport,
quests offered and accepted, WHAT NOW and lures, and giving, gifts and
selling. See docs/talk-and-layout.md."""

import json

from .conftest import drain, enter, texts


def of_type(events, kind):
    return [e for e in events if e["type"] == kind]


def card(events, nid):
    return next(e for e in of_type(events, "room")[-1]["room"]["entities"] if e["id"] == "npc:" + nid)


async def set_topics(world, nid, topics):
    await world.redis.hset(f"NPC:{nid}", "topics", json.dumps(topics))


async def test_people_only_list_what_they_would_discuss_with_you(world):
    kevin = await enter(world, "kevin")
    await set_topics(world, "marta", {
        "ale": "Best in Harrowgate.",
        "family": {"text": "My mother kept this inn before me.", "requires": {"rapport": 3}},
        "cellar": {"text": "Something's down there.", "while": {"quest": "gf_word"}},
        "redcaps": {"text": "Redcaps. Of course.", "heard_from": ["halden"]},
    })
    await world.call("goto", "kevin", "tavern")
    assert card(await drain(kevin), "marta")["topics"] == ["ale", "quests", "rumours"]
    await world.call("discuss", "kevin", "marta", "family")  # not one of her topics for you: she gives nothing away
    assert texts(await drain(kevin))[-1] == 'Marta says, "Can\'t help you with that, I\'m afraid."'

    await world.redis.hset("PLAYER:kevin:rapport", "marta", 3)  # she knows you now
    await world.redis.hset("PLAYER:kevin:quests", "gf_word", "active")  # a quest opens a topic, for a while
    await world.redis.sadd("PLAYER:kevin:discussed", "halden|redcaps")  # and word spreads
    await world.call("look", "kevin")
    marta = card(await drain(kevin), "marta")
    assert marta["topics"] == ["ale", "cellar", "family", "quests", "redcaps", "rumours"]
    assert marta["rapport"] == "friendly"
    await world.redis.hset("PLAYER:kevin:quests", "gf_word", "done")  # and it closes when the moment's passed
    await world.call("look", "kevin")
    assert "cellar" not in card(await drain(kevin), "marta")["topics"]


async def test_greeting_someone_new_and_someone_you_know(world):
    kevin = await enter(world, "kevin")
    await world.call("goto", "kevin", "tavern")
    await drain(kevin)
    await world.call("greet", "kevin", "marta")
    said = [t for t in texts(await drain(kevin)) if "Harrowgate" not in t]  # courtesy counts with her people too
    assert said == ["Kevin greets Marta.", 'Marta says, "Welcome to the Gilded Tankard! I\'m Marta. Sit anywhere."',
                    'Marta says, "I might have work for you, if you want it."', "DISCUSS QUESTS to hear it."]
    assert await world.redis.hget("PLAYER:kevin:rapport", "marta") == "1"  # once a day
    await world.call("greet", "kevin", "marta")
    assert texts(await drain(kevin))[1] == 'Marta says, "Back again! The usual?"'
    assert await world.redis.hget("PLAYER:kevin:rapport", "marta") == "1"
    await world.call("goto", "kevin", "training_yard")  # someone with no greeting of their own
    await drain(kevin)
    await world.call("greet", "kevin", "holt")
    assert 'Sergeant Holt says, "Sergeant Holt. Good to meet you."' in texts(await drain(kevin))


async def test_quests_are_offered_and_answered(world):
    kevin = await enter(world, "kevin")
    await world.call("goto", "kevin", "mb_mill")
    await drain(kevin)
    await world.call("discuss", "kevin", "fenwick", "quests")  # the standard topic: whatever they need done
    events = await drain(kevin)
    assert texts(events)[1].startswith('Fenwick says, "Four wild boars')
    assert of_type(events, "guide")[-1]["text"] == "Type ACCEPT to take this on, or DECLINE."
    await world.call("decline", "kevin")
    assert texts(await drain(kevin)) == ['Fenwick says, "Suit yourself. You know where to find me."']
    assert not await world.redis.hget("PLAYER:kevin:quests", "gf_boars")
    await world.call("discuss", "kevin", "fenwick", "work")  # work, jobs, help: the same, unless they've a topic of that name
    await world.call("discuss", "kevin", "fenwick", "quests")  # offered again
    await world.call("accept", "kevin")
    events = await drain(kevin)
    assert 'Fenwick says, "Good."' in texts(events)
    assert of_type(events, "quest_update")[0]["new"] is True
    assert await world.redis.hget("PLAYER:kevin:quest:gf_boars", "giver") == "fenwick"
    await world.call("discuss", "kevin", "fenwick", "quests")
    events = await drain(kevin)
    assert texts(events)[-2:] == ['Fenwick says, "You know what I need. Get on with it."',
                                  "Rooting Boars: " + (await quest_goal(world, "gf_boars"))]

    await world.call("goto", "kevin", "tavern")
    await drain(kevin)
    await world.call("accept", "kevin")
    assert texts(await drain(kevin)) == ["Nobody's waiting on an answer from you."]


async def quest_goal(world, qid):
    quest = json.loads(await world.redis.hget("alz:quests", qid))
    return quest["steps"][quest["start"]]["goal"]


async def test_finishing_a_job_for_someone_brings_you_closer(world):
    kevin = await enter(world, "kevin")
    await world.redis.hset("PLAYER:kevin:quests", "gf_boars", "active")
    await world.redis.hset("PLAYER:kevin:quest:gf_boars", mapping={"step": "back", "count": 0, "giver": "fenwick"})
    await world.call("goto", "kevin", "mb_mill")
    await world.call("discuss", "kevin", "fenwick", "orchard")
    assert await world.redis.hget("PLAYER:kevin:quests", "gf_boars") == "done"
    assert await world.redis.hget("PLAYER:kevin:rapport", "fenwick") == "2"


async def test_what_now(world):
    kevin = await enter(world, "kevin")
    await world.call("goto", "kevin", "cellar")  # below the tavern, with Marta's work in it
    await drain(kevin)
    await world.call("whatnow", "kevin")
    text = of_type(await drain(kevin), "lure")[0]["text"]
    assert text.startswith("Close by") and text.endswith("you see the warm light of what may be an inn.")
    await world.call("goto", "kevin", "market_square")
    await drain(kevin)
    await world.call("whatnow", "kevin")
    assert of_type(await drain(kevin), "lure")[0]["text"] in (
        "Close by, to the south you see the warm light of what may be an inn.",
        "Close by, to the east, the ring of a hammer on an anvil.")
    await world.call("goto", "kevin", "tavern")
    await drain(kevin)
    await world.call("whatnow", "kevin")
    assert texts(await drain(kevin)) == ["Marta is right here, and might have work for you: GREET them."]

    await world.call("discuss", "kevin", "marta", "millbrook")
    await world.call("whatnow", "kevin")  # an answer owed
    assert texts(await drain(kevin))[-1] == "Marta is waiting for your answer: go back and ACCEPT."
    await world.call("accept", "kevin")
    await world.call("whatnow", "kevin")  # and then, the quest
    assert texts(await drain(kevin))[-1] == "Word from Millbrook: " + (await quest_goal(world, "gf_word"))


async def test_lures_come_unbidden_and_rumours_point_to_people(world):
    kevin = await enter(world, "kevin")
    await world.redis.hset("alz:rules", "lure_chance", 1)
    await world.call("goto", "kevin", "temple_steps")
    await drain(kevin)
    await world.call("move", "kevin", "south")  # to the market square
    [lure] = of_type(await drain(kevin), "lure")  # someone within reach, felt as you walk
    assert lure["text"].split(",")[0] in ("Close by", "Off to the north", "Off to the east", "Off to the south", "Off to the west",
                                          "Far off to the north", "Far off to the east", "Far off to the south", "Far off to the west",
                                          "Off to the northeast", "Off to the northwest", "Off to the southeast", "Off to the southwest",
                                          "Far off to the northeast", "Far off to the northwest", "Far off to the southeast",
                                          "Far off to the southwest") or lure["text"].startswith("Close by")
    assert len(await world.redis.keys("PLAYER:kevin:lured:*")) == 1
    await world.call("move", "kevin", "north")
    await drain(kevin)
    assert len(await world.redis.keys("PLAYER:kevin:lured:*")) == 2  # each at most once a day: another one, now

    await world.call("goto", "kevin", "smithy")
    await drain(kevin)
    await world.call("discuss", "kevin", "brannoc", "rumours")
    said = texts(await drain(kevin))[-1]
    assert said.startswith('Brannoc says, "') and "Brannoc" not in said[len("Brannoc says"):]  # word of someone else


async def test_giving_selling_and_gifts(world):
    kevin = await enter(world, "kevin")
    await world.redis.hset("ITEM:bear_claw", mapping={"name": "bear claw", "keywords": "claw", "tags": json.dumps(["claw"])})
    await world.redis.hset("ITEM:posy", mapping={"name": "posy of herbs", "keywords": "posy herbs", "tags": json.dumps(["herb"])})
    await world.redis.hset("NPC:marta", mapping={
        "wants": json.dumps({"says": "Claws. For the stew. Don't ask.", "items": [{"tag": "claw", "price": 4, "cap": 1}]}),
        "likes": json.dumps(["herb"]), "thanks": "Oh, lovely.", "refuse": "What would I want with that?"})
    await world.redis.sadd("PLAYER:kevin:inv", "bear_claw", "posy")
    await world.call("goto", "kevin", "tavern")
    marta = card(await drain(kevin), "marta")
    assert "wants" in marta["topics"]
    await world.call("discuss", "kevin", "marta", "buy")
    assert texts(await drain(kevin))[-1] == 'Marta says, "Claws. For the stew. Don\'t ask."'

    coins = int(await world.redis.hget("ACCOUNT:kevin", "coins") or 0)
    await world.call("give", "kevin", "claw", "marta")
    said = texts(await drain(kevin))
    assert said[:2] == ["Kevin sells the bear claw to Marta.", 'Marta says, "Done."']
    assert "You sell the bear claw for 4 coins." in said
    assert int(await world.redis.hget("ACCOUNT:kevin", "coins")) == coins + 4
    await world.redis.sadd("PLAYER:kevin:inv", "bear_claw")
    await world.call("give", "kevin", "claw", "marta")  # her daily cap
    assert texts(await drain(kevin)) == ['Marta says, "That\'s all of those I need today."']

    await world.call("give", "kevin", "posy", "marta")
    assert 'Marta says, "Oh, lovely."' in texts(await drain(kevin))
    assert await world.redis.hget("PLAYER:kevin:rapport", "marta") == "3"  # a sale (1), and a gift (2)
    await world.redis.sadd("PLAYER:kevin:inv", "posy")
    await world.call("give", "kevin", "posy", "marta")  # one gift a day
    assert texts(await drain(kevin)) == ['Marta says, "You\'ve given me plenty already. Keep it."']

    await world.redis.delete("PLAYER:kevin:gift:marta")
    await world.redis.hset("NPC:marta", "likes", "[]")
    await world.call("give", "kevin", "posy", "marta")
    assert texts(await drain(kevin)) == ['Marta says, "What would I want with that?"',
                                         "You offer the posy of herbs to Marta, but they won't take it."]
    assert await world.redis.sismember("PLAYER:kevin:inv", "posy")


async def test_creatures_drop_loot(world):
    kevin = await enter(world, "kevin")
    await world.redis.hset("ITEM:bear_claw", mapping={"name": "bear claw", "keywords": "claw"})
    await world.redis.hset("NPC:wild_boar_1", mapping={"hp": 1, "loot": json.dumps([{"item": "bear_claw", "chance": 1}])})
    await world.call("goto", "kevin", "ff_orchard")
    await drain(kevin)
    await world.call("use", "kevin", 1, "npc:wild_boar_1")
    assert "You take bear claw." in texts(await drain(kevin))
    assert await world.redis.sismember("PLAYER:kevin:inv", "bear_claw")


async def test_an_npc_moved_in_the_seed_moves_in_the_world(world, tmp_path):
    from alzendor.world import load_seed
    seed = load_seed("world/seed.json")
    seed["npcs"]["marta"]["room"] = "market_square"
    (tmp_path / "seed.json").write_text(json.dumps(seed))
    await world.seed(tmp_path / "seed.json")
    assert await world.redis.hget("NPC:marta", "room") == "market_square"
    assert await world.redis.sismember("ROOM:market_square:npcs", "marta")
    assert not await world.redis.sismember("ROOM:tavern:npcs", "marta")
