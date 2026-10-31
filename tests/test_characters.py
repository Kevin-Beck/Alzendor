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


async def test_a_reset_while_still_in_the_world_starts_fresh(world):
    """Resetting a connected (or linkdead) player takes them out of the world,
    so their new character gets the intro and first quest, not a reconnect."""
    kevin = await create(world, "kevin")
    await drain(kevin)
    await world.call("reset_character", "kevin")
    await drain(kevin)
    assert kevin.ended == "Your character was reset. Log in again to make a new one."
    assert not await world.redis.exists("PLAYER:kevin:session")
    assert await world.redis.zscore("alz:online", "kevin") is None
    assert await world.call("create_character", "kevin", "mage", "human", "haggler", "merchant") == ""
    events = await drain(await enter(world, "kevin", session="session-2"))
    assert await world.redis.get("PLAYER:kevin:room") == "stall_row"
    assert of_type(events, "intro")[0]["text"].startswith("Your first day running the family stall")
    assert any(t.startswith("New quest: Opening the Stall.") for t in texts(events))


async def test_creation_checks_its_choices(world):
    assert await world.call("create_character", "kevin", "bard", "elf", "starsight", "sailor") == "Choose a class."
    assert await world.call("create_character", "kevin", "rogue", "elf", "bloodrhythm", "sailor") == "Choose a passive from your ancestry."


async def test_a_class_can_only_use_its_kinds_of_gear(world):
    kevin = await create(world, "kevin", cls="fighter", ancestry="human", passive="second_wind")
    await world.redis.sadd("PLAYER:kevin:gear", "firebolt")
    await drain(kevin)
    await world.call("equip", "kevin", "firebolt", 1)
    assert texts(await drain(kevin)) == ["A Fighter can't use spell gear like Firebolt."]


async def test_talents_come_every_third_level_and_open_by_rank(world):
    kevin = await create(world, "kevin", cls="mage", ancestry="human", passive="quick_study")
    await world.redis.hset("ACCOUNT:kevin", "level", 2)  # level 2 is only a stat point
    await drain(kevin)
    await world.call("learn", "kevin", "spark")
    assert texts(await drain(kevin)) == ["You have no talent to learn yet: one comes every third level (3, 6, 9 … 18)."]
    await world.redis.hset("ACCOUNT:kevin", "level", 9)  # three talents' worth
    for talent in ("spark", "frost shard"):
        await world.call("learn", "kevin", talent)
    await drain(kevin)
    await world.call("learn", "kevin", "ice lance")  # rank 2 opens after two
    assert texts(await drain(kevin))[0] == "You learn Ice Lance. EQUIP ICE LANCE <slot> to use it."
    await world.redis.hset("ACCOUNT:kevin", "level", 15)
    await world.call("learn", "kevin", "tempest")
    assert texts(await drain(kevin)) == ["Tempest opens after 4 talents."]
    await world.call("learn", "kevin", "chain lightning")  # the one link: needs Spark, which Kevin has
    assert texts(await drain(kevin))[0].startswith("You learn Chain Lightning.")
    await world.call("learn", "kevin", "tempest")
    assert texts(await drain(kevin))[0].startswith("You learn Tempest.")


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
    await world.redis.delete("PLAYER:kevin:worn_stats")  # no armour, to see the guard alone
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


