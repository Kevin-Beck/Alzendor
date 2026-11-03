"""Retunes the content against the tuning targets (docs/combat.md,
Tuning), with the balance bot (tools/balance_bot.py), and writes the result
into world/seed.json and world/zones/*.json:

    python -m tools.tune_balance            # tune, and write the content
    python -m tools.tune_balance --dry-run  # just say what it would change

In order:

1. Health by tier: every fighting NPC of a kind (ordinary, or boss) at a
   level gets the same health multiplier, so the tier's median fight takes
   its target time for the ideal player (30 s for an ordinary NPC, 3
   minutes for a boss). That keeps how tough NPCs are next to each other.
2. Outliers: an NPC whose fight is still outside its target window gets its
   own multiplier, just enough to bring it in.
3. Survival: where the sloppy player wins too rarely against an ordinary NPC
   (or the ideal player against a boss), its attacks come more slowly (a
   longer `period`), up to two and a half times as slow. Damage per blow
   stays as the content placed it.
4. Rooms of three or more enemies: their attack periods are staggered so the
   blows don't land together, and slowed as above if the sloppy player
   still loses.
5. Biggest blows: where the player still loses too often (step 3 has done
   all it may), the NPC's hardest-hitting attack loses 15% of its damage a
   round, down to half what it had when this step began.

`--steps 5` runs step 5 alone, on the content as it is (steps 1-4 have been
run on it already; running them again would retune every NPC's health).

Health changes keep an NPC's experience where it was (its `xp` is written
down if it came from its health). Bosses keep their poise.
"""

from __future__ import annotations

import argparse
import json
import statistics
from collections import defaultdict
from concurrent.futures import ProcessPoolExecutor

from tools import balance_bot as bot

TARGET = {"ordinary": (20, 30, 40), "boss": (120, 180, 240), "big boss": (120, 180, 240)}
FIGHTS = 6
MAX_SLOW = 2.5  # attacks at most this much slower than the content placed them
SOFTEN = 0.85    # step 5: the biggest blow's damage, each round
MIN_DAMAGE = 0.5  # step 5: never below this share of what it was

_world: bot.World | None = None


def _init(npcs: dict) -> None:
    global _world
    _world = bot.World.load()
    _world.data["npcs"].update(npcs)


def _judge(args) -> bot.Verdict:
    npcs, group, fights = args
    _world.data["npcs"].update(npcs)
    return bot.judge(_world, group, fights)


