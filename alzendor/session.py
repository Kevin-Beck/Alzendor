"""One client connection, from authentication until it closes.

Protocol: every WebSocket message is one JSON object with a `type`.

Client -> server
  {"type": "register", "name": ..., "password": ...}
  {"type": "login",    "name": ..., "password": ...}
  {"type": "resume",   "token": ..., "since": <last seq seen>}
  {"type": "create",   "class": ..., "ancestry": ..., "passive": ..., "background": ...}
  {"type": "cmd",      "text": "move north", "target": "npc:orc-1"}   (target optional)
  {"type": "ping",     "t": <client clock ms>}   at most 5 a second
  {"type": "input",    "seq": 812, "step": 4410, "keys": 5, "act": "strike", "slot": 1, "target": "npc:orc-1"}
      In a fight (an encounter): the steering keys held (1 up, 2 down, 4 left,
      8 right), and maybe an act: strike (slot, target), dodge, block,
      unblock, or flee (dir). `step` is the encounter step the client applied
      it at: the owner replays steering from there, up to 200 ms back. Sent on
      any change and every 100 ms; at most 30 a second, and the rest are
      dropped. See docs/combat.md.

Server -> client
  {"type": "auth_ok", "player": <id>, "name": <display name>, "token": ..., "server": <id>, "version": <rules version>}
  {"type": "auth_error", "message": ...}
  {"type": "create", "name": ..., "options": {classes, ancestries, backgrounds}}
  {"type": "create_error", "message": ...}
  {"type": "event", "event": {"seq", "channel", "type", "actor", "verb", "target", "text", "ts", ...}}
  {"type": "error", "message": ...}
  {"type": "pong", "t": <echoed>, "server_ms": <Redis clock ms>}
  {"type": "state", "id": <encounter>, "step": N, "players": {...}, "blows": [...], "bosses": {...}}
      15 a second while the player is in an encounter, from its owner: every
      dot in it (a full snapshot, with the last input `seq` applied), the NPC
      blows announced, and boss stagger meters.
  {"type": "refused", "pid": ..., "act": ..., "reason": ...}   a dropped strike, dodge or flee

An encounter's steps count from its start_ms on Redis's clock. A client syncs
to that clock with ping/pong (server_ms is the time when the pong left, by
Redis's clock). `encounter` events (start, join, leave, end) on the player's
own stream say when they're in one. The README's Protocol section lists the
event types.

A player without a character (a new account, or one wiped for a new version)
is sent `create` after authenticating and must answer with its choices
(docs/characters.md) before entering the world. After that, everything the
client sees arrives as events in sequence order. The connection closes with the reason as its close message when the
player quits, is disconnected, or connects from somewhere else.
"""

import asyncio
import json
import logging
import random
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
INPUTS_PER_SECOND = 30


