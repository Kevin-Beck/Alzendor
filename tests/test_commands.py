"""The parser and command handlers, with the world replaced by a recorder."""

import pytest

from alzendor import commands
from alzendor.commands import Context, clean, dispatch, parse


class RecordingWorld:
    def __init__(self):
        self.calls = []

    async def call(self, function, *args):
        self.calls.append((function, *args))
        return 1

    @property
    def replies(self):
        return [args[1] for function, *args in self.calls if function == "notify"]


@pytest.fixture
def ctx():
    return Context(RecordingWorld(), "kevin")


@pytest.mark.parametrize(
    "text, expected",
    [
        ("n", ("move", "north")),
        ("UP", ("move", "up")),
        ("go west", ("move", "west")),
        ("l", ("look", "")),
        ("'hello there", ("say", "hello there")),
        (":grins.", ("emote", "grins.")),
        ("  LOOK    at   anvil ", ("look", "at anvil")),
        ("x lantern", ("inspect", "lantern")),
        ("ne", ("move", "northeast")),
        ("d", ("move", "down")),
        ("n hello", ("n", "hello")),  # a direction with words after it isn't a move
        ("2", ("use", "2")),
        ("1 Orc", ("use", "1 Orc")),
    ],
)
def test_parse(text, expected):
    assert parse(text) == expected


def test_parse_ignores_blank_input():
    assert parse("   \t ") is None


def test_clean_strips_control_characters_and_collapses_spaces():
    assert clean("say\x00 hi\x1b[31m   there") == "say hi[31m there"
    assert len(clean("x" * 5000)) == commands.MAX_INPUT


async def test_commands_call_one_game_function(ctx):
    for text in ["n", "say hi", "touch the ground", "get the brass lantern", "tell Mara psst", "join #General"]:
        await dispatch(ctx, text)
    assert ctx.world.calls == [
        ("move", "kevin", "north"),
        ("say", "kevin", "hi", ""),
        ("emote", "kevin", "touch", "ground", "", "{actor} touches {target}."),
        ("get", "kevin", "brass lantern"),
        ("tell", "kevin", "mara", "psst"),
        ("join", "kevin", "general"),
    ]


async def test_selected_target_fills_in_for_commands_that_take_one(ctx):
    ctx.target = "npc:rat-2"
    for text in ["1", "wave", "inspect", "1 orc", "stand", "say hi"]:
        await dispatch(ctx, text)
    assert ctx.world.calls == [
        ("use", "kevin", "1", "npc:rat-2"),
        ("emote", "kevin", "wave", "npc:rat-2", "{actor} waves.", "{actor} waves at {target}."),
        ("inspect", "kevin", "npc:rat-2"),
        ("use", "kevin", "1", "orc"),  # typed names win
        ("emote", "kevin", "stand", "", "{actor} stands up.", ""),
        ("say", "kevin", "hi", "npc:rat-2"),  # said to the target
    ]


@pytest.mark.parametrize("value, expected", [
    ("npc:rat-2", "npc:rat-2"), ("pc:mara", "pc:mara"),
    ("PLAYER:mara", ""), ("npc:", ""), ("npc:a b", ""), (42, ""), (None, ""),
])
def test_target_ids_are_validated(value, expected):
    assert commands.target_id(value) == expected


async def test_slot_commands(ctx):
    for text in ["3", "use 2 the orc", "2 at rat", "equip sword 2", "equip 1 magic missile", "wield greataxe in slot 3",
                 "equip dagger", "unequip 2", "unequip slot 3", "gear", "slots", "train Poise", "stats", "rep"]:
        await dispatch(ctx, text)
    assert ctx.world.calls == [
        ("use", "kevin", "3", ""),
        ("use", "kevin", "2", "orc"),
        ("use", "kevin", "2", "rat"),
        ("equip", "kevin", "sword", "2"),
        ("equip", "kevin", "magic missile", "1"),
        ("equip", "kevin", "greataxe", "3"),
        ("equip", "kevin", "dagger", ""),
        ("unequip", "kevin", "2"),
        ("unequip", "kevin", "3"),
        ("gear", "kevin"),
        ("gear", "kevin"),
        ("train", "kevin", "poise"),
        ("stats", "kevin"),
        ("stats", "kevin"),
    ]


async def test_free_emote_gets_punctuation(ctx):
    await dispatch(ctx, "emote stretches")
    assert ctx.world.calls == [("emote", "kevin", "", "", "stretches.", "")]


@pytest.mark.parametrize(
    "text, reply",
    [
        ("move sideways", "Move where?"),
        ("touch", "Touch what?"),
        ("use", "Use which slot?"),
        ("use 4 orc", "Use which slot?"),
        ("equip", "Equip what?"),
        ("equip 2", "Equip what?"),
        ("unequip", "Unequip which slot?"),
        ("stand on table", "Just 'stand'."),
        ("say", "Say what?"),
        ("tell mara", "Usage: tell <player> <message>"),
        ("juggle", "Unknown command 'juggle'"),
        ("train", "Train which stat?"),
        ("train strength", "Train which stat?"),
    ],
)
async def test_bad_input_gets_a_hint_not_an_action(ctx, text, reply):
    await dispatch(ctx, text)
    assert len(ctx.world.calls) == 1
    assert ctx.world.replies[0].startswith(reply)


@pytest.mark.parametrize("name", ["PLAYER:mara", "ROOM:tavern", "x", "a" * 30])
async def test_private_channels_cannot_be_joined(ctx, name):
    await dispatch(ctx, f"join {name}")
    assert ctx.world.replies[0].startswith("Channel names are")


async def test_admin_commands_are_hidden_from_players(ctx):
    await dispatch(ctx, "announce city Hello")
    assert ctx.world.replies == ["Unknown command 'announce'. Type 'help' for a list."]
    await dispatch(ctx, "help")
    assert "announce" not in ctx.world.replies[1]

    admin = Context(RecordingWorld(), "kevin", is_admin=True)
    await dispatch(admin, "announce city Hello")
    assert admin.world.calls == [("announce", "kevin", "city", "Hello")]


async def test_help_lists_every_command(ctx):
    await dispatch(ctx, "help")
    listing = ctx.world.replies[0]
    for name, cmd in commands.COMMANDS.items():
        if not cmd.admin:
            assert name in listing
    await dispatch(ctx, "help n")
    assert ctx.world.replies[1].startswith("move <direction>")
