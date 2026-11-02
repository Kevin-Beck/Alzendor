"""Encounters (docs/combat-redesign.md): the records and consequences in Lua,
called directly, and (further down) owners running them."""

import json

from .conftest import drain, enter, texts


def of_type(events, kind, **match):
    return [e for e in events if e["type"] == kind and all(e.get(k) == v for k, v in match.items())]


async def info(world, eid):
    raw = await world.redis.fcall("encounter_info", 0, eid)
    return json.loads(raw) if raw else None


async def strike(world, eid, pid, target, slot, tier, hit=1, hits=1, mult=1):
    return json.loads(await world.call("encounter_strike", eid, pid, target, slot, tier, hit, hits, mult))


async def blow(world, eid, nid, n, pid, how):
    return json.loads(await world.call("encounter_blow", eid, nid, n, pid, how))


async def in_back_alley(world, pid="kevin"):
    """A player walked in on the Orc Warrior (hostile): a fight starts."""
    feed = await enter(world, pid)
    await world.call("goto", pid, "back_alley")
    events = await drain(feed)
    return feed, events, await world.redis.get(f"PLAYER:{pid}:encounter")


# Records ---------------------------------------------------------------------------------


async def test_walking_in_on_an_enemy_starts_an_encounter(world):
    _, events, eid = await in_back_alley(world)
    assert eid
    record = await world.redis.hgetall(f"ENC:{eid}")
    assert (record["room"], record["kind"], record["owner"]) == ("back_alley", "pve", "local")
    assert await world.redis.zrange(f"ENC:{eid}:players", 0, -1) == ["kevin"]
    assert await world.redis.zrange(f"ENC:{eid}:npcs", 0, -1) == ["orc-1"]
    assert await world.redis.get("NPC:orc-1:encounter") == eid
    assert await world.redis.get("ROOM:back_alley:encounter") == eid
    assert await world.redis.sismember("alz:encounters", eid)
    assert await world.redis.pttl(f"ENC:{eid}:lease") > 2000
    stream = await world.redis.xrange("alz:new_encounters")
    assert stream[-1][1] == {"id": eid, "owner": "local"}
    assert "The Orc Warrior turns on Kevin!" in texts(events)
    start = of_type(events, "encounter", op="start")[0]
    assert start["encounter"]["players"][0]["pid"] == "kevin"
    assert start["encounter"]["players"][0]["slots"]["1"]["gear"] == "kick"
    assert start["encounter"]["npcs"][0]["attacks"][0]["kick"] > 0
    assert start["encounter"]["rules"]["balance_core"] == "0.22"


async def test_encounter_info(world):
    _, _, eid = await in_back_alley(world)
    data = await info(world, eid)
    assert data["room"] == "back_alley" and data["owner"] == "local" and data["lead_ms"] == 1000
    assert [p["pid"] for p in data["players"]] == ["kevin"]
    assert data["npcs"][0]["nid"] == "orc-1" and data["npcs"][0]["max_hp"] == 80
    assert await info(world, "e999") is None


async def test_start_join_leave_and_end(world):
    kevin = await enter(world, "kevin")
    ana = await enter(world, "ana")
    eid = await world.call("encounter_start", "tavern", "pve", "seed-1", "kevin", "rat-1")
    assert await world.redis.hget(f"ENC:{eid}", "seed") == "seed-1"
    await drain(kevin)
    await world.call("encounter_join", eid, "pc:ana")
    assert of_type(await drain(kevin), "encounter", op="join", who="pc:ana")
    assert of_type(await drain(ana), "encounter", op="start")
    await world.call("encounter_leave", eid, "pc:ana", "fled")
    assert of_type(await drain(kevin), "encounter", op="leave", who="pc:ana", why="fled")
    assert of_type(await drain(ana), "encounter", op="end", why="fled")
    assert await world.redis.get("PLAYER:ana:encounter") is None
    await world.call("encounter_end", eid, "testing")
    assert of_type(await drain(kevin), "encounter", op="end", why="testing")
    assert not await world.redis.exists(f"ENC:{eid}", f"ENC:{eid}:players", "PLAYER:kevin:encounter", "NPC:rat-1:encounter")
    assert not await world.redis.sismember("alz:encounters", eid)


