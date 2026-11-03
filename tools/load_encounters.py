"""Load test for encounters (docs/combat.md, "Cost"): bot players
fighting at once, each in an encounter of its own, steering toward the centre
of their circle from the owner's state and striking when they're there.

    python -m tools.load_encounters --url ws://localhost:8097/ws --redis redis://localhost:6380/1 \\
        --players 50 --seconds 60 --pid <the game server's process id>

Run it against a test server and its own Redis, never the live one: it
registers bot accounts and puts a hostile copy of the Sparring Post in a room
of each bot's own (or, with --same-room, all in the Training Yard), and takes
those copies away again at the end (--keep leaves them). --redis has no
default, and db 0 (where a game keeps its world) is refused unless
--i-mean-it. Each
bot's foe belongs to that bot alone (like an ambusher), so every bot is in an
encounter of its own, owned by the server it's connected to. With --pid, it reports that process's CPU use (of one core)
while the bots fight.

It reports the round trip, how many state messages each bot got a second,
strikes landed, and the server's CPU. The budget is 10% of one core on the
t4g.micro with 50 players; if it's over, lower encounter_hz from 30 to 20.
"""

from __future__ import annotations

import argparse
import asyncio
import json
import os
import statistics
import time
from urllib.parse import urlsplit

from websockets.asyncio.client import connect

from alzendor.server import open_redis
from alzendor.world import World

ROOM = "training_yard"
TEMPLATE = "post-1"


class Bot:
    def __init__(self, n: int, url: str):
        self.n = n
        self.url = url
        self.name = f"Loadbot{n}"
        self.pid = self.name.lower()
        self.server = ""
        self.states = 0
        self.strikes = 0
        self.rtts: list[float] = []
        self.dot = None
        self.seq = 0
        self.keys = 0
        self.ws = None

    async def login(self) -> None:
        self.ws = await connect(self.url, max_size=2**20)
        await self.ws.send(json.dumps({"type": "register", "name": self.name, "password": "load test bot"}))
        reply = json.loads(await self.ws.recv())
        if reply["type"] == "auth_error":  # registered by an earlier run
            await self.ws.send(json.dumps({"type": "login", "name": self.name, "password": "load test bot"}))
            reply = json.loads(await self.ws.recv())
        if reply["type"] == "create":
            await self.ws.send(json.dumps({"type": "create", "class": "fighter", "ancestry": "human", "passive": "second_wind",
                                           "background": "merchant"}))
            reply = json.loads(await self.ws.recv())
        assert reply["type"] == "auth_ok", reply
        self.server = reply["server"]

    async def run(self, until: float) -> None:
        reader = asyncio.create_task(self._read())
        try:
            pinged = 0.0
            while time.monotonic() < until:
                if time.monotonic() - pinged >= 1:  # for the round trip (the web client pings far less)
                    pinged = time.monotonic()
                    await self.ws.send(json.dumps({"type": "ping", "t": pinged * 1000}))
                self._steer()
                await self.ws.send(json.dumps(self._input()))
                await asyncio.sleep(0.1)
        finally:
            reader.cancel()
            await self.ws.close()

    def _input(self) -> dict:
        self.seq += 1
        message = {"type": "input", "seq": self.seq, "keys": self.keys}
        if self.dot and (self.dot["x"] ** 2 + self.dot["y"] ** 2) ** 0.5 < 0.1:
            message.update(act="strike", slot=1, target="")
        return message

    def _steer(self) -> None:
        if not self.dot:
            return
        x, y, keys = self.dot["x"], self.dot["y"], 0
        if x > 0.03:
            keys |= 4
        elif x < -0.03:
            keys |= 8
        if y > 0.03:
            keys |= 1
        elif y < -0.03:
            keys |= 2
        self.keys = keys

    async def _read(self) -> None:
        async for raw in self.ws:
            if raw.startswith('{"type":"state"'):
                self.states += 1
                self.dot = json.loads(raw)["players"].get(self.pid)
                continue
            message = json.loads(raw)
            if message["type"] == "pong" and isinstance(message.get("t"), (int, float)):
                self.rtts.append(time.monotonic() * 1000 - message["t"])
            elif message["type"] == "event" and message["event"].get("type") == "combat" and message["event"].get("actor") == self.pid:
                self.strikes += 1


async def rooms_to_fight_in(redis, count: int, same: bool) -> list[str]:
    """A room for each bot: the Training Yard for all of them (the worst case:
    everyone hears every blow), or rooms of their own (more like real play)."""
    if same:
        return [ROOM] * count
    rooms = []
    for key in sorted(await redis.keys("ROOM:*:info")):
        rid = key.split(":")[1]
        if await redis.hget(key, "waypoint") != "1":
            rooms.append(rid)
    return [rooms[i % len(rooms)] for i in range(count)]