async def test_worn_gear_comes_with_the_class_and_background(world):
    kevin = await create(world, "kevin", cls="fighter", ancestry="human", passive="last_stand")
    character = of_type(await drain(kevin), "character")[-1]
    assert {place: w["id"] for place, w in character["worn"].items()} == {
        "head": "knitted_cap", "chest": "mail_shirt", "legs": "leather_breeches", "hand": "round_shield"}
    assert (character["armor"], character["armor_pct"]) == (9, 23)  # 9 / (9 + 30)

    await world.call("wear", "kevin", "torch")
    assert texts(await drain(kevin)) == ["You don't have anything called 'torch' to wear."]
    await world.redis.sadd("PLAYER:kevin:wardrobe", "torch", "apprentice_orb")
    await world.call("hold", "kevin", "torch")  # one hand: the torch or the shield
    assert texts(await drain(kevin))[0] == "You hold the Pitch Torch, and put away the Round Shield. It lights the way."
    assert await world.redis.hget("PLAYER:kevin:worn_stats", "armor") == "8"
    await world.call("wear", "kevin", "orb")
    assert texts(await drain(kevin)) == ["A Fighter can't use an orb like the Apprentice's Orb."]
    # WEAR a hand item holds it, and says so; HOLD a hat doesn't; EQUIP does either.
    await world.call("wear", "kevin", "shield")
    assert texts(await drain(kevin))[0].endswith("(HOLD is for things in your hand.)")
    await world.call("hold", "kevin", "cap")
    assert texts(await drain(kevin)) == ["The Knitted Cap isn't something to hold: WEAR KNITTED CAP."]
    await world.call("remove", "kevin", "head")
    await world.call("equip", "kevin", "cap")
    await world.call("equip", "kevin", "torch")
    assert await world.redis.hgetall("PLAYER:kevin:worn") == {
        "head": "knitted_cap", "chest": "mail_shirt", "legs": "leather_breeches", "hand": "torch"}


async def test_worn_stats_count(world):
    kevin = await create(world, "kevin", cls="mage", ancestry="human", passive="quick_study")
    character = of_type(await drain(kevin), "character")[-1]
    assert character["stats"]["focus"] == 1 and character["stats"]["resilience"] == 1  # the orb and the robe
    await world.call("remove", "kevin", "orb")
    assert of_type(await drain(kevin), "character")[-1]["stats"]["focus"] == 0


async def test_a_dark_room_needs_a_light(world):
    kevin = await create(world, "kevin")  # a sailor, on the slipway
    await world.call("move", "kevin", "east")  # the sail loft, shuttered
    room = of_type(await drain(kevin), "room")[-1]["room"]
    assert (room["exits"], room["dark"], room["description"], room["features"]) == (
        ["west"], True, "It's pitch dark. You can't see a thing.", [])
    await world.call("move", "kevin", "east")
    assert texts(await drain(kevin)) == ["It's too dark to find a way east. You need a light in your hand: WEAR a torch."]
    await world.redis.sadd("PLAYER:kevin:wardrobe", "torch")
    await world.call("wear", "kevin", "torch")
    room = of_type(await drain(kevin), "room")[-1]["room"]
    assert room["exits"] == ["east", "west"] and "dark" not in room


async def blow(world, pid, pressed_offset_ms=None, attacks=None):
    """Lands one Orc Warrior blow on a player, as if they pressed DEFEND that
    long after it landed (None: they didn't). Returns what they were told."""
    at = (await world.redis.time())[0] * 1000 - 2000  # long enough ago to land at once
    if attacks:
        await world.redis.hset("NPC:orc-1", "attacks", attacks)
    if pressed_offset_ms is not None:
        await world.redis.set(f"PLAYER:{pid}:defend", at + pressed_offset_ms)
    await world.redis.zadd("NPC:orc-1:foes", {pid: 0})
    await world.redis.hset("NPC:orc-1:next", 1, at)
    await world.redis.zadd("alz:npc_attacks", {"orc-1#1": at})
    await world.call("tick")
    return [e for e in await drain(world.feeds[pid]) if e["type"] == "combat" and e.get("entity_id") == "npc:orc-1"][0]


