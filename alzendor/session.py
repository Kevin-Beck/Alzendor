"""One client connection, from authentication until it closes.

Protocol: every WebSocket message is one JSON object with a `type`.

Client -> server
  {"type": "register", "name": ..., "password": ...}
  {"type": "login",    "name": ..., "password": ...}
  {"type": "resume",   "token": ..., "since": <last seq seen>}
  {"type": "create",   "class": ..., "ancestry": ..., "passive": ..., "background": ...}
  {"type": "cmd",      "text": "move north", "target": "npc:orc-1"}   (target optional)
  {"type": "ping",     "t": <client clock ms>}   at most 5 a second

Server -> client
  {"type": "auth_ok", "player": <id>, "name": <display name>, "token": ..., "server": <id>}
  {"type": "auth_error", "message": ...}
  {"type": "create", "name": ..., "options": {classes, ancestries, backgrounds}}
  {"type": "create_error", "message": ...}
  {"type": "event", "event": {"seq", "channel", "type", "actor", "verb", "target", "text", "ts", ...}}
  {"type": "error", "message": ...}
  {"type": "pong", "t": <echoed>, "server_ms": <Redis clock ms>}

Combat timing is judged by Redis's clock. A client syncs to it with ping/pong
(server_ms is the time when the pong left, by Redis's clock) and uses that to
draw the timing bars from `timing` events (your slots) and `npc_timing` events
(an NPC's attacks). The README's Protocol section lists the event types.

A player without a character (a new account, or one wiped for a new version)
is sent `create` after authenticating and must answer with its choices
(docs/characters.md) before entering the world. After that, everything the
client sees arrives as events in sequence order. The connection closes with the reason as its close message when the
player quits, is disconnected, or connects from somewhere else.
"""

import asyncio
import json
import logging
import secrets
import time

from redis.exceptions import RedisError
from websockets.asyncio.server import ServerConnection
from websockets.exceptions import ConnectionClosed

from . import commands
from .auth import AuthError
from .feed import Feed

log = logging.getLogger(__name__)

AUTH_TIMEOUT_SECONDS = 120
CREATE_TIMEOUT_SECONDS = 1800
COMMANDS_PER_SECOND = 4
COMMAND_BURST = 10


