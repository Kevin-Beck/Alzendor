"""The balance simulation (alzendor/balance.py), with no Redis: the step,
strikes, blows, debuffs and the boss meter, and the shared vectors the
client's copy is checked against."""

import json
import math
import shutil
import subprocess
from pathlib import Path

import pytest

from alzendor import balance as b

ROOT = Path(__file__).parent.parent
VECTORS = Path(__file__).parent / "balance_vectors.json"
DAGGER = {"cooldown": 350, "kick": 1.0, "pattern": "bump"}
GREATAXE = {"cooldown": 2500, "kick": 1.6, "pattern": "side", "debuff": {"kind": "heavy", "strength": 1.75, "ms": 5000}}
MISSILE = {"cooldown": 4500, "kick": 0.7, "pattern": "taps", "hits": 4, "gap": 1000}


def still(**over) -> b.Rules:
    """Rules with no well pulling the dot, so a test can put it where it likes."""
    return b.Rules(**{"gravity": 0, **over})


def dot(rules=None, slots=None, shield=False, pid="p1") -> b.Dot:
    return b.make_dot(rules or still(), "enc-1", pid, slots if slots is not None else {1: DAGGER}, shield)


def run(d, n, keys=0):
    events = []
    for _ in range(n):
        events += b.step(d, keys)
    return events


def kinds(events):
    return [e["type"] for e in events]


# Random numbers and steps -----------------------------------------------------------------


def test_mulberry32_matches_javascript():
    # mulberry32(42), as the usual JavaScript one-liner gives it.
    r = b.Rng(42)
    assert [r.next() for _ in range(3)] == [0.6011037519201636, 0.44829055899754167, 0.8524657934904099]


def test_fnv1a():
    assert b.fnv1a("") == 0x811C9DC5
    assert b.fnv1a("a") == 0xE40C292C


def test_each_player_has_their_own_stream():
    assert b.seed_for("enc", "kev") != b.seed_for("enc", "ana")
    assert b.seed_for("enc", "kev") == b.seed_for("enc", "kev")


def test_steps_round_half_up():
    assert b.steps(1500) == 90
    assert b.steps(100) == 6
    assert b.steps(25) == 2  # 1.5 steps


def test_four_draws_every_step_whatever_happens():
    a, c = dot(shield=True), dot(shield=True)
    b.step(a, b.LEFT, [("strike", 1, "npc:x"), ("block",), ("dodge",)], [b.Blow(kick=2.5, angle=1)])
    b.step(c)
    assert a.rng.s == c.rng.s
    assert a.draws == c.draws


# The well and the dot ---------------------------------------------------------------------


def test_starts_at_the_centre():
    d = dot(b.Rules())
    assert (d.x, d.y, d.vx, d.vy) == (0, 0, 0, 0)
    assert 0.5 <= d.well_r <= 0.85


def test_the_well_pulls_an_idle_dot_out_of_the_core():
    d = dot(b.Rules())
    run(d, 120)
    assert d.dist > d.rules.core


def test_leaning_against_the_well_keeps_the_dot_in_the_core():
    d = dot(b.Rules())
    for _ in range(600):
        k = (b.LEFT if d.x > 0.02 else b.RIGHT if d.x < -0.02 else 0) | (b.UP if d.y > 0.02 else b.DOWN if d.y < -0.02 else 0)
        b.step(d, k)
        assert d.dist < d.rules.core


def test_the_well_turns_and_circles():
    d = dot(b.Rules())
    angles = []
    for _ in range(3000):
        before = d.well_a
        b.step(d)
        angles.append(d.well_a - before)
    assert any(a > 0 for a in angles) and any(a < 0 for a in angles)
    assert all(abs(a) == pytest.approx(0.3 / 60) for a in angles)
    assert 0.5 <= d.well_r <= 0.85


def test_push_moves_the_dot_and_diagonals_are_no_faster():
    straight, diagonal = dot(), dot()
    run(straight, 30, b.RIGHT)
    run(diagonal, 30, b.RIGHT | b.UP)
    assert straight.x > 0 and straight.y == 0
    assert diagonal.x > 0 and diagonal.y < 0  # up is toward -y, as on screen
    assert diagonal.dist == pytest.approx(straight.dist)


def test_opposite_keys_cancel():
    d = dot()
    run(d, 30, b.LEFT | b.RIGHT | b.UP | b.DOWN)
    assert (d.x, d.y) == (0, 0)


def test_touching_the_rim_staggers():
    d = dot()
    events = run(d, 200, b.RIGHT)
    assert {"type": "stagger", "by": "rim"} in events
    assert kinds(events).index("stagger") < kinds(events).index("recover")
    assert d.dist <= 1