async def test_dodging_and_blocking(world):
    kevin = await create(world, "kevin", cls="rogue", ancestry="human", passive="last_stand")
    await world.redis.delete("PLAYER:kevin:worn_stats")  # no armour, to see the dodge alone
    await world.call("goto", "kevin", "back_alley")
    world.feeds = {"kevin": kevin}
    await drain(kevin)
    hit = await blow(world, "kevin", 0)  # perfect: none of it
    assert (hit["damage"], hit["defended"], hit["perfect"]) == (0, "dodge", True)
    assert hit["text"].startswith("Kevin dodges the Orc Warrior's ")
    assert not await world.redis.exists("PLAYER:kevin:defend")  # a press is spent on one blow
    hit = await blow(world, "kevin", -130)  # early, inside the 200 ms window: 0.75 - 0.5 * 70/140 = half of it
    assert (hit["damage"], hit["defended"]) == (3, "dodge") and "4 dodged" in hit["text"]
    hit = await blow(world, "kevin", 250)  # too late
    assert hit["damage"] == 7 and not hit.get("defended")
    hit = await blow(world, "kevin", 0, attacks='[{"name": "cleaver", "period": 3000, "damage": 7, "defend": "none", "hit": "{actor} hacks at {target}."}]')
    assert hit["damage"] == 7  # some blows can't be met at all

    # With a shield in hand it's a block, with a wider window.
    await world.redis.sadd("PLAYER:kevin:wardrobe", "round_shield")
    await world.redis.hset("PLAYER:kevin:worn", "hand", "round_shield")
    hit = await blow(world, "kevin", 250, attacks='[{"name": "cleaver", "period": 3000, "damage": 7, "hit": "{actor} hacks at {target}."}]')
    assert hit["defended"] == "block" and hit["damage"] > 0


