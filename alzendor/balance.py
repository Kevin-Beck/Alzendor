"""Balance: the combat simulation, as pure functions with no I/O.

Each player in a fight keeps a dot inside a circle. An invisible well circles
the ring and pulls the dot; the player leans against it with the steering
keys. They can strike only while the dot is inside the core, and every
strike, blow and dodge knocks it back out. If it touches the rim they stagger.

The simulation runs in fixed 1/60 s steps, in two copies: this one (the
server's, the authority) and the `Balance` block at the top of the script in
web/index.html (the client's prediction). The two must agree to within 1e-6,
which `tests/balance_vectors.json` checks, so any change here is made there
too, with the arithmetic in the same order. Timers are whole steps, and every
step draws exactly four random numbers whatever happens, so the two copies'
random streams stay in step even when their branches differ.

The plan is docs/combat-redesign.md ("The rules in detail").
"""

from __future__ import annotations

import math
from dataclasses import dataclass, field, fields, replace

HZ = 60
DT = 1 / 60
MASK = 0xFFFFFFFF
TAU = 2 * math.pi

# Steering keys, as the `keys` bitmask of an input.
UP, DOWN, LEFT, RIGHT = 1, 2, 4, 8

TIERS = ("edge", "clean", "perfect")


def steps(ms: float) -> int:
    """Milliseconds as whole simulation steps (half rounds up, as in JavaScript)."""
    return math.floor(ms * HZ / 1000 + 0.5)


# Random numbers ---------------------------------------------------------------------------


def imul(a: int, b: int) -> int:
    """32-bit multiplication, as JavaScript's Math.imul (unsigned here)."""
    return (a * b) & MASK


class Rng:
    """mulberry32: a 32-bit generator that's the same in Python and JavaScript."""

    def __init__(self, seed: int):
        self.s = seed & MASK

    def next(self) -> float:
        self.s = (self.s + 0x6D2B79F5) & MASK
        t = self.s
        t = imul(t ^ (t >> 15), t | 1)
        t = ((t + imul(t ^ (t >> 7), t | 61)) & MASK) ^ t
        return ((t ^ (t >> 14)) & MASK) / 4294967296


def fnv1a(text: str) -> int:
    """32-bit FNV-1a of the text's UTF-8 bytes."""
    h = 0x811C9DC5
    for byte in text.encode():
        h = imul(h ^ byte, 0x01000193)
    return h


def seed_for(encounter_seed, pid: str) -> int:
    """Each player's random stream in an encounter: hash(encounter seed, player id)."""
    return fnv1a(f"{encounter_seed}:{pid}")


# Rules ------------------------------------------------------------------------------------


@dataclass(frozen=True)
class Rules:
    """The balance rules (seed.json `rules`, the `balance_*` keys), and for one
    player the radii and debuff lengths their stats give them (`for_player`)."""

    core: float = 0.22
    perfect_r: float = 0.06
    clean_r: float = 0.14
    damping: float = 2.5
    block_damping: float = 10
    push: float = 2.6
    gravity: float = 0.9
    gravity_falloff: float = 0.3
    well_radius: tuple = (0.5, 0.85)
    well_speed: float = 0.3
    warn_ms: float = 1500
    buffer_ms: float = 100
    stagger_ms: float = 1200
    stagger_dmg: float = 1.5
    stagger_kick: float = 1.8
    stagger_immune_ms: float = 3000
    dodge_ms: float = 600
    dodge_cd_ms: float = 3000
    wobble_ms: float = 2500
    block_cut: float = 0.7
    block_kick: float = 0.15
    perfect_block_poise: float = 40
    boss_stagger_ms: float = 4000
    boss_stagger_dmg: float = 1.5
    boss_poise_decay: float = 5
    damage_scale: float = 1
    defend_perfect_ms: float = 60
    # Debuffs last this share of their length (Resilience shortens them).
    debuff_scale: float = 1

    @classmethod
    def from_seed(cls, rules: dict) -> "Rules":
        """From seed.json's `rules` (or the alz:rules hash): `balance_core` and
        the like, and `defend_perfect_ms`. Anything missing keeps its default."""
        values = {}
        for f in fields(cls):
            raw = rules.get(f.name if f.name == "defend_perfect_ms" else "balance_" + f.name)
            if raw is None:
                continue
            if f.name == "well_radius":
                values[f.name] = tuple(float(x) for x in (raw if isinstance(raw, (list, tuple)) else str(raw).split(",")))
            else:
                values[f.name] = float(raw)
        return cls(**values)

    def as_dict(self) -> dict:
        """The rules as the client gets them when an encounter starts."""
        out = {f.name: getattr(self, f.name) for f in fields(self)}
        out["well_radius"] = list(self.well_radius)
        return out

    def for_player(self, poise: float = 0, focus: float = 0, resilience: float = 0) -> "Rules":
        """Poise widens the core, Focus the perfect circle, and Resilience
        shortens debuffs by 5% a point, up to half."""
        return replace(self, core=self.core * (1 + 0.04 * poise), perfect_r=self.perfect_r * (1 + 0.05 * focus),
                       debuff_scale=max(0.5, 1 - 0.05 * resilience))