def test_a_stagger_lasts_its_time_then_immunity():
    d = dot()
    b.stagger(d, 0)
    assert (d.x, d.y, d.vx, d.vy) == (1, 0, 0, 0)
    assert math.hypot(d.sx, d.sy) == pytest.approx(0.35)
    assert abs(math.atan2(d.sy, d.sx)) <= 0.8
    events = run(d, 71, b.LEFT)
    assert d.staggered and "recover" not in kinds(events)
    assert d.vx == 0  # no input while staggered
    assert math.hypot(d.x - d.sx, d.y - d.sy) < 0.1  # eased back toward its point
    assert kinds(run(d, 1)) == ["recover"]
    assert not d.staggered and d.immune == b.steps(3000)


def test_stagger_immune_dots_bounce_off_the_rim():
    d = dot()
    d.immune = 10000
    events = run(d, 300, b.RIGHT)
    assert "stagger" not in kinds(events)
    assert d.dist < 1


def test_wobbling_dots_bounce_off_the_rim():
    d = dot()
    b.add_debuff(d, "wobble", 1, 100000)
    d.x, d.vx = 0.99, 5
    assert "stagger" not in kinds(run(d, 2))
    assert d.dist < 1


# Strikes ----------------------------------------------------------------------------------


def test_tiers_by_distance_from_the_centre():
    d = dot()
    for x, t in [(0, 2), (0.06, 2), (0.07, 1), (0.14, 1), (0.15, 0), (0.22, 0)]:
        d.x = x
        assert b.tier(d) == t


def test_a_strike_in_the_core():
    d = dot()
    d.x = 0.1
    events = b.step(d, 0, [("strike", 1, "npc:orc")])
    assert {"type": "strike", "slot": 1, "target": "npc:orc", "tier": 1, "hit": 1, "hits": 1} in events
    assert d.cool[1] == b.steps(350)
    assert math.hypot(d.vx, d.vy) == pytest.approx(1.0 * math.exp(-2.5 / 60))  # the dagger's kick, after a step's damping


def test_cooldown_refuses_and_then_allows():
    d = dot()
    b.step(d, 0, [("strike", 1, "npc:orc")])
    d.x = d.y = d.vx = d.vy = 0
    events = run(d, 0) + b.step(d, 0, [("strike", 1, "npc:orc")])
    d.vx = d.vy = 0
    events += run(d, 6)
    assert {"type": "refused", "act": "strike", "slot": 1, "reason": "cooldown"} in events
    d.x = d.y = d.vx = d.vy = 0
    run(d, 30)
    d.x = d.y = d.vx = d.vy = 0
    assert "strike" in kinds(b.step(d, 0, [("strike", 1, "npc:orc")]))


def test_off_centre_strikes_wait_briefly_then_drop():
    d = dot()
    d.x = 0.5
    events = b.step(d, 0, [("strike", 1, None)])
    events += run(d, 5)
    assert kinds(events) == []  # held for 100 ms
    assert kinds(run(d, 1)) == ["refused"]


def test_a_buffered_strike_fires_when_the_dot_comes_in():
    d = dot()
    d.x, d.vx = 0.26, -3  # moving into the core
    events = b.step(d, 0, [("strike", 1, None)]) + run(d, 4)
    assert "strike" in kinds(events)


def test_no_strike_while_staggered_or_blocking():
    d = dot(shield=True)
    b.step(d, 0, [("block",)])
    assert b.strike_check(d, 1) == "not_steady"
    d.blocking = False
    b.stagger(d, 0)
    assert b.strike_check(d, 1) == "staggered"


def test_side_kick_goes_sideways():
    d = dot(slots={3: GREATAXE})
    b.step(d, 0, [("strike", 3, None)])
    assert abs(d.vx) > 3 * abs(d.vy)


def test_heavy_gear_slows_your_push():
    light, heavy = dot(), dot(slots={3: GREATAXE})
    b.step(heavy, 0, [("strike", 3, None)])
    heavy.x = heavy.y = heavy.vx = heavy.vy = 0
    light.n = heavy.n
    run(light, 20, b.UP)
    run(heavy, 20, b.UP)
    assert "heavy" in heavy.debuffs
    assert -heavy.y < -light.y / 2