async def test_defending_has_a_cooldown(world):
    kevin = await create(world, "kevin", cls="rogue", ancestry="human", passive="last_stand")
    await drain(kevin)
    await world.call("defend", "kevin")
    first = of_type(await drain(kevin), "defend")[0]
    assert (first["ready"], first["mode"], first["cooldown_ms"]) == (True, "dodge", 1500)
    await world.call("defend", "kevin")
    assert of_type(await drain(kevin), "defend")[0]["ready"] is False


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
    await do("give", "kevin", "purse", "nan")
    # Nan's lesson: the sky, how weather works on gear (and a torch), and a first fight. She asks first.
    events = await drain(kevin)
    assert any(t.startswith('Nan Gristle says, "Good. You\'ve quick hands. Before real work') for t in texts(events))
    assert of_type(events, "guide")[-1]["text"] == "Type ACCEPT to take this on."  # no turning this one down
    assert not any(t.startswith("New quest") for t in texts(of_type(events, "system")))  # that's for the pinned line
    await do("decline", "kevin")
    assert texts(await drain(kevin)) == ["This one isn't one to turn down: type ACCEPT."]
    await do("accept", "kevin")
    events = await drain(kevin)
    assert of_type(events, "quest_update")[0]["text"].startswith("New quest: Gutter Weather.")
    await do("ask", "kevin", "nan", "weather")
    events = await drain(kevin)
    assert of_type(events, "say")[-1]["text"].startswith('Nan Gristle says, "Rain empties the streets.')
    assert of_type(events, "guide")[0]["text"].startswith("Your weather panel, left to right:")  # and what it means
    await do("ask", "kevin", "nan", "sensitivity")
    assert await world.redis.sismember("PLAYER:kevin:wardrobe", "torch")
    await do("move", "kevin", "east")
    await world.redis.hset("NPC:alley_rat", "hp", 1)
    await do("use", "kevin", 1, "npc:alley_rat")
    await do("move", "kevin", "west")
    await drain(kevin)
    await do("ask", "kevin", "nan", "rats")  # report back, and Nan has the next job
    events = await drain(kevin)
    assert of_type(events, "character")[-1]["level"] == 2
    assert of_type(events, "character")[-1]["talent_picks"] == 0  # level 2 is a stat point, no talent
    assert any(t.startswith('Nan Gristle says, "If you don\'t mind, I\'ve a real job for you') for t in texts(events))
    await do("accept", "kevin")
    assert await world.redis.hget("PLAYER:kevin:quest:lw_signet", "step") == "steal"
    for nid in ("guard_dog",):
        await world.redis.srem("ROOM:magistrates_house:npcs", nid)  # the dog is dealt with
    await world.redis.rpush("alz:test_rolls", 0.0)  # step over the thread
    for direction in ("east", "east", "east"):
        await do("move", "kevin", direction)
    await do("move", "kevin", "north")  # the house is dark: no way up the stairs without a light
    assert await world.redis.get("PLAYER:kevin:room") == "magistrates_house"
    await do("hold", "kevin", "torch")
    await do("move", "kevin", "north")
    await do("get", "kevin", "signet")
    for direction in ("south", "west", "west", "west"):
        await do("move", "kevin", direction)
    await do("give", "kevin", "signet", "nan")
    await do("accept", "kevin")
    assert await world.redis.hget("PLAYER:kevin:quests", "lw_hot") == "active"
    await world.redis.delete("ROOM:rooftops:npcs")  # the watch looks the other way
    for direction in ("east", "east", "east", "north", "east", "south"):
        await do("move", "kevin", direction)
    events = await drain(kevin)
    assert "Too Hot: Joss the carter owes Nan a favour: DISCUSS TRAVEL WITH JOSS." in texts(events)

    await do("discuss", "kevin", "joss", "travel")  # how travel works; nobody's put on the road yet
    events = await drain(kevin)
    assert of_type(events, "guide")[0]["text"].startswith("Travel: coaches, ferries, caravans and portals")
    assert await world.redis.get("PLAYER:kevin:room") == "cart_yard"
    await do("travel", "kevin")
    [route] = of_type(await drain(kevin), "routes")[0]["routes"]
    assert route["id"] == "lowwick-cart"
    await do("travel", "kevin", "cart")
    events = await drain(kevin)
    assert await world.redis.hget("ACCOUNT:kevin", "level") == "3"  # two levels in the tutorial
    event = of_type(events, "travel_event")[0]  # the scripted checkpoint
    assert event["id"] == "checkpoint" and len(event["choices"]) == 2  # the urchin's own way out
    await do("choose", "kevin", "2")
    await ride(world, "kevin")
    assert await world.redis.get("PLAYER:kevin:room") == "back_alley"
    assert not await world.redis.sismember("PLAYER:kevin:realms", "lowwick")  # never to return
    assert await world.redis.hget("PLAYER:kevin:quests", "gf_newcomer") == "active"  # pointing at Harrowgate's tavern


async def test_dying_in_a_starting_realm_wakes_you_where_you_began(world):
    kevin = await create(world, "kevin", background="woodsman")
    await world.call("goto", "kevin", "fern_bog")
    await world.redis.hset("ACCOUNT:kevin", "hp", 1)
    await world.redis.zadd("alz:npc_attacks", {"bog_wisp#1": 0})
    await world.call("tick")
    assert await world.redis.get("PLAYER:kevin:room") == "hunters_lodge"


async def test_a_quest_step_gone_from_the_seed_goes_back_to_the_start(world):
    kevin = await create(world, "kevin")  # a sailor, on Caulk and Tar
    await world.redis.hset("PLAYER:kevin:quest:gh_tar", "step", "a_step_since_removed")
    await drain(kevin)
    await world.call("quests", "kevin")
    [quest] = of_type(await drain(kevin), "quests")[-1]["quests"]
    assert quest["goal"].startswith("Hedda needs tar")


