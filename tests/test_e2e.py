"""Two servers, two clients: players on different servers share one world."""

import asyncio
import json
import socket
from contextlib import asynccontextmanager

from websockets.asyncio.client import connect

from alzendor.config import Config
from alzendor.feed import FEED_BLOCK_MS
from alzendor.server import GameServer

from .conftest import SEED


def free_port() -> int:
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


@asynccontextmanager
async def running_server(redis, server_id):
    config = Config(host="127.0.0.1", port=free_port(), server_id=server_id, seed_file=SEED)
    server = GameServer(config, redis)
    await server.prepare()
    stop = asyncio.get_running_loop().create_future()
    task = asyncio.create_task(server.serve(stop))
    await asyncio.sleep(0.2)
    try:
        yield f"ws://127.0.0.1:{config.port}/ws"
    finally:
        stop.set_result(None)
        await task


class Client:
    def __init__(self, ws):
        self.ws = ws
        self.last_seq = 0
        self.token = None

    @classmethod
    @asynccontextmanager
    async def open(cls, url):
        async with connect(url) as ws:
            yield cls(ws)

    async def send(self, **message):
        await self.ws.send(json.dumps(message))

    async def auth(self, **message) -> dict:
        await self.send(**message)
        reply = json.loads(await self.ws.recv())
        assert reply["type"] == "auth_ok", reply
        self.token = reply["token"]
        return reply

    async def until(self, text: str) -> list[str]:
        """Collects event texts until one equals `text`."""
        seen = []
        async with asyncio.timeout(5):
            while True:
                message = json.loads(await self.ws.recv())
                if message["type"] != "event":
                    continue
                self.last_seq = message["event"]["seq"]
                if "text" not in message["event"]:
                    continue
                seen.append(message["event"]["text"])
                if seen[-1] == text:
                    return seen


async def test_players_on_different_servers_see_each_other(redis):
    async with running_server(redis, "one") as url_one, running_server(redis, "two") as url_two:
        async with Client.open(url_one) as kevin, Client.open(url_two) as mara:
            assert (await kevin.auth(type="register", name="Kevin", password="correct horse"))["server"] == "one"
            assert (await mara.auth(type="register", name="Mara", password="battery staple"))["server"] == "two"

            await kevin.until("Mara arrives, well rested.")
            await kevin.send(type="cmd", text="north")
            await mara.until("Kevin heads north.")
            await mara.send(type="cmd", text="n")
            await kevin.until("Mara arrives from the south.")
            await mara.send(type="cmd", text="say Nice day for it.")
            await kevin.until('Mara says, "Nice day for it."')

            # Mara's connection drops; she misses something, then resumes on the other server.
            missed_from = mara.last_seq
            await mara.ws.close()
            await kevin.send(type="cmd", text="wave mara")
            await kevin.until("Kevin waves at Mara.")

        async with Client.open(url_one) as mara_again:
            reply = await mara_again.auth(type="resume", token=mara.token, since=missed_from)
            assert reply["server"] == "one"
            assert "Kevin waves at Mara." in await mara_again.until("Kevin waves at Mara.")


async def test_idle_connections_stay_open(redis):
    """A quiet room must not drop the connection (a Redis read timeout once did)."""
    async with running_server(redis, "one") as url:
        async with Client.open(url) as kevin, Client.open(url) as mara:
            await kevin.auth(type="register", name="Kevin", password="correct horse")
            await mara.auth(type="register", name="Mara", password="battery staple")
            await kevin.until("Mara arrives, well rested.")
            await asyncio.sleep(FEED_BLOCK_MS / 1000 + 2)
            await mara.send(type="cmd", text="say Still there?")
            assert await kevin.until('Mara says, "Still there?"') == ['Mara says, "Still there?"']
            assert kevin.ws.state.name == "OPEN"


async def test_ping_reports_the_redis_clock(redis):
    async with running_server(redis, "one") as url:
        async with Client.open(url) as kevin:
            await kevin.auth(type="register", name="Kevin", password="correct horse")
            await kevin.send(type="ping", t=123)
            async with asyncio.timeout(5):
                while (reply := json.loads(await kevin.ws.recv()))["type"] != "pong":
                    pass
            seconds, micros = await redis.time()
            assert reply["t"] == 123
            assert abs(reply["server_ms"] - (seconds * 1000 + micros / 1000)) < 100


async def test_quitting_closes_with_a_reason(redis):
    async with running_server(redis, "one") as url:
        async with Client.open(url) as kevin:
            await kevin.auth(type="register", name="Kevin", password="correct horse")
            await kevin.send(type="cmd", text="quit")
            await kevin.until("Kevin settles in to rest, and is gone.")
            async with asyncio.timeout(5):
                await kevin.ws.wait_closed()
            assert kevin.ws.close_reason == "You leave the world."