class Session:
    def __init__(self, server, ws: ServerConnection):
        self.server = server
        self.ws = ws
        self.id = secrets.token_hex(8)
        self.pid: str | None = None
        self.token: str | None = None
        self._allowance = float(COMMAND_BURST)
        self._last_command = time.monotonic()
        self._last_ping = 0.0
        self.last_active = time.monotonic()  # the last command, for the idle timeout

    @property
    def address(self) -> str:
        forwarded = self.ws.request.headers.get("X-Forwarded-For") if self.server.config.trust_proxy else None
        if forwarded:
            return forwarded.split(",")[-1].strip()
        return self.ws.remote_address[0] if self.ws.remote_address else "unknown"

    async def run(self) -> None:
        try:
            since = await asyncio.wait_for(self._authenticate(), AUTH_TIMEOUT_SECONDS)
        except (TimeoutError, ConnectionClosed):
            return
        if since is None:
            return

        world = self.server.world
        if await world.redis.hget(f"ACCOUNT:{self.pid}", "created") != "1":
            try:
                if not await asyncio.wait_for(self._create_character(), CREATE_TIMEOUT_SECONDS):
                    return
            except (TimeoutError, ConnectionClosed):
                return
            since = 0
        cursor = await world.call("connect", self.pid, self.id, since)
        feed = await Feed.open(world.redis, self.pid, self.id, cursor)
        name = await world.redis.hget(f"ACCOUNT:{self.pid}", "name")
        await self._send(type="auth_ok", player=self.pid, name=name, token=self.token, server=self.server.config.server_id)
        log.info("%s entered the world from %s (session %s)", self.pid, self.address, self.id)

        self.server.sessions[self.id] = self
        pump = asyncio.create_task(self._pump(feed))
        ctx = commands.Context(world, self.pid, self.pid in self.server.config.admins, self._quit)
        try:
            async for message in self.ws:
                await self._handle(ctx, message)
        except ConnectionClosed:
            pass
        finally:
            # A dropped connection leaves the player in the world; the reaper
            # removes them if no client resumes within the linkdead grace period.
            self.server.sessions.pop(self.id, None)
            pump.cancel()
            log.info("%s's connection closed (session %s)", self.pid, self.id)

    async def _authenticate(self) -> int | None:
        """Handles messages until the client authenticates. Returns the sequence
        number to resume from (0 for a fresh login), or None if it went away."""
        auth = self.server.auth
        async for raw in self.ws:
            message = _decode(raw)
            kind = message.get("type") if message else None
            try:
                if kind in ("register", "login"):
                    name, password = str(message.get("name", "")), str(message.get("password", ""))
                    if kind == "register":
                        self.pid = await auth.register(name, password, self.address)
                    else:
                        self.pid = await auth.login(name, password, self.address)
                    self.token = await auth.issue_token(self.pid)
                    return 0
                if kind == "resume":
                    self.token = str(message.get("token", ""))
                    self.pid = await auth.resume(self.token)
                    if self.pid is None:
                        raise AuthError("Your session has expired. Please log in again.")
                    since = message.get("since")
                    return since if type(since) is int and since > 0 else 0
                await self._send(type="error", message="Log in or register first.")
            except AuthError as failure:
                await self._send(type="auth_error", message=str(failure))
        return None

    async def _create_character(self) -> bool:
        """Offers the character creation choices until the client makes valid
        ones. Returns False if the client went away."""
        world = self.server.world
        name = await world.redis.hget(f"ACCOUNT:{self.pid}", "name")
        await self._send(type="create", name=name, token=self.token, options=world.creation)
        async for raw in self.ws:
            message = _decode(raw)
            if not self._take_allowance():
                await self._send(type="create_error", message="Slow down a little.")
                continue
            if not message or message.get("type") != "create":
                await self._send(type="create_error", message="Create your character first.")
                continue
            choices = [str(message.get(key, ""))[:40] for key in ("class", "ancestry", "passive", "background")]
            problem = await world.call("create_character", self.pid, *choices)
            if not problem:
                log.info("%s created a character: %s", self.pid, " ".join(choices))
                return True
            await self._send(type="create_error", message=problem)
        return False

    async def _handle(self, ctx: commands.Context, raw) -> None:
        message = _decode(raw)
        if message and message.get("type") == "ping":
            now = time.monotonic()
            if now - self._last_ping >= 0.2:
                self._last_ping = now
                echo = message.get("t") if type(message.get("t")) in (int, float) else None
                await self._send(type="pong", t=echo, server_ms=self.server.now_ms())
            return
        if not message or message.get("type") != "cmd" or not isinstance(message.get("text"), str):
            await self._send(type="error", message='Expected {"type": "cmd", "text": ...}.')
            return
        self.last_active = time.monotonic()
        if not self._take_allowance():
            await self._send(type="error", message="Slow down a little.")
            return
        ctx.target = commands.target_id(message.get("target"))
        try:
            await commands.dispatch(ctx, message["text"])
        except Exception:
            log.exception("command from %s failed: %r", self.pid, message["text"][:100])
            await self._send(type="error", message="Something went wrong with that command.")

    async def _pump(self, feed: Feed) -> None:
        """Forwards this player's events to the client until told to stop."""
        try:
            while feed.ended is None:
                try:
                    events = await feed.read()
                except RedisError as error:
                    # Safe to retry: the feed carries on from the last event sent.
                    log.warning("event feed for %s: %s; retrying", self.pid, error)
                    await asyncio.sleep(1)
                    continue
                for event in events:
                    await self._send(type="event", event=event)
            await self.ws.close(1000, feed.ended[:120])
        except ConnectionClosed:
            pass
        except Exception:
            log.exception("event feed for %s failed", self.pid)
            await self.ws.close(1011, "Server error.")

    async def _quit(self, revoke: bool) -> None:
        if revoke and self.token:
            await self.server.auth.revoke(self.token)
        reason = "You have logged out." if revoke else "You leave the world."
        # Emits the room's leave event and a kick for this session, which the
        # feed delivers in order before closing the connection.
        await self.server.world.call("disconnect", self.pid, self.id, "", reason)

    def _take_allowance(self) -> bool:
        now = time.monotonic()
        self._allowance = min(COMMAND_BURST, self._allowance + (now - self._last_command) * COMMANDS_PER_SECOND)
        self._last_command = now
        if self._allowance < 1:
            return False
        self._allowance -= 1
        return True

    async def _send(self, **message) -> None:
        await self.ws.send(json.dumps(message))


def _decode(raw) -> dict | None:
    try:
        message = json.loads(raw)
    except (TypeError, ValueError):
        return None
    return message if isinstance(message, dict) else None