# Gear and blows ---------------------------------------------------------------------------


@dataclass(frozen=True)
class Gear:
    """What the simulation needs of the gear in a slot."""

    cooldown: float = 0          # ms before the slot can strike again
    kick: float = 0              # knock on your own dot, per hit
    pattern: str = "bump"        # bump, side or taps
    hits: int = 1                # a volley's hits
    gap: float = 0               # ms between them
    debuff: dict | None = None   # on yourself: {"kind", "strength", "ms"}

    @classmethod
    def from_dict(cls, g: dict) -> "Gear":
        return cls(cooldown=float(g.get("cooldown") or 0), kick=float(g.get("kick") or 0),
                   pattern=g.get("pattern") or "bump", hits=int(g.get("hits") or 1), gap=float(g.get("gap") or 0),
                   debuff=g.get("debuff") or None)


@dataclass(frozen=True)
class Blow:
    """An NPC attack landing on a player: its knock, in the direction the
    server drew and announced with the warning."""

    kick: float = 0
    angle: float = 0
    defend: str = "both"          # both, block, dodge or none: what can meet it
    stagger: bool = False         # a signature blow, that staggers whatever its kick
    debuff: dict | None = None    # e.g. {"kind": "reeling", "strength": 1, "ms": 5000}
    parting: bool = False         # a parting blow: no defence, no knock, no stagger, no debuff


# The dot ----------------------------------------------------------------------------------


@dataclass
class Dot:
    """One player's dot, well, timers and random stream."""

    rules: Rules
    seed: int
    slots: dict = field(default_factory=dict)   # slot number: Gear
    shield: bool = False
    x: float = 0.0
    y: float = 0.0
    vx: float = 0.0
    vy: float = 0.0
    well_a: float = 0.0
    well_r: float = 0.0
    well_target: float = 0.0
    spin: int = 1
    n: int = 0                                  # steps taken
    cool: dict = field(default_factory=dict)    # slot: steps until it can strike again
    dodge_cd: int = 0
    invuln: int = 0
    wobble_after: bool = False                  # a dodge's wobble, due when it ends
    stagger: int = 0
    sx: float = 0.0
    sy: float = 0.0
    immune: int = 0
    debuffs: dict = field(default_factory=dict)  # kind: [strength, steps left, steps in all]
    blocking: bool = False
    block_n: int = 0
    wobble_clock: float = 0.0
    pending: list | None = None                 # a buffered strike: [slot, target, steps left]
    volleys: list = field(default_factory=list)  # [slot, target, tier, next hit, steps to it, angle]
    draws: tuple = (0.0, 0.0, 0.0, 0.0)
    rng: Rng = None

    def __post_init__(self):
        self.rng = Rng(self.seed)
        lo, hi = self.rules.well_radius
        self.well_a = self.rng.next() * TAU
        self.well_r = lo + (hi - lo) * self.rng.next()
        self.well_target = self.well_r
        self.spin = -1 if self.rng.next() < 0.5 else 1
        self.slots = {int(k): v if isinstance(v, Gear) else Gear.from_dict(v) for k, v in self.slots.items()}

    @property
    def dist(self) -> float:
        return math.sqrt(self.x * self.x + self.y * self.y)

    @property
    def staggered(self) -> bool:
        return self.stagger > 0

    def fade(self, kind: str) -> float:
        """A debuff's strength now: its strength, fading to 0 over its length."""
        d = self.debuffs.get(kind)
        return d[0] * d[1] / d[2] if d else 0.0

    def state(self) -> dict:
        """What the server sends (and the vectors record) of a dot."""
        return {"n": self.n, "x": self.x, "y": self.y, "vx": self.vx, "vy": self.vy,
                "well": [self.well_a, self.well_r], "stagger": self.stagger, "immune": self.immune,
                "invuln": self.invuln, "blocking": self.blocking, "dodge_cd": self.dodge_cd,
                "cool": {str(k): v for k, v in sorted(self.cool.items()) if v > 0},
                "debuffs": {k: [round(v[0], 6), v[1], v[2]] for k, v in sorted(self.debuffs.items())}}


