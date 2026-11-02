"""The balance bot (docs/combat-redesign.md, Tuning): plays fights with
alzendor/balance.py and no server, and reports how long they take and who
wins, against the tuning targets.

    python -m tools.balance_bot                    # every fighting NPC, 20 fights each
    python -m tools.balance_bot --npc orc-1 -n 5   # one NPC, 5 fights
    python -m tools.balance_bot --rooms            # rooms of three or more enemies, all at once
    python -m tools.balance_bot --scale 1.3        # with another balance_damage_scale

Two players:

- ideal: steers to the centre knowing exactly where the well is pulling,
  strikes from the perfect circle, and dodges or (with a shield) perfectly
  blocks every blow it can;
- sloppy: sees its dot 250 ms late, steers with noise, strikes when it looks
  clean, and dodges and blocks roughly in time, never perfectly.

For each fighting NPC it plays a character of the NPC's zone level (stat
points spread evenly) with each class's starting loadout and the class
talents available by that level. A fight works as an encounter does: blows
land one period after the start and every period after, on the first player;
damage, armour, blocks and staggers as alzendor.lua has them. The weather is
neutral, and bleed and passives are left out.

Targets (the "Tuning" table): an ordinary NPC, solo, the ideal player kills
in 20-40 s and the sloppy one beats at least 80% of the time; a boss under
1000 health the ideal player beats in 2-4 minutes (the sloppy one may lose);
a boss of 1000 or more, three ideal players beat in 2-4 minutes; a room of
three or more enemies at once, the sloppy player beats at least 60% of the
time.
"""

from __future__ import annotations

import argparse
import json
import math
import random
import statistics
from collections import defaultdict
from concurrent.futures import ProcessPoolExecutor
from dataclasses import dataclass, field
from pathlib import Path

from alzendor import balance as b
from alzendor.world import load_seed

SEED = Path(__file__).parent.parent / "world" / "seed.json"
STATS = ("vigor", "poise", "focus", "presence", "resilience")
BASE_HP, VIGOR_HP = 100, 8   # as in alzendor.lua
LEAD = b.steps(1000)
REACTION = b.steps(250)      # the sloppy player's

# Each zone's level (docs/zones.md), by the file its NPCs are in; the seed's
# by region (starting realms 2, Harrowgate 3, the Spiderwood 4, the realms
# beyond the rift 8).
ZONE_LEVELS = {
    "greyfold": 4, "sallow_fen": 5, "cindercrag": 6, "gallows_moor": 7, "sunken_abbey": 8, "deepwood": 9,
    "cold_spine": 10, "underdeep": 11, "emberwaste": 12, "rotwood": 13, "hollowcrown": 14,
    "mirefall": 10, "ember_courts": 11, "hollowmoon": 12, "gyre": 13, "overgrowth": 14, "brassmarch": 15,
    "pale_deep": 16, "gloaming": 17, "bone_steppe": 18, "starfall": 19, "tempest_throne": 20,
}
SEED_REGION_LEVELS = {"harrowgate": 3, "harrowlake": 3, "skerries": 3, "spiderwood": 4, "frostfell": 8, "glass_flats": 8}
TOO_STRONG = 2000  # an ordinary NPC with this much health is one to sneak past, not to fight


# The world -----------------------------------------------------------------------------------


