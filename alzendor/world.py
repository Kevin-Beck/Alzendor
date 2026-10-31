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
        self.creation: dict = {}  # what the character creation screen offers, once seeded

    async def load_rules(self) -> None:
        """Installs (or replaces) the game-rules function library in Redis."""
        await self.redis.function_load(LUA_LIBRARY.read_text(), replace=True)

    async def call(self, function: str, *args) -> int:
        """Runs one game-rules function atomically. See alzendor.lua."""
        return await self.redis.fcall(function, 0, *(str(a) for a in args))

    async def seed(self, path: Path) -> dict:
        """Loads the map from a seed file (and its zone files) and returns it (for its ambient events)."""
        data = load_seed(path)
        validate_seed(data)
        # Lua gets each realm's weather waves ready-made (see weather.py).
        weather_seed = str(data.get("rules", {}).get("weather_seed", "alzendor"))
        params = {realm: weather.realm_params(weather_seed, realm) for realm in data.get("realms", {})}
        await self.call("seed", json.dumps({**data, "weather_params": params}))
        self.creation = creation_options(data)
        return data


def load_seed(path: Path) -> dict:
    """The seed file, plus every zone file in the zones/ folder beside it
    (docs/zones.md), merged: each zone adds its own realms, regions, areas,
    rooms, NPCs, quests and so on. A zone can't redefine anything (ids must be
    new), so changes to existing places belong in the seed file. Keys starting
    with _ are notes."""
    path = Path(path)
    data = json.loads(path.read_text(encoding="utf-8"))
    for zone in sorted((path.parent / "zones").glob("*.json")):
        for key, value in json.loads(zone.read_text(encoding="utf-8")).items():
            if key.startswith("_"):
                continue
            if isinstance(value, dict):
                into = data.setdefault(key, {})
                clash = sorted(set(into) & set(value))
                if clash:
                    raise ValueError(f"Invalid seed map:\n  {zone.name}: {key} already has {', '.join(clash)}")
                into.update(value)
            elif isinstance(value, list):
                data.setdefault(key, []).extend(value)
            else:
                raise ValueError(f"Invalid seed map:\n  {zone.name}: {key} must be an object or a list")
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
TIERS = ("grey", "green", "blue", "purple", "orange")  # weather sensitivity 1-5, see docs/weather.md
RARITIES = ("common", "uncommon", "rare", "epic", "legendary")
DEFENCES = ("both", "block", "dodge", "none")  # how an NPC attack can be met, see docs/combat.md
PLACES = ("head", "chest", "legs", "hand")  # where worn gear goes, see docs/characters.md
WEAR_TYPES = ("cloth", "leather", "mail", "shield", "light", "orb")
PHASES = ("dawn", "day", "dusk", "night")  # of the clock, as in alzendor.lua
WETNESS = ("wet", "dry", "any")
# How far an exit's line on the map may stray from its direction before it looks wrong.
BEARING_TOLERANCE = 10
ROUTE_KINDS = ("coach", "ferry", "portal", "rift")
DIFFICULTIES = ("easy", "fair", "hard")  # as in alzendor.lua
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
        if realm.get("shrine") is not None and (realm["shrine"] not in rooms or rooms[realm["shrine"]].get("waypoint")):
            problems.append(f"realm {rid}: shrine {realm['shrine']!r} is not a room you can stand in")
        if realm.get("sky", "") not in ("", "always_day", "always_dusk", "always_night"):
            problems.append(f"realm {rid}: sky must be always_day, always_dusk or always_night")
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
        if "exposure" in area:
            e = area["exposure"]
            if not e.get("kind") or not all(isinstance(e.get(k, 1), int) and e.get(k, 1) > 0 for k in ("max", "damage")):
                problems.append(f"area {aid}: exposure needs a kind, and whole positive max and damage")
            worse = dict(e.get("worse_when", {}))
            problems += [f"area {aid}: exposure worse_when time {p!r} isn't a phase" for p in worse.pop("time", []) if p not in PHASES]
            problems += [f"area {aid}: exposure worse_when {p}" for p in _ranges_problems(worse)]
    for terrain, ground in data.get("terrain_ground", {}).items():
        if ground not in ("open", "rough"):
            problems.append(f"terrain_ground {terrain}: must be open or rough")
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
        if "trap" in room:
            problems += [f"room {rid}: trap {problem}" for problem in _trap_problems(room, rooms)]
        if room.get("waypoint") and room.get("exits"):
            problems.append(f"room {rid}: a waypoint has no exits; you only pass through it on a route")
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
            if rooms[dest].get("waypoint"):
                problems.append(f"room {rid}: exit {direction} leads to a waypoint; waypoints are only reached by routes")
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
        if item.get("room") not in rooms and not (item.get("quest") and "room" not in item):  # quests can hand items out
            problems.append(f"item {iid}: unknown room {item.get('room')!r}")
        if not item.get("name"):
            problems.append(f"item {iid}: missing name")
        problems += [f"item {iid}: reveals unknown region {g!r}" for g in item.get("reveals", []) if g not in regions]
        problems += [f"item {iid}: forecasts unknown realm {r!r}" for r in item.get("forecasts", []) if r not in realms]
    gear, perks = data.get("gear", {}), data.get("perks", {})
    for nid, npc in data.get("npcs", {}).items():
        if npc.get("template") and "room" in npc:
            problems.append(f"npc {nid}: a template has no room (ambushes place its copies)")
        elif not npc.get("template") and npc.get("room") not in rooms:
            problems.append(f"npc {nid}: unknown room {npc.get('room')!r}")
        if not npc.get("name"):
            problems.append(f"npc {nid}: missing name")
        problems += [f"npc {nid}: {problem}" for problem in _npc_problems(npc, factions, gear)]
        problems += [f"npc {nid}: forecasts unknown realm {r!r}" for r in npc.get("forecasts", []) if r not in realms]
        when = dict(npc.get("active_when", {}))
        phases = when.pop("time", [])
        problems += [f"npc {nid}: active_when {problem}" for problem in _ranges_problems(when)]
        problems += [f"npc {nid}: active_when time {p!r} isn't one of {', '.join(PHASES)}" for p in phases if p not in PHASES]
        if npc.get("notice", "fair") not in DIFFICULTIES:
            problems.append(f"npc {nid}: notice must be one of {', '.join(DIFFICULTIES)}")
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
    problems += _character_problems(data)
    for gid in data.get("starting_gear", []):
        if gid not in gear:
            problems.append(f"starting_gear: unknown gear {gid!r}")
    shrine = data.get("rules", {}).get("shrine_room")
    if shrine is not None and shrine not in rooms:
        problems.append(f"rules: shrine_room {shrine!r} is not a room")
    for gid, item in gear.items():
        problems += [f"gear {gid}: {problem}" for problem in _gear_problems(item)]
        if item.get("rarity", "common") not in RARITIES:
            problems.append(f"gear {gid}: rarity must be one of {', '.join(RARITIES)}")
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
        problems += [f"route {route_id}: {problem}" for problem in _route_problems(route, rooms, data.get("npcs", {}), data.get("travel_events", {}))]
        place = (route.get("from"), rooms.get(route.get("to"), {}).get("name", "").lower())
        if place in destinations:
            problems.append(f"route {route_id}: goes to {place[1]!r} like route {destinations[place]}; "
                            "routes from one room need different destinations")
        destinations.setdefault(place, route_id)
        if "quest" in route:
            # Offered only while the player is at that step of the quest (TRAVEL lists it then).
            steps = data.get("quests", {}).get(route["quest"], {}).get("steps", {})
            if route.get("step") not in steps:
                problems.append(f"route {route_id}: offered for a quest step that doesn't exist: {route['quest']!r} {route.get('step')!r}")
    for quest_id, quest in data.get("quests", {}).items():
        problems += [f"quest {quest_id}: {problem}" for problem in _quest_problems(quest, data)]
    for nid, npc in data.get("npcs", {}).items():
        for topic, said in npc.get("topics", {}).items():
            if isinstance(said, dict) and not said.get("text"):
                problems.append(f"npc {nid}: topic {topic!r} needs text")
            if isinstance(said, dict) and "starts" in said and said["starts"] not in data.get("quests", {}):
                problems.append(f"npc {nid}: topic {topic!r} starts unknown quest {said.get('starts')!r}")
    for event_id, event in data.get("travel_events", {}).items():
        problems += [f"travel event {event_id}: {problem}" for problem in _event_problems(event, data)]
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
        if attack.get("defend", "both") not in DEFENCES:
            problems.append(f"attack {attack.get('name')!r}: defend must be one of {', '.join(DEFENCES)}")
    problems += [f"drops unknown gear {g!r}" for g in npc.get("drops", []) if g not in gear]
    return problems


