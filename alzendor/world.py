"""Access to the world in Redis: the game-rules library and the seed map."""

import json
import math
from pathlib import Path

from redis.asyncio import Redis

LUA_LIBRARY = Path(__file__).with_name("alzendor.lua")


class World:
    def __init__(self, redis: Redis):
        self.redis = redis

    async def load_rules(self) -> None:
        """Installs (or replaces) the game-rules function library in Redis."""
        await self.redis.function_load(LUA_LIBRARY.read_text(), replace=True)

    async def call(self, function: str, *args) -> int:
        """Runs one game-rules function atomically. See alzendor.lua."""
        return await self.redis.fcall(function, 0, *(str(a) for a in args))

    async def seed(self, path: Path) -> dict:
        """Loads the map from a seed file and returns it (for its ambient events)."""
        data = json.loads(Path(path).read_text(encoding="utf-8"))
        validate_seed(data)
        await self.call("seed", json.dumps(data))
        return data


DIRECTIONS = ("north", "south", "east", "west", "northeast", "northwest", "southeast", "southwest", "up", "down")
# Compass bearings (degrees anticlockwise from east) of the directions drawn on the map.
BEARINGS = {"east": 0, "northeast": 45, "north": 90, "northwest": 135, "west": 180, "southwest": 225, "south": 270, "southeast": 315}
OPPOSITE = {"north": "south", "south": "north", "east": "west", "west": "east", "up": "down", "down": "up",
            "northeast": "southwest", "southwest": "northeast", "northwest": "southeast", "southeast": "northwest"}
SLOTS = 3  # gear slots per player, as in alzendor.lua
DISPOSITIONS = ("hostile", "neutral", "friendly")
DEEDS = ("kill", "clean_kill", "ambush", "flee", "defeated", "heal", "greet", "taunt")  # see deed() in alzendor.lua
# How far an exit's line on the map may stray from its direction before it looks wrong.
BEARING_TOLERANCE = 10


def bearing_error(direction: str, start: list, end: list) -> float:
    """Degrees between an exit's direction and the line drawn for it (y grows south)."""
    angle = math.degrees(math.atan2(start[1] - end[1], end[0] - start[0])) % 360
    return abs((angle - BEARINGS[direction] + 180) % 360 - 180)


