"""Tuning (docs/combat-redesign.md): a quick run of the balance bot
(tools/balance_bot.py, 3 fights a class) over a fixed sample of NPCs from
every tier, against the tuning targets. No Redis needed."""

import statistics

import pytest

from tools.balance_bot import World, character, fight, judge

# Two ordinary NPCs from the low, middle and high levels, a lone boss under
# 1000 health from the frontier and one from the dangerous places, and two
# big bosses (three players).
SAMPLE = ["orc-1", "bramble_wolf", "highwayman_1", "deep_spider_1", "ash_wyrm_1", "glass_eel_1",
          "captain_crowe", "weaver_queen", "cinder_colossus", "storm_king"]


@pytest.fixture(scope="module")
def world():
    return World.load()


@pytest.fixture(scope="module")
def verdicts(world):
    return {nid: judge(world, [nid], fights=3) for nid in SAMPLE}


def test_the_sample_is_what_it_says(world):
    assert all(nid in world.fighters() for nid in SAMPLE)
    assert [world.is_boss(n) for n in SAMPLE] == [False] * 6 + [True] * 4
    assert sorted(world.levels[n] for n in SAMPLE[:6]) == [3, 4, 7, 9, 12, 16]


def test_the_ideal_player_beats_the_sloppy_one(world):
    c = character(world, "fighter", 3)
    ideal = [fight(world, [c], ["ideal"], ["orc-1"], s) for s in range(3)]
    sloppy = [fight(world, [c], ["sloppy"], ["orc-1"], s) for s in range(3)]
    assert all(r.won for r in ideal)
    assert statistics.median(r.seconds for r in ideal) < statistics.median(r.seconds for r in sloppy)


def test_characters_grow_with_their_level(world):
    low, high = character(world, "mage", 3), character(world, "mage", 15)
    assert high.max_hp > low.max_hp and high.armor >= low.armor
    assert sum(g["amounts"][1] for g in high.slots.values()) > sum(g["amounts"][1] for g in low.slots.values())


def test_the_damage_scale_centres_ordinary_fights(verdicts):
    """Step 1 of the procedure: the median ordinary NPC in the sample dies in 20-40 s to the ideal player."""
    times = [v.ideal_seconds for v in verdicts.values() if v.kind == "ordinary" and v.ideal_seconds]
    assert 20 <= statistics.median(times) <= 40


@pytest.mark.xfail(reason="the content isn't retuned per NPC yet (steps 2 and 3 of the tuning procedure); "
                          "python -m tools.balance_bot shows where each NPC stands", strict=False)
def test_every_sampled_npc_is_on_target(verdicts):
    off = {nid: v.why for nid, v in verdicts.items() if not v.ok}
    assert off == {}