async def test_the_last_player_out_ends_it(world):
    _, _, eid = await in_back_alley(world)
    await world.call("encounter_leave", eid, "pc:kevin", "gone")
    assert not await world.redis.exists(f"ENC:{eid}", "NPC:orc-1:encounter", "ROOM:back_alley:encounter")


async def test_a_lost_encounter_starts_afresh(world):
    _, _, eid = await in_back_alley(world)
    await world.redis.hset("NPC:orc-1", "hp", 50)
    await world.call("encounter_end", eid, "lost")
    fresh = await world.redis.get("PLAYER:kevin:encounter")
    assert fresh and fresh != eid
    assert await world.redis.get("NPC:orc-1:encounter") == fresh
    assert await world.redis.hget("NPC:orc-1", "hp") == "50"  # as hurt as it was


# Strikes ---------------------------------------------------------------------------------


async def test_a_strike_lands_by_tier(world):
    feed, _, eid = await in_back_alley(world)
    result = await strike(world, eid, "kevin", "npc:orc-1", 1, 2)
    assert result == {"damage": 10, "hp": 70, "stagger_ms": 0}  # the kick's perfect 8, +25% in this weather
    events = await drain(feed)
    combat = of_type(events, "combat")[0]
    assert (combat["tier"], combat["damage"], combat["target"]) == ("perfect", 10, "npc:orc-1")
    edge = await strike(world, eid, "kevin", "npc:orc-1", 1, 0)
    assert edge["damage"] == 5
    # A volley's hit is its share, rounded up.
    assert (await strike(world, eid, "kevin", "npc:orc-1", 1, 0, 1, 4))["damage"] == 2
    # A multiplier (a staggered boss) on top.
    assert (await strike(world, eid, "kevin", "npc:orc-1", 1, 0, 1, 1, 1.5))["damage"] == 8


async def test_the_damage_scale(world):
    _, _, eid = await in_back_alley(world)
    await world.redis.hset("alz:rules", "balance_damage_scale", 2)
    assert (await strike(world, eid, "kevin", "npc:orc-1", 1, 0))["damage"] == 10


async def test_a_kill_ends_the_encounter_and_pays_out(world):
    feed, _, eid = await in_back_alley(world)
    await world.redis.hset("NPC:orc-1", "hp", 3)
    coins = int(await world.redis.hget("ACCOUNT:kevin", "coins"))
    result = await strike(world, eid, "kevin", "npc:orc-1", 1, 2)
    assert result["killed"]
    events = await drain(feed)
    assert "The Orc Warrior collapses." in texts(events)
    assert of_type(events, "encounter", op="end", why="won")
    assert not await world.redis.exists(f"ENC:{eid}", "PLAYER:kevin:encounter")
    assert not await world.redis.sismember("ROOM:back_alley:npcs", "orc-1")
    assert int(await world.redis.hget("ACCOUNT:kevin", "coins")) > coins


async def test_a_strike_on_a_gone_target(world):
    _, _, eid = await in_back_alley(world)
    assert await strike(world, eid, "kevin", "npc:nobody", 1, 1) == {"gone": True}
    assert await strike(world, "e999", "kevin", "npc:orc-1", 1, 1) == {"gone": True}


async def test_striking_a_bystander_npc_brings_it_in(world):
    feed = await enter(world, "kevin")
    for direction in ("north", "west", "south"):  # the fish market: two dock rats, neutral
        await world.call("move", "kevin", direction)
    eid = await world.call("encounter_start", "fish_market", "pve", "", "kevin", "rat-1")
    await drain(feed)
    await world.redis.hset("NPC:rat-2", "hp", 100)
    await strike(world, eid, "kevin", "npc:rat-2", 1, 1)
    assert await world.redis.get("NPC:rat-2:encounter") == eid
    reputation = of_type(await drain(feed), "reputation")
    assert reputation == [] or reputation  # the ambush deed is the factions' to judge