def _gear_problems(gear: dict) -> list[str]:
    problems = []
    for key in ("name", "hit", "perfect_hit", "miss", "whiff"):
        if not gear.get(key):
            problems.append(f"missing {key}")
    if gear.get("effect") not in ("damage", "heal", "guard"):
        problems.append("effect must be 'damage', 'heal' or 'guard'")
    period, window, perfect = (gear.get(key) for key in ("period", "window", "perfect_window"))
    if not all(isinstance(n, int) and n > 0 for n in (period, window, perfect)):
        problems.append("period, window and perfect_window must be positive whole ms")
    elif not perfect <= window < period / 2:
        problems.append("needs perfect_window <= window < half the period (windows can't overlap)")
    amounts = gear.get("amounts")
    if not (isinstance(amounts, list) and len(amounts) == 3 and all(isinstance(n, int) and n > 0 for n in amounts)):
        problems.append("amounts must be [opener, good, perfect], positive whole numbers")
    return problems


EFFECTS = ("text", "delay", "hasten", "coins", "xp", "hp", "reputation", "discover", "rumour", "boon", "death",
           "strand", "ambush", "maroon")


def _event_problems(event: dict, data: dict) -> list[str]:
    """Travel events (docs/journeys.md): pools, conditions, and choices with outcomes."""
    problems = []
    realms, routes, npcs = data.get("realms", {}), data.get("routes", {}), data.get("npcs", {})
    backgrounds = data.get("backgrounds", {})
    if not event.get("text"):
        problems.append("needs text")
    for pool in event.get("pools", ["any"]):
        if pool != "any" and pool not in ROUTE_KINDS and pool not in routes and pool not in realms:
            problems.append(f"unknown pool {pool!r} (a route, a route kind, a realm, or 'any')")
    when = dict(event.get("when", {}))
    for phase in when.pop("time", []):
        if phase not in ("dawn", "day", "dusk", "night"):
            problems.append(f"unknown time {phase!r}")
    severity = when.pop("severity", None)
    if severity is not None and not (isinstance(severity, list) and len(severity) == 2):
        problems.append("severity needs [low, high]")
    problems += _ranges_problems(when)
    choices = event.get("choices", [])
    if not 2 <= len(choices) <= 4:
        problems.append("needs two to four choices")
    for i, choice in enumerate(choices, 1):
        if not choice.get("label"):
            problems.append(f"choice {i} needs a label")
        check = choice.get("check")
        if check and (check.get("stat") not in STATS or check.get("difficulty", "fair") not in DIFFICULTIES):
            problems.append(f"choice {i}: check needs a stat and a difficulty")
        for key in ("background", "bonus"):
            if key in choice and backgrounds and choice[key] not in backgrounds:
                problems.append(f"choice {i}: unknown background {choice[key]!r}")
        for outcome in ("success", "failure"):
            for effect in choice.get(outcome, []):
                for name, value in effect.items():
                    if name not in EFFECTS:
                        problems.append(f"choice {i}: unknown effect {name!r}")
                    elif name == "ambush" and not all(npcs.get(t, {}).get("template") for t in value):
                        problems.append(f"choice {i}: ambush needs template NPCs")
                    elif name == "reputation" and value.get("faction") not in data.get("factions", {}):
                        problems.append(f"choice {i}: unknown faction {value.get('faction')!r}")
                    elif name == "discover" and value not in data.get("regions", {}):
                        problems.append(f"choice {i}: unknown region {value!r}")
                    elif name == "rumour" and value not in realms:
                        problems.append(f"choice {i}: unknown realm {value!r}")
                    elif name == "maroon" and (value.get("room") not in data.get("rooms", {})
                                               or not data.get("quests", {}).get(value.get("quest"), {}).get("priority")):
                        problems.append(f"choice {i}: maroon needs a room and a priority quest")
                    elif name == "boon" and value.get("stat") not in STATS:
                        problems.append(f"choice {i}: boon needs a stat")
        if not choice.get("success"):
            problems.append(f"choice {i} needs a success outcome")
    return problems


