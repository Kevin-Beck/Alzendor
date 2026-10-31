"""Access to the world in Redis: the game-rules library and the seed map."""

import json
import math
from pathlib import Path

from redis.asyncio import Redis

from . import weather

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
        # Lua gets each realm's weather waves ready-made (see weather.py).
        weather_seed = str(data.get("rules", {}).get("weather_seed", "alzendor"))
        params = {realm: weather.realm_params(weather_seed, realm) for realm in data.get("realms", {})}
        await self.call("seed", json.dumps({**data, "weather_params": params}))
        return data


DIRECTIONS = ("north", "south", "east", "west", "northeast", "northwest", "southeast", "southwest", "up", "down")
# Compass bearings (degrees anticlockwise from east) of the directions drawn on the map.
BEARINGS = {"east": 0, "northeast": 45, "north": 90, "northwest": 135, "west": 180, "southwest": 225, "south": 270, "southeast": 315}
OPPOSITE = {"north": "south", "south": "north", "east": "west", "west": "east", "up": "down", "down": "up",
            "northeast": "southwest", "southwest": "northeast", "northwest": "southeast", "southeast": "northwest"}
SLOTS = 3  # gear slots per player, as in alzendor.lua
DISPOSITIONS = ("hostile", "neutral", "friendly")
DEEDS = ("kill", "clean_kill", "ambush", "flee", "defeated", "heal", "greet", "taunt")  # see deed() in alzendor.lua
STATS = ("vigor", "poise", "focus", "presence", "resilience")  # as in alzendor.lua
TIERS = ("grey", "green", "blue", "purple", "orange")  # see docs/weather.md
WETNESS = ("wet", "dry", "any")
# How far an exit's line on the map may stray from its direction before it looks wrong.
BEARING_TOLERANCE = 10
# Clear map units between the rooms of neighbouring areas, and of neighbouring
# regions in a realm, so their boxes never overlap (see docs/places.md).
AREA_GAP = 30
REGION_GAP = 40


def bearing_error(direction: str, start: list, end: list) -> float:
    """Degrees between an exit's direction and the line drawn for it (y grows south)."""
    angle = math.degrees(math.atan2(start[1] - end[1], end[0] - start[0])) % 360
    return abs((angle - BEARINGS[direction] + 180) % 360 - 180)


