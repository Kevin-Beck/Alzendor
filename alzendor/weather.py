"""The weather's random numbers, drawn from the seed, and a reference copy of
the weather function in alzendor.lua. See docs/weather.md.

Each realm has one sky. Each of its axes is a sum of five sine waves, evened
out to −1…1 with its measured distribution (101 quantiles), then (for
temperature and energy) stretched so a third of the time is spent in the
temperate middle.
"""

import bisect
import math
import random
from functools import lru_cache

AXES = ("temperature", "energy", "precipitation")
WAVES = 5
QUANTILES = 101
SAMPLES = 20000
CENTER = math.sqrt(1 / 3)  # each axis's share of the middle half, so the middle square gets 1/3


@lru_cache(maxsize=None)
def axis_params(weather_seed: str, realm: str, axis: str) -> dict:
    """The fixed waves of one axis, and the quantiles of their sum."""
    rng = random.Random(f"{weather_seed}:{realm}:{axis}")
    a = [rng.uniform(0.5, 1) for _ in range(WAVES)]
    w = [rng.uniform(0.1, 1) for _ in range(WAVES)]
    phase = [rng.uniform(0, 2 * math.pi) for _ in range(WAVES)]
    # Over a long time, incommensurate waves are like independent random phases.
    sample = sorted(sum(ak * math.sin(rng.uniform(0, 2 * math.pi)) for ak in a) for _ in range(SAMPLES))
    q = [sample[round(i * (SAMPLES - 1) / (QUANTILES - 1))] for i in range(QUANTILES)]
    return {"a": a, "w": w, "phase": phase, "q": q}


def realm_params(weather_seed: str, realm: str) -> dict:
    return {axis: axis_params(weather_seed, realm, axis) for axis in AXES}


def evened(params: dict, t: float) -> float:
    """Steps 1 and 2: the sum of waves at t, as a value spread evenly over −1…1."""
    r = sum(a * math.sin(w * t + ph) for a, w, ph in zip(params["a"], params["w"], params["phase"]))
    q = params["q"]
    if r <= q[0]:
        return -1.0
    if r >= q[-1]:
        return 1.0
    i = bisect.bisect_right(q, r) - 1
    span = q[i + 1] - q[i]
    f = (i + ((r - q[i]) / span if span > 0 else 0)) / (QUANTILES - 1)
    return 2 * f - 1


def stretch(u: float) -> float:
    """Step 3: sends u's middle 57.7% to −½…½ and the rest to the outer bands."""
    m = abs(u)
    x = m / (2 * CENTER) if m < CENTER else 0.5 + (m - CENTER) / (2 * (1 - CENTER))
    return math.copysign(x, u)


def weather(params: dict, t: float) -> dict:
    """A realm's weather at time t (in weather units), before the realm's centre and spread."""
    return {
        "temperature": stretch(evened(params["temperature"], t)),
        "energy": stretch(evened(params["energy"], t)),
        "precipitation": evened(params["precipitation"], t),
    }
