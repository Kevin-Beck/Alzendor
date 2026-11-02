"""Writes tests/balance_vectors.json: scripted runs of the balance simulation
and the Python copy's results, which the JavaScript copy (in web/index.html)
must reproduce. Run it again after any change to alzendor/balance.py:

    python -m tools.make_vectors

Each run is made by playing the simulation with a rough steering bot (it
leans toward the centre, with some noise and some lazy stretches), striking
when it can, dodging and blocking now and then, under blows of every kind.
What it pressed is written down as the script, so a replay needs no bot.
"""

from __future__ import annotations

import json
from pathlib import Path

from alzendor import balance as b

OUT = Path(__file__).parent.parent / "tests" / "balance_vectors.json"
RUNS = 20

SLOTS = {
    # The Training Yard loadout, converted as the plan's conversion does.
    1: {"cooldown": 350, "kick": 1.0, "pattern": "bump"},                     # Dagger
    2: {"cooldown": 4500, "kick": 0.7, "pattern": "taps", "hits": 4, "gap": 1000},  # Magic Missile
    3: {"cooldown": 2500, "kick": 1.6, "pattern": "side",
        "debuff": {"kind": "heavy", "strength": 1.75, "ms": 5000}},          # Greataxe
}
POTION = {"cooldown": 3000, "kick": 0, "pattern": "bump", "debuff": {"kind": "steady", "strength": 1.5, "ms": 3000}}
DEFENDS = ["both", "both", "block", "dodge", "none"]


def keys_toward(x: float, y: float, dead: float) -> int:
    k = 0
    if x > dead:
        k |= b.LEFT
    elif x < -dead:
        k |= b.RIGHT
    if y > dead:
        k |= b.UP
    elif y < -dead:
        k |= b.DOWN
    return k


def make_run(i: int) -> dict:
    r = b.Rng(1000 + i)
    stats = {"poise": int(r.next() * 4), "focus": int(r.next() * 4), "resilience": int(r.next() * 6)}
    rules = {}
    if i % 5 == 4:  # a few runs with other rules, so the client is seen to use the ones it's sent
        rules = {"balance_push": 2.2, "balance_gravity": 1.2, "balance_well_radius": [0.4, 0.9], "balance_damping": 3,
                 "balance_global_cd_ms": 900}
    slots = dict(SLOTS)
    if i % 3 == 1:
        slots[3] = POTION
    perks = [["second_wind"], ["steady_hands"], ["long_breath"], ["second_wind", "steady_hands", "long_breath"], []][i % 5]
    script = {"seed": f"vec-{i}", "pid": f"p{i}", "rules": rules, "stats": stats, "slots": {str(k): v for k, v in slots.items()},
              "shield": i % 2 == 0, "perks": perks, "steps": 600 + 60 * (i % 5)}
    rs = b.Rules.from_seed(rules).for_player(**stats)
    dot = b.make_dot(rs, script["seed"], script["pid"], slots, script["shield"], perks)
    dead = 0.02 + 0.08 * r.next()
    lazy = 0
    keys, key_log, acts, blows, pending_blows = 0, [], [], [], []
    for n in range(1, script["steps"] + 1):
        # The bot's choices for this step, from the dot as it stands.
        if lazy > 0:
            lazy -= 1
        elif r.next() < 0.01:
            lazy = int(20 + r.next() * 60)
        want = 0 if lazy else keys_toward(dot.x, dot.y, dead)
        if r.next() < 0.03:
            want = int(r.next() * 16)
        if want != keys:
            keys = want
            key_log.append([n, keys])
        now_acts, now_blows = [], []
        if r.next() < 0.06:
            now_acts.append(["strike", 1 + int(r.next() * 3), "npc:target"])
        if r.next() < 0.008:
            now_acts.append(["dodge"])
        if script["shield"] and r.next() < 0.01:
            now_acts.append(["unblock" if dot.blocking else "block"])
            if not dot.blocking and r.next() < 0.5:  # a blow just after: a perfect block, or nearly
                soon = n + 1 + int(r.next() * 6)
                pending_blows.append([soon, {"kick": round(1 + r.next(), 3), "angle": round(r.next() * b.TAU, 6)}])
        now_blows += [x for at, x in pending_blows if at == n]
        pending_blows = [p for p in pending_blows if p[0] != n]
        if r.next() < 0.012:
            blow = {"kick": round(0.5 + r.next() * 2, 3), "angle": round(r.next() * b.TAU, 6),
                    "defend": DEFENDS[int(r.next() * len(DEFENDS))]}
            if r.next() < 0.15:
                blow["stagger"] = True
            if r.next() < 0.2:
                blow["debuff"] = {"kind": "reeling", "strength": 1, "ms": 5000}
            if r.next() < 0.05:
                blow["parting"] = True
            now_blows.append(blow)
        acts += [[n, *a] for a in now_acts]
        blows += [[n, x] for x in now_blows]
        b.step(dot, keys, [tuple(a) for a in now_acts], [b.Blow(**x) for x in now_blows])
    script.update(keys=key_log, acts=acts, blows=blows, snap_at=300)
    return script


def main() -> None:
    runs = []
    for i in range(RUNS):
        script = make_run(i)
        runs.append({"script": script, "expect": b.replay(script)})
    OUT.write_text(json.dumps({"about": "Made by tools/make_vectors.py from alzendor/balance.py; checked by "
                                        "tests/test_balance.py and tools/check_vectors.mjs.", "runs": runs},
                              separators=(",", ":")) + "\n")
    events = sum(len(r["expect"]["events"]) for r in runs)
    kinds = {}
    for run in runs:
        for e in run["expect"]["events"]:
            key = e["type"] + (":" + e["result"] if e["type"] == "blow" else "") + (":" + e["by"] if e["type"] == "stagger" else "")
            kinds[key] = kinds.get(key, 0) + 1
    print(f"wrote {OUT} ({RUNS} runs, {events} events)")
    print(json.dumps(dict(sorted(kinds.items()))))


if __name__ == "__main__":
    main()