def make_dot(rules: Rules, encounter_seed, pid: str, slots: dict | None = None, shield: bool = False) -> Dot:
    """A player's dot at the start of an encounter, at the centre."""
    return Dot(rules=rules, seed=seed_for(encounter_seed, pid), slots=slots or {}, shield=shield)


def add_debuff(dot: Dot, kind: str, strength: float, ms: float) -> None:
    """Starts a debuff (shortened by Resilience). One already running restarts
    at the larger strength."""
    total = max(1, steps(ms * dot.rules.debuff_scale))
    old = dot.debuffs.get(kind)
    dot.debuffs[kind] = [max(strength, old[0]) if old else strength, total, total]


def tier(dot: Dot) -> int:
    """How close to the centre a strike is: 0 edge, 1 clean, 2 perfect."""
    d = dot.dist
    if d <= dot.rules.perfect_r:
        return 2
    if d <= dot.rules.clean_r:
        return 1
    return 0


def strike_check(dot: Dot, slot: int) -> str | None:
    """Why a strike with this slot can't happen now, or None if it can."""
    if dot.staggered:
        return "staggered"
    if dot.blocking or dot.dist > dot.rules.core:
        return "not_steady"
    if dot.cool.get(slot, 0) > 0:
        return "cooldown"
    if slot not in dot.slots:
        return "empty"
    return None


def apply_kick(dot: Dot, kick: float, pattern: str, angle: float | None = None) -> float:
    """Knocks the dot (an impulse on its velocity) and returns the direction.
    `bump` goes in a random direction, `side` sideways, `taps` the given one."""
    u = dot.draws[3]
    if pattern == "side":
        sign = -1 if u < 0.5 else 1
        lean = (u * 2 % 1) * 2 - 1
        dx, dy = sign * kick, kick * 0.2 * lean
        dot.vx += dx
        dot.vy += dy
        return math.atan2(dy, dx)
    if angle is None:
        angle = u * TAU
    dot.vx += kick * math.cos(angle)
    dot.vy += kick * math.sin(angle)
    return angle


def stagger(dot: Dot, angle: float) -> None:
    """Puts the dot on the rim where it hit, still, easing back toward a point
    0.35 from the centre within 0.8 rad of there."""
    dot.x = math.cos(angle)
    dot.y = math.sin(angle)
    dot.vx = dot.vy = 0.0
    dot.stagger = steps(dot.rules.stagger_ms)
    back = angle + (dot.draws[3] * 2 - 1) * 0.8
    dot.sx = 0.35 * math.cos(back)
    dot.sy = 0.35 * math.sin(back)