@dataclass
class World:
    data: dict
    rules: b.Rules
    levels: dict           # nid: level
    sources: dict          # nid: zone file
    rewards: list          # (zone level, gear or wearable id): what quests give and NPCs drop, zone by zone

    @classmethod
    def load(cls, scale: float | None = None) -> "World":
        data = load_seed(SEED)
        raw = dict(data.get("rules", {}))
        if scale is not None:
            raw["balance_damage_scale"] = scale
        sources, rewards = {}, []
        for path in [SEED, *sorted((SEED.parent / "zones").glob("*.json"))]:
            zone = json.loads(path.read_text(encoding="utf-8"))
            level = ZONE_LEVELS.get(path.stem, 2)
            for nid, npc in zone.get("npcs", {}).items():
                sources[nid] = path.stem
                rewards += [(level, g) for g in npc.get("drops", [])]
            for quest in zone.get("quests", {}).values():
                for step in quest["steps"].values():
                    rewards += [(level, e["give"]) for e in step.get("effects", []) if "give" in e]
        levels = {}
        for nid, npc in data["npcs"].items():
            if sources.get(nid) == "seed" and npc.get("room"):
                region = data["areas"][data["rooms"][npc["room"]]["area"]]["region"]
                levels[nid] = SEED_REGION_LEVELS.get(region, 2)
            else:
                levels[nid] = ZONE_LEVELS.get(sources.get(nid, ""), 10)
        return cls(data, b.Rules.from_seed(raw), levels, sources, rewards)

    def fighters(self) -> list[str]:
        """Every NPC there is to fight: with attacks, placed, mortal, and not one to sneak past."""
        out = []
        for nid, npc in sorted(self.data["npcs"].items()):
            if not npc.get("attacks") or npc.get("template") or npc.get("immortal") or not npc.get("room"):
                continue
            if not self.is_boss(nid) and npc.get("max_hp", 10) >= TOO_STRONG:
                continue
            out.append(nid)
        return out

    def is_boss(self, nid: str) -> bool:
        npc = self.data["npcs"][nid]
        return float(npc.get("respawn") or 300) >= 900

    def rooms(self) -> list[list[str]]:
        """Rooms of three or more hostile fighters."""
        by_room = defaultdict(list)
        for nid in self.fighters():
            npc = self.data["npcs"][nid]
            if npc.get("disposition") == "hostile":
                by_room[npc["room"]].append(nid)
        return [nids for _, nids in sorted(by_room.items()) if len(nids) >= 3]


@dataclass
class Character:
    cls: str
    level: int
    stats: dict
    max_hp: int
    armor: int
    shield: float
    slots: dict      # slot: gear dict (with its id)