def validate_seed(data: dict) -> None:
    """Raises ValueError if the seed map refers to things that don't exist."""
    regions, areas, rooms = data.get("regions", {}), data.get("areas", {}), data.get("rooms", {})
    factions, realms = data.get("factions", {}), data.get("realms", {})
    problems = []
    if sum(1 for realm in realms.values() if realm.get("home")) != 1:
        problems.append("realms: exactly one realm must be the home realm")
    for rid, realm in realms.items():
        if not realm.get("name"):
            problems.append(f"realm {rid}: missing name")
        for axis, bias in realm.get("weather", {}).items():
            if axis not in weather.AXES or not (isinstance(bias, list) and len(bias) == 2 and _in_range(bias[0]) and 0 <= bias[1] <= 1):
                problems.append(f"realm {rid}: weather needs [centre, spread] for {', '.join(weather.AXES)} (centre -1 to 1, spread 0 to 1)")
    for gid, region in regions.items():
        if not region.get("name"):
            problems.append(f"region {gid}: missing name")
        if region.get("realm") not in realms:
            problems.append(f"region {gid}: unknown realm {region.get('realm')!r}")
        problems += [f"region {gid}: borders unknown region {b!r}" for b in region.get("borders", []) if b not in regions]
        reveal = region.get("reveal")
        if reveal is not None:
            if reveal.get("faction") not in factions:
                problems.append(f"region {gid}: reveal needs a known faction, not {reveal.get('faction')!r}")
            if not any(isinstance(reveal.get(key), int) for key in ("affinity", "respect")):
                problems.append(f"region {gid}: reveal needs an affinity or respect threshold")
    for aid, area in areas.items():
        if area.get("region") not in regions:
            problems.append(f"area {aid}: unknown region {area.get('region')!r}")
        if "climate" in area:
            problems += [f"area {aid}: {problem}" for problem in _climate_problems(area["climate"])]
    for terrain, nudge in data.get("terrain_weather", {}).items():
        problems += [f"terrain_weather {terrain}: unknown axis {axis!r}" for axis in nudge if axis not in weather.AXES]
    kinds = data.get("kinds", {})
    for kind, profile in kinds.items():
        problems += [f"kinds {kind}: {problem}" for problem in _profile_problems(profile)]
    for rid, room in rooms.items():
        for key in ("name", "description"):
            if not room.get(key):
                problems.append(f"room {rid}: missing {key}")
        if not _valid_pos(room):
            problems.append(f"room {rid}: pos must be [x, y]")
        if room.get("area") not in areas:
            problems.append(f"room {rid}: unknown area {room.get('area')!r}")
        if "climate" in room:
            problems += [f"room {rid}: {problem}" for problem in _climate_problems(room["climate"])]
            if room.get("indoor"):
                problems.append(f"room {rid}: indoor rooms are always neutral; give a climate only to exceptional places")
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
            if _realm_of(room, areas, regions) != _realm_of(rooms[dest], areas, regions):
                problems.append(f"room {rid}: exit {direction} leads into another realm; realms are joined only by gates and passages")
            back = [d for d, there in rooms[dest].get("exits", {}).items() if there == rid]
            if back and OPPOSITE.get(direction) not in back:
                problems.append(f"room {rid}: exit {direction} to {dest}, but the way back is {back[0]}, not {OPPOSITE.get(direction)}")
    problems += _overlap_problems(rooms, areas, regions)
    for iid, item in data.get("items", {}).items():
        if item.get("room") not in rooms:
            problems.append(f"item {iid}: unknown room {item.get('room')!r}")
        if not item.get("name"):
            problems.append(f"item {iid}: missing name")
        problems += [f"item {iid}: reveals unknown region {g!r}" for g in item.get("reveals", []) if g not in regions]
        problems += [f"item {iid}: forecasts unknown realm {r!r}" for r in item.get("forecasts", []) if r not in realms]
    gear, perks = data.get("gear", {}), data.get("perks", {})
    for nid, npc in data.get("npcs", {}).items():
        if npc.get("room") not in rooms:
            problems.append(f"npc {nid}: unknown room {npc.get('room')!r}")
        if not npc.get("name"):
            problems.append(f"npc {nid}: missing name")
        problems += [f"npc {nid}: {problem}" for problem in _npc_problems(npc, factions, gear)]
        problems += [f"npc {nid}: forecasts unknown realm {r!r}" for r in npc.get("forecasts", []) if r not in realms]
        problems += [f"npc {nid}: active_when {problem}" for problem in _ranges_problems(npc.get("active_when", {}))]
    for fid, faction in factions.items():
        if not faction.get("name"):
            problems.append(f"faction {fid}: missing name")
        if "realm" in faction and faction["realm"] not in realms:
            problems.append(f"faction {fid}: unknown realm {faction['realm']!r}")
        for rule in faction.get("rules", []):
            if rule.get("deed") not in DEEDS:
                problems.append(f"faction {fid}: unknown deed {rule.get('deed')!r} (deeds are {', '.join(DEEDS)})")
            if "of" in rule and rule["of"] not in factions:
                problems.append(f"faction {fid}: rule for unknown faction {rule['of']!r}")
        for boon in faction.get("boons", []):
            if boon.get("stat") not in STATS:
                problems.append(f"faction {fid}: boon for unknown stat {boon.get('stat')!r}")
            if not any(isinstance(boon.get(key), int) for key in ("affinity", "respect")):
                problems.append(f"faction {fid}: boon needs an affinity or respect threshold")
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
        if "weather" in item:
            problems += [f"gear {gid}: weather {problem}" for problem in _profile_problems(item["weather"])]
        elif item.get("kind") not in kinds:
            problems.append(f"gear {gid}: no weather profile, and kind {item.get('kind')!r} has no default in 'kinds'")
    loadout = data.get("loadout", [])
    if len(loadout) > SLOTS:
        problems.append(f"loadout: at most {SLOTS} slots")
    for gid in loadout:
        if gid not in gear:
            problems.append(f"loadout: unknown gear {gid!r}")
    destinations = {}  # players take a route by typing TRAVEL and where it goes
    for route_id, route in data.get("routes", {}).items():
        problems += [f"route {route_id}: {problem}" for problem in _route_problems(route, rooms, data.get("npcs", {}))]
        place = (route.get("from"), rooms.get(route.get("to"), {}).get("name", "").lower())
        if place in destinations:
            problems.append(f"route {route_id}: goes to {place[1]!r} like route {destinations[place]}; "
                            "routes from one room need different destinations")
        destinations.setdefault(place, route_id)
    if data.get("start_room") not in rooms:
        problems.append(f"start_room {data.get('start_room')!r} is not a room")
    for ambient in data.get("ambient", []):
        channel = ambient.get("channel", "")
        kind, _, cid = channel.partition(":")
        known = {"AREA": areas, "REGION": regions, "REALM": realms}.get(kind, {})
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


