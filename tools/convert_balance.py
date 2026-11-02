"""Converts the world's content from rhythm combat to balance
(docs/combat-redesign.md, "Content conversion"), once:

    python -m tools.convert_balance

It rewrites world/seed.json and world/zones/*.json in place:

- gear: `period`, `window` and `perfect_window` give way to `cooldown`,
  `kick`, `pattern` (and `hits` and `gap` for volleys, `debuff` for heavy
  gear and potions), interpolated on the old period;
- NPC attacks gain `kick` (and `stagger` for a boss's signature blows,
  `debuff` reeling for the slowest);
- bosses (respawn of 900 s or more, with attacks) gain `poise`.

The formulas are in alzendor/balance.py (convert_gear, convert_attack,
boss_poise). Gear and attacks that already have their balance fields keep
them. The result is committed and then tuned (tools/balance_bot.py).
"""

from __future__ import annotations

import json
from pathlib import Path

from alzendor import balance as b

WORLD = Path(__file__).parent.parent / "world"
RHYTHM = ("period", "window", "perfect_window")


def convert_gear(gid: str, gear: dict) -> dict:
    """The gear with its balance fields where `period` was, and no rhythm."""
    fields = b.convert_gear(gid, gear)
    if "period" not in gear:
        return {**{k: v for k, v in gear.items() if k not in RHYTHM}, **fields}
    out = {}
    for key, value in gear.items():
        if key == "period":
            out.update(fields)
        elif key not in RHYTHM and key not in fields:
            out[key] = value
    return out


def convert_npc(npc: dict) -> dict:
    boss = float(npc.get("respawn") or 0) >= 900 and bool(npc.get("attacks"))
    for i, attack in enumerate(npc.get("attacks", [])):
        fields = b.convert_attack(attack, boss)
        out = {}
        for key, value in attack.items():
            out[key] = value
            if key == "damage":
                out.update(fields)
        out.update({k: v for k, v in fields.items() if k not in out})
        npc["attacks"][i] = out
    if boss and npc.get("poise") is None:
        out = {}
        for key, value in npc.items():
            out[key] = value
            if key == "max_hp":
                out["poise"] = b.boss_poise(float(npc.get("max_hp") or 10))
        out.setdefault("poise", b.boss_poise(float(npc.get("max_hp") or 10)))
        return out
    return npc


def convert_file(path: Path) -> tuple[int, int, int]:
    data = json.loads(path.read_text(encoding="utf-8"))
    gear = data.get("gear", {})
    for gid in list(gear):
        gear[gid] = convert_gear(gid, gear[gid])
    npcs = data.get("npcs", {})
    attacks = 0
    for nid in list(npcs):
        npcs[nid] = convert_npc(npcs[nid])
        attacks += len(npcs[nid].get("attacks", []))
    bosses = sum(1 for n in npcs.values() if n.get("poise"))
    path.write_text(json.dumps(data, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    return len(gear), attacks, bosses


def main() -> None:
    totals = [0, 0, 0]
    for path in [WORLD / "seed.json", *sorted((WORLD / "zones").glob("*.json"))]:
        counts = convert_file(path)
        totals = [a + c for a, c in zip(totals, counts)]
    print(f"converted {totals[0]} pieces of gear, {totals[1]} NPC attacks, {totals[2]} bosses")


if __name__ == "__main__":
    main()