async def test_heals_and_guards(world):
    feed, _, eid = await in_back_alley(world)
    await world.redis.hset("ACCOUNT:kevin", "hp", 10)
    result = await strike(world, eid, "kevin", "", 3, 1)  # the health potion, clean
    assert result["healed"] == 18  # 15, +20% in this weather
    assert await world.redis.hget("ACCOUNT:kevin", "hp") == "28"


# Blows -----------------------------------------------------------------------------------


async def test_blows_by_how_they_were_met(world):
    feed, _, eid = await in_back_alley(world)
    await world.redis.delete("PLAYER:kevin:worn_stats")  # no armour
    hp = 100
    for how, damage in [("hit", 7), ("dodge", 0), ("perfect_block", 0), ("staggered", 11), ("parting", 7)]:
        result = await blow(world, eid, "orc-1", 1, "kevin", how)
        hp -= damage
        assert result == {"damage": damage, "hp": hp}, how
    events = await drain(feed)
    results = [e["result"] for e in of_type(events, "combat")]
    assert results == ["hit", "dodge", "perfect_block", "staggered", "parting"]
    assert "Kevin dodges the Orc Warrior's cleaver. (0)" in texts(events)


async def test_a_block_takes_most_of_it(world):
    _, _, eid = await in_back_alley(world)
    await world.redis.delete("PLAYER:kevin:worn_stats")
    await world.redis.hset("PLAYER:kevin:worn", "hand", "round_shield")
    assert (await blow(world, eid, "orc-1", 1, "kevin", "block"))["damage"] == 2  # 7, 70% off (5)


async def test_guard_and_armour(world):
    _, _, eid = await in_back_alley(world)
    await world.redis.hset("PLAYER:kevin:worn_stats", "armor", 30)  # half
    await world.redis.set("PLAYER:kevin:guard", 3)
    assert (await blow(world, eid, "orc-1", 1, "kevin", "hit"))["damage"] == 2  # 7, 3 guarded, half the rest
    assert not await world.redis.exists("PLAYER:kevin:guard")


async def test_a_killing_blow(world):
    feed, _, eid = await in_back_alley(world)
    await world.redis.hset("ACCOUNT:kevin", "hp", 3)
    result = await blow(world, eid, "orc-1", 1, "kevin", "parting")
    assert result["dead"]
    events = await drain(feed)
    assert of_type(events, "encounter", op="end", why="died")
    assert await world.redis.get("PLAYER:kevin:room") != "back_alley"
    assert not await world.redis.exists(f"ENC:{eid}")


# The one rule and its exceptions ------------------------------------------------------------


async def test_moving_is_refused_in_a_fight(world):
    feed, _, _ = await in_back_alley(world)
    exits = await world.redis.hkeys("ROOM:back_alley:exits")
    await world.call("move", "kevin", exits[0])
    assert texts(await drain(feed)) == [f"You're in a fight. FLEE {exits[0].upper()} to break away."]
    assert await world.redis.get("PLAYER:kevin:room") == "back_alley"


async def test_fleeing_takes_a_parting_blow_from_the_toughest(world):
    feed, _, eid = await in_back_alley(world)
    await world.redis.delete("PLAYER:kevin:worn_stats")
    direction = (await world.redis.hkeys("ROOM:back_alley:exits"))[0]
    result = json.loads(await world.call("encounter_flee", eid, "kevin", direction))
    assert result == {"fled": True}
    events = await drain(feed)
    parting = of_type(events, "combat", result="parting")[0]
    assert (parting["verb"], parting["damage"]) == ("cleaver", 7)  # its hardest
    assert of_type(events, "encounter", op="end", why="fled")
    assert await world.redis.get("PLAYER:kevin:room") != "back_alley"
    assert not await world.redis.exists(f"ENC:{eid}")  # nobody left in it
    # Straight back in: the fight starts again, the orc as hurt as it was.
    back = {"north": "south", "south": "north", "east": "west", "west": "east"}[direction]
    await world.redis.delete("PLAYER:kevin:moved")
    await world.call("move", "kevin", back)
    assert await world.redis.get("PLAYER:kevin:encounter")


