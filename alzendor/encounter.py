"""Encounters, as their owner runs them (docs/combat-redesign.md).

Every fight is an encounter, and one server runs each: the server that caused
it, its owner. The owner simulates every player's dot (alzendor/balance.py)
and the NPCs' attack clock in fixed 1/60 s steps, `encounter_hz` ticks a
second. It never changes the world itself: a strike that lands calls
`encounter_strike` and a blow `encounter_blow` (alzendor.lua), which do the
damage, kills, drops and deaths in the global event order, and the owner
carries on from what they say happened.

Players may be connected to any server. Their sessions publish inputs on
`enc:<id>:in`, and the owner publishes the encounter's state on
`enc:<id>:out`, which every session with a player in the encounter forwards
to its client. Lua publishes `{"op": "sync"}` on `enc:<id>:in` when the
encounter changes (someone joins or leaves), and `{"op": "end"}` when it's over.

The owner refreshes the encounter's lease (`ENC:<id>:lease`) every second.
Every server checks the live encounters once a second, and ends one whose
lease has lapsed (its owner died): everyone keeps the health they have, and
the one rule starts a fresh encounter for whoever is still there, owned by
the server that found it.
"""

from __future__ import annotations

import asyncio
import json
import logging
import math
import random
import time
from collections import defaultdict, deque
from collections.abc import Callable
from dataclasses import dataclass, field

from redis.asyncio import Redis

from . import balance as b
from .world import World

log = logging.getLogger(__name__)

LEASE_MS = 3000
STATE_HZ = 15            # state messages a second
MAX_CATCH_UP = 120       # steps a tick may run to catch up (2 s)
# How far back a player's steering may be applied: an input says which step
# the client applied it at, and the owner replays the dot from there, so lag
# doesn't put the server's dot somewhere the player never steered it. Capped,
# because a modified client could use it to revise its recent steering.
REWIND_STEPS = b.steps(200)
# What a rewind takes from the replay when something in the window has
# already gone to Lua: where the dot is and how it's moving. Everything else
# (cooldowns, a buffered strike, dodges, debuffs) stays as it happened.
REWOUND = ("x", "y", "vx", "vy", "stagger", "sx", "sy", "immune", "wobble_clock")
NEW_ENCOUNTERS = "alz:new_encounters"


class Bus:
    """One pubsub connection for a server: owners listen for inputs on it, and
    sessions for state. Handlers are plain functions of the message data."""

    def __init__(self, redis: Redis):
        self.redis = redis
        self.pubsub = redis.pubsub()
        self.handlers: dict[str, set[Callable[[str], None]]] = defaultdict(set)
        self.task: asyncio.Task | None = None

    async def start(self, name: str) -> None:
        await self.pubsub.subscribe(f"alz:bus:{name}")  # so the connection is always listening
        self.task = asyncio.create_task(self._run())

    async def close(self) -> None:
        if self.task:
            self.task.cancel()
        await self.pubsub.aclose()

    async def subscribe(self, channel: str, handler: Callable[[str], None]) -> None:
        first = not self.handlers[channel]
        self.handlers[channel].add(handler)
        if first:
            await self.pubsub.subscribe(channel)

    async def unsubscribe(self, channel: str, handler: Callable[[str], None]) -> None:
        handlers = self.handlers.get(channel)
        if handlers is None:
            return
        handlers.discard(handler)
        if not handlers:
            del self.handlers[channel]
            await self.pubsub.unsubscribe(channel)

    async def _run(self) -> None:
        while True:
            try:
                message = await self.pubsub.get_message(ignore_subscribe_messages=True, timeout=1.0)
            except asyncio.CancelledError:
                raise
            except Exception:
                log.exception("encounter bus read failed")
                await asyncio.sleep(0.5)
                continue
            if not message or message["type"] != "message":
                continue
            for handler in list(self.handlers.get(message["channel"], ())):
                try:
                    handler(message["data"])
                except Exception:
                    log.exception("encounter bus handler failed")


# The encounter's state, as the owner keeps it ---------------------------------------------


@dataclass
class Attack:
    """One of an NPC's attacks, on the encounter's clock (in steps)."""

    n: int                      # its number among the NPC's attacks (1-based, as in Lua)
    info: dict
    period: int
    warn: int
    land: int                   # the step it lands on
    angle: float | None = None  # drawn when it's announced
    target: str | None = None


