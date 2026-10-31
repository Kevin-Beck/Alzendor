"""Player commands.

Each command is one handler registered with @command; the parser and `help`
both work from that registry. Handlers check the shape of the input and then
call one game-rules function (alzendor.lua), which checks it against the world
and publishes the outcome. Nothing a handler does is sent to the client
directly: replies are events on the player's own channel, like everything else.

Commands are shown to players in capitals (TRAVEL VILLAGE GREEN), so they
stand out from the text around them, and accepted in any case. In usages,
lowercase words are what you fill in.
"""

import re
from collections.abc import Awaitable, Callable
from dataclasses import dataclass, field

from .world import DIRECTIONS, World

MAX_INPUT = 500
CHANNEL_RE = re.compile(r"^[a-z0-9][a-z0-9_-]{1,23}$")
TARGET_RE = re.compile(r"^(pc|npc):[a-z0-9_~-]{1,80}$")  # ~ joins an ambusher's template, owner and number
SHORT_DIRECTIONS = {
    "n": "north", "s": "south", "e": "east", "w": "west",
    "ne": "northeast", "nw": "northwest", "se": "southeast", "sw": "southwest",
    "u": "up", "d": "down",
}


class Usage(Exception):
    """Raised by a handler to reply with a hint instead of acting."""


@dataclass
class Context:
    world: World
    pid: str
    is_admin: bool = False
    # Ends this player's session; True also revokes the session token.
    quit: Callable[[bool], Awaitable[None]] | None = None
    # The entity the client has selected ('pc:<id>' or 'npc:<id>'), used by
    # commands that take a target when none is typed.
    target: str = ""

    async def call(self, function: str, *args) -> int:
        return await self.world.call(function, self.pid, *args)

    async def reply(self, text: str) -> None:
        await self.call("notify", text)


Handler = Callable[[Context, str], Awaitable[None]]


@dataclass(frozen=True)
class Command:
    name: str
    usage: str
    summary: str
    handler: Handler
    aliases: tuple[str, ...] = ()
    admin: bool = False


COMMANDS: dict[str, Command] = {}
ALIASES: dict[str, str] = {}


def command(name: str, usage: str, summary: str, aliases: tuple[str, ...] = (), admin: bool = False):
    def register(handler: Handler) -> Handler:
        COMMANDS[name] = Command(name, usage, summary, handler, aliases, admin)
        for alias in aliases:
            ALIASES[alias] = name
        return handler

    return register


def target_id(value) -> str:
    """A client-selected target, if it's a well-formed entity id."""
    return value if isinstance(value, str) and TARGET_RE.match(value) else ""


def clean(text: str) -> str:
    text = "".join(ch for ch in text if ch.isprintable())
    return " ".join(text.split())[:MAX_INPUT]


def parse(text: str) -> tuple[str, str] | None:
    """Splits input into (command name, rest), resolving aliases and shorthands."""
    text = clean(text)
    if not text:
        return None
    if text[0] == "'":
        return "say", text[1:].strip()
    if text[0] == ":":
        return "emote", text[1:].strip()
    first, _, rest = text.partition(" ")
    first = first.lower()
    if first in SLOT_NUMBERS:  # "2 orc" uses slot 2
        return "use", text
    if not rest and (first in DIRECTIONS or first in SHORT_DIRECTIONS):
        return "move", SHORT_DIRECTIONS.get(first, first)
    return ALIASES.get(first, first), rest


async def dispatch(ctx: Context, text: str) -> None:
    parsed = parse(text)
    if parsed is None:
        return
    name, rest = parsed
    cmd = COMMANDS.get(name)
    if cmd is None or (cmd.admin and not ctx.is_admin):
        await ctx.reply(f"Unknown command '{name[:20]}'. Type HELP for a list.")
        return
    try:
        await cmd.handler(ctx, rest)
    except Usage as hint:
        await ctx.reply(str(hint) or f"Usage: {cmd.usage}")


def _require(rest: str, hint: str = "") -> str:
    if not rest:
        raise Usage(hint)
    return rest