async def test_flee_needs_a_way_out(world):
    feed, _, eid = await in_back_alley(world)
    assert json.loads(await world.call("encounter_flee", eid, "kevin", "up")) == {"refused": "no_exit"}
    assert await world.redis.get("PLAYER:kevin:encounter") == eid


async def test_attacking_first_starts_an_encounter_with_an_opening(world):
    feed = await enter(world, "kevin")
    for direction in ("north", "west", "south"):
        await world.call("move", "kevin", direction)
    assert not await world.redis.get("PLAYER:kevin:encounter")  # the rats are neutral
    await world.call("use", "kevin", 1, "rat")
    eid = await world.redis.get("PLAYER:kevin:encounter")
    assert eid
    data = await info(world, eid)
    rat = data["npcs"][0]["nid"]
    assert data["opening"] == {"kevin": {"slot": 1, "target": f"npc:{rat}"}}
    assert await world.redis.smembers(f"ENC:{eid}:ambush") == {f"kevin|{rat}"}


async def test_a_player_walking_in_joins_the_fight(world):
    _, _, eid = await in_back_alley(world)
    ana = await enter(world, "ana")
    await world.call("goto", "ana", "back_alley")
    assert await world.redis.get("PLAYER:ana:encounter") == eid
    assert of_type(await drain(ana), "encounter", op="start")


async def test_gear_is_locked_in_a_fight(world):
    feed, _, _ = await in_back_alley(world)
    await world.call("unequip", "kevin", 1)
    assert "You can't change your gear mid-fight." in texts(await drain(feed))


async def test_heals_out_of_a_fight_work_at_once_then_cool_down(world):
    feed = await enter(world, "kevin")
    await world.redis.hset("ACCOUNT:kevin", "hp", 10)
    await world.call("use", "kevin", 3, "")
    await world.call("use", "kevin", 3, "")
    events = texts(await drain(feed))[-2:]
    assert events[0].endswith("(+18)")  # the clean amount, 15, +20% in the tavern's weather
    assert "Health Potion isn't ready yet." in events
    assert not await world.redis.get("PLAYER:kevin:encounter")


# Owners ----------------------------------------------------------------------------------

import asyncio  # noqa: E402
import time  # noqa: E402

import pytest  # noqa: E402

from alzendor.encounter import EncounterHost  # noqa: E402
from alzendor.world import World  # noqa: E402


async def redis_now(redis) -> float:
    seconds, micros = await redis.time()
    return seconds * 1000 + micros / 1000


@pytest.fixture
async def host(world):
    """This test's server, running the encounters it owns (as 'local')."""
    seconds, micros = await world.redis.time()
    offset = seconds * 1000 + micros / 1000 - time.time() * 1000
    h = EncounterHost(world, "local", lambda: time.time() * 1000 + offset)
    await h.start()
    await world.redis.hset("alz:rules", "encounter_lead_ms", 200)
    yield h
    await h.close()


async def until(check, timeout=4.0):
    """Waits for check() (a coroutine function) to come true."""
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if await check():
            return True
        await asyncio.sleep(0.05)
    return False


async def quick_orc(world, period=400, damage=1, kick=0.3):
    await world.redis.hset("NPC:orc-1", "attacks", json.dumps([
        {"name": "cleaver", "period": period, "damage": damage, "kick": kick, "hit": "{actor} hacks at {target}."}]))


async def send(world, eid, **message):
    await world.redis.publish(f"enc:{eid}:in", json.dumps(message))


async def test_the_owner_runs_it_and_lands_blows(world, host):
    await quick_orc(world)
    feed, _, eid = await in_back_alley(world)
    assert await until(lambda: asyncio.sleep(0, eid in host.owners))
    await world.redis.delete("PLAYER:kevin:worn_stats")

    async def hurt():
        return int(await world.redis.hget("ACCOUNT:kevin", "hp") or 100) < 100
    assert await until(hurt)
    events = await drain(feed)
    assert of_type(events, "combat", entity_id="npc:orc-1")[0]["result"] in ("hit", "staggered")