def _strike(dot: Dot, slot: int, target, events: list) -> None:
    """A valid strike: its tier, the cooldown, the kick on your own dot, any
    debuff on yourself, and the first hit of a volley (the rest follow)."""
    gear = dot.slots[slot]
    t = tier(dot)
    dot.cool[slot] = steps(gear.cooldown)
    angle = apply_kick(dot, gear.kick, gear.pattern)
    if gear.debuff:
        add_debuff(dot, gear.debuff["kind"], float(gear.debuff["strength"]), float(gear.debuff["ms"]))
    events.append({"type": "strike", "slot": slot, "target": target, "tier": t, "hit": 1, "hits": gear.hits})
    if gear.hits > 1:
        dot.volleys.append([slot, target, t, 2, max(1, steps(gear.gap)), angle])


def cancel_volleys(dot: Dot, target=None) -> None:
    """Stops volleys (at a target that died, or all of them when you leave)."""
    dot.volleys = [v for v in dot.volleys if target is not None and v[1] != target]


def apply_blow(dot: Dot, blow: Blow) -> dict:
    """An NPC attack landing on this dot. Returns `result` (parting, dodge,
    block, perfect_block, staggered or hit: `staggered` means it landed while
    you were staggered, for the extra damage) and `stagger` (it staggered you)."""
    r = dot.rules
    if blow.parting:
        return {"result": "parting", "stagger": False}
    if dot.invuln > 0 and blow.defend not in ("block", "none"):
        return {"result": "dodge", "stagger": False}
    if dot.blocking and not dot.staggered and blow.defend not in ("dodge", "none"):
        k = blow.kick * r.block_kick
        dot.vx += k * math.cos(blow.angle)
        dot.vy += k * math.sin(blow.angle)
        perfect = dot.n - dot.block_n <= steps(r.defend_perfect_ms)
        return {"result": "perfect_block" if perfect else "block", "stagger": False}
    was = dot.staggered
    if not was:
        dot.vx += blow.kick * math.cos(blow.angle)
        dot.vy += blow.kick * math.sin(blow.angle)
    staggers = (blow.stagger or blow.kick >= r.stagger_kick) and not was and dot.immune == 0
    if staggers:
        stagger(dot, blow.angle)
    if blow.debuff:
        add_debuff(dot, blow.debuff["kind"], float(blow.debuff["strength"]), float(blow.debuff["ms"]))
    return {"result": "staggered" if was else "hit", "stagger": staggers}


def _timers(dot: Dot, events: list) -> None:
    for slot in list(dot.cool):
        if dot.cool[slot] > 0:
            dot.cool[slot] -= 1
    if dot.dodge_cd > 0:
        dot.dodge_cd -= 1
    if dot.immune > 0:
        dot.immune -= 1
    if dot.invuln > 0:
        dot.invuln -= 1
        if dot.invuln == 0 and dot.wobble_after:
            dot.wobble_after = False
            add_debuff(dot, "wobble", 1.0, dot.rules.wobble_ms)
    if dot.stagger > 0:
        dot.stagger -= 1
        if dot.stagger == 0:
            dot.immune = steps(dot.rules.stagger_immune_ms)
            events.append({"type": "recover"})
    for kind in list(dot.debuffs):
        d = dot.debuffs[kind]
        d[1] -= 1
        if d[1] <= 0:
            del dot.debuffs[kind]


def _well(dot: Dot) -> None:
    r = min(1.0, dot.fade("reeling"))
    u1, u2 = dot.draws[0], dot.draws[1]
    if u1 < DT * (0.08 + 0.6 * r):
        dot.spin = -dot.spin
    p = DT * (0.25 + r)
    if u2 < p:
        lo, hi = dot.rules.well_radius
        dot.well_target = lo + (hi - lo) * (u2 / p)
    dot.well_r += (dot.well_target - dot.well_r) * (1 - math.exp(-0.8 * DT))
    dot.well_a += dot.spin * dot.rules.well_speed * (1 + 3 * r) * DT