def _split(rest: str, hint: str = "") -> tuple[str, str]:
    first, _, remainder = rest.partition(" ")
    if not first or not remainder:
        raise Usage(hint)
    return first.lower(), remainder


FILLER_WORDS = ("at", "to", "on", "the", "a", "an")


def _thing(rest: str) -> str:
    """Lowercases a reference to something and drops filler: 'at the Anvil' -> 'anvil'."""
    words = rest.lower().split()
    while len(words) > 1 and words[0] in FILLER_WORDS:
        words.pop(0)
    return " ".join(words)


def _channel(rest: str) -> str:
    name = rest.lower().lstrip("#")
    if not CHANNEL_RE.match(name):
        raise Usage("Channel names are 2-24 lowercase letters, digits, '-' or '_'.")
    return name


# Looking around ---------------------------------------------------------------


@command("look", "LOOK [thing]", "Describe the room, or something in it.", aliases=("l",))
async def look(ctx: Context, rest: str) -> None:
    await ctx.call("look", _thing(rest))


@command("inspect", "INSPECT <thing>", "Examine something closely.", aliases=("examine", "x"))
async def inspect(ctx: Context, rest: str) -> None:
    await ctx.call("inspect", _require(_thing(rest) or ctx.target, "Inspect what?"))


@command("inventory", "INVENTORY", "List what you're carrying.", aliases=("i", "inv"))
async def inventory(ctx: Context, rest: str) -> None:
    await ctx.call("inventory")


@command("who", "WHO", "List who is online.")
async def who(ctx: Context, rest: str) -> None:
    await ctx.call("who")


# Weather ----------------------------------------------------------------------


@command("weather", "WEATHER", "The weather here, what's on the ground, and the forecast if you can read these skies.",
         aliases=("forecast", "sky"))
async def weather(ctx: Context, rest: str) -> None:
    await ctx.call("weather")


@command("ask", "ASK <someone> [ABOUT] <topic>", "Ask someone about something, e.g. ASK TAMSIN ABOUT WEATHER.")
async def ask(ctx: Context, rest: str) -> None:
    words = [w for w in _thing(rest).split() if w != "about"]
    if not words:
        raise Usage("Ask whom, about what? e.g. ASK TAMSIN ABOUT WEATHER.")
    topic = words.pop()
    whom = " ".join(words) or ctx.target
    await ctx.call("ask", _require(whom, "Ask whom? Name them, or press Tab to pick someone."), topic)


# Moving -----------------------------------------------------------------------


@command("choose", "CHOOSE <number>", "Make a choice in a travel event, e.g. CHOOSE 2.", aliases=("pick",))
async def choose(ctx: Context, rest: str) -> None:
    number = rest.strip()
    if not number.isdigit():
        raise Usage("Choose which? e.g. CHOOSE 1.")
    await ctx.call("choose", number)


@command("flee", "FLEE", "Run from an ambush on the road, and be left behind in the wilds.", aliases=("run",))
async def flee(ctx: Context, rest: str) -> None:
    await ctx.call("flee")


@command("travel", "TRAVEL [destination]", "List the ferries, coaches, portals and other routes from here, or take one, e.g. TRAVEL VILLAGE GREEN.",
         aliases=("enter", "board", "ride"))
async def travel(ctx: Context, rest: str) -> None:
    await ctx.call("travel", _thing(rest))


@command("move", "MOVE <direction>", "Walk somewhere. Shorthand: N, S, E, W, NE, NW, SE, SW, U, D.", aliases=("go", "walk"))
async def move(ctx: Context, rest: str) -> None:
    direction = rest.lower()
    direction = SHORT_DIRECTIONS.get(direction, direction)
    if direction not in DIRECTIONS:
        raise Usage("Move where? Directions are " + ", ".join(DIRECTIONS) + ".")
    await ctx.call("move", direction)