class Tuner:
    def __init__(self, fights: int):
        self.world = bot.World.load()
        self.fights = fights
        self.original = json.loads(json.dumps(self.world.data["npcs"]))
        self.fighters = self.world.fighters()
        self.rooms = self.world.rooms()
        self.slowed: dict[str, float] = defaultdict(lambda: 1.0)

    @property
    def npcs(self) -> dict:
        return self.world.data["npcs"]

    def judge(self, groups: list[list[str]]) -> dict:
        changed = {nid: self.npcs[nid] for g in groups for nid in g}
        with ProcessPoolExecutor(initializer=_init, initargs=(changed,)) as pool:
            verdicts = list(pool.map(_judge, [({}, g, self.fights) for g in groups]))
        return {tuple(g): v for g, v in zip(groups, verdicts)}

    def scale_health(self, nid: str, by: float) -> None:
        npc = self.npcs[nid]
        npc["max_hp"] = max(5, round(npc["max_hp"] * by))

    def slow(self, nids: list[str], by: float) -> bool:
        """Slows these NPCs' attacks; False if they're as slow as they may get."""
        moved = False
        for nid in nids:
            step = min(by, MAX_SLOW / self.slowed[nid])
            if step <= 1.001:
                continue
            self.slowed[nid] *= step
            for a in self.npcs[nid]["attacks"]:
                a["period"] = int(round(a["period"] * step / 100) * 100)
            moved = True
        return moved

    # The steps --------------------------------------------------------------------------

    def tiers(self) -> None:
        verdicts = self.judge([[n] for n in self.fighters])
        groups = defaultdict(list)
        for (nid,), v in verdicts.items():
            groups[(v.kind, v.level)].append((nid, v))
        for (kind, level), members in sorted(groups.items()):
            times = [v.ideal_seconds for _, v in members if v.ideal_seconds]
            if not times:
                continue
            by = max(0.2, min(8.0, TARGET[kind][1] / statistics.median(times)))
            for nid, _ in members:
                self.scale_health(nid, by)
            print(f"  tier {kind} L{level}: {len(members)} NPCs, median {statistics.median(times):.0f} s, health x{by:.2f}")

    def outliers_and_survival(self, rounds: int) -> dict:
        verdicts = {}
        for r in range(rounds):
            verdicts = self.judge([[n] for n in self.fighters])
            moved = 0
            for (nid,), v in verdicts.items():
                lo, mid, hi = TARGET[v.kind]
                if v.ideal_seconds and not lo <= v.ideal_seconds <= hi:
                    self.scale_health(nid, max(0.3, min(3.0, mid / v.ideal_seconds)))
                    moved += 1
                losing = v.sloppy_wins < 0.8 if v.kind == "ordinary" else v.ideal_wins < 0.9
                if losing and self.slow([nid], 1.25):
                    moved += 1
            on = sum(v.ok for v in verdicts.values())
            print(f"  round {r + 1}: {on} of {len(verdicts)} on target, {moved} changes")
            if not moved:
                break
        return verdicts

    def losing(self, v: bot.Verdict) -> bool:
        return v.sloppy_wins < 0.8 if v.kind == "ordinary" else v.ideal_wins < 0.9

    def soften(self, nid: str) -> bool:
        """Takes SOFTEN off the damage of this NPC's biggest blow; False if
        it's as soft as it may get."""
        attacks = self.npcs[nid]["attacks"]
        floor = {i: max(1, round(a["damage"] * MIN_DAMAGE)) for i, a in enumerate(self.original[nid]["attacks"])}
        for i in sorted(range(len(attacks)), key=lambda i: -attacks[i]["damage"]):
            new = max(floor[i], round(attacks[i]["damage"] * SOFTEN))
            if new < attacks[i]["damage"]:
                attacks[i]["damage"] = new
                return True
        return False

    def biggest_blows(self, rounds: int) -> dict:
        verdicts = self.judge([[n] for n in self.fighters])
        todo = [nid for (nid,), v in verdicts.items() if self.losing(v)]
        print(f"  {len(todo)} NPCs the player loses to too often")
        for r in range(rounds):
            moved = [nid for nid in todo if self.soften(nid)]
            if not moved:
                break
            again = self.judge([[n] for n in moved])
            verdicts.update(again)
            todo = [nid for (nid,), v in again.items() if self.losing(v)]
            print(f"  round {r + 1}: {len(moved)} softened, {len(todo)} still losing")
            if not todo:
                break
        on = sum(v.ok for v in verdicts.values())
        print(f"  {on} of {len(verdicts)} on target")
        return verdicts

    def tune_rooms(self, rounds: int) -> dict:
        # Stagger: each member's attacks a little slower than the last, so blows drift apart.
        for room in self.rooms:
            for i, nid in enumerate(room[1:], start=1):
                self.slow([nid], 1 + 0.12 * i)
        verdicts = {}
        for r in range(rounds):
            verdicts = self.judge(self.rooms)
            moved = 0
            for group, v in verdicts.items():
                if not v.ok and self.slow(list(group), 1.2):
                    moved += 1
            print(f"  rooms, round {r + 1}: {sum(v.ok for v in verdicts.values())} of {len(verdicts)} on target")
            if not moved:
                break
        return verdicts

    # Writing it down ---------------------------------------------------------------------

    def changes(self) -> list[str]:
        out = []
        for nid in self.fighters:
            old, new = self.original[nid], self.npcs[nid]
            periods = [(a["period"], b["period"]) for a, b in zip(old["attacks"], new["attacks"])]
            damage = [(a["damage"], b["damage"]) for a, b in zip(old["attacks"], new["attacks"])]
            if old["max_hp"] != new["max_hp"] or any(a != b for a, b in periods + damage):
                out.append(f"{nid}: health {old['max_hp']} -> {new['max_hp']}, "
                           f"periods {', '.join(f'{a}->{b}' for a, b in periods)}, "
                           f"damage {', '.join(f'{a}->{b}' for a, b in damage)}")
        return out

    def write(self) -> None:
        for path in [bot.SEED, *sorted((bot.SEED.parent / "zones").glob("*.json"))]:
            data = json.loads(path.read_text(encoding="utf-8"))
            touched = False
            for nid, npc in data.get("npcs", {}).items():
                if nid not in self.fighters:
                    continue
                new = self.npcs[nid]
                if npc["max_hp"] != new["max_hp"] and "xp" not in npc:
                    npc["xp"] = npc["max_hp"] // 2  # what it gave before; health no longer decides it
                npc["max_hp"] = new["max_hp"]
                for a, b in zip(npc["attacks"], new["attacks"]):
                    a["period"], a["damage"] = b["period"], b["damage"]
                touched = True
            if touched:
                path.write_text(json.dumps(data, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("-n", "--fights", type=int, default=FIGHTS)
    parser.add_argument("--rounds", type=int, default=6)
    parser.add_argument("--steps", default="1-5", help="which steps: 1-5 (all), or 5 (on the content as it is)")
    args = parser.parse_args()
    t = Tuner(args.fights)
    if args.steps != "5":
        print("1. health by tier")
        t.tiers()
        t.tiers()
        print("2-3. outliers and survival")
        t.outliers_and_survival(args.rounds)
        print("4. rooms")
        t.tune_rooms(args.rounds)
    print("5. biggest blows")
    t.biggest_blows(args.rounds)
    changes = t.changes()
    print(f"{len(changes)} NPCs changed")
    if args.dry_run:
        print("\n".join(changes))
    else:
        t.write()


if __name__ == "__main__":
    main()