def _act(dot: Dot, act, events: list) -> None:
    kind = act[0]
    if kind == "strike":
        dot.pending = [int(act[1]), act[2] if len(act) > 2 else None, steps(dot.rules.buffer_ms)]
    elif kind == "dodge":
        why = "staggered" if dot.staggered else "blocking" if dot.blocking else "cooldown" if dot.dodge_cd > 0 else None
        if why:
            events.append({"type": "refused", "act": "dodge", "reason": why})
            return
        dot.invuln = steps(dot.rules.dodge_ms)
        dot.dodge_cd = steps(dot.rules.dodge_cd_ms)
        dot.wobble_after = True
        events.append({"type": "dodge"})
    elif kind == "block":
        if not dot.shield:
            events.append({"type": "refused", "act": "block", "reason": "no_shield"})
        elif not dot.blocking:
            dot.blocking = True
            dot.block_n = dot.n
    elif kind == "unblock":
        dot.blocking = False


def _volleys(dot: Dot, events: list) -> None:
    keep = []
    for v in dot.volleys:
        v[4] -= 1
        if v[4] > 0:
            keep.append(v)
            continue
        slot, target, t, hit, _, angle = v
        gear = dot.slots[slot]
        apply_kick(dot, gear.kick, gear.pattern, angle if gear.pattern == "taps" else None)
        events.append({"type": "strike", "slot": slot, "target": target, "tier": t, "hit": hit, "hits": gear.hits})
        if hit < gear.hits:
            keep.append([slot, target, t, hit + 1, max(1, steps(gear.gap)), angle])
    dot.volleys = keep


def _physics(dot: Dot, keys: int, events: list) -> None:
    r = dot.rules
    if dot.staggered:
        ease = 1 - math.exp(-3 * DT)
        dot.x += (dot.sx - dot.x) * ease
        dot.y += (dot.sy - dot.y) * ease
        dot.vx = dot.vy = 0.0
        return
    reel = min(1.0, dot.fade("reeling"))
    calm = 0.1 if dot.blocking else 1.0
    # Gravity toward the well, eased off close to it.
    wx = dot.well_r * math.cos(dot.well_a)
    wy = dot.well_r * math.sin(dot.well_a)
    gx, gy = wx - dot.x, wy - dot.y
    dg = math.sqrt(gx * gx + gy * gy)
    ax = ay = 0.0
    if dg > 0:
        g = r.gravity * (1 + 0.6 * reel) * calm
        if dg < r.gravity_falloff:
            g = g * dg / r.gravity_falloff
        ax = g * gx / dg
        ay = g * gy / dg
    # Your push, against it.
    if not dot.blocking:
        px = (1 if keys & RIGHT else 0) - (1 if keys & LEFT else 0)
        py = (1 if keys & DOWN else 0) - (1 if keys & UP else 0)
        if px and py:
            px *= math.sqrt(0.5)
            py *= math.sqrt(0.5)
        steady = 1.5 if "steady" in dot.debuffs else 1.0
        heavy = dot.debuffs.get("heavy")
        weigh = 1 + (heavy[0] * heavy[1] / heavy[2] if heavy else 0.0)
        push = r.push * steady / weigh
        ax += px * push
        ay += py * push
    dot.vx += ax * DT
    dot.vy += ay * DT
    # Wobble: a kick in a random direction every 0.07 s, fading.
    wob = dot.fade("wobble")
    if wob > 0:
        dot.wobble_clock += DT
        if dot.wobble_clock >= 0.07:
            dot.wobble_clock -= 0.07
            k = 1.1 * wob * calm
            a = dot.draws[2] * TAU
            dot.vx += k * math.cos(a)
            dot.vy += k * math.sin(a)
    else:
        dot.wobble_clock = 0.0
    damp = math.exp(-(r.block_damping if dot.blocking else r.damping) * DT)
    dot.vx *= damp
    dot.vy *= damp
    dot.x += dot.vx * DT
    dot.y += dot.vy * DT
    # The rim: bounce back while wobbling or stagger-immune, else stagger.
    d = dot.dist
    if d >= 1:
        nx, ny = dot.x / d, dot.y / d
        if wob > 0.15 or dot.immune > 0:
            vn = dot.vx * nx + dot.vy * ny
            if vn > 0:
                dot.vx -= 2 * vn * nx
                dot.vy -= 2 * vn * ny
            dot.x = nx * 0.999
            dot.y = ny * 0.999
        else:
            stagger(dot, math.atan2(ny, nx))
            events.append({"type": "stagger", "by": "rim"})