@command("creep", "CREEP <direction>", "Step somewhere carefully: slower, but likelier to spot a trap.", aliases=("careful", "sneak"))
async def creep(ctx: Context, rest: str) -> None:
    direction = rest.lower()
    direction = SHORT_DIRECTIONS.get(direction, direction)
    if direction not in DIRECTIONS:
        raise Usage("Creep where? Directions are " + ", ".join(DIRECTIONS) + ".")
    await ctx.call("move", direction, "careful")


# Acting in the room -----------------------------------------------------------


@command("say", "SAY <message>", "Speak to everyone in the room (addressed to your target, if you have one). Shorthand: 'message (an apostrophe first)")
async def say(ctx: Context, rest: str) -> None:
    await ctx.call("say", _require(rest, "Say what?"), ctx.target)


@command("emote", "EMOTE <action>", "Act something out, e.g. EMOTE STRETCHES. Shorthand: :action", aliases=("me",))
async def emote(ctx: Context, rest: str) -> None:
    text = _require(rest, "Emote what?")
    if text[-1] not in ".!?":
        text += "."
    await ctx.call("emote", "", "", text, "")


# Fixed verbs: (text without a target, text with one). None means that form
# isn't allowed. Rooms can override the targeted text for their features
# (e.g. "touch ground" in the tavern).
VERBS: dict[str, tuple[str | None, str | None]] = {
    "wave": ("{actor} waves.", "{actor} waves at {target}."),
    "nod": ("{actor} nods.", "{actor} nods to {target}."),
    "bow": ("{actor} bows.", "{actor} bows to {target}."),
    "smile": ("{actor} smiles.", "{actor} smiles at {target}."),
    "laugh": ("{actor} laughs.", "{actor} laughs at {target}."),
    "dance": ("{actor} dances.", "{actor} dances with {target}."),
    "cheer": ("{actor} cheers.", "{actor} cheers for {target}."),
    "point": (None, "{actor} points at {target}."),
    "poke": (None, "{actor} pokes {target}."),
    "touch": (None, "{actor} touches {target}."),
    "sit": ("{actor} sits down.", "{actor} sits on {target}."),
    "stand": ("{actor} stands up.", None),
}


def _verb_handler(verb: str, plain: str | None, targeted: str | None) -> Handler:
    async def handler(ctx: Context, rest: str) -> None:
        target = _thing(rest) or (ctx.target if targeted else "")
        if target and targeted is None:
            raise Usage(f"Just {verb.upper()}.")
        if not target and plain is None:
            raise Usage(f"{verb.capitalize()} what?")
        await ctx.call("emote", verb, target, plain or "", targeted or "")

    return handler


for _verb, (_plain, _targeted) in VERBS.items():
    _usage = _verb.upper() if _targeted is None else (f"{_verb.upper()} <thing>" if _plain is None else f"{_verb.upper()} [thing]")
    command(_verb, _usage, f"Emote: {_verb}.")(_verb_handler(_verb, _plain, _targeted))


@command("describe", "DESCRIBE <text>", "Set the short description others see, e.g. 'tall, with a scarred lip'.")
async def describe(ctx: Context, rest: str) -> None:
    text = _require(rest, "Describe yourself how? e.g. DESCRIBE tall, with a scarred lip")
    if len(text) > 80:
        raise Usage("Keep it under 80 characters.")
    await ctx.call("describe", text)


# Combat -----------------------------------------------------------------------


# Three slots, each holding a piece of gear with its own rhythm (see
# alzendor.lua): the first use lands at once, and after that only on its beat.
SLOT_NUMBERS = ("1", "2", "3")
SLOT_FILLER = ("in", "into", "to", "slot")


@command("use", "USE <slot> [target] | USE <item> [ON <thing>]",
         "Use what's in slot 1, 2 or 3, on its beat (shorthand: 1, 2, 3; in the web client, the keys 4, 3, 2), "
         "or use something you carry, e.g. USE TAR ON HULL.")
