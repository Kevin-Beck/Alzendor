"""The game server: accepts WebSocket connections and serves the web client.

A server keeps no lasting game state. The world, subscriptions and events all
live in Redis, so several servers can run side by side and a client can
reconnect to any of them. A fight is the exception: each one is simulated by
one server, its owner, and starts again on another if that server dies
(encounter.py, docs/combat.md). Each server needs an id of its own
(ALZ_SERVER_ID) for that, and claims it in Redis while it runs.
"""

import asyncio
import hashlib
import json
import logging
import random
import secrets
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
from .encounter import EncounterHost
from .feed import FEED_BLOCK_MS
from .session import Session
from .world import LUA_LIBRARY, World, load_seed, validate_seed

log = logging.getLogger(__name__)

WEB_CLIENT = Path(__file__).with_name("web") / "index.html"
MAX_MESSAGE_BYTES = 16 * 1024
MAX_REDIS_CONNECTIONS = 1000
WEATHER_SECONDS = 30  # how often weather_tick runs (ground, NPCs, everyone's weather)
UPKEEP_SECONDS = 5  # how often upkeep runs (respawns, healing): once per slot, across all servers
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
        self.world = World(redis, config.server_id)
        self.auth = Auth(redis, config.session_ttl_days * 24 * 3600, config.signups_per_hour)
        self.sessions: dict[str, Session] = {}
        self.ambient: list[dict] = []
        # Redis's clock minus ours. Combat timing is judged by Redis's clock,
        # so clients sync to it (ping/pong) through this offset.
        self.clock_offset_ms = 0.0
        self._web_client = WEB_CLIENT.read_bytes()
        # The encounters this server owns, and the bus their inputs and state travel on.
        self.encounters = EncounterHost(self.world, config.server_id, self.now_ms)
        self.version = ""  # of the rules and content this server loaded (rules_version)
        self._claim = secrets.token_hex(8)  # proves alz:server:<id> is this process's

    async def prepare(self) -> None:
        """Checks the map, then installs the game rules and loads it. Safe to
        run on every server at every start: it never overwrites live state. The
        rules belong to the whole Redis, so the last server to start decides
        them for every server: one from another version is logged."""
        data = load_seed(self.config.seed_file)
        validate_seed(data)  # before anything is installed: a bad map changes nothing
        self.version = rules_version(data)
        loaded = await self.world.redis.hgetall("alz:version")
        if loaded and loaded.get("version") != self.version:
            log.warning("replacing rules and content %s (loaded by server %s) with %s: servers still running "
                        "the old version will call rules they weren't written for until they restart",
                        loaded.get("version"), loaded.get("server"), self.version)
        await self.world.load_rules()
        seed = await self.world.seed(self.config.seed_file, data)
        await self.world.redis.hset("alz:version", mapping={"version": self.version, "server": self.config.server_id,
                                                            "at": int(time.time())})
        log.info("rules and content version %s", self.version)
        self.ambient = seed.get("ambient", [])
        await self.sync_clock()

    def _claim_ttl(self) -> int:
        return max(30, 3 * self.config.heartbeat_seconds)

    async def claim_server_id(self, wait: int | None = None) -> None:
        """Holds alz:server:<id> while running: two servers with one id would
        both run every fight that id owns. Waits out a claim left by a server
        that stopped without letting go (up to `wait` seconds, by default as
        long as a claim lasts), then gives up."""
        key, ttl = f"alz:server:{self.config.server_id}", self._claim_ttl()
        wait = ttl if wait is None else wait
        for attempt in range(wait + 1):
            if await self.world.redis.set(key, self._claim, nx=True, ex=ttl):
                return
            if attempt == wait:
                break
            if attempt == 0:
                log.warning("server id %r is held by another server; waiting up to %d s for it to go",
                            self.config.server_id, wait)
            await asyncio.sleep(1)
        raise RuntimeError(f"Server id {self.config.server_id!r} is in use by another running server. "
                           "Give each server its own ALZ_SERVER_ID.")

    async def release_server_id(self) -> None:
        key = f"alz:server:{self.config.server_id}"
        try:
            if await self.world.redis.get(key) == self._claim:
                await self.world.redis.delete(key)
        except Exception:
            log.exception("couldn't release the server id")

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
        path = request.path.split("?", 1)[0]  # the page takes flags in its query (?balance=1)
        if path == "/ws":
            return None  # carry on with the WebSocket handshake
        if path in ("/", "/index.html"):
            headers = Headers({"Content-Type": "text/html; charset=utf-8", "Cache-Control": "no-cache", **SECURITY_HEADERS})
            return Response(200, "OK", headers, self._web_client)
        if path == "/healthz":
            return connection.respond(200, f"ok {self.version}\n")
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
            # Encounter state goes out 15 times a second to every fighting
            # player: deflating each message cost more CPU than anything else.
            compression=None,
        ) as server:
            log.info("server %s listening on %s:%d", self.config.server_id, self.config.host, self.config.port)
            if self.config.fake_latency_ms or self.config.fake_jitter_ms:
                log.warning("faking %d ms of latency (and up to %d ms of jitter) each way: for local testing only",
                            self.config.fake_latency_ms, self.config.fake_jitter_ms)
            await self.claim_server_id()
            await self.encounters.start()
            tasks = [asyncio.create_task(loop()) for loop in (self._heartbeats, self._ticker, self._world_tick)]
            try:
                await stop
            finally:
                for task in tasks:
                    task.cancel()
                await self.encounters.close()
                await self.release_server_id()
                server.close()

    async def _heartbeats(self) -> None:
        """Marks this server's players as connected, and takes out of the world
        any player whose connection has been gone too long, on any server."""
        redis = self.world.redis
        while True:
            try:
                await self.world.redis.set(f"alz:server:{self.config.server_id}", self._claim, ex=self._claim_ttl())
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

    async def _world_tick(self) -> None:
        """Finishes held-up moves and moves journeys on as they come due. Every
        server runs this loop; each is taken off its schedule atomically."""
        while True:
            await asyncio.sleep(0.1)
            try:
                await self.world.call("tick")
            except Exception:
                log.exception("world tick failed")
                await asyncio.sleep(1)

    async def upkeep(self) -> bool:
        """The world's upkeep, once per UPKEEP_SECONDS slot across every
        server: it heals by a fixed amount a call, so it isn't safe to run once
        per server. Returns whether this server ran it."""
        slot = int(time.time() // UPKEEP_SECONDS)
        if not await self.world.redis.set(f"alz:upkeep:{slot}", self.config.server_id, nx=True, ex=UPKEEP_SECONDS * 4):
            return False
        await self.world.call("upkeep")
        return True

    async def _ticker(self) -> None:
        """Runs the world's upkeep (respawns, sleeping bodies fading, healing out
        of a fight), the weather's 30-second tick, and the map's ambient events.
        Every server runs this loop, so each of them takes a Redis key per time
        slot first: only one server fires each (atomic isn't enough; upkeep
        and the weather change the world each time they run)."""
        last_slot = {i: int(time.time() // a["every"]) for i, a in enumerate(self.ambient)}
        last_weather = 0
        while True:
            # Just past the start of the next slot, so no slot is skipped.
            await asyncio.sleep(UPKEEP_SECONDS - time.time() % UPKEEP_SECONDS + random.uniform(0.05, 0.3))
            try:
                await self.upkeep()
            except Exception:
                log.exception("upkeep failed")
            # The weather's beat: one server per 30 s slot (see weather_tick).
            slot = int(time.time() // WEATHER_SECONDS)
            if slot != last_weather:
                last_weather = slot
                try:
                    if await self.world.redis.set(f"alz:weather_tick:{slot}", self.config.server_id, nx=True, ex=WEATHER_SECONDS * 2):
                        await self.world.call("weather_tick")
                except Exception:
                    log.exception("weather tick failed")
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
    # And each holds a connection while it waits, so the pool has room for a
    # connection per player and then some (redis-py's default is 100).
    return Redis.from_url(
        url,
        decode_responses=True,
        protocol=2,
        socket_timeout=FEED_BLOCK_MS / 1000 + 10,
        socket_connect_timeout=5,
        max_connections=MAX_REDIS_CONNECTIONS,
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


def rules_version(data: dict) -> str:
    """Names the rules library and the content a server loads, so servers of
    different versions on one Redis show up (alz:version, /healthz, auth_ok)."""
    digest = hashlib.sha1(LUA_LIBRARY.read_bytes())
    digest.update(json.dumps(data, sort_keys=True).encode())
    return digest.hexdigest()[:12]