class Delay:
    """Holds messages for a while, in order, then hands each on: the fake
    latency (ALZ_FAKE_LATENCY_MS) and jitter (ALZ_FAKE_JITTER_MS, up to that
    much more, at random) for trying the game with lag locally. Like TCP, a
    late message holds up the ones behind it rather than being overtaken."""

    def __init__(self, seconds: float, deliver, jitter: float = 0):
        self.seconds = seconds
        self.jitter = jitter
        self.deliver = deliver
        self.queue: asyncio.Queue = asyncio.Queue()
        self.last = 0.0
        self.task = asyncio.create_task(self._run())

    def put(self, item) -> None:
        due = time.monotonic() + self.seconds + random.uniform(0, self.jitter)
        self.last = max(self.last, due)
        self.queue.put_nowait((self.last, item))

    async def _run(self) -> None:
        while True:
            due, item = await self.queue.get()
            wait = due - time.monotonic()
            if wait > 0:
                await asyncio.sleep(wait)
            try:
                await self.deliver(item)
            except ConnectionClosed:
                return
            except Exception:
                log.exception("a delayed message failed")

    def cancel(self) -> None:
        self.task.cancel()


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
        self._inputs: list[float] = []      # when recent inputs came, for their rate limit
        self.encounter: str | None = None   # the encounter the player is in, whose state is forwarded
        self.encounter_owner: str | None = None  # the server that owns it
        self._input_seq = 0
        self._out: Delay | None = None  # outgoing messages, when there's a fake latency
        # A fight's state goes out 15 times a second; each is a full snapshot, so
        # only the newest waiting one matters. One task sends them.
        self._next_state: str | None = None
        self._state_sender: asyncio.Task | None = None
        self._sends: set[asyncio.Task] = set()  # other forwarded messages on their way

    @property
    def address(self) -> str:
        """The client's address, for rate limits. Behind a trusted proxy, CloudFront's
        CloudFront-Viewer-Address ("ip:port") if it sent one, else the last
        X-Forwarded-For entry (the one the proxy added)."""
        if self.server.config.trust_proxy:
            headers = self.ws.request.headers
            viewer = headers.get("CloudFront-Viewer-Address")
            if viewer:
                return viewer.rsplit(":", 1)[0].strip("[]")
            forwarded = headers.get("X-Forwarded-For")
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
        await self._send(type="auth_ok", player=self.pid, name=name, token=self.token, server=self.server.config.server_id,
                         version=self.server.version)
        log.info("%s entered the world from %s (session %s)", self.pid, self.address, self.id)

        self.server.sessions[self.id] = self
        ctx = commands.Context(world, self.pid, self.pid in self.server.config.admins, self._quit,
                               tell=lambda text: self._send(type="error", message=text))
        lag = self.server.config.fake_latency_ms / 1000
        jitter = self.server.config.fake_jitter_ms / 1000
        if lag > 0 or jitter > 0:
            # Everything the client sends and is sent, held for the fake latency each way.
            lag = max(lag, 1e-6)
            self._out = Delay(lag, lambda send: send(), jitter)
            incoming = Delay(lag, lambda message: self._handle(ctx, message), jitter)
        pump = asyncio.create_task(self._pump(feed))
        try:
            async for message in self.ws:
                if lag > 0:
                    incoming.put(message)
                else:
                    await self._handle(ctx, message)
        except ConnectionClosed:
            pass
        finally:
            if lag > 0:
                incoming.cancel()
                self._out.cancel()
            # A dropped connection leaves the player in the world; the reaper
            # removes them if no client resumes within the linkdead grace period.
            # In a fight, their keys are let go: the fight runs on without them.
            self.server.sessions.pop(self.id, None)
            pump.cancel()
            if self.encounter:
                try:
                    await self.server.encounters.send_input(self.encounter, self.encounter_owner,
                                                            json.dumps({"pid": self.pid, "act": "release"}))
                except RedisError:
                    pass
                await self._follow(None, None)
            log.info("%s's connection closed (session %s)", self.pid, self.id)

    async def _authenticate(self) -> int | None:
        """Handles messages until the client authenticates. Returns the sequence
        number to resume from (0 for a fresh login), or None if it went away."""
        auth = self.server.auth
        async for raw in self.ws:
            message = _decode(raw)
            kind = message.get("type") if message else None
            if not self._take_allowance():
                await self._send(type="auth_error", message="Slow down a little.")
                continue
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
            if await world.redis.hget(f"ACCOUNT:{self.pid}", "created") == "1":
                return True  # made meanwhile, in another tab: enter the world with it
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
        if message and message.get("type") == "input":
            try:
                return await self._input(message)
            except RedisError as error:
                # A lost input, not a lost connection: the client sends its keys again on the next change.
                log.warning("fight input from %s dropped: %s", self.pid, error)
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

    async def _input(self, message: dict) -> None:
        """Passes a fight input to the encounter's owner, if the player is in one."""
        now = time.monotonic()
        self._inputs = [t for t in self._inputs if now - t < 1]
        if len(self._inputs) >= INPUTS_PER_SECOND or not self.encounter:
            return
        self._inputs.append(now)
        self.last_active = now
        out = {"pid": self.pid}
        for key, kind in (("seq", int), ("step", int), ("keys", int), ("act", str), ("slot", int), ("target", str), ("dir", str)):
            value = message.get(key)
            if type(value) is kind:
                out[key] = value[:100] if kind is str else value
        await self.server.encounters.send_input(self.encounter, self.encounter_owner, json.dumps(out))

    def _forward(self, data: str) -> None:
        """An encounter's state or refusal, from its owner, to this client."""
        if data.startswith('{"type":"refused"') and json.loads(data).get("pid") != self.pid:
            return
        if self._out:
            self._out.put(lambda: self._send_raw(data))
        elif data.startswith('{"type":"state"'):
            self._next_state = data  # replaces one not yet sent: a slow client gets the newest
            if self._state_sender is None or self._state_sender.done():
                self._state_sender = asyncio.create_task(self._send_states())
        else:
            task = asyncio.create_task(self._send_raw(data))
            self._sends.add(task)
            task.add_done_callback(self._sends.discard)

    async def _send_states(self) -> None:
        while self._next_state is not None:
            data, self._next_state = self._next_state, None
            await self._send_raw(data)

    async def _follow(self, eid: str | None, owner: str | None) -> None:
        """Forwards the state of this encounter (or none) to the client."""
        if eid == self.encounter:
            return
        host = self.server.encounters
        if self.encounter:
            await host.unfollow(self.encounter, self.encounter_owner, self._forward)
        self.encounter, self.encounter_owner = eid, owner
        if eid:
            await host.follow(eid, owner, self._forward)

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
                    if event["type"] == "encounter" and event.get("channel") == f"PLAYER:{self.pid}":
                        if event["op"] == "start":
                            await self._follow(event["id"], (event.get("encounter") or {}).get("owner"))
                        elif event["op"] == "end" and event["id"] == self.encounter:
                            await self._follow(None, None)
                    await self._send(type="event", event=event)
            await self._later(lambda: self.ws.close(1000, feed.ended[:120]))
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
        data = json.dumps(message)
        await self._later(lambda: self.ws.send(data))

    async def _later(self, send) -> None:
        """Sends now, or after the fake latency if there is one."""
        if self._out:
            self._out.put(send)
        else:
            await send()

    async def _send_raw(self, data: str) -> None:
        try:
            await self.ws.send(data)
        except ConnectionClosed:
            pass
        except Exception:
            log.exception("sending to %s failed", self.pid)


def _decode(raw) -> dict | None:
    try:
        message = json.loads(raw)
    except (TypeError, ValueError):
        return None
    return message if isinstance(message, dict) else None