async def put_in_a_fight(redis, bot: Bot, room: str) -> None:
    """A private, hostile, unkillable Sparring Post for this bot, then the bot
    jumps there: the one rule starts its encounter, owned by its server."""
    nid = f"{TEMPLATE}~{bot.pid}~1"
    template = await redis.hgetall(f"NPC:{TEMPLATE}")
    await redis.delete(f"NPC:{nid}", f"NPC:{nid}:encounter")
    await redis.hset(f"NPC:{nid}", mapping={**template, "room": room, "owner": bot.pid, "disposition": "hostile",
                                           "immortal": "1", "respawn": 0, "hp": template.get("max_hp", 200)})
    await redis.sadd(f"ROOM:{room}:npcs", nid)
    await World(redis, bot.server).call("goto", bot.pid, room)


async def clean_up(redis, bots: list[Bot]) -> int:
    """Takes the bots' Sparring Posts out of the world."""
    removed = 0
    for bot in bots:
        nid = f"{TEMPLATE}~{bot.pid}~1"
        room = await redis.hget(f"NPC:{nid}", "room")
        if room:
            await redis.srem(f"ROOM:{room}:npcs", nid)
        removed += await redis.delete(f"NPC:{nid}", f"NPC:{nid}:encounter")
    return removed


def cpu_seconds(pid: int) -> float:
    with open(f"/proc/{pid}/stat") as f:
        fields = f.read().rsplit(")", 1)[1].split()
    return (int(fields[11]) + int(fields[12])) / os.sysconf("SC_CLK_TCK")


async def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--url", default="ws://localhost:8000/ws")
    parser.add_argument("--redis", required=True, help="the test server's Redis, e.g. redis://localhost:6380/1 (never the live one)")
    parser.add_argument("--i-mean-it", action="store_true", help="allow db 0 of a Redis")
    parser.add_argument("--keep", action="store_true", help="leave the bots' Sparring Posts in the world at the end")
    parser.add_argument("--players", type=int, default=50)
    parser.add_argument("--seconds", type=float, default=60)
    parser.add_argument("--pid", type=int, help="the game server's process id, to measure its CPU")
    parser.add_argument("--same-room", action="store_true", help="every bot in the Training Yard (the worst case)")
    parser.add_argument("--idle", action="store_true", help="connected and sending inputs, but not fighting: the baseline")
    args = parser.parse_args()
    if not args.i_mean_it and urlsplit(args.redis).path.strip("/") in ("", "0"):
        parser.error(f"--redis {args.redis} is db 0, where a game keeps its world: use another db, or add --i-mean-it")

    print(f"Writing bot accounts and NPCs to {args.redis}")
    redis = open_redis(args.redis)
    bots = [Bot(n, args.url) for n in range(args.players)]
    for i in range(0, len(bots), 10):  # signups are rate limited per address; raise ALZ_SIGNUPS_PER_HOUR for big runs
        await asyncio.gather(*(b.login() for b in bots[i:i + 10]))
    for bot, room in zip(bots, await rooms_to_fight_in(redis, len(bots), args.same_room)):
        if not args.idle:
            await put_in_a_fight(redis, bot, room)
    await asyncio.sleep(2)  # the lead-ins
    before = (time.monotonic(), cpu_seconds(args.pid)) if args.pid else None
    until = time.monotonic() + args.seconds
    await asyncio.gather(*(b.run(until) for b in bots))
    cpu = None
    if before:
        cpu = 100 * (cpu_seconds(args.pid) - before[1]) / (time.monotonic() - before[0])
    fighting = sum(1 for b in bots if b.states)
    rtts = [r for b in bots for r in b.rtts]
    print(f"{args.players} bots for {args.seconds:.0f} s, {fighting} of them in a fight")
    print(f"state messages: {statistics.mean(b.states for b in bots) / args.seconds:.1f} a second per bot")
    print(f"strikes landed: {sum(b.strikes for b in bots)}")
    if rtts:
        print(f"round trip: median {statistics.median(rtts):.1f} ms, 95th percentile {sorted(rtts)[int(len(rtts) * 0.95)]:.1f} ms")
    if cpu is not None:
        print(f"server CPU: {cpu:.1f}% of one core")
    if not args.keep:
        print(f"cleaned up: {await clean_up(redis, bots)} keys")
    await redis.aclose()


if __name__ == "__main__":
    asyncio.run(main())
