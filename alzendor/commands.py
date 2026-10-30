"""Player commands.

Each command is one handler registered with @command; the parser and `help`
both work from that registry. Handlers check the shape of the input and then
call one game-rules function (alzendor.lua), which checks it against the world
and publishes the outcome. Nothing a handler does is sent to the client
directly: replies are events on the player's own channel, like everything else.
"""

import re
from collections.abc import Awaitable, Callable
from dataclasses import dataclass, field

from .world import DIRECTIONS, World

MAX_INPUT = 500
CHANNEL_RE = re.compile(r"^[a-z0-9][a-z0-9_-]{1,23}$")
TARGET_RE = re.compile(r"^(pc|npc):[a-z0-9_-]{1,40}$")
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
        await ctx.reply(f"Unknown command '{name[:20]}'. Type 'help' for a list.")
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


@command("look", "look [thing]", "Describe the room, or something in it.", aliases=("l",))
async def look(ctx: Context, rest: str) -> None:
    await ctx.call("look", _thing(rest))


@command("inspect", "inspect <thing>", "Examine something closely.", aliases=("examine", "x"))
async def inspect(ctx: Context, rest: str) -> None:
    await ctx.call("inspect", _require(_thing(rest) or ctx.target, "Inspect what?"))


@command("inventory", "inventory", "List what you're carrying.", aliases=("i", "inv"))
async def inventory(ctx: Context, rest: str) -> None:
    await ctx.call("inventory")


@command("who", "who", "List who is online.")
async def who(ctx: Context, rest: str) -> None:
    await ctx.call("who")


# Moving -----------------------------------------------------------------------


@command("move", "move <direction>", "Walk somewhere. Shorthand: n, s, e, w, ne, nw, se, sw, u, d.", aliases=("go", "walk"))
async def move(ctx: Context, rest: str) -> None:
    direction = rest.lower()
    direction = SHORT_DIRECTIONS.get(direction, direction)
    if direction not in DIRECTIONS:
        raise Usage("Move where? Directions are " + ", ".join(DIRECTIONS) + ".")
    await ctx.call("move", direction)


# Acting in the room -----------------------------------------------------------


@command("say", "say <message>", "Speak to everyone in the room (addressed to your target, if you have one). Shorthand: 'message")
async def say(ctx: Context, rest: str) -> None:
    await ctx.call("say", _require(rest, "Say what?"), ctx.target)


@command("emote", "emote <action>", "Act something out, e.g. 'emote stretches'. Shorthand: :action", aliases=("me",))
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
            raise Usage(f"Just '{verb}'.")
        if not target and plain is None:
            raise Usage(f"{verb.capitalize()} what?")
        await ctx.call("emote", verb, target, plain or "", targeted or "")

    return handler


for _verb, (_plain, _targeted) in VERBS.items():
    _usage = _verb if _targeted is None else (f"{_verb} <thing>" if _plain is None else f"{_verb} [thing]")
    command(_verb, _usage, f"Emote: {_verb}.")(_verb_handler(_verb, _plain, _targeted))


@command("describe", "describe <text>", "Set the short description others see, e.g. 'tall, with a scarred lip'.")
async def describe(ctx: Context, rest: str) -> None:
    text = _require(rest, "Describe yourself how? e.g. 'describe tall, with a scarred lip'")
    if len(text) > 80:
        raise Usage("Keep it under 80 characters.")
    await ctx.call("describe", text)


# Combat -----------------------------------------------------------------------


# Three slots, each holding a piece of gear with its own rhythm (see
# alzendor.lua): the first use lands at once, and after that only on its beat.
SLOT_NUMBERS = ("1", "2", "3")
SLOT_FILLER = ("in", "into", "to", "slot")


@command("use", "use <slot> [target]", "Use what's in slot 1, 2 or 3, on its beat. Shorthand: 1, 2, 3")
async def use(ctx: Context, rest: str) -> None:
    slot, _, target = rest.partition(" ")
    if slot not in SLOT_NUMBERS:
        raise Usage("Use which slot? 1, 2 or 3.")
    await ctx.call("use", slot, _thing(target) or ctx.target)


@command("equip", "equip <gear> [slot]", "Put gear in a slot, e.g. 'equip sword 2'. 'gear' lists it all.", aliases=("wield",))
async def equip(ctx: Context, rest: str) -> None:
    words = rest.lower().split()
    slot = ""
    if words and words[-1] in SLOT_NUMBERS:
        slot = words.pop()
    elif words and words[0] in SLOT_NUMBERS:
        slot = words.pop(0)
    while words and words[-1] in SLOT_FILLER:
        words.pop()
    await ctx.call("equip", _require(_thing(" ".join(words)), "Equip what? Type 'gear' to see what there is."), slot)