async def use(ctx: Context, rest: str) -> None:
    slot, _, target = rest.partition(" ")
    if slot in SLOT_NUMBERS:
        await ctx.call("use", slot, _thing(target) or ctx.target)
        return
    if not rest or slot.isdigit():
        raise Usage("Use which slot? 1, 2 or 3. Or USE <item> ON <thing>.")
    item, _, thing = rest.lower().partition(" on ")
    await ctx.call("use_item", _thing(item), _thing(thing))


@command("learn", "LEARN <talent or passive>", "Learn a talent from your class (at even levels) or a passive from your ancestry (at 5, 10, 15 and 20).")
async def learn(ctx: Context, rest: str) -> None:
    await ctx.call("learn", _require(rest.strip(), "Learn what? The Character panel lists what you can."))


@command("attune", "ATTUNE <passive> <slot>", "Choose which slot a slot passive (like Second Wind) belongs to.")
async def attune(ctx: Context, rest: str) -> None:
    words = rest.lower().split()
    if len(words) < 2 or words[-1] not in SLOT_NUMBERS:
        raise Usage("Usage: ATTUNE <passive> <slot>, e.g. ATTUNE SECOND WIND 1.")
    await ctx.call("attune", " ".join(words[:-1]), words[-1])


@command("respec", "RESPEC", "At a trainer, forget your talents and passives and choose again, for 10 coins a level.")
async def respec(ctx: Context, rest: str) -> None:
    await ctx.call("respec")


@command("quests", "QUESTS", "List your quests and what each needs next.", aliases=("journal", "q"))
async def quests(ctx: Context, rest: str) -> None:
    await ctx.call("quests")


@command("equip", "EQUIP <gear> [slot]", "Put gear in a slot, e.g. EQUIP SWORD 2. GEAR lists it all.", aliases=("wield",))
async def equip(ctx: Context, rest: str) -> None:
    words = rest.lower().split()
    slot = ""
    if words and words[-1] in SLOT_NUMBERS:
        slot = words.pop()
    elif words and words[0] in SLOT_NUMBERS:
        slot = words.pop(0)
    while words and words[-1] in SLOT_FILLER:
        words.pop()
    await ctx.call("equip", _require(_thing(" ".join(words)), "Equip what? Type GEAR to see what there is."), slot)


@command("unequip", "UNEQUIP <slot>", "Empty a slot.")
async def unequip(ctx: Context, rest: str) -> None:
    slot = rest.lower().removeprefix("slot").strip()
    if slot not in SLOT_NUMBERS:
        raise Usage("Unequip which slot? 1, 2 or 3.")
    await ctx.call("unequip", slot)


@command("gear", "GEAR", "List your gear and what's in your slots.", aliases=("slots", "loadout"))
async def gear(ctx: Context, rest: str) -> None:
    await ctx.call("gear")


# Character ----------------------------------------------------------------------

STATS = ("vigor", "poise", "focus", "presence", "resilience")


@command("stats", "STATS", "Your level, stats, perks and reputation.", aliases=("character", "sheet", "reputation", "rep"))
async def stats(ctx: Context, rest: str) -> None:
    await ctx.call("stats")


@command("train", "TRAIN <stat>", "Spend a stat point: vigor, poise, focus, presence or resilience.")
async def train(ctx: Context, rest: str) -> None:
    stat = rest.lower().strip()
    if stat not in STATS:
        raise Usage("Train which stat? " + ", ".join(STATS) + ".")
    await ctx.call("train", stat)


@command("get", "GET <item>", "Pick something up.", aliases=("take",))
async def get(ctx: Context, rest: str) -> None:
    await ctx.call("get", _thing(_require(rest, "Get what?")))


@command("drop", "DROP <item>", "Put something down.")
async def drop(ctx: Context, rest: str) -> None:
    await ctx.call("drop", _thing(_require(rest, "Drop what?")))


# Talking ----------------------------------------------------------------------


@command("tell", "TELL <player> <message>", "Send a private message to a player.", aliases=("whisper", "dm"))
async def tell(ctx: Context, rest: str) -> None:
    target, message = _split(rest, "Usage: tell <player> <message>")
    await ctx.call("tell", target, message)