TRIGGERS = ("ask", "get", "enter", "kill", "use", "have", "level", "in", "travel")
QUEST_EFFECTS = EFFECTS + ("give", "take", "start", "teleport", "resume_journey", "leave_start", "say", "by", "guide")


def _quest_problems(quest: dict, data: dict) -> list[str]:
    """Quests are small state machines (docs/quests.md): every step reachable, every quest able to end."""
    problems, steps = [], quest.get("steps", {})
    rooms, items, npcs = data.get("rooms", {}), data.get("items", {}), data.get("npcs", {})
    if not quest.get("name"):
        problems.append("needs a name")
    if quest.get("start") not in steps:
        problems.append(f"start {quest.get('start')!r} is not a step")
    if quest.get("priority") and quest.get("area") not in data.get("areas", {}):
        problems.append("a priority quest needs the area it belongs to")
    if ("giver" in quest or "offer" in quest) and (quest.get("giver") not in npcs or not quest.get("offer")):
        problems.append("a quest's offer needs a giver (an NPC) and what they say")
    reached, todo, ends = set(), [quest.get("start")], False
    while todo:
        step_id = todo.pop()
        if step_id in reached or step_id not in steps:
            continue
        reached.add(step_id)
        nxt = steps[step_id].get("then")
        if nxt:
            todo.append(nxt)
        else:
            ends = True
    if not ends:
        problems.append("never ends (some step needs no 'then')")
    for step_id, step in steps.items():
        if step_id not in reached:
            problems.append(f"step {step_id} can't be reached")
        if step.get("then") and step["then"] not in steps:
            problems.append(f"step {step_id}: then {step['then']!r} is not a step")
        on = step.get("on", {})
        kinds = [k for k in on if k in TRIGGERS]
        if len(kinds) != 1:
            problems.append(f"step {step_id}: 'on' needs exactly one of {', '.join(TRIGGERS)}")
        for key in ("enter", "in"):
            if key in on and on[key] not in rooms:
                problems.append(f"step {step_id}: unknown room {on[key]!r}")
        for item in ([on["get"]] if "get" in on else []) + ([on["use"]] if "use" in on else []) + on.get("have", []):
            if item not in items:
                problems.append(f"step {step_id}: unknown item {item!r}")
        if "ask" in on and on["ask"] not in npcs:
            problems.append(f"step {step_id}: unknown NPC {on['ask']!r}")
        if "travel" in on and on["travel"] not in data.get("routes", {}):
            problems.append(f"step {step_id}: unknown route {on['travel']!r}")
        for effect in step.get("effects", []):
            for name, value in effect.items():
                if name not in QUEST_EFFECTS:
                    problems.append(f"step {step_id}: unknown effect {name!r}")
                elif name == "give" and value not in items and value not in data.get("wearables", {}) and value not in data.get("gear", {}):
                    problems.append(f"step {step_id}: unknown item, gear or worn gear {value!r}")
                elif name == "take" and value not in items:
                    problems.append(f"step {step_id}: unknown item {value!r}")
                elif name == "teleport" and value not in rooms:
                    problems.append(f"step {step_id}: unknown room {value!r}")
                elif name == "start" and value not in data.get("quests", {}):
                    problems.append(f"step {step_id}: unknown quest {value!r}")
                elif name == "say" and effect.get("by") not in npcs:
                    problems.append(f"step {step_id}: say needs who says it, by: an NPC")
    return problems


