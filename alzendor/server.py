"""The game server: accepts WebSocket connections and serves the web client.

A server holds client connections and nothing else. World state, subscriptions
and events all live in Redis, so any number of servers can run side by side and
a client can reconnect to any of them.
"""

import asyncio
import logging
import random
import signal
import time
from pathlib import Path

from redis.asyncio import Redis
from redis.exceptions import ConnectionError as RedisConnectionError
from websockets.asyncio.server import ServerConnection, serve
from websockets.datastructures import Headers
from websockets.http11 import Request, Response

from .auth import Auth
from .config import Config
from .feed import FEED_BLOCK_MS
from .session import Session
from .world import World

log = logging.getLogger(__name__)

WEB_CLIENT = Path(__file__).with_name("web") / "index.html"
MAX_MESSAGE_BYTES = 16 * 1024
SECURITY_HEADERS = {
    "Content-Security-Policy": (
        "default-src 'none'; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'; "
        "connect-src 'self'; img-src 'self' data:; base-uri 'none'; frame-ancestors 'none'"
    ),
    "X-Content-Type-Options": "nosniff",
    "Referrer-Policy": "no-referrer",
}


class GameServer:
    def __init__(self, config: Config, redis: Redis):
        self.config = config
        self.world = World(redis)
        self.auth = Auth(redis, config.session_ttl_days * 24 * 3600, config.signups_per_hour)
        self.sessions: dict[str, Session] = {}
        self.ambient: list[dict] = []
        # Redis's clock minus ours. Combat timing is judged by Redis's clock,
        # so clients sync to it (ping/pong) through this offset.
        self.clock_offset_ms = 0.0
        self._web_client = WEB_CLIENT.read_bytes()

    async def prepare(self) -> None:
        """Installs the game rules and loads the map. Safe to run on every
        server at every start: it never overwrites live state."""
        await self.world.load_rules()
        seed = await self.world.seed(self.config.seed_file)
        self.ambient = seed.get("ambient", [])
        await self.sync_clock()

    async def sync_clock(self) -> None:
        before = time.time()
        seconds, micros = await self.world.redis.time()
        after = time.time()
        self.clock_offset_ms = seconds * 1000 + micros / 1000 - (before + after) * 500

    def now_ms(self) -> int:
        """The current time by Redis's clock, without asking Redis."""
        return int(time.time() * 1000 + self.clock_offset_ms)

    async def handle(self, ws: ServerConnection) -> None:
        await Session(self, ws).run()

    def http(self, connection: ServerConnection, request: Request) -> Response | None:
        if request.path == "/ws":
            return None  # carry on with the WebSocket handshake
        if request.path in ("/", "/index.html"):
            headers = Headers({"Content-Type": "text/html; charset=utf-8", "Cache-Control": "no-cache", **SECURITY_HEADERS})
            return Response(200, "OK", headers, self._web_client)
        if request.path == "/healthz":
            return connection.respond(200, "ok\n")
        return connection.respond(404, "Not found\n")

    async def serve(self, stop: asyncio.Future) -> None:
        origins = [*self.config.allowed_origins, None] if self.config.allowed_origins else None
        async with serve(
            self.handle,
            self.config.host,
            self.config.port,
            process_request=self.http,
            origins=origins,
            max_size=MAX_MESSAGE_BYTES,
        ) as server:
            log.info("server %s listening on %s:%d", self.config.server_id, self.config.host, self.config.port)
            tasks = [asyncio.create_task(loop()) for loop in (self._heartbeats, self._ticker, self._combat)]
            try:
                await stop
            finally:
                for task in tasks:
                    task.cancel()
                server.close()

    async def _heartbeats(self) -> None:
        """Marks this server's players as connected, and takes out of the world
        any player whose connection has been gone too long, on any server."""
        redis = self.world.redis
        while True:
            try:
                await self.sync_clock()
                now = int(time.time() * 1000)
                live = {s.pid: now for s in self.sessions.values()}
                if live:
                    await redis.zadd("alz:online", live, xx=True)
                cutoff = now - self.config.linkdead_seconds * 1000
                for pid in await redis.zrangebyscore("alz:online", "-inf", cutoff):
                    if await self.world.call("disconnect", pid, "", cutoff, "Your connection was lost."):
                        log.info("removed %s from the world after their connection was lost", pid)
                await self._send_idle_to_sleep()
            except Exception:
                log.exception("heartbeat failed")
            await asyncio.sleep(self.config.heartbeat_seconds)

    async def _send_idle_to_sleep(self) -> None:
        """Takes players who have been idle too long out of the world."""
        if self.config.idle_minutes <= 0:
            return
        limit = time.monotonic() - self.config.idle_minutes * 60
        for session in list(self.sessions.values()):
            if session.last_active < limit and session.pid:
                await self.world.call("disconnect", session.pid, session.id, "", "You drifted off after a long while idle.")
                log.info("%s left the world after being idle", session.pid)

    async def _combat(self) -> None:
        """Lands NPC attacks as they come due. Every server runs this loop; each
        attack is taken off the schedule atomically, so it lands only once."""
        while True:
            await asyncio.sleep(0.1)
            try:
                await self.world.call("tick")
            except Exception:
                log.exception("combat tick failed")
                await asyncio.sleep(1)

    async def _ticker(self) -> None:
        """Runs the world's upkeep (respawns, sleeping bodies fading, healing out
        of a fight) and publishes the map's ambient events (bells, weather).
        Every server runs this loop: upkeep is atomic in Redis, and a Redis key
        per time slot makes sure only one server fires each ambient."""
        last_slot = {i: int(time.time() // a["every"]) for i, a in enumerate(self.ambient)}
        while True:
            await asyncio.sleep(5)
            try:
                await self.world.call("upkeep")
            except Exception:
                log.exception("upkeep failed")
            for i, ambient in enumerate(self.ambient):
                slot = int(time.time() // ambient["every"])
                if slot == last_slot[i]:
                    continue
                last_slot[i] = slot
                try:
                    key = f"alz:ambient:{ambient['channel']}:{slot}"
                    if await self.world.redis.set(key, self.config.server_id, nx=True, ex=ambient["every"] * 2):
                        await self.world.call("ambient", ambient["channel"], random.choice(ambient["texts"]))
                except Exception:
                    log.exception("ambient event failed")


def open_redis(url: str) -> Redis:
    # Each player's feed blocks on XREAD for up to FEED_BLOCK_MS, so reads must be
    # allowed to take longer than that. redis-py's default timeout (5s) is not.
    return Redis.from_url(
        url,
        decode_responses=True,
        protocol=2,
        socket_timeout=FEED_BLOCK_MS / 1000 + 10,
        socket_connect_timeout=5,
    )


async def connect_redis(url: str) -> Redis:
    """Connects to Redis, retrying with backoff until it's reachable."""
    delay = 0.5
    while True:
        redis = open_redis(url)
        try:
            await redis.ping()
            return redis
        except (RedisConnectionError, OSError) as error:
            await redis.aclose()
            log.warning("Redis at %s isn't reachable (%s); retrying in %.1fs", url, error, delay)
            await asyncio.sleep(delay)
            delay = min(delay * 2, 10)


async def main(config: Config) -> None:
    redis = await connect_redis(config.redis_url)
    server = GameServer(config, redis)
    await server.prepare()

    stop = asyncio.get_running_loop().create_future()
    for sig in (signal.SIGINT, signal.SIGTERM):
        asyncio.get_running_loop().add_signal_handler(sig, lambda: stop.done() or stop.set_result(None))
    try:
        await server.serve(stop)
    finally:
        await redis.aclose()