def test_volleys_land_hit_by_hit_in_one_direction():
    d = dot(slots={2: MISSILE})
    first = b.step(d, 0, [("strike", 2, "npc:orc")])
    assert [e["hit"] for e in first if e["type"] == "strike"] == [1]
    angle = math.atan2(d.vy, d.vx)
    hits = []
    for _ in range(4 * 60):
        d.x = d.y = d.vx = d.vy = 0
        for e in b.step(d):
            if e["type"] == "strike":
                hits.append((d.n, e["hit"], e["tier"]))
                assert math.atan2(d.vy, d.vx) == pytest.approx(angle)
    assert [h[1] for h in hits] == [2, 3, 4]
    assert hits[1][0] - hits[0][0] == 60  # every gap
    assert {h[2] for h in hits} == {2}  # at the tier of the press


def test_volleys_stop_when_their_target_goes():
    d = dot(slots={2: MISSILE})
    b.step(d, 0, [("strike", 2, "npc:orc")])
    b.cancel_volleys(d, "npc:other")
    assert d.volleys
    b.cancel_volleys(d, "npc:orc")
    assert not d.volleys


# Blows ------------------------------------------------------------------------------------


def test_a_blow_knocks_in_its_direction():
    d = dot()
    events = b.step(d, 0, blows=[b.Blow(kick=1, angle=math.pi / 2)])
    assert {"type": "blow", "result": "hit", "stagger": False} in events
    assert d.vy > 0.9 and abs(d.vx) < 1e-9


def test_a_big_blow_staggers():
    d = dot()
    events = b.step(d, 0, blows=[b.Blow(kick=1.8, angle=0)])
    assert {"type": "stagger", "by": "blow"} in events
    assert d.staggered and d.x > 0.95 and d.vx == 0


def test_a_signature_blow_staggers_whatever_its_kick():
    d = dot()
    assert b.apply_blow(d, b.Blow(kick=0.3, stagger=True))["stagger"]


def test_blows_while_staggered_count_extra_and_dont_restagger():
    d = dot()
    b.stagger(d, 0)
    assert b.apply_blow(d, b.Blow(kick=2.5)) == {"result": "staggered", "stagger": False}


def test_stagger_immunity():
    d = dot()
    d.immune = 10
    assert b.apply_blow(d, b.Blow(kick=2.5)) == {"result": "hit", "stagger": False}


def test_dodging():
    d = dot()
    assert kinds(b.step(d, 0, [("dodge",)])) == ["dodge"]
    assert b.apply_blow(d, b.Blow(kick=2.5, defend="both"))["result"] == "dodge"
    assert b.apply_blow(d, b.Blow(kick=2.5, defend="dodge"))["result"] == "dodge"
    assert d.vx == d.vy == 0
    assert b.apply_blow(d, b.Blow(kick=1, defend="block"))["result"] == "hit"
    d.vx = 0
    assert b.apply_blow(d, b.Blow(kick=1, defend="none"))["result"] == "hit"


def test_a_dodge_lasts_then_wobbles_then_cools_down():
    d = dot()
    b.step(d, 0, [("dodge",)])
    run(d, b.steps(600) - 1)
    assert d.invuln == 1 and "wobble" not in d.debuffs
    run(d, 1)
    assert d.invuln == 0 and "wobble" in d.debuffs
    assert d.debuffs["wobble"][2] == b.steps(2500)
    assert b.step(d, 0, [("dodge",)])[0] == {"type": "refused", "act": "dodge", "reason": "cooldown"}
    run(d, b.steps(3000))
    assert kinds(b.step(d, 0, [("dodge",)])) == ["dodge"]


def test_blocking():
    d = dot(shield=True)
    b.step(d, 0, [("block",)])
    run(d, 10)
    d.vx = d.vy = 0
    result = b.apply_blow(d, b.Blow(kick=2.5, angle=0, defend="both", debuff={"kind": "reeling", "strength": 1, "ms": 5000}))
    assert result == {"result": "block", "stagger": False}
    assert d.vx == pytest.approx(2.5 * 0.15)
    assert "reeling" not in d.debuffs
    assert b.apply_blow(d, b.Blow(kick=1, defend="dodge"))["result"] == "hit"


def test_a_perfect_block():
    d = dot(shield=True)
    b.step(d, 0, [("block",)])
    run(d, 3)
    assert b.apply_blow(d, b.Blow(kick=1))["result"] == "perfect_block"
    run(d, 2)
    assert b.apply_blow(d, b.Blow(kick=1))["result"] == "block"


def test_no_block_without_a_shield():
    d = dot()
    assert b.step(d, 0, [("block",)])[0]["reason"] == "no_shield"
    assert not d.blocking


def test_blocking_holds_the_dot_steady_and_stops_steering():
    loose, held = dot(b.Rules(), shield=True), dot(b.Rules(), shield=True)
    b.step(held, 0, [("block",)])
    b.step(loose)
    run(held, 120, b.RIGHT)
    run(loose, 120)
    assert held.dist < loose.dist / 3