def _character_problems(data: dict) -> list[str]:
    """Classes, ancestries and backgrounds (docs/characters.md)."""
    problems = []
    gear, perks, rooms, kinds = data.get("gear", {}), data.get("perks", {}), data.get("rooms", {}), data.get("kinds", {})
    for cid, c in data.get("classes", {}).items():
        if not c.get("name") or c.get("ability") not in gear:
            problems.append(f"class {cid}: needs a name and an ability (gear)")
        problems += [f"class {cid}: unknown gear kind {k!r}" for k in c.get("kinds", []) if k not in kinds]
        if c.get("ability") in gear and gear[c["ability"]].get("kind") not in c.get("kinds", []):
            problems.append(f"class {cid}: can't use its own ability")
        for tid in c.get("talents", []):
            talent = gear.get(tid)
            if not talent or talent.get("rank") not in (1, 2, 3):
                problems.append(f"class {cid}: talent {tid!r} must be gear with a rank of 1, 2 or 3")
            elif talent.get("kind") not in c.get("kinds", []):
                problems.append(f"class {cid}: talent {tid!r} is a kind the class can't use")
            elif talent.get("requires") and talent["requires"] not in c.get("talents", []):
                problems.append(f"class {cid}: talent {tid!r} requires a talent outside the class")
        problems += [f"class {cid}: unknown worn gear type {t!r}" for t in c.get("wears", []) if t not in WEAR_TYPES]
    wearables = data.get("wearables", {})
    for wid, w in wearables.items():
        if not w.get("name") or w.get("place") not in PLACES or w.get("type") not in WEAR_TYPES:
            problems.append(f"wearable {wid}: needs a name, a place ({', '.join(PLACES)}) and a type ({', '.join(WEAR_TYPES)})")
        if w.get("rarity", "common") not in RARITIES:
            problems.append(f"wearable {wid}: rarity must be one of {', '.join(RARITIES)}")
        if not isinstance(w.get("armor", 0), int) or w.get("armor", 0) < 0:
            problems.append(f"wearable {wid}: armor must be a whole number, 0 or more")
        problems += [f"wearable {wid}: unknown stat {s!r}" for s in w.get("stats", {}) if s not in STATS]
        if (w.get("type") in ("shield", "light", "orb")) != (w.get("place") == "hand"):
            problems.append(f"wearable {wid}: shields, lights and orbs (and only they) go in the hand")
        if w.get("light") and w.get("type") != "light":
            problems.append(f"wearable {wid}: only a light gives light")
        if not isinstance(w.get("protects", []), list):
            problems.append(f"wearable {wid}: protects is a list of exposure kinds")
    for owner, outfits in (("class", data.get("classes", {})), ("background", data.get("backgrounds", {}))):
        for oid, o in outfits.items():
            problems += [f"{owner} {oid}: unknown worn gear {w!r}" for w in o.get("outfit", []) if w not in wearables]
    for aid, a in data.get("ancestries", {}).items():
        if not a.get("name") or a.get("stat") not in STATS:
            problems.append(f"ancestry {aid}: needs a name and a stat")
        problems += [f"ancestry {aid}: unknown passive {p!r}" for p in a.get("passives", []) if p not in perks]
    for bid, b in data.get("backgrounds", {}).items():
        if not b.get("name"):
            problems.append(f"background {bid}: needs a name")
        problems += [f"background {bid}: unknown item {g!r}" for g in b.get("items", []) if g not in gear]
        for key in ("start", "arrive"):
            if b.get(key) not in rooms or rooms[b[key]].get("waypoint"):
                problems.append(f"background {bid}: {key} is not a room: {b.get(key)!r}")
        for cid, c in data.get("classes", {}).items():
            usable = [g for g in b.get("items", []) if gear.get(g, {}).get("kind") in c.get("kinds", [])]
            if len(usable) < 2:
                problems.append(f"background {bid}: a {cid} can use fewer than two of its items")
        for o in b.get("opinions", []):
            if o.get("faction") not in data.get("factions", {}):
                problems.append(f"background {bid}: unknown faction {o.get('faction')!r}")
    return problems