@command("unequip", "unequip <slot>", "Empty a slot.")
async def unequip(ctx: Context, rest: str) -> None:
    slot = rest.lower().removeprefix("slot").strip()
    if slot not in SLOT_NUMBERS:
        raise Usage("Unequip which slot? 1, 2 or 3.")
    await ctx.call("unequip", slot)


@command("gear", "gear", "List your gear and what's in your slots.", aliases=("slots", "loadout"))
async def gear(ctx: Context, rest: str) -> None:
    await ctx.call("gear")


# Character ----------------------------------------------------------------------

STATS = ("vigor", "poise", "focus", "presence")


@command("stats", "stats", "Your level, stats, perks and reputation.", aliases=("character", "sheet", "reputation", "rep"))
async def stats(ctx: Context, rest: str) -> None:
    await ctx.call("stats")


@command("train", "train <stat>", "Spend a stat point: vigor, poise, focus or presence.")
async def train(ctx: Context, rest: str) -> None:
    stat = rest.lower().strip()
    if stat not in STATS:
        raise Usage("Train which stat? " + ", ".join(STATS) + ".")
    await ctx.call("train", stat)


@command("get", "get <item>", "Pick something up.", aliases=("take",))
async def get(ctx: Context, rest: str) -> None:
    await ctx.call("get", _thing(_require(rest, "Get what?")))


@command("drop", "drop <item>", "Put something down.")
async def drop(ctx: Context, rest: str) -> None:
    await ctx.call("drop", _thing(_require(rest, "Drop what?")))


# Talking ----------------------------------------------------------------------


@command("tell", "tell <player> <message>", "Send a private message to a player.", aliases=("whisper", "dm"))
async def tell(ctx: Context, rest: str) -> None:
    target, message = _split(rest, "Usage: tell <player> <message>")
    await ctx.call("tell", target, message)


@command("chat", "chat <channel> <message>", "Talk on a chat channel you've joined.", aliases=("c",))
async def chat(ctx: Context, rest: str) -> None:
    channel, message = _split(rest, "Usage: chat <channel> <message>")
    await ctx.call("chat", _channel(channel), message)


@command("channels", "channels", "List chat channels.")
async def channels(ctx: Context, rest: str) -> None:
    await ctx.call("channels")


@command("join", "join <channel>", "Join a chat channel.")
async def join(ctx: Context, rest: str) -> None:
    await ctx.call("join", _channel(_require(rest)))


@command("leave", "leave <channel>", "Leave a chat channel.")
async def leave(ctx: Context, rest: str) -> None:
    await ctx.call("leave", _channel(_require(rest)))


@command("create", "create <channel>", "Create a new chat channel and join it.")
async def create(ctx: Context, rest: str) -> None:
    rest = rest.removeprefix("channel ").strip()
    await ctx.call("create_channel", _channel(_require(rest)))


# Admin ------------------------------------------------------------------------


@command("announce", "announce <area|city> <message>", "Announce to your whole area or city.", admin=True)
async def announce(ctx: Context, rest: str) -> None:
    scope, message = _split(rest, "Usage: announce <area|city> <message>")
    if scope not in ("area", "city"):
        raise Usage("Usage: announce <area|city> <message>")
    await ctx.call("announce", scope, message)


# Session ----------------------------------------------------------------------


@command("help", "help [command]", "List commands, or explain one.", aliases=("?", "commands"))
async def help_(ctx: Context, rest: str) -> None:
    visible = {name: cmd for name, cmd in COMMANDS.items() if ctx.is_admin or not cmd.admin}
    if rest:
        cmd = visible.get(parse(rest)[0])
        if cmd is None:
            raise Usage(f"There's no '{rest[:20]}' command.")
        lines = [cmd.usage, cmd.summary]
        if cmd.aliases:
            lines.append("Also: " + ", ".join(cmd.aliases))
        await ctx.reply("\n".join(lines))
        return
    width = max(len(cmd.usage) for cmd in visible.values())
    lines = ["Commands:"] + [f"  {cmd.usage.ljust(width)}  {cmd.summary}" for cmd in visible.values() if cmd.name not in VERBS]
    lines.append("Emotes: " + ", ".join(VERBS))
    await ctx.reply("\n".join(lines))


@command("quit", "quit", "Leave the world (you stay signed in on this device).")
async def quit_(ctx: Context, rest: str) -> None:
    await ctx.quit(False)


@command("logout", "logout", "Leave the world and sign out.")
async def logout(ctx: Context, rest: str) -> None:
    await ctx.quit(True)