@dataclass
class Npc:
    nid: str
    info: dict
    join: int                                   # the step it joined on
    attacks: list[Attack] = field(default_factory=list)
    boss: b.Boss | None = None


@dataclass
class Player:
    pid: str
    info: dict
    join: int                                   # its dot's first step comes after this one
    dot: b.Dot
    gear: dict = field(default_factory=dict)    # slot: gear info (effect, kick…)
    keys: int = 0
    seq: int = 0
    acts: list = field(default_factory=list)    # waiting for the next step
    flee: str | None = None
    # The last REWIND_STEPS steps: [global step, snapshot before it, keys, acts, blows, what it reported].
    history: deque = field(default_factory=lambda: deque(maxlen=REWIND_STEPS))
    scratch: b.Dot | None = None                # a dot to replay on


def steps_since(start_ms: float, ms: float) -> int:
    return math.floor((ms - start_ms) * b.HZ / 1000)


class Owner:
    """Runs one encounter, on the server that owns it."""

    def __init__(self, host: "EncounterHost", eid: str):
        self.host = host
        self.world: World = host.world
        self.id = eid
        self.inbox: list[dict] = []
        self.players: dict[str, Player] = {}
        self.npcs: dict[str, Npc] = {}
        self.opened: set[str] = set()
        self.step = 0
        self.ended = False
        self.need_sync = True
        self.rules = b.Rules()
        self.start_ms = 0
        self.lead_ms = 1000
        self.hz = 30
        self.seed = eid
        self.rng = random.Random()
        self.late: list = []    # consequences of a rewind, to carry out with the next tick's
        self.remote = True      # whether sessions on other servers follow it (see _publish)
        self.probed = 0.0

    # Messages ------------------------------------------------------------------------------

    def receive(self, data: str) -> None:
        """An input from a session on this server, without going through Redis."""
        self._receive(data)

    def _receive(self, data: str) -> None:
        try:
            message = json.loads(data)
        except ValueError:
            return
        if isinstance(message, dict):
            self.inbox.append(message)

    def _take_inbox(self) -> None:
        inbox, self.inbox = self.inbox, []
        for m in inbox:
            op = m.get("op")
            if op == "end":
                self.ended = True
            elif op == "sync":
                self.need_sync = True
            else:
                self._input(m)

    def _input(self, m: dict) -> None:
        """A player's input: held keys, and maybe an act (strike, dodge, block,
        unblock, flee)."""
        p = self.players.get(str(m.get("pid", "")))
        if p is None:
            return
        seq = m.get("seq")
        if isinstance(seq, int) and seq > p.seq:
            p.seq = seq
        at = m.get("step") if isinstance(m.get("step"), int) else None
        if isinstance(m.get("keys"), int):
            keys = m["keys"] & 15
            if keys != p.keys and at is not None:
                self._rewind(p, at, keys=keys)
            p.keys = keys
        act = m.get("act")
        done = None
        if act == "strike":
            slot = m.get("slot")
            if isinstance(slot, int) and 1 <= slot <= 3:
                done = ("strike", slot, self._target(p, slot, m.get("target")))
        elif act in ("dodge", "block", "unblock"):
            done = (act,)
        if done and not (at is not None and self._rewind(p, at, act=done)):
            p.acts.append(done)
        elif act == "flee" and isinstance(m.get("dir"), str):
            p.flee = m["dir"][:16]
        elif act == "release":
            p.keys = 0
            p.acts.append(("unblock",))

    def _rewind(self, p: Player, at: int, keys: int | None = None, act: tuple | None = None) -> bool:
        """Something the client did at step `at`, which the owner has already
        run: replays the dot from there (or as far back as it may) with it.
        When nothing in between has gone to Lua (no blow landed, nothing
        reported), the replay replaces the dot outright, and what it does
        (a strike) is reported now. Otherwise only steering is replayed, and
        only where the dot is (REWOUND); an act then waits for the next step
        (returns False)."""
        if not p.history or at > p.history[-1][0]:
            return False
        entries = [e for e in p.history if e[0] >= at]
        clean = all(not e[4] and not e[5] for e in entries)
        if act is not None and not clean:
            return False
        scratch = p.scratch
        b.restore(scratch, entries[0][1])
        reported = []
        for i, e in enumerate(entries):
            e[1] = b.snapshot(scratch)
            if keys is not None:
                e[2] = keys
            if i == 0 and act is not None:
                e[3] = [*e[3], act]
            events = b.step(scratch, e[2], e[3], e[4])
            if clean:  # (no blows in it, so nothing to match up)
                e[5] = self._reportable(p, events, [])
                reported += e[5]
        if clean:
            b.restore(p.dot, b.snapshot(scratch))
            self.late.extend(reported)
        else:
            for name in REWOUND:
                setattr(p.dot, name, getattr(scratch, name))
        return True

    def _reportable(self, p: Player, events: list, mine: list) -> list:
        """The consequences of a dot's step, as calls: strikes, blows (with
        the NPC attacks that made them, `mine`), refusals."""
        calls, k = [], 0
        for e in events:
            if e["type"] == "strike":
                calls.append(("strike", p.pid, e))
            elif e["type"] == "blow":
                nid, an, _ = mine[k]
                k += 1
                calls.append(("blow", nid, an, p.pid, e["result"]))
                if e["result"] == "perfect_block" and nid in self.npcs and self.npcs[nid].boss:
                    calls.append(("poise", nid, None))
            elif e["type"] == "refused":
                calls.append(("refused", p.pid, {k2: e[k2] for k2 in ("act", "reason", "slot") if k2 in e}))
        return calls

    def _target(self, p: Player, slot: int, target) -> str:
        """Who a strike is aimed at: an entity id, a word naming an NPC in the
        fight, or (for damage gear, with nothing named) the first NPC in it."""
        gear = p.gear.get(slot) or {}
        if isinstance(target, str) and target.startswith(("npc:", "pc:")):
            return target[:100]
        if isinstance(target, str) and target.strip():
            word = target.strip().lower()
            for npc in self.npcs.values():
                words = f" {npc.info['name'].lower()} {npc.info.get('keywords', '')} "
                if word == npc.nid or f" {word} " in words:
                    return "npc:" + npc.nid
        if gear.get("effect") in ("heal", "guard"):
            return ""
        first = min(self.npcs.values(), key=lambda n: n.join, default=None)
        return "npc:" + first.nid if first else ""

    # Membership ---------------------------------------------------------------------------

    async def _sync(self) -> bool:
        """Brings the encounter's membership up to date. False if it's over."""
        self.need_sync = False
        raw = await self.world.redis.fcall("encounter_info", 0, self.id)
        if not raw:
            return False
        info = json.loads(raw)
        if not self.start_ms:
            self.start_ms = info["start_ms"]
            self.lead_ms = info["lead_ms"]
            self.hz = max(1, int(info.get("hz") or 30))
            self.seed = info["seed"]
            self.rules = b.Rules.from_seed(info["rules"])
        here = {p["pid"] for p in info["players"]}
        for pid in list(self.players):
            if pid not in here:
                del self.players[pid]
        for p in info["players"]:
            if p["pid"] not in self.players:
                self._add_player(p, info.get("opening", {}).get(p["pid"]))
        there = {n["nid"] for n in info["npcs"]}
        for nid in list(self.npcs):
            if nid not in there:
                self._drop_npc(nid)
        for n in info["npcs"]:
            if n["nid"] not in self.npcs:
                self._add_npc(n)
        return True

    def _add_player(self, p: dict, opening: dict | None) -> None:
        stats = p.get("stats") or {}
        rules = self.rules.for_player(poise=stats.get("poise", 0), focus=stats.get("focus", 0), resilience=stats.get("resilience", 0))
        slots = {int(n): b.Gear.from_dict(g) for n, g in (p.get("slots") or {}).items()}
        join = steps_since(self.start_ms, p["join_ms"] + self.lead_ms)
        dot = b.make_dot(rules, self.seed, p["pid"], slots, bool(p.get("shield")))
        player = Player(p["pid"], p, join, dot, {int(n): g for n, g in (p.get("slots") or {}).items()})
        player.scratch = b.make_dot(rules, self.seed, p["pid"], slots, bool(p.get("shield")))
        if opening and p["pid"] not in self.opened:
            self.opened.add(p["pid"])
            player.acts.append(("strike", int(opening["slot"]), opening.get("target") or ""))
        self.players[p["pid"]] = player

    def _add_npc(self, n: dict) -> None:
        join = steps_since(self.start_ms, n["join_ms"])
        npc = Npc(n["nid"], n, join)
        for i, a in enumerate(n.get("attacks") or [], start=1):
            period = max(1, b.steps(a.get("period") or 6000))
            warn = b.steps(a.get("warn") or self.rules.warn_ms)
            npc.attacks.append(Attack(i, a, period, min(warn, period), join + period))
        if n.get("poise"):
            npc.boss = b.Boss(float(n["poise"]), self.rules)
        self.npcs[n["nid"]] = npc

    def _drop_npc(self, nid: str) -> None:
        self.npcs.pop(nid, None)
        for p in self.players.values():
            b.cancel_volleys(p.dot, "npc:" + nid)

    # The clock ---------------------------------------------------------------------------

    def _first_player(self) -> Player | None:
        return min(self.players.values(), key=lambda p: (p.info.get("join_ms", 0), p.pid), default=None)

    def _run_step(self, n: int, calls: list) -> None:
        """Global step n: blows announced and landing, every active dot, the bosses."""
        blows: dict[str, list] = defaultdict(list)
        for npc in self.npcs.values():
            for a in npc.attacks:
                if a.angle is None and n >= a.land - a.warn:
                    first = self._first_player()
                    a.target = first.pid if first else None
                    a.angle = self.rng.random() * b.TAU
                if n >= a.land:
                    target = a.target if a.target in self.players else (self._first_player().pid if self.players else None)
                    if target is not None:
                        info = a.info
                        blow = b.Blow(kick=float(info.get("kick") or 0), angle=a.angle or 0.0, defend=info.get("defend") or "both",
                                      stagger=bool(info.get("stagger")), debuff=info.get("debuff") or None)
                        blows[target].append((npc.nid, a.n, blow))
                    a.land += a.period
                    a.angle = a.target = None
        for p in list(self.players.values()):
            if n <= p.join:
                if blows.get(p.pid):  # not on their feet yet: it just lands
                    for nid, an, _ in blows[p.pid]:
                        calls.append(("blow", nid, an, p.pid, "hit"))
                continue
            if p.flee is not None:
                direction, p.flee = p.flee, None
                if p.dot.staggered or p.dot.dist > p.dot.rules.core:
                    calls.append(("refused", p.pid, {"act": "flee", "reason": "not_steady"}))
                else:
                    calls.append(("flee", p.pid, direction))
            acts, p.acts = p.acts, []
            mine = blows.get(p.pid, [])
            landing = [x[2] for x in mine]
            entry = [n, b.snapshot(p.dot), p.keys, acts, landing, []]
            p.history.append(entry)
            entry[5] = self._reportable(p, b.step(p.dot, p.keys, acts, landing), mine)
            calls += entry[5]
        for npc in self.npcs.values():
            if npc.boss:
                was = npc.boss.staggered
                npc.boss.step()
                if was and not npc.boss.staggered:
                    calls.append(("note", npc.nid, "steadies"))

    def _boss_reels(self, npc: Npc) -> None:
        """A boss's meter filled: its attacks due while it reels wait for the end."""
        end = self.step + npc.boss.staggered
        for a in npc.attacks:
            if a.land < end:
                a.land = end
                a.angle = a.target = None

    async def _call(self, call: tuple) -> None:
        """Carries out one consequence, in Lua, and whatever follows from it."""
        kind = call[0]
        w = self.world
        if kind == "strike":
            _, pid, e = call
            p = self.players.get(pid)
            if p is None:
                return
            target = e["target"] or ""
            gear = p.gear.get(e["slot"]) or {}
            npc = self.npcs.get(target[4:]) if target.startswith("npc:") else None
            mult = npc.boss.damage_mult if npc and npc.boss else 1
            result = json.loads(await w.call("encounter_strike", self.id, pid, target, e["slot"], e["tier"],
                                              e["hit"], e["hits"], mult))
            if result.get("gone"):
                b.cancel_volleys(p.dot, target)
                await self._publish({"type": "refused", "pid": pid, "act": "strike", "slot": e["slot"], "reason": "gone"})
                return
            if result.get("killed") and npc:
                self._drop_npc(npc.nid)
                return
            if npc and result.get("stagger_ms"):
                for a in npc.attacks:
                    a.land += b.steps(result["stagger_ms"])
            if npc and npc.boss and gear.get("effect") == "damage" and npc.boss.strike(float(gear.get("kick") or 0)):
                self._boss_reels(npc)
                await w.call("encounter_note", self.id, npc.nid, "reels")
        elif kind == "blow":
            _, nid, n, pid, how = call
            if pid not in self.players or nid not in self.npcs:
                return
            result = json.loads(await w.call("encounter_blow", self.id, nid, n, pid, how))
            if result.get("dead"):
                self.players.pop(pid, None)
        elif kind == "poise":
            npc = self.npcs.get(call[1])
            if npc and npc.boss and npc.boss.perfect_block():
                self._boss_reels(npc)
                await w.call("encounter_note", self.id, npc.nid, "reels")
        elif kind == "note":
            await w.call("encounter_note", self.id, call[1], call[2])
        elif kind == "flee":
            _, pid, direction = call
            result = json.loads(await w.call("encounter_flee", self.id, pid, direction))
            if result.get("fled") or result.get("dead"):
                self.players.pop(pid, None)
            elif result.get("refused"):
                await self._publish({"type": "refused", "pid": pid, "act": "flee", "reason": result["refused"]})
        elif kind == "refused":
            _, pid, detail = call
            await self._publish({"type": "refused", "pid": pid, **detail})

    # State ---------------------------------------------------------------------------------

    def state(self) -> dict:
        players = {}
        for p in self.players.values():
            # Each dot as it was at the start of its rewind window: a late input
            # can still change anything after that, but nothing before it. The
            # client replays its own inputs (and the blows it knows of) from there.
            if p.history:
                oldest = p.history[0]
                snap = dict(oldest[1], keys=oldest[2])
            else:
                snap = dict(b.snapshot(p.dot), keys=p.keys)
            snap.update(seq=p.seq, join=p.join)
            players[p.pid] = snap
        blows = []
        for npc in self.npcs.values():
            for a in npc.attacks:
                if a.angle is not None:
                    blows.append({"nid": npc.nid, "n": a.n, "pid": a.target, "land": a.land, "warn": a.warn, "angle": a.angle,
                                  "kick": a.info.get("kick") or 0, "name": a.info.get("name"), "defend": a.info.get("defend") or "both",
                                  "stagger": bool(a.info.get("stagger")), "debuff": a.info.get("debuff") or None})
        bosses = {npc.nid: {"meter": round(npc.boss.meter, 2), "poise": npc.boss.poise, "staggered": npc.boss.staggered}
                  for npc in self.npcs.values() if npc.boss}
        return {"type": "state", "id": self.id, "step": self.step, "players": players, "blows": blows, "bosses": bosses}

    async def _publish(self, message: dict) -> None:
        """To every session following this encounter: those on this server
        directly, and through Redis only while someone elsewhere listens
        (checked once a second, by how many a publish reached)."""
        data = json.dumps(message, separators=(",", ":"))
        for handler in list(self.host.local.get(self.id, ())):
            handler(data)
        now = time.monotonic()
        if self.remote or now - self.probed >= 1:
            self.probed = now
            self.remote = await self.world.redis.publish(f"enc:{self.id}:out", data) > 0

    # The loop ------------------------------------------------------------------------------

    async def run(self) -> None:
        channel = f"enc:{self.id}:in"
        await self.host.bus.subscribe(channel, self._receive)
        try:
            await self._loop()
        except asyncio.CancelledError:
            raise
        except Exception:
            log.exception("encounter %s failed", self.id)
        finally:
            await self.host.bus.unsubscribe(channel, self._receive)

    async def _loop(self) -> None:
        if not await self._sync():
            return
        tick = 1 / self.hz
        per_state = max(1, math.ceil(self.hz / STATE_HZ))  # at most STATE_HZ a second
        ticks, last_lease = 0, 0.0
        while True:
            started = time.monotonic()
            self._take_inbox()
            if self.ended:
                return
            if self.need_sync and not await self._sync():
                return
            if started - last_lease >= 1:
                last_lease = started
                ok = await self.world.redis.set(f"ENC:{self.id}:lease", self.host.server_id, xx=True, px=LEASE_MS)
                if not ok:
                    return
            target = steps_since(self.start_ms, self.host.now_ms())
            calls, self.late = self.late, []
            ran = 0
            while self.step < target and ran < MAX_CATCH_UP:
                self.step += 1
                ran += 1
                self._run_step(self.step, calls)
            if ran >= MAX_CATCH_UP:
                self.step = target  # too far behind: skip ahead rather than run slow for ever
            for call in calls:
                if self.ended:
                    break
                await self._call(call)
            ticks += 1
            if ticks % per_state == 0 and self.players:
                await self._publish(self.state())
            await asyncio.sleep(max(0, tick - (time.monotonic() - started)))