def creation_options(data: dict) -> dict:
    """What the character creation screen offers, from the seed."""
    gear, perks, realms = data.get("gear", {}), data.get("perks", {}), data.get("realms", {})

    def gear_card(gid):
        g = gear.get(gid, {})
        return {"id": gid, "name": g.get("name", gid), "kind": g.get("kind"), "description": g.get("description", "")}

    classes = [{"id": cid, "name": c["name"], "description": c.get("description", ""), "ability": gear_card(c["ability"]),
                "kinds": c.get("kinds", [])} for cid, c in data.get("classes", {}).items()]
    ancestries = [{"id": aid, "name": a["name"], "description": a.get("description", ""), "stat": a["stat"],
                   "passives": [{"id": p, "name": perks[p]["name"], "description": perks[p].get("description", "")}
                                for p in a.get("passives", [])]} for aid, a in data.get("ancestries", {}).items()]
    backgrounds = []
    for bid, b in data.get("backgrounds", {}).items():
        start = data["rooms"].get(b["start"], {})
        region = data["regions"].get(data["areas"].get(start.get("area"), {}).get("region"), {})
        items = {cid: [gear_card(g) for g in b.get("items", []) if gear.get(g, {}).get("kind") in c.get("kinds", [])][:2]
                 for cid, c in data.get("classes", {}).items()}
        backgrounds.append({"id": bid, "name": b["name"], "description": b.get("description", ""), "coins": b.get("coins", 0),
                            "items": items, "start": realms.get(region.get("realm"), {}).get("name", "")})
    return {"classes": classes, "ancestries": ancestries, "backgrounds": backgrounds}