async def test_the_next_quest_is_offered_out_loud_a_beat_later(world):
    await world.redis.hset("alz:rules", "offer_beat_ms", 2500)
    kevin = await create(world, "kevin", cls="mage", ancestry="human", passive="haggler", background="merchant")
    await world.call("goto", "kevin", "fountain")
    await world.call("get", "kevin", "crates")
    await world.call("goto", "kevin", "stall_row")
    await drain(kevin)
    await world.call("use_item", "kevin", "crates", "stall")
    said = texts(await drain(kevin))
    assert "Quest complete: Opening the Stall." in said
    assert 'Aunt Brisa says, "There. Open for business. And hear that? The shouting\'s started across the market already."' in said
    assert await world.redis.hget("PLAYER:kevin:quests", "cs_sky") is None  # not yet: she's still talking
    await world.call("tick")
    assert await world.redis.hget("PLAYER:kevin:quests", "cs_sky") is None
    await world.redis.zadd("alz:quest_offers", {"kevin|cs_sky": 0})  # the beat has passed
    await world.call("tick")
    events = await drain(kevin)
    assert of_type(events, "say")[0]["text"] == ('Aunt Brisa says, "Before you go meddling in that, I want you to learn the sky. '
                                                 'Will you let an old woman teach you?"')
    assert of_type(events, "say")[0]["entity_id"] == "npc:brisa"
    assert await world.redis.hget("PLAYER:kevin:quests", "cs_sky") is None  # she's asked; she waits for an answer
    await world.call("accept", "kevin")
    events = await drain(kevin)
    assert texts(events)[0] == 'Aunt Brisa says, "Good. Ask me about the weather, then."'
    assert any(t.startswith("New quest: Market Weather.") for t in texts(events))
    assert await world.redis.hget("PLAYER:kevin:quest:cs_sky", "giver") == "brisa"


async def test_copperstall_ends_with_your_aunt_and_a_caravan_you_choose_to_take(world):
    kevin = await create(world, "kevin", cls="mage", ancestry="human", passive="haggler", background="merchant")
    await world.redis.hset("PLAYER:kevin:quests", mapping={"cs_stall": "done", "cs_sky": "done", "cs_weight": "done"})
    await world.call("goto", "kevin", "guild_hall")
    await world.redis.hset("PLAYER:kevin:quests", "cs_rats", "active")
    await world.redis.hset("PLAYER:kevin:quest:cs_rats", mapping={"step": "back", "count": 0})  # the Rat King is dead
    await drain(kevin)
    await world.call("discuss", "kevin", "thorne", "rats")
    said = texts(await drain(kevin))
    assert any(t.startswith('Guildmaster Thorne says, "You\'ve done more for this guild') for t in said)
    await world.call("accept", "kevin")
    assert any(t.startswith("New quest: Your Own Road. Ask Aunt Brisa") for t in texts(await drain(kevin)))

    await world.call("goto", "kevin", "stall_row")
    await world.call("ask", "kevin", "brisa", "future")
    said = texts(await drain(kevin))
    assert any("Wenna and Hob" in t and "Go and see the world" in t for t in said)

    await world.call("goto", "kevin", "caravan_yard")
    assert "dace" not in await world.redis.smembers("ROOM:caravan_yard:npcs")  # he's at the coach stand, away from the rats
    await world.call("move", "kevin", "south")
    assert await world.redis.get("PLAYER:kevin:room") == "coach_stand"
    await drain(kevin)
    await world.call("travel", "kevin")
    assert texts(await drain(kevin)) == ["No routes leave from here."]  # not until you've asked
    await world.call("ask", "kevin", "dace", "travel")
    events = await drain(kevin)
    assert of_type(events, "guide")[0]["text"].endswith("When you're ready, type TRAVEL to see it, then TRAVEL CARAVAN.")
    assert await world.redis.get("PLAYER:kevin:room") == "coach_stand"  # nobody's thrust onto the road
    await world.call("travel", "kevin", "caravan")
    assert "Quest complete: Your Own Road." in texts(await drain(kevin))
    assert not await world.redis.sismember("PLAYER:kevin:realms", "copperstall")
    assert await world.redis.hget("PLAYER:kevin:quests", "gf_newcomer") == "active"
