"""The server's own loops and start-up, with more than one server on one Redis."""

import asyncio
import json
import time
from types import SimpleNamespace

import pytest
from redis.exceptions import ConnectionError as RedisConnectionError

from alzendor import commands
from alzendor.config import Config
from alzendor.encounter import EncounterHost
from alzendor.server import GameServer
from alzendor.session import Session

from .conftest import SEED, enter


def server(redis, server_id: str, **settings) -> GameServer:
    return GameServer(Config(server_id=server_id, seed_file=SEED, **settings), redis)


async def test_upkeep_heals_once_per_slot_however_many_servers_run_it(world, redis):
    await enter(world, "kevin")
    await redis.hset("ACCOUNT:kevin", "hp", 1)
    await redis.sadd("alz:wounded", "kevin")
    one, two = server(redis, "server1"), server(redis, "server2")
    ran = [await one.upkeep(), await two.upkeep()]
    assert sorted(ran) == [False, True]  # whichever came first
    assert await redis.hget("ACCOUNT:kevin", "hp") == "11"  # one safe_regen (the tavern), not two


async def test_a_server_id_can_only_be_held_by_one_server(redis):
    one, two = server(redis, "server1"), server(redis, "server1")
    await one.claim_server_id()
    with pytest.raises(RuntimeError, match="in use"):
        await two.claim_server_id(wait=1)
    await one.release_server_id()
    await two.claim_server_id(wait=0)


def test_server_ids_default_to_unique_per_port():
    assert Config.from_env({"ALZ_PORT": "8001"}).server_id != Config.from_env({"ALZ_PORT": "8002"}).server_id
    assert Config.from_env({"ALZ_SERVER_ID": "s1"}).server_id == "s1"


async def test_start_up_records_the_rules_version_and_refuses_a_bad_map_before_loading_rules(redis, tmp_path, caplog):
    one = server(redis, "server1")
    await one.prepare()
    assert (await redis.hgetall("alz:version"))["version"] == one.version
    # Another version starting is logged.
    await redis.hset("alz:version", "version", "older")
    await server(redis, "server2").prepare()
    assert "replacing rules and content older" in caplog.text
    # A map that doesn't validate installs nothing.
    await redis.function_flush()
    (tmp_path / "zones").mkdir()
    (tmp_path / "seed.json").write_text(SEED.read_text().replace('"start_room": "tavern"', '"start_room": "nowhere"'))
    with pytest.raises(ValueError, match="start_room"):
        await GameServer(Config(server_id="server3", seed_file=tmp_path / "seed.json"), redis).prepare()
    assert await redis.function_list() == []


class FakeWs:
    """A client connection that records what it's sent."""

    def __init__(self, block: asyncio.Event | None = None):
        self.sent: list[dict] = []
        self.block = block
        self.waiting = 0
        self.request = SimpleNamespace(headers={})
        self.remote_address = ("127.0.0.1", 1)

    async def send(self, data):
        if self.block:
            self.waiting += 1
            await self.block.wait()
            self.waiting -= 1
        self.sent.append(json.loads(data))


def session_for(game: GameServer, pid: str, ws: FakeWs) -> tuple[Session, commands.Context]:
    session = Session(game, ws)
    session.pid = pid
    ctx = commands.Context(game.world, pid, tell=lambda text: session._send(type="error", message=text))
    return session, ctx


async def test_a_flood_of_commands_is_cut_to_the_allowance(world, redis):
    await enter(world, "kevin")
    ws = FakeWs()
    session, ctx = session_for(server(redis, "server1"), "kevin", ws)
    for _ in range(20):
        await session._handle(ctx, json.dumps({"type": "cmd", "text": "look"}))
    refused = [m for m in ws.sent if m.get("message") == "Slow down a little."]
    assert 8 <= len(refused) <= 10  # a burst of 10 goes through


async def test_idle_players_are_sent_to_sleep(world, redis):
    await enter(world, "kevin")
    game = server(redis, "server1", idle_minutes=1)
    game.sessions["s"] = SimpleNamespace(pid="kevin", id="session-kevin", last_active=time.monotonic() - 120)
    await game._send_idle_to_sleep()
    assert not await redis.exists("PLAYER:kevin:session")


async def test_a_command_from_someone_no_longer_in_the_world_gets_a_reply(world, redis):
    await enter(world, "kevin")
    await world.call("disconnect", "kevin", "", "", "Bye.")
    ws = FakeWs()
    session, ctx = session_for(server(redis, "server1"), "kevin", ws)
    await session._handle(ctx, json.dumps({"type": "cmd", "text": "look"}))
    assert ws.sent == [{"type": "error", "message": "You're not in the world right now."}]


async def test_a_redis_error_on_a_fight_input_drops_the_input_not_the_player(redis):
    session, _ = session_for(server(redis, "server1"), "kevin", FakeWs())
    session.encounter, session.encounter_owner = "e1", "elsewhere"

    async def broken(*args):
        raise RedisConnectionError("gone for a moment")
    session.server.encounters.send_input = broken
    await session._handle(None, json.dumps({"type": "input", "seq": 1, "keys": 1}))  # no exception


async def test_a_slow_client_gets_the_newest_fight_state_and_no_pile_up(redis):
    gate = asyncio.Event()
    ws = FakeWs(block=gate)
    session, _ = session_for(server(redis, "server1"), "kevin", ws)
    for n in range(50):
        session._forward(json.dumps({"type": "state", "step": n}, separators=(",", ":")))
    await asyncio.sleep(0.05)
    assert ws.waiting == 1  # one send in flight, not fifty
    gate.set()
    await asyncio.sleep(0.05)
    assert [m["step"] for m in ws.sent] == [49]


async def test_an_encounter_added_between_idle_reads_is_adopted(world, redis):
    host = EncounterHost(world, "server1", lambda: time.time() * 1000)
    adopted = []
    host.adopt = adopted.append
    real, reads = redis.xread, []

    async def xread(streams, block=None):
        reply = await real(streams, block=100)
        reads.append(1)
        if len(reads) == 1:  # the first read timed out; one arrives before the next read starts
            await redis.xadd("alz:new_encounters", {"id": "e9", "owner": "server1"})
        return reply
    redis.xread = xread
    task = asyncio.create_task(host._discover())
    for _ in range(30):
        if adopted:
            break
        await asyncio.sleep(0.1)
    task.cancel()
    assert adopted == ["e9"]