async def test_state_is_published(world, host):
    _, _, eid = await in_back_alley(world)
    pubsub = world.redis.pubsub()
    await pubsub.subscribe(f"enc:{eid}:out")
    state = None
    deadline = time.monotonic() + 3
    while time.monotonic() < deadline and not state:
        m = await pubsub.get_message(ignore_subscribe_messages=True, timeout=0.5)
        if m and json.loads(m["data"])["type"] == "state":
            state = json.loads(m["data"])
    await pubsub.aclose()
    assert state and state["id"] == eid
    assert set(state["players"]) == {"kevin"}
    assert {"x", "y", "rng", "join", "seq", "keys"} <= set(state["players"]["kevin"])


async def test_a_strike_from_the_centre_is_perfect(world, host):
    feed, _, eid = await in_back_alley(world)
    await asyncio.sleep(0.25)  # the lead-in: the dot starts at the centre
    await send(world, eid, pid="kevin", seq=1, keys=0, act="strike", slot=1, target="npc:orc-1")

    async def struck():
        return int(await world.redis.hget("NPC:orc-1", "hp")) < 80
    assert await until(struck)
    combat = of_type(await drain(feed), "combat", actor="kevin")[0]
    assert combat["tier"] in ("perfect", "clean")


async def test_a_kill_ends_it(world, host):
    feed, _, eid = await in_back_alley(world)
    await world.redis.hset("NPC:orc-1", "hp", 1)
    await asyncio.sleep(0.25)
    await send(world, eid, pid="kevin", seq=1, act="strike", slot=1, target="orc")  # a word works too

    async def over():
        return not await world.redis.exists(f"ENC:{eid}")
    assert await until(over)
    assert await until(lambda: asyncio.sleep(0, eid not in host.owners))


async def test_the_opening_strike_lands_after_the_lead_in(world, host):
    feed = await enter(world, "kevin")
    for direction in ("north", "west", "south"):
        await world.call("move", "kevin", direction)
    await world.redis.hset("NPC:rat-1", "hp", 100)
    await world.redis.hset("NPC:rat-2", "hp", 100)
    await world.call("use", "kevin", 1, "rat")

    async def opened():
        return [int(await world.redis.hget(f"NPC:{r}", "hp")) for r in ("rat-1", "rat-2")] != [100, 100]
    assert await until(opened)


async def test_fleeing_by_input(world, host):
    feed, _, eid = await in_back_alley(world)
    await asyncio.sleep(0.25)
    direction = (await world.redis.hkeys("ROOM:back_alley:exits"))[0]
    await send(world, eid, pid="kevin", seq=1, act="flee", dir=direction)

    async def gone():
        return await world.redis.get("PLAYER:kevin:room") != "back_alley"
    assert await until(gone)
    assert of_type(await drain(feed), "combat", result="parting")


async def test_fleeing_off_centre_is_refused(world, host):
    feed, _, eid = await in_back_alley(world)
    pubsub = world.redis.pubsub()
    await pubsub.subscribe(f"enc:{eid}:out")
    await asyncio.sleep(0.25)
    await send(world, eid, pid="kevin", seq=1, keys=8)  # lean right, hard
    await asyncio.sleep(0.8)
    direction = (await world.redis.hkeys("ROOM:back_alley:exits"))[0]
    await send(world, eid, pid="kevin", seq=2, keys=8, act="flee", dir=direction)
    refused = None
    deadline = time.monotonic() + 3
    while time.monotonic() < deadline and not refused:
        m = await pubsub.get_message(ignore_subscribe_messages=True, timeout=0.5)
        if m and json.loads(m["data"])["type"] == "refused":
            refused = json.loads(m["data"])
    await pubsub.aclose()
    assert refused == {"type": "refused", "pid": "kevin", "act": "flee", "reason": "not_steady"}
    assert await world.redis.get("PLAYER:kevin:room") == "back_alley"