def validate_seed(data: dict) -> None:
    """Raises ValueError if the seed map refers to things that don't exist."""
    cities, areas, rooms = data.get("cities", {}), data.get("areas", {}), data.get("rooms", {})
    problems = []
    for aid, area in areas.items():
        if area.get("city") not in cities:
            problems.append(f"area {aid}: unknown city {area.get('city')!r}")
    for rid, room in rooms.items():
        for key in ("name", "description"):
            if not room.get(key):
                problems.append(f"room {rid}: missing {key}")
        if not _valid_pos(room):
            problems.append(f"room {rid}: pos must be [x, y]")
        if room.get("area") not in areas:
            problems.append(f"room {rid}: unknown area {room.get('area')!r}")
        for direction, dest in room.get("exits", {}).items():
            if direction not in DIRECTIONS:
                problems.append(f"room {rid}: unknown direction {direction!r}")
            if dest not in rooms:
                problems.append(f"room {rid}: exit {direction} leads to unknown room {dest!r}")
                continue
            if direction in BEARINGS and _valid_pos(room) and _valid_pos(rooms[dest]):
                error = bearing_error(direction, room["pos"], rooms[dest]["pos"])
                if error > BEARING_TOLERANCE:
                    problems.append(f"room {rid}: exit {direction} to {dest} is drawn {error:.0f}° off {direction}; move one of the rooms")
            back = [d for d, there in rooms[dest].get("exits", {}).items() if there == rid]
            if back and OPPOSITE.get(direction) not in back:
                problems.append(f"room {rid}: exit {direction} to {dest}, but the way back is {back[0]}, not {OPPOSITE.get(direction)}")
    for iid, item in data.get("items", {}).items():
        if item.get("room") not in rooms:
            problems.append(f"item {iid}: unknown room {item.get('room')!r}")
        if not item.get("name"):
            problems.append(f"item {iid}: missing name")
    gear, factions, perks = data.get("gear", {}), data.get("factions", {}), data.get("perks", {})
    for nid, npc in data.get("npcs", {}).items():
        if npc.get("room") not in rooms:
            problems.append(f"npc {nid}: unknown room {npc.get('room')!r}")
        if not npc.get("name"):
            problems.append(f"npc {nid}: missing name")
        problems += [f"npc {nid}: {problem}" for problem in _npc_problems(npc, factions, gear)]
    for fid, faction in factions.items():
        if not faction.get("name"):
            problems.append(f"faction {fid}: missing name")
        for rule in faction.get("rules", []):
            if rule.get("deed") not in DEEDS:
                problems.append(f"faction {fid}: unknown deed {rule.get('deed')!r} (deeds are {', '.join(DEEDS)})")
            if "of" in rule and rule["of"] not in factions:
                problems.append(f"faction {fid}: rule for unknown faction {rule['of']!r}")
    terrains = {room.get("terrain") for room in rooms.values()}
    for pid, perk in perks.items():
        if perk.get("safe_terrain") and perk["safe_terrain"] not in terrains:
            problems.append(f"perk {pid}: no room has terrain {perk['safe_terrain']!r}")
    for level, reward in data.get("levels", {}).items():
        if not level.isdigit() or int(level) < 2:
            problems.append(f"levels: {level!r} should be a level number from 2")
        problems += [f"levels {level}: unknown gear {g!r}" for g in reward.get("gear", []) if g not in gear]
        problems += [f"levels {level}: unknown perk {p!r}" for p in reward.get("perks", []) if p not in perks]
    for gid in data.get("starting_gear", []):
        if gid not in gear:
            problems.append(f"starting_gear: unknown gear {gid!r}")
    shrine = data.get("rules", {}).get("shrine_room")
    if shrine is not None and shrine not in rooms:
        problems.append(f"rules: shrine_room {shrine!r} is not a room")
    for gid, item in gear.items():
        problems += [f"gear {gid}: {problem}" for problem in _gear_problems(item)]
    loadout = data.get("loadout", [])
    if len(loadout) > SLOTS:
        problems.append(f"loadout: at most {SLOTS} slots")
    for gid in loadout:
        if gid not in gear:
            problems.append(f"loadout: unknown gear {gid!r}")
    if data.get("start_room") not in rooms:
        problems.append(f"start_room {data.get('start_room')!r} is not a room")
    for ambient in data.get("ambient", []):
        channel = ambient.get("channel", "")
        kind, _, cid = channel.partition(":")
        known = {"AREA": areas, "CITY": cities}.get(kind, {})
        if cid not in known:
            problems.append(f"ambient: unknown channel {channel!r}")
        if not ambient.get("texts") or int(ambient.get("every", 0)) <= 0:
            problems.append(f"ambient {channel}: needs texts and a positive 'every'")
    if problems:
        raise ValueError("Invalid seed map:\n  " + "\n  ".join(problems))


def _npc_problems(npc: dict, factions: dict, gear: dict) -> list[str]:
    problems = []
    if npc.get("disposition", "neutral") not in DISPOSITIONS:
        problems.append(f"disposition must be one of {', '.join(DISPOSITIONS)}")
    if npc.get("faction") and npc["faction"] not in factions:
        problems.append(f"unknown faction {npc['faction']!r}")
    for attack in npc.get("attacks", []):
        if not attack.get("name") or not attack.get("hit"):
            problems.append("each attack needs a name and hit text")
        if not all(isinstance(attack.get(key), int) and attack[key] > 0 for key in ("period", "damage")):
            problems.append(f"attack {attack.get('name')!r}: period and damage must be positive whole numbers")
    problems += [f"drops unknown gear {g!r}" for g in npc.get("drops", []) if g not in gear]
    return problems


def _gear_problems(gear: dict) -> list[str]:
    problems = []
    for key in ("name", "hit", "perfect_hit", "miss", "whiff"):
        if not gear.get(key):
            problems.append(f"missing {key}")
    if gear.get("effect") not in ("damage", "heal"):
        problems.append("effect must be 'damage' or 'heal'")
    period, window, perfect = (gear.get(key) for key in ("period", "window", "perfect_window"))
    if not all(isinstance(n, int) and n > 0 for n in (period, window, perfect)):
        problems.append("period, window and perfect_window must be positive whole ms")
    elif not perfect <= window < period / 2:
        problems.append("needs perfect_window <= window < half the period (windows can't overlap)")
    amounts = gear.get("amounts")
    if not (isinstance(amounts, list) and len(amounts) == 3 and all(isinstance(n, int) and n > 0 for n in amounts)):
        problems.append("amounts must be [opener, good, perfect], positive whole numbers")
    return problems


def _valid_pos(room: dict) -> bool:
    pos = room.get("pos")
    return isinstance(pos, list) and len(pos) == 2 and all(isinstance(n, (int, float)) for n in pos)