def step(dot: Dot, keys: int = 0, acts=(), blows=()) -> list[dict]:
    """Moves the dot on one step: timers, the four random draws, the well,
    the acts (strike, dodge, block, unblock), any buffered strike, volleys,
    blows landing, then the dot itself. Returns what happened: strikes
    (with their tier), refusals, dodges, blows' results, staggers, recovery."""
    events: list[dict] = []
    dot.n += 1
    _timers(dot, events)
    dot.draws = (dot.rng.next(), dot.rng.next(), dot.rng.next(), dot.rng.next())
    _well(dot)
    for act in acts:
        _act(dot, act, events)
    if dot.pending:
        slot, target, left = dot.pending
        why = strike_check(dot, slot)
        if why is None:
            dot.pending = None
            _strike(dot, slot, target, events)
        elif why == "empty" or left <= 0:
            dot.pending = None
            events.append({"type": "refused", "act": "strike", "slot": slot, "reason": why})
        else:
            dot.pending[2] = left - 1
    _volleys(dot, events)
    for blow in blows:
        result = apply_blow(dot, blow)
        events.append({"type": "blow", **result})
        if result["stagger"]:
            events.append({"type": "stagger", "by": "blow"})
    _physics(dot, keys, events)
    return events


# Bosses -----------------------------------------------------------------------------------


@dataclass
class Boss:
    """A boss's stagger meter. Strikes and perfect blocks fill it, it drains
    over time, and when it's full the boss reels: its attacks wait and it takes
    extra damage."""

    poise: float
    rules: Rules = field(default_factory=Rules)
    meter: float = 0.0
    staggered: int = 0

    def add(self, amount: float) -> bool:
        """Fills the meter; True if that staggers the boss."""
        if self.staggered:
            return False
        self.meter += amount
        if self.meter >= self.poise:
            self.meter = 0.0
            self.staggered = steps(self.rules.boss_stagger_ms)
            return True
        return False

    def strike(self, kick: float) -> bool:
        """A strike's hit on the boss: its kick × 10."""
        return self.add(kick * 10)

    def perfect_block(self) -> bool:
        return self.add(self.rules.perfect_block_poise)

    def step(self) -> None:
        if self.staggered:
            self.staggered -= 1
        else:
            self.meter = max(0.0, self.meter - self.rules.boss_poise_decay * DT)

    @property
    def damage_mult(self) -> float:
        return self.rules.boss_stagger_dmg if self.staggered else 1.0


# Scripted runs ----------------------------------------------------------------------------


def replay(script: dict) -> dict:
    """Plays a scripted run: a dot (`seed`, `pid`, `rules` overrides, `slots`,
    `shield`, stats) for `steps` steps, with held keys changing at given steps
    (`keys`: [[step, mask]]), acts (`acts`: [[step, act, ...]]) and blows
    (`blows`: [[step, {kick, angle, ...}]]). Returns the dot's state every 30
    steps (and at the end) and every event, each with its step. The shared
    vectors (tests/balance_vectors.json) are scripts like this, and the
    client's copy of the simulation must replay them the same way."""
    rules = Rules.from_seed(script.get("rules", {})).for_player(**script.get("stats", {}))
    dot = make_dot(rules, script["seed"], script["pid"], script.get("slots", {}), script.get("shield", False))
    keys_at = {int(n): int(k) for n, k in script.get("keys", [])}
    acts_at: dict[int, list] = {}
    for n, *act in script.get("acts", []):
        acts_at.setdefault(int(n), []).append(tuple(act))
    blows_at: dict[int, list] = {}
    for n, b in script.get("blows", []):
        blows_at.setdefault(int(n), []).append(Blow(**b))
    keys, states, events = 0, [], []
    for n in range(1, script["steps"] + 1):
        keys = keys_at.get(n, keys)
        for e in step(dot, keys, acts_at.get(n, ()), blows_at.get(n, ())):
            events.append({"n": n, **e})
        if n % 30 == 0 or n == script["steps"]:
            states.append(dot.state())
    return {"states": states, "events": events}