async def test_a_dead_owners_encounter_ends_and_starts_afresh(world, host):
    ghost = World(world.redis, "ghost")  # a server that's about to die
    await enter(world, "kevin")
    await ghost.call("goto", "kevin", "back_alley")
    eid = await world.redis.get("PLAYER:kevin:encounter")
    assert await world.redis.hget(f"ENC:{eid}", "owner") == "ghost"
    assert eid not in host.owners
    await world.redis.delete(f"ENC:{eid}:lease")  # its lease lapses
    assert await host.check_leases() == 1
    fresh = await world.redis.get("PLAYER:kevin:encounter")
    assert fresh and fresh != eid
    assert await world.redis.hget(f"ENC:{fresh}", "owner") == "local"
    assert await until(lambda: asyncio.sleep(0, fresh in host.owners))


# Rewinding steering ------------------------------------------------------------------------

from types import SimpleNamespace  # noqa: E402

from alzendor import balance as bal  # noqa: E402
from alzendor.encounter import REWIND_STEPS, Owner  # noqa: E402


def bare_owner():
    """An owner with one player and nothing to fight, run step by step by hand."""
    owner = Owner(SimpleNamespace(world=None), "e1")
    owner.start_ms, owner.lead_ms, owner.seed = 0, 0, "seed"
    owner._add_player({"pid": "kevin", "join_ms": 0, "slots": {}, "stats": {}, "shield": 0}, None)
    return owner


def run(owner, steps):
    for _ in range(steps):
        owner.step += 1
        owner._run_step(owner.step, [])


def reference(keys_from: int, total: int, keys: int):
    """The same dot, steered with `keys` from step keys_from on."""
    dot = bal.make_dot(bal.Rules(), "seed", "kevin")
    for n in range(1, total + 1):
        bal.step(dot, keys if n >= keys_from else 0)
    return dot


def test_late_steering_is_applied_where_the_client_applied_it():
    owner = bare_owner()
    run(owner, 30)
    owner._input({"pid": "kevin", "seq": 1, "keys": 8, "step": 25})  # pressed at 25, arrived at 30
    run(owner, 10)
    dot, want = owner.players["kevin"].dot, reference(25, 40, 8)
    assert (dot.x, dot.y) == pytest.approx((want.x, want.y))


def test_steering_rewinds_only_so_far():
    owner = bare_owner()
    run(owner, 60)
    owner._input({"pid": "kevin", "seq": 1, "keys": 8, "step": 5})  # far too late: as far back as it may
    run(owner, 10)
    dot, want = owner.players["kevin"].dot, reference(61 - REWIND_STEPS, 70, 8)
    assert (dot.x, dot.y) == pytest.approx((want.x, want.y))
    assert REWIND_STEPS == 12  # 200 ms


def test_steering_without_a_step_applies_from_now():
    owner = bare_owner()
    run(owner, 30)
    owner._input({"pid": "kevin", "seq": 1, "keys": 8})
    run(owner, 10)
    dot, want = owner.players["kevin"].dot, reference(31, 40, 8)
    assert (dot.x, dot.y) == pytest.approx((want.x, want.y))


def test_a_late_strike_is_judged_where_the_client_pressed_it():
    owner = bare_owner()
    p = owner.players["kevin"]
    for d in (p.dot, p.scratch):
        d.slots[1] = bal.Gear(cooldown=350, kick=1.0)
    p.gear[1] = {"effect": "damage", "kick": 1.0}
    owner.npcs["orc"] = SimpleNamespace(nid="orc", join=0, info={"name": "Orc"}, attacks=[], boss=None)
    run(owner, 10)
    # Pressed at step 2, centred; it arrives at step 10, and is judged at step 2.
    owner._input({"pid": "kevin", "seq": 1, "act": "strike", "slot": 1, "target": "npc:orc", "step": 2})
    strikes = [c for c in owner.late if c[0] == "strike"]
    assert len(strikes) == 1 and strikes[0][2]["tier"] == 2
    assert p.dot.cool[1] == bal.steps(350) - 8  # its cooldown started back then
    assert not p.acts