def _trap_problems(room: dict, rooms: dict) -> list[str]:
    """A trap needs a stat to avoid it and a sign next door (docs/journeys.md)."""
    trap, problems = room["trap"], []
    if not trap.get("name"):
        problems.append("needs a name")
    if trap.get("stat", "poise") not in STATS:
        problems.append(f"stat must be one of {', '.join(STATS)}")
    if trap.get("difficulty", "fair") not in DIFFICULTIES:
        problems.append(f"difficulty must be one of {', '.join(DIFFICULTIES)}")
    sign = trap.get("sign", {})
    if not (sign.get("name") and sign.get("text")) or sign.get("room") not in room.get("exits", {}).values():
        problems.append("needs a sign {room, name, text} in a room next door")
    return problems


def _route_problems(route: dict, rooms: dict, npcs: dict, data_events: dict) -> list[str]:
    """Routes are every jump: ferries, coaches, portals and gates (see docs/places.md)."""
    problems = []
    if not route.get("name"):
        problems.append("missing name")
    for key in ("from", "to"):
        if route.get(key) not in rooms:
            problems.append(f"{key} is not a room: {route.get(key)!r}")
    if "by" in route and npcs.get(route["by"], {}).get("room") != route.get("from"):
        problems.append(f"its operator {route['by']!r} must be an NPC in the room it leaves from")
    if not isinstance(route.get("fare", 0), int) or route.get("fare", 0) < 0:
        problems.append("fare must be a whole number of coins")
    if route.get("kind", "") not in ROUTE_KINDS:
        problems.append(f"kind must be one of {', '.join(ROUTE_KINDS)}")
    for waypoint in route.get("path", []):
        if not rooms.get(waypoint, {}).get("waypoint"):
            problems.append(f"path: {waypoint!r} is not a waypoint room")
    for key in ("from", "to", "strand"):
        if rooms.get(route.get(key), {}).get("waypoint"):
            problems.append(f"{key} can't be a waypoint")
    if route.get("events") and not all(e in data_events for e in route["events"]):
        problems.append("events must be travel events")
    if "strand" in route and route["strand"] not in rooms:
        problems.append(f"strand is not a room: {route['strand']!r}")
    problems += [f"when {problem}" for problem in _ranges_problems(route.get("when", {}))]
    return problems


def _overlap_problems(rooms: dict, areas: dict, regions: dict) -> list[str]:
    """Areas and regions whose boxes on the map would overlap. A box is drawn
    around a place's rooms, so a room of one area must never fall inside, or
    too near, another's box."""
    boxes = {"area": {}, "region": {}}
    for room in rooms.values():
        if not _valid_pos(room) or room.get("area") not in areas or room.get("waypoint"):
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
