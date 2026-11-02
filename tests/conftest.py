import os
from pathlib import Path

import pytest
from redis.exceptions import ConnectionError as RedisConnectionError

from alzendor.feed import Feed
from alzendor.server import open_redis
from alzendor.world import World

# Tests use a database of their own and empty it before and after each test.
REDIS_URL = os.environ.get("ALZ_TEST_REDIS_URL", "redis://localhost:6379/15")
SEED = Path(__file__).parent.parent / "world" / "seed.json"


@pytest.fixture
async def redis():
    client = open_redis(REDIS_URL)
    try:
        await client.ping()
    except (RedisConnectionError, OSError):
        await client.aclose()
        pytest.skip(f"no Redis at {REDIS_URL} (start one with: docker compose up -d redis)")
    await client.flushdb()
    yield client
    await client.flushdb()
    await client.aclose()


@pytest.fixture
async def world(redis):
    world = World(redis)
    await world.load_rules()
    await world.seed(SEED)
    # Most tests walk several rooms in a row; walking pace has tests of its own.
    await redis.hset("alz:rules", "pace", 0)
    # And it's always midday, unless a test says otherwise.
    await redis.set("alz:clock_override", 12)
    # Nothing happens on the road unless a test asks for it.
    await redis.hset("alz:rules", "event_chance", 0)
    # The next quest in a chain is offered at once, not a beat later; offers have a test of their own.
    await redis.hset("alz:rules", "offer_beat_ms", 0)
    # Gear lands its amounts as listed; the tuned scale has a test of its own (test_tuning).
    await redis.hset("alz:rules", "balance_damage_scale", 1)
    # Lures only come when a test asks for them.
    await redis.hset("alz:rules", "lure_chance", 0)
    # Tests run on a mild, dry, temperate day in every realm; weather tests set their own.
    for realm in await redis.smembers("alz:realms"):
        await set_weather(redis, realm, 0, 0, -1)
    return world


async def set_weather(redis, realm: str, temperature: float, energy: float, precipitation: float) -> None:
    """Pins a realm's weather, as the admin 'setweather' command does."""
    await redis.hset(f"alz:weather_override:{realm}",
                     mapping={"temperature": temperature, "energy": energy, "precipitation": precipitation})


async def enter(world: World, pid: str, session: str | None = None, since: int = 0) -> Feed:
    """Puts a player into the world, as a server does after login."""
    await world.redis.hsetnx(f"ACCOUNT:{pid}", "name", pid.capitalize())
    session = session or f"session-{pid}"
    cursor = await world.call("connect", pid, session, since)
    return await Feed.open(world.redis, pid, session, cursor)


async def ride(world: World, pid: str, stages: int = 100) -> None:
    """Moves a journey on stage by stage, without the waits, to its end (or
    for `stages` stages)."""
    for _ in range(stages):
        if not await world.redis.exists(f"PLAYER:{pid}:journey"):
            return
        await world.redis.zadd("alz:journeys", {pid: 0})
        await world.call("tick")


async def drain(feed: Feed) -> list[dict]:
    """Reads everything currently waiting for this feed."""
    events = []
    while True:
        before = feed.cursor
        events += await feed.read(block_ms=50)
        if feed.cursor == before or feed.ended:
            return events


def texts(events: list[dict]) -> list[str]:
    """The text of events that have any (state updates like `map` don't)."""
    return [e["text"] for e in events if "text" in e]


async def hit(world: World, pid: str, target: str, slot: int = 1, tier: int = 0) -> dict:
    """Lands one strike as an encounter's owner would (tier 0 edge, 1 clean,
    2 perfect), striking first to start a fight if the player isn't in one."""
    import json
    eid = await world.redis.get(f"PLAYER:{pid}:encounter")
    if not eid:
        await world.call("use", pid, slot, target)
        eid = await world.redis.get(f"PLAYER:{pid}:encounter")
        if not eid:
            return {}
    return json.loads(await world.call("encounter_strike", eid, pid, target, slot, tier, 1, 1, 1))


async def blow(world: World, nid: str, n: int = 1, how: str = "hit", pid: str | None = None) -> dict:
    """Lands an NPC's attack n as an encounter's owner would, on the first
    player in its fight (or `pid`)."""
    import json
    eid = await world.redis.get(f"NPC:{nid}:encounter")
    if not eid:
        return {}
    pid = pid or (await world.redis.zrange(f"ENC:{eid}:players", 0, 0))[0]
    return json.loads(await world.call("encounter_blow", eid, nid, n, pid, how))


async def flee(world: World, pid: str, direction: str) -> dict:
    """FLEE <direction>, steady (the owner's check passed)."""
    import json
    eid = await world.redis.get(f"PLAYER:{pid}:encounter")
    return json.loads(await world.call("encounter_flee", eid, pid, direction))


async def go(world: World, pid: str, direction: str) -> None:
    """Moves on: by FLEE if something here is fighting the player."""
    if await world.redis.get(f"PLAYER:{pid}:encounter"):
        await flee(world, pid, direction)
    else:
        await world.call("move", pid, direction)