@command("chat", "CHAT <channel> <message>", "Talk on a chat channel you've joined.", aliases=("c",))
async def chat(ctx: Context, rest: str) -> None:
    channel, message = _split(rest, "Usage: chat <channel> <message>")
    await ctx.call("chat", _channel(channel), message)


@command("channels", "CHANNELS", "List chat channels.")
async def channels(ctx: Context, rest: str) -> None:
    await ctx.call("channels")


@command("join", "JOIN <channel>", "Join a chat channel.")
async def join(ctx: Context, rest: str) -> None:
    await ctx.call("join", _channel(_require(rest)))


@command("leave", "LEAVE <channel>", "Leave a chat channel.")
async def leave(ctx: Context, rest: str) -> None:
    await ctx.call("leave", _channel(_require(rest)))


@command("create", "CREATE <channel>", "Create a new chat channel and join it.")
async def create(ctx: Context, rest: str) -> None:
    rest = rest.removeprefix("channel ").strip()
    await ctx.call("create_channel", _channel(_require(rest)))


# Admin ------------------------------------------------------------------------


@command("announce", "ANNOUNCE AREA|REGION|REALM <message>", "Announce to your whole area, region or realm.", admin=True)
async def announce(ctx: Context, rest: str) -> None:
    scope, message = _split(rest, "Usage: ANNOUNCE AREA|REGION|REALM <message>")
    if scope not in ("area", "region", "realm"):
        raise Usage("Usage: ANNOUNCE AREA|REGION|REALM <message>")
    await ctx.call("announce", scope, message)


@command("setweather", "SETWEATHER <temperature> <energy> <precipitation> | CLEAR",
         "Pin the weather in your region (each -1 to 1) for testing, or let it run free.", admin=True)
async def setweather(ctx: Context, rest: str) -> None:
    values = rest.lower().split()
    if values != ["clear"] and len(values) != 3:
        raise Usage("Usage: SETWEATHER <temperature> <energy> <precipitation> (each -1 to 1), or SETWEATHER CLEAR.")
    await ctx.call("set_weather", *values)


@command("goto", "GOTO <room id>", "Jump to any room, for testing.", admin=True)
async def goto(ctx: Context, rest: str) -> None:
    await ctx.call("goto", _require(rest.strip().lower(), "Usage: GOTO <room id>"))


@command("setclock", "SETCLOCK <hour> | CLEAR", "Pin the time of day (0-23) for testing, or let the clock run.", admin=True)
async def setclock(ctx: Context, rest: str) -> None:
    value = rest.lower().strip()
    if not value:
        raise Usage("Usage: SETCLOCK <hour 0-23>, or SETCLOCK CLEAR.")
    await ctx.call("set_clock", value)


# Session ----------------------------------------------------------------------


@command("help", "HELP [command]", "List commands, or explain one.", aliases=("?", "commands"))
async def help_(ctx: Context, rest: str) -> None:
    visible = {name: cmd for name, cmd in COMMANDS.items() if ctx.is_admin or not cmd.admin}
    if rest:
        cmd = visible.get(parse(rest)[0])
        if cmd is None:
            raise Usage(f"There's no '{rest[:20]}' command.")
        lines = [cmd.usage, cmd.summary]
        if cmd.aliases:
            lines.append("Also: " + ", ".join(alias.upper() for alias in cmd.aliases))
        await ctx.reply("\n".join(lines))
        return
    width = max(len(cmd.usage) for cmd in visible.values())
    lines = ["Commands:"] + [f"  {cmd.usage.ljust(width)}  {cmd.summary}" for cmd in visible.values() if cmd.name not in VERBS]
    lines.append("Emotes: " + ", ".join(verb.upper() for verb in VERBS))
    await ctx.reply("\n".join(lines))


@command("quit", "QUIT", "Leave the world (you stay signed in on this device).")
async def quit_(ctx: Context, rest: str) -> None:
    await ctx.quit(False)


@command("logout", "LOGOUT", "Leave the world and sign out.")
async def logout(ctx: Context, rest: str) -> None:
    await ctx.quit(True)