class EncounterHost:
    """A server's part in encounters: it runs the ones it owns, and ends any
    whose owner has gone away."""

    def __init__(self, world: World, server_id: str, now_ms: Callable[[], float]):
        self.world = world
        self.server_id = server_id
        self.now_ms = now_ms
        self.bus = Bus(world.redis)
        self.owners: dict[str, asyncio.Task] = {}
        self.running: dict[str, Owner] = {}
        # Sessions on this server following encounters it owns: eid -> handlers.
        self.local: dict[str, set[Callable[[str], None]]] = defaultdict(set)
        self.tasks: list[asyncio.Task] = []

    async def start(self) -> None:
        await self.bus.start(self.server_id)
        self.tasks = [asyncio.create_task(self._discover()), asyncio.create_task(self._leases())]

    async def close(self) -> None:
        for task in [*self.tasks, *self.owners.values()]:
            task.cancel()
        await self.bus.close()

    def adopt(self, eid: str) -> None:
        """Starts running an encounter this server owns."""
        if eid in self.owners:
            return
        owner = Owner(self, eid)
        task = asyncio.create_task(owner.run())
        self.owners[eid] = task
        self.running[eid] = owner

        def done(_task, eid=eid):
            self.owners.pop(eid, None)
            self.running.pop(eid, None)
        task.add_done_callback(done)

    def is_local(self, owner: str | None) -> bool:
        return owner == self.server_id

    async def follow(self, eid: str, owner: str | None, handler: Callable[[str], None]) -> None:
        """A session starts forwarding an encounter's state: directly if this
        server owns it, else through Redis."""
        if self.is_local(owner):
            self.local[eid].add(handler)
        else:
            await self.bus.subscribe(f"enc:{eid}:out", handler)

    async def unfollow(self, eid: str, owner: str | None, handler: Callable[[str], None]) -> None:
        if self.is_local(owner):
            handlers = self.local.get(eid)
            if handlers is not None:
                handlers.discard(handler)
                if not handlers:
                    del self.local[eid]
        else:
            await self.bus.unsubscribe(f"enc:{eid}:out", handler)

    async def send_input(self, eid: str, owner: str | None, data: str) -> None:
        """A session's input, to the encounter's owner: directly if it's here."""
        running = self.running.get(eid) if self.is_local(owner) else None
        if running is not None:
            running.receive(data)
        else:
            await self.world.redis.publish(f"enc:{eid}:in", data)

    async def _discover(self) -> None:
        """Watches for new encounters, and runs the ones this server owns."""
        last = "$"
        while True:
            try:
                reply = await self.world.redis.xread({NEW_ENCOUNTERS: last}, block=1000)
                for _stream, entries in reply or ():
                    for entry_id, fields in entries:
                        last = entry_id
                        if fields.get("owner") == self.server_id:
                            self.adopt(fields["id"])
            except asyncio.CancelledError:
                raise
            except Exception:
                log.exception("watching for new encounters failed")
                await asyncio.sleep(1)

    async def check_leases(self) -> int:
        """Ends every encounter whose owner has stopped renewing its lease."""
        ended = 0
        for eid in await self.world.redis.smembers("alz:encounters"):
            if eid in self.owners:
                continue
            if not await self.world.redis.exists(f"ENC:{eid}:lease"):
                if await self.world.call("encounter_end", eid, "lost"):
                    log.info("encounter %s lost its owner; ended it", eid)
                    ended += 1
        return ended

    async def _leases(self) -> None:
        while True:
            await asyncio.sleep(1)
            try:
                await self.check_leases()
            except asyncio.CancelledError:
                raise
            except Exception:
                log.exception("checking encounter leases failed")