def character(world: World, cid: str, level: int) -> Character:
    """A character of this class at this level: stat points spread evenly
    over the five stats; the class's outfit, or better armour from the zones
    below this level; and three slots from the starting loadout (the class
    ability and what backgrounds give a class like it), the talents learned
    by that level, and the slot gear the zones below it give, best first."""
    data = world.data
    cls = data["classes"][cid]
    points = level - 1
    stats = {s: points // 5 + (1 if i < points % 5 else 0) for i, s in enumerate(STATS)}
    earned = [g for lv, g in world.rewards if lv < level]
    worn: dict = {}
    for wid in [*cls.get("outfit", []), *(g for g in earned if g in data["wearables"])]:
        w = data["wearables"][wid]
        if cls.get("wears") and w.get("type") not in cls["wears"]:
            continue
        place = w.get("place")
        if place == "hand" and worn.get("hand", {}).get("type") == "shield" and w.get("type") != "shield":
            continue  # a shield stays in hand
        if place not in worn or w.get("armor", 0) >= worn[place].get("armor", 0):
            worn[place] = w
    armor = sum(w.get("armor", 0) for w in worn.values())
    shield = float(worn["hand"].get("block", 1)) if worn.get("hand", {}).get("type") == "shield" else 0.0
    gear = data["gear"]
    pool = [cls["ability"]] + [g for g in earned if g in gear and gear[g].get("kind") in cls.get("kinds", [])]
    for bg in data["backgrounds"].values():
        pool += [g for g in bg.get("items", []) if gear.get(g, {}).get("kind") in cls.get("kinds", [])]
    # Talents: one every third level; rank 2 after two, rank 3 after four.
    talents = [t for t in cls.get("talents", []) if t in gear]
    learned: list[str] = []
    for _ in range(level // 3):
        open_ = [t for t in talents if t not in learned and (gear[t].get("rank", 1) == 1 or
                 (gear[t].get("rank") == 2 and len(learned) >= 2) or (gear[t].get("rank") == 3 and len(learned) >= 4))]
        if not open_:
            break
        learned.append(max(open_, key=lambda t: worth(gear[t])))
    pool = list(dict.fromkeys(pool + learned))
    damage = sorted((g for g in pool if gear[g]["effect"] == "damage"), key=lambda g: -worth(gear[g]))
    mending = sorted((g for g in pool if gear[g]["effect"] in ("heal", "guard")), key=lambda g: -worth(gear[g]))
    # The class ability always (it's what the class is), then the best damage, then a heal or guard.
    chosen = [cls["ability"]] if gear[cls["ability"]]["effect"] == "damage" else []
    chosen += [g for g in damage if g not in chosen][: 2 - len(chosen)]
    chosen += mending[:1]
    chosen += [g for g in damage if g not in chosen][: 3 - len(chosen)]
    slots = {i + 1: {"id": g, **gear[g]} for i, g in enumerate(chosen[:3])}
    return Character(cid, level, stats, BASE_HP + VIGOR_HP * stats["vigor"], armor, shield, slots)


def worth(g: dict) -> float:
    """What gear lands a second, at the clean tier."""
    return g["amounts"][1] / max(0.3, g.get("cooldown", 1000) / 1000)


# The players -------------------------------------------------------------------------------


def gravity(dot: b.Dot) -> tuple[float, float]:
    """The pull of the well on the dot, as balance._physics works it out."""
    r = dot.rules
    reel = min(1.0, dot.fade("reeling"))
    calm = 0.1 if dot.blocking else 1.0
    wx, wy = dot.well_r * math.cos(dot.well_a), dot.well_r * math.sin(dot.well_a)
    gx, gy = wx - dot.x, wy - dot.y
    dg = math.hypot(gx, gy)
    if dg == 0:
        return 0.0, 0.0
    g = r.gravity * (1 + 0.6 * reel) * calm
    if dg < r.gravity_falloff:
        g = g * dg / r.gravity_falloff
    return g * gx / dg, g * gy / dg


MASKS = [(0, 0.0, 0.0)] + [
    (mask, dx / math.hypot(dx, dy), dy / math.hypot(dx, dy))
    for mask, dx, dy in [(b.RIGHT, 1, 0), (b.LEFT, -1, 0), (b.DOWN, 0, 1), (b.UP, 0, -1),
                         (b.RIGHT | b.DOWN, 1, 1), (b.RIGHT | b.UP, 1, -1), (b.LEFT | b.DOWN, -1, 1), (b.LEFT | b.UP, -1, -1)]
]


def steer(x: float, y: float, vx: float, vy: float, g: tuple[float, float], push: float, kp: float, kd: float) -> int:
    """The keys whose push comes closest to what would bring the dot to the centre."""
    ax, ay = -kp * x - kd * vx - g[0], -kp * y - kd * vy - g[1]
    best, best_err = 0, float("inf")
    for mask, dx, dy in MASKS:
        err = (ax - push * dx) ** 2 + (ay - push * dy) ** 2
        if err < best_err:
            best, best_err = mask, err
    return best


@dataclass
class Player:
    me: Character
    style: str
    dot: b.Dot
    hp: int
    rng: random.Random
    ready_since: dict = field(default_factory=dict)
    seen: list = field(default_factory=list)       # the sloppy player's view of its dot: (x, y, vx, vy) by step
    noise: int = 0
    noise_keys: int = 0
    plans: dict = field(default_factory=dict)      # step: acts planned for it
    seen_blows: set = field(default_factory=set)   # blows already planned for
    staggers: int = 0

    @property
    def alive(self) -> bool:
        return self.hp > 0

    def push(self) -> float:
        dot = self.dot
        heavy = dot.debuffs.get("heavy")
        weigh = 1 + (heavy[0] * heavy[1] / heavy[2] if heavy else 0.0)
        return dot.rules.push * (1.5 if "steady" in dot.debuffs else 1.0) / weigh

    def keys(self) -> int:
        d = self.dot
        if self.style == "ideal":
            return steer(d.x, d.y, d.vx, d.vy, gravity(d), self.push(), 40, 9)
        self.seen.append((d.x, d.y, d.vx, d.vy))
        if len(self.seen) > REACTION:
            self.seen.pop(0)
        if self.noise > 0:
            self.noise -= 1
            return self.noise_keys
        if self.rng.random() < 0.03:
            self.noise, self.noise_keys = 8, self.rng.choice(MASKS)[0]
        x, y, vx, vy = self.seen[0]
        return steer(x, y, vx, vy, (0.0, 0.0), self.push(), 25, 4)

    def strike(self, n: int, foe: str) -> tuple | None:
        """The slot to strike with now, if any."""
        d = self.dot
        if d.staggered or d.blocking or d.pending:
            return None
        x, y = (d.x, d.y) if self.style == "ideal" else self.seen[0][:2]
        dist = math.hypot(x, y)
        hurt = self.hp < self.me.max_hp / 2
        best, best_worth = None, 0.0
        for slot, g in self.me.slots.items():
            if d.cool.get(slot, 0) > 0:
                self.ready_since.pop(slot, None)
                continue
            self.ready_since.setdefault(slot, n)
            if g["effect"] in ("heal", "guard") and not hurt:
                continue
            w = worth(g) * (3 if g["effect"] != "damage" else 1)
            if w > best_worth:
                best, best_worth = slot, w
        if best is None:
            return None
        waited = n - self.ready_since[best]
        if self.style == "ideal":
            ok = dist <= d.rules.perfect_r or (waited > 30 and dist <= d.rules.clean_r)
        else:
            ok = dist <= d.rules.clean_r
        if not ok:
            return None
        target = "" if self.me.slots[best]["effect"] != "damage" else foe
        return ("strike", best, target)

    def defend(self, n: int, blows: list) -> list:
        """Acts for this step against the blows coming at it: (land step, blow)."""
        d, acts = self.dot, []
        for step, acts_then in list(self.plans.items()):
            if step == n:
                acts += acts_then
                del self.plans[step]
        for land, blow, key in blows:
            if key in self.seen_blows:
                continue
            self.seen_blows.add(key)
            can_block = self.me.shield > 0 and blow.defend in ("both", "block")
            can_dodge = blow.defend in ("both", "dodge")
            if self.style == "ideal":
                if can_block:
                    self.plans.setdefault(land - 2, []).append(("block",))
                    self.plans.setdefault(land + 2, []).append(("unblock",))
                elif can_dodge:
                    self.plans.setdefault(land - 3, []).append(("dodge",))
            else:
                if can_block:
                    early = self.rng.randint(8, 40)  # never within the perfect window
                    self.plans.setdefault(land - early, []).append(("block",))
                    self.plans.setdefault(land + 10, []).append(("unblock",))
                elif can_dodge and self.rng.random() < 0.85:
                    self.plans.setdefault(land - self.rng.randint(-10, 30), []).append(("dodge",))
        return acts


# A fight ----------------------------------------------------------------------------------


@dataclass
class Result:
    won: bool
    seconds: float
    deaths: int
    staggers: int


def fight(world: World, chars: list[Character], styles: list[str], nids: list[str], seed: int,
          limit_s: float = 360) -> Result:
    """Plays one fight to the end (or the time limit, which is a loss)."""
    rng = random.Random(seed)
    data, rules = world.data, world.rules
    players = []
    for i, (c, style) in enumerate(zip(chars, styles)):
        prules = rules.for_player(poise=c.stats["poise"], focus=c.stats["focus"], resilience=c.stats["resilience"])
        slots = {n: b.Gear.from_dict(g) for n, g in c.slots.items()}
        dot = b.make_dot(prules, f"bot-{seed}", f"p{i}", slots, c.shield > 0)
        players.append(Player(c, style, dot, c.max_hp, random.Random(seed * 31 + i)))
    foes = []
    for nid in nids:
        npc = data["npcs"][nid]
        attacks = [{"a": a, "period": max(1, b.steps(a["period"])), "warn": b.steps(a.get("warn") or rules.warn_ms),
                    "land": b.steps(a["period"]), "angle": None} for a in npc["attacks"]]
        boss = b.Boss(float(npc["poise"]), rules) if npc.get("poise") else None
        foes.append({"nid": nid, "hp": npc.get("max_hp", 10), "attacks": attacks, "boss": boss})
    staggers = 0
    for n in range(1, b.steps(limit_s * 1000) + 1):
        alive = [p for p in players if p.alive]
        living = [f for f in foes if f["hp"] > 0]
        if not alive or not living:
            return Result(bool(alive), n / b.HZ, len(players) - len(alive), staggers)
        first = alive[0]
        landing: dict[int, list] = defaultdict(list)
        coming: dict[int, list] = defaultdict(list)
        for f in living:
            for at in f["attacks"]:
                if at["angle"] is None and n >= at["land"] - at["warn"]:
                    at["angle"] = rng.random() * b.TAU
                a = at["a"]
                blow = b.Blow(kick=float(a.get("kick", 0)), angle=at["angle"] or 0.0, defend=a.get("defend", "both"),
                              stagger=bool(a.get("stagger")), debuff=a.get("debuff"))
                if at["angle"] is not None:
                    coming[0].append((at["land"], blow, at))
                if n >= at["land"]:
                    landing[0].append((f, a, blow))
                    at["land"] += at["period"]
                    at["angle"] = None
        for p in alive:
            if n <= LEAD:  # still finding their feet: blows just land
                for f, a, blow in (landing[0] if p is first else []):
                    p.hp -= damage_taken(p, a, "hit", rules)
                continue
            foe = "npc:" + living[0]["nid"]
            acts = p.defend(n, [(land, blow, (id(at), land)) for land, blow, at in coming[0]] if p is first else [])
            keys = p.keys()
            chosen = p.strike(n, foe)
            if chosen:
                acts.append(chosen)
            mine = landing[0] if p is first else []
            events = b.step(p.dot, keys, acts, [x[2] for x in mine])
            k = 0
            for e in events:
                if e["type"] == "stagger":
                    staggers += 1
                elif e["type"] == "blow":
                    f, a, _ = mine[k]
                    k += 1
                    p.hp -= damage_taken(p, a, e["result"], rules)
                    if e["result"] == "perfect_block" and f["boss"] and f["boss"].perfect_block():
                        reels(f, n)
                elif e["type"] == "strike":
                    g = p.me.slots[e["slot"]]
                    amount = g["amounts"][e["tier"]] * rules.damage_scale
                    if g["effect"] == "damage":
                        target = next((f for f in living if "npc:" + f["nid"] == e["target"]), None) or living[0]
                        mult = target["boss"].damage_mult if target["boss"] else 1
                        target["hp"] -= max(1, math.ceil(amount * mult / e["hits"] - 1e-9))
                        if g.get("stagger_ms"):
                            for at in target["attacks"]:
                                at["land"] += b.steps(g["stagger_ms"])
                        if target["boss"] and target["boss"].strike(float(g.get("kick", 0))):
                            reels(target, n)
                    elif g["effect"] == "heal":
                        p.hp = min(p.me.max_hp, p.hp + max(1, math.ceil(amount - 1e-9)))
                    # (a guard: modelled as a heal of half as much, spread over the blows it soaks)
                    else:
                        p.hp = min(p.me.max_hp, p.hp + max(1, math.ceil(amount / 2 - 1e-9)))
        for f in living:
            if f["boss"]:
                f["boss"].step()
    return Result(False, limit_s, sum(1 for p in players if not p.alive), staggers)


def reels(foe: dict, n: int) -> None:
    end = n + foe["boss"].staggered
    for at in foe["attacks"]:
        if at["land"] < end:
            at["land"], at["angle"] = end, None


def damage_taken(p: Player, a: dict, how: str, rules: b.Rules) -> int:
    """A blow's damage, as encounter_blow works it out (no guard)."""
    dmg = a["damage"]
    if how in ("dodge", "perfect_block"):
        return 0
    if how == "block":
        dmg -= min(dmg, round(dmg * min(1, rules.block_cut * p.me.shield)))
    dmg -= min(dmg, round(dmg * p.me.armor / (p.me.armor + 30)))
    if how == "staggered":
        dmg = round(dmg * rules.stagger_dmg)
    return dmg


# Judging ----------------------------------------------------------------------------------


@dataclass
class Verdict:
    name: str
    kind: str          # ordinary, boss, big boss, room
    level: int
    ideal_seconds: float | None
    ideal_wins: float
    sloppy_wins: float
    staggers: float
    ok: bool
    why: str


def judge(world: World, nids: list[str], fights: int, seed: int = 1) -> Verdict:
    """Plays an NPC (or a room of them) with every class and judges it against its target."""
    data = world.data
    level = max(world.levels[n] for n in nids)
    room = len(nids) > 1
    boss = not room and world.is_boss(nids[0])
    big = boss and data["npcs"][nids[0]].get("max_hp", 10) >= 1000
    kind = "room" if room else "big boss" if big else "boss" if boss else "ordinary"
    times, ideal_wins, sloppy_wins, staggers, played = [], 0, 0, 0, 0
    for cid in sorted(data["classes"]):
        c = character(world, cid, level)
        for i in range(fights):
            s = seed * 1000 + i
            party = [c, c, c] if big else [c]
            r = fight(world, party, ["ideal"] * len(party), nids, s, limit_s=360 if boss else 180)
            played += 1
            ideal_wins += r.won
            staggers += r.staggers
            if r.won:
                times.append(r.seconds)
            if not big:
                sloppy_wins += fight(world, [c], ["sloppy"], nids, s + 500, limit_s=360 if boss else 180).won
    median = statistics.median(times) if times else None
    iw, sw = ideal_wins / played, sloppy_wins / played
    if kind == "ordinary":
        ok = median is not None and 20 <= median <= 40 and sw >= 0.8 and iw == 1
        why = f"ideal {fmt(median)} (20-40 s), sloppy wins {sw:.0%} (80%)"
    elif kind == "room":
        ok = sw >= 0.6
        why = f"sloppy wins {sw:.0%} (60%)"
    else:
        ok = median is not None and 120 <= median <= 240 and iw >= 0.9
        why = f"{'three ' if big else ''}ideal {fmt(median)} (2-4 min), wins {iw:.0%}"
    name = nids[0] if not room else f"{data['npcs'][nids[0]]['room']} ({len(nids)})"
    return Verdict(name, kind, level, median, iw, sw, staggers / played, ok, why)


def fmt(seconds: float | None) -> str:
    return "never" if seconds is None else f"{seconds:.0f} s"


def _judge(args):
    scale, nids, fights = args
    return judge(World.load(scale), nids, fights)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--npc", action="append", help="just these NPCs")
    parser.add_argument("--rooms", action="store_true", help="rooms of three or more enemies, all at once")
    parser.add_argument("-n", "--fights", type=int, default=20)
    parser.add_argument("--scale", type=float, help="balance_damage_scale to try")
    parser.add_argument("--json", help="write the verdicts here")
    args = parser.parse_args()
    world = World.load(args.scale)
    groups = [[n] for n in (args.npc or world.fighters())] if not args.rooms else world.rooms()
    with ProcessPoolExecutor() as pool:
        verdicts = list(pool.map(_judge, [(args.scale, g, args.fights) for g in groups]))
    ok = sum(v.ok for v in verdicts)
    for v in sorted(verdicts, key=lambda v: (v.kind, v.level, v.name)):
        print(f"{'ok ' if v.ok else 'OFF'} {v.kind:9} L{v.level:<2} {v.name:28} {v.why}; {v.staggers:.1f} staggers a fight")
    ordinary = [v.ideal_seconds for v in verdicts if v.kind == "ordinary" and v.ideal_seconds]
    if ordinary:
        print(f"ordinary NPCs: median {statistics.median(ordinary):.0f} s to kill (ideal)")
    print(f"{ok} of {len(verdicts)} on target")
    if args.json:
        Path(args.json).write_text(json.dumps([v.__dict__ for v in verdicts], indent=1))


if __name__ == "__main__":
    main()