def _route_problems(route: dict, rooms: dict, npcs: dict) -> list[str]:
    """Routes are every jump: ferries, coaches, portals and gates (see docs/places.md)."""
    problems = []
    if not route.get("name"):
        problems.append("missing name")
    for key in ("from", "to"):
        if route.get(key) not in rooms:
            problems.append(f"{key} is not a room: {route.get(key)!r}")
    if "by" in route and npcs.get(route["by"], {}).get("room") != route.get("from"):
        problems.append(f"its operator {route['by']!r} must be an NPC in the room it leaves from")
    if "via" in route and route["via"] not in rooms:
        problems.append(f"via is not a room: {route['via']!r}")
    if not isinstance(route.get("fare", 0), int) or route.get("fare", 0) < 0:
        problems.append("fare must be a whole number of coins")
    stages = route.get("stages", [])
    if stages and "via" not in route:
        problems.append("a journey with stages needs a 'via' room to travel in")
    for stage in stages:
        text = stage.get("text") if isinstance(stage, dict) else stage
        if not isinstance(text, str) or not text:
            problems.append("each stage is a line of text, or {text, event}")
    problems += [f"when {problem}" for problem in _ranges_problems(route.get("when", {}))]
    return problems


def _overlap_problems(rooms: dict, areas: dict, regions: dict) -> list[str]:
    """Areas and regions whose boxes on the map would overlap. A box is drawn
    around a place's rooms, so a room of one area must never fall inside, or
    too near, another's box."""
    boxes = {"area": {}, "region": {}}
    for room in rooms.values():
        if not _valid_pos(room) or room.get("area") not in areas:
            continue
        x, y = room["pos"]
        for kind, place in (("area", room["area"]), ("region", areas[room["area"]].get("region"))):
            x1, y1, x2, y2 = boxes[kind].get(place, (x, y, x, y))
            boxes[kind][place] = (min(x1, x), min(y1, y), max(x2, x), max(y2, y))
    realm = {"area": lambda aid: regions.get(areas[aid].get("region"), {}).get("realm"),
             "region": lambda gid: regions.get(gid, {}).get("realm")}
    problems = []
    for kind, gap in (("area", AREA_GAP), ("region", REGION_GAP)):
        places = sorted(boxes[kind])
        for i, one in enumerate(places):
            for other in places[i + 1:]:
                if realm[kind](one) != realm[kind](other):
                    continue
                a, b = boxes[kind][one], boxes[kind][other]
                apart = max(b[0] - a[2], a[0] - b[2], b[1] - a[3], a[1] - b[3])
                if apart < gap:
                    problems.append(f"{kind} {one}: its rooms are {max(apart, 0):g} units from {kind} {other}'s on the map; "
                                    f"keep at least {gap} so their boxes don't overlap")
    return problems


def _realm_of(room: dict, areas: dict, regions: dict):
    region = regions.get(areas.get(room.get("area"), {}).get("region"), {})
    return region.get("realm")


def _ranges_problems(ranges: dict) -> list[str]:
    for axis, bounds in ranges.items():
        if axis not in weather.AXES or not (isinstance(bounds, list) and len(bounds) == 2 and bounds[0] <= bounds[1]):
            return [f"needs [low, high] ranges for {', '.join(weather.AXES)}"]
    return []


def _in_range(value) -> bool:
    return isinstance(value, (int, float)) and -1 <= value <= 1


def _climate_problems(climate: dict) -> list[str]:
    if all(_in_range(climate.get(axis)) for axis in weather.AXES):
        return []
    return [f"climate needs {', '.join(weather.AXES)}, each from -1 to 1"]


def _profile_problems(profile: dict) -> list[str]:
    problems = []
    if not all(_in_range(profile.get(axis)) for axis in ("temperature", "energy")):
        problems.append("needs temperature and energy from -1 to 1")
    if profile.get("precipitation", "any") not in WETNESS:
        problems.append(f"precipitation must be one of {', '.join(WETNESS)}")
    if profile.get("tier", "grey") not in TIERS:
        problems.append(f"tier must be one of {', '.join(TIERS)}")
    return problems


def _valid_pos(room: dict) -> bool:
    pos = room.get("pos")
    return isinstance(pos, list) and len(pos) == 2 and all(isinstance(n, (int, float)) for n in pos)