def test_a_parting_blow_ignores_everything():
    d = dot(shield=True)
    b.step(d, 0, [("block",)])
    d.invuln = 10
    assert b.apply_blow(d, b.Blow(kick=3, stagger=True, parting=True, debuff={"kind": "reeling", "strength": 1, "ms": 5000})) \
        == {"result": "parting", "stagger": False}
    assert d.vx == d.vy == 0 and not d.debuffs


# Debuffs and stats ------------------------------------------------------------------------


def test_reeling_spins_the_well_faster():
    d = dot(b.Rules())
    b.apply_blow(d, b.Blow(kick=0, debuff={"kind": "reeling", "strength": 1, "ms": 5000}))
    before = d.well_a
    b.step(d)
    assert abs(d.well_a - before) > 3.5 * 0.3 / 60


def test_steady_strengthens_your_push():
    plain, steady = dot(), dot()
    b.add_debuff(steady, "steady", 1.5, 3000)
    run(plain, 10, b.RIGHT)
    run(steady, 10, b.RIGHT)
    assert steady.x == pytest.approx(plain.x * 1.5)


def test_debuffs_fade_and_end():
    d = dot()
    b.add_debuff(d, "heavy", 2, 1000)
    assert d.fade("heavy") == 2
    run(d, 30)
    assert d.fade("heavy") == pytest.approx(1)
    run(d, 30)
    assert "heavy" not in d.debuffs


def test_a_running_debuff_restarts_at_the_larger_strength():
    d = dot()
    b.add_debuff(d, "heavy", 2, 1000)
    run(d, 30)
    b.add_debuff(d, "heavy", 1.5, 1000)
    assert d.debuffs["heavy"] == [2, 60, 60]


def test_stats():
    r = b.Rules().for_player(poise=5, focus=4, resilience=4)
    assert r.core == pytest.approx(0.22 * 1.2)
    assert r.perfect_r == pytest.approx(0.06 * 1.2)
    assert r.debuff_scale == pytest.approx(0.8)
    assert b.Rules().for_player(resilience=20).debuff_scale == 0.5
    d = dot(r)
    b.add_debuff(d, "reeling", 1, 5000)
    assert d.debuffs["reeling"][2] == b.steps(4000)


def test_rules_from_the_seed():
    seed = json.loads((ROOT / "world" / "seed.json").read_text())["rules"]
    r = b.Rules.from_seed({**seed, "balance_core": 0.3, "balance_well_radius": [0.4, 0.9], "defend_perfect_ms": 80})
    assert (r.core, r.well_radius, r.defend_perfect_ms, r.push) == (0.3, (0.4, 0.9), 80, 2.6)
    assert b.Rules.from_seed({"balance_well_radius": "0.4,0.8"}).well_radius == (0.4, 0.8)


# The boss meter ---------------------------------------------------------------------------


def test_boss_meter_fills_staggers_and_drains():
    boss = b.Boss(poise=100)
    assert not boss.strike(1.6)
    assert boss.meter == 16
    boss.step()
    assert boss.meter == pytest.approx(16 - 5 / 60)
    assert not boss.perfect_block()
    for _ in range(4):
        if boss.strike(2.0):
            break
    assert boss.staggered == b.steps(4000) and boss.meter == 0
    assert boss.damage_mult == 1.5
    assert not boss.strike(2.0) and boss.meter == 0  # nothing builds while it reels
    for _ in range(b.steps(4000)):
        boss.step()
    assert not boss.staggered and boss.damage_mult == 1


# The shared vectors -----------------------------------------------------------------------


def vectors():
    return json.loads(VECTORS.read_text())["runs"]


def test_python_matches_the_vectors_exactly():
    for run_ in vectors():
        assert b.replay(run_["script"]) == run_["expect"]


def test_the_vectors_cover_every_kind_of_event():
    seen = set()
    for run_ in vectors():
        for e in run_["expect"]["events"]:
            seen.add(e["type"] + ":" + str(e.get("result") or e.get("by") or e.get("reason") or ""))
    for want in ["strike:", "dodge:", "recover:", "blow:hit", "blow:dodge", "blow:block", "blow:perfect_block",
                 "blow:staggered", "blow:parting", "stagger:blow", "stagger:rim", "refused:not_steady", "refused:cooldown"]:
        assert want in seen, want


@pytest.mark.skipif(not shutil.which("node"), reason="node isn't installed")
def test_javascript_matches_the_vectors():
    result = subprocess.run(["node", str(ROOT / "tools" / "check_vectors.mjs")], capture_output=True, text=True, timeout=60)
    assert result.returncode == 0, result.stderr + result.stdout
